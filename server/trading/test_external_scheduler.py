from decimal import Decimal
from unittest.mock import patch

from django.core.cache import cache
from django.test import SimpleTestCase, TestCase, override_settings

from positions.models import Order, OrderStrategySnapshot
from trading import scheduler
from trading.services import reconcile_open_orders_protection, run_strategy_engine
from users.models import User


class ExternalSchedulerTests(SimpleTestCase):
    @override_settings(LEAD_TRADING_ENABLED=False)
    @patch("trading.scheduler._scheduler_heartbeat_job")
    @patch("trading.scheduler.BackgroundScheduler")
    def test_both_modes_keep_ten_second_external_protection_in_separate_workers(self, scheduler_cls, heartbeat):
        with patch.object(scheduler, "_scheduler", None):
            scheduler.start_scheduler()
            registered = {call.kwargs["id"]: call for call in scheduler_cls.return_value.add_job.call_args_list}
            ordinary = registered["reconcile_external_positions"]
            lead = registered["lead_external_positions"]
            for job in (ordinary, lead):
                self.assertEqual(job.args[0], scheduler._reconcile_external_positions_job)
                self.assertEqual(job.kwargs["trigger"].interval.total_seconds(), 10)
                self.assertEqual(job.kwargs["max_instances"], 1)
                self.assertTrue(job.kwargs["coalesce"])
            self.assertEqual(lead.kwargs["kwargs"], {"trading_mode": "lead"})
            self.assertEqual(lead.kwargs["executor"], "lead")
            self.assertEqual(ordinary.kwargs.get("executor", "default"), "default")
            self.assertNotEqual(ordinary.kwargs["next_run_time"], lead.kwargs["next_run_time"])
            scheduler_cls.return_value.start.assert_called_once()

    @patch("trading.external_positions.reconcile_external_positions")
    def test_external_scheduler_forwards_mode_and_isolates_failure(self, reconcile):
        scheduler._reconcile_external_positions_job(trading_mode="lead")
        reconcile.assert_called_once_with(trading_mode="lead")
        reconcile.side_effect = RuntimeError("simulated exchange outage")
        with self.assertLogs("trading.scheduler", level="ERROR"):
            scheduler._reconcile_external_positions_job()


class ExternalLegacyEngineIsolationTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="external-engine@example.com", password="test-password")

    @patch("trading.services.get_user_binding_generation", return_value=("", None))
    @patch("trading.services.get_user_binance_credentials", return_value=None)
    @patch("trading.services._load_protection_account_snapshot", return_value=None)
    def test_legacy_engines_skip_external_orders_even_if_strategy_flag_is_running(self, snapshot, credentials, generation):
        for mode in ("ordinary", "lead"):
            with self.subTest(mode=mode):
                order = Order.objects.create(
                    user=self.user, position_origin=Order.ORIGIN_EXTERNAL, trading_mode=mode,
                    binance_order_id=None, symbol="BTCUSDT", side=0,
                    open_price=Decimal("100"), stop_loss_price=Decimal("90"),
                    stop_loss_amount=Decimal("10"), size=Decimal("1"), leverage=10,
                    strategy_status=Order.STRATEGY_STATUS_RUNNING,
                )
                strategy = OrderStrategySnapshot.objects.create(
                    order=order, user=self.user, strategy_id="unexpected-legacy-flag",
                    strategy_name="legacy flag", strategy_config=[],
                )
                order.strategy_snapshot_id = strategy.id
                order.save(update_fields=["strategy_snapshot_id"])
                self.assertEqual(run_strategy_engine(trading_mode=mode), 0)
                self.assertEqual(reconcile_open_orders_protection(trading_mode=mode), 0)
                generation.assert_not_called()
                credentials.assert_not_called()
                snapshot.assert_not_called()
