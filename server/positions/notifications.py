from __future__ import annotations

import html
import json
import logging
from datetime import timedelta
from decimal import Decimal, ROUND_HALF_UP
from typing import Any, Optional
from urllib import request
from urllib.parse import urlsplit

from django.conf import settings
from django.db import connection, transaction
from django.db.models import Q
from django.utils import timezone

from common.binance import is_binance_rate_limit_error
from common.errors import safe_error_summary
from common.ops_alerts import send_ops_alert_once
from positions.models import Order, TradeNotificationEvent


logger = logging.getLogger(__name__)

_TITLE_PARTS_BY_TYPE = {
    TradeNotificationEvent.TYPE_OPEN: ("🚀", "开仓"),
    TradeNotificationEvent.TYPE_STOP_LOSS: ("🛑", "止损"),
    TradeNotificationEvent.TYPE_STRATEGY_TAKE_PROFIT: ("🎯", "止盈"),
    TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT: ("✋", "手动止盈"),
    TradeNotificationEvent.TYPE_REDUCTION: ("📉", "减仓"),
}
_CLOSE_EVENT_TYPES = {
    TradeNotificationEvent.TYPE_STOP_LOSS,
    TradeNotificationEvent.TYPE_STRATEGY_TAKE_PROFIT,
    TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT,
}
_CLOSE_CLASSIFICATION_FALLBACK = 1
_CLOSE_CLASSIFICATION_PRICE = 2
_CLOSE_CLASSIFICATION_EXCHANGE = 3
_CLOSE_CLASSIFICATION_EXPLICIT = 4
_TERMINAL_ALGO_STATES = {"filled", "finished", "triggered"}
_TERMINAL_SETTLEMENT_STATUSES = {
    Order.SETTLEMENT_STATUS_SETTLED,
    Order.SETTLEMENT_STATUS_ESTIMATED,
}
DELIVERY_LEASE_SECONDS = 60
DELIVERY_MAX_ATTEMPTS = 8


def _decimal(value: Any) -> Decimal:
    try:
        return Decimal(str(value or "0"))
    except Exception:
        return Decimal("0")


