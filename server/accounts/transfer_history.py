import hashlib
import logging
from datetime import datetime, timedelta, timezone as dt_timezone
from decimal import Decimal, InvalidOperation
from typing import Any, Callable, Optional
from zoneinfo import ZoneInfo

from django.db import transaction
from django.db.models import Q, Sum

from accounts.models import TransferHistoryRecord, TransferHistorySyncState
from api_bindings.models import ApiBinding
from api_bindings.services import (
    get_user_binding_generation,
    get_user_api_key_fingerprint,
    get_user_binance_credentials,
    get_user_binance_credentials_for_generation,
)
from common.binance import BinanceApiError, BinanceFuturesClient, is_binance_rate_limit_error
from common.errors import safe_error_summary
from trading.balance_cap import account_type_for_client
from trading.locks import distributed_cache_lock


logger = logging.getLogger(__name__)
TRANSFER_HISTORY_ASSET = "USDT"
TRANSFER_HISTORY_ZONE = ZoneInfo("Asia/Shanghai")
TRANSFER_HISTORY_START = datetime(2026, 8, 28, tzinfo=TRANSFER_HISTORY_ZONE)
SUB_ACCOUNT_PAGE_SIZE = 200
MASTER_ACCOUNT_PAGE_SIZE = 1000
PAY_PAGE_SIZE = 100
# Binance requires both wallet-history timestamps to span less than 90 days.
MASTER_WINDOW_MS = int(timedelta(days=89).total_seconds() * 1000)
MAX_MASTER_HISTORY_ROWS = 100_000
TRANSFER_HISTORY_OVERLAP = timedelta(days=3)
TRANSFER_HISTORY_SYNC_LOCK_SECONDS = 120
# A source change requires one successful backfill before resuming the overlap.
TRANSFER_HISTORY_SOURCE_VERSION = 2


def _decimal_value(value: Any) -> Optional[Decimal]:
    try:
        amount = Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return None
    if not amount.is_finite() or amount <= 0:
        return None
    return amount


def _decimal_text(value: Decimal) -> str:
    return format(value, "f")


def _compact_decimal_text(value: Decimal) -> str:
    text = format(value, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text or "0"


def _to_local_datetime(value: Any) -> Optional[datetime]:
    if value is None or value == "":
        return None
    try:
        if isinstance(value, (int, float, Decimal)) or str(value).strip().isdigit():
            raw = Decimal(str(value).strip())
            divisor = Decimal("1000") if raw >= Decimal("100000000000") else Decimal("1")
            return datetime.fromtimestamp(float(raw / divisor), tz=dt_timezone.utc).astimezone(
                TRANSFER_HISTORY_ZONE
            )
    except (InvalidOperation, OSError, OverflowError, ValueError):
        return None

    text = str(value).strip()
    if not text:
        return None
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        try:
            parsed = datetime.strptime(text, "%Y-%m-%d %H:%M:%S")
        except ValueError:
            return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt_timezone.utc)
    return parsed.astimezone(TRANSFER_HISTORY_ZONE)


def _record_id(prefix: str, row: dict[str, Any], *preferred_fields: str) -> str:
    for field in preferred_fields:
        value = str(row.get(field) or "").strip()
        if value:
            digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:20]
            return f"{prefix}-{digest}"
    digest_source = "|".join(
        str(row.get(field) or "")
        for field in ("coin", "asset", "amount", "qty", "time", "insertTime", "applyTime")
    )
    return f"{prefix}-{hashlib.sha256(digest_source.encode('utf-8')).hexdigest()[:20]}"


def _wallet_label(value: Any) -> str:
    wallet_type = str(value or "").strip().upper()
    return {
        "SPOT": "现货",
        "FUNDING": "资金",
        "USDT_FUTURE": "合约",
        "USDT_FUTURES": "合约",
        "UMFUTURE": "合约",
        "FUTURES": "合约",
        "COIN_FUTURE": "币本位合约",
        "COIN_FUTURES": "币本位合约",
        "CMFUTURE": "币本位合约",
        "MARGIN": "杠杆",
    }.get(wallet_type, "账户")


