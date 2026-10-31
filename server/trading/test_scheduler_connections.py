from unittest.mock import patch

from django.test import SimpleTestCase

from trading import scheduler


class SchedulerConnectionTests(SimpleTestCase):
    JOBS = (
        ("_sync_limit_orders_job", "trading.services.sync_all_pending_limit_orders"),
        ("_run_strategy_engine_job", "trading.services.run_strategy_engine"),
        ("_reconcile_order_protection_job", "trading.services.reconcile_open_orders_protection"),
        ("_reconcile_external_positions_job", "trading.external_positions.reconcile_external_positions"),
        ("_reconcile_stale_open_orders_job", "positions.views.reconcile_stale_open_orders"),
        ("_reconcile_position_settlement_job", "positions.views.reconcile_pending_order_settlements"),
        ("_sync_entry_fees_job", "positions.views.sync_pending_entry_fees"),
        ("_dispatch_trade_notifications_job", "positions.notifications.dispatch_pending_trade_notifications"),
        ("_audit_suspicious_closed_orders_job", "positions.views.audit_suspicious_closed_orders"),
        ("_reconcile_closed_order_exchange_artifacts_job", "positions.views.reconcile_closed_order_exchange_artifacts"),
        ("_trend_signal_scan_job", "market_analysis.trend.scan_trend_signals"),
        ("_purge_tradingview_messages_job", "trading.views.purge_expired_tradingview_messages"),
        ("_warm_market_klines_job", "trading.views.warm_market_kline_caches"),
        ("_prewarm_market_snapshots_job", "trading.snapshot_prewarm.prewarm_public_snapshot_caches"),
        ("_balance_cap_cycle_job", "trading.balance_cap.run_capital_reminder_cycle"),
        ("_sync_transfer_history_job", "accounts.transfer_history.sync_all_transfer_histories"),
    )

    def test_every_business_job_discards_stale_connections_before_and_after_work(self):
        for job_name, service_name in self.JOBS:
            for failure in (False, True):
                with self.subTest(job=job_name, failure=failure), patch(
                    "trading.scheduler.close_old_connections", create=True
                ) as cleanup, patch(service_name) as service, patch(
                    "positions.external_trade_signals.dispatch_pending_external_trade_signals", return_value=0
                ), patch("trading.scheduler.logger"):
                    service.return_value = {"checked": 0} if job_name == "_prewarm_market_snapshots_job" else 0
                    if failure:
                        service.side_effect = RuntimeError("synthetic database disconnect")

                    def execute(*args, **kwargs):
                        self.assertEqual(cleanup.call_count, 1)
                        return service.return_value

                    if not failure:
                        service.side_effect = execute
                    getattr(scheduler, job_name)()
                    self.assertEqual(cleanup.call_count, 2)

    def test_connection_cleanup_also_runs_if_job_escapes_with_base_exception(self):
        with patch("trading.scheduler.close_old_connections", create=True) as cleanup, patch(
            "trading.services.sync_all_pending_limit_orders", side_effect=KeyboardInterrupt
        ), self.assertRaises(KeyboardInterrupt):
            scheduler._sync_limit_orders_job()
        self.assertEqual(cleanup.call_count, 2)

    def test_heartbeat_keeps_redis_only_semantics(self):
        with patch("trading.scheduler.close_old_connections", create=True) as cleanup, patch(
            "common.health.touch_scheduler_heartbeat"
        ) as heartbeat:
            scheduler._scheduler_heartbeat_job()
        heartbeat.assert_called_once()
        cleanup.assert_not_called()
