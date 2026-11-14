"""Wallet actions use exchange substitutes; no live transfers."""
from decimal import Decimal
from unittest.mock import MagicMock, patch
from uuid import uuid4

from django.core.cache import cache
from django.test import TestCase

from api_bindings.models import ApiBinding
from api_bindings.services import build_api_key_fingerprint
from trading import capital_wallet
from trading.models import CapitalSweep
from users.models import User


class CapitalWalletTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="wallet@example.invalid", password="test")
        self.user.stop_loss_amount = Decimal("200")
        self.user.save(update_fields=["stop_loss_amount"])
        self.fingerprint = build_api_key_fingerprint("wallet-key")
        ApiBinding.objects.create(user=self.user, api_key="wallet-key", secret_key="test",
                                  api_key_fingerprint=self.fingerprint, status=1)
        self.exchange = MagicMock()
        self.exchange.credentials.api_key = "wallet-key"
        self.exchange.get_positions.return_value = {"data": []}
        self.exchange.get_pending_orders.return_value = {"data": []}
        self.exchange.get_pending_algo_orders.return_value = {"data": []}
        self.exchange.get_balance.return_value = {"data": [{"details": [{"eq": "1200", "availEq": "1200"}]}]}
        self.exchange.get_funding_usdt_free_balance.return_value = "50"
        self.exchange.get_spot_usdt_free_balance.return_value = "80"
        self.exchange.probe_account_type.return_value = "sub"
        self.exchange.transfer_between_spot_and_futures.return_value = "futures-receipt"
        self.exchange.transfer_from_funding.return_value = "refill-receipt"
        self.exchange.transfer_funding_to_spot.return_value = "funding-receipt"
        self.exchange.transfer_spot_to_master.return_value = "master-receipt"
        def futures_transfer(amount, *, to_futures):
            details = self.exchange.get_balance.return_value["data"][0]["details"][0]
            delta = Decimal(amount) * (1 if to_futures else -1)
            details["eq"] = str(Decimal(details["eq"]) + delta)
            details["availEq"] = details["eq"]
            return "futures-receipt"
        self.exchange.transfer_between_spot_and_futures.side_effect = futures_transfer

    def preview(self, action="to_spot"):
        return capital_wallet.wallet_precheck(self.user, self.exchange, action=action)

    def execute(self, action="to_spot", request_id=None, preview=None):
        return capital_wallet.execute_wallet_operation(
            self.user, self.exchange, action=action, request_id=request_id or uuid4(),
            expected_plan=(preview or self.preview(action))["plan_token"])

    def test_collect_only_futures_excess_and_funding_to_spot(self):
        plan = self.preview()
        self.assertEqual(plan["operation_amount"], "250.00")
        self.assertEqual(plan["futures_collect"], "200.00")
        self.assertEqual(plan["funding_collect"], "50.00")
        result = self.execute(preview=plan)
        self.assertEqual(result["reason"], "normalization_completed")
        self.exchange.transfer_between_spot_and_futures.assert_called_once_with("200.00", to_futures=False)
        self.exchange.transfer_funding_to_spot.assert_called_once_with("50.00", ccy="USDT")
        self.exchange.transfer_spot_to_master.assert_not_called()
        self.exchange.withdraw_to_binance_address.assert_not_called()
        self.exchange.probe_account_type.assert_not_called()

    def test_refill_directions_are_independent_and_never_exceed_cap(self):
        for action, method in [("funding_to_futures", "transfer_from_funding"),
                               ("spot_to_futures", "transfer_between_spot_and_futures")]:
            with self.subTest(action=action):
                self.exchange.get_balance.return_value["data"][0]["details"][0]["eq"] = "980"
                self.assertEqual(self.preview(action)["operation_amount"], "20.00")
                self.execute(action)
                self.assertEqual(getattr(self.exchange, method).call_args.args, ("20.00",))
        self.exchange.transfer_funding_to_spot.assert_not_called()
        self.exchange.transfer_spot_to_master.assert_not_called()

    def test_outward_transfer_uses_spot_only(self):
        plan = self.preview("transfer")
        self.assertEqual(plan["operation_amount"], "80.00")
        self.execute("transfer", preview=plan)
        self.exchange.transfer_spot_to_master.assert_called_once_with("80.00", ccy="USDT")
        self.exchange.transfer_between_spot_and_futures.assert_not_called()
        self.exchange.transfer_funding_to_spot.assert_not_called()

    def test_completed_request_replay_never_submits_again(self):
        request_id = uuid4()
        plan = self.preview()
        first = self.execute(request_id=request_id, preview=plan)
        second = self.execute(request_id=request_id, preview=plan)
        self.assertEqual(first["collection_id"], second["collection_id"])
        self.assertEqual(CapitalSweep.objects.count(), 1)
        self.exchange.transfer_funding_to_spot.assert_called_once()

    def test_wallet_change_requires_review_before_any_transfer(self):
        plan = self.preview()
        self.exchange.get_funding_usdt_free_balance.return_value = "60"
        result = self.execute(preview=plan)
        self.assertTrue(result["plan_changed"])
        self.assertEqual(CapitalSweep.objects.count(), 0)
        self.exchange.transfer_between_spot_and_futures.assert_not_called()

    def test_unknown_first_transfer_is_queried_and_never_replayed(self):
        self.exchange.transfer_between_spot_and_futures.side_effect = TimeoutError()
        self.exchange.get_spot_futures_transfer_history.return_value = []
        request_id = uuid4()
        plan = self.preview()
        first = self.execute(request_id=request_id, preview=plan)
        self.assertEqual(first["status"], "collection_pending")
        self.execute(request_id=request_id, preview=plan)
        self.preview("transfer")
        self.exchange.transfer_between_spot_and_futures.assert_called_once()
        self.exchange.transfer_funding_to_spot.assert_not_called()
        self.exchange.transfer_spot_to_master.assert_not_called()

    def test_refresh_only_confirms_receipt_without_submitting_next_step(self):
        self.exchange.transfer_between_spot_and_futures.side_effect = TimeoutError()
        self.execute()
        with patch("trading.balance_cap._matching_futures_to_spot_transfer", return_value="confirmed"):
            state = self.preview()
        self.assertEqual(state["status"], "collection_pending")
        self.exchange.transfer_funding_to_spot.assert_not_called()

    def test_real_position_and_both_order_types_block_all_actions(self):
        for method, value in [("get_positions", {"data": [{"pos": "1"}]}),
                              ("get_pending_orders", {"data": [{"ordId": "1"}]}),
                              ("get_pending_algo_orders", {"data": [{"algoId": "1"}]})]:
            with self.subTest(method=method):
                getattr(self.exchange, method).return_value = value
                for action in capital_wallet.WALLET_ACTIONS:
                    self.assertEqual(self.preview(action)["status"], "blocked")
                getattr(self.exchange, method).return_value = {"data": []}

    def test_dust_and_exact_cap_have_no_futures_transfer(self):
        self.exchange.get_balance.return_value["data"][0]["details"][0]["eq"] = "1000"
        self.exchange.get_funding_usdt_free_balance.return_value = "0.99"
        self.assertEqual(self.preview()["status"], "ready")
        self.assertEqual(self.preview()["operation_amount"], "0.00")

    def test_to_spot_executes_only_futures_excess_at_fixed_cap_boundaries(self):
        self.user.stop_loss_amount = Decimal("50")
        self.user.save(update_fields=["stop_loss_amount"])
        self.exchange.get_funding_usdt_free_balance.return_value = "0.99"
        for futures, excess in (("1000", "0.00"), ("1000.01", "0.01"), ("1000.50", "0.50")):
            with self.subTest(futures=futures):
                self.exchange.get_balance.return_value = {"data": [{"details": [{"eq": futures, "availEq": futures}]}]}
                self.exchange.transfer_between_spot_and_futures.reset_mock()
                plan = self.preview()
                self.assertEqual(Decimal(plan["operation_amount"]), Decimal(excess))
                self.assertEqual(Decimal(plan["futures_collect"]), Decimal(excess))
                result = self.execute(preview=plan)
                if excess == "0.00":
                    self.assertEqual(result["status"], "ready")
                    self.exchange.transfer_between_spot_and_futures.assert_not_called()
                else:
                    self.assertEqual(result["reason"], "normalization_completed")
                    self.exchange.transfer_between_spot_and_futures.assert_called_once_with(excess, to_futures=False)
                    self.assertEqual(Decimal(result["target"]), Decimal("1000"))
        self.exchange.transfer_funding_to_spot.assert_not_called()
        self.exchange.transfer_spot_to_master.assert_not_called()
        self.assertEqual(CapitalSweep.objects.count(), 2)

    def test_foreign_binding_pending_operation_blocks(self):
        CapitalSweep.objects.create(user=self.user, api_key_fingerprint="another-key", amount=0, target_balance=1000)
        self.assertEqual(self.preview()["status"], "blocked")

    def test_request_id_cannot_change_action(self):
        request_id = uuid4()
        self.execute(request_id=request_id)
        with self.assertRaisesMessage(ValueError, "请求编号"):
            self.execute("transfer", request_id=request_id)

    def test_new_position_between_steps_pauses_before_next_transfer(self):
        original = self.exchange.transfer_between_spot_and_futures.side_effect
        def transfer_then_position(*args, **kwargs):
            receipt = original(*args, **kwargs)
            self.exchange.get_positions.return_value = {"data": [{"pos": "1"}]}
            return receipt
        self.exchange.transfer_between_spot_and_futures.side_effect = transfer_then_position
        result = self.execute()
        self.assertEqual(result["status"], "collection_pending")
        self.exchange.transfer_funding_to_spot.assert_not_called()

    def test_legacy_endpoint_cannot_resume_a_new_wallet_operation(self):
        self.exchange.transfer_between_spot_and_futures.side_effect = TimeoutError()
        state = self.execute()
        from trading import balance_cap
        with self.assertRaisesMessage(ValueError, "划转 / 转账"):
            balance_cap.normalize_capital(self.user, self.exchange, "collection_pending", collection_id=state["collection_id"])
        balance_cap.refresh_capital_precheck(self.user, self.exchange)
        self.exchange.transfer_between_spot_and_futures.assert_called_once()

    def test_http_rejects_lead_and_invalid_action_without_exchange_calls(self):
        from rest_framework.test import APIClient
        http = APIClient()
        http.force_authenticate(self.user)
        for path in ("precheck", "execute"):
            response = http.post("/v1/trade/capital/wallet/" + path, {"action": "to_spot"}, format="json", HTTP_X_TRADING_MODE="lead")
            self.assertEqual(response.status_code, 400)
        response = http.post("/v1/trade/capital/wallet/precheck", {"action": "invalid"}, format="json")
        self.assertEqual(response.status_code, 400)
        self.exchange.get_balance.assert_not_called()

    def test_master_transfer_freezes_address_and_does_not_repeat_accepted_withdrawal(self):
        self.exchange.probe_account_type.return_value = "master"
        self.user.capital_collect_account = "0x123456789012345678901234567890123456BEEF"
        self.user.capital_collect_network = "BSC"
        self.user.save(update_fields=["capital_collect_account", "capital_collect_network"])
        self.exchange.withdraw_to_binance_address.return_value = "withdraw-receipt"
        self.exchange.get_withdraw_history.return_value = []
        request_id = uuid4()
        preview = self.preview("transfer")
        first = self.execute("transfer", request_id=request_id, preview=preview)
        self.assertEqual(first["status"], "collection_pending")
        self.assertEqual(first["destination_address"], self.user.capital_collect_account)
        self.user.capital_collect_account = "0xOTHER"
        self.user.save(update_fields=["capital_collect_account"])
        self.execute("transfer", request_id=request_id, preview=preview)
        self.exchange.withdraw_to_binance_address.assert_called_once()
        self.assertEqual(self.exchange.withdraw_to_binance_address.call_args.kwargs["address"],
                         "0x123456789012345678901234567890123456BEEF")
        self.exchange.transfer_between_spot_and_futures.assert_not_called()

    def test_legacy_pending_journal_requires_legacy_confirmation(self):
        old = CapitalSweep.objects.create(user=self.user, api_key_fingerprint=self.fingerprint,
                                         amount=50, target_balance=1000)
        state = capital_wallet.execute_wallet_operation(self.user, self.exchange, action="to_spot", request_id=uuid4())
        self.assertEqual(state["operation"], "")
        self.assertEqual(state["collection_id"], old.pk)
        self.exchange.transfer_between_spot_and_futures.assert_not_called()
        self.exchange.transfer_spot_to_master.assert_not_called()

    def test_http_preview_and_execution_dispatch_the_confirmed_action(self):
        from rest_framework.test import APIClient
        http = APIClient()
        http.force_authenticate(self.user)
        with patch("trading.capital_wallet_views.get_user_binance_credentials", return_value=object()), \
             patch("trading.capital_wallet_views.BinanceFuturesClient", return_value=self.exchange):
            response = http.post("/v1/trade/capital/wallet/precheck", {"action": "to_spot"}, format="json")
            self.assertEqual(response.status_code, 200)
            plan = response.data["data"]
            response = http.post("/v1/trade/capital/wallet/execute", {
                "action": "to_spot", "request_id": str(uuid4()), "expected_plan": plan["plan_token"],
            }, format="json")
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.data["data"]["reason"], "normalization_completed")
            self.exchange.transfer_spot_to_master.assert_not_called()
