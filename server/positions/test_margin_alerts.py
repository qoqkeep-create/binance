import time
from dataclasses import replace
from datetime import timedelta
from unittest.mock import patch

from django.db import connection
from django.test import TransactionTestCase, override_settings
from django.utils import timezone

from api_bindings.models import ApiBinding
from api_bindings.services import get_user_trading_account
from common.utils import aes_encrypt
from positions.margin_alerts import account_scope, claim_margin_alert, dispatch_margin_alerts
from positions.models import PositionMarginAlert, PositionMarginWatch
from positions.profit_alerts import EchobellRejected
from positions.test_margin import snapshot
from users.models import User


@override_settings(POSITION_MARGIN_CALL_ENABLED=True, POSITION_PROFIT_CALL_ENABLED=False,
                   POSITION_PROFIT_CALL_URL="https://hook.echobell.one/t/test-only")
class MarginAlertTests(TransactionTestCase):
    def setUp(self):
        self.user = User.objects.create_user(email="margin@example.com", password="test-only")
        self.config = override_settings(POSITION_PROFIT_CALL_USER_ID=self.user.pk)
        self.config.enable()
        self.addCleanup(self.config.disable)
        self.binding = ApiBinding.objects.create(user=self.user, status=1, alias="fixture",
            api_key=aes_encrypt("fixture-margin-key"), secret_key=aes_encrypt("fixture-secret"),
            passphrase=aes_encrypt(""))
        self.account = get_user_trading_account(self.user, active_only=True)

    def risk(self, ratio="75.01", **changes):
        return {"supported": True, "observed_at": time.time() * 1000,
                "margin_ratio_percent": ratio, "positions": [{"symbol": "BTCUSDT", "quantity": "1"}],
                "liquidation_reached": False, **changes}

    def claim(self, sample=None, account=None):
        return claim_margin_alert(self.user, account or self.account, sample or self.risk())

    def test_strict_decimal_threshold_and_one_attempt_per_episode(self):
        self.assertIsNone(self.claim(self.risk("75")))
        self.assertIsNone(self.claim(self.risk("74.99999")))
        first = self.claim(self.risk("75.00001"))
        self.assertIsNotNone(first)
        PositionMarginAlert.objects.filter(pk=first[0]).update(status="sent",
            attempted_at=timezone.now() - timedelta(seconds=61))
        self.assertIsNone(self.claim(self.risk("99")))
        self.assertEqual(PositionMarginAlert.objects.count(), 1)
        self.assertIsNone(self.claim(self.risk("75")))
        self.assertIsNotNone(self.claim(self.risk("76")))
        self.assertEqual(PositionMarginAlert.objects.count(), 2)

    def test_empty_unsupported_invalid_and_stale_do_not_alert(self):
        for sample in (self.risk(positions=[]), self.risk(supported=False), self.risk("NaN"),
                       self.risk(None), self.risk("-1"), self.risk(observed_at=(time.time()-21)*1000)):
            self.assertIsNone(self.claim(sample))
        self.assertEqual(PositionMarginAlert.objects.count(), 0)

    def test_zero_equity_with_live_maintenance_alerts_at_liquidation(self):
        alert = self.claim(self.risk(None, liquidation_reached=True))
        self.assertIn("已达强平线", alert[1]["title"])

    def test_cooldown_is_shared_across_modes_and_recovery_cancels_pending(self):
        first = self.claim()
        ApiBinding.objects.create(user=self.user, trading_mode="lead", status=1,
            api_key=aes_encrypt("lead-key"), secret_key=aes_encrypt("lead-secret"), passphrase=aes_encrypt(""))
        lead = get_user_trading_account(self.user, active_only=True, trading_mode="lead")
        self.assertIsNone(self.claim(account=lead))
        pending = PositionMarginAlert.objects.get(status="pending")
        self.assertNotEqual(pending.watch.scope, account_scope(self.account))
        self.assertIsNone(self.claim(self.risk("75"), lead))
        pending.refresh_from_db()
        self.assertEqual(pending.status, "cancelled")
        self.assertIsNotNone(first)

    def test_old_binding_disabled_binding_other_recipient_and_old_snapshot_rejected(self):
        old = self.risk()
        self.assertIsNone(self.claim(self.risk("50")))
        self.assertIsNone(self.claim(old))
        self.assertIsNone(self.claim(account=replace(self.account, user_id=self.user.pk + 100)))
        self.binding.status = 0
        self.binding.save(update_fields=["status"])
        self.assertIsNone(self.claim())
        self.binding.status = 1
        self.binding.created_at = timezone.now()
        self.binding.save(update_fields=["status", "created_at"])
        self.assertIsNone(self.claim())
        self.assertEqual(PositionMarginAlert.objects.count(), 0)

    @patch("positions.margin_alerts.send_echobell")
    @patch("common.binance.BinanceFuturesClient.get_margin_account_snapshot")
    def test_background_monitor_is_read_only_and_sends_outside_transaction(self, read, send):
        read.return_value = ({"multiAssetsMargin": False}, snapshot())
        def outside_transaction(payload):
            self.assertFalse(connection.in_atomic_block)
            self.assertIn("账户", payload["title"])
            self.assertIn("AAAUSDT", payload["body"])
            self.assertIn("BBBUSDT", payload["body"])
        send.side_effect = outside_transaction
        self.assertEqual(dispatch_margin_alerts(), 1)
        self.assertEqual(dispatch_margin_alerts(), 0)
        self.assertEqual(send.call_count, 1)
        self.assertEqual(PositionMarginAlert.objects.get().status, "sent")

    @patch("positions.margin_alerts.send_echobell")
    @patch("common.binance.BinanceFuturesClient.get_margin_account_snapshot")
    def test_timeout_or_rejection_never_retries_same_episode(self, read, send):
        read.return_value = ({"multiAssetsMargin": False}, snapshot())
        for failure, expected in ((TimeoutError("redacted"), "unknown"), (EchobellRejected(), "failed")):
            PositionMarginWatch.objects.all().delete()
            send.reset_mock()
            send.side_effect = failure
            self.assertEqual(dispatch_margin_alerts(), 0)
            self.assertEqual(dispatch_margin_alerts(), 0)
            self.assertEqual(send.call_count, 1)
            self.assertEqual(PositionMarginAlert.objects.get().status, expected)

    @patch("positions.margin_alerts.send_echobell")
    @patch("common.binance.BinanceFuturesClient.get_margin_account_snapshot")
    def test_unavailable_snapshot_does_not_rearm_or_send(self, read, send):
        self.claim()
        read.side_effect = RuntimeError("redacted")
        self.assertEqual(dispatch_margin_alerts(), 0)
        send.assert_not_called()
        self.assertTrue(PositionMarginWatch.objects.get().above_threshold)

    @override_settings(POSITION_MARGIN_CALL_ENABLED=False)
    @patch("positions.margin_alerts.get_user_trading_account")
    def test_disabled_monitor_does_no_account_reads(self, read):
        self.assertEqual(dispatch_margin_alerts(), 0)
        read.assert_not_called()

    @patch("positions.margin_alerts.dispatch_margin_alerts", side_effect=RuntimeError("redacted"))
    def test_scheduler_failure_is_isolated(self, dispatch):
        from trading.scheduler import _dispatch_margin_alerts_job
        _dispatch_margin_alerts_job()
        dispatch.assert_called_once()
