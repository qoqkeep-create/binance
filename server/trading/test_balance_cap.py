"""Tests for user-confirmed capital normalization and read-only reminders."""
import importlib
from datetime import timedelta
from decimal import Decimal
from typing import Optional
from unittest.mock import DEFAULT, MagicMock, patch

from django.apps import apps
from django.core import mail
from django.core.cache import cache
from django.db import IntegrityError, transaction
from django.test import TestCase, override_settings
from django.utils import timezone

from api_bindings.models import ApiBinding
from api_bindings.services import build_api_key_fingerprint
from common.binance import BinanceApiError
from trading import balance_cap
from trading.models import CapitalSweep
from users.models import User


def _balance(total: str, available: Optional[str] = None) -> dict:
    return {"data": [{"details": [{"eq": total, "availEq": available or total}]}]}


@override_settings(EMAIL_HOST="smtp.example.com")
class BalanceCapTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="cap@example.com", password="password")
        self.user.stop_loss_amount = Decimal("200")
        self.user.save(update_fields=["stop_loss_amount"])
        self.api_key_fingerprint = build_api_key_fingerprint("key")
        ApiBinding.objects.create(
            user=self.user,
            api_key="key",
            api_key_fingerprint=self.api_key_fingerprint,
            secret_key="secret",
            status=1,
        )
        self.client = MagicMock()
        self.client.credentials.api_key = "key"
        self.client.get_positions.return_value = {"data": []}
        self.client.get_pending_orders.return_value = {"data": []}
        self.client.get_pending_algo_orders.return_value = {"data": []}
        self.client.get_balance.return_value = _balance("600")
        self.client.get_funding_usdt_free_balance.return_value = "0"
        self.client.get_spot_usdt_free_balance.return_value = "0"
        self.client.get_spot_usdt_balance.return_value = "0"
        self.client.transfer_between_spot_and_futures.return_value = "futures-1"
        self.client.transfer_from_funding.return_value = "funding-refill-1"
        self.client.transfer_spot_to_master.return_value = "master-1"
        self.client.transfer_funding_to_spot.return_value = "funding-1"
        self.client.get_sub_account_transfer_history.return_value = []
        self.client.get_spot_futures_transfer_history.return_value = []
        self.client.get_universal_transfer_history.return_value = []
        self.client.probe_account_type.return_value = "sub"
        # Model the Spot ledger after successful mock API replies. Tests that
        # simulate delayed visibility override this reader with explicit snapshots.
        self.spot_delta = Decimal("0")
        def spot_futures(amount, *, to_futures):
            self.spot_delta += Decimal(amount) * (-1 if to_futures else 1)
            return DEFAULT
        def funding_spot(amount, **kwargs):
            self.spot_delta += Decimal(amount)
            return DEFAULT
        def spot_out(amount, **kwargs):
            self.spot_delta -= Decimal(amount)
            return DEFAULT
        self.client.transfer_between_spot_and_futures.side_effect = spot_futures
        self.client.transfer_funding_to_spot.side_effect = funding_spot
        self.client.transfer_spot_to_master.side_effect = spot_out
        self.client.withdraw_to_binance_address.side_effect = spot_out
        self.client.get_spot_usdt_free_balance.side_effect = lambda *a, **kw: str(
            Decimal(self.client.get_spot_usdt_free_balance.return_value) + self.spot_delta
        )

    def precheck(self):
        return balance_cap.capital_precheck(self.user, self.client)

    def test_manual_refresh_settles_old_withdrawal_and_shows_current_futures_path(self):
        sweep = CapitalSweep.objects.create(
            user=self.user, api_key_fingerprint=self.api_key_fingerprint,
            amount=Decimal("589.96"), target_balance=Decimal("999.99089891"),
            spot_amount=Decimal("589.96"), status=CapitalSweep.STATUS_SPOT_PENDING,
            master_attempted_at=timezone.now() - timedelta(days=6),
            master_withdraw_order_id="old-withdrawal", master_txn_id="old-receipt",
        )
        self.client.get_withdraw_history.return_value = [{
            "withdrawOrderId": "old-withdrawal", "coin": "USDT", "amount": "589.96",
            "status": 6, "transferType": 1, "id": "old-receipt",
        }]
        self.client.get_balance.return_value = _balance("1405.280079")
        state = balance_cap.refresh_capital_precheck(self.user, self.client)
        sweep.refresh_from_db()
        self.assertEqual(sweep.status, CapitalSweep.STATUS_COMPLETED)
        self.assertIsNone(sweep.active_slot)
        self.assertNotIn("pending_collection", state)
        self.assertEqual(state["futures_collect"], "405.28")
        self.assertEqual(state["transfer_amount"], "405.28")
        self.client.transfer_between_spot_and_futures.assert_not_called()
        self.client.transfer_spot_to_master.assert_not_called()
        self.client.withdraw_to_binance_address.assert_not_called()
        self.client.probe_account_type.assert_not_called()

    def test_refresh_confirms_each_internal_stage_without_submitting_next_stage(self):
        stages = [
            (CapitalSweep.STATUS_FUNDING_REFILL_PENDING, "funding_refill", "funding_to_futures", "_matching_funding_to_futures_transfer"),
            (CapitalSweep.STATUS_SPOT_REFILL_PENDING, "spot_refill", "spot_to_futures", "_matching_spot_to_futures_transfer"),
            (CapitalSweep.STATUS_FUTURES_PENDING, "futures", "futures_collect", "_matching_futures_to_spot_transfer"),
            (CapitalSweep.STATUS_FUNDING_PENDING, "funding", "funding_collect", "_matching_funding_to_spot_transfer"),
        ]
        for status, prefix, direction, lookup in stages:
            with self.subTest(status=status):
                CapitalSweep.objects.all().delete()
                sweep = CapitalSweep.objects.create(
                    user=self.user, api_key_fingerprint=self.api_key_fingerprint,
                    amount=Decimal("50"), target_balance=Decimal("1000"), status=status,
                    **{f"{prefix}_amount": Decimal("50"), f"{prefix}_attempted_at": timezone.now()},
                )
                with patch.object(balance_cap, lookup, return_value="confirmed-stage"):
                    state = balance_cap.refresh_capital_precheck(self.user, self.client)
                sweep.refresh_from_db()
                self.assertEqual(sweep.status, CapitalSweep.STATUS_SPOT_PENDING)
                self.assertIn(direction, state["pending_collection"]["completed_steps"])
                self.assertIsNone(sweep.master_attempted_at)
        self.client.transfer_from_funding.assert_not_called()
        self.client.transfer_funding_to_spot.assert_not_called()
        self.client.transfer_between_spot_and_futures.assert_not_called()
        self.client.transfer_spot_to_master.assert_not_called()

    def test_unknown_master_result_is_not_discarded_when_futures_balance_falls(self):
        sweep = CapitalSweep.objects.create(
            user=self.user, api_key_fingerprint=self.api_key_fingerprint,
            amount=Decimal("100"), target_balance=Decimal("1000"),
            status=CapitalSweep.STATUS_SPOT_PENDING, master_attempted_at=timezone.now(),
        )
        self.client.get_balance.return_value = _balance("200")
        result = balance_cap.normalize_capital(self.user, self.client, "collection_pending")
        sweep.refresh_from_db()
        self.assertEqual(result["status"], "collection_pending")
        self.assertEqual(sweep.active_slot, 1)
        self.client.get_balance.assert_not_called()
        self.client.transfer_spot_to_master.assert_not_called()

    def test_collection_id_never_resumes_a_newer_sweep(self):
        old = CapitalSweep.objects.create(
            user=self.user, api_key_fingerprint=self.api_key_fingerprint,
            amount=Decimal("100"), target_balance=Decimal("1000"), status=CapitalSweep.STATUS_COMPLETED,
        )
        current = CapitalSweep.objects.create(
            user=self.user, api_key_fingerprint=self.api_key_fingerprint,
            amount=Decimal("405.28"), target_balance=Decimal("1000"),
        )
        result = balance_cap.normalize_capital(
            self.user, self.client, "collection_pending", collection_id=old.id,
        )
        self.assertEqual(result["collection_id"], old.id)
        current.refresh_from_db()
        self.assertIsNone(current.futures_attempted_at)
        self.client.get_balance.assert_not_called()
        self.client.transfer_spot_to_master.assert_not_called()

    def test_accepted_withdrawal_is_confirmed_immediately_if_history_is_visible(self):
        self._mark_master_account()
        self._configure_collect_account("originalDestination")
        self.client.get_balance.return_value = _balance("1100")
        self.client.withdraw_to_binance_address.return_value = "new-receipt"
        self.client.get_withdraw_history.side_effect = lambda **kwargs: [{
            "withdrawOrderId": kwargs["withdraw_order_id"], "coin": "USDT", "amount": "100",
            "status": 6, "transferType": 1, "id": "new-receipt",
        }]
        result = balance_cap.normalize_capital(self.user, self.client, "normalization_required")
        self.assertEqual(result["reason"], "normalization_completed")
        self.assertEqual(len(mail.outbox), 1)
        balance_cap.refresh_capital_precheck(self.user, self.client)
        self.assertEqual(len(mail.outbox), 1)

    def test_collection_cap_is_fixed_and_independent_of_stop_loss(self):
        self.client.get_balance.return_value = _balance("1100")
        for amount in ("50", "120", "200"):
            with self.subTest(stop_loss=amount):
                self.user.stop_loss_amount = Decimal(amount)
                self.user.save(update_fields=["stop_loss_amount"])
                self.assertEqual(balance_cap.retention_threshold(self.user), Decimal("1000"))
                state = balance_cap.refresh_capital_precheck(self.user, self.client)
                self.assertEqual(Decimal(state["futures_collect"]), Decimal("100"))
                self.assertEqual(Decimal(state["upper_limit"]), Decimal("1000"))
        self.client.transfer_between_spot_and_futures.assert_not_called()

    def test_fixed_cap_collects_cent_and_sub_dollar_futures_excess(self):
        self.user.stop_loss_amount = Decimal("50")
        self.user.save(update_fields=["stop_loss_amount"])
        # Wallet residuals below 1 USDT are ignored; futures excess uses cents.
        self.client.get_funding_usdt_free_balance.return_value = "0.99"
        self.client.get_spot_usdt_free_balance.return_value = "0.99"
        for futures, excess in (("1000", "0.00"), ("1000.01", "0.01"), ("1000.50", "0.50")):
            with self.subTest(futures=futures):
                self.client.get_balance.return_value = _balance(futures)
                self.spot_delta = Decimal("0")
                self.client.transfer_between_spot_and_futures.reset_mock()
                self.client.transfer_spot_to_master.reset_mock()
                state = balance_cap.refresh_capital_precheck(self.user, self.client)
                self.assertEqual(Decimal(state["futures_collect"]), Decimal(excess))
                self.assertEqual(Decimal(state["collection_total"]), Decimal(excess))
                self.assertEqual(Decimal(state["target_balance"]), Decimal("1000"))
                self.assertEqual(state["status"], "ready" if excess == "0.00" else "normalization_required")
                if excess == "0.00":
                    self.client.transfer_between_spot_and_futures.assert_not_called()
                    continue
                result = balance_cap.normalize_capital(
                    self.user, self.client, "normalization_required", purpose="manual_sweep",
                    expected_plan=state["plan_token"],
                )
                self.assertEqual(result["reason"], "normalization_completed")
                self.client.transfer_between_spot_and_futures.assert_called_once_with(excess, to_futures=False)
                self.client.transfer_spot_to_master.assert_called_once_with(excess, ccy="USDT")
        self.assertEqual(CapitalSweep.objects.count(), 2)

    def test_changed_preview_amount_requires_another_confirmation(self):
        self.client.get_balance.return_value = _balance("1100")
        preview = balance_cap.refresh_capital_precheck(self.user, self.client)
        self.client.get_balance.return_value = _balance("1405.280079")
        state = balance_cap.normalize_capital(
            self.user, self.client, "normalization_required", expected_plan=preview["plan_token"],
        )
        self.assertTrue(state["plan_changed"])
        self.assertEqual(state["futures_collect"], "405.28")
        self.assertFalse(CapitalSweep.objects.exists())
        self.client.transfer_between_spot_and_futures.assert_not_called()

    def test_completed_internal_receipt_cannot_submit_next_step_with_a_position(self):
        sweep = CapitalSweep.objects.create(
            user=self.user, api_key_fingerprint=self.api_key_fingerprint,
            amount=Decimal("100"), target_balance=Decimal("1000"), futures_amount=Decimal("100"),
            status=CapitalSweep.STATUS_FUTURES_PENDING, futures_attempted_at=timezone.now(),
        )
        self.client.get_positions.return_value = {"data": [{"symbol": "BTCUSDT"}]}
        with patch.object(balance_cap, "_matching_futures_to_spot_transfer", return_value="confirmed"):
            state = balance_cap.normalize_capital(self.user, self.client, "collection_pending", collection_id=sweep.id, purpose="manual_sweep")
        self.assertEqual(state["reason"], "active_position")
        sweep.refresh_from_db()
        self.assertEqual(sweep.futures_tran_id, "confirmed")
        self.assertIsNone(sweep.master_attempted_at)
        self.client.transfer_spot_to_master.assert_not_called()

    def test_all_submitted_internal_stages_remain_pending_without_replay(self):
        for status, prefix, _direction in balance_cap.SWEEP_STAGES[:-1]:
            with self.subTest(status=status):
                CapitalSweep.objects.all().delete()
                sweep = CapitalSweep.objects.create(
                    user=self.user, api_key_fingerprint=self.api_key_fingerprint,
                    amount=Decimal("50"), target_balance=Decimal("1000"), status=status,
                    **{f"{prefix}_amount": Decimal("50"), f"{prefix}_attempted_at": timezone.now() - timedelta(days=7)},
                )
                state = balance_cap.normalize_capital(self.user, self.client, "collection_pending", collection_id=sweep.id)
                self.assertEqual(state["status"], "collection_pending")
                sweep.refresh_from_db()
                self.assertEqual(sweep.active_slot, 1)
        self.client.get_balance.assert_not_called()
        self.client.transfer_from_funding.assert_not_called()
        self.client.transfer_between_spot_and_futures.assert_not_called()
        self.client.transfer_funding_to_spot.assert_not_called()
        self.client.transfer_spot_to_master.assert_not_called()

    def test_new_stop_loss_replans_unsubmitted_futures_step_on_panel_open(self):
        sweep = CapitalSweep.objects.create(
            user=self.user, api_key_fingerprint=self.api_key_fingerprint,
            amount=Decimal("500"), target_balance=Decimal("500"), futures_amount=Decimal("500"),
            status=CapitalSweep.STATUS_FUTURES_PENDING,
        )
        self.client.get_balance.return_value = _balance("1100")
        state = balance_cap.refresh_capital_precheck(self.user, self.client)
        self.assertTrue(state["plan_changed"])
        self.assertEqual(state["futures_collect"], "100.00")
        self.assertNotIn("pending_collection", state)
        sweep.refresh_from_db()
        self.assertEqual(sweep.status, CapitalSweep.STATUS_FAILED)
        self.client.transfer_between_spot_and_futures.assert_not_called()

    def test_wallet_visibility_wait_expires_without_retransferring_internal_funds(self):
        sweep = CapitalSweep.objects.create(
            user=self.user, api_key_fingerprint=self.api_key_fingerprint,
            amount=Decimal("100"), target_balance=Decimal("1000"), futures_amount=Decimal("100"),
            futures_tran_id="confirmed", futures_attempted_at=timezone.now() - timedelta(seconds=61),
            status=CapitalSweep.STATUS_SPOT_PENDING,
        )
        self.client.get_balance.return_value = _balance("1000")
        state = balance_cap.normalize_capital(self.user, self.client, "collection_pending", collection_id=sweep.id)
        self.assertTrue(state["plan_changed"])
        sweep.refresh_from_db()
        self.assertEqual(sweep.status, CapitalSweep.STATUS_FAILED)
        self.client.transfer_between_spot_and_futures.assert_not_called()
        self.client.transfer_spot_to_master.assert_not_called()

    def test_empty_internal_receipt_does_not_advance_to_master(self):
        self.client.get_balance.return_value = _balance("1100")
        self.client.transfer_between_spot_and_futures.return_value = ""
        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required")
        self.assertEqual(state["status"], "collection_pending")
        self.assertEqual(state["reason"], CapitalSweep.STATUS_FUTURES_PENDING)
        self.client.transfer_spot_to_master.assert_not_called()

    def test_collection_id_from_another_binding_is_rejected(self):
        sweep = CapitalSweep.objects.create(
            user=self.user, api_key_fingerprint="other-key", amount=Decimal("100"),
            target_balance=Decimal("1000"), status=CapitalSweep.STATUS_SPOT_PENDING,
        )
        with self.assertRaisesMessage(ValueError, "不属于当前 API 账户"):
            balance_cap.normalize_capital(self.user, self.client, "collection_pending", collection_id=sweep.id)
        self.client.get_balance.assert_not_called()

    def test_reminder_trigger_is_strictly_below_one_point_five_times_stop_loss(self):
        self.client.get_balance.return_value = _balance("300")
        at_trigger = balance_cap.capital_shortfall_reminder_preview(self.user, self.client)
        self.assertEqual(at_trigger["status"], "ready")
        self.assertNotIn("email_subject", at_trigger)

        self.client.get_balance.return_value = _balance("299.99")
        below_trigger = balance_cap.capital_shortfall_reminder_preview(self.user, self.client)
        self.assertEqual(below_trigger["status"], "shortfall")
        self.assertEqual(below_trigger["refill_trigger"], "300.0")
        self.assertEqual(below_trigger["recommended_topup"], "1")
        self.assertEqual(below_trigger["minimum_topup"], "0.01")
        self.assertEqual(below_trigger["maximum_topup"], "700.01")

    def test_real_position_skips_wallet_checks(self):
        self.client.get_positions.return_value = {"data": [{"symbol": "BTCUSDT"}]}
        self.assertEqual(self.precheck()["status"], "not_required")
        self.client.get_balance.assert_not_called()

    def test_real_position_blocks_manual_sweep_with_reason(self):
        self.client.get_positions.return_value = {"data": [{"symbol": "BTCUSDT"}]}
        state = balance_cap.capital_precheck(self.user, self.client, purpose="manual_sweep")
        self.assertEqual((state["status"], state["reason"]), ("blocked", "active_position"))
        self.client.get_balance.assert_not_called()

    def test_regular_or_algo_order_only_blocks_manual_sweep(self):
        self.client.get_pending_orders.return_value = {"data": [{"orderId": "1"}]}
        self.assertEqual(self.precheck()["status"], "ready")
        self.assertEqual(
            balance_cap.capital_precheck(self.user, self.client, purpose="manual_sweep")["status"],
            "blocked",
        )
        self.client.get_pending_orders.return_value = {"data": []}
        self.client.get_pending_algo_orders.return_value = {"data": [{"algoId": "2"}]}
        self.assertEqual(self.precheck()["status"], "ready")
        self.assertEqual(
            balance_cap.capital_precheck(self.user, self.client, purpose="manual_sweep")["status"],
            "blocked",
        )

    def test_precheck_reuses_supplied_exchange_activity_snapshot(self):
        snapshot = balance_cap.load_exchange_activity(self.client)
        self.client.get_positions.reset_mock()
        self.client.get_pending_orders.reset_mock()
        self.client.get_pending_algo_orders.reset_mock()

        state = balance_cap.capital_precheck(
            self.user,
            self.client,
            activity_snapshot=snapshot,
        )

        self.assertEqual(state["status"], "ready")
        self.client.get_positions.assert_not_called()
        self.client.get_pending_orders.assert_not_called()
        self.client.get_pending_algo_orders.assert_not_called()

    def test_chase_ignores_entry_order_but_still_checks_capital(self):
        self.client.get_pending_orders.return_value = {"data": [{"orderId": "1"}]}
        self.client.get_balance.return_value = _balance("250")

        state = balance_cap.capital_precheck(self.user, self.client, purpose="chase")

        self.assertEqual(state["status"], "shortfall")
        self.assertEqual(state["minimum_topup"], "50.00")

    def test_excess_and_shortfall_details(self):
        self.client.get_balance.return_value = _balance("1100")
        excess = self.precheck()
        self.assertEqual((excess["status"], excess["transfer_amount"]), ("normalization_required", "100.00"))
        self.client.get_balance.return_value = _balance("250")
        self.client.get_funding_usdt_free_balance.return_value = "40"
        self.client.get_spot_usdt_free_balance.return_value = "0"
        shortfall = self.precheck()
        self.assertEqual(shortfall["status"], "shortfall")
        self.assertEqual(shortfall["internal_available"], "40.00")
        self.assertEqual(shortfall["remaining_after_transfer"], "10.00")
        self.assertEqual(shortfall["minimum_topup"], "10.00")
        self.assertEqual(shortfall["maximum_topup"], "710.00")
        self.assertEqual(shortfall["recommended_topup"], "10")

    def test_unknown_account_type_blocks_excess_transfers(self):
        self.client.probe_account_type.return_value = "unknown"
        self.client.get_balance.return_value = _balance("1100")
        with self.assertRaisesMessage(ValueError, "无法确认 Binance 账户类型"):
            balance_cap.normalize_capital(self.user, self.client, "normalization_required")
        self.client.transfer_from_funding.assert_not_called()
        self.client.transfer_between_spot_and_futures.assert_not_called()
        self.client.transfer_spot_to_master.assert_not_called()

    def test_account_type_probe_propagates_shared_rate_limit(self):
        self.client.probe_account_type.side_effect = BinanceApiError(
            "请求过于频繁",
            code="-1003",
        )

        with self.assertRaises(BinanceApiError):
            balance_cap.account_type_for_client(self.client)

    def test_futures_balance_inside_open_range_is_ready(self):
        self.client.get_balance.return_value = _balance("999.99")
        state = self.precheck()
        self.assertEqual(state["status"], "ready")
        self.assertEqual(state["upper_limit"], "1000")

    def test_sub_cent_excess_above_retention_cap_is_not_collectible(self):
        self.client.get_balance.return_value = _balance("1000.004")

        state = self.precheck()

        self.assertEqual(state["status"], "ready")
        self.assertEqual(state["futures_collect"], "0.00")

    def test_collectible_excess_rounds_down_without_crossing_retention_cap(self):
        self.client.get_balance.return_value = _balance("1000.019")

        state = self.precheck()

        self.assertEqual(state["status"], "normalization_required")
        self.assertEqual(state["futures_collect"], "0.01")
        self.assertEqual(state["target_balance"], "1000.009")

    def test_stale_spot_pending_sweep_replans_futures_refill_before_collection(self):
        self.user.stop_loss_amount = Decimal("100")
        self.user.save(update_fields=["stop_loss_amount"])
        CapitalSweep.objects.create(
            user=self.user,
            amount=Decimal("312.70"),
            target_balance=Decimal("300"),
            futures_amount=Decimal("312.70"),
            status=CapitalSweep.STATUS_SPOT_PENDING,
        )
        self.client.get_balance.return_value = _balance("205")
        self.client.get_funding_usdt_free_balance.return_value = "0"
        self.client.get_spot_usdt_free_balance.return_value = "312.70"

        state = balance_cap.capital_precheck(self.user, self.client, purpose="manual_sweep")

        self.assertEqual(state["status"], "normalization_required")
        self.assertEqual(state["spot_to_futures"], "312.70")
        self.assertEqual(state["spot_collect"], "0.00")
        self.assertEqual(CapitalSweep.objects.get(user=self.user).status, CapitalSweep.STATUS_SPOT_PENDING)

        normalized = balance_cap.normalize_capital(
            self.user,
            self.client,
            "collection_pending",
            purpose="manual_sweep",
        )
        self.assertEqual(normalized["status"], "normalization_required")
        self.assertEqual(CapitalSweep.objects.get(user=self.user).status, CapitalSweep.STATUS_FAILED)

    def test_unattempted_refill_is_replanned_when_manual_transfer_would_overfund_futures(self):
        sweep = CapitalSweep.objects.create(
            user=self.user,
            api_key_fingerprint=self.api_key_fingerprint,
            amount=Decimal("0"),
            target_balance=Decimal("1000"),
            spot_refill_amount=Decimal("150"),
            status=CapitalSweep.STATUS_SPOT_REFILL_PENDING,
        )
        self.client.get_balance.return_value = _balance("950")
        self.client.get_spot_usdt_free_balance.return_value = "200"

        state = balance_cap.normalize_capital(
            self.user,
            self.client,
            "collection_pending",
            purpose="manual_sweep",
        )

        sweep.refresh_from_db()
        self.assertEqual(sweep.status, CapitalSweep.STATUS_FAILED)
        self.assertEqual(state["status"], "normalization_required")
        self.assertEqual(state["spot_to_futures"], "50.00")
        self.client.transfer_between_spot_and_futures.assert_not_called()

    def test_only_one_active_sweep_is_allowed_per_user(self):
        CapitalSweep.objects.create(
            user=self.user,
            amount=Decimal("10"),
            target_balance=Decimal("1000"),
        )

        with self.assertRaises(IntegrityError), transaction.atomic():
            CapitalSweep.objects.create(
                user=self.user,
                amount=Decimal("20"),
                target_balance=Decimal("1000"),
            )

    def test_sub_cent_gap_below_open_minimum_requires_refill(self):
        self.client.get_balance.return_value = _balance("299.99635842")
        state = self.precheck()
        self.assertEqual(state["status"], "shortfall")
        self.assertEqual(state["target"], "1000")
        self.assertEqual(state["minimum_open_balance"], "300.0")
        self.assertEqual(state["shortfall"], "0.01")

    def test_normalize_excess_completes_all_transfer_steps_in_one_request(self):
        self.client.get_balance.side_effect = [_balance("1100"), _balance("1100"), _balance("1000")]
        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required")
        self.client.transfer_between_spot_and_futures.assert_called_once_with("100.00", to_futures=False)
        self.client.transfer_spot_to_master.assert_called_once_with("100.00", ccy="USDT")
        self.assertEqual(state["status"], "ready")
        self.assertEqual(len(mail.outbox), 1)
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.status, CapitalSweep.STATUS_COMPLETED)
        self.assertIsNone(sweep.active_slot)
        self.assertEqual(sweep.futures_tran_id, "futures-1")
        self.assertEqual(sweep.master_txn_id, "master-1")
        self.assertIn("100.00 USDT", mail.outbox[0].body)
        self.assertIn("主账户的现货账户", mail.outbox[0].body)
        self.assertIn("合约账户转出：100.00 USDT", mail.outbox[0].body)
        self.assertIn("资金账户转出：0.00 USDT", mail.outbox[0].body)
        self.assertIn("原现货账户归集：0.00 USDT", mail.outbox[0].body)
        self.assertIn("合约账户保留目标：1000.00 USDT", mail.outbox[0].body)
        self.assertIn(f"系统归集编号：{sweep.id}", mail.outbox[0].body)
        self.assertIn("不使用提现 API", mail.outbox[0].body)
        self.client.get_spot_futures_transfer_history.assert_not_called()

        self.client.get_balance.reset_mock()
        self.client.get_balance.side_effect = None
        self.client.get_balance.return_value = _balance("1000")
        repeated = balance_cap.capital_precheck(self.user, self.client, purpose="manual_sweep")
        self.assertEqual((repeated["status"], repeated["reason"]), ("ready", "normalization_completed"))
        self.client.get_balance.assert_called_once()

        self.client.get_balance.side_effect = None
        self.client.get_balance.return_value = _balance("1100")
        self.assertEqual(self.precheck()["status"], "normalization_required")

    def test_recent_completed_sweep_does_not_hide_remaining_spot_balance(self):
        CapitalSweep.objects.create(
            user=self.user,
            amount=Decimal("312.70"),
            target_balance=Decimal("1000"),
            status=CapitalSweep.STATUS_COMPLETED,
        )
        self.client.get_balance.return_value = _balance("1000")
        self.client.get_spot_usdt_free_balance.return_value = "312.70"

        state = balance_cap.capital_precheck(self.user, self.client, purpose="manual_sweep")

        self.assertEqual(state["status"], "normalization_required")
        self.assertEqual(state["spot_collect"], "312.70")
        self.assertNotIn("collection_id", state)

    def test_recent_completed_sweep_is_not_shown_after_a_newer_failure(self):
        CapitalSweep.objects.create(
            user=self.user,
            amount=Decimal("100"),
            target_balance=Decimal("1000"),
            status=CapitalSweep.STATUS_COMPLETED,
        )
        CapitalSweep.objects.create(
            user=self.user,
            amount=Decimal("10"),
            target_balance=Decimal("1000"),
            status=CapitalSweep.STATUS_FAILED,
            error="test failure",
        )
        self.client.get_balance.return_value = _balance("1000")

        state = balance_cap.capital_precheck(self.user, self.client, purpose="manual_sweep")

        self.assertEqual(state["status"], "ready")
        self.assertNotIn("collection_id", state)

    def test_excess_requires_all_excess_to_be_available(self):
        self.client.get_balance.return_value = _balance("1100", "40")
        with self.assertRaisesMessage(ValueError, "可用余额不足"):
            balance_cap.normalize_capital(self.user, self.client, "normalization_required")
        self.client.transfer_between_spot_and_futures.assert_not_called()

    def test_shortfall_cannot_start_a_normalization_transfer(self):
        self.client.get_balance.return_value = _balance("250")
        self.client.get_funding_usdt_free_balance.return_value = "20"
        self.client.get_spot_usdt_free_balance.return_value = "10"

        with self.assertRaisesMessage(ValueError, "资金状态已变化"):
            balance_cap.normalize_capital(self.user, self.client, "shortfall")

        self.client.transfer_from_funding.assert_not_called()
        self.client.transfer_between_spot_and_futures.assert_not_called()
        self.assertEqual(len(mail.outbox), 0)

    def test_manual_shortfall_reminder_sends_each_explicit_request(self):
        self.client.get_balance.return_value = _balance("250")
        self.client.get_funding_usdt_free_balance.return_value = "40"
        self.client.get_spot_usdt_free_balance.return_value = "0"

        first = balance_cap.send_capital_shortfall_reminder(self.user, self.client)
        second = balance_cap.send_capital_shortfall_reminder(self.user, self.client)

        self.assertTrue(first["reminder_sent"])
        self.assertTrue(second["reminder_sent"])
        self.assertEqual(first["recommended_topup"], "10")
        self.assertEqual(len(mail.outbox), 2)
        self.assertIn("请转入 10 USDT", mail.outbox[0].subject)
        self.assertIn("建议向该交易账户的资金账户转入：10 USDT", mail.outbox[0].body)
        self.assertIn("已向上取整", mail.outbox[0].body)

    @override_settings(EMAIL_HOST="")
    def test_manual_reminder_reports_missing_email_service(self):
        self.client.get_balance.return_value = _balance("250")
        self.client.get_funding_usdt_free_balance.return_value = "40"
        self.client.get_spot_usdt_free_balance.return_value = "0"

        with self.assertRaisesMessage(ValueError, "邮件服务未配置"):
            balance_cap.send_capital_shortfall_reminder(self.user, self.client)
        self.assertEqual(len(mail.outbox), 0)

    def test_shortfall_preview_matches_email_without_sending(self):
        self.client.get_balance.return_value = _balance("250")
        self.client.get_funding_usdt_free_balance.return_value = "40"
        self.client.get_spot_usdt_free_balance.return_value = "0"

        preview = balance_cap.capital_shortfall_reminder_preview(self.user, self.client)

        self.assertEqual(preview["account_total"], "290")
        self.assertEqual(preview["remaining_after_transfer"], "10.00")
        self.assertEqual(preview["recommended_topup"], "10")
        self.assertIn("请转入 10 USDT", preview["email_subject"])
        self.assertIn("至少需要补充：10.00 USDT", preview["email_body"])
        self.assertEqual(len(mail.outbox), 0)

    def test_uncertain_futures_transfer_surfaces_pending_collection_without_blocking_entry(self):
        # 待确认流水只在预检结果里透出供账户页确认，绝不能阻塞开仓判定。
        self.client.get_balance.return_value = _balance("1100")
        self.client.transfer_between_spot_and_futures.side_effect = RuntimeError("timeout")
        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required")
        self.assertEqual(state["status"], "collection_pending")
        self.client.get_balance.return_value = _balance("1000")
        recheck = self.precheck()
        self.assertEqual(recheck["status"], "ready")
        self.assertEqual(recheck["pending_collection"]["status"], "collection_pending")
        self.client.transfer_spot_to_master.assert_not_called()

    def test_pending_sweep_blocks_new_excess_sweep_but_not_entry(self):
        CapitalSweep.objects.create(
            user=self.user,
            amount=Decimal("100"),
            target_balance=Decimal("1000"),
            futures_amount=Decimal("100"),
            status=CapitalSweep.STATUS_SPOT_PENDING,
        )
        self.client.get_balance.return_value = _balance("1100")
        recheck = self.precheck()
        self.assertEqual(recheck["status"], "normalization_required")
        self.assertIn("pending_collection", recheck)
        with self.assertRaisesMessage(ValueError, "请先完成确认"):
            balance_cap.normalize_capital(self.user, self.client, "normalization_required")
        self.client.transfer_between_spot_and_futures.assert_not_called()

    def test_active_sweep_from_old_api_binding_blocks_only_manual_sweep(self):
        sweep = CapitalSweep.objects.create(
            user=self.user,
            api_key_fingerprint="old-api-key-fingerprint",
            amount=Decimal("100"),
            target_balance=Decimal("1000"),
            futures_amount=Decimal("100"),
            status=CapitalSweep.STATUS_SPOT_PENDING,
        )

        manual = balance_cap.capital_precheck(self.user, self.client, purpose="manual_sweep")
        entry = balance_cap.capital_precheck(self.user, self.client, purpose="entry")

        self.assertEqual(manual["status"], "blocked")
        self.assertEqual(manual["reason"], "capital_sweep_binding_mismatch")
        self.assertEqual(entry["status"], "ready")
        self.assertNotIn("pending_collection", entry)
        continued = balance_cap.normalize_capital(
            self.user,
            self.client,
            "collection_pending",
            purpose="manual_sweep",
        )
        self.assertEqual(continued["status"], "blocked")
        sweep.refresh_from_db()
        self.assertEqual(sweep.status, CapitalSweep.STATUS_SPOT_PENDING)
        self.client.transfer_spot_to_master.assert_not_called()

    def test_normalize_stops_when_api_binding_changes_before_locked_recheck(self):
        binding = ApiBinding.objects.get(user=self.user)
        changed_at = binding.created_at + timedelta(seconds=1)

        with patch.object(
            balance_cap,
            "get_user_binding_generation",
            side_effect=[
                (self.api_key_fingerprint, binding.created_at),
                ("replacement-fingerprint", changed_at),
            ],
        ):
            with self.assertRaisesMessage(ValueError, "API 绑定已发生变化"):
                balance_cap.normalize_capital(
                    self.user,
                    self.client,
                    "normalization_required",
                    purpose="manual_sweep",
                )

        self.client.get_balance.assert_not_called()
        self.client.transfer_between_spot_and_futures.assert_not_called()

    def test_legacy_sweep_created_under_current_binding_remains_compatible(self):
        sweep = CapitalSweep.objects.create(
            user=self.user,
            api_key_fingerprint=None,
            amount=Decimal("100"),
            target_balance=Decimal("1000"),
            futures_amount=Decimal("100"),
            status=CapitalSweep.STATUS_SPOT_PENDING,
        )

        self.assertEqual(balance_cap._pending_sweep(self.user), sweep)

    def test_recent_completed_sweep_from_old_binding_is_not_replayed(self):
        CapitalSweep.objects.create(
            user=self.user,
            api_key_fingerprint="old-api-key-fingerprint",
            amount=Decimal("100"),
            target_balance=Decimal("1000"),
            status=CapitalSweep.STATUS_COMPLETED,
        )

        state = balance_cap.capital_precheck(self.user, self.client, purpose="manual_sweep")

        self.assertEqual(state["status"], "ready")
        self.assertNotEqual(state.get("reason"), "normalization_completed")

    def test_sub_one_usdt_wallet_dust_is_ignored_by_plan_and_entry(self):
        # 币安截断/手续费返还会留下 <1U 残差：不规划、不划转、不阻塞开仓。
        self.client.get_balance.return_value = _balance("500")
        self.client.get_funding_usdt_free_balance.return_value = "0.01"
        self.client.get_spot_usdt_free_balance.return_value = "0.5"
        state = self.precheck()
        self.assertEqual(state["status"], "ready")
        self.assertEqual(state["funding_to_futures"], "0.00")
        self.assertEqual(state["spot_to_futures"], "0.00")
        self.assertEqual(state["collection_total"], "0.00")

    def test_wallet_dust_is_not_counted_as_usable_opening_capital(self):
        self.client.get_balance.return_value = _balance("299")
        self.client.get_funding_usdt_free_balance.return_value = "0.5"
        self.client.get_spot_usdt_free_balance.return_value = "0.5"

        state = self.precheck()

        self.assertEqual(state["status"], "shortfall")
        self.assertEqual(state["account_total"], "300.0")
        self.assertEqual(state["usable_total"], "299")
        self.assertEqual(state["internal_available"], "0.00")
        self.assertEqual(state["remaining_after_transfer"], "1.00")
        self.assertEqual(state["recommended_topup"], "1")

    def test_manual_sweep_can_apply_partial_refill_below_opening_minimum(self):
        self.client.get_balance.return_value = _balance("200")
        self.client.get_funding_usdt_free_balance.return_value = "50"

        state = balance_cap.capital_precheck(self.user, self.client, purpose="manual_sweep")

        self.assertEqual(state["status"], "normalization_required")
        self.assertEqual(state["reason"], "partial_refill_available")
        self.assertEqual(state["funding_to_futures"], "50.00")
        self.assertEqual(state["remaining_after_transfer"], "50.00")

    def test_partial_refill_completion_returns_real_shortfall_state(self):
        self.client.get_balance.side_effect = [_balance("200"), _balance("250")]
        self.client.get_funding_usdt_free_balance.side_effect = ["50", "0"]

        state = balance_cap.normalize_capital(
            self.user,
            self.client,
            "normalization_required",
            purpose="manual_sweep",
        )

        self.client.transfer_from_funding.assert_called_once_with("50.00")
        self.assertEqual(state["status"], "shortfall")
        self.assertEqual(state["reason"], "normalization_completed")
        self.assertEqual(state["futures_balance"], "250")
        self.assertEqual(state["remaining_after_transfer"], "50.00")
        self.assertEqual(state["recommended_topup"], "50")
        self.assertEqual(CapitalSweep.objects.get(user=self.user).status, CapitalSweep.STATUS_COMPLETED)

    def test_uncertain_futures_transfer_recovers_only_from_exchange_history(self):
        self.client.get_balance.side_effect = [_balance("1100"), _balance("1100"), _balance("1000")]
        self.client.transfer_between_spot_and_futures.side_effect = RuntimeError("timeout")
        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required", purpose="manual_sweep")
        self.assertEqual(state["status"], "collection_pending")
        self.client.get_spot_futures_transfer_history.return_value = [
            {"asset": "USDT", "type": 2, "amount": "100", "status": "CONFIRMED", "tranId": 456}
        ]
        self.client.get_balance.side_effect = None
        self.client.get_balance.return_value = _balance("1000")
        self.client.get_spot_usdt_free_balance.return_value = "100"
        state = balance_cap.normalize_capital(self.user, self.client, "collection_pending")
        self.assertEqual(state["status"], "ready")
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.futures_tran_id, "456")
        self.client.transfer_between_spot_and_futures.assert_called_once()
        self.client.transfer_spot_to_master.assert_called_once_with("100.00000000", ccy="USDT")

    def test_uncertain_funding_refill_is_reconciled_without_repeating(self):
        self.client.get_balance.return_value = _balance("250")
        self.client.get_funding_usdt_free_balance.return_value = "100"
        self.client.transfer_from_funding.side_effect = RuntimeError("timeout")

        state = balance_cap.normalize_capital(
            self.user,
            self.client,
            "normalization_required",
            purpose="manual_sweep",
        )
        self.assertEqual(state["status"], "collection_pending")
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.status, CapitalSweep.STATUS_FUNDING_REFILL_PENDING)
        self.assertIsNotNone(sweep.funding_refill_attempted_at)

        self.client.get_universal_transfer_history.return_value = [{
            "asset": "USDT",
            "type": "FUNDING_UMFUTURE",
            "amount": "100",
            "status": "CONFIRMED",
            "tranId": 901,
        }]
        state = balance_cap.normalize_capital(
            self.user,
            self.client,
            "collection_pending",
            purpose="manual_sweep",
        )
        self.assertEqual(state["status"], "ready")
        self.client.transfer_from_funding.assert_called_once_with("100.00")
        sweep.refresh_from_db()
        self.assertEqual(sweep.funding_refill_tran_id, "901")
        self.assertIsNone(sweep.active_slot)

    def test_shared_rate_limit_pauses_internal_step_without_history_or_followup(self):
        self.client.get_balance.return_value = _balance("250")
        self.client.get_funding_usdt_free_balance.return_value = "100"
        self.client.transfer_from_funding.side_effect = BinanceApiError(
            "Binance 请求预算保护中",
            code="LOCAL_RATE_BUDGET",
        )

        state = balance_cap.normalize_capital(
            self.user,
            self.client,
            "normalization_required",
            purpose="manual_sweep",
        )

        self.assertEqual(state["status"], "collection_pending")
        self.assertEqual(state["collection_error"], "Binance 请求预算保护中")
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.status, CapitalSweep.STATUS_FUNDING_REFILL_PENDING)
        self.assertIsNone(sweep.funding_refill_attempted_at)
        self.client.get_universal_transfer_history.assert_not_called()
        self.client.transfer_between_spot_and_futures.assert_not_called()

    def test_exchange_rate_limit_keeps_internal_attempt_for_reconciliation(self):
        self.client.get_balance.return_value = _balance("250")
        self.client.get_funding_usdt_free_balance.return_value = "100"
        self.client.transfer_from_funding.side_effect = BinanceApiError(
            "Binance 请求过于频繁",
            code="-1003",
            outcome_unknown=True,
        )

        state = balance_cap.normalize_capital(
            self.user,
            self.client,
            "normalization_required",
            purpose="manual_sweep",
        )

        self.assertEqual(state["status"], "collection_pending")
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertIsNotNone(sweep.funding_refill_attempted_at)
        self.assertEqual(sweep.status, CapitalSweep.STATUS_FUNDING_REFILL_PENDING)

        self.client.get_universal_transfer_history.return_value = [{
            "asset": "USDT",
            "type": "FUNDING_UMFUTURE",
            "amount": "100",
            "status": "CONFIRMED",
            "tranId": 902,
        }]
        self.client.transfer_from_funding.side_effect = None
        state = balance_cap.normalize_capital(
            self.user,
            self.client,
            "collection_pending",
            purpose="manual_sweep",
        )

        self.assertEqual(state["status"], "ready")
        self.client.transfer_from_funding.assert_called_once_with("100.00")
        self.assertEqual(CapitalSweep.objects.get(user=self.user).funding_refill_tran_id, "902")

    def test_shared_rate_limit_pauses_sub_to_master_without_replanning(self):
        self.client.get_balance.return_value = _balance("1100")
        self.client.transfer_spot_to_master.side_effect = BinanceApiError(
            "Binance 请求预算保护中",
            code="LOCAL_RATE_BUDGET",
        )

        state = balance_cap.normalize_capital(
            self.user,
            self.client,
            "normalization_required",
            purpose="manual_sweep",
        )

        self.assertEqual(state["status"], "collection_pending")
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.status, CapitalSweep.STATUS_SPOT_PENDING)
        self.assertIsNone(sweep.master_attempted_at)
        self.client.get_sub_account_transfer_history.assert_not_called()
        self.assertEqual(self.client.get_balance.call_count, 1)

    def test_shared_rate_limit_pauses_master_withdrawal_without_history_query(self):
        self._mark_master_account()
        self._configure_collect_account("TQx9d8qM7exampleAddress")
        self.client.get_balance.return_value = _balance("1100")
        self.client.withdraw_to_binance_address.side_effect = BinanceApiError(
            "Binance 请求预算保护中",
            code="LOCAL_RATE_BUDGET",
        )

        state = balance_cap.normalize_capital(
            self.user,
            self.client,
            "normalization_required",
            purpose="manual_sweep",
        )

        self.assertEqual(state["status"], "collection_pending")
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.status, CapitalSweep.STATUS_SPOT_PENDING)
        self.assertIsNone(sweep.master_attempted_at)
        self.client.get_withdraw_history.assert_not_called()
        self.assertEqual(self.client.get_balance.call_count, 1)

    def test_deterministic_funding_refill_rejection_terminates_and_replans(self):
        self.client.get_balance.return_value = _balance("200")
        self.client.get_funding_usdt_free_balance.return_value = "100"
        self.client.transfer_from_funding.side_effect = BinanceApiError(
            "insufficient balance",
            code="-2010",
        )

        state = balance_cap.normalize_capital(
            self.user,
            self.client,
            "normalization_required",
            purpose="manual_sweep",
        )

        self.assertEqual(state["status"], "normalization_required")
        self.client.transfer_from_funding.assert_called_once_with("100.00")
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.status, CapitalSweep.STATUS_FAILED)
        self.assertIsNone(sweep.active_slot)
        self.assertIn("insufficient balance", sweep.error)

    def test_uncertain_spot_refill_is_reconciled_without_repeating(self):
        self.client.get_balance.return_value = _balance("250")
        self.client.get_spot_usdt_free_balance.return_value = "100"
        self.client.transfer_between_spot_and_futures.side_effect = RuntimeError("timeout")

        state = balance_cap.normalize_capital(
            self.user,
            self.client,
            "normalization_required",
            purpose="manual_sweep",
        )
        self.assertEqual(state["status"], "collection_pending")
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.status, CapitalSweep.STATUS_SPOT_REFILL_PENDING)
        self.assertIsNotNone(sweep.spot_refill_attempted_at)

        self.client.get_spot_futures_transfer_history.return_value = [{
            "asset": "USDT",
            "type": 1,
            "amount": "100",
            "status": "CONFIRMED",
            "tranId": 902,
        }]
        state = balance_cap.normalize_capital(
            self.user,
            self.client,
            "collection_pending",
            purpose="manual_sweep",
        )

        self.assertEqual(state["status"], "ready")
        self.client.transfer_between_spot_and_futures.assert_called_once_with("100.00", to_futures=True)
        sweep.refresh_from_db()
        self.assertEqual(sweep.spot_refill_tran_id, "902")
        self.assertIsNone(sweep.active_slot)

    def test_uncertain_master_transfer_recovers_from_history_without_repeating(self):
        self.client.get_balance.side_effect = [_balance("1100"), _balance("1100"), _balance("1000")]
        self.client.transfer_spot_to_master.side_effect = RuntimeError("timeout")
        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required")
        self.assertEqual(state["status"], "collection_pending")
        self.client.get_sub_account_transfer_history.return_value = [
            {"asset": "USDT", "qty": "100", "status": "SUCCESS", "counterParty": "master", "tranId": 789}
        ]
        state = balance_cap.normalize_capital(self.user, self.client, "collection_pending")
        self.assertEqual(state["status"], "ready")
        self.client.transfer_spot_to_master.assert_called_once()
        self.assertEqual(CapitalSweep.objects.get(user=self.user).master_txn_id, "789")

    def test_sub_to_master_reconciliation_requires_explicit_matching_counterparty(self):
        base = {
            "asset": "USDT",
            "qty": "100",
            "status": "SUCCESS",
            "tranId": 789,
        }
        kwargs = {
            "asset": "USDT",
            "expected_amount": Decimal("100"),
            "ok_statuses": balance_cap.TRANSFER_OK_STATUSES,
            "amount_fields": ("qty", "amount"),
            "counterparty": "master",
            "id_fields": ("tranId", "txnId"),
        }

        self.assertEqual(balance_cap._first_confirmed_transfer([base], **kwargs), "")
        self.assertEqual(
            balance_cap._first_confirmed_transfer(
                [{**base, "counterParty": "other"}],
                **kwargs,
            ),
            "",
        )
        self.assertEqual(
            balance_cap._first_confirmed_transfer(
                [{**base, "counterParty": "MASTER"}],
                **kwargs,
            ),
            "789",
        )

    def test_transfer_reconciliation_rejects_missing_status_or_type(self):
        row = {
            "asset": "USDT",
            "amount": "100",
            "status": "CONFIRMED",
            "type": "FUNDING_MAIN",
            "tranId": 789,
        }
        kwargs = {
            "asset": "USDT",
            "expected_amount": Decimal("100"),
            "ok_statuses": balance_cap.TRANSFER_OK_STATUSES,
            "type_field": "type",
            "type_value": "FUNDING_MAIN",
        }

        self.assertEqual(balance_cap._first_confirmed_transfer([row], **kwargs), "789")
        self.assertEqual(
            balance_cap._first_confirmed_transfer(
                [{key: value for key, value in row.items() if key != "status"}],
                **kwargs,
            ),
            "",
        )
        self.assertEqual(
            balance_cap._first_confirmed_transfer(
                [{key: value for key, value in row.items() if key != "type"}],
                **kwargs,
            ),
            "",
        )

    def test_uncertain_transfer_history_queries_never_use_future_end_time(self):
        observed_at = timezone.now()
        submitted_at = observed_at - timedelta(minutes=2)
        sweep = CapitalSweep.objects.create(
            user=self.user,
            api_key_fingerprint=self.api_key_fingerprint,
            amount=Decimal("100"),
            target_balance=Decimal("1000"),
            funding_refill_amount=Decimal("10"),
            spot_refill_amount=Decimal("20"),
            futures_amount=Decimal("30"),
            funding_amount=Decimal("40"),
            status=CapitalSweep.STATUS_SPOT_PENDING,
            funding_refill_attempted_at=submitted_at,
            spot_refill_attempted_at=submitted_at,
            futures_attempted_at=submitted_at,
            funding_attempted_at=submitted_at,
            master_attempted_at=submitted_at,
        )
        expected_start = int((submitted_at - timedelta(seconds=1)).timestamp() * 1000)
        expected_end = int(observed_at.timestamp() * 1000)

        with patch("trading.balance_cap.timezone.now", return_value=observed_at):
            balance_cap._matching_master_transfer(self.client, sweep)
            balance_cap._matching_spot_to_futures_transfer(self.client, sweep)
            balance_cap._matching_futures_to_spot_transfer(self.client, sweep)
            balance_cap._matching_funding_to_futures_transfer(self.client, sweep)
            balance_cap._matching_funding_to_spot_transfer(self.client, sweep)

        self.client.get_sub_account_transfer_history.assert_called_once_with(
            ccy="USDT",
            start_time_ms=expected_start,
            end_time_ms=expected_end,
        )
        for history_call in self.client.get_spot_futures_transfer_history.call_args_list:
            self.assertEqual(history_call.kwargs["start_time_ms"], expected_start)
            self.assertEqual(history_call.kwargs["end_time_ms"], expected_end)
        for history_call in self.client.get_universal_transfer_history.call_args_list:
            self.assertEqual(history_call.kwargs["start_time_ms"], expected_start)
            self.assertEqual(history_call.kwargs["end_time_ms"], expected_end)

    def test_transfer_history_window_freezes_five_minutes_after_submission(self):
        submitted_at = timezone.now() - timedelta(minutes=10)

        start_ms, end_ms = balance_cap._transfer_history_window(submitted_at, submitted_at)

        self.assertEqual(
            start_ms,
            int((submitted_at - timedelta(seconds=1)).timestamp() * 1000),
        )
        self.assertEqual(
            end_ms,
            int(
                (
                    submitted_at
                    + timedelta(seconds=balance_cap.TRANSFER_RECONCILIATION_WINDOW_SECONDS)
                ).timestamp()
                * 1000
            ),
        )

    def test_deterministic_sub_to_master_rejection_terminates_and_replans(self):
        self.client.get_balance.return_value = _balance("1100")
        self.client.transfer_spot_to_master.side_effect = BinanceApiError(
            "permission denied",
            code="-1002",
        )

        state = balance_cap.normalize_capital(
            self.user,
            self.client,
            "normalization_required",
            purpose="manual_sweep",
        )

        self.assertEqual(state["status"], "normalization_required")
        self.client.transfer_spot_to_master.assert_called_once()
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.status, CapitalSweep.STATUS_FAILED)
        self.assertIsNone(sweep.active_slot)
        self.assertIn("permission denied", sweep.error)

    def test_waits_for_spot_ledger_then_continues_same_sweep(self):
        self.client.get_balance.side_effect = [_balance("1100"), _balance("1000")]
        self.client.get_spot_usdt_free_balance.side_effect = ["0", "0", "100", "100"]
        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required")
        self.assertEqual(state["status"], "collection_pending")
        self.client.transfer_spot_to_master.assert_not_called()
        self.assertEqual(CapitalSweep.objects.get(user=self.user).master_txn_id, "")
        completed = balance_cap.normalize_capital(
            self.user, self.client, "collection_pending", collection_id=state["collection_id"],
        )
        self.assertEqual(completed["reason"], "normalization_completed")
        self.assertEqual(completed["collection_id"], state["collection_id"])
        self.client.transfer_spot_to_master.assert_called_once()
        self.client.transfer_between_spot_and_futures.assert_called_once()

    def test_uncertain_funding_transfer_recovers_from_history_without_repeating(self):
        self.client.get_balance.side_effect = [
            _balance("1000"),
            _balance("1000"),
            _balance("1000"),
        ]
        self.client.get_funding_usdt_free_balance.side_effect = ["20", "0"]
        self.client.get_spot_usdt_free_balance.side_effect = ["10", "30", "30"]
        self.client.transfer_funding_to_spot.side_effect = RuntimeError("timeout")

        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required", purpose="manual_sweep")
        self.assertEqual(state["status"], "collection_pending")
        self.client.get_universal_transfer_history.return_value = [
            {
                "asset": "USDT",
                "type": "FUNDING_MAIN",
                "amount": "20",
                "status": "CONFIRMED",
                "tranId": 654,
            }
        ]
        state = balance_cap.normalize_capital(self.user, self.client, "collection_pending")

        self.assertEqual(state["status"], "ready")
        self.client.transfer_funding_to_spot.assert_called_once()
        self.client.transfer_spot_to_master.assert_called_once_with("30.00000000", ccy="USDT")
        self.assertEqual(CapitalSweep.objects.get(user=self.user).funding_tran_id, "654")

    def test_collects_funding_and_spot_after_refilling_futures_target(self):
        self.client.get_balance.side_effect = [
            _balance("999.99635842"),
            _balance("999.99635842"),
            _balance("999.99635842"),
        ]
        self.client.get_funding_usdt_free_balance.side_effect = ["10", "10", "0"]
        self.client.get_spot_usdt_free_balance.side_effect = ["290", "300"]

        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required", purpose="manual_sweep")

        self.client.transfer_from_funding.assert_not_called()
        self.client.transfer_funding_to_spot.assert_called_once_with("10.00", ccy="USDT")
        self.client.transfer_spot_to_master.assert_called_once_with("300.00", ccy="USDT")
        self.assertEqual(state["status"], "ready")
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.funding_amount, Decimal("10.00"))
        self.assertEqual(sweep.spot_amount, Decimal("290"))

    def test_manual_sweep_refills_funding_then_spot_and_collects_remaining_spot(self):
        """Manual collection uses all available wallets toward the fixed cap."""
        self.client.get_balance.side_effect = [_balance("250"), _balance("300"), _balance("300")]
        self.client.get_funding_usdt_free_balance.side_effect = ["30", "0", "0"]
        self.client.get_spot_usdt_free_balance.side_effect = ["80", "60", "0"]

        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required", purpose="manual_sweep")

        self.client.transfer_from_funding.assert_called_once_with("30.00")
        self.client.transfer_between_spot_and_futures.assert_called_once_with("80.00", to_futures=True)
        self.client.transfer_spot_to_master.assert_not_called()
        self.assertEqual(state["status"], "ready")
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.status, CapitalSweep.STATUS_COMPLETED)
        self.assertEqual(sweep.funding_refill_amount, Decimal("30.00"))
        self.assertEqual(sweep.spot_refill_amount, Decimal("80.00"))
        self.assertIsNone(sweep.active_slot)

    def test_manual_sweep_collects_wallet_balance_when_futures_is_already_in_range(self):
        self.client.get_balance.return_value = _balance("850")
        self.client.get_spot_usdt_free_balance.return_value = "400"

        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required", purpose="manual_sweep")

        self.client.transfer_between_spot_and_futures.assert_called_once_with("150.00", to_futures=True)
        self.client.transfer_spot_to_master.assert_called_once_with("250.00", ccy="USDT")
        self.assertEqual(state["status"], "ready")

    def test_manual_sweep_refills_to_fixed_cap_then_collects_only_remainder(self):
        self.client.get_balance.side_effect = [_balance("850"), _balance("1000")]
        self.client.get_spot_usdt_free_balance.side_effect = ["200", "50", "0"]

        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required", purpose="manual_sweep")

        self.client.transfer_between_spot_and_futures.assert_called_once_with("150.00", to_futures=True)
        self.client.transfer_spot_to_master.assert_called_once_with("50.00", ccy="USDT")
        self.assertEqual(state["status"], "ready")
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.api_key_fingerprint, self.api_key_fingerprint)
        self.assertEqual(sweep.target_balance, Decimal("1000"))
        self.assertEqual(sweep.spot_amount, Decimal("50"))

    def test_manual_sweep_button_is_available_for_partial_refill_even_without_outbound_amount(self):
        self.client.get_balance.side_effect = [_balance("450"), _balance("450"), _balance("550")]
        self.client.get_spot_usdt_free_balance.side_effect = ["100", "100", "0"]

        state = balance_cap.capital_precheck(self.user, self.client, purpose="manual_sweep")

        self.assertEqual(state["status"], "normalization_required")
        self.assertEqual(state["reason"], "futures_refill_available")
        self.assertEqual(state["spot_to_futures"], "100.00")

        normalized = balance_cap.normalize_capital(self.user, self.client, "normalization_required", purpose="manual_sweep")

        self.client.transfer_between_spot_and_futures.assert_called_once_with("100.00", to_futures=True)
        self.client.transfer_spot_to_master.assert_not_called()
        self.assertEqual(normalized["status"], "ready")

    def test_entry_is_ready_from_risk_minimum_to_fixed_cap(self):
        for futures in ("300", "650", "1000"):
            with self.subTest(futures=futures):
                self.client.get_balance.return_value = _balance(futures)
                state = self.precheck()
                self.assertEqual(state["status"], "ready")
                self.assertEqual(state["minimum_open_balance"], "300.0")
                self.assertEqual(state["maximum_futures_balance"], "1000")

    def test_entry_requires_account_page_collection_when_futures_is_below_minimum_but_wallets_can_refill(self):
        self.client.get_balance.return_value = _balance("250")
        self.client.get_funding_usdt_free_balance.return_value = "50"

        state = self.precheck()

        self.assertEqual(state["status"], "normalization_required")
        self.assertEqual(state["reason"], "futures_below_open_minimum")
        self.assertEqual(state["funding_to_futures"], "50.00")
        self.assertEqual(state["target_balance"], "300.00")

    def test_reminder_cycle_never_transfers_and_obeys_cooldown(self):
        self.client.get_balance.return_value = _balance("0")
        self.client.get_spot_usdt_free_balance.return_value = "250"
        with patch.object(balance_cap, "BinanceFuturesClient", return_value=self.client), patch.object(
            balance_cap, "get_user_binance_credentials", return_value=object()
        ):
            balance_cap.run_capital_reminder_cycle()
            balance_cap.run_capital_reminder_cycle()
        self.client.transfer_from_funding.assert_not_called()
        self.client.transfer_between_spot_and_futures.assert_not_called()
        self.client.transfer_spot_to_master.assert_not_called()
        self.assertEqual(len(mail.outbox), 1)
        self.assertIn("距离开仓下限仍差 50.00 USDT", mail.outbox[0].body)
        self.client.get_spot_usdt_balance.assert_not_called()

    def test_reminder_cycle_skips_accounts_with_exchange_activity(self):
        self.client.get_positions.return_value = {"data": [{"symbol": "BTCUSDT"}]}
        with patch.object(balance_cap, "BinanceFuturesClient", return_value=self.client), patch.object(
            balance_cap, "get_user_binance_credentials", return_value=object()
        ):
            balance_cap.run_capital_reminder_cycle()

        self.client.get_balance.assert_not_called()
        self.client.get_spot_usdt_balance.assert_not_called()
        self.assertEqual(len(mail.outbox), 0)

    def test_reminder_cycle_stops_after_shared_rate_limit(self):
        second_user = User.objects.create_user(
            email="cap-second@example.com",
            password="password",
        )
        ApiBinding.objects.create(
            user=second_user,
            api_key="second-key",
            api_key_fingerprint=build_api_key_fingerprint("second-key"),
            secret_key="second-secret",
            status=1,
        )
        with (
            patch.object(balance_cap, "BinanceFuturesClient", return_value=self.client),
            patch.object(balance_cap, "get_user_binance_credentials", return_value=object()),
            patch.object(balance_cap.logger, "exception") as exception_log,
            patch.object(
                balance_cap,
                "capital_precheck",
                side_effect=BinanceApiError("请求过于频繁", code="-1003"),
            ) as precheck,
        ):
            self.assertEqual(balance_cap.run_capital_reminder_cycle(), 0)

        self.assertEqual(precheck.call_count, 1)
        exception_log.assert_not_called()

    def _mark_master_account(self):
        self.client.probe_account_type.return_value = "master"

    def _configure_collect_account(self, value: str):
        self.user.capital_collect_account = value
        self.user.capital_collect_network = "BSC"
        self.user.save(update_fields=["capital_collect_account", "capital_collect_network"])

    def test_master_account_sweeps_excess_to_configured_collect_account(self):
        self._mark_master_account()
        self._configure_collect_account("TQx9d8qM7exampleAddress")
        self.client.get_balance.side_effect = [_balance("1100"), _balance("1100"), _balance("1005"), _balance("1005")]
        self.client.withdraw_to_binance_address.return_value = "withdraw-1"

        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required")

        self.assertEqual(state["status"], "collection_pending")
        self.client.withdraw_to_binance_address.assert_called_once()
        (sent_amount,), sent_kwargs = self.client.withdraw_to_binance_address.call_args
        self.assertEqual(Decimal(sent_amount), Decimal("100"))
        self.assertEqual(sent_kwargs["address"], "TQx9d8qM7exampleAddress")
        self.assertEqual(sent_kwargs["network"], "BSC")
        self.assertEqual(sent_kwargs["ccy"], "USDT")
        self.assertTrue(sent_kwargs["withdraw_order_id"])
        self.client.transfer_spot_to_master.assert_not_called()
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.master_txn_id, "withdraw-1")
        self.assertEqual(sweep.status, CapitalSweep.STATUS_SPOT_PENDING)

        self.client.get_withdraw_history.return_value = [{
            "withdrawOrderId": sweep.master_withdraw_order_id,
            "coin": "USDT",
            "amount": "100",
            "status": "6",
            "transferType": "1",
            "address": "TQx9d8qM7exampleAddress",
            "network": "BSC",
            "id": 790,
        }]
        state = balance_cap.normalize_capital(self.user, self.client, "collection_pending")
        self.assertEqual(state["status"], "ready")
        self.assertEqual(CapitalSweep.objects.get(user=self.user).master_txn_id, "790")
        self.assertIn("TQx9d8qM7exampleAddress", mail.outbox[-1].body)

    def test_master_reconciliation_accepts_exchange_truncated_amount(self):
        # 币安会按币种/网络精度截断提现金额（如 100.00 -> 99.9），
        # 对账必须按容差匹配，否则已成功到账的内部转账会被误判卡死。
        self._mark_master_account()
        self._configure_collect_account("TQx9d8qM7exampleAddress")
        self.client.get_balance.side_effect = [_balance("1100"), _balance("1100"), _balance("1005"), _balance("1005")]
        self.client.withdraw_to_binance_address.return_value = "withdraw-1"

        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required")
        self.assertEqual(state["status"], "collection_pending")
        sweep = CapitalSweep.objects.get(user=self.user)

        self.client.get_withdraw_history.return_value = [{
            "withdrawOrderId": sweep.master_withdraw_order_id,
            "coin": "USDT",
            "amount": "99.9",
            "status": "6",
            "transferType": "1",
            "address": "TQx9d8qM7exampleAddress",
            "network": "BSC",
            "id": 791,
        }]
        state = balance_cap.normalize_capital(self.user, self.client, "collection_pending")
        self.assertEqual(state["status"], "ready")
        self.assertEqual(CapitalSweep.objects.get(user=self.user).master_txn_id, "791")

    def test_pending_master_sweep_keeps_the_destination_frozen_at_creation(self):
        self._mark_master_account()
        self._configure_collect_account("originalDestination")
        self.client.get_balance.side_effect = [
            _balance("1100"),
            _balance("1100"),
            _balance("1005"),
            _balance("1005"),
        ]
        self.client.withdraw_to_binance_address.return_value = "withdraw-1"

        state = balance_cap.normalize_capital(
            self.user,
            self.client,
            "normalization_required",
        )
        self.assertEqual(state["status"], "collection_pending")
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.master_destination_address, "originalDestination")

        self.user.capital_collect_account = "changedDestination"
        self.user.capital_collect_network = "TRX"
        self.user.save(update_fields=["capital_collect_account", "capital_collect_network"])
        self.client.get_withdraw_history.return_value = [{
            "withdrawOrderId": sweep.master_withdraw_order_id,
            "coin": "USDT",
            "amount": "100",
            "status": "6",
            "transferType": "1",
            "address": "originalDestination",
            "network": "BSC",
            "id": 792,
        }]

        completed = balance_cap.normalize_capital(
            self.user,
            self.client,
            "collection_pending",
        )

        self.assertEqual(completed["status"], "ready")
        sweep.refresh_from_db()
        self.assertEqual(sweep.master_destination_address, "originalDestination")
        self.assertEqual(sweep.master_destination_network, "BSC")
        sent_kwargs = self.client.withdraw_to_binance_address.call_args.kwargs
        self.assertEqual(sent_kwargs["address"], "originalDestination")
        self.assertEqual(sent_kwargs["network"], "BSC")

    def test_master_account_without_collect_account_blocks_sweep_before_transfers(self):
        self._mark_master_account()
        self.client.get_balance.return_value = _balance("1100")

        with self.assertRaisesMessage(ValueError, "充值网络和地址"):
            balance_cap.normalize_capital(self.user, self.client, "normalization_required")

        self.client.transfer_between_spot_and_futures.assert_not_called()
        self.client.withdraw_to_binance_address.assert_not_called()

    def test_master_account_with_legacy_network_blocks_before_transfers(self):
        self._mark_master_account()
        self.user.capital_collect_account = "TQx9d8qM7exampleAddress"
        self.user.capital_collect_network = "SOL"
        self.user.save(update_fields=["capital_collect_account", "capital_collect_network"])
        self.client.get_balance.return_value = _balance("1100")

        with self.assertRaisesMessage(ValueError, "充值网络和地址"):
            balance_cap.normalize_capital(self.user, self.client, "normalization_required")

        self.client.transfer_from_funding.assert_not_called()
        self.client.transfer_between_spot_and_futures.assert_not_called()
        self.client.withdraw_to_binance_address.assert_not_called()

    def test_master_internal_transfer_recovers_from_withdraw_history(self):
        self._mark_master_account()
        self._configure_collect_account("TQx9d8qM7exampleAddress")
        self.client.get_balance.side_effect = [
            _balance("1100"),
            _balance("1100"),
            _balance("1100"),
            _balance("1100"),
            _balance("1005"),
        ]
        self.client.withdraw_to_binance_address.side_effect = RuntimeError("timeout")
        # 首次确认时历史查询本身失败：结果未知，保持 pending 不重试。
        self.client.get_withdraw_history.side_effect = RuntimeError("history unavailable")

        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required")
        self.assertEqual(state["status"], "collection_pending")

        sweep = CapitalSweep.objects.get(user=self.user)
        self.client.get_withdraw_history.side_effect = None
        self.client.get_withdraw_history.return_value = [{
            "withdrawOrderId": sweep.master_withdraw_order_id,
            "coin": "USDT", "amount": "100", "status": "6", "transferType": "1",
            "txId": "INNER_WITHDRAW_9", "id": 321,
        }]
        state = balance_cap.normalize_capital(self.user, self.client, "collection_pending")

        self.assertEqual(state["status"], "ready")
        self.client.withdraw_to_binance_address.assert_called_once()
        self.assertEqual(CapitalSweep.objects.get(user=self.user).master_txn_id, "321")

    def test_master_reconciliation_treats_exact_onchain_withdrawal_as_terminal(self):
        self._mark_master_account()
        self._configure_collect_account("TQx9d8qM7exampleAddress")
        self.client.get_balance.side_effect = [_balance("1100"), _balance("1100"), _balance("1005"), _balance("1005")]
        self.client.withdraw_to_binance_address.side_effect = RuntimeError("timeout")
        # 首次确认时历史查询本身失败：结果未知，保持 pending 不重试。
        self.client.get_withdraw_history.side_effect = RuntimeError("history unavailable")

        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required")
        self.assertEqual(state["status"], "collection_pending")

        # Binance 选择链上路径时资金已经离开现货；必须终结流水且不能重试。
        sweep = CapitalSweep.objects.get(user=self.user)
        self.client.get_withdraw_history.side_effect = None
        self.client.get_withdraw_history.return_value = [
            {"withdrawOrderId": sweep.master_withdraw_order_id, "coin": "USDT", "amount": "100", "status": "6", "transferType": "0", "txId": "0xabc123", "id": 322}
        ]
        state = balance_cap.normalize_capital(self.user, self.client, "collection_pending")

        self.assertEqual(state["status"], "ready")
        self.assertEqual(self.client.withdraw_to_binance_address.call_count, 1)
        completed = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(completed.status, CapitalSweep.STATUS_COMPLETED)
        self.assertEqual(completed.master_transfer_kind, CapitalSweep.MASTER_TRANSFER_ONCHAIN)
        self.assertIn("链上转出", mail.outbox[-1].body)

    def test_master_missing_withdraw_history_never_allows_automatic_resubmit(self):
        # 空历史不能证明提现请求失败；宁可等待人工核验，也不能重复转出。
        self._mark_master_account()
        self._configure_collect_account("TQx9d8qM7exampleAddress")
        self.client.get_balance.return_value = _balance("1100")
        self.client.withdraw_to_binance_address.side_effect = RuntimeError("timeout")
        # 首次确认时历史查询本身失败：结果未知，保持 pending 不重试。
        self.client.get_withdraw_history.side_effect = RuntimeError("history unavailable")

        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required")
        self.assertEqual(state["status"], "collection_pending")
        sweep = CapitalSweep.objects.get(user=self.user)
        sweep.master_attempted_at = timezone.now() - timedelta(minutes=5)
        sweep.save(update_fields=["master_attempted_at", "updated_at"])
        self.client.get_withdraw_history.side_effect = None
        self.client.get_withdraw_history.return_value = []

        state = balance_cap.normalize_capital(self.user, self.client, "collection_pending")

        self.assertEqual(state["status"], "collection_pending")
        self.assertEqual(self.client.withdraw_to_binance_address.call_count, 1)
        sweep.refresh_from_db()
        self.assertEqual(sweep.status, CapitalSweep.STATUS_SPOT_PENDING)
        self.assertIn("不会重复转账", sweep.error)

    def test_http_5xx_withdrawal_result_never_allows_automatic_resubmit(self):
        self._mark_master_account()
        self._configure_collect_account("TQx9d8qM7exampleAddress")
        self.client.get_balance.return_value = _balance("1100")
        self.client.withdraw_to_binance_address.side_effect = BinanceApiError(
            "Binance 请求失败 (http: 503)",
            code="503",
            outcome_unknown=True,
        )
        self.client.get_withdraw_history.return_value = []

        first = balance_cap.normalize_capital(
            self.user,
            self.client,
            "normalization_required",
            purpose="manual_sweep",
        )
        second = balance_cap.normalize_capital(
            self.user,
            self.client,
            "collection_pending",
            purpose="manual_sweep",
        )

        self.assertEqual(first["status"], "collection_pending")
        self.assertEqual(second["status"], "collection_pending")
        self.client.withdraw_to_binance_address.assert_called_once()
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.status, CapitalSweep.STATUS_SPOT_PENDING)
        self.assertEqual(sweep.active_slot, 1)
        self.assertIsNotNone(sweep.master_attempted_at)

    def test_master_missing_withdraw_history_stays_pending_during_visibility_grace(self):
        self._mark_master_account()
        self._configure_collect_account("TQx9d8qM7exampleAddress")
        self.client.get_balance.return_value = _balance("1100")
        self.client.withdraw_to_binance_address.side_effect = RuntimeError("timeout")
        self.client.get_withdraw_history.side_effect = RuntimeError("history unavailable")

        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required")
        self.assertEqual(state["status"], "collection_pending")

        self.client.get_withdraw_history.side_effect = None
        self.client.get_withdraw_history.return_value = []
        state = balance_cap.normalize_capital(self.user, self.client, "collection_pending")

        self.assertEqual(state["status"], "collection_pending")
        self.assertIn("尚未同步", state["collection_error"])
        self.client.withdraw_to_binance_address.assert_called_once()
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.status, CapitalSweep.STATUS_SPOT_PENDING)

    def test_master_internal_transfer_failure_surfaces_exchange_reason(self):
        self._mark_master_account()
        self._configure_collect_account("TQx9d8qM7exampleAddress")
        self.client.get_balance.return_value = _balance("1100")
        self.client.withdraw_to_binance_address.side_effect = BinanceApiError(
            "You don't have permission to withdraw", code="-8020"
        )

        state = balance_cap.normalize_capital(self.user, self.client, "normalization_required")

        # 被交易所明确拒绝：流水终结并按最新余额重规划，给出可操作状态。
        self.assertEqual(state["status"], "normalization_required")
        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertIn("被 Binance 拒绝", sweep.error)
        self.assertIn("withdraw", sweep.error)
        self.assertEqual(sweep.status, CapitalSweep.STATUS_FAILED)
        self.assertIsNone(sweep.active_slot)

    def test_master_withdraw_history_reason_is_redacted_before_persistence(self):
        self._mark_master_account()
        self._configure_collect_account("TQx9d8qM7exampleAddress")
        sweep = CapitalSweep.objects.create(
            user=self.user,
            api_key_fingerprint=self.api_key_fingerprint,
            amount=Decimal("100"),
            target_balance=Decimal("1000"),
            status=CapitalSweep.STATUS_SPOT_PENDING,
            master_attempted_at=timezone.now(),
            master_withdraw_order_id="tt-redaction-test",
            master_destination_address="TQx9d8qM7exampleAddress",
            master_destination_network="BSC",
        )
        self.client.get_withdraw_history.return_value = [{
            "withdrawOrderId": "tt-redaction-test",
            "coin": "USDT",
            "amount": "100",
            "status": "3",
            "address": "TQx9d8qM7exampleAddress",
            "network": "BSC",
            "info": "failed token=history-secret https://example.test/?signature=url-secret",
        }]

        completed = balance_cap._complete_spot_to_collect_account(
            self.client,
            sweep,
            collect_address="TQx9d8qM7exampleAddress",
            collect_network="BSC",
        )

        self.assertFalse(completed)
        sweep.refresh_from_db()
        self.assertNotIn("history-secret", sweep.error)
        self.assertNotIn("url-secret", sweep.error)
        self.assertIn("[redacted", sweep.error)

    def test_submitted_master_sweep_stays_pending_when_collect_account_missing(self):
        self._mark_master_account()
        CapitalSweep.objects.create(
            user=self.user,
            amount=Decimal("100"),
            target_balance=Decimal("1000"),
            futures_amount=Decimal("100"),
            status=CapitalSweep.STATUS_SPOT_PENDING,
            master_attempted_at=timezone.now(),
            master_withdraw_order_id="frozen-order",
        )
        self.client.get_balance.return_value = _balance("1000")

        state = balance_cap.normalize_capital(self.user, self.client, "collection_pending")

        sweep = CapitalSweep.objects.get(user=self.user)
        self.assertEqual(sweep.status, CapitalSweep.STATUS_SPOT_PENDING)
        self.assertEqual(sweep.active_slot, 1)
        self.assertEqual(state["status"], "collection_pending")
        self.client.withdraw_to_binance_address.assert_not_called()


