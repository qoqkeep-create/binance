import json
from datetime import timedelta
from decimal import Decimal
from io import StringIO
from unittest.mock import MagicMock, patch

from django.core.management import call_command
from django.core.management.base import CommandError
from django.db import IntegrityError, connection, transaction
from django.test import SimpleTestCase, TransactionTestCase, override_settings
from django.utils import timezone

from positions.external_trade_signals import (
    dispatch_pending_external_trade_signals,
    send_external_trade_signal,
)
from positions.models import ExternalTradeSignalDelivery, LimitOrder, Order, TradeNotificationEvent
from common.binance import BinanceApiError
from positions.notifications import (
    build_trade_notification,
    dispatch_pending_trade_notifications,
    enqueue_close_notification,
    enqueue_open_notification,
    infer_exchange_close_notification,
    send_trade_notification,
)
from trading.services import _sync_order_exchange_size
from users.models import User


@override_settings(APNS_ENABLED=True)
class TradeNotificationTemplateTests(SimpleTestCase):
    @override_settings(TRADE_NOTIFICATION_ENABLED=False, EXTERNAL_TRADE_SIGNAL_ENABLED=True)
    @patch("positions.notifications.send_trade_notification")
    @patch("positions.external_trade_signals.send_external_trade_signal")
    def test_disabled_trade_notifications_skip_both_queues(self, external, internal):
        self.assertEqual(dispatch_pending_trade_notifications(), 0)
        self.assertEqual(dispatch_pending_external_trade_signals(), 0)
        internal.assert_not_called()
        external.assert_not_called()

    @override_settings(
        TRADE_NOTIFICATION_ENABLED=False,
        TRADE_NOTIFICATION_URL="https://notify.example.invalid/trade",
        TRADE_NOTIFICATION_TOKEN="test-token",
        EXTERNAL_TRADE_SIGNAL_URL="https://notify.example.invalid/external",
        EXTERNAL_TRADE_SIGNAL_API_KEY="test-key",
    )
    @patch("urllib.request.urlopen")
    @patch("positions.external_trade_signals.request.build_opener")
    def test_disabled_trade_notifications_also_block_direct_senders(self, opener, urlopen):
        for sender in [send_trade_notification, send_external_trade_signal]:
            with self.subTest(sender=sender.__name__), self.assertRaisesRegex(RuntimeError, "disabled"):
                sender({"type": "OPEN"})
        urlopen.assert_not_called()
        opener.assert_not_called()

    @staticmethod
    def _labels(content):
        return [line.removeprefix("> **").split("**：", 1)[0] for line in content.splitlines()]

    def test_template_test_is_marked_and_untrusted_values_are_single_line(self):
        title, content = build_trade_notification(
            TradeNotificationEvent.TYPE_OPEN,
            [
                ("币种", "BTCUSDT"),
                ("订单方向", "多单"),
                ("策略", "test\n<@all>`code`"),
            ],
            template_test=True,
        )

        self.assertEqual(title, "🚀 【模板测试】BTCUSDT 多单 开仓")
        self.assertIn("仅验证通知样式", content)
        self.assertNotIn("\n&lt;@all", content)
        self.assertNotIn("<@all>", content)
        self.assertNotIn("`", content)

    @override_settings(
        TRADE_NOTIFICATION_URL="http://tradingview-webhook:3000/internal/trade-notification",
        TRADE_NOTIFICATION_TOKEN="header-only-token",
        TRADE_NOTIFICATION_TIMEOUT_SECONDS=5,
    )
    @patch("urllib.request.urlopen")
    @patch("mobile.push.enqueue_app_notification")
    def test_template_sender_uses_app_outbox_with_explicit_recipient_and_no_http(self, enqueue, urlopen):
        notification = {
            "schemaVersion": 1,
            "eventId": "template:OPEN:test-only-123",
            "type": "OPEN",
            "title": "开单成功",
            "content": "> **交易对**：BTCUSDT",
            "occurredAt": "2026-09-04T12:00:00+08:00",
        }

        result = send_trade_notification(notification, recipient_user_id=42)

        self.assertTrue(result["ok"])
        enqueue.assert_called_once()
        self.assertEqual(enqueue.call_args.kwargs["user_id"], 42)
        self.assertEqual(enqueue.call_args.kwargs["payload"]["route"], "trade.notification")
        self.assertEqual(enqueue.call_args.kwargs["payload"]["aps"]["alert"]["title"], "开单成功")
        urlopen.assert_not_called()

    @override_settings(
        EXTERNAL_TRADE_SIGNAL_URL="https://signals.example.com/api/external/messages",
        EXTERNAL_TRADE_SIGNAL_API_KEY="external-header-token",
        EXTERNAL_TRADE_SIGNAL_TIMEOUT_SECONDS=5,
    )
    @patch("positions.external_trade_signals.request.build_opener")
    def test_external_sender_uses_https_header_and_requires_accepted_response(self, build_opener):
        response = MagicMock()
        response.status = 202
        response.read.return_value = b'{"code":202,"message":"accepted","data":null}'
        build_opener.return_value.open.return_value.__enter__.return_value = response
        payload = {
            "schemaVersion": 1,
            "eventId": "trade:open:123",
            "type": "OPEN",
            "title": "🚀 BTCUSDT 多单 开仓",
            "content": "> **币种**：BTCUSDT",
            "occurredAt": "2026-09-04T12:00:00+08:00",
        }

        result = send_external_trade_signal(payload)

        self.assertEqual(result["code"], 202)
        req = build_opener.return_value.open.call_args.args[0]
        self.assertEqual(req.full_url, "https://signals.example.com/api/external/messages")
        self.assertNotIn("external-header-token", req.full_url)
        self.assertEqual(req.get_header("X-external-message-key"), "external-header-token")
        self.assertEqual(json.loads(req.data.decode("utf-8")), payload)

    @override_settings(
        EXTERNAL_TRADE_SIGNAL_URL="http://signals.example.com/api/external/messages",
        EXTERNAL_TRADE_SIGNAL_API_KEY="external-header-token",
    )
    @patch("positions.external_trade_signals.request.build_opener")
    def test_external_sender_rejects_non_https_url_before_opening_connection(self, build_opener):
        with self.assertRaisesRegex(RuntimeError, "HTTPS"):
            send_external_trade_signal({"type": "CLOSE"})
        build_opener.assert_not_called()

    @patch("positions.management.commands.send_trade_notification_templates.send_trade_notification")
    def test_template_command_sends_all_five_categories(self, send):
        output = StringIO()

        call_command("send_trade_notification_templates", confirm=True, user_id=42, stdout=output)

        self.assertEqual(send.call_count, 5)
        self.assertTrue(all(item.kwargs["recipient_user_id"] == 42 for item in send.call_args_list))
        titles = [item.args[0]["title"] for item in send.call_args_list]
        self.assertEqual(
            titles,
            [
                "🚀 【模板测试】BTCUSDT 多单 开仓",
                "🛑 【模板测试】BTCUSDT 多单 止损",
                "🎯 【模板测试】BTCUSDT 多单 止盈",
                "✋ 【模板测试】BTCUSDT 空单 手动止盈",
                "📉 【模板测试】BTCUSDT 多单 减仓",
            ],
        )
        labels = [self._labels(item.args[0]["content"]) for item in send.call_args_list]
        self.assertEqual(
            labels,
            [
                ["测试说明", "币种", "订单方向", "止损价", "成交价", "订单编号", "成交时间"],
                ["测试说明", "币种", "订单方向", "开仓价", "止损价", "止损时间", "止损盈亏比"],
                ["测试说明", "币种", "订单方向", "止盈价", "止盈盈亏比", "止盈时间"],
                ["测试说明", "币种", "订单方向", "止盈价", "止盈盈亏比", "止盈时间"],
                ["测试说明", "币种", "订单方向", "减仓百分比", "减仓价格", "减仓时间", "减仓类型"],
            ],
        )

    @patch(
        "positions.management.commands.send_external_trade_notification_templates.send_external_trade_signal"
    )
    def test_external_template_command_sends_all_five_categories_with_unified_payload(self, send):
        output = StringIO()

        call_command("send_external_trade_notification_templates", confirm=True, stdout=output)

        self.assertEqual(send.call_count, 5)
        payloads = [item.args[0] for item in send.call_args_list]
        self.assertEqual(
            [payload["type"] for payload in payloads],
            ["OPEN", "STOP_LOSS", "STRATEGY_TAKE_PROFIT", "MANUAL_TAKE_PROFIT", "REDUCTION"],
        )
        for payload in payloads:
            self.assertEqual(
                set(payload),
                {"schemaVersion", "eventId", "type", "title", "content", "occurredAt"},
            )
            self.assertEqual(payload["schemaVersion"], 1)
            self.assertTrue(payload["eventId"].startswith("template:"))
            self.assertIn("【模板测试】", payload["title"])
            self.assertIn("仅验证通知样式", payload["content"])

    @patch(
        "positions.management.commands.send_external_trade_notification_templates.send_external_trade_signal",
        side_effect=RuntimeError("receiver rejected"),
    )
    def test_external_template_command_attempts_all_categories_when_receiver_rejects(self, send):
        with self.assertRaisesRegex(CommandError, "其中 5 类失败"):
            call_command(
                "send_external_trade_notification_templates",
                confirm=True,
                stdout=StringIO(),
                stderr=StringIO(),
            )

        self.assertEqual(send.call_count, 5)


