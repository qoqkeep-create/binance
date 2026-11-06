from contextlib import contextmanager
from threading import Event
from unittest.mock import patch

from django.db import connection
from django.test import TransactionTestCase
from django.test.utils import CaptureQueriesContext

from api_bindings.models import ApiBinding
from mobile.account_events import ingest, reduce_pending
from mobile.commands import execute_account
from mobile.management.commands.mobile_worker import publish_outbox
from mobile.models import AccountFact, AccountInbox, AccountOutbox, AccountWorkerState
from users.models import User


class AccountEventDeliveryTests(TransactionTestCase):
    def setUp(self):
        self.user = User.objects.create_user("delivery@example.invalid", "test-password-only")
        self.binding = ApiBinding.objects.create(user=self.user, alias="test", api_key="placeholder",
                                               secret_key="placeholder", passphrase="")

    @contextmanager
    def lease(self, _binding_id):
        AccountWorkerState.objects.create(binding_id_snapshot=self.binding.pk, fence=1)
        alive = Event()
        alive.set()
        yield 1, alive

    def test_balance_only_update_publishes_fact_without_order_maintenance(self):
        ingest(self.binding, {"e": "ACCOUNT_UPDATE", "T": 10,
                              "a": {"B": [{"a": "USDT", "wb": "50"}]}})
        with patch("mobile.commands.account_lease", side_effect=self.lease), \
             patch("mobile.account_events.reconcile_changed_account") as reconcile:
            execute_account(self.binding.pk)
        reconcile.assert_not_called()
        self.assertEqual(AccountFact.objects.get().payload["wb"], "50")
        self.assertEqual(AccountOutbox.objects.get().channel, "trading.account")
        self.assertFalse(AccountInbox.objects.filter(processed=False).exists())

    def test_position_order_fill_and_recovery_still_require_maintenance(self):
        events = [
            {"e": "ACCOUNT_UPDATE", "T": 10, "a": {"B": [{"a": "USDT", "wb": "50"}],
                         "P": [{"s": "BTCUSDT", "ps": "LONG", "pa": "0.1"}]}},
            {"e": "ORDER_TRADE_UPDATE", "T": 20, "o": {"s": "BTCUSDT", "i": 11, "X": "NEW"}},
            {"e": "TRADE_LITE", "T": 30, "s": "BTCUSDT", "t": 12},
            {"e": "ALGO_UPDATE", "T": 40, "o": {"s": "BTCUSDT", "aid": 13}},
            {"e": "RECONCILE", "T": 50},
        ]
        for event in events:
            with self.subTest(kind=event["e"]):
                ingest(self.binding, event)
                self.assertTrue(reduce_pending(self.binding.pk))

    def test_stale_position_does_not_trigger_another_reconcile(self):
        event = {"e": "ACCOUNT_UPDATE", "T": 20,
                 "a": {"P": [{"s": "BTCUSDT", "ps": "LONG", "pa": "0.1"}]}}
        ingest(self.binding, event)
        self.assertTrue(reduce_pending(self.binding.pk))
        ingest(self.binding, {**event, "T": 10})
        self.assertFalse(reduce_pending(self.binding.pk))

    def add_outbox(self, count):
        return AccountOutbox.objects.bulk_create([
            AccountOutbox(user=self.user, trading_mode="lead" if i % 2 else "ordinary",
                          channel="trading.order" if i % 2 else "trading.position",
                          event_key=f"event-{i}", payload={"number": i}) for i in range(count)
        ])

    def test_batch_is_ordered_scoped_and_marked_delivered_with_one_update(self):
        rows = self.add_outbox(3)
        with patch("market_stream.bus.publish_private_batch") as publish, \
             CaptureQueriesContext(connection) as queries:
            publish_outbox()
        publish.assert_called_once()
        self.assertEqual(publish.call_args.args[0], [
            (row.channel, row.event_key, row.payload, row.user_id, row.trading_mode) for row in rows
        ])
        updates = [query for query in queries if query["sql"].lstrip().upper().startswith("UPDATE")]
        self.assertEqual(len(updates), 1)
        self.assertEqual(AccountOutbox.objects.filter(published_at__isnull=False).count(), 3)

    def test_failed_batch_stays_pending_for_at_least_once_retry(self):
        self.add_outbox(3)
        with patch("market_stream.bus.publish_private_batch", side_effect=ConnectionError), \
             self.assertRaises(ConnectionError):
            publish_outbox()
        self.assertEqual(AccountOutbox.objects.filter(published_at__isnull=True).count(), 3)

    def test_one_delivery_pass_is_bounded_and_empty_queue_does_no_redis_work(self):
        self.add_outbox(101)
        with patch("market_stream.bus.publish_private_batch") as publish:
            publish_outbox()
            self.assertEqual(len(publish.call_args.args[0]), 100)
            self.assertEqual(AccountOutbox.objects.filter(published_at__isnull=True).count(), 1)
            publish_outbox()
            publish.reset_mock()
            publish_outbox()
            publish.assert_not_called()
