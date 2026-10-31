"""Best-effort business logs and a read-only account activity feed."""

import hashlib
import logging
import re

from django.core import signing
from django.db import transaction
from django.db.models import Q
from django.utils.dateparse import parse_datetime
from django.utils.timezone import is_aware

from api_bindings.models import ApiBinding
from common.errors import safe_error_summary
from common.trading_mode import TradingMode, normalize_trading_mode
from positions.models import Order, OrderStrategyLog, TradeNotificationEvent, TradeOperationLog


logger = logging.getLogger(__name__)
_EMAIL = re.compile(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
_PRIVATE_FIELD = re.compile(
    r"(?i)(?:api[_ -]?key[_ -]?fingerprint|fingerprint|(?:source|destination|deposit|withdraw)?[_ -]?address|邮箱|地址)"
    r"[\"']?\s*[:=：]\s*[\"']?[^\s\"',;}\]]+"
)
_LONG_IDENTIFIER = re.compile(r"\b(?:0x[A-Fa-f0-9]{40,}|[A-Za-z0-9_-]{32,})\b")
_STATUSES = {"success", "pending", "failed", "info"}
_CLOSE_TYPES = (
    TradeNotificationEvent.TYPE_STOP_LOSS,
    TradeNotificationEvent.TYPE_STRATEGY_TAKE_PROFIT,
    TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT,
)


def safe_operation_message(value):
    if not value:
        return ""
    # Redact before applying the final display limit, including legacy rows.
    text = safe_error_summary(str(value), include_type=False, limit=max(500, len(str(value))))
    text = _EMAIL.sub("[已隐藏邮箱]", text)
    text = _PRIVATE_FIELD.sub("[已隐藏账户信息]", text)
    return _LONG_IDENTIFIER.sub("[已隐藏标识]", text)[:500]


def record_operation(order, *, action, status, message, actor="system", event_key=None, dedupe=True):
    """Record one transition without making a logging failure a trading failure."""
    try:
        if actor not in {"system", "user"} or status not in _STATUSES:
            raise ValueError("invalid operation log classification")
        if not re.fullmatch(r"[a-zA-Z0-9_.:-]{1,64}", str(action)):
            raise ValueError("invalid operation log action")
        message = safe_operation_message(message)
        key = None
        if event_key is not None:
            key = hashlib.sha256(f"{order.pk}:{action}:{actor}:{event_key}".encode()).hexdigest()
        # A savepoint is essential: catching a database error inside the caller's
        # transaction alone would leave that transaction unusable.
        with transaction.atomic():
            queryset = TradeOperationLog.objects.filter(order=order, action=action, actor=actor)
            if key:
                existing = queryset.filter(event_key=key).first()
                if existing:
                    return existing
            if dedupe:
                latest = queryset.order_by("-created_at", "-id").first()
                if latest and latest.status == status and latest.message == message:
                    return latest
            fields = dict(order=order, action=action, actor=actor, status=status, message=message)
            if key:
                return TradeOperationLog.objects.get_or_create(event_key=key, defaults=fields)[0]
            return TradeOperationLog.objects.create(**fields)
    except Exception as exc:  # Logging must never change the exchange outcome.
        logger.warning("operation log unavailable order=%s error_type=%s", getattr(order, "pk", None), type(exc).__name__)
        return None


def _cursor_position(cursor, salt):
    if not cursor:
        return None
    try:
        payload = signing.loads(cursor, salt=salt)
        at = parse_datetime(payload["t"])
        rank, row_id = payload["r"], payload["i"]
        if payload.get("v") != 1 or not at or not is_aware(at) or type(rank) is not int or rank not in {0, 1, 2} or type(row_id) is not int or row_id <= 0:
            raise ValueError
        return at, rank, row_id
    except (signing.BadSignature, TypeError, ValueError, KeyError, OverflowError) as exc:
        raise ValueError("日志分页游标无效，请刷新后重试") from exc


def _page(queryset, rank, cursor, limit):
    if cursor:
        at, cursor_rank, row_id = cursor
        before = Q(created_at__lt=at)
        if rank < cursor_rank:
            before |= Q(created_at=at)
        elif rank == cursor_rank:
            before |= Q(created_at=at, pk__lt=row_id)
        queryset = queryset.filter(before)
    return queryset.select_related("order").order_by("-created_at", "-id")[:limit + 1]


def _serialize(row, rank):
    order = row.order
    if rank == 2:
        source, action, status, message = row.actor, row.action, row.status, row.message
        kind = "operation"
    elif rank == 1:
        source, action, kind = "strategy", "strategy_event", "strategy"
        status = {OrderStrategyLog.RESULT_SUCCESS: "success", OrderStrategyLog.RESULT_FAILED: "failed"}.get(row.result, "info")
        message = row.behavior_desc
        if row.error:
            message += f"：{row.error}"
    else:
        source, action, status, kind = "trade", row.event_type, "success", "trade"
        message = {
            TradeNotificationEvent.TYPE_OPEN: "开仓成交已确认",
            TradeNotificationEvent.TYPE_REDUCTION: "仓位减少已确认",
            TradeNotificationEvent.TYPE_STOP_LOSS: "止损平仓已确认",
            TradeNotificationEvent.TYPE_STRATEGY_TAKE_PROFIT: "策略止盈平仓已确认",
            TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT: "手动平仓已确认",
        }[row.event_type]
        if row.event_type in _CLOSE_TYPES:
            try:
                confidence = int((row.context or {}).get("classification_confidence", 0))
            except (TypeError, ValueError, AttributeError):
                confidence = 0
            if confidence < 3:
                action, message = "close_confirmed", "平仓已确认，具体触发来源待核实"
    return {
        "id": f"{kind}:{row.pk}",
        "occurred_at": row.created_at.isoformat(),
        "order_id": order.pk,
        "symbol": order.symbol,
        "side": "long" if order.side == 0 else "short",
        "position_origin": order.position_origin,
        "source": source,
        "action": action,
        "status": status,
        "message": safe_operation_message(message),
    }


def get_operation_logs(user, *, trading_mode=TradingMode.ORDINARY, cursor="", limit=20):
    """Merge bounded source pages; never query Binance or mutate legacy records."""
    mode = normalize_trading_mode(trading_mode)
    if not 1 <= limit <= 50 or len(cursor) > 1000:
        raise ValueError("日志分页参数无效")
    fingerprint = ApiBinding.objects.filter(user=user, trading_mode=mode).values_list("api_key_fingerprint", flat=True).first()
    if not fingerprint:
        return {"records": [], "next_cursor": None, "has_more": False}
    salt = f"trade-operation-feed:{user.pk}:{mode}:{fingerprint}"
    position = _cursor_position(cursor, salt)
    orders = Order.objects.filter(user=user, trading_mode=mode, api_key_fingerprint=fingerprint)
    # The lifecycle service writes this terminal state only after confirmation.
    # Two confirmed empty-position snapshots need not include a close order ID.
    confirmed_close = Q(order__status=1, order__closed_at__isnull=False)
    trade_events = TradeNotificationEvent.objects.filter(order__in=orders).filter(
        Q(event_type=TradeNotificationEvent.TYPE_OPEN, order__size__gt=0, order__open_price__gt=0, order__binance_order_id__isnull=False) & ~Q(order__binance_order_id="")
        | Q(event_type=TradeNotificationEvent.TYPE_REDUCTION)
        | Q(event_type__in=_CLOSE_TYPES) & confirmed_close
    )
    sources = [
        (2, TradeOperationLog.objects.filter(order__in=orders)),
        (1, OrderStrategyLog.objects.filter(order__in=orders)),
        (0, trade_events),
    ]
    rows = [(row.created_at, rank, row.pk, row) for rank, queryset in sources for row in _page(queryset, rank, position, limit)]
    rows.sort(key=lambda entry: entry[:3], reverse=True)
    selected, has_more = rows[:limit], len(rows) > limit
    next_cursor = None
    if has_more:
        at, rank, row_id, _row = selected[-1]
        next_cursor = signing.dumps({"v": 1, "t": at.isoformat(), "r": rank, "i": row_id}, salt=salt)
    return {"records": [_serialize(row, rank) for _at, rank, _id, row in selected], "next_cursor": next_cursor, "has_more": has_more}