@override_settings(APNS_ENABLED=True)
class TradeNotificationEventTests(TransactionTestCase):
    reset_sequences = True

    def setUp(self):
        self.user = User.objects.create_user(email="notify@example.com", password="password")
        self.order = Order.objects.create(
            user=self.user,
            binance_order_id="open-notify-1",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            initial_stop_price=Decimal("90"),
            stop_loss_price=Decimal("90"),
            current_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )

    @staticmethod
    def _labels(event):
        return [line.removeprefix("> **").split("**：", 1)[0] for line in event.content.splitlines()]

    def _assert_unified_delivery(self, delivery, expected_type):
        event = delivery.event
        payload = delivery.payload
        self.assertEqual(
            set(payload),
            {"schemaVersion", "eventId", "type", "title", "content", "occurredAt"},
        )
        self.assertEqual(payload["schemaVersion"], 1)
        self.assertEqual(payload["eventId"], event.event_key)
        self.assertEqual(payload["type"], expected_type)
        self.assertEqual(payload["title"], event.title)
        self.assertEqual(payload["content"], event.content)
        self.assertEqual(
            payload["occurredAt"],
            timezone.localtime(event.created_at).isoformat(timespec="seconds"),
        )

    def test_open_enqueue_is_idempotent(self):
        enqueue_open_notification(self.order)
        enqueue_open_notification(self.order)

        event = TradeNotificationEvent.objects.get()
        self.assertEqual(event.event_type, TradeNotificationEvent.TYPE_OPEN)
        self.assertEqual(
            self._labels(event),
            ["币种", "订单方向", "止损价", "成交价", "订单编号", "成交时间"],
        )
        self.assertIn("订单方向**：多单", event.content)
        self.assertEqual(event.title, "🚀 BTCUSDT 多单 开仓")
        self.assertIn(f"订单编号**：{self.order.id}", event.content)
        self.assertNotIn("open-notify-1", event.content)
        self.assertEqual(TradeNotificationEvent.objects.count(), 1)

    @override_settings(EXTERNAL_TRADE_SIGNAL_ENABLED=True)
    @patch("positions.notifications.send_trade_notification", return_value={"ok": True})
    @patch("positions.external_trade_signals.send_external_trade_signal", return_value={"code": 202})
    def test_pause_preserves_event_and_retry_state_until_resumed(self, external, internal):
        enqueue_open_notification(self.order)
        event = TradeNotificationEvent.objects.get()
        delivery = ExternalTradeSignalDelivery.objects.get(event=event)
        retry_at = timezone.now() - timedelta(seconds=1)
        event.status = "failed"
        event.attempt_count = 3
        event.next_retry_at = retry_at
        event.save()
        delivery.status = "failed"
        delivery.attempt_count = 2
        delivery.next_retry_at = retry_at
        delivery.save()
        with override_settings(TRADE_NOTIFICATION_ENABLED=False):
            self.assertEqual(dispatch_pending_trade_notifications(), 0)
            self.assertEqual(dispatch_pending_external_trade_signals(), 0)
        event.refresh_from_db()
        delivery.refresh_from_db()
        self.assertEqual((event.status, event.attempt_count, event.next_retry_at), ("failed", 3, retry_at))
        self.assertEqual((delivery.status, delivery.attempt_count, delivery.next_retry_at), ("failed", 2, retry_at))
        internal.assert_not_called()
        external.assert_not_called()
        with override_settings(TRADE_NOTIFICATION_ENABLED=True):
            self.assertEqual(dispatch_pending_trade_notifications(), 1)
            self.assertEqual(dispatch_pending_external_trade_signals(), 1)
        internal.assert_called_once()
        external.assert_called_once()

    @override_settings(EXTERNAL_TRADE_SIGNAL_ENABLED=True)
    @patch("positions.external_trade_signals.send_external_trade_signal", return_value={"code": 202})
    def test_lead_notification_marker_survives_close_classification_upgrade(self, send):
        self.order.trading_mode = "lead"
        self.order.save(update_fields=["trading_mode"])
        enqueue_open_notification(self.order)
        opening = TradeNotificationEvent.objects.get(event_type=TradeNotificationEvent.TYPE_OPEN)
        self.assertIn("【带单】", opening.title)
        self.assertTrue(opening.content.startswith("> **交易账户**：带单组合\n"))
        self.assertEqual(dispatch_pending_external_trade_signals(), 1)
        send.assert_called_once()
        delivery = ExternalTradeSignalDelivery.objects.get(event=opening)
        self._assert_unified_delivery(delivery, "OPEN")
        enqueue_close_notification(self.order, event_type=TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT,
                                   classification_confidence=1)
        enqueue_close_notification(self.order, event_type=TradeNotificationEvent.TYPE_STOP_LOSS,
                                   classification_confidence=3, trigger_price=Decimal("90"))
        closing = TradeNotificationEvent.objects.get(event_key=f"trade:close:{self.order.pk}")
        self.assertIn("【带单】", closing.title)
        self.assertEqual(closing.event_type, TradeNotificationEvent.TYPE_STOP_LOSS)

    @override_settings(EXTERNAL_TRADE_SIGNAL_ENABLED=True)
    @patch(
        "positions.external_trade_signals.send_external_trade_signal",
        return_value={"code": 202},
    )
    @patch(
        "positions.external_trade_signals.enqueue_external_trade_signal",
        side_effect=RuntimeError("temporary database failure"),
    )
    def test_external_dispatch_repairs_missing_delivery_row(self, _enqueue, send):
        enqueue_open_notification(self.order)

        event = TradeNotificationEvent.objects.get()
        self.assertTrue(event.context["external_delivery_required"])
        self.assertFalse(ExternalTradeSignalDelivery.objects.filter(event=event).exists())

        self.assertEqual(dispatch_pending_external_trade_signals(), 1)

        delivery = ExternalTradeSignalDelivery.objects.get(event=event)
        self.assertEqual(delivery.status, ExternalTradeSignalDelivery.STATUS_SENT)
        send.assert_called_once()

    def test_exchange_size_drop_enqueues_one_reduction(self):
        self.order.exchange_size = Decimal("1")
        self.order.save(update_fields=["exchange_size"])

        _sync_order_exchange_size(self.order, Decimal("0.7"), current_price=Decimal("110"))
        _sync_order_exchange_size(self.order, Decimal("0.7"), current_price=Decimal("110"))

        event = TradeNotificationEvent.objects.get(event_type=TradeNotificationEvent.TYPE_REDUCTION)
        self.assertEqual(
            self._labels(event),
            ["币种", "订单方向", "减仓百分比", "减仓价格", "减仓时间", "减仓类型"],
        )
        self.assertIn("减仓百分比**：30%", event.content)
        self.assertIn("减仓价格**：110", event.content)
        self.assertIn("减仓类型**：浮盈减仓", event.content)
        self.assertEqual(event.title, "📉 BTCUSDT 多单 减仓")

    @patch(
        "positions.notifications.TradeNotificationEvent.objects.get_or_create",
        side_effect=IntegrityError("temporary event insert failure"),
    )
    def test_exchange_size_drop_rolls_back_when_reduction_event_insert_fails(self, _create):
        self.order.exchange_size = Decimal("1")
        self.order.save(update_fields=["exchange_size"])

        with self.assertRaises(IntegrityError):
            _sync_order_exchange_size(self.order, Decimal("0.7"), current_price=Decimal("110"))

        self.order.refresh_from_db()
        self.assertEqual(self.order.exchange_size, Decimal("1"))
        self.assertFalse(self.order.has_manual_addition)
        self.assertFalse(
            TradeNotificationEvent.objects.filter(
                event_type=TradeNotificationEvent.TYPE_REDUCTION,
            ).exists()
        )

    def test_short_reduction_at_higher_price_is_floating_loss(self):
        self.order.side = 1
        self.order.exchange_size = Decimal("1")
        self.order.save(update_fields=["side", "exchange_size"])

        _sync_order_exchange_size(self.order, Decimal("0.5"), current_price=Decimal("110"))

        event = TradeNotificationEvent.objects.get(event_type=TradeNotificationEvent.TYPE_REDUCTION)
        self.assertIn("订单方向**：空单", event.content)
        self.assertIn("减仓类型**：浮亏减仓", event.content)

    @override_settings(EXTERNAL_TRADE_SIGNAL_ENABLED=True)
    @patch("positions.external_trade_signals.send_external_trade_signal", return_value={"code": 202})
    def test_external_delivery_uses_unified_open_and_reduction_events(self, send):
        self.order.side = 1
        self.order.exchange_size = Decimal("1")
        self.order.save(update_fields=["side", "exchange_size"])

        enqueue_open_notification(self.order)
        _sync_order_exchange_size(self.order, Decimal("0.7"), current_price=Decimal("110"))

        self.assertEqual(dispatch_pending_external_trade_signals(), 2)
        deliveries = {
            row.event.event_type: row
            for row in ExternalTradeSignalDelivery.objects.select_related("event").all()
        }
        self._assert_unified_delivery(
            deliveries[TradeNotificationEvent.TYPE_OPEN],
            "OPEN",
        )
        self._assert_unified_delivery(
            deliveries[TradeNotificationEvent.TYPE_REDUCTION],
            "REDUCTION",
        )
        self.assertEqual(send.call_count, 2)

    @override_settings(EXTERNAL_TRADE_SIGNAL_ENABLED=True)
    @patch("positions.external_trade_signals.send_external_trade_signal", return_value={"code": 202})
    def test_external_dispatch_prepares_all_settled_close_events_without_wecom_dispatch(self, send):
        event_types = [
            TradeNotificationEvent.TYPE_STOP_LOSS,
            TradeNotificationEvent.TYPE_STRATEGY_TAKE_PROFIT,
            TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT,
        ]
        for index, event_type in enumerate(event_types, start=1):
            order = Order.objects.create(
                user=self.user,
                binance_order_id=f"close-external-{index}",
                symbol="ETHUSDT",
                side=0,
                open_price=Decimal("200"),
                stop_loss_price=Decimal("190"),
                stop_loss_amount=Decimal("20"),
                size=Decimal("0.25"),
                leverage=10,
                status=1,
                close_price=Decimal(str(200 + index)),
                closed_at=timezone.now(),
                settlement_status=Order.SETTLEMENT_STATUS_SETTLED,
                settled_at=timezone.now(),
            )
            enqueue_close_notification(order, event_type=event_type)

        self.assertEqual(dispatch_pending_external_trade_signals(), 3)
        deliveries = list(
            ExternalTradeSignalDelivery.objects.select_related("event").order_by("event__event_type")
        )
        self.assertEqual(
            {delivery.payload["type"] for delivery in deliveries},
            {"STOP_LOSS", "STRATEGY_TAKE_PROFIT", "MANUAL_TAKE_PROFIT"},
        )
        for delivery in deliveries:
            self._assert_unified_delivery(delivery, delivery.event.event_type.upper())
            self.assertTrue(delivery.event.content)
            self.assertEqual(delivery.event.status, TradeNotificationEvent.STATUS_PENDING)
        self.assertEqual(send.call_count, 3)

    @override_settings(EXTERNAL_TRADE_SIGNAL_ENABLED=True)
    @patch("positions.external_trade_signals.send_external_trade_signal", return_value={"code": 202})
    @patch("positions.notifications.send_trade_notification", side_effect=TimeoutError("wecom timeout"))
    def test_external_delivery_is_independent_from_wecom_failure(self, send_wecom, send_external):
        enqueue_open_notification(self.order)

        self.assertEqual(dispatch_pending_trade_notifications(), 0)
        self.assertEqual(dispatch_pending_external_trade_signals(), 1)

        event = TradeNotificationEvent.objects.get()
        delivery = ExternalTradeSignalDelivery.objects.get(event=event)
        self.assertEqual(event.status, TradeNotificationEvent.STATUS_FAILED)
        self.assertEqual(delivery.status, ExternalTradeSignalDelivery.STATUS_SENT)
        send_wecom.assert_called_once()
        send_external.assert_called_once()
        external_payload = send_external.call_args.args[0]
        self.assertEqual(send_wecom.call_args.args, (external_payload,))

    @override_settings(EXTERNAL_TRADE_SIGNAL_ENABLED=True)
    @patch("positions.external_trade_signals.send_external_trade_signal", side_effect=TimeoutError("remote timeout"))
    @patch("positions.notifications.send_trade_notification", return_value={"ok": True})
    def test_wecom_delivery_is_independent_from_external_failure(self, send_wecom, send_external):
        enqueue_open_notification(self.order)

        self.assertEqual(dispatch_pending_trade_notifications(), 1)
        self.assertEqual(dispatch_pending_external_trade_signals(), 0)

        event = TradeNotificationEvent.objects.get()
        delivery = ExternalTradeSignalDelivery.objects.get(event=event)
        self.assertEqual(event.status, TradeNotificationEvent.STATUS_SENT)
        self.assertEqual(delivery.status, ExternalTradeSignalDelivery.STATUS_FAILED)
        self.assertIsNotNone(delivery.next_retry_at)
        send_wecom.assert_called_once()
        send_external.assert_called_once()
        external_payload = send_external.call_args.args[0]
        self.assertEqual(send_wecom.call_args.args, (external_payload,))

    @patch("positions.notifications.send_trade_notification", return_value={"ok": True})
    def test_close_notification_waits_for_settlement_then_uses_final_financials(self, send):
        self.order.status = 1
        self.order.close_binance_order_id = "close-stop-1"
        self.order.close_price = Decimal("89.9")
        self.order.realized_pnl = Decimal("-10.1")
        self.order.realized_fee = Decimal("-0.2")
        self.order.realized_funding_fee = Decimal("0")
        self.order.pnl = Decimal("-10.3")
        self.order.pnl_ratio = Decimal("-10.3")
        self.order.closed_at = timezone.now()
        self.order.save()

        enqueue_close_notification(
            self.order,
            event_type=TradeNotificationEvent.TYPE_STOP_LOSS,
            trigger_price=Decimal("90"),
        )
        enqueue_close_notification(
            self.order,
            event_type=TradeNotificationEvent.TYPE_STOP_LOSS,
            trigger_price=Decimal("90"),
        )

        self.assertEqual(dispatch_pending_trade_notifications(), 0)
        pending_event = TradeNotificationEvent.objects.get()
        self.assertEqual(pending_event.content, "")
        self.assertEqual(pending_event.status, TradeNotificationEvent.STATUS_PENDING)
        send.assert_not_called()

        self.order.settlement_status = Order.SETTLEMENT_STATUS_SETTLED
        self.order.settled_at = timezone.now()
        self.order.save(update_fields=["settlement_status", "settled_at"])
        self.assertEqual(dispatch_pending_trade_notifications(), 1)

        event = TradeNotificationEvent.objects.get()
        self.assertEqual(event.event_type, TradeNotificationEvent.TYPE_STOP_LOSS)
        self.assertEqual(
            self._labels(event),
            ["币种", "订单方向", "开仓价", "止损价", "止损时间", "止损盈亏比"],
        )
        self.assertIn("止损盈亏比**：-0.3:1", event.content)
        self.assertNotIn("close-stop-1", event.content)
        self.assertEqual(event.title, "🛑 BTCUSDT 多单 止损")
        send.assert_called_once()

    @patch("positions.notifications.send_trade_notification", return_value={"ok": True})
    def test_unsettled_close_does_not_block_ready_open_notification(self, send):
        self.order.status = 1
        self.order.closed_at = timezone.now()
        self.order.save(update_fields=["status", "closed_at"])
        enqueue_close_notification(
            self.order,
            event_type=TradeNotificationEvent.TYPE_STOP_LOSS,
            trigger_price=Decimal("90"),
        )
        ready_order = Order.objects.create(
            user=self.user,
            binance_order_id="open-notify-ready",
            symbol="ETHUSDT",
            side=1,
            open_price=Decimal("200"),
            stop_loss_price=Decimal("210"),
            stop_loss_amount=Decimal("20"),
            size=Decimal("1"),
            leverage=10,
        )
        enqueue_open_notification(ready_order)

        self.assertEqual(dispatch_pending_trade_notifications(limit=1), 1)

        close_event = TradeNotificationEvent.objects.get(order=self.order)
        open_event = TradeNotificationEvent.objects.get(order=ready_order)
        self.assertEqual(close_event.status, TradeNotificationEvent.STATUS_PENDING)
        self.assertEqual(open_event.status, TradeNotificationEvent.STATUS_SENT)
        send.assert_called_once()

    @patch("positions.notifications.send_trade_notification", return_value={"ok": True})
    def test_strategy_take_profit_uses_compact_fields_and_risk_reward_ratio(self, send):
        self.order.status = 1
        self.order.close_binance_order_id = "close-strategy-1"
        self.order.close_price = Decimal("130")
        self.order.pnl = Decimal("60")
        self.order.closed_at = timezone.now()
        self.order.settlement_status = Order.SETTLEMENT_STATUS_SETTLED
        self.order.settled_at = timezone.now()
        self.order.save()

        enqueue_close_notification(
            self.order,
            event_type=TradeNotificationEvent.TYPE_STRATEGY_TAKE_PROFIT,
            trigger_price=Decimal("130"),
        )
        dispatch_pending_trade_notifications()

        event = TradeNotificationEvent.objects.get()
        self.assertEqual(event.event_type, TradeNotificationEvent.TYPE_STRATEGY_TAKE_PROFIT)
        self.assertEqual(
            self._labels(event),
            ["币种", "订单方向", "止盈价", "止盈盈亏比", "止盈时间"],
        )
        self.assertIn("止盈盈亏比**：2.0:1", event.content)
        self.assertEqual(event.title, "🎯 BTCUSDT 多单 止盈")
        send.assert_called_once()

    @patch("positions.notifications.send_trade_notification", return_value={"ok": True})
    def test_manual_take_profit_uses_compact_fields_and_short_direction(self, send):
        self.order.side = 1
        self.order.status = 1
        self.order.close_binance_order_id = "close-manual-1"
        self.order.close_price = Decimal("80")
        self.order.pnl = Decimal("45")
        self.order.closed_at = timezone.now()
        self.order.settlement_status = Order.SETTLEMENT_STATUS_SETTLED
        self.order.settled_at = timezone.now()
        self.order.save()

        enqueue_close_notification(
            self.order,
            event_type=TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT,
            trigger_price=Decimal("80"),
        )
        dispatch_pending_trade_notifications()

        event = TradeNotificationEvent.objects.get()
        self.assertEqual(event.event_type, TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT)
        self.assertEqual(
            self._labels(event),
            ["币种", "订单方向", "止盈价", "止盈盈亏比", "止盈时间"],
        )
        self.assertIn("订单方向**：空单", event.content)
        self.assertIn("止盈盈亏比**：1.5:1", event.content)
        self.assertEqual(event.title, "✋ BTCUSDT 空单 手动止盈")
        send.assert_called_once()

    def test_infers_manual_take_profit_from_filled_algo(self):
        self.order.manual_take_profit_algo_id = "manual-tp-1"
        self.order.manual_take_profit_price = Decimal("110")
        client = MagicMock()
        client.get_pending_algo_orders.return_value = {
            "data": [
                {
                    "algoId": "manual-tp-1",
                    "actualOrderId": "close-manual-1",
                    "state": "filled",
                    "tpTriggerPx": "110",
                }
            ]
        }

        result = infer_exchange_close_notification(
            self.order,
            client,
            close_price=Decimal("110.1"),
            close_order_id="close-manual-1",
        )

        self.assertEqual(result["event_type"], TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT)
        self.assertEqual(result["trigger_price"], Decimal("110"))

    def test_pending_fallback_close_is_upgraded_by_exchange_order_evidence(self):
        self.order.binance_stop_market_order_id = "stop-1"
        self.order.save(update_fields=["binance_stop_market_order_id"])
        client = MagicMock()
        client.get_pending_algo_orders.return_value = {"data": []}

        fallback = infer_exchange_close_notification(
            self.order,
            client,
            close_price=Decimal("105"),
            close_order_id="close-1",
        )
        enqueue_close_notification(self.order, **fallback)
        event = TradeNotificationEvent.objects.get()
        self.assertEqual(event.event_type, TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT)
        self.assertEqual(event.context["classification_confidence"], 1)

        client.get_pending_algo_orders.return_value = {
            "data": [
                {
                    "algoId": "stop-1",
                    "actualOrderId": "close-1",
                    "state": "filled",
                    "slTriggerPx": "90",
                }
            ]
        }
        authoritative = infer_exchange_close_notification(
            self.order,
            client,
            close_price=Decimal("105"),
            close_order_id="close-1",
        )
        enqueue_close_notification(self.order, **authoritative)

        event.refresh_from_db()
        self.assertEqual(event.event_type, TradeNotificationEvent.TYPE_STOP_LOSS)
        self.assertEqual(event.context["trigger_price"], "90")
        self.assertEqual(event.context["classification_confidence"], 3)
        self.assertEqual(event.content, "")

    def test_close_inference_stops_exchange_queries_after_shared_rate_limit(self):
        self.order.binance_stop_market_order_id = "stop-market-1"
        self.order.binance_stop_order_id = "stop-limit-1"
        self.order.current_stop_price = Decimal("90")
        client = MagicMock()
        client.get_pending_algo_orders.side_effect = BinanceApiError(
            "Binance 请求预算保护中",
            code="LOCAL_RATE_BUDGET",
        )

        result = infer_exchange_close_notification(
            self.order,
            client,
            close_price=Decimal("90"),
            close_order_id="close-1",
        )

        self.assertEqual(client.get_pending_algo_orders.call_count, 1)
        self.assertEqual(result["event_type"], TradeNotificationEvent.TYPE_STOP_LOSS)
        self.assertEqual(result["classification_confidence"], 2)

    def test_rendered_close_notification_is_immutable(self):
        event = enqueue_close_notification(
            self.order,
            event_type=TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT,
            trigger_price=Decimal("105"),
            classification_confidence=1,
        )
        event.content = "already rendered"
        event.save(update_fields=["content"])

        enqueue_close_notification(
            self.order,
            event_type=TradeNotificationEvent.TYPE_STOP_LOSS,
            trigger_price=Decimal("90"),
            classification_confidence=3,
        )

        event.refresh_from_db()
        self.assertEqual(event.event_type, TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT)
        self.assertEqual(event.context["trigger_price"], "105")
        self.assertEqual(event.context["classification_confidence"], 1)

    @override_settings(
        TRADE_NOTIFICATION_URL="http://tradingview-webhook:3000/internal/trade-notification",
        TRADE_NOTIFICATION_TOKEN="internal-token",
    )
    @patch("positions.notifications.send_trade_notification", return_value={"ok": True})
    def test_dispatch_marks_event_sent(self, send):
        enqueue_open_notification(self.order)

        sent = dispatch_pending_trade_notifications()

        self.assertEqual(sent, 1)
        event = TradeNotificationEvent.objects.get()
        self.assertEqual(event.status, TradeNotificationEvent.STATUS_SENT)
        self.assertEqual(event.attempt_count, 1)
        send.assert_called_once()

    @patch("positions.notifications.send_trade_notification", side_effect=TimeoutError("timeout"))
    def test_dispatch_failure_is_retained_for_retry(self, send):
        enqueue_open_notification(self.order)

        sent = dispatch_pending_trade_notifications()

        self.assertEqual(sent, 0)
        event = TradeNotificationEvent.objects.get()
        self.assertEqual(event.status, TradeNotificationEvent.STATUS_FAILED)
        self.assertEqual(event.attempt_count, 1)
        self.assertIsNotNone(event.next_retry_at)
        self.assertIn("timeout", event.last_error)
        send.assert_called_once()

    @patch(
        "positions.notifications.send_trade_notification",
        side_effect=RuntimeError(
            "POST https://notify.example.test/send?signature=abc token=secret-value failed"
        ),
    )
    def test_dispatch_failure_redacts_endpoint_and_credentials(self, send):
        enqueue_open_notification(self.order)

        self.assertEqual(dispatch_pending_trade_notifications(), 0)

        event = TradeNotificationEvent.objects.get()
        self.assertEqual(event.status, TradeNotificationEvent.STATUS_FAILED)
        self.assertIn("RuntimeError", event.last_error)
        self.assertNotIn("notify.example.test", event.last_error)
        self.assertNotIn("secret-value", event.last_error)
        self.assertNotIn("signature=abc", event.last_error)
        send.assert_called_once()

    @patch("positions.notifications.send_trade_notification")
    def test_trade_notification_network_call_runs_outside_transaction(self, send):
        send.side_effect = lambda *_args: self.assertFalse(connection.in_atomic_block) or {"ok": True}
        enqueue_open_notification(self.order)

        self.assertEqual(dispatch_pending_trade_notifications(), 1)

    @patch("positions.notifications.send_trade_notification", return_value={"ok": True})
    def test_trade_notification_recovers_expired_lease(self, send):
        enqueue_open_notification(self.order)
        event = TradeNotificationEvent.objects.get()
        event.status = TradeNotificationEvent.STATUS_SENDING
        event.attempt_count = 1
        event.lease_expires_at = timezone.now() - timedelta(seconds=1)
        event.save(update_fields=["status", "attempt_count", "lease_expires_at"])

        self.assertEqual(dispatch_pending_trade_notifications(), 1)
        event.refresh_from_db()
        self.assertEqual(event.status, TradeNotificationEvent.STATUS_SENT)
        self.assertEqual(event.attempt_count, 2)
        self.assertIsNone(event.lease_expires_at)
        send.assert_called_once()

    @patch("positions.notifications.send_ops_alert_once")
    @patch("positions.notifications.send_trade_notification", side_effect=TimeoutError("still down"))
    def test_trade_notification_stops_after_max_attempts(self, send, alert):
        enqueue_open_notification(self.order)
        event = TradeNotificationEvent.objects.get()
        event.attempt_count = 7
        event.save(update_fields=["attempt_count"])

        self.assertEqual(dispatch_pending_trade_notifications(), 0)
        event.refresh_from_db()
        self.assertEqual(event.status, TradeNotificationEvent.STATUS_EXHAUSTED)
        self.assertEqual(event.attempt_count, 8)
        self.assertIsNone(event.next_retry_at)
        alert.assert_called_once()
        send.assert_called_once()

    @patch("positions.notifications.send_trade_notification", return_value={"ok": True})
    def test_estimated_close_notification_discloses_estimate(self, send):
        self.order.status = 1
        self.order.close_price = Decimal("110")
        self.order.pnl = Decimal("10")
        self.order.closed_at = timezone.now()
        self.order.settlement_status = Order.SETTLEMENT_STATUS_ESTIMATED
        self.order.settlement_error = "缺少精确平仓订单号"
        self.order.save()
        enqueue_close_notification(
            self.order,
            event_type=TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT,
            trigger_price=Decimal("110"),
        )

        self.assertEqual(dispatch_pending_trade_notifications(), 1)
        event = TradeNotificationEvent.objects.get()
        self.assertIn("数据状态**：估算", event.content)

    @override_settings(EXTERNAL_TRADE_SIGNAL_ENABLED=True)
    @patch("positions.external_trade_signals.send_external_trade_signal")
    def test_external_notification_network_call_runs_outside_transaction(self, send):
        send.side_effect = lambda *_args: self.assertFalse(connection.in_atomic_block) or {"code": 202}
        enqueue_open_notification(self.order)

        self.assertEqual(dispatch_pending_external_trade_signals(), 1)

    @override_settings(EXTERNAL_TRADE_SIGNAL_ENABLED=True)
    @patch("positions.external_trade_signals.send_ops_alert_once")
    @patch("positions.external_trade_signals.send_external_trade_signal", side_effect=TimeoutError("still down"))
    def test_external_notification_stops_after_max_attempts(self, send, alert):
        enqueue_open_notification(self.order)
        delivery = ExternalTradeSignalDelivery.objects.get()
        delivery.attempt_count = 7
        delivery.save(update_fields=["attempt_count"])

        self.assertEqual(dispatch_pending_external_trade_signals(), 0)
        delivery.refresh_from_db()
        self.assertEqual(delivery.status, ExternalTradeSignalDelivery.STATUS_EXHAUSTED)
        self.assertEqual(delivery.attempt_count, 8)
        self.assertIsNone(delivery.next_retry_at)
        alert.assert_called_once()
        send.assert_called_once()


