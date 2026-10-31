from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from django.db import connection, transaction
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework.test import APITestCase

from api_bindings.models import ApiBinding
from positions.models import Order, OrderStrategyLog, OrderStrategySnapshot, TradeNotificationEvent, TradeOperationLog
from positions.operation_logs import get_operation_logs, record_operation
from users.models import User


def make_order(user, *, fingerprint="a" * 64, mode="ordinary", **overrides):
    fields = dict(
        user=user, api_key_fingerprint=fingerprint, trading_mode=mode,
        binance_order_id=f"test-entry-{uuid4().hex[:12]}", symbol="BTCUSDT", side=0,
        open_price="100", stop_loss_price="90", stop_loss_amount="10", size="1", leverage=10,
    )
    fields.update(overrides)
    return Order.objects.create(**fields)


def make_binding(user, *, fingerprint="a" * 64, mode="ordinary"):
    return ApiBinding.objects.create(
        user=user, trading_mode=mode, api_key_fingerprint=fingerprint,
        api_key="unused-test-ciphertext", secret_key="unused-test-ciphertext", passphrase="",
        alias="test", status=1,
    )


def strategy_log(order, message="达到 2R，准备移动止损"):
    snapshot = OrderStrategySnapshot.objects.create(
        user=order.user, order=order, strategy_id="test", strategy_name="test", strategy_config=[],
    )
    return OrderStrategyLog.objects.create(order=order, snapshot=snapshot, behavior_desc=message)


def trade_event(order, kind=TradeNotificationEvent.TYPE_OPEN, **overrides):
    fields = dict(order=order, event_key=f"test:{order.pk}:{kind}", event_type=kind, title="test", content="test")
    fields.update(overrides)
    return TradeNotificationEvent.objects.create(**fields)


class OperationLogWriterTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(email="writer@example.com", password="test-password")
        self.order = make_order(self.user)

    def write(self, **overrides):
        fields = dict(action="stop_restore", status="pending", message="止损提交待确认")
        fields.update(overrides)
        return record_operation(self.order, **fields)

    def test_dedupes_unchanged_state_but_preserves_real_transitions(self):
        first = self.write(event_key="attempt-one")
        duplicate = self.write(event_key="attempt-two")
        self.assertEqual(first.pk, duplicate.pk)
        self.write(status="success", message="止损补挂已确认")
        self.write(event_key="attempt-three")
        self.assertEqual(TradeOperationLog.objects.count(), 3)

    def test_event_key_is_hashed_and_scoped_by_order_action_and_actor(self):
        first = self.write(event_key="sensitive-request-key", dedupe=False)
        self.assertEqual(self.write(event_key="sensitive-request-key", dedupe=False).pk, first.pk)
        self.write(event_key="sensitive-request-key", actor="user", dedupe=False)
        self.write(event_key="sensitive-request-key", action="close", dedupe=False)
        other = make_order(self.user)
        record_operation(other, action="stop_restore", status="pending", message="止损提交待确认", event_key="sensitive-request-key")
        self.assertEqual(TradeOperationLog.objects.count(), 4)
        self.assertEqual(len(first.event_key), 64)
        self.assertNotIn("sensitive-request-key", first.event_key)

    def test_database_error_rolls_back_savepoint_without_poisoning_caller(self):
        existing = self.write()
        original_create = TradeOperationLog.objects.create
        with transaction.atomic():
            self.order.leverage = 5
            self.order.save(update_fields=["leverage"])
            with patch("positions.operation_logs.TradeOperationLog.objects.create", side_effect=lambda **fields: original_create(pk=existing.pk, **fields)):
                self.assertIsNone(self.write(dedupe=False))
            self.order.leverage = 8
            self.order.save(update_fields=["leverage"])
        self.order.refresh_from_db()
        self.assertEqual(self.order.leverage, 8)
        self.assertEqual(TradeOperationLog.objects.count(), 1)

    def test_redacts_sensitive_material_before_persistence(self):
        row = self.write(message="api_key=secret-one signature=secret-two https://example.com/private?token=secret-three owner@example.com address=TAbcdefghijklmnopqrstuvwxyz12345678 " + "a" * 64)
        for secret in ("secret-one", "secret-two", "secret-three", "owner@example.com", "TAbcdefghijklmnopqrstuvwxyz12345678", "a" * 64):
            self.assertNotIn(secret, row.message)
        self.assertLessEqual(len(row.message), 500)

    def test_invalid_classification_and_general_failure_are_nonfatal(self):
        self.assertIsNone(self.write(status="sent"))
        with patch("positions.operation_logs.TradeOperationLog.objects.create", side_effect=RuntimeError("secret")):
            self.assertIsNone(self.write())