def _counterparty_label(row: dict[str, Any]) -> str:
    return "所属主账户" if str(row.get("counterParty") or "").lower() == "master" else "币安账户"


def _in_requested_period(
    occurred_at: Optional[datetime], start_at: datetime, end_at: datetime
) -> bool:
    return bool(occurred_at and start_at <= occurred_at <= end_at)


def _sub_account_rows(
    client: BinanceFuturesClient,
    *,
    transfer_type: int,
    start_ms: int,
    end_ms: int,
) -> list[dict[str, Any]]:
    rows = client.get_sub_account_transfer_history(
        ccy=TRANSFER_HISTORY_ASSET,
        transfer_type=transfer_type,
        start_time_ms=start_ms,
        end_time_ms=end_ms,
        limit=SUB_ACCOUNT_PAGE_SIZE,
    )
    if len(rows) < SUB_ACCOUNT_PAGE_SIZE:
        return rows
    if start_ms >= end_ms:
        raise BinanceApiError("同一时间点的转账流水超过查询上限，暂时无法生成准确统计")

    midpoint = start_ms + (end_ms - start_ms) // 2
    return _sub_account_rows(
        client,
        transfer_type=transfer_type,
        start_ms=start_ms,
        end_ms=midpoint,
    ) + _sub_account_rows(
        client,
        transfer_type=transfer_type,
        start_ms=midpoint + 1,
        end_ms=end_ms,
    )


def _master_windows(start_ms: int, end_ms: int):
    cursor = start_ms
    while cursor <= end_ms:
        window_end = min(end_ms, cursor + MASTER_WINDOW_MS)
        yield cursor, window_end
        cursor = window_end + 1


def _pay_history_rows(
    client: BinanceFuturesClient, *, start_ms: int, end_ms: int
) -> list[dict[str, Any]]:
    rows = client.get_pay_transactions(
        start_time_ms=start_ms, end_time_ms=end_ms, limit=PAY_PAGE_SIZE,
    )
    if len(rows) < PAY_PAGE_SIZE:
        return rows
    if start_ms >= end_ms:
        raise BinanceApiError("同一时间点的站内转账流水达到查询上限，暂时无法生成准确统计")
    midpoint = start_ms + (end_ms - start_ms) // 2
    return _pay_history_rows(client, start_ms=start_ms, end_ms=midpoint) + _pay_history_rows(
        client, start_ms=midpoint + 1, end_ms=end_ms,
    )


def _normalized_pay_records(
    client: BinanceFuturesClient,
    *,
    start_ms: int,
    end_ms: int,
    start_at: datetime,
    end_at: datetime,
) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for window_start, window_end in _master_windows(start_ms, end_ms):
        for row in _pay_history_rows(client, start_ms=window_start, end_ms=window_end):
            if str(row.get("currency") or "").upper() != TRANSFER_HISTORY_ASSET:
                continue
            if not str(row.get("transactionId") or "").strip():
                continue
            try:
                amount = Decimal(str(row.get("amount")))
            except (InvalidOperation, TypeError, ValueError):
                continue
            occurred_at = _to_local_datetime(row.get("transactionTime"))
            if not amount.is_finite() or amount == 0 or not _in_requested_period(occurred_at, start_at, end_at):
                continue
            incoming = amount > 0
            # Pay wallet types differ from the capital deposit endpoint.
            wallet = {"1": "资金", "2": "现货"}.get(str(row.get("walletType")), "账户")
            normalized.append({
                "id": _record_id("pay", row, "transactionId"),
                "direction": "incoming" if incoming else "outgoing",
                "amount": _decimal_text(abs(amount)),
                "asset": TRANSFER_HISTORY_ASSET,
                "occurred_at": occurred_at.isoformat(),
                "route": f"币安账户 -> {wallet}" if incoming else f"{wallet} -> 币安账户",
                "channel": "币安站内转账",
            })
    return normalized


