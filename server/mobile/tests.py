import json
from unittest.mock import patch

from django.test import TestCase, override_settings
from rest_framework.response import Response
from rest_framework.test import APIClient

from api_bindings.models import ApiBinding
from market_stream.websocket import matches, validate_subscription
from mobile.account_events import ingest, reduce_pending
from mobile.commands import submit
from mobile.models import AccountFact, AccountInbox, TradingCommand
from users.models import User


class CommandSafetyTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user("mobile-test@example.invalid", "test-password-only")
        self.binding = ApiBinding.objects.create(user=self.user, alias="test", api_key="encrypted-placeholder",
                    secret_key="encrypted-placeholder", passphrase="", api_key_fingerprint="a"*64)

    def test_idempotency_is_durable_and_payload_change_is_rejected(self):
        command = submit(self.user, "ordinary", "open", {"symbol": "BTCUSDT"}, "request-1")
        again = submit(self.user, "ordinary", "open", {"symbol": "BTCUSDT"}, "request-1")
        self.assertEqual(command.pk, again.pk)
        self.assertEqual(TradingCommand.objects.count(), 1)
        self.assertEqual(command.payload["client_request_id"], str(command.pk))
        with self.assertRaisesMessage(ValueError, "不同请求"):
            submit(self.user, "ordinary", "open", {"symbol": "ETHUSDT"}, "request-1")

    def test_maker_status_read_can_run_while_another_command_is_unknown(self):
        unknown = submit(self.user, "ordinary", "open", {}, "unknown-open")
        unknown.status = "UNKNOWN"
        unknown.save(update_fields=["status"])

        status = submit(self.user, "ordinary", "maker-status", {
            "client_request_id": "maker-request",
        }, "maker-status-1")

        self.assertEqual(status.action, "maker-status")
        self.assertEqual(status.status, "PENDING")

    def test_new_open_stays_blocked_by_unknown_maker_status(self):
        unknown = submit(self.user, "ordinary", "maker-status", {}, "unknown-maker-status")
        unknown.status = "UNKNOWN"
        unknown.save(update_fields=["status"])

        with self.assertRaisesMessage(ValueError, "结果未知"):
            submit(self.user, "ordinary", "open", {}, "new-risk")

    def test_missing_other_mode_binding_never_uses_ordinary_key(self):
        with override_settings(LEAD_TRADING_ENABLED=True):
            with self.assertRaisesMessage(ValueError, "当前模式"):
                submit(self.user, "lead", "open", {}, "lead-1")

    def test_detail_is_scoped_to_user_and_mode(self):
        command = submit(self.user, "ordinary", "open", {}, "request-1")
        client = APIClient()
        client.force_authenticate(self.user)
        self.assertEqual(client.get(f"/api/commands/{command.pk}", HTTP_X_TRADING_MODE="lead").status_code, 404)
        other = User.objects.create_user("another@example.invalid", "test-password-only")
        client.force_authenticate(other)
        self.assertEqual(client.get(f"/api/commands/{command.pk}").status_code, 404)

    def test_duplicate_account_event_and_older_fact_do_not_regress(self):
        event = {"e": "ACCOUNT_UPDATE", "T": 200, "E": 210,
                 "a": {"P": [{"s": "BTCUSDT", "ps": "LONG", "pa": "0.1"}]}}
        self.assertTrue(ingest(self.binding, event))
        self.assertFalse(ingest(self.binding, event))
        self.assertTrue(reduce_pending(self.binding.pk))
        older = {**event, "T": 100, "a": {"P": [{"s": "BTCUSDT", "ps": "LONG", "pa": "0.01"}]}}
        ingest(self.binding, older)
        reduce_pending(self.binding.pk)
        self.assertEqual(AccountFact.objects.get().payload["pa"], "0.1")
        self.assertEqual(AccountInbox.objects.filter(processed=False).count(), 0)

    def test_control_message_with_listen_key_is_never_stored(self):
        self.assertFalse(ingest(self.binding, {"e": "listenKeyExpired", "listenKey": "test-placeholder"}))
        self.assertEqual(AccountInbox.objects.count(), 0)

    def test_private_event_cannot_cross_user_or_mode(self):
        channel, filters = validate_subscription({"channel": "trading.order"})
        payload = {"channel": channel, "_user": str(self.user.pk), "_mode": "ordinary", "data": {}}
        self.assertTrue(matches(payload, {channel: filters}, str(self.user.pk), "ordinary"))
        self.assertFalse(matches(payload, {channel: filters}, "another", "ordinary"))
        self.assertFalse(matches(payload, {channel: filters}, str(self.user.pk), "lead"))


class MobileAuthTests(TestCase):
    def test_original_login_limits_and_agreement_are_retained(self):
        User.objects.create_user("auth-test@example.invalid", "test-password-only")
        client = APIClient()
        response = client.post("/api/auth/login", {"account": "auth-test@example.invalid", "password": "test-password-only"}, format="json")
        self.assertNotEqual(response.data["code"], 200)
        response = client.post("/api/auth/login", {"account": "auth-test@example.invalid", "password": "test-password-only", "agreed": True}, format="json")
        self.assertEqual(response.data["code"], 200)
        token = response.data["data"]["accessToken"]
        client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
        self.assertEqual(client.get("/api/auth/me").data["data"]["email"], "auth-test@example.invalid")