class OperationLogFeedTests(APITestCase):
    URL = "/v1/account/operation-logs"

    def setUp(self):
        self.user = User.objects.create_user(email="feed@example.com", password="test-password")
        self.binding = make_binding(self.user)
        self.order = make_order(self.user)
        self.client.force_authenticate(self.user)

    def add_log(self, order=None, **overrides):
        return record_operation(order or self.order, action="stop_restore", status="success", message="止损补挂已确认", dedupe=False, **overrides)

    def test_read_only_feed_never_contacts_exchange_or_decrypts_credentials(self):
        self.add_log()
        strategy_log(self.order)
        trade_event(self.order)
        with patch("common.binance.BinanceFuturesClient._request", side_effect=AssertionError("must not contact Binance")) as exchange, patch("api_bindings.services.get_user_binance_credentials", side_effect=AssertionError("must not decrypt")), CaptureQueriesContext(connection) as queries:
            response = self.client.get(self.URL)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data["data"]["records"]), 3)
        exchange.assert_not_called()
        self.assertTrue(all(not query["sql"].lstrip().upper().startswith(("INSERT", "UPDATE", "DELETE")) for query in queries))
        self.assertNotIn(self.binding.api_key_fingerprint, str(response.data))

    def test_owner_mode_and_key_are_strictly_isolated_in_all_sources(self):
        other_user = User.objects.create_user(email="other@example.com", password="test-password")
        hidden = [
            make_order(other_user), make_order(self.user, mode="lead"),
            make_order(self.user, fingerprint="b" * 64), make_order(self.user, fingerprint=None),
        ]
        for order in [self.order, *hidden]:
            self.add_log(order)
            strategy_log(order)
            trade_event(order)
        result = get_operation_logs(self.user)
        self.assertEqual(len(result["records"]), 3)
        self.assertEqual({row["order_id"] for row in result["records"]}, {self.order.pk})

    def test_no_binding_or_missing_fingerprint_returns_empty(self):
        self.add_log()
        self.binding.api_key_fingerprint = None
        self.binding.save(update_fields=["api_key_fingerprint"])
        self.assertEqual(get_operation_logs(self.user)["records"], [])
        self.binding.delete()
        self.assertEqual(get_operation_logs(self.user)["records"], [])

    def test_lead_mode_uses_only_its_own_binding(self):
        make_binding(self.user, fingerprint="c" * 64, mode="lead")
        lead = make_order(self.user, fingerprint="c" * 64, mode="lead", side=1, position_origin=Order.ORIGIN_EXTERNAL)
        self.add_log()
        self.add_log(lead)
        result = get_operation_logs(self.user, trading_mode="lead")
        self.assertEqual(len(result["records"]), 1)
        self.assertEqual(result["records"][0]["side"], "short")
        self.assertEqual(result["records"][0]["position_origin"], Order.ORIGIN_EXTERNAL)

    def test_cursor_pages_all_sources_at_identical_timestamps_without_duplicates(self):
        at = timezone.now() - timedelta(days=1)
        expected_ids = set()
        for index in range(9):
            order = make_order(self.user, binance_order_id=f"entry-{index}")
            for kind, row in (("operation", self.add_log(order)), ("strategy", strategy_log(order)), ("trade", trade_event(order))):
                type(row).objects.filter(pk=row.pk).update(created_at=at)
                expected_ids.add(f"{kind}:{row.pk}")
        cursor, seen = "", []
        while True:
            with CaptureQueriesContext(connection) as queries:
                page = get_operation_logs(self.user, limit=4, cursor=cursor)
            source_queries = [query["sql"] for query in queries if "INNER JOIN" in query["sql"]]
            self.assertEqual(len(source_queries), 3)
            self.assertTrue(all("LIMIT 5" in query for query in source_queries))
            seen += [row["id"] for row in page["records"]]
            if not page["has_more"]:
                self.assertIsNone(page["next_cursor"])
                break
            cursor = page["next_cursor"]
        self.assertEqual(set(seen), expected_ids)
        self.assertEqual(len(seen), len(expected_ids))

    def test_cursor_is_validated_and_bound_to_account_scope(self):
        self.add_log()
        self.add_log()
        cursor = get_operation_logs(self.user, limit=1)["next_cursor"]
        self.binding.api_key_fingerprint = "d" * 64
        self.binding.save(update_fields=["api_key_fingerprint"])
        with self.assertRaisesMessage(ValueError, "游标无效"):
            get_operation_logs(self.user, cursor=cursor)
        for params in ({"cursor": "garbage"}, {"limit": 0}, {"limit": 51}, {"limit": "bad"}):
            self.assertEqual(self.client.get(self.URL, params).status_code, 400)

    def test_notification_delivery_status_does_not_define_trade_success(self):
        trade_event(self.order, status=TradeNotificationEvent.STATUS_FAILED)
        pending_close = trade_event(self.order, TradeNotificationEvent.TYPE_STOP_LOSS, status=TradeNotificationEvent.STATUS_SENT)
        rows = get_operation_logs(self.user)["records"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "success")
        self.order.status, self.order.closed_at = 1, timezone.now()
        self.order.save(update_fields=["status", "closed_at"])
        rows = get_operation_logs(self.user)["records"]
        close = next(row for row in rows if row["id"] == f"trade:{pending_close.pk}")
        self.assertEqual(close["status"], "success")
        self.assertEqual(close["action"], "close_confirmed")
        self.assertIn("来源待核实", close["message"])

    def test_web_confirmed_close_without_order_id_preserves_explicit_classification(self):
        self.order.status, self.order.closed_at = 1, timezone.now()
        self.order.settlement_status = Order.SETTLEMENT_STATUS_ESTIMATED
        self.order.save(update_fields=["status", "closed_at", "settlement_status"])
        for confidence, event_type in ((3, TradeNotificationEvent.TYPE_STOP_LOSS), (4, TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT)):
            event = trade_event(self.order, event_type, context={"classification_confidence": confidence})
            rows = get_operation_logs(self.user)["records"]
            close = next(row for row in rows if row["id"] == f"trade:{event.pk}")
            self.assertEqual(close["status"], "success")
            self.assertEqual(close["action"], event_type)
            self.assertNotIn("待核实", close["message"])

    def test_confirmed_manual_lifecycle_close_can_be_shown_without_fabricated_fill(self):
        self.order.status, self.order.closed_at = 1, timezone.now()
        self.order.external_close_request = {"status": "confirmed"}
        self.order.save(update_fields=["status", "closed_at", "external_close_request"])
        event = trade_event(self.order, TradeNotificationEvent.TYPE_STOP_LOSS, status="pending", context={"classification_confidence": 100})
        rows = get_operation_logs(self.user)["records"]
        self.assertEqual(rows[0]["id"], f"trade:{event.pk}")
        self.assertEqual(rows[0]["message"], "止损平仓已确认")

    def test_legacy_text_is_redacted_and_historical_snapshots_are_retained(self):
        legacy = strategy_log(self.order, "用户取消策略 owner@example.com https://example.com/secret")
        legacy.error = "api_key=private-key address=wallet-private-value"
        legacy.save(update_fields=["error"])
        strategy_log(self.order, "新策略绑定成功")
        row = self.add_log()
        TradeOperationLog.objects.filter(pk=row.pk).update(message="secret_key=legacy-secret other@example.com")
        records = get_operation_logs(self.user)["records"]
        text = str(records)
        for secret in ("owner@example.com", "https://example.com/secret", "private-key", "wallet-private-value", "legacy-secret", "other@example.com"):
            self.assertNotIn(secret, text)
        self.assertEqual(sum(record["source"] == "strategy" for record in records), 2)

    def test_anonymous_access_is_rejected(self):
        self.client.force_authenticate(user=None)
        self.assertEqual(self.client.get(self.URL).status_code, 401)