def _offset_history_rows(
    fetch_page: Callable[..., list[dict[str, Any]]],
    *,
    start_ms: int,
    end_ms: int,
    status: int,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    offset = 0
    previous_signature: Optional[tuple[str, str, int]] = None
    while True:
        page = fetch_page(
            ccy=TRANSFER_HISTORY_ASSET,
            status=status,
            start_time_ms=start_ms,
            end_time_ms=end_ms,
            offset=offset,
            limit=MASTER_ACCOUNT_PAGE_SIZE,
        )
        if len(page) >= MASTER_ACCOUNT_PAGE_SIZE:
            signature = (
                str(page[0].get("id") or page[0].get("txId") or ""),
                str(page[-1].get("id") or page[-1].get("txId") or ""),
                len(page),
            )
            if signature == previous_signature:
                raise BinanceApiError("交易所历史分页结果重复，暂时无法生成准确统计")
            previous_signature = signature
        rows.extend(page)
        if len(page) < MASTER_ACCOUNT_PAGE_SIZE:
            return rows
        if len(rows) >= MAX_MASTER_HISTORY_ROWS:
            raise BinanceApiError("转账历史记录过多，暂时无法生成准确统计")
        offset += MASTER_ACCOUNT_PAGE_SIZE


def _normalized_sub_records(
    client: BinanceFuturesClient,
    *,
    start_ms: int,
    end_ms: int,
    start_at: datetime,
    end_at: datetime,
) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for transfer_type, direction in ((1, "incoming"), (2, "outgoing")):
        rows = _sub_account_rows(
            client,
            transfer_type=transfer_type,
            start_ms=start_ms,
            end_ms=end_ms,
        )
        for row in rows:
            if str(row.get("asset") or "").upper() != TRANSFER_HISTORY_ASSET:
                continue
            if str(row.get("status") or "").upper() != "SUCCESS":
                continue
            row_type = row.get("type")
            if row_type not in (None, "") and str(row_type) != str(transfer_type):
                continue
            if direction == "outgoing" and str(row.get("fromAccountType") or "").upper() != "SPOT":
                continue
            amount = _decimal_value(row.get("qty"))
            occurred_at = _to_local_datetime(row.get("time"))
            if amount is None or not _in_requested_period(occurred_at, start_at, end_at):
                continue
            counterparty = _counterparty_label(row)
            if direction == "incoming":
                route = f"{counterparty} -> {_wallet_label(row.get('toAccountType'))}"
            else:
                route = f"现货 -> {counterparty}"
            normalized.append(
                {
                    "id": _record_id(f"sub-{transfer_type}", row, "tranId"),
                    "direction": direction,
                    "amount": _decimal_text(amount),
                    "asset": TRANSFER_HISTORY_ASSET,
                    "occurred_at": occurred_at.isoformat(),
                    "route": route,
                    "channel": "币安账户划转",
                }
            )
    return normalized


def _is_spot_wallet(row: dict[str, Any]) -> bool:
    wallet_type = row.get("walletType")
    return wallet_type in (None, "", 0, "0")


def _normalized_deposit_records(
    client: BinanceFuturesClient,
    *,
    start_ms: int,
    end_ms: int,
    start_at: datetime,
    end_at: datetime,
) -> list[dict[str, Any]]:
    deposit_rows: list[dict[str, Any]] = []
    for window_start, window_end in _master_windows(start_ms, end_ms):
        deposit_rows.extend(
            _offset_history_rows(
                client.get_deposit_history,
                start_ms=window_start,
                end_ms=window_end,
                status=1,
            )
        )
    normalized: list[dict[str, Any]] = []
    for row in deposit_rows:
        if str(row.get("coin") or "").upper() != TRANSFER_HISTORY_ASSET:
            continue
        if str(row.get("status") or "") != "1":
            continue
        amount = _decimal_value(row.get("amount"))
        occurred_at = _to_local_datetime(row.get("completeTime") or row.get("insertTime"))
        if amount is None or not _in_requested_period(occurred_at, start_at, end_at):
            continue
        is_internal = str(row.get("transferType") or "0") == "1"
        wallet = {"0": "现货", "1": "资金"}.get(str(row.get("walletType")), "账户")
        normalized.append(
            {
                "id": _record_id("deposit", row, "id", "txId"),
                "direction": "incoming",
                "amount": _decimal_text(amount),
                "asset": TRANSFER_HISTORY_ASSET,
                "occurred_at": occurred_at.isoformat(),
                "route": f"{'币安账户' if is_internal else '外部账户'} -> {wallet}",
                "channel": "币安站内转账" if is_internal else f"{str(row.get('network') or '链上')}充值",
            }
        )
    return normalized


def _normalized_master_withdrawals(
    client: BinanceFuturesClient,
    *,
    start_ms: int,
    end_ms: int,
    start_at: datetime,
    end_at: datetime,
) -> list[dict[str, Any]]:
    withdrawal_rows: list[dict[str, Any]] = []
    for window_start, window_end in _master_windows(start_ms, end_ms):
        withdrawal_rows.extend(
            _offset_history_rows(
                client.get_withdraw_history,
                start_ms=window_start,
                end_ms=window_end,
                status=6,
            )
        )

    normalized: list[dict[str, Any]] = []
    for row in withdrawal_rows:
        if str(row.get("coin") or "").upper() != TRANSFER_HISTORY_ASSET:
            continue
        if str(row.get("status") or "") != "6" or not _is_spot_wallet(row):
            continue
        amount = _decimal_value(row.get("amount"))
        occurred_at = _to_local_datetime(row.get("completeTime") or row.get("applyTime"))
        if amount is None or not _in_requested_period(occurred_at, start_at, end_at):
            continue
        is_internal = str(row.get("transferType") or "0") == "1"
        is_collection = str(row.get("withdrawOrderId") or "").lower().startswith("tt")
        destination = "归集账户" if is_collection else ("币安账户" if is_internal else "外部账户")
        normalized.append(
            {
                "id": _record_id("withdrawal", row, "id", "txId"),
                "direction": "outgoing",
                "amount": _decimal_text(amount),
                "asset": TRANSFER_HISTORY_ASSET,
                "occurred_at": occurred_at.isoformat(),
                "route": f"现货 -> {destination}",
                "channel": "币安站内转账" if is_internal else f"{str(row.get('network') or '链上')}转出",
            }
        )
    return normalized


def _deduplicated(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_id: dict[str, dict[str, Any]] = {}
    for record in records:
        by_id.setdefault(record["id"], record)
    return sorted(by_id.values(), key=lambda row: (row["occurred_at"], row["id"]), reverse=True)


def _local_datetime(value: Optional[datetime]) -> datetime:
    result = value or datetime.now(tz=dt_timezone.utc)
    if result.tzinfo is None:
        result = result.replace(tzinfo=dt_timezone.utc)
    return result.astimezone(TRANSFER_HISTORY_ZONE)


def _current_fingerprint(user) -> str:
    fingerprint = get_user_api_key_fingerprint(user)
    if fingerprint:
        return fingerprint
    if not ApiBinding.objects.filter(user=user, trading_mode="ordinary").exists():
        raise BinanceApiError("请先绑定 Binance API")
    raise BinanceApiError("当前 Binance API 绑定无效，请重新绑定")


def _account_type_for_history(client: BinanceFuturesClient) -> str:
    return account_type_for_client(client)


def build_transfer_history(
    user,
    *,
    start_at: Optional[datetime] = None,
    now: Optional[datetime] = None,
    credentials=None,
) -> dict[str, Any]:
    credentials = credentials or get_user_binance_credentials(user)
    if not credentials:
        raise BinanceApiError("请先绑定 Binance API")

    client = BinanceFuturesClient(credentials)
    account_type = _account_type_for_history(client)
    if account_type not in {"master", "sub"}:
        raise BinanceApiError("无法确认当前 Binance 账户类型，请稍后重试")

    end_at = _local_datetime(now)
    requested_start = (
        max(_local_datetime(start_at), TRANSFER_HISTORY_START)
        if start_at
        else TRANSFER_HISTORY_START
    )
    start_ms = int(requested_start.timestamp() * 1000)
    end_ms = int(end_at.timestamp() * 1000)
    records: list[dict[str, Any]] = []
    if end_ms >= start_ms:
        records = _normalized_deposit_records(
            client,
            start_ms=start_ms,
            end_ms=end_ms,
            start_at=requested_start,
            end_at=end_at,
        )
        records += _normalized_pay_records(
            client,
            start_ms=start_ms,
            end_ms=end_ms,
            start_at=requested_start,
            end_at=end_at,
        )
        if account_type == "sub":
            records += _normalized_sub_records(
                client,
                start_ms=start_ms,
                end_ms=end_ms,
                start_at=requested_start,
                end_at=end_at,
            )
        else:
            records += _normalized_master_withdrawals(
                client,
                start_ms=start_ms,
                end_ms=end_ms,
                start_at=requested_start,
                end_at=end_at,
            )
    records = _deduplicated(records)

    outgoing_total = sum(
        (Decimal(row["amount"]) for row in records if row["direction"] == "outgoing"),
        Decimal("0"),
    )
    incoming_total = sum(
        (Decimal(row["amount"]) for row in records if row["direction"] == "incoming"),
        Decimal("0"),
    )
    return {
        "start_at": requested_start.isoformat(),
        "account_type": account_type,
        "outgoing_total": _decimal_text(outgoing_total),
        "incoming_total": _decimal_text(incoming_total),
        "net_amount": _decimal_text(outgoing_total - incoming_total),
        "records": records,
    }


def _sync_transfer_history_for_user(
    user,
    *,
    fingerprint: str,
    binding_created_at: datetime,
    credentials,
    now: Optional[datetime] = None,
) -> dict[str, Any]:
    end_at = _local_datetime(now)
    state, _ = TransferHistorySyncState.objects.get_or_create(
        user=user,
        api_key_fingerprint=fingerprint,
    )
    start_at = TRANSFER_HISTORY_START
    if state.synced_through and state.source_version >= TRANSFER_HISTORY_SOURCE_VERSION:
        start_at = max(
            TRANSFER_HISTORY_START,
            _local_datetime(state.synced_through) - TRANSFER_HISTORY_OVERLAP,
        )

    try:
        history = build_transfer_history(
            user,
            start_at=start_at,
            now=end_at,
            credentials=credentials,
        )
        with transaction.atomic():
            binding_is_current = ApiBinding.objects.select_for_update().filter(
                user=user,
                status=1,
                api_key_fingerprint=fingerprint,
                created_at=binding_created_at,
            ).exists()
            if not binding_is_current:
                raise BinanceApiError("API 绑定已发生变化，本次同步结果未写入")
            for row in history["records"]:
                occurred_at = _to_local_datetime(row["occurred_at"])
                if occurred_at is None:
                    raise ValueError(f"转账记录时间无效: {row['id']}")
                TransferHistoryRecord.objects.update_or_create(
                    user=user,
                    api_key_fingerprint=fingerprint,
                    record_id=row["id"],
                    defaults={
                        "account_type": history["account_type"],
                        "direction": row["direction"],
                        "amount": Decimal(row["amount"]),
                        "asset": row["asset"],
                        "occurred_at": occurred_at,
                        "route": row["route"],
                        "channel": row["channel"],
                    },
                )
            state.account_type = history["account_type"]
            state.synced_through = end_at
            state.last_synced_at = end_at
            state.last_error = ""
            state.source_version = TRANSFER_HISTORY_SOURCE_VERSION
            state.save(
                update_fields=[
                    "account_type",
                    "synced_through",
                    "last_synced_at",
                    "last_error",
                    "source_version",
                    "updated_at",
                ]
            )
    except Exception as exc:
        state.last_error = safe_error_summary(exc, include_type=False)
        state.save(update_fields=["last_error", "updated_at"])
        raise

    return {
        "account_type": history["account_type"],
        "stored_records": len(history["records"]),
        "synced_through": end_at.isoformat(),
    }


def sync_transfer_history_for_user(user, *, now: Optional[datetime] = None) -> dict[str, Any]:
    fingerprint, binding_created_at = get_user_binding_generation(user)
    if not fingerprint or binding_created_at is None:
        _current_fingerprint(user)
        raise BinanceApiError("当前 Binance API 绑定无效，请重新绑定")
    credentials = get_user_binance_credentials_for_generation(
        user,
        api_key_fingerprint=fingerprint,
        binding_created_at=binding_created_at,
    )
    if not credentials:
        raise BinanceApiError("API 绑定已发生变化，请重新同步")
    lock_key = f"transfer-history:sync:{user.pk}:{fingerprint[:16]}"
    with distributed_cache_lock(
        lock_key,
        timeout=TRANSFER_HISTORY_SYNC_LOCK_SECONDS,
    ) as locked:
        if not locked:
            raise BinanceApiError("转账历史正在同步，请稍后再试")
        return _sync_transfer_history_for_user(
            user,
            fingerprint=fingerprint,
            binding_created_at=binding_created_at,
            credentials=credentials,
            now=now,
        )


def sync_all_transfer_histories(*, now: Optional[datetime] = None) -> dict[str, int]:
    result = {"attempted": 0, "synced": 0, "failed": 0, "stored_records": 0}
    bindings = ApiBinding.objects.filter(status=1, trading_mode="ordinary").select_related("user").order_by("user_id")
    for binding in bindings.iterator():
        result["attempted"] += 1
        try:
            sync_result = sync_transfer_history_for_user(binding.user, now=now)
        except Exception as exc:
            result["failed"] += 1
            if is_binance_rate_limit_error(exc):
                logger.warning(
                    "transfer_history_sync_rate_limited user=%s error=%s",
                    binding.user_id,
                    safe_error_summary(exc),
                )
                break
            logger.error(
                "transfer_history_sync_failed user=%s error=%s",
                binding.user_id,
                safe_error_summary(exc),
            )
            continue
        result["synced"] += 1
        result["stored_records"] += sync_result["stored_records"]
    return result


def get_cached_transfer_history(
    user,
    *,
    page: int = 1,
    page_size: int = 20,
) -> dict[str, Any]:
    fingerprint = _current_fingerprint(user)
    state = TransferHistorySyncState.objects.filter(
        user=user,
        api_key_fingerprint=fingerprint,
    ).first()
    records_query = TransferHistoryRecord.objects.filter(
        user=user,
        api_key_fingerprint=fingerprint,
    )
    totals = records_query.aggregate(
        outgoing_total=Sum("amount", filter=Q(direction="outgoing")),
        incoming_total=Sum("amount", filter=Q(direction="incoming")),
    )
    outgoing_total = totals["outgoing_total"] or Decimal("0")
    incoming_total = totals["incoming_total"] or Decimal("0")
    total_records = records_query.count()
    total_pages = (total_records + page_size - 1) // page_size
    offset = (page - 1) * page_size
    records = list(
        records_query.order_by("-occurred_at", "record_id")[offset : offset + page_size]
    )
    account_type = state.account_type if state and state.account_type else "unknown"
    if account_type == "unknown":
        account_type = (
            records_query.order_by("-occurred_at", "record_id")
            .values_list("account_type", flat=True)
            .first()
            or "unknown"
        )

    if state and state.last_error:
        sync_status = "error"
    elif state and state.last_synced_at:
        sync_status = "ready"
    else:
        sync_status = "pending"

    return {
        "start_at": TRANSFER_HISTORY_START.isoformat(),
        "account_type": account_type,
        "outgoing_total": _compact_decimal_text(outgoing_total),
        "incoming_total": _compact_decimal_text(incoming_total),
        "net_amount": _compact_decimal_text(outgoing_total - incoming_total),
        "last_synced_at": state.last_synced_at.isoformat() if state and state.last_synced_at else None,
        "sync_status": sync_status,
        "pagination": {
            "page": page,
            "page_size": page_size,
            "total": total_records,
            "total_pages": total_pages,
            "has_next": page < total_pages,
        },
        "records": [
            {
                "id": record.record_id,
                "direction": record.direction,
                "amount": _compact_decimal_text(record.amount),
                "asset": record.asset,
                "occurred_at": record.occurred_at.isoformat(),
                "route": record.route,
                "channel": record.channel,
            }
            for record in records
        ],
    }