class MasterAccountDetectionCacheTests(TestCase):
    def setUp(self):
        cache.clear()

    def test_positive_probe_result_is_cached(self):
        from common.binance import BinanceCredentials, BinanceFuturesClient

        client = BinanceFuturesClient(BinanceCredentials(api_key="k", secret_key="s"))
        with patch.object(
            client,
            "_request",
            return_value={"subAccounts": []},
        ) as mock_request:
            self.assertTrue(balance_cap._is_master_account(client))
            self.assertTrue(balance_cap._is_master_account(client))
        # 正命中缓存 5 分钟：重复判定不再重复探测交易所
        mock_request.assert_called_once()

    def test_unknown_probe_is_not_cached(self):
        client = MagicMock()
        client.credentials.api_key = "unknown-key"
        client.probe_account_type.side_effect = ["unknown", "sub"]
        self.assertEqual(balance_cap.account_type_for_client(client), "unknown")
        self.assertEqual(balance_cap.account_type_for_client(client), "sub")
        self.assertEqual(client.probe_account_type.call_count, 2)


class CapitalSweepFingerprintMigrationTests(TestCase):
    def test_backfill_does_not_claim_sweeps_from_before_the_current_binding(self):
        user = User.objects.create_user(email="migration-cap@example.com", password="password")
        fingerprint = build_api_key_fingerprint("current-key")
        binding = ApiBinding.objects.create(
            user=user,
            api_key="current-key",
            api_key_fingerprint=fingerprint,
            secret_key="secret",
            status=1,
        )
        boundary = timezone.now() - timedelta(hours=1)
        ApiBinding.objects.filter(pk=binding.pk).update(created_at=boundary)
        old_sweep = CapitalSweep.objects.create(
            user=user,
            amount=Decimal("10"),
            target_balance=Decimal("100"),
            status=CapitalSweep.STATUS_FAILED,
        )
        current_sweep = CapitalSweep.objects.create(
            user=user,
            amount=Decimal("20"),
            target_balance=Decimal("100"),
            status=CapitalSweep.STATUS_COMPLETED,
        )
        CapitalSweep.objects.filter(pk=old_sweep.pk).update(
            created_at=boundary - timedelta(seconds=1),
        )
        CapitalSweep.objects.filter(pk=current_sweep.pk).update(
            created_at=boundary + timedelta(seconds=1),
        )

        migration = importlib.import_module(
            "trading.migrations.0014_capitalsweep_api_key_fingerprint"
        )
        migration.backfill_api_key_fingerprints(apps, None)

        old_sweep.refresh_from_db()
        current_sweep.refresh_from_db()
        self.assertIsNone(old_sweep.api_key_fingerprint)
        self.assertEqual(current_sweep.api_key_fingerprint, fingerprint)