class ExchangeOrderIdentityTests(TransactionTestCase):
    reset_sequences = True

    def setUp(self):
        self.user = User.objects.create_user(email="identity@example.com", password="password")

    def _order(self, fingerprint: str):
        return Order.objects.create(
            user=self.user,
            api_key_fingerprint=fingerprint,
            binance_order_id="shared-exchange-order",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
        )

    def test_order_id_is_scoped_by_api_fingerprint_and_symbol(self):
        self._order("a" * 64)
        self._order("b" * 64)
        Order.objects.create(
            user=self.user,
            api_key_fingerprint="a" * 64,
            binance_order_id="shared-exchange-order",
            symbol="ETHUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
        )
        with self.assertRaises(IntegrityError), transaction.atomic():
            self._order("a" * 64)

    def test_limit_order_id_is_scoped_by_api_fingerprint_and_symbol(self):
        values = {
            "user": self.user,
            "binance_order_id": "shared-limit-order",
            "symbol": "BTCUSDT",
            "side": 0,
            "limit_price": Decimal("95"),
            "stop_loss_price": Decimal("90"),
            "stop_loss_amount": Decimal("30"),
            "size": Decimal("1"),
            "leverage": 10,
        }
        LimitOrder.objects.create(api_key_fingerprint="a" * 64, **values)
        LimitOrder.objects.create(api_key_fingerprint="b" * 64, **values)
        with self.assertRaises(IntegrityError), transaction.atomic():
            LimitOrder.objects.create(api_key_fingerprint="a" * 64, **values)
