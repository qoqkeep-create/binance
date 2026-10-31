import os
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal

from django.db import close_old_connections, connection
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase

from positions.models import Order, TradeOperationLog
from positions.operation_logs import record_operation
from users.models import User


@unittest.skipUnless(
    os.getenv("RUN_INTEGRATION_TESTS") == "1",
    "set RUN_INTEGRATION_TESTS=1 with isolated MySQL",
)
class OperationLogMySQLContractTests(TransactionTestCase):
    databases = {"default"}

    def setUp(self):
        self.assertEqual(connection.vendor, "mysql", "Requires isolated MySQL")
        self.user = User.objects.create_user(
            email="operation-log-integration@example.com",
            password="test-only-password",
        )
        self.order = Order.objects.create(**self.order_fields("log-test-order"))

    def order_fields(self, exchange_id):
        return {
            "user_id": self.user.pk,
            "api_key_fingerprint": "operation-log-test-account",
            "trading_mode": "ordinary",
            "binance_order_id": exchange_id,
            "symbol": "BTCUSDT",
            "side": 0,
            "open_price": Decimal("100"),
            "stop_loss_price": Decimal("90"),
            "stop_loss_amount": Decimal("10"),
            "size": Decimal("1"),
            "leverage": 1,
        }

    def test_same_event_key_is_idempotent_across_two_mysql_connections(self):
        barrier = threading.Barrier(2)

        def worker(_index):
            close_old_connections()
            try:
                order = Order.objects.get(pk=self.order.pk)
                barrier.wait(timeout=5)
                event = record_operation(
                    order,
                    action="external_stop",
                    status="success",
                    message="手动仓止损已确认有效",
                    event_key="same-confirmed-stop",
                )
                return event.pk if event else None
            finally:
                close_old_connections()

        with ThreadPoolExecutor(max_workers=2) as executor:
            ids = list(executor.map(worker, range(2)))
        self.assertNotIn(None, ids)
        self.assertEqual(ids[0], ids[1])
        self.assertEqual(TradeOperationLog.objects.filter(order=self.order).count(), 1)

    def test_distinct_events_without_an_event_key_share_nullable_unique_column(self):
        events = [
            record_operation(
                self.order,
                action=action,
                status=status,
                message=message,
            )
            for action, status, message in (
                ("external_stop", "pending", "止损提交结果待核对"),
                ("external_stop", "success", "止损保护已确认"),
                ("external_cleanup", "pending", "旧保护单待清理"),
            )
        ]
        self.assertTrue(all(event is not None for event in events))
        self.assertEqual(len({event.pk for event in events}), 3)
        self.assertEqual(
            TradeOperationLog.objects.filter(order=self.order, event_key__isnull=True).count(),
            3,
        )

    def test_0027_order_orm_can_create_and_update_with_0028_log_table(self):
        self.assertIn(TradeOperationLog._meta.db_table, connection.introspection.table_names())
        executor = MigrationExecutor(connection)
        old_apps = executor.loader.project_state(
            [("positions", "0027_external_position_protection")]
        ).apps
        old_order_model = old_apps.get_model("positions", "Order")
        old_order = old_order_model.objects.create(**self.order_fields("old-0027-worker"))
        old_order.stop_loss_price = Decimal("95")
        old_order.save(update_fields=["stop_loss_price"])

        current = Order.objects.get(pk=old_order.pk)
        self.assertEqual(current.stop_loss_price, Decimal("95"))
        self.assertEqual(current.position_origin, Order.ORIGIN_WEB)
        self.assertEqual(current.external_stop_request, {})
        self.assertEqual(current.external_close_request, {})
        self.assertFalse(TradeOperationLog.objects.filter(order=current).exists())
        event = record_operation(
            current,
            action="stop_confirmed",
            status="success",
            message="止损保护已确认",
        )
        self.assertIsNotNone(event)
        self.assertEqual(event.order_id, old_order.pk)
