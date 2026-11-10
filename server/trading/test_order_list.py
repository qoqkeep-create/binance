from datetime import timedelta
from decimal import Decimal
from uuid import uuid4
from unittest.mock import patch

from django.db import connection
from django.utils import timezone
from rest_framework.test import APITestCase

from api_bindings.models import ApiBinding
from mobile.models import AccountFact, TradingCommand
from positions.models import LimitOrder, Order
from trading.models import TradeOpenRequest
from users.models import User


class UnifiedOrderListTests(APITestCase):
    url = "/v1/trade/order/list"

    def setUp(self):
        self.user = User.objects.create_user("order-list@example.invalid", "test-only-password")
        self.client.force_authenticate(self.user)
        self.binding = ApiBinding.objects.create(
            user=self.user, alias="test", api_key="unused-placeholder",
            secret_key="unused-placeholder", passphrase="", api_key_fingerprint="a" * 64,
        )
        self.now = timezone.now()
        self.binding.created_at = self.now - timedelta(hours=1)
        self.binding.save(update_fields=["created_at"])

    def limit(self, **changes):
        values = dict(
            user=self.user, trading_mode="ordinary", api_key_fingerprint=self.binding.api_key_fingerprint,
            binance_order_id=str(uuid4()), symbol="BTCUSDT", side=0,
            limit_price=Decimal("100"), stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("20"), size=Decimal("2"), leverage=10,
        )
        values.update(changes)
        return LimitOrder.objects.create(**values)

    def maker(self, **changes):
        values = dict(
            user=self.user, trading_mode="ordinary", api_key_fingerprint=self.binding.api_key_fingerprint,
            symbol="BTCUSDT", client_request_id=str(uuid4()), client_order_id=str(uuid4()),
            binance_order_id=str(uuid4()), status=TradeOpenRequest.STATUS_SUBMITTED,
            request_payload={"_execution_intent": {
                "execution_mode": "maker", "maker_price": "100", "size": "2",
                "side_code": 0, "stop_loss_price": "90", "stop_loss_amount": "20", "leverage": 10,
            }},
        )
        values.update(changes)
        return TradeOpenRequest.objects.create(**values)

    def fact(self, maker, **payload):
        return AccountFact.objects.create(
            user=self.user, binding_id_snapshot=self.binding.pk, trading_mode="ordinary", kind="order",
            identity=f"{maker.symbol}:{maker.binance_order_id}",
            event_time=int((self.now + timedelta(seconds=60)).timestamp() * 1000),
            payload={"s": maker.symbol, "i": maker.binance_order_id, "c": maker.client_order_id,
                     "X": "NEW", "z": "0", "ap": "0", **payload},
        )

    def position(self, maker, **changes):
        values = dict(
            user=self.user, trading_mode="ordinary", api_key_fingerprint=self.binding.api_key_fingerprint,
            binance_order_id=maker.binance_order_id, symbol=maker.symbol, side=0,
            open_price=Decimal("101"), stop_loss_price=Decimal("90"), stop_loss_amount=Decimal("20"),
            size=Decimal("2"), leverage=10,
        )
        values.update(changes)
        return Order.objects.create(**values)

    def dated(self, record, seconds):
        type(record).objects.filter(pk=record.pk).update(created_at=self.now + timedelta(seconds=seconds))

    def command(self, maker, *, action="maker-fallback", result=None, **changes):
        values = dict(
            user=self.user, binding_id_snapshot=self.binding.pk,
            binding_fingerprint=self.binding.api_key_fingerprint, binding_created_at=self.binding.created_at,
            trading_mode="ordinary", idempotency_key=str(uuid4()), request_hash="test-only-hash",
            action=action, payload={"client_request_id": maker.client_request_id, "cancel_only": True},
            status="SUCCEEDED", result=result or {"code": 200, "data": {"state": "CANCELLED", "filled_size": "0.5"}},
        )
        if action == "open":
            values["id"] = maker.client_request_id
        values.update(changes)
        command = TradingCommand.objects.create(**values)
        TradingCommand.objects.filter(pk=command.pk).update(updated_at=self.now + timedelta(seconds=120))
        return command

    def test_mixed_pages_retain_filled_records_and_distinguish_same_source_ids(self):
        pending = self.limit()
        filled = self.limit(status=LimitOrder.STATUS_FILLED, filled_size=Decimal("2"))
        maker = self.maker()
        position = self.position(maker, status=1, closed_at=self.now)
        TradeOpenRequest.objects.filter(pk=maker.pk).update(order_id=position.pk)
        self.fact(maker, X="FILLED", z="2", ap="101")
        for record, seconds in [(pending, -3), (filled, -2), (maker, -1)]:
            self.dated(record, seconds)

        response = self.client.get(self.url, {"page_size": 2})
        self.assertEqual(response.status_code, 200)
        data = response.data["data"]
        self.assertEqual([row["id"] for row in data["items"]], [f"maker:{maker.pk}", f"limit:{filled.pk}"])
        self.assertEqual(data["pagination"], {
            "page": 1, "page_size": 2, "total": 3, "has_next": True, "has_previous": False,
        })
        self.assertEqual(data["items"][0]["status"], 1)
        self.assertEqual(data["items"][0]["filled_amount"], "202")
        self.assertEqual(data["items"][0]["position_id"], position.pk)
        second = self.client.get(self.url, {"page_size": 2, "page": 2}).data["data"]
        self.assertEqual([row["id"] for row in second["items"]], [f"limit:{pending.pk}"])
        self.assertFalse(second["pagination"]["has_next"])
        self.assertNotEqual(f"limit:{pending.pk}", f"maker:{maker.pk}")

    def test_partial_fill_keeps_quantity_when_average_price_is_unknown(self):
        maker = self.maker()
        self.fact(maker, X="PARTIALLY_FILLED", z="0.5", ap=None)
        row = self.client.get(self.url).data["data"]["items"][0]
        self.assertEqual((row["status"], row["status_text"], row["filled_size"]), (0, "部分成交", "0.5"))
        self.assertIsNone(row["filled_amount"])
        self.assertIsNone(row["average_price"])
        self.assertTrue(row["can_cancel"])
        self.assertFalse(row["can_chase"])

    def test_submitted_without_fill_evidence_never_invents_zero_or_success(self):
        maker = self.maker()
        row = self.client.get(self.url).data["data"]["items"][0]
        self.assertEqual(row["id"], f"maker:{maker.pk}")
        self.assertEqual(row["status"], 4)
        self.assertIsNone(row["filled_size"])
        self.assertIsNone(row["filled_amount"])
        self.assertFalse(row["can_cancel"])

    def test_discovered_order_without_local_exchange_id_has_no_cancel_capability(self):
        maker = self.maker()
        self.fact(maker)
        TradeOpenRequest.objects.filter(pk=maker.pk).update(binance_order_id="")
        row = self.client.get(self.url).data["data"]["items"][0]
        self.assertEqual((row["status"], row["filled_size"]), (0, "0"))
        self.assertFalse(row["can_cancel"])

    def test_original_maker_fact_survives_fallback_order_id_replacement(self):
        maker = self.maker()
        original = maker.binance_order_id
        self.fact(maker, X="CANCELED", z="0.5", ap="100")
        fallback_id = str(uuid4())
        intent = maker.request_payload["_execution_intent"]
        intent.update(fallback_client_order_id="market-remainder", maker_filled_size="0.5")
        maker.binance_order_id = fallback_id
        maker.save(update_fields=["binance_order_id", "request_payload", "updated_at"])
        self.fact(maker, c="market-remainder", X="FILLED", z="1.5", ap="110")

        row = self.client.get(self.url).data["data"]["items"][0]
        self.assertNotEqual(original, fallback_id)
        self.assertEqual((row["status"], row["filled_size"], row["filled_amount"]), (2, "0.5", "50"))
        self.assertFalse(row["can_cancel"])

    def test_newer_cancel_receipt_overrides_an_older_new_fact(self):
        maker = self.maker()
        self.fact(maker)
        self.command(maker)
        row = self.client.get(self.url).data["data"]["items"][0]
        self.assertEqual((row["status"], row["filled_size"]), (2, "0.5"))
        self.assertIsNone(row["filled_amount"])
        self.assertFalse(row["can_cancel"])

    def test_confirmed_pending_receipt_is_visible_without_stream_facts(self):
        maker = self.maker()
        self.command(maker, action="open", result={"code": 200, "data": {
            "state": "PENDING_MAKER", "maker_order_id": maker.binance_order_id,
            "client_request_id": maker.client_request_id, "symbol": maker.symbol,
        }})
        row = self.client.get(self.url).data["data"]["items"][0]
        self.assertEqual((row["status"], row["status_text"]), (0, "待成交"))
        self.assertIsNone(row["filled_size"])
        self.assertFalse(row["can_cancel"])

    def test_partial_adopted_order_and_succeeded_command_do_not_claim_full_fill(self):
        maker = self.maker()
        position = self.position(maker, size=Decimal("0.5"))
        TradeOpenRequest.objects.filter(pk=maker.pk).update(order_id=position.pk)
        self.command(maker, action="maker-status", result={"code": 200, "data": {
            "state": "SUCCEEDED", "position_id": position.pk,
        }})
        row = self.client.get(self.url).data["data"]["items"][0]
        self.assertEqual((row["status"], row["filled_size"]), (4, "0.5"))
        self.assertFalse(row["can_cancel"])

    def test_exact_original_fully_adopted_position_stays_filled_after_close_without_stream_fact(self):
        maker = self.maker()
        position = self.position(maker, status=1, closed_at=self.now)
        TradeOpenRequest.objects.filter(pk=maker.pk).update(order_id=position.pk)
        row = self.client.get(self.url).data["data"]["items"][0]
        self.assertEqual((row["status"], row["filled_size"], row["filled_amount"]), (1, "2", "202"))
        self.assertEqual(row["position_id"], position.pk)
        self.assertFalse(row["can_cancel"])

    def test_fully_adopted_position_supersedes_stale_nonterminal_evidence(self):
        for state in ["NEW", "PARTIALLY_FILLED", "PENDING_MAKER"]:
            with self.subTest(state=state):
                AccountFact.objects.all().delete()
                TradingCommand.objects.all().delete()
                TradeOpenRequest.objects.all().delete()
                maker = self.maker()
                position = self.position(maker)
                TradeOpenRequest.objects.filter(pk=maker.pk).update(order_id=position.pk)
                if state == "PENDING_MAKER":
                    self.command(maker, action="open", result={"code": 200, "data": {
                        "state": state, "maker_order_id": maker.binance_order_id,
                        "client_request_id": maker.client_request_id,
                    }})
                else:
                    self.fact(maker, X=state, z="0" if state == "NEW" else "0.5", ap="0" if state == "NEW" else "101")
                row = self.client.get(self.url).data["data"]["items"][0]
                self.assertEqual((row["status"], row["filled_size"], row["filled_amount"]), (1, "2", "202"))
                self.assertFalse(row["can_cancel"])

    def test_open_command_created_before_the_request_still_confirms_a_waiting_order(self):
        maker = self.maker()
        command = self.command(maker, action="open", result={"code": 200, "data": {
            "state": "PENDING_MAKER", "maker_order_id": maker.binance_order_id,
            "client_request_id": maker.client_request_id,
        }})
        TradingCommand.objects.filter(pk=command.pk).update(created_at=self.now - timedelta(seconds=10))
        row = self.client.get(self.url).data["data"]["items"][0]
        self.assertEqual(row["status"], 0)
        self.assertIsNone(row["filled_size"])
        self.assertFalse(row["can_cancel"])

    def test_terminal_fact_never_regresses_to_a_later_pending_receipt(self):
        maker = self.maker()
        self.fact(maker, X="FILLED", z="2", ap="101")
        self.command(maker, action="open", result={"code": 200, "data": {
            "state": "PENDING_MAKER", "maker_order_id": maker.binance_order_id,
            "client_request_id": maker.client_request_id,
        }})
        row = self.client.get(self.url).data["data"]["items"][0]
        self.assertEqual((row["status"], row["filled_size"]), (1, "2"))
        self.assertFalse(row["can_cancel"])

    def test_later_pending_receipt_cannot_reduce_confirmed_partial_quantity(self):
        maker = self.maker()
        self.fact(maker, X="PARTIALLY_FILLED", z="0.5", ap="101")
        self.command(maker, action="maker-status", result={"code": 200, "data": {
            "state": "PENDING_MAKER", "maker_order_id": maker.binance_order_id,
            "filled_size": "0", "symbol": maker.symbol,
        }})
        row = self.client.get(self.url).data["data"]["items"][0]
        self.assertEqual((row["status"], row["filled_size"], row["filled_amount"]), (0, "0.5", "50.5"))
        self.assertFalse(row["can_cancel"])

    def test_pending_receipt_with_full_quantity_does_not_invent_a_terminal_fill(self):
        maker = self.maker()
        self.command(maker, action="maker-status", result={"code": 200, "data": {
            "state": "PENDING_MAKER", "maker_order_id": maker.binance_order_id,
            "filled_size": "2", "symbol": maker.symbol,
        }})
        row = self.client.get(self.url).data["data"]["items"][0]
        self.assertEqual((row["status"], row["filled_size"]), (4, "2"))
        self.assertIsNone(row["filled_amount"])
        self.assertFalse(row["can_cancel"])

    def test_confirmed_rejection_is_not_a_live_or_uncertain_order(self):
        self.maker(status=TradeOpenRequest.STATUS_FAILED, binance_order_id="", error="GTX rejected")
        row = self.client.get(self.url).data["data"]["items"][0]
        self.assertEqual(row["status_text"], "已拒绝")
        self.assertIsNone(row["filled_size"])
        self.assertFalse(row["can_cancel"])

    def test_current_account_scope_excludes_other_users_modes_keys_and_generations(self):
        visible = self.limit()
        maker = self.maker()
        old_limit = self.limit()
        old_maker = self.maker()
        for record in [old_limit, old_maker]:
            type(record).objects.filter(pk=record.pk).update(created_at=self.binding.created_at - timedelta(seconds=1))
        self.limit(api_key_fingerprint="old-key")
        self.maker(api_key_fingerprint="old-key")
        self.limit(trading_mode="lead")
        self.maker(trading_mode="lead")
        other = User.objects.create_user("other-orders@example.invalid", "test-only-password")
        self.limit(user=other)
        self.maker(user=other)

        rows = self.client.get(self.url).data["data"]["items"]
        self.assertEqual({row["id"] for row in rows}, {f"limit:{visible.pk}", f"maker:{maker.pk}"})

    def test_stale_wrong_payload_and_other_binding_facts_are_not_order_evidence(self):
        for changes in [
            {"payload": {"s": "ETHUSDT", "i": "same-id", "c": "same-client", "X": "FILLED", "z": "2", "ap": "101"}},
            {"payload": {"s": "BTCUSDT", "i": "wrong-id", "c": "same-client", "X": "FILLED", "z": "2", "ap": "101"}},
            {"event_time": int((self.binding.created_at - timedelta(seconds=1)).timestamp() * 1000)},
            {"event_time": int((self.now - timedelta(seconds=1)).timestamp() * 1000)},
            {"binding_id_snapshot": self.binding.pk + 100},
            {"trading_mode": "lead"},
        ]:
            with self.subTest(changes=changes):
                AccountFact.objects.all().delete()
                TradeOpenRequest.objects.all().delete()
                maker = self.maker(binance_order_id="same-id", client_order_id="same-client")
                fact = self.fact(maker, X="FILLED", z="2", ap="101")
                AccountFact.objects.filter(pk=fact.pk).update(**changes)
                row = self.client.get(self.url).data["data"]["items"][0]
                self.assertEqual(row["status"], 4)
                self.assertIsNone(row["filled_size"])

    def test_stale_command_snapshots_never_prove_cancellation(self):
        maker = self.maker()
        for changes in [
            {"binding_id_snapshot": self.binding.pk + 100},
            {"binding_fingerprint": "old-key"},
            {"binding_created_at": self.binding.created_at - timedelta(seconds=1)},
            {"trading_mode": "lead"},
            {"payload": {"client_request_id": "other-request", "cancel_only": True}},
            {"action": "limit-create"},
            {"status": "UNKNOWN"},
        ]:
            with self.subTest(changes=changes):
                TradingCommand.objects.all().delete()
                self.command(maker, **changes)
                row = self.client.get(self.url).data["data"]["items"][0]
                self.assertEqual(row["status"], 4)
                self.assertIsNone(row["filled_size"])

    def test_lead_query_stays_read_only_when_new_risk_is_disabled(self):
        lead = ApiBinding.objects.create(user=self.user, trading_mode="lead", alias="lead", api_key="unused",
                                        secret_key="unused", api_key_fingerprint="b" * 64)
        maker = self.maker(trading_mode="lead", api_key_fingerprint=lead.api_key_fingerprint)
        fact = self.fact(maker)
        AccountFact.objects.filter(pk=fact.pk).update(binding_id_snapshot=lead.pk, trading_mode="lead")
        with self.settings(LEAD_TRADING_ENABLED=False):
            response = self.client.get(self.url, HTTP_X_TRADING_MODE="lead")
        self.assertEqual(response.status_code, 200)
        row = response.data["data"]["items"][0]
        self.assertEqual(row["status"], 0)
        self.assertFalse(row["can_cancel"])

    def test_get_only_selects_database_rows_and_never_reaches_exchange(self):
        def select_only(execute, sql, params, many, context):
            self.assertEqual(sql.lstrip().split()[0].upper(), "SELECT", sql)
            return execute(sql, params, many, context)

        for fingerprint in ["a" * 64, ""]:
            with self.subTest(fingerprint=fingerprint):
                LimitOrder.objects.all().delete()
                TradeOpenRequest.objects.all().delete()
                self.binding.api_key_fingerprint = fingerprint
                self.binding.save(update_fields=["api_key_fingerprint"])
                self.limit()
                self.fact(self.maker(), X="FILLED", z="2", ap="101")
                with connection.execute_wrapper(select_only), patch("socket.socket.connect", side_effect=AssertionError("network forbidden")):
                    response = self.client.get(self.url)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(len(response.data["data"]["items"]), 2)

    def test_unrelated_positions_never_supply_fills_or_position_ids(self):
        for changes in [
            {"trading_mode": "lead"}, {"api_key_fingerprint": "other-key"},
            {"symbol": "ETHUSDT"}, {"binance_order_id": "other-id"}, {"side": 1},
            {"created_at": self.binding.created_at - timedelta(seconds=1)},
            {"user": User.objects.create_user("position-other@example.invalid", "test-only-password")},
        ]:
            with self.subTest(changes=changes):
                TradeOpenRequest.objects.all().delete()
                maker = self.maker()
                position = self.position(maker)
                Order.objects.filter(pk=position.pk).update(**changes)
                TradeOpenRequest.objects.filter(pk=maker.pk).update(order_id=position.pk)
                row = self.client.get(self.url).data["data"]["items"][0]
                self.assertEqual(row["status"], 4)
                self.assertIsNone(row["position_id"])
                self.assertIsNone(row["filled_size"])

    def test_equal_creation_times_have_stable_order_across_mixed_pages(self):
        limit = self.limit()
        maker = self.maker()
        self.dated(limit, -1)
        self.dated(maker, -1)
        first = self.client.get(self.url, {"page_size": 1}).data["data"]
        second = self.client.get(self.url, {"page_size": 1, "page": 2}).data["data"]
        self.assertEqual([first["items"][0]["id"], second["items"][0]["id"]],
                         [f"limit:{limit.pk}", f"maker:{maker.pk}"])

    def test_terminal_limits_remain_visible_and_cannot_be_modified(self):
        for status in [LimitOrder.STATUS_FILLED, LimitOrder.STATUS_CANCELLED, LimitOrder.STATUS_EXPIRED]:
            self.limit(status=status)
        response = self.client.get(self.url)
        rows = response.data["data"]["items"]
        self.assertEqual({row["status"] for row in rows}, {1, 2, 3})
        self.assertTrue(all(not row["can_cancel"] and not row["can_chase"] for row in rows))

    def test_page_size_is_bounded_and_empty_pages_keep_total(self):
        self.limit()
        data = self.client.get(self.url, {"page_size": 1000, "page": 2}).data["data"]
        self.assertEqual(data["pagination"], {
            "page": 2, "page_size": 100, "total": 1, "has_next": False, "has_previous": True,
        })
        self.assertEqual(data["items"], [])

    def test_missing_binding_and_invalid_mode_fail_without_other_account_data(self):
        self.assertEqual(self.client.get(self.url, HTTP_X_TRADING_MODE="invalid").status_code, 400)
        ApiBinding.objects.all().delete()
        self.assertEqual(self.client.get(self.url).status_code, 400)