class WorkerRecoveryTests(CommandSafetyTests):
    def lease(self, _binding_id):
        from contextlib import contextmanager
        from threading import Event
        from mobile.models import AccountWorkerState
        @contextmanager
        def held():
            AccountWorkerState.objects.update_or_create(binding_id_snapshot=self.binding.pk, defaults={"fence": 1})
            alive = Event(); alive.set()
            yield 1, alive
        return held()

    @patch("mobile.commands.invoke")
    @patch("mobile.commands.account_lease")
    def test_crashed_running_command_is_not_replayed(self, lease, invoke):
        from mobile.commands import execute_account
        command = submit(self.user, "ordinary", "open", {}, "crashed")
        command.status = "RUNNING"; command.save()
        lease.side_effect = self.lease
        execute_account(self.binding.pk)
        command.refresh_from_db()
        self.assertEqual(command.status, "UNKNOWN")
        invoke.assert_not_called()
        with self.assertRaisesMessage(ValueError, "结果未知"):
            submit(self.user, "ordinary", "open", {}, "new-risk")

    @patch("mobile.commands.invoke")
    @patch("mobile.commands.account_lease")
    def test_changed_binding_fails_before_any_exchange_call(self, lease, invoke):
        from mobile.commands import execute_account
        command = submit(self.user, "ordinary", "open", {}, "old-binding")
        self.binding.api_key_fingerprint = "b"*64; self.binding.save()
        lease.side_effect = self.lease
        execute_account(self.binding.pk)
        command.refresh_from_db()
        self.assertEqual(command.status, "FAILED")
        invoke.assert_not_called()

    @patch("mobile.commands.invoke", side_effect=TimeoutError)
    @patch("mobile.commands.account_lease")
    def test_timeout_holds_already_queued_new_risk_without_retry(self, lease, invoke):
        from mobile.commands import execute_account
        first = submit(self.user, "ordinary", "open", {}, "first")
        second = submit(self.user, "ordinary", "open", {}, "second")
        lease.side_effect = self.lease
        execute_account(self.binding.pk)
        first.refresh_from_db(); second.refresh_from_db()
        self.assertEqual(first.status, "UNKNOWN")
        self.assertEqual(second.status, "PENDING")
        self.assertEqual(invoke.call_count, 1)

    @patch("mobile.commands.invoke")
    @patch("mobile.commands.account_lease")
    def test_maker_status_is_processed_while_new_risk_is_unknown(self, lease, invoke):
        unknown = submit(self.user, "ordinary", "open", {}, "unknown-open")
        unknown.status = "UNKNOWN"
        unknown.save(update_fields=["status"])
        status_command = submit(self.user, "ordinary", "maker-status", {
            "client_request_id": "maker-request",
        }, "maker-status-1")
        invoke.return_value = Response({"code": 200, "data": {"state": "PENDING_MAKER"}}, status=200)
        lease.side_effect = self.lease

        from mobile.commands import execute_account
        execute_account(self.binding.pk)

        status_command.refresh_from_db()
        self.assertEqual(status_command.status, "SUCCEEDED")
        invoke.assert_called_once_with(status_command)

    def test_command_list_never_crosses_users_or_modes(self):
        submit(self.user, "ordinary", "open", {}, "list-test")
        client = APIClient(); client.force_authenticate(self.user)
        self.assertEqual(len(client.get("/api/commands").data["data"]), 1)
        self.assertEqual(client.get("/api/commands", HTTP_X_TRADING_MODE="lead").data["data"], [])
        self.assertEqual(client.get("/api/commands", HTTP_X_TRADING_MODE="invalid").status_code, 400)


class ReconcileDeliveryTests(TestCase):
    def test_refresh_hint_is_persisted_after_both_maintenance_services(self):
        from types import SimpleNamespace
        from mobile.account_events import reconcile_changed_account
        from mobile.models import AccountOutbox
        user = User.objects.create_user("reconcile@example.invalid", "test-password-only")
        binding = ApiBinding.objects.create(user=user, alias="test", api_key="placeholder", secret_key="placeholder", passphrase="")
        account = SimpleNamespace(identity="test-identity")
        order = []
        def record(name):
            def run(**kwargs):
                self.assertFalse(AccountOutbox.objects.exists())
                self.assertEqual(kwargs["user_id"], user.pk)
                order.append(name)
            return run
        with patch("api_bindings.services.get_user_trading_account", return_value=account), patch("trading.account_cache.invalidate_position_caches") as invalidate, patch("trading.services.sync_all_pending_limit_orders", side_effect=record("limits")), patch("trading.services.reconcile_open_orders_protection", side_effect=record("protection")):
            reconcile_changed_account(binding.pk)
        self.assertEqual(order, ["limits", "protection"])
        self.assertEqual(invalidate.call_count, 2)
        hint = AccountOutbox.objects.get()
        self.assertEqual(hint.user_id, user.pk)
        self.assertEqual(hint.trading_mode, "ordinary")
        self.assertEqual(hint.payload, {"reconciled": True})
