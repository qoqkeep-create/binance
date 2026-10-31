from decimal import Decimal
from django.test import SimpleTestCase
from django.test import TestCase
from unittest.mock import Mock, patch
from common.binance import BinanceApiError, BinanceFuturesClient
from positions.models import Order
from users.models import User

from trading.external_positions import (
    amount_stop_price,
    finite_decimal,
    tighter_price,
    reconcile_external_order,
    close_external_position,
)


class ExternalRiskMathTests(SimpleTestCase):
    def test_amount_prices_round_toward_less_risk(self):
        self.assertEqual(
            amount_stop_price(
                0, Decimal("100"), Decimal("3"), Decimal("10"), Decimal(".1")
            ),
            Decimal("96.7"),
        )
        self.assertEqual(
            amount_stop_price(
                1, Decimal("100"), Decimal("3"), Decimal("10"), Decimal(".1")
            ),
            Decimal("103.3"),
        )

    def test_floor_only_tightens(self):
        self.assertEqual(tighter_price(0, Decimal("90"), Decimal("95")), Decimal("95"))
        self.assertEqual(
            tighter_price(1, Decimal("110"), Decimal("105")), Decimal("105")
        )

    def test_missing_or_nonfinite_values_are_not_zero(self):
        for value in (None, "", "NaN", "Infinity", "invalid"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                finite_decimal(value)


class ExternalProtectionTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            email="external@example.com", password="test-only", stop_loss_amount=100
        )
        self.order = Order.objects.create(
            user=self.user,
            position_origin=Order.ORIGIN_EXTERNAL,
            external_active_key="slot",
            binance_order_id=None,
            symbol="BTCUSDT",
            side=0,
            open_price=1000,
            size=1,
            exchange_size=1,
            stop_loss_price=0,
            stop_loss_amount=100,
            leverage=10,
        )
        self.position = dict(
            instId="BTC-USDT-SWAP",
            posSide="long",
            rawPositionSide="BOTH",
            pos="1",
            avgPx="1000",
            rawUpl="-99",
            upl="-99",
            ctVal="1",
            markPx="901",
        )
        self.client = Mock(spec=BinanceFuturesClient)
        self.client.get_positions.side_effect = lambda *a, **kw: {
            "data": [self.position]
        }
        self.client.get_ticker.return_value = {"data": [{"last": "901"}]}
        self.client.get_pending_algo_orders.return_value = {"data": []}
        self.algos = {}
        self.submits = []

        def submit(inst_id, **kw):
            self.order.refresh_from_db()
            self.assertEqual(
                self.order.external_stop_request["client_id"], kw["client_algo_id"]
            )
            row = self.stop(
                str(len(self.submits) + 1),
                kw["trigger_price"],
                kw["size"],
                workingType=kw.get("working_type", "CONTRACT_PRICE"),
            )
            row["clientAlgoId"] = kw["client_algo_id"]
            self.algos[kw["client_algo_id"]] = row
            self.submits.append(row)
            return {"data": [{"algoId": row["algoId"]}]}

        self.client.place_stop_market_order.side_effect = submit
        self.client.get_algo_order_by_client_id.side_effect = lambda inst, cid: {
            "data": [self.algos[cid]]
        }
        for target, kwargs in (
            (
                "trading.external_positions._get_instrument_trade_rules",
                {"return_value": {"tickSz": Decimal(".1")}},
            ),
            ("trading.external_positions.BinanceAlgoClient", {}),
        ):
            patcher = patch(target, **kwargs)
            mock = patcher.start()
            if target.endswith("BinanceAlgoClient"):
                self.cancel = mock.return_value.cancel_algo_confirmed
            self.addCleanup(patcher.stop)

    def stop(self, algo_id="old", price="900", size="1", **kwargs):
        row = dict(
            instId="BTC-USDT-SWAP",
            algoId=algo_id,
            clientAlgoId="",
            state="live",
            algoType="STOP_MARKET",
            slTriggerPx=price,
            sz=size,
            side="sell",
            rawPositionSide="BOTH",
            reduceOnly=True,
            closePosition=False,
            workingType="CONTRACT_PRICE",
            priceProtect=False,
        )
        row.update(kwargs)
        return row

    def cycle(self):
        self.order.refresh_from_db()
        reconcile_external_order(self.order, self.client, "net_mode", self.position)
        self.order.refresh_from_db()

    def cancelled_snapshot(self, **kw):
        return (
            {"data": [self.stop(kw["algo_id"], state="canceled")]}
            if kw.get("algo_id")
            else {"data": []}
        )

    def close_receipt(self, quantity="1", state="filled", **extra):
        self.order.refresh_from_db()
        row = dict(
            instId="BTC-USDT-SWAP",
            clientOrderId=self.order.external_close_request["client_id"],
            rawPositionSide="BOTH",
            reduceOnly=True,
            side="sell",
            state=state,
            fillSz=quantity,
            sz="1",
            avgPx="899",
            ordId="close-1",
        )
        row.update(extra)
        return {"data": [row]}

    def test_missing_stop_is_added_and_recreated_after_each_cancel(self):
        self.cycle()
        self.assertEqual(self.order.stop_protection_status, "complete")
        self.assertEqual(Decimal(self.submits[0]["slTriggerPx"]), Decimal("900"))
        first_id = self.order.external_stop_request["client_id"]
        self.client.get_pending_algo_orders.side_effect = self.cancelled_snapshot
        self.cycle()
        self.cycle()
        self.assertEqual(len(self.submits), 3)
        self.assertNotEqual(self.order.external_stop_request["client_id"], first_id)

    def test_stricter_full_stop_is_preserved_and_recreated_at_same_floor(self):
        self.client.get_ticker.return_value = {"data": [{"last": "990"}]}
        self.client.get_pending_algo_orders.return_value = {
            "data": [self.stop(price="950")]
        }
        self.cycle()
        self.assertEqual(self.order.current_stop_price, Decimal("950"))
        self.client.place_stop_market_order.assert_not_called()
        self.client.get_pending_algo_orders.return_value = {"data": []}
        self.client.get_pending_algo_orders.side_effect = self.cancelled_snapshot
        self.order.strategy_status = Order.STRATEGY_STATUS_CANCELLED
        self.order.save()
        self.cycle()
        self.assertEqual(self.submits[-1]["slTriggerPx"], "950.00000000")

    def test_looser_stop_replaced_only_after_new_stop_is_verified(self):
        self.client.get_pending_algo_orders.return_value = {
            "data": [self.stop(price="850")]
        }
        self.client.get_algo_order_by_client_id.side_effect = BinanceApiError(
            "timeout", outcome_unknown=True
        )
        self.cycle()
        self.cancel.assert_not_called()
        self.assertEqual(self.order.external_stop_request["status"], "pending")
        self.client.get_algo_order_by_client_id.side_effect = lambda inst, cid: {
            "data": [self.algos[cid]]
        }
        self.cycle()
        self.assertEqual(len(self.submits), 1)
        self.cancel.assert_called_once_with(
            "old", "BTC-USDT-SWAP", action="external_replace_stop"
        )

    def test_unknown_stop_submit_does_not_repeat(self):
        self.client.place_stop_market_order.side_effect = BinanceApiError(
            "timeout", outcome_unknown=True
        )
        self.client.get_algo_order_by_client_id.side_effect = BinanceApiError(
            "unknown order", code="-2013"
        )
        self.cycle()
        cid = self.order.external_stop_request["client_id"]
        self.cycle()
        self.assertEqual(self.client.place_stop_market_order.call_count, 1)
        self.assertEqual(self.order.external_stop_request["client_id"], cid)

    def test_stronger_partial_stop_and_take_profit_are_not_cancelled(self):
        self.client.get_pending_algo_orders.return_value = {
            "data": [
                self.stop(price="950", size=".4"),
                self.stop("tp", "1100", algoType="TAKE_PROFIT_MARKET"),
            ]
        }
        self.cycle()
        self.assertEqual(len(self.submits), 1)
        self.cancel.assert_not_called()

    def test_full_close_position_stop_does_not_require_quantity(self):
        self.client.get_pending_algo_orders.return_value = {
            "data": [self.stop(size="0", closePosition=True)]
        }
        self.cycle()
        self.client.place_stop_market_order.assert_not_called()
        self.assertEqual(self.order.stop_protection_status, "complete")

    def test_opposite_entry_stop_is_not_protection(self):
        self.client.get_pending_algo_orders.return_value = {
            "data": [self.stop(reduceOnly=False)]
        }
        self.cycle()
        self.assertEqual(len(self.submits), 1)
        self.cancel.assert_not_called()

    def test_locked_profit_is_not_mistaken_for_excess_risk(self):
        self.position["rawUpl"] = "150"
        self.client.get_ticker.return_value = {"data": [{"last": "1150"}]}
        self.client.get_pending_algo_orders.return_value = {
            "data": [self.stop(price="1100")]
        }
        self.cycle()
        self.client.close_position.assert_not_called()
        self.client.place_stop_market_order.assert_not_called()
        self.assertEqual(self.order.current_stop_price, Decimal("1100"))

    def test_short_hedge_position_gets_buy_stop_without_touching_long(self):
        self.order.side = 1
        self.order.save(update_fields=["side"])
        self.position.update(
            posSide="short",
            rawPositionSide="SHORT",
            pos="-1",
            rawUpl="-99",
            markPx="1099",
        )
        self.client.get_ticker.return_value = {"data": [{"last": "1099"}]}
        self.client.get_pending_algo_orders.return_value = {
            "data": [self.stop(price="900", rawPositionSide="LONG")]
        }

        def submit(inst_id, **kw):
            self.assertEqual(kw["side"], "buy")
            self.assertEqual(kw["pos_side"], "short")
            self.assertEqual(Decimal(kw["trigger_price"]), Decimal("1100"))
            row = self.stop(
                "short-new",
                kw["trigger_price"],
                side="buy",
                rawPositionSide="SHORT",
                clientAlgoId=kw["client_algo_id"],
            )
            self.algos[kw["client_algo_id"]] = row
            return {"data": [{"algoId": "short-new"}]}

        self.client.place_stop_market_order.side_effect = submit
        reconcile_external_order(
            self.order, self.client, "long_short_mode", self.position
        )
        self.order.refresh_from_db()
        self.assertEqual(self.order.stop_protection_status, "complete")
        self.cancel.assert_not_called()

    def test_quantity_change_recalculates_budget_without_relaxing_floor(self):
        self.client.get_ticker.return_value = {"data": [{"last": "990"}]}
        self.cycle()
        self.position["pos"] = "2"
        self.client.get_pending_algo_orders.return_value = {"data": [self.submits[0]]}
        self.cycle()
        self.assertEqual(self.order.current_stop_price, Decimal("950"))
        self.assertEqual(self.submits[-1]["sz"], "2")
        self.position["pos"] = ".5"
        self.client.get_pending_algo_orders.return_value = {"data": [self.submits[-1]]}
        self.cycle()
        self.assertEqual(self.order.current_stop_price, Decimal("950"))

    def test_limit_stop_gets_market_fallback_before_retirement(self):
        self.client.get_pending_algo_orders.return_value = {
            "data": [self.stop(algoType="STOP")]
        }
        self.cycle()
        self.assertEqual(len(self.submits), 1)
        self.assertEqual(self.order.stop_protection_status, "complete")
        self.cancel.assert_called_once_with(
            "old", "BTC-USDT-SWAP", action="external_replace_stop"
        )

    def test_unknown_write_before_post_stays_pending_without_replay(self):
        self.order.external_stop_request = {
            "client_id": "tt-crash-before-post",
            "status": "pending",
        }
        self.order.save(update_fields=["external_stop_request"])
        self.client.get_algo_order_by_client_id.side_effect = BinanceApiError(
            "not found", code="-2013"
        )
        for _ in range(3):
            self.cycle()
        self.client.place_stop_market_order.assert_not_called()
        self.assertEqual(self.order.stop_protection_status, "pending")
        self.assertEqual(
            self.order.external_stop_request["client_id"], "tt-crash-before-post"
        )

    def test_web_duplicate_check_does_not_close_external_lifecycle(self):
        from trading.views import _close_local_order_after_exchange_manual_close

        self.assertFalse(
            _close_local_order_after_exchange_manual_close(self.order, self.client)
        )
        self.client.get_positions.assert_not_called()
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)
        self.assertEqual(self.order.external_active_key, "slot")

    def test_float_loss_over_budget_closes_even_with_stop_and_broken_algo_query(self):
        self.position["rawUpl"] = "-101"
        self.client.get_pending_algo_orders.side_effect = RuntimeError(
            "algo unavailable"
        )
        self.client.close_position.side_effect = lambda *a, **kw: self.close_receipt()
        self.cycle()
        self.assertEqual(self.order.status, 1)
        self.assertIsNone(self.order.external_active_key)
        self.assertIsNone(self.order.pnl)
        self.client.get_pending_algo_orders.assert_not_called()
        self.assertEqual(
            self.client.close_position.call_args.kwargs["max_quantity"], Decimal("1")
        )

    def test_equality_does_not_trigger_excess_branch(self):
        self.position["rawUpl"] = "-100"
        self.cycle()
        self.client.close_position.assert_not_called()
        self.assertEqual(len(self.submits), 1)

    def test_touched_floor_closes_even_before_algo_read(self):
        self.order.current_stop_price = Decimal("900")
        self.order.save(update_fields=["current_stop_price"])
        self.client.get_ticker.return_value = {"data": [{"last": "900"}]}
        self.client.close_position.side_effect = lambda *a, **kw: self.close_receipt()
        self.cycle()
        self.assertEqual(self.order.status, 1)
        self.assertEqual(self.order.external_close_request["reason"], "stop_crossed")
        self.client.get_pending_algo_orders.assert_not_called()

    def test_missing_pnl_does_not_act_as_zero(self):
        self.position["rawUpl"] = None
        self.cycle()
        self.client.close_position.assert_not_called()
        self.client.place_stop_market_order.assert_not_called()
        self.assertEqual(self.order.stop_protection_status, "pending")

    def test_unknown_close_restores_same_request_without_resubmission(self):
        self.client.close_position.side_effect = BinanceApiError(
            "timeout", outcome_unknown=True
        )
        self.assertFalse(close_external_position(self.order, self.client, "net_mode"))
        cid = self.order.external_close_request["client_id"]
        self.client.get_order.side_effect = BinanceApiError("not found", code="-2013")
        self.assertFalse(close_external_position(self.order, self.client, "net_mode"))
        self.assertEqual(self.client.close_position.call_count, 1)
        self.assertEqual(self.order.external_close_request["client_id"], cid)
        self.assertEqual(self.order.status, 0)
        self.cancel.assert_not_called()
        self.client.get_order.side_effect = lambda *a, **kw: self.close_receipt()
        self.assertTrue(close_external_position(self.order, self.client, "net_mode"))
        self.assertEqual(self.client.close_position.call_count, 1)

    def test_database_failure_after_fill_recovers_without_a_second_close(self):
        from django.db import IntegrityError

        self.client.close_position.side_effect = lambda *a, **kw: self.close_receipt()
        with patch(
            "trading.external_positions.persist_confirmed_close_transition",
            side_effect=IntegrityError("unavailable"),
        ):
            self.assertFalse(
                close_external_position(self.order, self.client, "net_mode")
            )
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)
        self.assertEqual(self.order.external_close_request["status"], "pending")
        self.client.get_order.side_effect = lambda *a, **kw: self.close_receipt()
        self.assertTrue(close_external_position(self.order, self.client, "net_mode"))
        self.assertEqual(self.client.close_position.call_count, 1)

    def test_full_fill_recovery_does_not_close_reopened_position(self):
        self.client.close_position.side_effect = BinanceApiError(
            "timeout", outcome_unknown=True
        )
        close_external_position(self.order, self.client, "net_mode")
        self.position["pos"] = "2"
        self.client.get_order.side_effect = lambda *a, **kw: self.close_receipt()
        self.assertTrue(close_external_position(self.order, self.client, "net_mode"))
        self.assertEqual(self.client.close_position.call_count, 1)

    def test_terminal_partial_close_caps_next_attempt(self):
        self.client.close_position.side_effect = lambda *a, **kw: self.close_receipt(
            ".4", "canceled"
        )
        self.assertFalse(close_external_position(self.order, self.client, "net_mode"))
        self.position["pos"] = ".6"
        self.client.get_order.side_effect = lambda *a, **kw: self.close_receipt(
            ".4", "canceled"
        )
        self.assertFalse(close_external_position(self.order, self.client, "net_mode"))
        self.assertEqual(
            self.client.close_position.call_args.kwargs["max_quantity"], Decimal(".6")
        )

    def test_partial_receipt_does_not_retry_on_changed_lifecycle(self):
        self.client.close_position.side_effect = lambda *a, **kw: self.close_receipt(
            ".4", "canceled"
        )
        close_external_position(self.order, self.client, "net_mode")
        self.client.get_order.side_effect = lambda *a, **kw: self.close_receipt(
            ".4", "canceled"
        )
        self.position.update(pos="2", avgPx="1200")
        self.assertFalse(close_external_position(self.order, self.client, "net_mode"))
        self.assertEqual(self.client.close_position.call_count, 1)

    def test_rejected_close_does_not_replay_against_reopened_position(self):
        self.client.close_position.side_effect = BinanceApiError(
            "ReduceOnly rejected", code="-2022"
        )
        self.assertFalse(close_external_position(self.order, self.client, "net_mode"))
        self.position.update(pos="2", avgPx="1200")
        self.assertFalse(close_external_position(self.order, self.client, "net_mode"))
        self.assertEqual(self.client.close_position.call_count, 1)
        self.assertEqual(self.order.external_close_request["status"], "superseded")

    def test_mark_floor_keeps_reference_after_cancel_and_restart(self):
        self.position.update(rawUpl="50", markPx="1050")
        self.client.get_ticker.return_value = {"data": [{"last": "990"}]}
        self.client.get_pending_algo_orders.return_value = {
            "data": [self.stop(price="1000", workingType="MARK_PRICE")]
        }
        self.cycle()
        self.cycle()
        self.client.close_position.assert_not_called()
        self.client.get_pending_algo_orders.return_value = {"data": []}
        self.client.get_pending_algo_orders.side_effect = self.cancelled_snapshot
        self.cycle()
        self.client.close_position.assert_not_called()
        self.assertEqual(self.submits[-1]["workingType"], "MARK_PRICE")

    def test_first_adoption_uses_existing_mark_stop_reference(self):
        self.position.update(rawUpl="-80", markPx="920")
        self.client.get_ticker.return_value = {"data": [{"last": "890"}]}
        self.client.get_pending_algo_orders.return_value = {
            "data": [self.stop(price="910", workingType="MARK_PRICE")]
        }
        self.cycle()
        self.client.close_position.assert_not_called()
        self.assertEqual(self.order.current_stop_price, Decimal("910"))

    def test_temporary_open_list_omission_does_not_duplicate_live_stop(self):
        self.cycle()
        self.client.get_pending_algo_orders.side_effect = lambda **kw: {
            "data": [self.submits[0]] if kw.get("algo_id") else []
        }
        self.cycle()
        self.assertEqual(len(self.submits), 1)

    def test_reopened_position_does_not_adopt_previous_lifecycle_leftover(self):
        Order.objects.create(
            user=self.user,
            position_origin=Order.ORIGIN_EXTERNAL,
            status=1,
            symbol="BTCUSDT",
            side=0,
            open_price=1000,
            size=1,
            stop_loss_price=950,
            stop_loss_amount=100,
            leverage=10,
            external_stop_request={"status": "closed", "retired_ids": ["old"]},
        )
        self.client.get_pending_algo_orders.return_value = {
            "data": [self.stop(price="950")]
        }
        self.cycle()
        self.assertEqual(len(self.submits), 1)
        self.assertNotEqual(self.order.binance_stop_market_order_id, "old")
        self.assertEqual(self.order.current_stop_price, Decimal("900"))

    def test_unknown_stop_is_recovered_for_cleanup_after_close(self):
        self.client.place_stop_market_order.side_effect = BinanceApiError(
            "timeout", outcome_unknown=True
        )
        self.cycle()
        cid = self.order.external_stop_request["client_id"]
        self.algos[cid] = self.stop("recovered-stop", clientAlgoId=cid)
        self.client.close_position.side_effect = lambda *a, **kw: self.close_receipt()
        self.assertTrue(close_external_position(self.order, self.client, "net_mode"))
        self.cancel.assert_called_once_with(
            "recovered-stop", "BTC-USDT-SWAP", action="external_closed_cleanup"
        )

    def test_filled_without_actual_quantity_is_not_closed(self):
        self.client.close_position.side_effect = lambda *a, **kw: self.close_receipt(
            "0"
        )
        self.assertFalse(close_external_position(self.order, self.client, "net_mode"))
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)

    def test_empty_position_requires_two_successful_observations(self):
        self.client.get_positions.side_effect = [
            {"data": []},
            BinanceApiError("timeout"),
        ]
        self.assertFalse(close_external_position(self.order, self.client, "net_mode"))
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)
        self.client.get_positions.side_effect = [{"data": []}, {"data": []}]
        self.assertTrue(close_external_position(self.order, self.client, "net_mode"))
        self.client.close_position.assert_not_called()

    def test_receipt_identity_mismatch_is_not_closed(self):
        self.client.close_position.side_effect = lambda *a, **kw: self.close_receipt(
            rawPositionSide="SHORT"
        )
        self.assertFalse(close_external_position(self.order, self.client, "net_mode"))
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)
