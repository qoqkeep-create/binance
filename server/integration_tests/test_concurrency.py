import os
import threading
import unittest
import subprocess
import sys
from unittest.mock import MagicMock
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal

from django.core.cache import cache, caches
from django.db import IntegrityError, close_old_connections, connection, transaction
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase, override_settings

from common.binance_rate_limit import (
    RequestBudgetExceeded,
    RequestBudgetSpec,
    RequestPriority,
    reserve_request_budget,
)
from positions.models import Order, TradeNotificationEvent
from positions.notifications import enqueue_close_notification
from trading.locks import trading_activity_lock
from trading.models import CapitalSweep, TradeOpenRequest
from trading.open_requests import resolve_open_request
from users.models import User
from api_bindings.models import ApiBinding
from api_bindings.context import build_trading_account_identity
from api_bindings.services import build_api_key_fingerprint
from trading.balance_cap import normalize_capital, refresh_capital_precheck
from common.binance_rate_limit import _clear_local_budget_state


RUN_INTEGRATION_TESTS = os.getenv("RUN_INTEGRATION_TESTS") == "1"


class ProductionConcurrencyContractTests(TransactionTestCase):
    databases = {"default"}

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        if not RUN_INTEGRATION_TESTS:
            raise unittest.SkipTest(
                "set RUN_INTEGRATION_TESTS=1 with isolated MySQL and Redis"
            )

    def setUp(self):
        self.assertEqual(connection.vendor, "mysql", "Requires isolated MySQL")
        self.assertIn("redis", type(caches["default"]).__module__, "Requires isolated Redis")
        cache.clear()
        _clear_local_budget_state()
        self.user = User.objects.create_user(
            email="concurrency@example.com",
            password="test-only-password",
        )

    def _run_two_workers(self, worker, worker_args=((), ())):
        barrier = threading.Barrier(2)

        def synchronized_worker(args):
            close_old_connections()
            try:
                barrier.wait(timeout=5)
                return worker(*args)
            finally:
                close_old_connections()

        with ThreadPoolExecutor(max_workers=2) as executor:
            return list(executor.map(synchronized_worker, worker_args))

    def test_mysql_allows_only_one_active_capital_sweep(self):
        def create_sweep():
            user = User.objects.get(pk=self.user.pk)
            try:
                sweep = CapitalSweep.objects.create(
                    user=user,
                    amount=Decimal("1"),
                    target_balance=Decimal("500"),
                )
                return ("created", sweep.pk)
            except IntegrityError:
                return ("conflict", None)

        results = self._run_two_workers(create_sweep)

        self.assertEqual([result[0] for result in results].count("created"), 1)
        self.assertEqual([result[0] for result in results].count("conflict"), 1)
        self.assertEqual(CapitalSweep.objects.filter(user=self.user, active_slot=1).count(), 1)

    def _external_order_fields(self, **overrides):
        return {
            "user_id": self.user.pk,
            "api_key_fingerprint": "external-integration-account",
            "trading_mode": "ordinary",
            "position_origin": Order.ORIGIN_EXTERNAL,
            "binance_order_id": None,
            "symbol": "BTCUSDT", "side": 0,
            "open_price": Decimal("100"), "stop_loss_price": Decimal("90"),
            "stop_loss_amount": Decimal("10"), "size": Decimal("1"), "leverage": 1,
            **overrides,
        }

    def test_mysql_external_active_slot_rejects_concurrent_duplicate_adoption(self):
        slot = "external-integration-active-slot"

        def adopt():
            try:
                order = Order.objects.create(**self._external_order_fields(external_active_key=slot))
                return ("created", order.pk)
            except IntegrityError:
                return ("conflict", None)

        results = self._run_two_workers(adopt)

        self.assertEqual([status for status, _ in results].count("created"), 1)
        self.assertEqual([status for status, _ in results].count("conflict"), 1)
        self.assertEqual(Order.objects.filter(external_active_key=slot, status=0).count(), 1)

    def test_mysql_external_slot_is_reusable_after_transactional_close(self):
        slot = "external-integration-reopen-slot"
        previous = Order.objects.create(**self._external_order_fields(external_active_key=slot))
        with transaction.atomic():
            Order.objects.filter(pk=previous.pk, status=0).update(
                status=1, external_active_key=None, exchange_size=Decimal("0"),
            )
        reopened = Order.objects.create(**self._external_order_fields(external_active_key=slot))

        previous.refresh_from_db()
        self.assertEqual(previous.status, 1)
        self.assertIsNone(previous.external_active_key)
        self.assertNotEqual(previous.pk, reopened.pk)
        self.assertEqual(Order.objects.filter(external_active_key=slot, status=0).count(), 1)
        self.assertEqual(Order.objects.filter(position_origin=Order.ORIGIN_EXTERNAL).count(), 2)

    def test_mysql_null_entry_id_allows_concurrent_external_history_rows(self):
        def create_history():
            return Order.objects.create(**self._external_order_fields(
                status=1, external_active_key=None,
            )).pk

        order_ids = self._run_two_workers(create_history)

        self.assertEqual(len(set(order_ids)), 2)
        self.assertEqual(Order.objects.filter(
            api_key_fingerprint="external-integration-account", symbol="BTCUSDT",
            binance_order_id__isnull=True, external_active_key__isnull=True, status=1,
        ).count(), 2)

    def test_previous_order_orm_can_write_after_external_protection_migration(self):
        executor = MigrationExecutor(connection)
        old_apps = executor.loader.project_state([("positions", "0026_trading_modes")]).apps
        old_order_model = old_apps.get_model("positions", "Order")
        old_order = old_order_model.objects.create(
            user_id=self.user.pk, api_key_fingerprint="old-worker-account",
            binance_order_id="old-worker-external-migration", symbol="BTCUSDT", side=0,
            open_price=100, stop_loss_price=90, stop_loss_amount=10, size=1, leverage=1,
        )
        current = Order.objects.get(pk=old_order.pk)
        self.assertEqual(current.position_origin, Order.ORIGIN_WEB)
        self.assertIsNone(current.external_active_key)
        self.assertEqual(current.external_stop_request, {})
        self.assertEqual(current.external_close_request, {})

        old_order.stop_loss_price = Decimal("95")
        old_order.save(update_fields=["stop_loss_price"])
        current.refresh_from_db()
        self.assertEqual(current.stop_loss_price, Decimal("95"))
        self.assertEqual(current.position_origin, Order.ORIGIN_WEB)
        self.assertEqual(current.external_stop_request, {})
        self.assertEqual(current.external_close_request, {})

    def test_receipt_refresh_and_execution_share_the_trading_activity_lock(self):
        fingerprint = build_api_key_fingerprint("integration-only-api-key")
        ApiBinding.objects.create(
            user=self.user, api_key="integration-only-api-key", secret_key="integration-only-secret",
            api_key_fingerprint=fingerprint, status=1,
        )
        identity = build_trading_account_identity(user_id=self.user.id, api_key_fingerprint=fingerprint)
        client = MagicMock()
        client.credentials.api_key = "integration-only-api-key"
        with trading_activity_lock(identity, timeout=10) as locked:
            self.assertTrue(locked)
            with self.assertRaisesMessage(ValueError, "正在处理中"):
                refresh_capital_precheck(self.user, client)
            with self.assertRaisesMessage(ValueError, "正在处理中"):
                normalize_capital(self.user, client, "normalization_required")
        client.get_balance.assert_not_called()
        client.transfer_spot_to_master.assert_not_called()

    def test_mysql_open_request_is_idempotent_under_concurrent_creation(self):
        payload = {"symbol": "BTCUSDT", "stop_loss_price": "90000"}

        def create_request():
            user = User.objects.get(pk=self.user.pk)
            resolution = resolve_open_request(
                user=user,
                symbol="BTCUSDT",
                client_request_id="integration-request",
                client_order_id="rtmo-integration-request",
                request_payload=payload,
            )
            return resolution.request.pk

        request_ids = self._run_two_workers(create_request)

        self.assertEqual(len(set(request_ids)), 1)
        self.assertEqual(TradeOpenRequest.objects.count(), 1)
        self.assertEqual(Order.objects.count(), 0)

    def test_redis_lock_is_shared_between_workers(self):
        first_entered = threading.Event()
        release_first = threading.Event()

        def hold_lock():
            with trading_activity_lock("integration-account", timeout=10) as locked:
                first_entered.set()
                release_first.wait(timeout=5)
                return locked

        with ThreadPoolExecutor(max_workers=1) as executor:
            first = executor.submit(hold_lock)
            self.assertTrue(first_entered.wait(timeout=5))
            with trading_activity_lock("integration-account", timeout=10) as second_locked:
                self.assertFalse(second_locked)
            release_first.set()
            self.assertTrue(first.result(timeout=5))

    def test_mysql_close_notification_keeps_highest_concurrent_confidence(self):
        order = Order.objects.create(
            user=self.user,
            binance_order_id="concurrent-close-notification",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("10"),
            size=Decimal("1"),
            leverage=1,
        )

        def enqueue(confidence):
            current_order = Order.objects.get(pk=order.pk)
            event_type = (
                TradeNotificationEvent.TYPE_STOP_LOSS
                if confidence == 3
                else TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT
            )
            event = enqueue_close_notification(
                current_order,
                event_type=event_type,
                trigger_price=Decimal("90") if confidence == 3 else Decimal("105"),
                classification_confidence=confidence,
            )
            return event.pk if event else None

        event_ids = self._run_two_workers(enqueue, ((1,), (3,)))

        self.assertEqual(len(set(event_ids)), 1)
        event = TradeNotificationEvent.objects.get(pk=event_ids[0])
        self.assertEqual(event.event_type, TradeNotificationEvent.TYPE_STOP_LOSS)
        self.assertEqual(event.context["classification_confidence"], 3)

    @override_settings(
        BINANCE_FUTURES_WEIGHT_LIMIT_PER_MINUTE=10,
        BINANCE_NORMAL_WEIGHT_RATIO=1.0,
    )
    def test_redis_request_budget_is_shared_between_workers(self):
        spec = RequestBudgetSpec(
            scope="futures",
            priority=RequestPriority.NORMAL,
            weight=6,
            counts_as_order=False,
        )

        def reserve():
            try:
                reserve_request_budget(spec, now=120.0)
                return "reserved"
            except RequestBudgetExceeded:
                return "limited"

        results = self._run_two_workers(reserve)

        self.assertEqual(results.count("reserved"), 1)
        self.assertEqual(results.count("limited"), 1)

    def _redis_process(self, operation, identity):
        result = subprocess.run(
            [sys.executable, "-m", "integration_tests.redis_worker", operation, identity],
            check=True, capture_output=True, text=True, timeout=20,
        )
        return result.stdout.strip().splitlines()[-1]

    def test_redis_lock_is_shared_across_processes_and_separates_modes(self):
        ordinary = build_trading_account_identity(user_id=self.user.pk, api_key_fingerprint="test-fingerprint")
        lead = build_trading_account_identity(user_id=self.user.pk, api_key_fingerprint="test-fingerprint", trading_mode="lead")
        with trading_activity_lock(ordinary, timeout=30) as locked:
            self.assertTrue(locked)
            self.assertEqual(self._redis_process("lock", ordinary), "blocked")
            self.assertEqual(self._redis_process("lock", lead), "acquired")
        self.assertEqual(self._redis_process("lock", ordinary), "acquired")

    def test_lead_short_budget_is_shared_across_processes(self):
        spec = RequestBudgetSpec("futures", RequestPriority.NORMAL, 1, True)
        for _ in range(14):
            reserve_request_budget(spec, account_api_key="test-lead-key", lead_trading=True, now=120)
        self.assertEqual(self._redis_process("budget", "test-lead-key"), "limited")
        self.assertEqual(self._redis_process("budget", "test-other-key"), "reserved")

    def test_mysql_dual_bindings_keep_one_binding_per_mode(self):
        ApiBinding.objects.create(user=self.user, alias="ordinary", api_key="test", secret_key="test")
        def bind():
            try:
                return ApiBinding.objects.create(user_id=self.user.pk, trading_mode="lead", alias="lead", api_key="test", secret_key="test").pk
            except IntegrityError:
                return None
        results = self._run_two_workers(bind)
        self.assertEqual(sum(value is not None for value in results), 1)
        self.assertEqual(ApiBinding.objects.filter(user=self.user).count(), 2)

    def test_previous_code_can_write_during_additive_migration_rollout(self):
        executor = MigrationExecutor(connection)
        old_apps = executor.loader.project_state([
            ("api_bindings", "0007_unique_api_key_fingerprint"),
            ("positions", "0025_order_stop_loss_order_created_at"),
            ("trading", "0014_capitalsweep_api_key_fingerprint"),
        ]).apps
        old_binding = old_apps.get_model("api_bindings", "ApiBinding").objects.create(
            user_id=self.user.pk, api_key="test", secret_key="test", alias="old-worker",
        )
        old_order = old_apps.get_model("positions", "Order").objects.create(
            user_id=self.user.pk, binance_order_id="old-worker", symbol="BTCUSDT", side=0,
            open_price=100, stop_loss_price=90, stop_loss_amount=10, size=1, leverage=1,
        )
        old_request = old_apps.get_model("trading", "TradeOpenRequest").objects.create(
            user_id=self.user.pk, symbol="BTCUSDT", client_request_id="old-worker", client_order_id="old-worker",
        )
        self.assertEqual(ApiBinding.objects.get(pk=old_binding.pk).trading_mode, "ordinary")
        self.assertEqual(Order.objects.get(pk=old_order.pk).trading_mode, "ordinary")
        self.assertEqual(TradeOpenRequest.objects.get(pk=old_request.pk).trading_mode, "ordinary")