def _number(value: Any) -> str:
    if value in (None, ""):
        return "-"
    number = _decimal(value)
    text = format(number, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text or "0"


def _text(value: Any, *, limit: int = 240) -> str:
    raw = " ".join(str(value if value not in (None, "") else "-").split())
    raw = raw.replace("`", "'")
    return html.escape(raw[:limit], quote=False)


def _local_time(value=None) -> str:
    target = value or timezone.now()
    if timezone.is_naive(target):
        target = timezone.make_aware(target, timezone.get_current_timezone())
    return timezone.localtime(target).strftime("%Y-%m-%d %H:%M:%S")


def _order_direction(order: Order) -> str:
    return "多单" if order.side == 0 else "空单"


def _risk_reward_ratio(order: Order) -> str:
    risk_amount = _decimal(order.stop_loss_amount)
    pnl = order.pnl if order.pnl is not None else order.realized_pnl
    if risk_amount <= 0 or pnl is None:
        return "-"
    ratio = (_decimal(pnl) / risk_amount).quantize(Decimal("0.1"), rounding=ROUND_HALF_UP)
    return f"{format(ratio, '.1f')}:1"


def _trade_notification_title(
    event_type: str,
    fields: list[tuple[str, Any]],
    *,
    template_test: bool = False,
) -> str:
    values = {str(label): value for label, value in fields}
    symbol = _text(values.get("币种"), limit=32)
    direction = _text(values.get("订单方向"), limit=16)
    icon, action = _TITLE_PARTS_BY_TYPE[event_type]
    test_marker = "【模板测试】" if template_test else ""
    mode_marker = "【带单】" if values.get("交易账户") == "带单组合" else ""
    return f"{icon} {test_marker}{mode_marker}{symbol} {direction} {action}"


def _account_notification_fields(order: Order, fields: list[tuple[str, Any]]) -> list[tuple[str, Any]]:
    return [("交易账户", "带单组合"), *fields] if order.trading_mode == "lead" else fields


def build_trade_notification(
    event_type: str,
    fields: list[tuple[str, Any]],
    *,
    template_test: bool = False,
) -> tuple[str, str]:
    title = _trade_notification_title(event_type, fields, template_test=template_test)
    if template_test:
        fields = [("测试说明", "仅验证通知样式，不对应真实交易"), *fields]
    content = "\n".join(f"> **{_text(label, limit=40)}**：{_text(value)}" for label, value in fields)
    return title, content


def trade_notification_template_samples() -> list[tuple[str, list[tuple[str, str]]]]:
    return [
        (
            TradeNotificationEvent.TYPE_OPEN,
            [
                ("币种", "BTCUSDT"),
                ("订单方向", "多单"),
                ("止损价", "108000"),
                ("成交价", "110000"),
                ("订单编号", "1001"),
                ("成交时间", "2026-09-04 12:00:00"),
            ],
        ),
        (
            TradeNotificationEvent.TYPE_STOP_LOSS,
            [
                ("币种", "BTCUSDT"),
                ("订单方向", "多单"),
                ("开仓价", "110000"),
                ("止损价", "108000"),
                ("止损时间", "2026-09-04 12:30:00"),
                ("止损盈亏比", "-1.1:1"),
            ],
        ),
        (
            TradeNotificationEvent.TYPE_STRATEGY_TAKE_PROFIT,
            [
                ("币种", "BTCUSDT"),
                ("订单方向", "多单"),
                ("止盈价", "116020"),
                ("止盈盈亏比", "0.9:1"),
                ("止盈时间", "2026-09-04 14:00:00"),
            ],
        ),
        (
            TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT,
            [
                ("币种", "BTCUSDT"),
                ("订单方向", "空单"),
                ("止盈价", "106500"),
                ("止盈盈亏比", "0.7:1"),
                ("止盈时间", "2026-09-04 15:00:00"),
            ],
        ),
        (
            TradeNotificationEvent.TYPE_REDUCTION,
            [
                ("币种", "BTCUSDT"),
                ("订单方向", "多单"),
                ("减仓百分比", "30%"),
                ("减仓价格", "112000"),
                ("减仓时间", "2026-09-04 13:00:00"),
                ("减仓类型", "浮盈减仓"),
            ],
        ),
    ]


def build_trade_notification_payload(
    *,
    event_id: str,
    event_type: str,
    title: str,
    content: str,
    occurred_at,
) -> dict[str, Any]:
    if event_type not in _TITLE_PARTS_BY_TYPE:
        raise ValueError("trade notification event type is invalid")
    target = occurred_at or timezone.now()
    if timezone.is_naive(target):
        target = timezone.make_aware(target, timezone.get_current_timezone())
    return {
        "schemaVersion": 1,
        "eventId": str(event_id),
        "type": event_type.upper(),
        "title": str(title),
        "content": str(content),
        "occurredAt": timezone.localtime(target).isoformat(timespec="seconds"),
    }


def trade_notification_payload(event: TradeNotificationEvent) -> dict[str, Any]:
    return build_trade_notification_payload(
        event_id=event.event_key,
        event_type=event.event_type,
        title=event.title,
        content=event.content,
        occurred_at=event.created_at,
    )


def send_trade_notification(payload: dict[str, Any]) -> dict[str, Any]:
    url = str(getattr(settings, "TRADE_NOTIFICATION_URL", "") or "").strip()
    token = str(getattr(settings, "TRADE_NOTIFICATION_TOKEN", "") or "").strip()
    if not url or not token:
        raise RuntimeError("trade notification channel is not configured")
    parsed = urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
        raise RuntimeError("trade notification URL is invalid")
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
    req = request.Request(
        url=url,
        data=body,
        headers={"Content-Type": "application/json", "X-API-Key": token},
        method="POST",
    )
    timeout = max(1.0, float(getattr(settings, "TRADE_NOTIFICATION_TIMEOUT_SECONDS", 5)))
    with request.urlopen(req, timeout=timeout) as response:
        result = json.loads(response.read(64 * 1024).decode("utf-8") or "{}")
    if not isinstance(result, dict) or not result.get("ok"):
        raise RuntimeError("trade notification endpoint rejected the message")
    return result


def _create_notification(
    *,
    event_key: str,
    order: Order,
    event_type: str,
    title: str,
    content: str,
    context: Optional[dict[str, Any]] = None,
    raise_on_error: bool = False,
) -> Optional[TradeNotificationEvent]:
    event_context = dict(context or {})
    if bool(getattr(settings, "EXTERNAL_TRADE_SIGNAL_ENABLED", False)):
        # Persist channel intent on the source event so the external dispatcher
        # can repair a delivery row that failed to be created transiently.
        event_context["external_delivery_required"] = True
    try:
        event, created = TradeNotificationEvent.objects.get_or_create(
            event_key=event_key[:191],
            defaults={
                "order": order,
                "event_type": event_type,
                "title": title,
                "content": content,
                "context": event_context,
            },
        )
        if not created and event_context.get("external_delivery_required"):
            existing_context = dict(event.context or {})
            if not existing_context.get("external_delivery_required"):
                existing_context["external_delivery_required"] = True
                event.context = existing_context
                event.save(update_fields=["context", "updated_at"])
    except Exception as exc:  # noqa: BLE001
        error_summary = safe_error_summary(exc)
        logger.error(
            "trade notification enqueue failed order=%s event_type=%s err=%s",
            order.id,
            event_type,
            error_summary,
        )
        if raise_on_error:
            raise
        return None
    try:
        from positions.external_trade_signals import enqueue_external_trade_signal

        enqueue_external_trade_signal(event)
    except Exception as exc:  # noqa: BLE001
        error_summary = safe_error_summary(exc)
        logger.error(
            "external trade signal enqueue failed event=%s type=%s err=%s",
            event.id,
            event.event_type,
            error_summary,
        )
    return event


def enqueue_trade_notification(
    *,
    event_key: str,
    order: Order,
    event_type: str,
    fields: list[tuple[str, Any]],
    persist_now: bool = False,
) -> Optional[TradeNotificationEvent]:
    title, content = build_trade_notification(event_type, _account_notification_fields(order, fields))
    kwargs = {
        "event_key": event_key,
        "order": order,
        "event_type": event_type,
        "title": title,
        "content": content,
    }
    if persist_now:
        return _create_notification(**kwargs, raise_on_error=True)
    if connection.in_atomic_block:
        transaction.on_commit(lambda: _create_notification(**kwargs))
        return None
    return _create_notification(**kwargs)


def enqueue_open_notification(order: Order) -> Optional[TradeNotificationEvent]:
    fields = [
        ("币种", order.symbol),
        ("订单方向", _order_direction(order)),
        ("止损价", _number(order.current_stop_price or order.stop_loss_price)),
        ("成交价", _number(order.open_price)),
    ]
    if order.id:
        fields.append(("订单编号", order.id))
    fields.append(("成交时间", _local_time(order.created_at)))
    return enqueue_trade_notification(
        event_key=f"trade:open:{order.id}:{order.binance_order_id}",
        order=order,
        event_type=TradeNotificationEvent.TYPE_OPEN,
        fields=fields,
    )


def enqueue_reduction_notification(
    order: Order,
    *,
    previous_size: Decimal,
    remaining_size: Decimal,
    execution_price: Optional[Decimal] = None,
    persist_now: bool = False,
) -> Optional[TradeNotificationEvent]:
    reduced_size = max(previous_size - remaining_size, Decimal("0"))
    if reduced_size <= 0:
        return None
    price = execution_price or Decimal("0")
    estimated_pnl = Decimal("0")
    if price > 0 and order.open_price:
        estimated_pnl = (price - order.open_price) * reduced_size
        if order.side == 1:
            estimated_pnl = -estimated_pnl
    reduce_ratio = (reduced_size / order.size * Decimal("100")) if order.size else Decimal("0")
    fields = [
        ("币种", order.symbol),
        ("订单方向", _order_direction(order)),
        ("减仓百分比", f"{_number(reduce_ratio)}%"),
        ("减仓价格", _number(price) if price > 0 else "待确认"),
        ("减仓时间", _local_time()),
        ("减仓类型", "浮盈减仓" if estimated_pnl > 0 else "浮亏减仓"),
    ]
    transition = f"{_number(previous_size)}:{_number(remaining_size)}:{timezone.now().strftime('%Y%m%d%H%M')}"
    return enqueue_trade_notification(
        event_key=f"trade:reduction:{order.id}:{transition}",
        order=order,
        event_type=TradeNotificationEvent.TYPE_REDUCTION,
        fields=fields,
        persist_now=persist_now,
    )


def _existing_close_notification(
    order: Order,
    *,
    for_update: bool = False,
) -> Optional[TradeNotificationEvent]:
    try:
        queryset = TradeNotificationEvent.objects.filter(
            order=order,
            event_type__in=_CLOSE_EVENT_TYPES,
        ).order_by("created_at", "id")
        if for_update:
            queryset = queryset.select_for_update()
        return queryset.first()
    except Exception as exc:  # noqa: BLE001
        if for_update:
            raise
        logger.error(
            "trade notification lookup failed order=%s err=%s",
            order.id,
            safe_error_summary(exc),
        )
        return None


def _close_classification_confidence(event: TradeNotificationEvent) -> int:
    try:
        return int((event.context or {}).get("classification_confidence"))
    except (TypeError, ValueError):
        # Events written before confidence metadata existed must stay immutable.
        return _CLOSE_CLASSIFICATION_EXPLICIT


def _algo_row(client, algo_id: str) -> Optional[dict[str, Any]]:
    if not algo_id:
        return None
    try:
        payload = client.get_pending_algo_orders(
            ord_type="conditional",
            inst_type="SWAP",
            algo_id=str(algo_id),
        )
    except Exception as exc:
        if is_binance_rate_limit_error(exc):
            raise
        return None
    if not isinstance(payload, dict):
        return None
    rows = payload.get("data") or []
    if not isinstance(rows, list):
        return None
    return next((row for row in rows if isinstance(row, dict)), None)


def infer_exchange_close_notification(
    order: Order,
    client,
    *,
    close_price: Decimal,
    close_order_id: str = "",
) -> dict[str, Any]:
    existing = _existing_close_notification(order)
    if existing and (
        existing.content
        or existing.status != TradeNotificationEvent.STATUS_PENDING
        or _close_classification_confidence(existing) >= _CLOSE_CLASSIFICATION_EXCHANGE
    ):
        return {
            "event_type": existing.event_type,
            "trigger_price": _decimal((existing.context or {}).get("trigger_price")),
            "classification_confidence": _close_classification_confidence(existing),
        }

    candidates: list[tuple[str, str]] = []
    manual_algo_id = str(order.manual_take_profit_algo_id or "").strip()
    if manual_algo_id:
        candidates.append((TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT, manual_algo_id))
    for algo_id in (order.binance_stop_market_order_id, order.binance_stop_order_id):
        if algo_id:
            candidates.append((TradeNotificationEvent.TYPE_STOP_LOSS, str(algo_id)))
    for algo_id in order.strategy_tp_algo_ids or []:
        if algo_id:
            candidates.append((TradeNotificationEvent.TYPE_STRATEGY_TAKE_PROFIT, str(algo_id)))

    loaded: list[tuple[str, str, dict[str, Any]]] = []
    for reason, algo_id in candidates:
        try:
            row = _algo_row(client, algo_id)
        except Exception as exc:  # noqa: BLE001
            if is_binance_rate_limit_error(exc):
                break
            continue
        if row:
            loaded.append((reason, algo_id, row))

    target_order_id = str(close_order_id or "").strip()
    if target_order_id:
        for event_type, _algo_id, row in loaded:
            actual_order_id = str(row.get("actualOrderId") or row.get("ordId") or "").strip()
            if actual_order_id and actual_order_id == target_order_id:
                trigger_price = (
                    row.get("slTriggerPx")
                    if event_type == TradeNotificationEvent.TYPE_STOP_LOSS
                    else row.get("tpTriggerPx")
                )
                return {
                    "event_type": event_type,
                    "trigger_price": _decimal(trigger_price),
                    "classification_confidence": _CLOSE_CLASSIFICATION_EXCHANGE,
                }

    for event_type, _algo_id, row in loaded:
        state = str(row.get("state") or "").lower()
        if state in _TERMINAL_ALGO_STATES:
            trigger_price = (
                row.get("slTriggerPx")
                if event_type == TradeNotificationEvent.TYPE_STOP_LOSS
                else row.get("tpTriggerPx")
            )
            return {
                "event_type": event_type,
                "trigger_price": _decimal(trigger_price),
                "classification_confidence": _CLOSE_CLASSIFICATION_EXCHANGE,
            }

    stop_price = _decimal(order.current_stop_price or order.stop_loss_price)
    if stop_price > 0 and close_price > 0:
        stop_hit = close_price <= stop_price * Decimal("1.002") if order.side == 0 else close_price >= stop_price * Decimal("0.998")
        if stop_hit:
            return {
                "event_type": TradeNotificationEvent.TYPE_STOP_LOSS,
                "trigger_price": stop_price,
                "classification_confidence": _CLOSE_CLASSIFICATION_PRICE,
            }

    manual_price = _decimal(order.manual_take_profit_price)
    if manual_algo_id and manual_price > 0 and close_price > 0:
        target_hit = close_price >= manual_price * Decimal("0.998") if order.side == 0 else close_price <= manual_price * Decimal("1.002")
        if target_hit:
            return {
                "event_type": TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT,
                "trigger_price": manual_price,
                "classification_confidence": _CLOSE_CLASSIFICATION_PRICE,
            }

    if order.strategy_tp_algo_ids and close_price > 0:
        profitable = close_price > order.open_price if order.side == 0 else close_price < order.open_price
        if profitable:
            return {
                "event_type": TradeNotificationEvent.TYPE_STRATEGY_TAKE_PROFIT,
                "trigger_price": close_price,
                "classification_confidence": _CLOSE_CLASSIFICATION_PRICE,
            }

    return {
        "event_type": TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT,
        "trigger_price": close_price if close_price > 0 else None,
        "classification_confidence": _CLOSE_CLASSIFICATION_FALLBACK,
    }


def _create_close_notification(
    *,
    order: Order,
    event_type: str,
    trigger_price: Optional[Decimal],
    classification_confidence: int = _CLOSE_CLASSIFICATION_EXPLICIT,
    raise_on_error: bool = False,
) -> Optional[TradeNotificationEvent]:
    context = {
        "trigger_price": _number(trigger_price) if trigger_price is not None else "",
        "classification_confidence": classification_confidence,
    }
    if bool(getattr(settings, "EXTERNAL_TRADE_SIGNAL_ENABLED", False)):
        context["external_delivery_required"] = True
    try:
        with transaction.atomic():
            existing = _existing_close_notification(order, for_update=True)
            if existing is None:
                existing, _created = (
                    TradeNotificationEvent.objects.select_for_update().get_or_create(
                        event_key=f"trade:close:{order.id}",
                        defaults={
                            "order": order,
                            "event_type": event_type,
                            "title": _trade_notification_title(
                                event_type,
                                _account_notification_fields(order, [("币种", order.symbol), ("订单方向", _order_direction(order))]),
                            ),
                            "content": "",
                            "context": context,
                        },
                    )
                )

            existing_context = dict(existing.context or {})
            existing_confidence = _close_classification_confidence(existing)
            classification_mutable = (
                existing.status == TradeNotificationEvent.STATUS_PENDING
                and not existing.content
            )
            can_upgrade = (
                classification_mutable
                and classification_confidence > existing_confidence
            )
            update_fields = []
            if can_upgrade:
                existing.event_type = event_type
                existing.title = _trade_notification_title(
                    event_type,
                    _account_notification_fields(order, [("币种", order.symbol), ("订单方向", _order_direction(order))]),
                )
                existing_context["classification_confidence"] = classification_confidence
                existing_context["trigger_price"] = context["trigger_price"]
                update_fields.extend(["event_type", "title"])
            elif (
                classification_mutable
                and context["trigger_price"]
                and not existing_context.get("trigger_price")
            ):
                existing_context["trigger_price"] = context["trigger_price"]
            if (
                context.get("external_delivery_required")
                and not existing_context.get("external_delivery_required")
            ):
                existing_context["external_delivery_required"] = True
            if existing_context != (existing.context or {}):
                existing.context = existing_context
                update_fields.append("context")
            if update_fields:
                existing.save(update_fields=[*update_fields, "updated_at"])
    except Exception as exc:  # noqa: BLE001
        error_summary = safe_error_summary(exc)
        logger.error(
            "close notification enqueue failed order=%s event_type=%s err=%s",
            order.id,
            event_type,
            error_summary,
        )
        if raise_on_error:
            raise
        return None

    try:
        from positions.external_trade_signals import enqueue_external_trade_signal

        enqueue_external_trade_signal(existing)
    except Exception as exc:  # noqa: BLE001
        logger.error(
            "external close signal enqueue failed event=%s err=%s",
            existing.id,
            safe_error_summary(exc),
        )
    return existing


def enqueue_close_notification(
    order: Order,
    *,
    event_type: str,
    trigger_price: Optional[Decimal] = None,
    classification_confidence: int = _CLOSE_CLASSIFICATION_EXPLICIT,
    persist_now: bool = False,
) -> Optional[TradeNotificationEvent]:
    kwargs = {
        "order": order,
        "event_type": event_type,
        "trigger_price": trigger_price,
        "classification_confidence": classification_confidence,
    }
    if persist_now:
        return _create_close_notification(**kwargs, raise_on_error=True)
    if connection.in_atomic_block:
        transaction.on_commit(lambda: _create_close_notification(**kwargs))
        return None
    return _create_close_notification(**kwargs)


def enqueue_stop_loss_notification(
    order: Order,
    *,
    trigger_price: Optional[Decimal] = None,
    persist_now: bool = False,
) -> Optional[TradeNotificationEvent]:
    return enqueue_close_notification(
        order,
        event_type=TradeNotificationEvent.TYPE_STOP_LOSS,
        trigger_price=trigger_price,
        persist_now=persist_now,
    )


def enqueue_manual_take_profit_notification(
    order: Order,
    *,
    trigger_price: Optional[Decimal] = None,
    persist_now: bool = False,
) -> Optional[TradeNotificationEvent]:
    return enqueue_close_notification(
        order,
        event_type=TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT,
        trigger_price=trigger_price,
        persist_now=persist_now,
    )


def _render_close_notification(event: TradeNotificationEvent) -> bool:
    order = event.order
    if not order or order.status != 1 or order.settlement_status not in _TERMINAL_SETTLEMENT_STATUSES:
        return False

    closed_at = order.closed_at or order.settled_at
    trigger_price = _decimal((event.context or {}).get("trigger_price"))
    if event.event_type == TradeNotificationEvent.TYPE_STOP_LOSS:
        fields = [
            ("币种", order.symbol),
            ("订单方向", _order_direction(order)),
            ("开仓价", _number(order.open_price)),
            (
                "止损价",
                _number(trigger_price or order.current_stop_price or order.stop_loss_price),
            ),
            ("止损时间", _local_time(closed_at)),
            ("止损盈亏比", _risk_reward_ratio(order)),
        ]
    elif event.event_type == TradeNotificationEvent.TYPE_STRATEGY_TAKE_PROFIT:
        fields = [
            ("币种", order.symbol),
            ("订单方向", _order_direction(order)),
            ("止盈价", _number(order.close_price or trigger_price)),
            ("止盈盈亏比", _risk_reward_ratio(order)),
            ("止盈时间", _local_time(closed_at)),
        ]
    else:
        fields = [
            ("币种", order.symbol),
            ("订单方向", _order_direction(order)),
            ("止盈价", _number(order.close_price or trigger_price)),
            ("止盈盈亏比", _risk_reward_ratio(order)),
            ("止盈时间", _local_time(closed_at)),
        ]
    if order.settlement_status == Order.SETTLEMENT_STATUS_ESTIMATED:
        fields.append(("数据状态", "估算"))
    event.title, event.content = build_trade_notification(event.event_type, _account_notification_fields(order, fields))
    event.save(update_fields=["title", "content", "updated_at"])
    return True


def prepare_trade_notification(event: TradeNotificationEvent) -> bool:
    if event.event_type in _CLOSE_EVENT_TYPES and not event.content:
        return _render_close_notification(event)
    return bool(event.title and event.content)


def _claim_trade_notification(event_id: int, *, now) -> Optional[tuple[dict[str, Any], int, str]]:
    with transaction.atomic():
        event = (
            TradeNotificationEvent.objects.select_for_update()
            .select_related("order")
            .filter(id=event_id)
            .first()
        )
        if not event:
            return None
        retry_due = (
            event.status in {TradeNotificationEvent.STATUS_PENDING, TradeNotificationEvent.STATUS_FAILED}
            and (event.next_retry_at is None or event.next_retry_at <= now)
        )
        lease_expired = (
            event.status == TradeNotificationEvent.STATUS_SENDING
            and event.lease_expires_at is not None
            and event.lease_expires_at <= now
        )
        if not retry_due and not lease_expired:
            return None
        if not prepare_trade_notification(event):
            return None
        event.attempt_count += 1
        event.status = TradeNotificationEvent.STATUS_SENDING
        event.lease_expires_at = now + timedelta(seconds=DELIVERY_LEASE_SECONDS)
        event.next_retry_at = None
        event.save(
            update_fields=["attempt_count", "status", "lease_expires_at", "next_retry_at", "updated_at"]
        )
        return trade_notification_payload(event), event.attempt_count, event.event_type


def _record_trade_notification_result(
    event_id: int,
    *,
    attempt_count: int,
    error: Optional[Exception] = None,
) -> tuple[bool, bool]:
    now = timezone.now()
    selector = TradeNotificationEvent.objects.filter(
        id=event_id,
        status=TradeNotificationEvent.STATUS_SENDING,
        attempt_count=attempt_count,
    )
    if error is None:
        updated = selector.update(
            status=TradeNotificationEvent.STATUS_SENT,
            sent_at=now,
            next_retry_at=None,
            lease_expires_at=None,
            last_error="",
            updated_at=now,
        )
        return bool(updated), False

    exhausted = attempt_count >= DELIVERY_MAX_ATTEMPTS
    retry_seconds = min(3600, 15 * (2 ** min(attempt_count - 1, 8)))
    updated = selector.update(
        status=(
            TradeNotificationEvent.STATUS_EXHAUSTED
            if exhausted
            else TradeNotificationEvent.STATUS_FAILED
        ),
        next_retry_at=None if exhausted else now + timedelta(seconds=retry_seconds),
        lease_expires_at=None,
        last_error=safe_error_summary(error),
        updated_at=now,
    )
    return False, bool(updated and exhausted)


def dispatch_pending_trade_notifications(limit: int = 20) -> int:
    now = timezone.now()
    claimable = (
        Q(
            status__in=[TradeNotificationEvent.STATUS_PENDING, TradeNotificationEvent.STATUS_FAILED],
        )
        & (Q(next_retry_at__isnull=True) | Q(next_retry_at__lte=now))
    ) | Q(
        status=TradeNotificationEvent.STATUS_SENDING,
        lease_expires_at__lte=now,
    )
    event_ids = list(
        TradeNotificationEvent.objects.filter(claimable)
        .filter(
            ~Q(event_type__in=_CLOSE_EVENT_TYPES)
            | ~Q(content="")
            | Q(
                order__status=1,
                order__settlement_status__in=_TERMINAL_SETTLEMENT_STATUSES,
            )
        )
        .order_by("created_at", "id")
        .values_list("id", flat=True)[: max(1, int(limit))]
    )
    sent = 0
    for event_id in event_ids:
        claimed = _claim_trade_notification(event_id, now=now)
        if not claimed:
            continue
        payload, attempt_count, event_type = claimed
        try:
            send_trade_notification(payload)
        except Exception as exc:  # noqa: BLE001
            error_summary = safe_error_summary(exc)
            _, exhausted = _record_trade_notification_result(
                event_id,
                attempt_count=attempt_count,
                error=exc,
            )
            log = logger.critical if exhausted else logger.warning
            log(
                "trade notification send failed event=%s type=%s attempt=%s exhausted=%s err=%s",
                event_id,
                event_type,
                attempt_count,
                int(exhausted),
                error_summary,
            )
            if exhausted:
                send_ops_alert_once(
                    key=f"trade-notification-exhausted:{event_id}",
                    title="交易通知投递耗尽",
                    text=f"事件 {event_id}（{event_type}）连续 {attempt_count} 次发送失败：{error_summary}",
                )
            continue
        delivered, _ = _record_trade_notification_result(event_id, attempt_count=attempt_count)
        if delivered:
            sent += 1
    return sent
