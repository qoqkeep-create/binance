from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import patch

from django.db import IntegrityError
from django.test import TestCase
from django.utils import timezone

from api_bindings.models import ApiBinding
from common.binance import BinanceApiError
from positions.models import Order, TradeNotificationEvent, TradeOperationLog
from positions.operation_logs import get_operation_logs
from trading import test_external_positions as protection_fixtures
from trading.external_positions import (
    _cleanup_closed,
    _scan_account,
    close_external_position,
)


class ExternalOperationLogTests(TestCase):
    # Reuse the existing entirely mocked exchange fixture, without inheriting and
    # rediscovering its trading-behavior tests.
    setUp = protection_fixtures.ExternalProtectionTests.setUp
    stop = protection_fixtures.ExternalProtectionTests.stop
    cycle = protection_fixtures.ExternalProtectionTests.cycle
    cancelled_snapshot = protection_fixtures.ExternalProtectionTests.cancelled_snapshot
    close_receipt = protection_fixtures.ExternalProtectionTests.close_receipt

    def logs(self, action, status=None):
        rows = TradeOperationLog.objects.filter(order=self.order, action=action)
        return rows.filter(status=status) if status else rows

    def keep_current_stop_visible(self):
        self.client.get_pending_algo_orders.side_effect = None
        self.client.get_pending_algo_orders.return_value = {"data": [self.submits[-1]]}

    def enable_log_feed(self):
        fingerprint = "external-log-feed-test-account"
        ApiBinding.objects.create(
            user=self.user,
            api_key="unused-test-placeholder",
            secret_key="unused-test-placeholder",
            passphrase="",
            alias="test account",
            api_key_fingerprint=fingerprint,
        )
        self.order.api_key_fingerprint = fingerprint
        self.order.save(update_fields=["api_key_fingerprint"])

    def confirmed_trade_feed(self):
        return [
            row
            for row in get_operation_logs(self.user)["records"]
            if row["source"] == "trade"
        ]

    def test_empty_position_without_close_request_has_unverified_source_in_feed(self):
        self.enable_log_feed()
        self.client.get_positions.side_effect = lambda *_a, **_kw: {"data": []}
        self.assertTrue(close_external_position(self.order, self.client, "net_mode"))
        self.client.close_position.assert_not_called()
        self.assertEqual(self.client.get_positions.call_count, 2)

        records = self.confirmed_trade_feed()
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["status"], "success")
        self.assertEqual(records[0]["action"], "close_confirmed")
        self.assertEqual(records[0]["message"], "平仓已确认，具体触发来源待核实")

    def test_adoption_is_logged_once_without_fabricating_an_open_fill(self):
        self.order.delete()
        self.client.get_account_config.return_value = {"data": [{"posMode": "net_mode"}]}
        account = SimpleNamespace(
            identity="test-log-account",
            api_key_fingerprint="test-log-key",
            trading_mode="ordinary",
            binding_created_at=timezone.now(),
            create_futures_client=lambda: self.client,
        )
        with patch("trading.external_positions.reconcile_external_order"), patch(
            "trading.external_positions._risk_amount", return_value=Decimal("100")
        ):
            _scan_account(self.user, account)
            _scan_account(self.user, account)
        self.order = Order.objects.get()
        event = self.logs("external_adopt").get()
        self.assertEqual(event.status, "info")
        self.assertIn("发现并纳管手动仓", event.message)
        self.assertIn("止损额度 100 USDT", event.message)
        self.assertFalse(TradeNotificationEvent.objects.exists())

    def test_healthy_scans_are_silent_after_the_stop_is_confirmed(self):
        self.cycle()
        self.keep_current_stop_visible()
        before = TradeOperationLog.objects.count()
        self.cycle()
        self.cycle()
        self.assertEqual(TradeOperationLog.objects.count(), before)
        event = self.logs("external_stop", "success").get()
        self.assertIn("已设置", event.message)
        self.assertIn("900", event.message)
        self.assertIn("100", event.message)

    def test_each_cancel_and_restore_is_visible_even_at_the_same_price(self):
        self.cycle()
        self.client.get_pending_algo_orders.side_effect = self.cancelled_snapshot
        self.cycle()
        self.cycle()
        self.assertEqual(self.logs("external_stop_missing").count(), 2)
        self.assertEqual(self.logs("external_stop", "success").count(), 3)
        self.assertEqual(
            self.logs("external_stop", "success").filter(message__contains="已恢复").count(),
            2,
        )

    def test_tightening_log_is_after_confirmation_and_before_old_stop_cancel(self):
        self.client.get_pending_algo_orders.return_value = {"data": [self.stop(price="850")]}

        def cancel(*_args, **_kwargs):
            event = self.logs("external_stop", "success").get()
            self.assertIn("850 → 900", event.message)
            self.order.refresh_from_db()
            self.assertEqual(self.order.external_stop_request["status"], "live")

        self.cancel.side_effect = cancel
        self.cycle()
        self.cancel.assert_called_once()
        self.assertEqual(self.logs("external_stop_cancel", "success").count(), 1)

    def test_existing_stricter_stop_is_described_as_adopted_not_created(self):
        self.client.get_ticker.return_value = {"data": [{"last": "980"}]}
        self.client.get_pending_algo_orders.return_value = {"data": [self.stop(price="950")]}
        self.cycle()
        self.client.place_stop_market_order.assert_not_called()
        self.assertIn("已纳管已有", self.logs("external_stop", "success").get().message)

    def test_unknown_stop_result_is_pending_once_then_recovered_without_resubmit(self):
        self.client.place_stop_market_order.side_effect = BinanceApiError(
            "simulated timeout", outcome_unknown=True
        )
        self.client.get_algo_order_by_client_id.side_effect = BinanceApiError(
            "simulated not found", code="-2013"
        )
        self.cycle()
        self.cycle()
        self.assertEqual(self.logs("external_stop", "pending").count(), 1)
        self.assertFalse(self.logs("external_stop", "success").exists())
        client_id = self.order.external_stop_request["client_id"]
        recovered = self.stop("recovered-stop", clientAlgoId=client_id)
        self.client.get_algo_order_by_client_id.side_effect = lambda *_a, **_kw: {
            "data": [recovered]
        }
        self.cycle()
        self.client.place_stop_market_order.assert_called_once()
        self.assertIn("提交结果已核对", self.logs("external_stop", "success").get().message)
        self.assertFalse(TradeOperationLog.objects.filter(message__contains=client_id).exists())

    def test_submitted_but_unconfirmed_stop_never_logs_success(self):
        self.client.get_algo_order_by_client_id.side_effect = lambda *_a, **_kw: {"data": []}
        self.cycle()
        self.cycle()
        self.client.place_stop_market_order.assert_called_once()
        self.assertEqual(self.logs("external_stop", "pending").count(), 1)
        self.assertFalse(self.logs("external_stop", "success").exists())

    def test_repeated_explicit_stop_rejections_do_not_spam_or_claim_success(self):
        self.client.place_stop_market_order.side_effect = BinanceApiError(
            "simulated rejection", code="-1100"
        )
        self.cycle()
        self.cycle()
        self.assertEqual(self.client.place_stop_market_order.call_count, 2)
        self.assertEqual(self.logs("external_stop", "failed").count(), 1)
        self.assertFalse(self.logs("external_stop", "success").exists())

    def test_protection_failure_and_recovery_are_logged_per_episode(self):
        self.cycle()
        self.keep_current_stop_visible()
        for _ in range(2):
            self.client.get_ticker.side_effect = RuntimeError("simulated unavailable ticker")
            self.cycle()
            self.cycle()
            self.client.get_ticker.side_effect = None
            self.cycle()
        self.assertEqual(self.logs("external_protection", "failed").count(), 2)
        self.assertEqual(self.logs("external_protection", "success").count(), 2)
        self.assertEqual(self.logs("external_stop", "success").count(), 1)

    def test_old_stop_cleanup_failure_is_deduped_and_later_success_is_visible(self):
        old = self.stop(price="850")
        self.client.get_pending_algo_orders.return_value = {"data": [old]}
        self.cancel.side_effect = RuntimeError("simulated cancel failure")
        self.cycle()
        self.client.get_pending_algo_orders.return_value = {"data": [old, self.submits[-1]]}
        self.cycle()
        self.assertEqual(self.logs("external_stop_cancel", "failed").count(), 1)
        self.cancel.side_effect = None
        self.cycle()
        self.assertEqual(self.logs("external_stop_cancel", "success").count(), 1)
        self.assertEqual(self.order.external_stop_request["retired_ids"], [])

    def test_close_cleanup_failure_and_recovery_do_not_duplicate_confirmation(self):
        self.cycle()
        self.cancel.side_effect = RuntimeError("simulated cancel failure")
        self.client.close_position.side_effect = lambda *_a, **_kw: self.close_receipt()
        self.assertTrue(close_external_position(self.order, self.client, "net_mode"))
        _cleanup_closed(self.order, self.client)
        self.assertEqual(self.logs("external_cleanup", "failed").count(), 1)
        self.cancel.side_effect = None
        _cleanup_closed(self.order, self.client)
        _cleanup_closed(self.order, self.client)
        self.assertEqual(self.logs("external_cleanup", "success").count(), 1)
        self.assertEqual(TradeNotificationEvent.objects.filter(order=self.order).count(), 1)
        self.assertFalse(self.logs("external_close", "success").exists())

    def test_excess_loss_close_logs_automatic_reason_and_reuses_confirmed_trade_event(self):
        self.enable_log_feed()
        self.position["rawUpl"] = "-101"
        self.client.close_position.side_effect = lambda *_a, **_kw: self.close_receipt()
        self.cycle()
        event = self.logs("external_close_request").get()
        self.assertEqual(event.actor, "system")
        self.assertEqual(event.status, "pending")
        self.assertIn("浮亏已超过止损额度 100", event.message)
        self.assertEqual(TradeNotificationEvent.objects.filter(order=self.order).count(), 1)
        self.assertFalse(self.logs("external_close", "success").exists())
        records = self.confirmed_trade_feed()
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["action"], "stop_loss")
        self.assertEqual(records[0]["message"], "止损平仓已确认")

    def test_touched_stop_close_logs_the_trigger_reason(self):
        self.enable_log_feed()
        self.order.current_stop_price = Decimal("900")
        self.order.save(update_fields=["current_stop_price"])
        self.client.get_ticker.return_value = {"data": [{"last": "900"}]}
        self.client.close_position.side_effect = lambda *_a, **_kw: self.close_receipt()
        self.cycle()
        self.assertIn("价格已触及止损保护价 900", self.logs("external_close_request").get().message)
        self.assertEqual(self.confirmed_trade_feed()[0]["action"], "stop_loss")

    def test_manual_close_unknown_result_is_not_failed_or_successful(self):
        self.enable_log_feed()
        self.client.close_position.side_effect = BinanceApiError(
            "simulated timeout", outcome_unknown=True
        )
        self.client.get_order.side_effect = BinanceApiError("simulated not found", code="-2013")
        self.assertFalse(close_external_position(self.order, self.client, "net_mode"))
        self.assertFalse(close_external_position(self.order, self.client, "net_mode"))
        self.assertEqual(self.logs("external_close_request").get().actor, "user")
        self.assertEqual(self.logs("external_close", "pending").count(), 1)
        self.assertFalse(self.logs("external_close", "failed").exists())
        self.assertFalse(TradeNotificationEvent.objects.filter(order=self.order).exists())
        self.client.get_order.side_effect = lambda *_a, **_kw: self.close_receipt()
        self.assertTrue(close_external_position(self.order, self.client, "net_mode"))
        self.client.close_position.assert_called_once()
        self.assertEqual(TradeNotificationEvent.objects.filter(order=self.order).count(), 1)
        records = self.confirmed_trade_feed()
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["action"], "manual_take_profit")
        self.assertEqual(records[0]["message"], "手动平仓已确认")

    def test_repeated_close_rejections_log_one_failure_until_status_changes(self):
        self.client.close_position.side_effect = BinanceApiError(
            "simulated reduce-only rejection", code="-2022"
        )
        self.assertFalse(close_external_position(self.order, self.client, "net_mode"))
        self.assertFalse(close_external_position(self.order, self.client, "net_mode"))
        self.assertEqual(self.logs("external_close_request").count(), 1)
        self.assertEqual(self.logs("external_close", "failed").count(), 1)
        self.assertEqual(self.order.status, 0)

    def test_log_database_failure_cannot_interrupt_stop_or_close_transactions(self):
        with patch.object(
            TradeOperationLog,
            "save",
            side_effect=IntegrityError("simulated log DB failure"),
        ):
            self.cycle()
            self.assertEqual(self.order.stop_protection_status, Order.STOP_PROTECTION_COMPLETE)
            self.assertEqual(self.order.external_stop_request["status"], "live")
            self.client.close_position.side_effect = lambda *_a, **_kw: self.close_receipt()
            self.assertTrue(close_external_position(self.order, self.client, "net_mode"))
            self.order.refresh_from_db()
            self.assertEqual(self.order.status, 1)
            self.assertEqual(TradeNotificationEvent.objects.filter(order=self.order).count(), 1)
        self.assertFalse(TradeOperationLog.objects.exists())
