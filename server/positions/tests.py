from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from django.core.cache import cache
from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase
from datetime import timedelta

from positions.models import LimitOrder, Order, OrderStrategyLog, OrderStrategySnapshot
from positions.cleanup import ClosedOrderCleanupResult, cleanup_closed_order_exchange_artifacts
from api_bindings.context import build_trading_account_identity
from api_bindings.models import ApiBinding
from trading.account_cache import position_cache_key
from trading.locks import user_trading_activity_lock
from positions.projection import project_position_financials, project_trigger_pnl
from positions.views import (
    _auto_close_missing_exchange_order,
    _auto_close_missing_exchange_order_safely,
    _fetch_order_exchange_financial_rows,
    _has_nearby_close_trade,
    _reconcile_order_settlement,
    _sync_entry_fee_for_order,
    _take_profit_client_id,
    reconcile_closed_order_exchange_artifacts,
    reconcile_pending_order_settlements,
    reconcile_stale_open_orders,
    audit_suspicious_closed_orders,
    sync_pending_entry_fees,
)
from positions.lifecycle import (
    fetch_order_trade_rows,
    select_order_lifecycle_close_trades,
    summarize_order_close_trades,
)
from users.models import User
from common.binance import BinanceApiError


class PositionProjectionTests(SimpleTestCase):
    def test_uses_exchange_pnl_and_margin_when_available(self):
        projection = project_position_financials(
            row={
                "avgPx": "100",
                "pos": "2",
                "ctVal": "0.5",
                "upl": "7.5",
                "margin": "20",
                "lever": "5",
            },
            side=0,
            fallback_open_price=Decimal("99"),
            current_price=Decimal("110"),
            stored_leverage=3,
        )

        self.assertEqual(projection.position_scale, Decimal("1.0"))
        self.assertEqual(projection.position_amount, Decimal("110.0"))
        self.assertEqual(projection.unrealized_pnl, Decimal("7.5"))
        self.assertEqual(projection.pnl_ratio, Decimal("37.500"))
        self.assertEqual(projection.leverage, 5)

    def test_estimates_short_pnl_and_margin_when_exchange_fields_are_absent(self):
        projection = project_position_financials(
            row={"avgPx": "100", "pos": "2", "ctVal": "1", "upl": "", "margin": ""},
            side=1,
            fallback_open_price=Decimal("99"),
            current_price=Decimal("90"),
            stored_leverage=10,
        )

        self.assertEqual(projection.unrealized_pnl, Decimal("20"))
        self.assertEqual(projection.margin, Decimal("18"))
        self.assertEqual(projection.pnl_ratio, Decimal("111.1111111111111111111111111"))
        self.assertEqual(
            project_trigger_pnl(
                side=1,
                average_price=Decimal("100"),
                trigger_price=Decimal("105"),
                position_scale=Decimal("2"),
            ),
            Decimal("-10"),
        )


class PositionApiTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="position_test@example.com", password="123456")
        login_resp = self.client.post(
            "/v1/auth/login",
            {"email": "position_test@example.com", "password": "123456", "agreed": True},
            format="json",
        )
        token = login_resp.data["data"]["token"]
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
        self.order = Order.objects.create(
            user=self.user,
            binance_order_id="binance-order-1",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )
        self.snapshot = OrderStrategySnapshot.objects.create(
            order=self.order,
            user=self.user,
            strategy_id="local-strategy-1",
            strategy_name="稳健通用",
            strategy_config=[
                {"profitRR": 1.5, "reducePosition": 50},
                {"profitRR": 2.0, "reducePosition": 50},
            ],
        )
        self.order.strategy_snapshot_id = self.snapshot.id
        self.order.strategy_status = Order.STRATEGY_STATUS_RUNNING
        self.order.save(update_fields=["strategy_snapshot_id", "strategy_status"])

    def _bind_for_maintenance(self, user=None):
        user = user or self.user
        binding = ApiBinding.objects.create(
            user=user, api_key="synthetic", secret_key="synthetic", passphrase="",
            api_key_fingerprint=f"maintenance-current-{user.id}", alias="test",
        )
        ApiBinding.objects.filter(pk=binding.pk).update(created_at=timezone.now() - timedelta(days=3))
        return binding

    def test_direct_position_mutations_reject_json_arrays(self):
        requests = (
            ("post", "/v1/position/close"),
            ("post", "/v1/position/break-even-stop"),
            ("post", "/v1/position/take-profit"),
            ("delete", "/v1/position/take-profit"),
            ("post", "/v1/strategy/cancel"),
            ("post", "/v1/strategy/rebind"),
        )
        for method, path in requests:
            with self.subTest(method=method, path=path):
                response = getattr(self.client, method)(path, [], format="json")
                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertEqual(response.data["message"], "请求参数必须是对象")

    def test_take_profit_client_id_changes_with_price_type_and_size(self):
        baseline = _take_profit_client_id(
            self.order,
            "mtp",
            "market",
            Decimal("120"),
            Decimal("1"),
        )

        self.assertEqual(
            baseline,
            _take_profit_client_id(
                self.order,
                "mtp",
                "market",
                Decimal("120.0"),
                Decimal("1.00"),
            ),
        )
        self.assertNotEqual(
            baseline,
            _take_profit_client_id(self.order, "mtp", "market", Decimal("121"), Decimal("1")),
        )
        self.assertNotEqual(
            baseline,
            _take_profit_client_id(self.order, "mtp", "limit", Decimal("120"), Decimal("1")),
        )
        self.assertNotEqual(
            baseline,
            _take_profit_client_id(self.order, "mtp", "market", Decimal("120"), Decimal("0.5")),
        )

    @patch("common.binance.time.sleep")
    @patch("positions.cleanup.time.sleep")
    def test_closed_order_cleanup_preserves_local_ids_when_exchange_state_is_unknown(
        self,
        _cleanup_sleep,
        _binance_sleep,
    ):
        self.order.binance_stop_order_id = "stop-keep"
        self.order.binance_stop_market_order_id = "stop-market-keep"
        self.order.strategy_tp_algo_ids = ["tp-keep"]
        self.order.manual_take_profit_algo_id = "manual-tp-keep"
        self.order.save(update_fields=[
            "binance_stop_order_id",
            "binance_stop_market_order_id",
            "strategy_tp_algo_ids",
            "manual_take_profit_algo_id",
        ])
        limit_order = LimitOrder.objects.create(
            user=self.user,
            order=self.order,
            binance_order_id="limit-keep",
            symbol="BTCUSDT",
            side=0,
            limit_price=Decimal("99"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=LimitOrder.STATUS_PENDING,
        )
        client = MagicMock()
        client.get_pending_algo_orders.side_effect = BinanceApiError("查询失败", code="-2015")
        client.cancel_algos.side_effect = BinanceApiError("权限不足", code="-2015")
        client.get_pending_orders.side_effect = BinanceApiError("查询失败", code="-2015")
        client.get_order.side_effect = BinanceApiError("查询失败", code="-2015")

        result = cleanup_closed_order_exchange_artifacts(self.order, client)

        self.assertEqual(result.stop_order_id, "stop-keep")
        self.assertEqual(result.stop_market_order_id, "stop-market-keep")
        self.assertEqual(result.take_profit_algo_ids, ["tp-keep"])
        self.assertEqual(result.manual_take_profit_algo_id, "manual-tp-keep")
        self.assertTrue(result.had_exchange_errors)
        limit_order.refresh_from_db()
        self.assertEqual(limit_order.status, LimitOrder.STATUS_PENDING)

    def test_closed_order_cleanup_clears_only_exchange_confirmed_algo_ids(self):
        self.order.binance_stop_order_id = "stop-clear"
        self.order.strategy_tp_algo_ids = ["tp-clear"]
        self.order.manual_take_profit_algo_id = "manual-clear"
        self.order.save(update_fields=[
            "binance_stop_order_id",
            "strategy_tp_algo_ids",
            "manual_take_profit_algo_id",
        ])
        client = MagicMock()
        client.get_pending_algo_orders.side_effect = [
            {
                "data": [
                    {"algoId": "stop-clear", "algoType": "STOP"},
                    {"algoId": "tp-clear", "algoType": "TAKE_PROFIT_MARKET"},
                    {"algoId": "manual-clear", "algoType": "TAKE_PROFIT_MARKET"},
                ],
            },
            {"data": []},
        ]
        client.cancel_algos.side_effect = lambda *, algo_id, inst_id: {
            "data": [{"algoId": algo_id, "state": "canceled"}],
        }
        client.get_pending_orders.return_value = {"data": []}

        result = cleanup_closed_order_exchange_artifacts(self.order, client)

        self.assertEqual(result.stop_order_id, "")
        self.assertEqual(result.take_profit_algo_ids, [])
        self.assertEqual(result.manual_take_profit_algo_id, "")
        self.assertFalse(result.has_residual_exchange_orders)

    @patch("positions.views.summarize_order_close_trades")
    @patch("positions.views.fetch_order_trade_rows")
    def test_settlement_bill_filter_excludes_adjacent_order_lifecycle(self, mock_fetch_trades, mock_summary):
        entry_time = int(self.order.created_at.timestamp() * 1000)
        close_time = entry_time + 2 * 60 * 60 * 1000
        unrelated_time = entry_time + 60 * 60 * 1000
        entry_trade = {"ordId": self.order.binance_order_id, "time": str(entry_time)}
        close_trade = {"ordId": "close-1", "time": str(close_time), "fillSz": "1"}
        mock_fetch_trades.return_value = [entry_trade, close_trade]
        mock_summary.return_value = {
            "opening_rows": [entry_trade],
            "rows": [close_trade],
            "is_fully_closed": True,
        }
        client = MagicMock()
        client.get_bills.return_value = {
            "code": "0",
            "data": [
                {"instId": "BTC-USDT-SWAP", "type": "COMMISSION", "pnl": "-0.1", "uTime": str(entry_time)},
                {"instId": "BTC-USDT-SWAP", "type": "COMMISSION", "pnl": "-0.2", "uTime": str(close_time)},
                {"instId": "BTC-USDT-SWAP", "type": "REALIZED_PNL", "pnl": "10", "uTime": str(close_time)},
                {"instId": "BTC-USDT-SWAP", "type": "COMMISSION", "pnl": "-9", "uTime": str(unrelated_time)},
                {"instId": "BTC-USDT-SWAP", "type": "REALIZED_PNL", "pnl": "99", "uTime": str(unrelated_time)},
            ],
        }
        self.order.closed_at = self.order.created_at + timedelta(hours=2)
        rows = _fetch_order_exchange_financial_rows(self.order, client)
        self.assertEqual([row["pnl"] for row in rows["bill_rows"]], ["-0.1", "-0.2", "10"])

    def test_exchange_history_queries_never_use_future_end_time(self):
        fixed_now = timezone.now()
        self.order.closed_at = fixed_now
        client = MagicMock()
        client.get_user_trades.return_value = {"data": []}
        client.get_bills.return_value = {"data": []}

        with patch("positions.lifecycle.timezone.now", return_value=fixed_now):
            fetch_order_trade_rows(self.order, client)
        self.assertEqual(
            client.get_user_trades.call_args.kwargs["end_time"],
            str(int(fixed_now.timestamp() * 1000)),
        )

        client.reset_mock()
        with (
            patch("positions.views.timezone.now", return_value=fixed_now),
            patch("positions.views.fetch_order_trade_rows", return_value=[]),
        ):
            _fetch_order_exchange_financial_rows(self.order, client)
        self.assertEqual(
            client.get_bills.call_args.kwargs["end"],
            str(int(fixed_now.timestamp() * 1000)),
        )

        client.reset_mock()
        with patch("positions.views.timezone.now", return_value=fixed_now):
            _has_nearby_close_trade(self.order, client)
        self.assertEqual(
            client.get_user_trades.call_args.kwargs["end_time"],
            str(int(fixed_now.timestamp() * 1000)),
        )

        client.reset_mock()
        client.get_user_trades.return_value = {"data": []}
        with patch("positions.views.timezone.now", return_value=fixed_now):
            _sync_entry_fee_for_order(self.order, client)
        self.assertEqual(
            client.get_user_trades.call_args.kwargs["end_time"],
            str(int(fixed_now.timestamp() * 1000)),
        )

    def test_close_lifecycle_excludes_opposite_hedge_position_trades(self):
        entry_time = int(self.order.created_at.timestamp() * 1000)
        rows = [
            {
                "ordId": self.order.binance_order_id,
                "side": "buy",
                "rawPositionSide": "LONG",
                "fillSz": "1",
                "time": str(entry_time - 10),
            },
            {
                "ordId": "short-entry",
                "side": "sell",
                "rawPositionSide": "SHORT",
                "fillSz": "1",
                "time": str(entry_time + 1_000),
            },
            {
                "ordId": "long-close",
                "side": "sell",
                "rawPositionSide": "LONG",
                "fillSz": "1",
                "time": str(entry_time + 2_000),
            },
        ]

        selected = select_order_lifecycle_close_trades(self.order, rows)
        summary = summarize_order_close_trades(self.order, rows)

        self.assertEqual([row["ordId"] for row in selected], ["long-close"])
        self.assertTrue(summary["is_fully_closed"])
        self.assertEqual(summary["latest_close_row"]["ordId"], "long-close")

    def test_close_lifecycle_accounts_for_position_additions(self):
        entry_time = int(self.order.created_at.timestamp() * 1000)
        rows = [
            {
                "ordId": self.order.binance_order_id,
                "side": "buy",
                "rawPositionSide": "LONG",
                "fillSz": "1",
                "time": str(entry_time - 10),
            },
            {
                "ordId": "manual-addition",
                "side": "buy",
                "rawPositionSide": "LONG",
                "fillSz": "1",
                "time": str(entry_time + 1_000),
            },
            {
                "ordId": "partial-close",
                "side": "sell",
                "rawPositionSide": "LONG",
                "fillSz": "1.5",
                "time": str(entry_time + 2_000),
            },
        ]

        summary = summarize_order_close_trades(self.order, rows)

        self.assertEqual(summary["close_qty"], Decimal("1.5"))
        self.assertFalse(summary["is_fully_closed"])

    def test_close_lifecycle_uses_known_exchange_size_when_entry_trade_is_missing(self):
        self.order.exchange_size = Decimal("1.5")
        entry_time = int(self.order.created_at.timestamp() * 1000)
        rows = [
            {
                "ordId": "partial-close",
                "side": "sell",
                "rawPositionSide": "LONG",
                "fillSz": "1",
                "time": str(entry_time + 1_000),
            },
        ]

        summary = summarize_order_close_trades(self.order, rows)

        self.assertEqual(summary["close_qty"], Decimal("1"))
        self.assertFalse(summary["is_fully_closed"])

    def test_settlement_waits_until_close_trades_cover_the_lifecycle(self):
        self.order.status = 1
        self.order.closed_at = timezone.now()
        self.order.close_binance_order_id = "partial-close"
        self.order.save(update_fields=["status", "closed_at", "close_binance_order_id"])

        reconciled = _reconcile_order_settlement(
            order=self.order,
            client=MagicMock(),
            close_price=Decimal("105"),
            exchange_rows={
                "trade_rows": [
                    {
                        "ordId": "partial-close",
                        "side": "sell",
                        "fillSz": "0.5",
                        "fillPx": "105",
                        "realizedPnl": "2.5",
                        "fee": "0.1",
                    },
                ],
                "entry_trade_rows": [],
                "opening_trade_rows": [],
                "bill_rows": [],
                "is_fully_closed": False,
            },
        )

        self.assertFalse(reconciled)
        self.order.refresh_from_db()
        self.assertEqual(self.order.settlement_status, Order.SETTLEMENT_STATUS_FAILED)
        self.assertIn("未完整覆盖", self.order.settlement_error)
        self.assertIsNone(self.order.settled_at)

    def test_settlement_includes_manual_addition_trade_fee(self):
        self.order.status = 1
        self.order.closed_at = timezone.now()
        self.order.close_binance_order_id = "full-close"
        self.order.save(update_fields=["status", "closed_at", "close_binance_order_id"])
        entry_trade = {
            "ordId": self.order.binance_order_id,
            "side": "buy",
            "fillSz": "1",
            "fillPx": "100",
            "fee": "0.1",
        }
        manual_addition = {
            "ordId": "manual-addition",
            "side": "buy",
            "fillSz": "0.5",
            "fillPx": "102",
            "fee": "0.2",
        }
        close_trade = {
            "ordId": "full-close",
            "side": "sell",
            "fillSz": "1.5",
            "fillPx": "110",
            "realizedPnl": "10",
            "fee": "0.3",
        }

        reconciled = _reconcile_order_settlement(
            order=self.order,
            client=MagicMock(),
            close_price=Decimal("110"),
            exchange_rows={
                "trade_rows": [close_trade],
                "entry_trade_rows": [entry_trade],
                "opening_trade_rows": [entry_trade, manual_addition],
                "bill_rows": [],
                "is_fully_closed": True,
            },
        )

        self.assertTrue(reconciled)
        self.order.refresh_from_db()
        self.assertEqual(self.order.realized_fee, Decimal("-0.6"))
        self.assertEqual(self.order.pnl, Decimal("9.4"))
        self.assertEqual(self.order.settlement_status, Order.SETTLEMENT_STATUS_SETTLED)

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_list(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [
                {
                    "instId": "BTC-USDT-SWAP",
                    "markPx": "110",
                    "avgPx": "100",
                    "upl": "10",
                    "uplRatio": "0.1",
                    "pos": "1",
                    "ctVal": "1",
                    "lever": "25",
                }
            ],
        }
        mock_client_cls.return_value = mock_client

        resp = self.client.get("/v1/position/list")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(len(resp.data["data"]), 1)
        self.assertEqual(resp.data["data"][0]["strategy_status"], Order.STRATEGY_STATUS_RUNNING)
        self.assertEqual(resp.data["data"][0]["strategy_name"], "稳健通用")
        self.assertFalse(resp.data["data"][0]["can_bind_strategy"])
        self.assertEqual(resp.data["data"][0]["exchange_size"], "1")
        self.assertFalse(resp.data["data"][0]["has_manual_addition"])
        self.assertEqual(resp.data["data"][0]["leverage"], "25")
        self.assertFalse(resp.data["data"][0]["limit_stop_set"])
        self.assertFalse(resp.data["data"][0]["market_stop_set"])
        self.assertIsNone(resp.data["data"][0]["entry_realized_fee"])
        self.assertEqual(resp.data["data"][0]["entry_fee_status"], Order.ENTRY_FEE_STATUS_PENDING)

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_list_includes_manual_take_profit_info(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        self.order.manual_take_profit_algo_id = "mtp-1"
        self.order.manual_take_profit_price = Decimal("120")
        self.order.manual_take_profit_order_type = "limit"
        self.order.save(update_fields=[
            "manual_take_profit_algo_id",
            "manual_take_profit_price",
            "manual_take_profit_order_type",
        ])
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{
                "instId": "BTC-USDT-SWAP",
                "posSide": "long",
                "markPx": "110",
                "avgPx": "100",
                "upl": "10",
                "uplRatio": "0.1",
                "pos": "1",
                "ctVal": "1",
                "lever": "25",
            }],
        }
        mock_client_cls.return_value = mock_client

        resp = self.client.get("/v1/position/list")

        row = resp.data["data"][0]
        self.assertTrue(row["manual_take_profit_set"])
        self.assertEqual(row["manual_take_profit_price"], "120.00000000")
        self.assertEqual(row["manual_take_profit_order_type"], "limit")
        self.assertEqual(row["manual_take_profit_pnl"], "20.00000000")

    @patch("positions.views._move_stop_loss")
    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_break_even_stop_with_fee_moves_stop_to_fee_covered_price(self, mock_client_cls, mock_creds, mock_move_stop):
        mock_creds.return_value = object()
        self.order.estimated_total_fee = Decimal("2")
        self.order.save(update_fields=["estimated_total_fee"])
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{
                "instId": "BTC-USDT-SWAP",
                "posSide": "long",
                "markPx": "110",
                "avgPx": "100",
                "upl": "10",
                "pos": "1",
                "ctVal": "1",
            }],
        }
        mock_client_cls.return_value = mock_client
        mock_move_stop.return_value = True

        resp = self.client.post(
            "/v1/position/break-even-stop",
            {"position_id": self.order.id, "mode": "with_fee"},
            format="json",
        )

        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["code"], 200)
        self.assertEqual(mock_move_stop.call_args.args[2], Decimal("102"))
        self.assertEqual(mock_move_stop.call_args.args[3], Decimal("110"))

    @patch("positions.views._move_stop_loss")
    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_break_even_stop_with_fee_rejects_when_profit_cannot_cover_fee(self, mock_client_cls, mock_creds, mock_move_stop):
        mock_creds.return_value = object()
        self.order.estimated_total_fee = Decimal("2")
        self.order.save(update_fields=["estimated_total_fee"])
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{
                "instId": "BTC-USDT-SWAP",
                "posSide": "long",
                "markPx": "101",
                "avgPx": "100",
                "upl": "1",
                "pos": "1",
                "ctVal": "1",
            }],
        }
        mock_client_cls.return_value = mock_client

        resp = self.client.post(
            "/v1/position/break-even-stop",
            {"position_id": self.order.id, "mode": "with_fee"},
            format="json",
        )

        self.assertEqual(resp.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(resp.data["code"], 400)
        self.assertIn("浮盈不足", resp.data["message"])
        mock_move_stop.assert_not_called()

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_list_syncs_external_take_profit_algo(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{
                "instId": "BTC-USDT-SWAP",
                "posSide": "long",
                "markPx": "110",
                "avgPx": "100",
                "upl": "10",
                "uplRatio": "0.1",
                "pos": "1",
                "ctVal": "1",
                "lever": "25",
            }],
        }
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_pending_algo_orders.return_value = {
            "code": "0",
            "data": [{
                "algoId": "external-tp-1",
                "clientAlgoId": "aos_external",
                "instId": "BTC-USDT-SWAP",
                "sz": "1",
                "slTriggerPx": "0",
                "tpTriggerPx": "120",
                "side": "sell",
                "posSide": "long",
                "state": "live",
                "algoType": "TAKE_PROFIT",
            }],
        }
        mock_client_cls.return_value = mock_client

        resp = self.client.get("/v1/position/list")

        row = resp.data["data"][0]
        self.assertTrue(row["manual_take_profit_set"])
        self.assertEqual(row["manual_take_profit_algo_id"], "external-tp-1")
        self.assertEqual(row["manual_take_profit_price"], "120")
        self.assertEqual(row["manual_take_profit_order_type"], "limit")
        self.order.refresh_from_db()
        self.assertEqual(self.order.manual_take_profit_algo_id, "external-tp-1")
        self.assertEqual(self.order.manual_take_profit_price, Decimal("120"))
        self.assertEqual(self.order.manual_take_profit_order_type, "limit")

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_sync_pending_entry_fees_confirms_fee_by_entry_order_id(self, mock_client_cls, mock_creds):
        self._bind_for_maintenance()
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": self.order.binance_order_id,
                    "instId": "BTC-USDT-SWAP",
                    "fillSz": "0.4",
                    "fee": "0.12",
                    "feeCcy": "USDT",
                    "time": str(int(self.order.created_at.timestamp() * 1000)),
                },
                {
                    "ordId": self.order.binance_order_id,
                    "instId": "BTC-USDT-SWAP",
                    "fillSz": "0.6",
                    "fee": "0.18",
                    "feeCcy": "USDT",
                    "time": str(int(self.order.created_at.timestamp() * 1000) + 1000),
                },
                {
                    "ordId": "another-order",
                    "instId": "BTC-USDT-SWAP",
                    "fillSz": "1.5",
                    "fee": "9",
                    "feeCcy": "USDT",
                    "time": str(int(self.order.created_at.timestamp() * 1000) + 2000),
                },
            ],
        }
        mock_client_cls.return_value = mock_client

        synced = sync_pending_entry_fees()

        self.assertEqual(synced, 1)
        self.order.refresh_from_db()
        self.assertEqual(self.order.entry_realized_fee, Decimal("-0.30"))
        self.assertEqual(self.order.entry_fee_asset, "USDT")
        self.assertEqual(self.order.entry_fee_status, Order.ENTRY_FEE_STATUS_CONFIRMED)
        self.assertEqual(self.order.entry_fee_error, "")

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_sync_pending_entry_fees_stops_batch_on_rate_limit(self, mock_client_cls, mock_creds):
        self._bind_for_maintenance()
        mock_creds.return_value = object()
        Order.objects.create(
            user=self.user,
            binance_order_id="binance-order-2",
            symbol="ETHUSDT",
            side=0,
            open_price=Decimal("200"),
            stop_loss_price=Decimal("190"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )
        mock_client = MagicMock()
        mock_client.get_user_trades.side_effect = BinanceApiError("请求过于频繁", code="-1003")
        mock_client_cls.return_value = mock_client

        synced = sync_pending_entry_fees(limit=5)

        self.assertEqual(synced, 0)
        self.assertEqual(mock_client.get_user_trades.call_count, 1)

    @patch("positions.views.get_user_binding_generation")
    @patch("positions.views._credentials_for_binding_generation")
    def test_background_reconcilers_never_use_current_key_for_stale_key_order(
        self,
        mock_credentials,
        mock_generation,
    ):
        self._bind_for_maintenance()
        mock_generation.return_value = ("current-fingerprint", timezone.now() - timedelta(days=1))
        self.order.api_key_fingerprint = "stale-fingerprint"
        self.order.save(update_fields=["api_key_fingerprint"])

        self.assertEqual(sync_pending_entry_fees(limit=10), 0)
        self.assertEqual(reconcile_stale_open_orders(limit=10), 0)

        self.order.status = 1
        self.order.closed_at = timezone.now() - timedelta(minutes=10)
        self.order.close_binance_order_id = ""
        self.order.settlement_status = Order.SETTLEMENT_STATUS_PENDING
        self.order.binance_stop_order_id = "stale-stop"
        self.order.save(
            update_fields=[
                "status",
                "closed_at",
                "close_binance_order_id",
                "settlement_status",
                "binance_stop_order_id",
            ]
        )

        self.assertEqual(reconcile_pending_order_settlements(limit=10), 0)
        self.assertEqual(audit_suspicious_closed_orders(limit=10), 0)
        self.assertEqual(reconcile_closed_order_exchange_artifacts(limit=10), 0)
        mock_credentials.assert_not_called()

    @patch("positions.views.binance_get_cached_last_prices")
    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_list_prefers_exchange_upl_over_locally_calculated_pnl(self, mock_client_cls, mock_creds, mock_prices):
        mock_creds.return_value = object()
        mock_prices.return_value = {"BTC-USDT-SWAP": "172"}
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [
                {
                    "instId": "BTC-USDT-SWAP",
                    "markPx": "153",
                    "avgPx": "100",
                    "upl": "53",
                    "uplRatio": "0.1",
                    "pos": "1",
                    "ctVal": "1",
                    "lever": "10",
                }
            ],
        }
        mock_client_cls.return_value = mock_client

        resp = self.client.get("/v1/position/list")

        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        row = resp.data["data"][0]
        self.assertEqual(row["pnl"], "53")
        self.assertEqual(row["current_price"], "172")

    @patch("positions.views.binance_get_cached_last_prices")
    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_list_uses_exchange_size_and_marks_manual_addition(self, mock_client_cls, mock_creds, mock_prices):
        mock_creds.return_value = object()
        mock_prices.return_value = {"BTC-USDT-SWAP": "110"}
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [
                {
                    "instId": "BTC-USDT-SWAP",
                    "markPx": "110",
                    "avgPx": "100",
                    "pos": "1.5",
                    "ctVal": "1",
                    "lever": "1",
                }
            ],
        }
        mock_client_cls.return_value = mock_client

        resp = self.client.get("/v1/position/list")

        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        row = resp.data["data"][0]
        self.assertEqual(row["exchange_size"], "1.5")
        self.assertTrue(row["has_manual_addition"])
        self.assertEqual(row["position_amount"], "165.0")
        self.assertEqual(row["pnl"], "15.0")
        self.assertEqual(Decimal(row["pnl_ratio"]).quantize(Decimal("0.0001")), Decimal("90.9091"))
        self.assertEqual(row["leverage"], "10")
        self.order.refresh_from_db()
        self.assertEqual(self.order.size, Decimal("1"))
        self.assertIsNone(self.order.exchange_size)
        self.assertFalse(self.order.has_manual_addition)

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_list_marks_closed_and_cleans_algo_orders_when_exchange_position_missing(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": "close-by-stop-1",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "fillSz": "1",
                    "fillPx": "95",
                    "time": str(int(timezone.now().timestamp() * 1000)),
                }
            ],
        }
        mock_client_cls.return_value = mock_client

        # Ensure order age passes auto-close minimum age gate.
        Order.objects.filter(id=self.order.id).update(created_at=timezone.now() - timedelta(minutes=5))
        self.order.refresh_from_db()
        self.order.binance_stop_order_id = "stop-algo-1"
        self.order.strategy_tp_algo_ids = ["tp-algo-1", "tp-algo-2"]
        self.order.save(update_fields=["binance_stop_order_id", "strategy_tp_algo_ids"])

        # First miss only marks candidate, should not close yet.
        first = self.client.get("/v1/position/list")
        self.assertEqual(first.status_code, status.HTTP_200_OK)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)

        candidate_key = f"position:auto-close:candidate:{self.user.id}:{self.order.id}"
        # Simulate confirmation gap elapsed.
        cache.set(candidate_key, int((timezone.now() - timedelta(seconds=10)).timestamp()), timeout=120)

        resp = self.client.get("/v1/position/list")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"], [])

        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 1)
        self.assertEqual(self.order.strategy_tp_algo_ids, [])
        mock_client.cancel_algos.assert_any_call(algo_id="stop-algo-1", inst_id="BTC-USDT-SWAP")
        mock_client.cancel_algos.assert_any_call(algo_id="tp-algo-1", inst_id="BTC-USDT-SWAP")
        mock_client.cancel_algos.assert_any_call(algo_id="tp-algo-2", inst_id="BTC-USDT-SWAP")

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_list_keeps_open_when_exchange_position_missing_but_no_trade_evidence(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.get_user_trades.return_value = {"code": "0", "data": []}
        mock_client_cls.return_value = mock_client

        Order.objects.filter(id=self.order.id).update(created_at=timezone.now() - timedelta(minutes=5))
        self.order.refresh_from_db()
        candidate_key = f"position:auto-close:candidate:{self.user.id}:{self.order.id}"
        cache.set(candidate_key, int((timezone.now() - timedelta(seconds=10)).timestamp()), timeout=120)

        resp = self.client.get("/v1/position/list")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"], [])
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)
        mock_client.cancel_algos.assert_not_called()

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_list_does_not_auto_close_when_only_stale_cached_rows_exist(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        cache.set(position_cache_key("exchange_rows", self.user.id), [], timeout=60)

        mock_client = MagicMock()
        mock_client.get_positions.side_effect = BinanceApiError("temporary timeout")
        mock_client_cls.return_value = mock_client

        resp = self.client.get("/v1/position/list")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"], [])

        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)
        mock_client.cancel_algos.assert_not_called()

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_reconcile_stale_open_orders_closes_missing_exchange_position(self, mock_client_cls, mock_creds):
        self._bind_for_maintenance()
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": "close-by-scheduler-1",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "fillSz": "1.5",
                    "fillPx": "96",
                    "time": str(int(timezone.now().timestamp() * 1000)),
                }
            ],
        }
        mock_client_cls.return_value = mock_client

        Order.objects.filter(id=self.order.id).update(created_at=timezone.now() - timedelta(minutes=5))
        self.order.refresh_from_db()
        self.order.binance_stop_order_id = "stop-algo-1"
        self.order.strategy_tp_algo_ids = ["tp-algo-1"]
        self.order.exchange_size = Decimal("1.5")
        self.order.has_manual_addition = True
        self.order.save(
            update_fields=[
                "binance_stop_order_id",
                "strategy_tp_algo_ids",
                "exchange_size",
                "has_manual_addition",
            ]
        )

        first = reconcile_stale_open_orders()
        self.assertEqual(first, 0)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)

        candidate_key = f"position:auto-close:candidate:{self.user.id}:{self.order.id}"
        cache.set(candidate_key, int((timezone.now() - timedelta(seconds=10)).timestamp()), timeout=120)

        repaired = reconcile_stale_open_orders()
        self.assertEqual(repaired, 1)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 1)
        self.assertEqual(self.order.close_binance_order_id, "close-by-scheduler-1")
        self.assertEqual(self.order.strategy_tp_algo_ids, [])
        self.assertEqual(self.order.exchange_size, Decimal("0"))
        self.assertFalse(self.order.has_manual_addition)
        self.assertEqual(mock_client.get_positions.call_count, 1)
        mock_client.cancel_algos.assert_any_call(algo_id="stop-algo-1", inst_id="BTC-USDT-SWAP")
        mock_client.cancel_algos.assert_any_call(algo_id="tp-algo-1", inst_id="BTC-USDT-SWAP")

    @patch("positions.views._confirm_auto_close_candidate", return_value=(True, "confirmed"))
    @patch("positions.views._snapshot_auto_close_anchor")
    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_reconcile_stale_open_orders_stops_after_internal_shared_rate_limit(
        self,
        mock_client_cls,
        mock_creds,
        mock_anchor,
        _mock_candidate,
    ):
        self._bind_for_maintenance()
        mock_creds.return_value = object()
        Order.objects.create(
            user=self.user,
            binance_order_id="binance-order-2",
            symbol="ETHUSDT",
            side=0,
            open_price=Decimal("200"),
            stop_loss_price=Decimal("190"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {"data": []}
        mock_client.get_account_config.return_value = {
            "data": [{"posMode": "long_short_mode"}],
        }
        mock_client_cls.return_value = mock_client
        mock_anchor.side_effect = BinanceApiError(
            "Binance 请求预算保护中",
            code="LOCAL_RATE_BUDGET",
        )

        with patch("positions.views.logger.exception") as exception_log:
            self.assertEqual(reconcile_stale_open_orders(), 0)
        self.assertEqual(mock_anchor.call_count, 1)
        exception_log.assert_not_called()

    @patch("positions.views._auto_close_missing_exchange_order")
    @patch("positions.views._credentials_for_binding_generation", return_value=object())
    @patch("positions.views.BinanceFuturesClient")
    def test_reconcile_stale_open_orders_isolates_an_account_error(
        self,
        mock_client_cls,
        _mock_creds,
        mock_auto_close,
    ):
        self._bind_for_maintenance()
        other_user = User.objects.create_user(email="position_other@example.com", password="123456")
        self._bind_for_maintenance(other_user)
        Order.objects.create(
            user=other_user,
            binance_order_id="other-binance-order",
            symbol="ETHUSDT",
            side=0,
            open_price=Decimal("200"),
            stop_loss_price=Decimal("190"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )
        first_client = MagicMock()
        second_client = MagicMock()
        for client in (first_client, second_client):
            client.get_positions.return_value = {"data": []}
            client.get_account_config.return_value = {
                "data": [{"posMode": "long_short_mode"}],
            }
        mock_client_cls.side_effect = [first_client, second_client]
        mock_auto_close.side_effect = [RuntimeError("first account unavailable"), True]

        self.assertEqual(reconcile_stale_open_orders(), 1)
        self.assertEqual(mock_auto_close.call_count, 2)

    def test_fresh_missing_position_confirmation_propagates_shared_rate_limit(self):
        client = MagicMock()
        client.get_positions.side_effect = BinanceApiError(
            "请求过于频繁",
            code="-1003",
        )

        with self.assertRaises(BinanceApiError):
            _auto_close_missing_exchange_order_safely(
                self.order,
                client,
                account_identity=build_trading_account_identity(user_id=self.user.id),
                pos_mode="long_short_mode",
                source="test",
            )

    def test_missing_exchange_close_classifies_before_cleaning_protection_orders(self):
        observed = []
        anchor = {
            "closed_at": timezone.now(),
            "close_price": Decimal("96"),
            "close_binance_order_id": "close-before-cleanup",
            "is_fully_closed": True,
            "close_qty": Decimal("1"),
        }
        cleanup_result = ClosedOrderCleanupResult(
            stop_order_id="",
            stop_market_order_id="",
            take_profit_algo_ids=[],
            manual_take_profit_algo_id="",
            pending_limit_updates=[],
            cancelled_algo_ids=[],
            cancelled_limit_order_ids=[],
            had_exchange_errors=False,
        )

        with (
            patch("positions.views._confirm_auto_close_candidate", return_value=(True, "confirmed")),
            patch("positions.views._snapshot_auto_close_anchor", return_value=anchor),
            patch(
                "positions.views.infer_exchange_close_notification",
                side_effect=lambda *_args, **_kwargs: observed.append("classify")
                or {
                    "event_type": "stop_loss",
                    "trigger_price": Decimal("90"),
                    "classification_confidence": 3,
                },
            ),
            patch(
                "positions.views.best_effort_cleanup_closed_order_exchange_artifacts",
                side_effect=lambda *_args, **_kwargs: observed.append("cleanup")
                or cleanup_result,
            ),
            patch("positions.lifecycle.enqueue_close_notification"),
        ):
            closed = _auto_close_missing_exchange_order(
                self.order,
                MagicMock(),
                user_id=self.user.id,
                source="test",
            )

        self.assertTrue(closed)
        self.assertEqual(observed, ["classify", "cleanup"])

    def test_missing_exchange_position_with_partial_close_evidence_stays_open(self):
        anchor = {
            "closed_at": timezone.now(),
            "close_price": Decimal("96"),
            "close_binance_order_id": "partial-close",
            "is_fully_closed": False,
            "close_qty": Decimal("1"),
        }

        with (
            patch("positions.views._confirm_auto_close_candidate", return_value=(True, "confirmed")),
            patch("positions.views._snapshot_auto_close_anchor", return_value=anchor),
            patch("positions.views.infer_exchange_close_notification") as infer_notification,
            patch("positions.views.best_effort_cleanup_closed_order_exchange_artifacts") as cleanup,
        ):
            closed = _auto_close_missing_exchange_order(
                self.order,
                MagicMock(),
                user_id=self.user.id,
                source="test",
            )

        self.assertFalse(closed)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)
        infer_notification.assert_not_called()
        cleanup.assert_not_called()

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_reconcile_stale_open_orders_skips_busy_account(self, mock_client_cls, mock_creds):
        self._bind_for_maintenance()
        mock_creds.return_value = object()
        account_identity = build_trading_account_identity(
            user_id=self.user.id, api_key_fingerprint=f"maintenance-current-{self.user.id}",
        )

        with user_trading_activity_lock(account_identity) as locked:
            repaired = reconcile_stale_open_orders()

        self.assertTrue(locked)
        self.assertEqual(repaired, 0)
        mock_client_cls.assert_not_called()

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_reconcile_stale_open_orders_closes_missing_exchange_position_and_cancels_linked_pending_limit(self, mock_client_cls, mock_creds):
        self._bind_for_maintenance()
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": "close-by-scheduler-2",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "fillSz": "1",
                    "fillPx": "96",
                    "time": str(int(timezone.now().timestamp() * 1000)),
                }
            ],
        }
        mock_client.get_pending_algo_orders.side_effect = [
            {
                "code": "0",
                "data": [
                    {"algoId": "stop-algo-1", "clientAlgoId": "tt1sl", "instId": "BTC-USDT-SWAP", "algoType": "STOP_MARKET", "side": "sell", "posSide": "long", "state": "live", "sz": "1", "slTriggerPx": "90"},
                    {"algoId": "tp-algo-1", "clientAlgoId": "tt1tp1", "instId": "BTC-USDT-SWAP", "algoType": "TAKE_PROFIT_MARKET", "side": "sell", "posSide": "long", "state": "live", "sz": "0.5", "tpTriggerPx": "110"},
                ],
            },
            {"code": "0", "data": []},
        ]
        mock_client.get_pending_orders.side_effect = [
            {"code": "0", "data": [{"ordId": "pending-limit-linked", "instId": "BTC-USDT-SWAP", "clientOrderId": "rtlo-linked"}]},
            {"code": "0", "data": []},
        ]
        mock_client.cancel_algos.return_value = {"code": "0", "data": [{"algoId": "ok"}]}
        mock_client.cancel_order.return_value = {
            "code": "0",
            "data": [{"ordId": "pending-limit-linked", "state": "canceled"}],
        }
        mock_client_cls.return_value = mock_client

        Order.objects.filter(id=self.order.id).update(created_at=timezone.now() - timedelta(minutes=5))
        self.order.refresh_from_db()
        self.order.binance_stop_order_id = "stop-algo-1"
        self.order.strategy_tp_algo_ids = ["tp-algo-1"]
        self.order.save(update_fields=["binance_stop_order_id", "strategy_tp_algo_ids"])
        linked_pending = LimitOrder.objects.create(
            user=self.user,
            order=self.order,
            binance_order_id="pending-limit-linked",
            binance_client_order_id="rtlo-linked",
            symbol="BTCUSDT",
            side=0,
            limit_price=Decimal("95"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=LimitOrder.STATUS_PENDING,
        )

        candidate_key = f"position:auto-close:candidate:{self.user.id}:{self.order.id}"
        cache.set(candidate_key, int((timezone.now() - timedelta(seconds=10)).timestamp()), timeout=120)

        repaired = reconcile_stale_open_orders()
        self.assertEqual(repaired, 1)
        self.order.refresh_from_db()
        linked_pending.refresh_from_db()
        self.assertEqual(self.order.status, 1)
        self.assertEqual(self.order.binance_stop_order_id, "")
        self.assertEqual(self.order.strategy_tp_algo_ids, [])
        self.assertEqual(linked_pending.status, LimitOrder.STATUS_CANCELLED)
        mock_client.cancel_order.assert_called_once_with(inst_id="BTC-USDT-SWAP", order_id="pending-limit-linked")

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_reconcile_stale_open_orders_matches_position_side_precisely(self, mock_client_cls, mock_creds):
        self._bind_for_maintenance()
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [
                {
                    "instId": "BTC-USDT-SWAP",
                    "posSide": "short",
                    "pos": "1",
                    "markPx": "101",
                }
            ],
        }
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": "close-by-scheduler-2",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "fillSz": "1",
                    "fillPx": "97",
                    "time": str(int(timezone.now().timestamp() * 1000)),
                }
            ],
        }
        mock_client_cls.return_value = mock_client

        Order.objects.filter(id=self.order.id).update(created_at=timezone.now() - timedelta(minutes=5))
        self.order.refresh_from_db()
        candidate_key = f"position:auto-close:candidate:{self.user.id}:{self.order.id}"
        cache.set(candidate_key, int((timezone.now() - timedelta(seconds=10)).timestamp()), timeout=120)

        repaired = reconcile_stale_open_orders()
        self.assertEqual(repaired, 1)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 1)
        self.assertEqual(self.order.close_binance_order_id, "close-by-scheduler-2")

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_reconcile_closed_order_exchange_artifacts_retries_residual_cleanup(self, mock_client_cls, mock_creds):
        self._bind_for_maintenance()
        mock_creds.return_value = object()
        self.order.status = 1
        self.order.closed_at = timezone.now()
        self.order.binance_stop_order_id = "stop-algo-1"
        self.order.strategy_tp_algo_ids = ["tp-algo-1"]
        self.order.save(update_fields=["status", "closed_at", "binance_stop_order_id", "strategy_tp_algo_ids"])
        linked_pending = LimitOrder.objects.create(
            user=self.user,
            order=self.order,
            binance_order_id="pending-limit-linked",
            binance_client_order_id="rtlo-linked",
            symbol="BTCUSDT",
            side=0,
            limit_price=Decimal("95"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=LimitOrder.STATUS_PENDING,
        )

        mock_client = MagicMock()
        mock_client.get_pending_algo_orders.side_effect = [
            {
                "code": "0",
                "data": [
                    {"algoId": "stop-algo-1", "clientAlgoId": "tt1sl", "instId": "BTC-USDT-SWAP", "algoType": "STOP_MARKET", "side": "sell", "posSide": "long", "state": "live", "sz": "1", "slTriggerPx": "90"},
                    {"algoId": "tp-algo-1", "clientAlgoId": "tt1tp1", "instId": "BTC-USDT-SWAP", "algoType": "TAKE_PROFIT_MARKET", "side": "sell", "posSide": "long", "state": "live", "sz": "0.5", "tpTriggerPx": "110"},
                ],
            },
            {"code": "0", "data": []},
        ]
        mock_client.get_pending_orders.side_effect = [
            {"code": "0", "data": [{"ordId": "pending-limit-linked", "instId": "BTC-USDT-SWAP", "clientOrderId": "rtlo-linked"}]},
            {"code": "0", "data": []},
        ]
        mock_client.cancel_algos.return_value = {"code": "0", "data": [{"algoId": "ok"}]}
        mock_client.cancel_order.return_value = {
            "code": "0",
            "data": [{"ordId": "pending-limit-linked", "state": "canceled"}],
        }
        mock_client_cls.return_value = mock_client

        repaired = reconcile_closed_order_exchange_artifacts(limit=10)
        self.assertEqual(repaired, 1)
        self.order.refresh_from_db()
        linked_pending.refresh_from_db()
        self.assertEqual(self.order.binance_stop_order_id, "")
        self.assertEqual(self.order.strategy_tp_algo_ids, [])
        self.assertEqual(linked_pending.status, LimitOrder.STATUS_CANCELLED)

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_reconcile_closed_order_exchange_artifacts_skips_busy_account(self, mock_client_cls, mock_creds):
        self._bind_for_maintenance()
        mock_creds.return_value = object()
        self.order.status = 1
        self.order.closed_at = timezone.now()
        self.order.binance_stop_order_id = "stop-algo-1"
        self.order.save(update_fields=["status", "closed_at", "binance_stop_order_id"])
        account_identity = build_trading_account_identity(
            user_id=self.user.id, api_key_fingerprint=f"maintenance-current-{self.user.id}",
        )

        with user_trading_activity_lock(account_identity) as locked:
            repaired = reconcile_closed_order_exchange_artifacts(limit=10)

        self.assertTrue(locked)
        self.assertEqual(repaired, 0)
        mock_client_cls.assert_not_called()

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_reconcile_closed_order_cleanup_stops_after_shared_rate_limit(
        self,
        mock_client_cls,
        mock_creds,
    ):
        self._bind_for_maintenance()
        now = timezone.now()
        mock_creds.return_value = object()
        self.order.status = 1
        self.order.closed_at = now
        self.order.binance_stop_order_id = "stop-algo-1"
        self.order.save(update_fields=["status", "closed_at", "binance_stop_order_id"])
        Order.objects.create(
            user=self.user,
            binance_order_id="closed-cleanup-2",
            symbol="ETHUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=1,
            closed_at=now - timedelta(seconds=1),
            binance_stop_order_id="stop-algo-2",
        )
        mock_client = mock_client_cls.return_value
        mock_client.get_pending_algo_orders.side_effect = BinanceApiError(
            "请求过于频繁",
            code="-1003",
        )

        repaired = reconcile_closed_order_exchange_artifacts(limit=10)

        self.assertEqual(repaired, 0)
        self.assertEqual(mock_client.get_pending_algo_orders.call_count, 1)
        mock_client.get_pending_orders.assert_not_called()

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_close(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.close_position.return_value = {
            "code": "0",
            "data": [{"ordId": "close-1", "avgPx": "110", "fillSz": "1", "state": "filled"}],
        }
        mock_client.get_positions.side_effect = [
            {
                "data": [{
                    "instId": "BTC-USDT-SWAP",
                    "posSide": "long",
                    "pos": "1",
                    "markPx": "110",
                    "ctVal": "1",
                    "upl": "10",
                    "uplRatio": "0.1",
                }],
            },
            {"data": []},
            {"data": []},
        ]
        pending_limit_order = LimitOrder.objects.create(
            user=self.user,
            binance_order_id="pending-limit-1",
            symbol="BTCUSDT",
            side=0,
            limit_price=Decimal("95"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=LimitOrder.STATUS_PENDING,
        )
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": "close-1",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "rawPositionSide": "LONG",
                    "fillSz": "1",
                    "fillPx": "110",
                    "realizedPnl": "10",
                    "fee": "0.5",
                    "time": str(int(timezone.now().timestamp() * 1000)),
                }
            ],
        }
        mock_client.get_bills.return_value = {
            "code": "0",
            "data": [
                {
                    "instId": "BTC-USDT-SWAP",
                    "type": "REALIZED_PNL",
                    "pnl": "10",
                    "uTime": str(int(timezone.now().timestamp() * 1000)),
                },
                {
                    "instId": "BTC-USDT-SWAP",
                    "type": "COMMISSION",
                    "pnl": "-0.5",
                    "uTime": str(int(timezone.now().timestamp() * 1000)),
                },
            ],
        }
        mock_client_cls.return_value = mock_client
        self.order.exchange_size = Decimal("1.5")
        self.order.has_manual_addition = True
        self.order.save(update_fields=["exchange_size", "has_manual_addition"])

        resp = self.client.post("/v1/position/close", {"position_id": self.order.id}, format="json")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 1)
        self.assertEqual(self.order.close_price, Decimal("110"))
        self.assertEqual(self.order.pnl, Decimal("9.5"))
        self.assertEqual(self.order.pnl_ratio, Decimal("9.5"))
        self.assertEqual(self.order.close_binance_order_id, "close-1")
        self.assertEqual(self.order.realized_pnl, Decimal("10"))
        self.assertEqual(self.order.realized_fee, Decimal("-0.5"))
        self.assertEqual(self.order.settlement_status, Order.SETTLEMENT_STATUS_ESTIMATED)
        self.assertEqual(self.order.exchange_size, Decimal("0"))
        self.assertFalse(self.order.has_manual_addition)
        self.assertEqual(mock_client.get_positions.call_count, 1)
        pending_limit_order.refresh_from_db()
        self.assertEqual(pending_limit_order.status, LimitOrder.STATUS_PENDING)

    @patch("positions.cleanup.cleanup_closed_order_exchange_artifacts", side_effect=RuntimeError("cleanup crashed"))
    @patch("positions.views._reconcile_order_settlement")
    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_close_persists_confirmed_close_when_artifact_cleanup_crashes(
        self,
        mock_client_cls,
        mock_creds,
        _mock_settlement,
        _mock_cleanup,
    ):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "data": [{
                "instId": "BTC-USDT-SWAP",
                "posSide": "long",
                "pos": "1",
                "markPx": "110",
                "ctVal": "1",
            }],
        }
        mock_client.close_position.return_value = {
            "data": [{"ordId": "close-after-cleanup-error", "avgPx": "110", "state": "filled"}],
        }
        mock_client_cls.return_value = mock_client
        self.order.binance_stop_order_id = "residual-stop"
        self.order.strategy_tp_algo_ids = ["residual-tp"]
        self.order.exchange_size = Decimal("1.5")
        self.order.has_manual_addition = True
        self.order.save(
            update_fields=[
                "binance_stop_order_id",
                "strategy_tp_algo_ids",
                "exchange_size",
                "has_manual_addition",
            ]
        )

        response = self.client.post(
            "/v1/position/close",
            {"position_id": self.order.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 1)
        self.assertEqual(self.order.close_binance_order_id, "close-after-cleanup-error")
        self.assertEqual(self.order.binance_stop_order_id, "residual-stop")
        self.assertEqual(self.order.strategy_tp_algo_ids, ["residual-tp"])
        self.assertEqual(self.order.exchange_size, Decimal("0"))
        self.assertFalse(self.order.has_manual_addition)

    @patch("positions.views.time.sleep")
    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_close_stays_open_until_exchange_position_is_gone(
        self, mock_client_cls, mock_creds, _mock_sleep
    ):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "data": [{
                "instId": "BTC-USDT-SWAP",
                "posSide": "long",
                "pos": "0.4",
                "markPx": "110",
                "ctVal": "1",
            }],
        }
        mock_client.close_position.return_value = {"data": [{"ordId": "close-pending"}]}
        mock_client_cls.return_value = mock_client
        self.order.binance_stop_order_id = "stop-1"
        self.order.strategy_tp_algo_ids = ["tp-1"]
        self.order.save(update_fields=["binance_stop_order_id", "strategy_tp_algo_ids"])

        response = self.client.post("/v1/position/close", {"position_id": self.order.id}, format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("尚未确认仓位归零", response.data["message"])
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)
        self.assertEqual(self.order.binance_stop_order_id, "stop-1")
        self.assertEqual(self.order.strategy_tp_algo_ids, ["tp-1"])
        mock_client.cancel_algos.assert_not_called()

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_close_returns_definitive_rejection_without_confirmation_queries(
        self,
        mock_client_cls,
        mock_creds,
    ):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {
            "data": [{"posMode": "long_short_mode"}],
        }
        mock_client.get_positions.return_value = {
            "data": [{
                "instId": "BTC-USDT-SWAP",
                "posSide": "long",
                "pos": "1",
                "markPx": "110",
                "ctVal": "1",
            }],
        }
        mock_client.close_position.side_effect = BinanceApiError("权限不足", code="-2015")
        mock_client_cls.return_value = mock_client

        response = self.client.post(
            "/v1/position/close",
            {"position_id": self.order.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("权限不足", response.data["message"])
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)
        self.assertEqual(mock_client.get_positions.call_count, 1)

    @patch("positions.views.time.sleep")
    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_close_does_not_accept_one_transient_empty_position_result(
        self,
        mock_client_cls,
        mock_creds,
        _mock_sleep,
    ):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        live_position = {
            "data": [{
                "instId": "BTC-USDT-SWAP",
                "posSide": "long",
                "pos": "0.4",
                "markPx": "110",
                "ctVal": "1",
            }],
        }
        mock_client.get_account_config.return_value = {
            "data": [{"posMode": "long_short_mode"}],
        }
        mock_client.get_positions.side_effect = [
            live_position,
            {"data": []},
            live_position,
            live_position,
            live_position,
        ]
        mock_client.close_position.return_value = {"data": [{"ordId": "close-pending"}]}
        mock_client_cls.return_value = mock_client

        response = self.client.post(
            "/v1/position/close",
            {"position_id": self.order.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)
        mock_client.cancel_algos.assert_not_called()

    @patch("positions.views.time.sleep")
    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_close_recovers_unknown_response_after_two_absent_position_checks(
        self,
        mock_client_cls,
        mock_creds,
        _mock_sleep,
    ):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {
            "data": [{"posMode": "long_short_mode"}],
        }
        mock_client.get_positions.side_effect = [
            {
                "data": [{
                    "instId": "BTC-USDT-SWAP",
                    "posSide": "long",
                    "pos": "1",
                    "markPx": "110",
                    "ctVal": "1",
                }],
            },
            {"data": []},
            {"data": []},
        ]
        mock_client.close_position.side_effect = BinanceApiError(
            "平仓响应超时",
            code="-1007",
            outcome_unknown=True,
        )
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": []}
        mock_client.get_pending_orders.return_value = {"code": "0", "data": []}
        mock_client.get_user_trades.return_value = {"code": "0", "data": []}
        mock_client.get_bills.return_value = {"code": "0", "data": []}
        mock_client_cls.return_value = mock_client
        self.order.exchange_size = Decimal("1.5")
        self.order.has_manual_addition = True
        self.order.save(update_fields=["exchange_size", "has_manual_addition"])

        response = self.client.post(
            "/v1/position/close",
            {"position_id": self.order.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 1)
        self.assertEqual(self.order.exchange_size, Decimal("0"))
        self.assertFalse(self.order.has_manual_addition)
        self.assertEqual(mock_client.get_positions.call_count, 3)
        mock_client.close_position.assert_called_once_with(
            inst_id="BTC-USDT-SWAP",
            pos_side="long",
            expected_side="long",
        )

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_close_only_cancels_pending_limit_orders_linked_to_current_order(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.close_position.return_value = {
            "code": "0",
            "data": [{"ordId": "close-2", "avgPx": "110", "fillSz": "1", "state": "filled"}],
        }
        mock_client.get_positions.side_effect = [
            {
                "data": [{
                    "instId": "BTC-USDT-SWAP",
                    "posSide": "long",
                    "pos": "1",
                    "markPx": "110",
                    "ctVal": "1",
                }],
            },
            {"data": []},
            {"data": []},
        ]
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": "close-2",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "fillSz": "1",
                    "fillPx": "110",
                    "fee": "0.5",
                    "time": str(int(timezone.now().timestamp() * 1000)),
                }
            ],
        }
        mock_client.get_bills.return_value = {
            "code": "0",
            "data": [
                {
                    "instId": "BTC-USDT-SWAP",
                    "type": "REALIZED_PNL",
                    "pnl": "10",
                    "uTime": str(int(timezone.now().timestamp() * 1000)),
                }
            ],
        }
        mock_client.get_pending_orders.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": "pending-limit-linked",
                    "instId": "BTC-USDT-SWAP",
                    "clientOrderId": "rtlo-linked",
                },
                {
                    "ordId": "pending-limit-other",
                    "instId": "BTC-USDT-SWAP",
                    "clientOrderId": "rtlo-other",
                },
            ],
        }
        mock_client.cancel_order.return_value = {
            "code": "0",
            "data": [{"ordId": "pending-limit-linked", "state": "canceled"}],
        }
        mock_client_cls.return_value = mock_client

        linked_pending = LimitOrder.objects.create(
            user=self.user,
            binance_order_id="pending-limit-linked",
            binance_client_order_id="rtlo-linked",
            symbol="BTCUSDT",
            side=0,
            limit_price=Decimal("95"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=LimitOrder.STATUS_PENDING,
            order=self.order,
        )
        unrelated_pending = LimitOrder.objects.create(
            user=self.user,
            binance_order_id="pending-limit-other",
            binance_client_order_id="rtlo-other",
            symbol="BTCUSDT",
            side=0,
            limit_price=Decimal("94"),
            stop_loss_price=Decimal("89"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=LimitOrder.STATUS_PENDING,
        )

        resp = self.client.post("/v1/position/close", {"position_id": self.order.id}, format="json")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)

        linked_pending.refresh_from_db()
        unrelated_pending.refresh_from_db()
        self.assertEqual(linked_pending.status, LimitOrder.STATUS_CANCELLED)
        self.assertEqual(unrelated_pending.status, LimitOrder.STATUS_PENDING)
        mock_client.cancel_order.assert_called_once_with(inst_id="BTC-USDT-SWAP", order_id="pending-limit-linked")

    def test_strategy_cancel(self):
        resp = self.client.post("/v1/strategy/cancel", {"position_id": self.order.id}, format="json")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.order.refresh_from_db()
        self.assertEqual(self.order.strategy_status, Order.STRATEGY_STATUS_CANCELLED)
        self.assertTrue(OrderStrategyLog.objects.filter(order=self.order, snapshot=self.snapshot).exists())

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_manual_take_profit_set_and_cancel(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{
                "instId": "BTC-USDT-SWAP",
                "posSide": "long",
                "pos": "1",
                "markPx": "110",
                "last": "110",
                "ctVal": "1",
            }],
        }
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.place_take_profit_order.return_value = {"code": "0", "data": [{"algoId": "mtp-001", "sCode": "0"}]}
        mock_client.cancel_algos.return_value = {"code": "0", "data": [{"algoId": "mtp-001"}]}
        mock_client_cls.return_value = mock_client

        resp = self.client.post(
            "/v1/position/take-profit",
            {"position_id": self.order.id, "take_profit_price": "120", "order_type": "limit"},
            format="json",
        )

        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.order.refresh_from_db()
        self.assertEqual(self.order.manual_take_profit_algo_id, "mtp-001")
        self.assertEqual(self.order.manual_take_profit_price, Decimal("120"))
        self.assertEqual(self.order.manual_take_profit_order_type, "limit")
        mock_client.place_take_profit_order.assert_called_once()
        self.assertEqual(mock_client.place_take_profit_order.call_args.kwargs["order_type"], "limit")

        resp = self.client.delete("/v1/position/take-profit", {"position_id": self.order.id}, format="json")

        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.order.refresh_from_db()
        self.assertEqual(self.order.manual_take_profit_algo_id, "")
        self.assertIsNone(self.order.manual_take_profit_price)
        self.assertEqual(self.order.manual_take_profit_order_type, "")
        mock_client.cancel_algos.assert_called_with(algo_id="mtp-001", inst_id="BTC-USDT-SWAP")

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_manual_take_profit_replacement_failure_keeps_existing_order(self, mock_client_cls, mock_creds):
        self.order.manual_take_profit_algo_id = "mtp-old"
        self.order.manual_take_profit_price = Decimal("120")
        self.order.manual_take_profit_order_type = "limit"
        self.order.save(update_fields=[
            "manual_take_profit_algo_id",
            "manual_take_profit_price",
            "manual_take_profit_order_type",
        ])
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{
                "instId": "BTC-USDT-SWAP",
                "posSide": "long",
                "pos": "1",
                "markPx": "110",
                "last": "110",
            }],
        }
        mock_client.get_account_config.return_value = {
            "code": "0",
            "data": [{"posMode": "long_short_mode"}],
        }
        mock_client.place_take_profit_order.side_effect = BinanceApiError("replacement rejected")
        mock_client_cls.return_value = mock_client

        resp = self.client.post(
            "/v1/position/take-profit",
            {"position_id": self.order.id, "take_profit_price": "125", "order_type": "limit"},
            format="json",
        )

        self.assertEqual(resp.status_code, status.HTTP_400_BAD_REQUEST)
        self.order.refresh_from_db()
        self.assertEqual(self.order.manual_take_profit_algo_id, "mtp-old")
        self.assertEqual(self.order.manual_take_profit_price, Decimal("120"))
        mock_client.cancel_algos.assert_not_called()

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_manual_take_profit_replacement_confirms_new_order_before_canceling_old(
        self,
        mock_client_cls,
        mock_creds,
    ):
        self.order.manual_take_profit_algo_id = "mtp-old"
        self.order.manual_take_profit_price = Decimal("120")
        self.order.manual_take_profit_order_type = "market"
        self.order.save(update_fields=[
            "manual_take_profit_algo_id",
            "manual_take_profit_price",
            "manual_take_profit_order_type",
        ])
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{
                "instId": "BTC-USDT-SWAP",
                "posSide": "long",
                "pos": "1",
                "markPx": "110",
                "last": "110",
            }],
        }
        mock_client.get_account_config.return_value = {
            "code": "0",
            "data": [{"posMode": "long_short_mode"}],
        }
        mock_client.place_take_profit_order.return_value = {
            "code": "0",
            "data": [{"algoId": "mtp-new", "sCode": "0"}],
        }
        mock_client.get_pending_algo_orders.return_value = {
            "code": "0",
            "data": [{"algoId": "mtp-new", "sz": "1", "state": "live"}],
        }
        mock_client.cancel_algos.return_value = {
            "code": "0",
            "data": [{"algoId": "mtp-old"}],
        }
        mock_client_cls.return_value = mock_client

        response = self.client.post(
            "/v1/position/take-profit",
            {"position_id": self.order.id, "take_profit_price": "125", "order_type": "market"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.order.refresh_from_db()
        self.assertEqual(self.order.manual_take_profit_algo_id, "mtp-new")
        self.assertEqual(self.order.manual_take_profit_price, Decimal("125"))
        method_names = [call_item[0] for call_item in mock_client.mock_calls]
        self.assertLess(
            method_names.index("place_take_profit_order"),
            method_names.index("cancel_algos"),
        )
        self.assertLess(
            method_names.index("get_pending_algo_orders"),
            method_names.index("cancel_algos"),
        )

    @patch("common.binance.time.sleep")
    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_manual_take_profit_visibility_timeout_reports_preserved_order(
        self,
        mock_client_cls,
        mock_creds,
        _mock_sleep,
    ):
        self.order.manual_take_profit_algo_id = "mtp-old"
        self.order.manual_take_profit_price = Decimal("120")
        self.order.manual_take_profit_order_type = "market"
        self.order.save(update_fields=[
            "manual_take_profit_algo_id",
            "manual_take_profit_price",
            "manual_take_profit_order_type",
        ])
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{
                "instId": "BTC-USDT-SWAP",
                "posSide": "long",
                "pos": "1",
                "markPx": "110",
                "last": "110",
            }],
        }
        mock_client.get_account_config.return_value = {
            "code": "0",
            "data": [{"posMode": "long_short_mode"}],
        }
        mock_client.place_take_profit_order.return_value = {
            "code": "0",
            "data": [{"algoId": "mtp-new", "sCode": "0"}],
        }
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": []}
        mock_client.cancel_algos.return_value = {
            "code": "0",
            "data": [{"algoId": "mtp-new"}],
        }
        mock_client_cls.return_value = mock_client

        response = self.client.post(
            "/v1/position/take-profit",
            {"position_id": self.order.id, "take_profit_price": "125", "order_type": "market"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("原止盈价 120", response.data["message"])
        self.order.refresh_from_db()
        self.assertEqual(self.order.manual_take_profit_algo_id, "mtp-old")
        self.assertEqual(self.order.manual_take_profit_price, Decimal("120"))
        mock_client.cancel_algos.assert_called_once_with(
            algo_id="mtp-new",
            inst_id="BTC-USDT-SWAP",
        )

    @patch("common.binance.time.sleep")
    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_manual_take_profit_cancel_failure_keeps_local_state(
        self,
        mock_client_cls,
        mock_creds,
        _mock_sleep,
    ):
        self.order.manual_take_profit_algo_id = "mtp-keep"
        self.order.manual_take_profit_price = Decimal("120")
        self.order.manual_take_profit_order_type = "market"
        self.order.save(update_fields=[
            "manual_take_profit_algo_id",
            "manual_take_profit_price",
            "manual_take_profit_order_type",
        ])
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.cancel_algos.side_effect = BinanceApiError(
            "请求超时",
            code="-1007",
            outcome_unknown=True,
        )
        mock_client.get_pending_algo_orders.return_value = {
            "code": "0",
            "data": [{"algoId": "mtp-keep"}],
        }
        mock_client_cls.return_value = mock_client

        response = self.client.delete(
            "/v1/position/take-profit",
            {"position_id": self.order.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.order.refresh_from_db()
        self.assertEqual(self.order.manual_take_profit_algo_id, "mtp-keep")
        self.assertEqual(self.order.manual_take_profit_price, Decimal("120"))

    @patch("common.binance.time.sleep")
    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_strategy_cancel_failure_keeps_running_state_and_order_ids(
        self,
        mock_client_cls,
        mock_creds,
        _mock_sleep,
    ):
        self.order.strategy_tp_algo_ids = ["tp-keep"]
        self.order.save(update_fields=["strategy_tp_algo_ids"])
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.cancel_algos.side_effect = BinanceApiError(
            "请求超时",
            code="-1007",
            outcome_unknown=True,
        )
        mock_client.get_pending_algo_orders.return_value = {
            "code": "0",
            "data": [{"algoId": "tp-keep"}],
        }
        mock_client_cls.return_value = mock_client

        response = self.client.post(
            "/v1/strategy/cancel",
            {"position_id": self.order.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.order.refresh_from_db()
        self.assertEqual(self.order.strategy_status, Order.STRATEGY_STATUS_RUNNING)
        self.assertEqual(self.order.strategy_tp_algo_ids, ["tp-keep"])

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_strategy_rebind_allowed_when_position_size_unchanged(self, mock_client_cls, mock_creds):
        from trading.models import Strategy, StrategyLevel

        strategy = Strategy.objects.create(user=self.user, name="新策略")
        StrategyLevel.objects.create(
            strategy=strategy,
            sort_order=1,
            profit_rr=Decimal("1.5"),
            reduce_position=Decimal("50"),
            stop_loss_type="fixedRR",
            stop_loss_rr=Decimal("0.5"),
        )

        self.order.strategy_status = Order.STRATEGY_STATUS_CANCELLED
        self.order.strategy_tp_algo_ids = []
        self.order.save(update_fields=["strategy_status", "strategy_tp_algo_ids"])

        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [
                {"instId": "BTC-USDT-SWAP", "posSide": "short", "pos": "0.5"},
                {"instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "1"},
            ],
        }
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.place_take_profit_order.return_value = {"code": "0", "data": [{"algoId": "tp-001", "sCode": "0"}]}
        mock_client_cls.return_value = mock_client

        resp = self.client.post(
            "/v1/strategy/rebind",
            {"position_id": self.order.id, "strategy_id": strategy.id},
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.order.refresh_from_db()
        self.assertEqual(self.order.strategy_status, Order.STRATEGY_STATUS_RUNNING)
        self.assertTrue(self.order.strategy_tp_algo_ids)
        self.assertIsNotNone(self.order.strategy_snapshot_id)

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_strategy_rebind_rolls_back_exchange_orders_when_final_persistence_fails(
        self,
        mock_client_cls,
        mock_creds,
    ):
        from trading.models import Strategy, StrategyLevel

        strategy = Strategy.objects.create(user=self.user, name="落库失败策略")
        StrategyLevel.objects.create(
            strategy=strategy,
            sort_order=1,
            profit_rr=Decimal("1.5"),
            reduce_position=Decimal("50"),
            stop_loss_type="fixedRR",
            stop_loss_rr=Decimal("0.5"),
        )
        self.order.strategy_status = Order.STRATEGY_STATUS_CANCELLED
        self.order.strategy_tp_algo_ids = []
        self.order.save(update_fields=["strategy_status", "strategy_tp_algo_ids"])

        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{"instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "1"}],
        }
        mock_client.get_account_config.return_value = {
            "code": "0",
            "data": [{"posMode": "long_short_mode"}],
        }
        mock_client.place_take_profit_order.return_value = {
            "code": "0",
            "data": [{"algoId": "tp-rollback", "sCode": "0"}],
        }
        mock_client.cancel_algos.return_value = {
            "code": "0",
            "data": [{"algoId": "tp-rollback"}],
        }
        mock_client_cls.return_value = mock_client

        with patch.object(Order, "save", side_effect=RuntimeError("database write failed")):
            response = self.client.post(
                "/v1/strategy/rebind",
                {"position_id": self.order.id, "strategy_id": strategy.id},
                format="json",
            )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        mock_client.cancel_algos.assert_called_once_with(
            algo_id="tp-rollback",
            inst_id="BTC-USDT-SWAP",
        )
        self.order.refresh_from_db()
        self.assertEqual(self.order.strategy_status, Order.STRATEGY_STATUS_CANCELLED)
        self.assertEqual(self.order.strategy_tp_algo_ids, [])
        self.assertFalse(
            OrderStrategySnapshot.objects.filter(
                order=self.order,
                strategy_id=str(strategy.id),
            ).exists()
        )

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_strategy_rebind_reports_account_config_failure_before_snapshot_creation(
        self,
        mock_client_cls,
        mock_creds,
    ):
        from trading.models import Strategy, StrategyLevel

        strategy = Strategy.objects.create(user=self.user, name="失败路径策略")
        StrategyLevel.objects.create(
            strategy=strategy,
            sort_order=1,
            profit_rr=Decimal("1.5"),
            reduce_position=Decimal("50"),
            stop_loss_type="fixedRR",
            stop_loss_rr=Decimal("0.5"),
        )
        self.order.strategy_status = Order.STRATEGY_STATUS_CANCELLED
        self.order.strategy_tp_algo_ids = []
        self.order.save(update_fields=["strategy_status", "strategy_tp_algo_ids"])

        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{"instId": "BTC-USDT-SWAP", "pos": "1"}],
        }
        mock_client.get_account_config.side_effect = BinanceApiError("账户配置暂不可用")
        mock_client_cls.return_value = mock_client

        response = self.client.post(
            "/v1/strategy/rebind",
            {"position_id": self.order.id, "strategy_id": strategy.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["message"], "账户配置暂不可用")
        self.assertFalse(
            OrderStrategySnapshot.objects.filter(
                order=self.order,
                strategy_id=str(strategy.id),
            ).exists()
        )

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_strategy_rebind_blocked_when_position_size_changed(self, mock_client_cls, mock_creds):
        from trading.models import Strategy

        strategy = Strategy.objects.create(user=self.user, name="新策略")
        self.order.strategy_status = Order.STRATEGY_STATUS_CANCELLED
        self.order.save(update_fields=["strategy_status"])

        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{"instId": "BTC-USDT-SWAP", "pos": "0.5"}],
        }
        mock_client_cls.return_value = mock_client

        resp = self.client.post(
            "/v1/strategy/rebind",
            {"position_id": self.order.id, "strategy_id": strategy.id},
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(resp.data["message"], "该订单无法添加止盈策略")

    def test_strategy_log(self):
        OrderStrategyLog.objects.create(
            order=self.order,
            snapshot=self.snapshot,
            behavior_desc="达到1R，减仓50%",
            result=OrderStrategyLog.RESULT_SUCCESS,
        )
        resp = self.client.get(f"/v1/strategy/log?position_id={self.order.id}")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["strategy_name"], "稳健通用")
        self.assertEqual(len(resp.data["data"]["logs"]), 1)
        self.assertEqual(resp.data["data"]["logs"][0]["behavior_desc"], "达到1R，减仓50%")

    def test_strategy_log_deduplicates_identical_visible_messages(self):
        for _ in range(3):
            OrderStrategyLog.objects.create(
                order=self.order,
                snapshot=self.snapshot,
                behavior_desc="L1 止损移动失败",
                trigger_r=Decimal("1.00"),
                result=OrderStrategyLog.RESULT_FAILED,
                error="Unknown order sent.",
            )
        OrderStrategyLog.objects.create(
            order=self.order,
            snapshot=self.snapshot,
            behavior_desc="L2 止损移动失败",
            trigger_r=Decimal("2.00"),
            result=OrderStrategyLog.RESULT_FAILED,
            error="Unknown order sent.",
        )

        resp = self.client.get(f"/v1/strategy/log?position_id={self.order.id}")

        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        logs = resp.data["data"]["logs"]
        self.assertEqual(len(logs), 2)
        self.assertEqual(logs[0]["behavior_desc"], "L1 止损移动失败")
        self.assertEqual(logs[0]["error"], "Unknown order sent.")
        self.assertEqual(logs[1]["behavior_desc"], "L2 止损移动失败")

    def test_position_history_shows_local_closed_orders_without_exchange_history(self):
        self.order.status = 1
        self.order.close_price = Decimal("120")
        self.order.position_amount = Decimal("120")
        self.order.pnl = Decimal("18")
        self.order.pnl_ratio = Decimal("18")
        self.order.closed_at = self.order.created_at
        self.order.save(update_fields=["status", "close_price", "position_amount", "pnl", "pnl_ratio", "closed_at"])

        OrderStrategyLog.objects.create(
            order=self.order,
            snapshot=self.snapshot,
            behavior_desc="历史测试日志",
            result=OrderStrategyLog.RESULT_SUCCESS,
        )

        resp = self.client.get("/v1/position/history")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["pagination"]["total"], 1)
        self.assertEqual(len(resp.data["data"]["items"]), 1)
        item = resp.data["data"]["items"][0]
        self.assertEqual(item["id"], self.order.id)
        self.assertEqual(item["open_price"], "100.00000000")
        self.assertEqual(item["close_price"], "120.00000000")
        self.assertEqual(item["pnl"], "18.00000000")
        self.assertEqual(item["realized_pnl"], "18.00000000")
        self.assertEqual(item["fee"], "0.00000000")
        self.assertEqual(item["stop_loss_amount"], "30.00")
        self.assertTrue(item["has_strategy_logs"])
        self.assertEqual(item["data_source_flags"]["pnl"], "local_order")
        self.assertEqual(item["data_source_flags"]["fee"], "local_order")
        self.assertEqual(item["size"], "1.00000000")
        self.assertEqual(item["opened_at"], item["created_at"])

    def test_position_history_filters_by_closed_time(self):
        self.order.status = 1
        self.order.closed_at = timezone.now() - timedelta(days=5)
        self.order.save(update_fields=["status", "closed_at"])

        resp = self.client.get("/v1/position/history?filter=day")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["items"], [])
        self.assertEqual(resp.data["data"]["pagination"]["total"], 0)

    def test_position_history_date_range_includes_end_of_day(self):
        now = timezone.now()
        self.order.status = 1
        self.order.closed_at = now.replace(hour=12, minute=0, second=0, microsecond=0)
        self.order.save(update_fields=["status", "closed_at"])
        day_str = self.order.closed_at.date().isoformat()

        resp = self.client.get(f"/v1/position/history?start_time={day_str}&end_time={day_str}")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["pagination"]["total"], 1)
        self.assertEqual(len(resp.data["data"]["items"]), 1)

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_history_includes_open_order_with_partial_close(self, mock_client_cls, mock_creds):
        trade_time = timezone.now()
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": "tp-1",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "fillSz": "0.4",
                    "fillPx": "120",
                    "realizedPnl": "8",
                    "fee": "0.2",
                    "time": str(int(trade_time.timestamp() * 1000)),
                }
            ],
        }
        mock_client.get_bills.return_value = {
            "code": "0",
            "data": [
                {
                    "instId": "BTC-USDT-SWAP",
                    "type": "REALIZED_PNL",
                    "pnl": "8",
                    "uTime": str(int(trade_time.timestamp() * 1000)),
                },
                {
                    "instId": "BTC-USDT-SWAP",
                    "type": "COMMISSION",
                    "pnl": "-0.2",
                    "uTime": str(int(trade_time.timestamp() * 1000)),
                },
            ],
        }
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [
                {
                    "instId": "BTC-USDT-SWAP",
                    "posSide": "long",
                    "upl": "55",
                }
            ],
        }
        mock_client_cls.return_value = mock_client

        resp = self.client.get("/v1/position/history")

        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["pagination"]["total"], 1)
        item = resp.data["data"]["items"][0]
        self.assertEqual(item["id"], self.order.id)
        self.assertTrue(item["is_partial_history"])
        self.assertEqual(item["pnl"], "7.80000000")
        self.assertEqual(item["realized_pnl"], "8.00000000")
        self.assertEqual(item["fee"], "-0.20000000")
        self.assertEqual(item["floating_pnl"], "55.00000000")
        self.assertEqual(item["close_price"], "120")
        self.assertEqual(item["position_amount"], "48.0")
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, 0)

    def test_position_history_supports_pagination(self):
        self.order.status = 1
        self.order.closed_at = timezone.now() - timedelta(hours=1)
        self.order.save(update_fields=["status", "closed_at"])
        second_order = Order.objects.create(
            user=self.user,
            binance_order_id="binance-order-2",
            symbol="ETHUSDT",
            side=1,
            open_price=Decimal("200"),
            stop_loss_price=Decimal("210"),
            stop_loss_amount=Decimal("50"),
            size=Decimal("2"),
            leverage=5,
            status=1,
            closed_at=timezone.now(),
        )

        resp = self.client.get("/v1/position/history?page=1&page_size=1")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        data = resp.data["data"]
        self.assertEqual(data["pagination"]["page"], 1)
        self.assertEqual(data["pagination"]["page_size"], 1)
        self.assertEqual(data["pagination"]["total"], 2)
        self.assertTrue(data["pagination"]["has_next"])
        self.assertEqual(len(data["items"]), 1)
        self.assertEqual(data["items"][0]["id"], second_order.id)

        resp_page_2 = self.client.get("/v1/position/history?page=2&page_size=1")
        self.assertEqual(resp_page_2.status_code, status.HTTP_200_OK)
        self.assertEqual(len(resp_page_2.data["data"]["items"]), 1)
        self.assertEqual(resp_page_2.data["data"]["items"][0]["id"], self.order.id)

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_history_prefers_per_trade_fields_over_bills(self, mock_client_cls, mock_creds):
        self.order.status = 1
        self.order.close_price = Decimal("120")
        self.order.position_amount = Decimal("120")
        self.order.pnl = Decimal("18")
        self.order.pnl_ratio = Decimal("18")
        self.order.closed_at = timezone.now()
        self.order.close_binance_order_id = "close-22"
        self.order.settlement_status = Order.SETTLEMENT_STATUS_FAILED
        self.order.save(update_fields=["status", "close_price", "position_amount", "pnl", "pnl_ratio", "closed_at", "close_binance_order_id", "settlement_status"])

        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": "tp-11",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "fillPx": "118",
                    "fillSz": "0.5",
                    "realizedPnl": "3",
                    "fee": "0.1",
                    "time": str(int((self.order.created_at + timedelta(minutes=10)).timestamp() * 1000)),
                },
                {
                    "ordId": "close-22",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "fillPx": "120",
                    "fillSz": "1",
                    "realizedPnl": "9.5",
                    "fee": "0.8",
                    "time": str(int(self.order.created_at.timestamp() * 1000)),
                }
            ],
        }
        mock_client.get_bills.return_value = {
            "code": "0",
            "data": [
                {
                    "instId": "BTC-USDT-SWAP",
                    "type": "REALIZED_PNL",
                    "pnl": "3",
                    "uTime": str(int((self.order.created_at + timedelta(minutes=10)).timestamp() * 1000)),
                },
                {
                    "instId": "BTC-USDT-SWAP",
                    "type": "COMMISSION",
                    "pnl": "-0.1",
                    "uTime": str(int((self.order.created_at + timedelta(minutes=10)).timestamp() * 1000)),
                },
                {
                    "instId": "BTC-USDT-SWAP",
                    "type": "REALIZED_PNL",
                    "pnl": "22.5",
                    "uTime": str(int(self.order.closed_at.timestamp() * 1000)),
                },
                {
                    "instId": "BTC-USDT-SWAP",
                    "type": "COMMISSION",
                    "pnl": "-1.2",
                    "uTime": str(int(self.order.closed_at.timestamp() * 1000)),
                },
                {
                    "instId": "BTC-USDT-SWAP",
                    "type": "FUNDING_FEE",
                    "pnl": "-0.3",
                    "uTime": str(int(self.order.closed_at.timestamp() * 1000)),
                },
            ],
        }
        mock_client_cls.return_value = mock_client

        resp = self.client.get("/v1/position/history")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        item = resp.data["data"]["items"][0]
        # 成交明细按订单号精确归属，优先于时间窗口匹配的账单流水（后者会混入邻单费用）
        self.assertEqual(item["pnl"], "8.40000000", item)
        self.assertEqual(item["realized_pnl"], "9.50000000")
        self.assertEqual(item["fee"], "-0.80000000")
        self.assertEqual(item["funding_fee"], "-0.30000000")
        self.assertEqual(Decimal(item["close_price"]).quantize(Decimal("0.0001")), Decimal("120.0000"))
        self.assertEqual(item["position_amount"], "120.00")
        self.assertEqual(item["data_source_flags"]["pnl"], "binance_trade")
        self.assertEqual(item["data_source_flags"]["fee"], "binance_trade")
        self.assertEqual(item["data_source_flags"]["funding_fee"], "binance_bill")

    def test_position_history_prefers_local_settled_financials(self):
        self.order.status = 1
        self.order.close_price = Decimal("120")
        self.order.position_amount = Decimal("120")
        self.order.pnl = Decimal("19.7")
        self.order.pnl_ratio = Decimal("19.7")
        self.order.realized_pnl = Decimal("21")
        self.order.realized_fee = Decimal("-1.1")
        self.order.realized_funding_fee = Decimal("-0.2")
        self.order.settlement_status = Order.SETTLEMENT_STATUS_SETTLED
        self.order.settled_at = timezone.now()
        self.order.closed_at = timezone.now()
        self.order.save(update_fields=[
            "status",
            "close_price",
            "position_amount",
            "pnl",
            "pnl_ratio",
            "realized_pnl",
            "realized_fee",
            "realized_funding_fee",
            "settlement_status",
            "settled_at",
            "closed_at",
        ])

        resp = self.client.get("/v1/position/history")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        item = resp.data["data"]["items"][0]
        self.assertEqual(item["pnl"], "19.70000000")
        self.assertEqual(item["realized_pnl"], "21.00000000")
        self.assertEqual(item["fee"], "-1.10000000")
        self.assertEqual(item["funding_fee"], "-0.20000000")
        self.assertEqual(item["data_source_flags"]["pnl"], "local_settled_order")
        self.assertEqual(item["data_source_flags"]["fee"], "local_settled_order")
        self.assertEqual(item["data_source_flags"]["funding_fee"], "local_settled_order")

    def test_position_history_derives_local_pnl_when_saved_pnl_is_zero(self):
        self.order.status = 1
        self.order.close_price = Decimal("110")
        self.order.position_amount = Decimal("110")
        self.order.pnl = Decimal("0")
        self.order.pnl_ratio = Decimal("0")
        self.order.closed_at = timezone.now()
        self.order.save(update_fields=["status", "close_price", "position_amount", "pnl", "pnl_ratio", "closed_at"])

        resp = self.client.get("/v1/position/history")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        item = resp.data["data"]["items"][0]
        self.assertEqual(item["pnl"], "10.00000000")
        self.assertEqual(item["realized_pnl"], "10.00000000")
        self.assertEqual(item["pnl_ratio"], "10.0000")
        self.assertEqual(item["data_source_flags"]["pnl"], "local_order_derived")
        self.assertEqual(item["data_source_flags"]["pnl_ratio"], "derived_from_pnl")

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_history_precisely_fetches_unsettled_order_financials(self, mock_client_cls, mock_creds):
        older = Order.objects.create(
            user=self.user,
            binance_order_id="binance-order-older",
            symbol="ETHUSDT",
            side=0,
            open_price=Decimal("200"),
            stop_loss_price=Decimal("180"),
            stop_loss_amount=Decimal("20"),
            size=Decimal("1"),
            leverage=5,
            status=1,
            close_price=Decimal("210"),
            closed_at=timezone.now() - timedelta(days=2),
            pnl=Decimal("0"),
            pnl_ratio=Decimal("0"),
            settlement_status=Order.SETTLEMENT_STATUS_SETTLED,
            realized_pnl=Decimal("10"),
            realized_fee=Decimal("0.1"),
        )
        self.order.status = 1
        self.order.close_price = Decimal("110")
        self.order.closed_at = timezone.now()
        self.order.close_binance_order_id = "close-1"
        self.order.pnl = Decimal("0")
        self.order.pnl_ratio = Decimal("0")
        self.order.settlement_status = Order.SETTLEMENT_STATUS_FAILED
        self.order.save(update_fields=["status", "close_price", "closed_at", "close_binance_order_id", "pnl", "pnl_ratio", "settlement_status"])

        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": self.order.binance_order_id,
                    "instId": "BTC-USDT-SWAP",
                    "side": "buy",
                    "fillSz": "1",
                    "realizedPnl": "0",
                    "fee": "0.1",
                    "time": str(int(self.order.created_at.timestamp() * 1000)),
                },
                {
                    "ordId": "close-1",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "fillSz": "1",
                    "realizedPnl": "12",
                    "fee": "0.4",
                    "time": str(int(self.order.closed_at.timestamp() * 1000)),
                },
            ],
        }
        mock_client.get_bills.return_value = {"code": "0", "data": [{"instId": "BTC-USDT-SWAP", "type": "REALIZED_PNL", "pnl": "12", "uTime": str(int(self.order.closed_at.timestamp() * 1000))}]}
        mock_client_cls.return_value = mock_client

        resp = self.client.get("/v1/position/history?page_size=20")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        items = resp.data["data"]["items"]
        latest = next(item for item in items if item["id"] == self.order.id)
        self.assertEqual(latest["pnl"], "11.50000000")
        self.assertEqual(latest["realized_pnl"], "12.00000000")
        self.assertEqual(latest["data_source_flags"]["pnl"], "binance_trade")
        self.order.refresh_from_db()
        self.assertEqual(self.order.settlement_status, Order.SETTLEMENT_STATUS_SETTLED)
        self.assertEqual(self.order.realized_pnl, Decimal("12"))
        self.assertEqual(older.id in [item["id"] for item in items], True)

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_history_does_not_mix_pre_open_close_trades(self, mock_client_cls, mock_creds):
        created_at = timezone.now() - timedelta(minutes=2)
        closed_at = timezone.now()
        self.order.status = 1
        self.order.created_at = created_at
        self.order.close_price = Decimal("110")
        self.order.closed_at = closed_at
        self.order.close_binance_order_id = ""
        self.order.pnl = Decimal("0")
        self.order.pnl_ratio = Decimal("0")
        self.order.settlement_status = Order.SETTLEMENT_STATUS_PENDING
        self.order.save(
            update_fields=[
                "status",
                "created_at",
                "close_price",
                "closed_at",
                "close_binance_order_id",
                "pnl",
                "pnl_ratio",
                "settlement_status",
            ]
        )

        mock_creds.return_value = object()
        mock_client = MagicMock()
        stale_trade_time = str(int((created_at - timedelta(minutes=1)).timestamp() * 1000))
        close_trade_time = str(int(closed_at.timestamp() * 1000))
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {"ordId": "older-close", "instId": "BTC-USDT-SWAP", "side": "sell", "fillSz": "1", "fillPx": "95", "realizedPnl": "-5", "fee": "0.1", "time": stale_trade_time},
                {"ordId": "current-close", "instId": "BTC-USDT-SWAP", "side": "sell", "fillSz": "1", "fillPx": "110", "realizedPnl": "10", "fee": "0.2", "time": close_trade_time},
            ],
        }
        mock_client.get_bills.return_value = {
            "code": "0",
            "data": [{"instId": "BTC-USDT-SWAP", "type": "REALIZED_PNL", "pnl": "10", "uTime": close_trade_time}],
        }
        mock_client_cls.return_value = mock_client

        resp = self.client.get("/v1/position/history")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        item = resp.data["data"]["items"][0]
        self.assertEqual(item["realized_pnl"], "10.00000000")
        self.assertEqual(item["pnl"], "9.80000000")
        self.order.refresh_from_db()
        self.assertEqual(self.order.realized_pnl, Decimal("10"))
        self.assertEqual(self.order.close_price, Decimal("110"))

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_history_exact_close_order_keeps_earlier_partial_close_legs(self, mock_client_cls, mock_creds):
        closed_at = timezone.now()
        self.order.status = 1
        self.order.close_price = Decimal("115")
        self.order.closed_at = closed_at
        self.order.close_binance_order_id = "close-final"
        self.order.pnl = Decimal("0")
        self.order.pnl_ratio = Decimal("0")
        self.order.settlement_status = Order.SETTLEMENT_STATUS_FAILED
        self.order.save(
            update_fields=[
                "status",
                "close_price",
                "closed_at",
                "close_binance_order_id",
                "pnl",
                "pnl_ratio",
                "settlement_status",
            ]
        )

        mock_creds.return_value = object()
        mock_client = MagicMock()
        partial_ts = str(int((self.order.created_at + timedelta(minutes=5)).timestamp() * 1000))
        final_ts = str(int(closed_at.timestamp() * 1000))
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {"ordId": "tp-partial", "instId": "BTC-USDT-SWAP", "side": "sell", "fillSz": "0.4", "fillPx": "105", "realizedPnl": "4", "fee": "0.1", "time": partial_ts},
                {"ordId": "close-final", "instId": "BTC-USDT-SWAP", "side": "sell", "fillSz": "0.6", "fillPx": "115", "realizedPnl": "9", "fee": "0.2", "time": final_ts},
            ],
        }
        mock_client.get_bills.return_value = {"code": "0", "data": []}
        mock_client_cls.return_value = mock_client

        resp = self.client.get("/v1/position/history")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        item = resp.data["data"]["items"][0]
        self.assertEqual(item["realized_pnl"], "13.00000000")
        self.assertEqual(item["fee"], "-0.30000000")
        self.assertEqual(item["pnl"], "12.70000000")
        self.assertEqual(item["close_price"], "111.00000000")
        self.assertEqual(item["position_amount"], "111.00")

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_history_unsettled_fetches_exchange_rows_only_once_per_order(self, mock_client_cls, mock_creds):
        self.order.status = 1
        self.order.close_price = Decimal("110")
        self.order.closed_at = timezone.now()
        self.order.close_binance_order_id = ""
        self.order.pnl = Decimal("0")
        self.order.pnl_ratio = Decimal("0")
        self.order.settlement_status = Order.SETTLEMENT_STATUS_PENDING
        self.order.save(update_fields=["status", "close_price", "closed_at", "close_binance_order_id", "pnl", "pnl_ratio", "settlement_status"])

        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_user_trades.return_value = {"code": "0", "data": []}
        mock_client.get_bills.return_value = {"code": "0", "data": []}
        mock_client_cls.return_value = mock_client

        resp = self.client.get("/v1/position/history")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(mock_client.get_user_trades.call_count, 1)
        self.assertEqual(mock_client.get_bills.call_count, 1)

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_history_skips_legacy_refresh_outside_private_history_window(
        self, mock_client_cls, mock_creds
    ):
        old_closed_at = timezone.now() - timedelta(days=90)
        self.order.status = 1
        self.order.closed_at = old_closed_at
        self.order.settlement_status = Order.SETTLEMENT_STATUS_SETTLED
        self.order.realized_fee = None
        self.order.realized_funding_fee = None
        self.order.save(
            update_fields=[
                "status",
                "closed_at",
                "settlement_status",
                "realized_fee",
                "realized_funding_fee",
            ]
        )
        mock_creds.return_value = object()

        response = self.client.get("/v1/position/history")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        mock_client_cls.return_value.get_user_trades.assert_not_called()
        mock_client_cls.return_value.get_bills.assert_not_called()

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_history_limits_closed_settlement_repairs_per_request(
        self, mock_client_cls, mock_creds
    ):
        now = timezone.now()
        self.order.status = 1
        self.order.closed_at = now
        self.order.settlement_status = Order.SETTLEMENT_STATUS_PENDING
        self.order.save(update_fields=["status", "closed_at", "settlement_status"])
        for index in range(2):
            Order.objects.create(
                user=self.user,
                binance_order_id=f"settlement-budget-{index}",
                symbol="ETHUSDT",
                side=0,
                open_price=Decimal("100"),
                stop_loss_price=Decimal("90"),
                stop_loss_amount=Decimal("30"),
                size=Decimal("1"),
                leverage=10,
                status=1,
                closed_at=now - timedelta(minutes=index + 1),
                close_price=Decimal("110"),
                settlement_status=Order.SETTLEMENT_STATUS_PENDING,
            )

        mock_creds.return_value = object()
        mock_client = mock_client_cls.return_value
        mock_client.get_user_trades.return_value = {"code": "0", "data": []}
        mock_client.get_bills.return_value = {"code": "0", "data": []}

        response = self.client.get("/v1/position/history")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(mock_client.get_user_trades.call_count, 2)
        self.assertEqual(mock_client.get_bills.call_count, 2)

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_reconcile_pending_settlement_does_not_persist_zero_without_exchange_evidence(self, mock_client_cls, mock_creds):
        self._bind_for_maintenance()
        self.order.status = 1
        self.order.close_price = Decimal("100")
        self.order.closed_at = timezone.now()
        self.order.close_binance_order_id = ""
        self.order.pnl = Decimal("0")
        self.order.pnl_ratio = Decimal("0")
        self.order.settlement_status = Order.SETTLEMENT_STATUS_PENDING
        self.order.save(update_fields=["status", "close_price", "closed_at", "close_binance_order_id", "pnl", "pnl_ratio", "settlement_status"])

        mock_creds.return_value = object()
        mock_client = MagicMock()
        trade_time_ms = str(int(self.order.closed_at.timestamp() * 1000))
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": "other-order",
                    "tradeId": "t1",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "fillSz": "0.1",
                    "realizedPnl": "0",
                    "fee": "0.01",
                    "time": trade_time_ms,
                }
            ],
        }
        mock_client.get_bills.return_value = {"code": "0", "data": []}
        mock_client_cls.return_value = mock_client

        repaired = reconcile_pending_order_settlements(limit=10)
        self.assertEqual(repaired, 0)
        self.order.refresh_from_db()
        self.assertEqual(self.order.settlement_status, Order.SETTLEMENT_STATUS_FAILED)
        self.assertEqual(self.order.settlement_retry_count, 1)
        self.assertIsNotNone(self.order.settlement_next_retry_at)

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_reconcile_pending_settlement_respects_next_retry_at(self, mock_client_cls, mock_creds):
        self._bind_for_maintenance()
        self.order.status = 1
        self.order.closed_at = timezone.now()
        self.order.settlement_status = Order.SETTLEMENT_STATUS_FAILED
        self.order.settlement_retry_count = 2
        self.order.settlement_next_retry_at = timezone.now() + timedelta(minutes=15)
        self.order.save(update_fields=["status", "closed_at", "settlement_status", "settlement_retry_count", "settlement_next_retry_at"])

        repaired = reconcile_pending_order_settlements(limit=10)
        self.assertEqual(repaired, 0)
        mock_creds.assert_not_called()
        mock_client_cls.assert_not_called()

    @patch("positions.views._credentials_for_binding_generation", return_value=object())
    @patch("positions.views.BinanceFuturesClient")
    def test_unmatched_settlement_retry_limit_becomes_estimated(self, mock_client_cls, _mock_creds):
        self._bind_for_maintenance()
        self.order.status = 1
        self.order.close_price = Decimal("110")
        self.order.closed_at = timezone.now()
        self.order.settlement_status = Order.SETTLEMENT_STATUS_FAILED
        self.order.settlement_error = "未匹配到本次平仓成交明细"
        self.order.settlement_retry_count = 24
        self.order.settlement_next_retry_at = timezone.now() - timedelta(seconds=1)
        self.order.save()

        self.assertEqual(reconcile_pending_order_settlements(limit=10), 1)
        self.order.refresh_from_db()
        self.assertEqual(self.order.settlement_status, Order.SETTLEMENT_STATUS_ESTIMATED)
        self.assertIn("估算", self.order.settlement_error)
        mock_client_cls.return_value.get_user_trades.assert_not_called()

    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_history_repairs_unsettled_order_once_and_then_reads_local(self, mock_client_cls, mock_creds):
        self.order.status = 1
        self.order.close_price = Decimal("110")
        self.order.closed_at = timezone.now()
        self.order.close_binance_order_id = ""
        self.order.pnl = Decimal("0")
        self.order.pnl_ratio = Decimal("0")
        self.order.settlement_status = Order.SETTLEMENT_STATUS_PENDING
        self.order.save(update_fields=["status", "close_price", "closed_at", "close_binance_order_id", "pnl", "pnl_ratio", "settlement_status"])

        mock_creds.return_value = object()
        mock_client = MagicMock()
        trade_time_ms = str(int(self.order.closed_at.timestamp() * 1000))
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {"ordId": "another-order", "tradeId": "t1", "instId": "BTC-USDT-SWAP", "side": "sell", "fillSz": "0.4", "realizedPnl": "4.2", "fee": "0.2", "time": trade_time_ms},
                {"ordId": "another-order", "tradeId": "t2", "instId": "BTC-USDT-SWAP", "side": "sell", "fillSz": "0.6", "realizedPnl": "6.8", "fee": "0.3", "time": trade_time_ms},
            ],
        }
        mock_client.get_bills.return_value = {
            "code": "0",
            "data": [
                {"instId": "BTC-USDT-SWAP", "type": "REALIZED_PNL", "pnl": "11", "uTime": trade_time_ms},
                {"instId": "BTC-USDT-SWAP", "type": "COMMISSION", "pnl": "-0.5", "uTime": trade_time_ms},
            ],
        }
        mock_client_cls.return_value = mock_client

        first_resp = self.client.get("/v1/position/history")
        self.assertEqual(first_resp.status_code, status.HTTP_200_OK)
        first_item = first_resp.data["data"]["items"][0]
        self.assertEqual(first_item["pnl"], "10.50000000")
        self.assertEqual(first_item["realized_pnl"], "11.00000000")
        self.assertEqual(first_item["data_source_flags"]["pnl"], "binance_trade")

        self.order.refresh_from_db()
        self.assertEqual(self.order.settlement_status, Order.SETTLEMENT_STATUS_ESTIMATED)
        self.assertEqual(self.order.realized_pnl, Decimal("11"))

        second_resp = self.client.get("/v1/position/history")
        self.assertEqual(second_resp.status_code, status.HTTP_200_OK)
        second_item = second_resp.data["data"]["items"][0]
        self.assertEqual(second_item["pnl"], "10.50000000")
        self.assertEqual(second_item["realized_pnl"], "11.00000000")
        self.assertEqual(second_item["data_source_flags"]["pnl"], "local_estimated_order")
        self.assertEqual(second_item["settlement_status"], "estimated")

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_reconcile_pending_order_settlements_repairs_failed_order(self, mock_client_cls, mock_creds):
        self._bind_for_maintenance()
        self.order.status = 1
        self.order.close_price = Decimal("110")
        self.order.closed_at = timezone.now()
        self.order.close_binance_order_id = "close-1"
        self.order.settlement_status = Order.SETTLEMENT_STATUS_FAILED
        self.order.save(update_fields=["status", "close_price", "closed_at", "close_binance_order_id", "settlement_status"])

        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": self.order.binance_order_id,
                    "instId": "BTC-USDT-SWAP",
                    "side": "buy",
                    "fillSz": "1",
                    "realizedPnl": "0",
                    "fee": "0.1",
                    "time": str(int(self.order.created_at.timestamp() * 1000)),
                },
                {
                    "ordId": "close-1",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "fillSz": "1",
                    "realizedPnl": "11",
                    "fee": "0.3",
                    "time": str(int(self.order.closed_at.timestamp() * 1000)),
                },
            ],
        }
        mock_client.get_bills.return_value = {
            "code": "0",
            "data": [{"instId": "BTC-USDT-SWAP", "type": "REALIZED_PNL", "pnl": "11", "uTime": str(int(self.order.closed_at.timestamp() * 1000))}],
        }
        mock_client_cls.return_value = mock_client

        repaired = reconcile_pending_order_settlements(limit=10)
        self.assertEqual(repaired, 1)
        self.order.refresh_from_db()
        self.assertEqual(self.order.settlement_status, Order.SETTLEMENT_STATUS_SETTLED)
        self.assertEqual(self.order.realized_pnl, Decimal("11"))

    @patch("positions.views._credentials_for_binding_generation", return_value=object())
    @patch("positions.views.BinanceFuturesClient")
    def test_reconcile_pending_settlements_stops_after_rate_limit(
        self, mock_client_cls, _mock_creds
    ):
        self._bind_for_maintenance()
        now = timezone.now()
        for index in range(2):
            Order.objects.create(
                user=self.user,
                binance_order_id=f"rate-limit-settlement-{index}",
                symbol="ETHUSDT",
                side=0,
                open_price=Decimal("100"),
                stop_loss_price=Decimal("90"),
                stop_loss_amount=Decimal("30"),
                size=Decimal("1"),
                leverage=10,
                status=1,
                closed_at=now - timedelta(minutes=index),
                close_price=Decimal("110"),
                settlement_status=Order.SETTLEMENT_STATUS_PENDING,
            )
        self.order.status = 1
        self.order.closed_at = now - timedelta(minutes=3)
        self.order.settlement_status = Order.SETTLEMENT_STATUS_PENDING
        self.order.save(update_fields=["status", "closed_at", "settlement_status"])

        mock_client = mock_client_cls.return_value
        mock_client.get_user_trades.side_effect = BinanceApiError(
            "请求过于频繁",
            code="-1003",
        )

        repaired = reconcile_pending_order_settlements(limit=10)

        self.assertEqual(repaired, 0)
        self.assertEqual(mock_client.get_user_trades.call_count, 1)
        mock_client.get_bills.assert_not_called()

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_audit_suspicious_closed_orders_reports_missing_close_anchor(self, mock_client_cls, mock_creds):
        self._bind_for_maintenance()
        self.order.status = 1
        self.order.created_at = timezone.now() - timedelta(minutes=20)
        self.order.close_price = Decimal("100")
        self.order.closed_at = timezone.now() - timedelta(minutes=10)
        self.order.close_binance_order_id = ""
        self.order.save(update_fields=["status", "created_at", "close_price", "closed_at", "close_binance_order_id"])

        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_user_trades.return_value = {"code": "0", "data": []}
        mock_client.get_bills.return_value = {"code": "0", "data": []}
        mock_client_cls.return_value = mock_client

        with self.assertLogs("positions.views", level="ERROR") as cm:
            alerts = audit_suspicious_closed_orders(limit=10)
        self.assertEqual(alerts, 1)
        self.assertTrue(any("suspicious_closed_order" in line for line in cm.output))

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_audit_suspicious_closed_orders_stops_after_shared_rate_limit(
        self,
        mock_client_cls,
        mock_creds,
    ):
        self._bind_for_maintenance()
        now = timezone.now()
        self.order.status = 1
        self.order.created_at = now - timedelta(minutes=20)
        self.order.close_price = Decimal("100")
        self.order.closed_at = now - timedelta(minutes=10)
        self.order.close_binance_order_id = ""
        self.order.save(
            update_fields=[
                "status",
                "created_at",
                "close_price",
                "closed_at",
                "close_binance_order_id",
            ]
        )
        Order.objects.create(
            user=self.user,
            binance_order_id="rate-limit-audit-2",
            symbol="ETHUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=1,
            close_price=Decimal("110"),
            closed_at=now - timedelta(minutes=11),
        )

        mock_creds.return_value = object()
        mock_client = mock_client_cls.return_value
        mock_client.get_user_trades.side_effect = BinanceApiError(
            "请求过于频繁",
            code="-1003",
        )

        alerts = audit_suspicious_closed_orders(limit=10)

        self.assertEqual(alerts, 0)
        self.assertEqual(mock_client.get_user_trades.call_count, 1)

    @patch("positions.views._credentials_for_binding_generation")
    @patch("positions.views.BinanceFuturesClient")
    def test_audit_suspicious_closed_orders_ignores_when_close_trade_exists(self, mock_client_cls, mock_creds):
        self._bind_for_maintenance()
        self.order.status = 1
        self.order.created_at = timezone.now() - timedelta(minutes=20)
        self.order.close_price = Decimal("110")
        self.order.closed_at = timezone.now() - timedelta(minutes=10)
        self.order.close_binance_order_id = ""
        self.order.save(update_fields=["status", "created_at", "close_price", "closed_at", "close_binance_order_id"])

        mock_creds.return_value = object()
        mock_client = MagicMock()
        close_time_ms = str(int(self.order.closed_at.timestamp() * 1000))
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": "close-ok-1",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "fillSz": "1",
                    "realizedPnl": "10",
                    "fee": "0.3",
                    "time": close_time_ms,
                }
            ],
        }
        mock_client.get_bills.return_value = {"code": "0", "data": []}
        mock_client_cls.return_value = mock_client

        alerts = audit_suspicious_closed_orders(limit=10)
        repeated_alerts = audit_suspicious_closed_orders(limit=10)
        self.assertEqual(alerts, 0)
        self.assertEqual(repeated_alerts, 0)
        self.assertEqual(mock_client.get_user_trades.call_count, 1)

    @patch("positions.views.get_binding_api_key_fingerprint", return_value="fp-current")
    @patch("positions.views.get_user_binding")
    def test_position_history_scopes_orders_by_api_key_fingerprint(self, mock_binding, _mock_fp):
        mock_binding.return_value = SimpleNamespace(
            created_at=timezone.now() - timedelta(hours=1),
            updated_at=timezone.now() + timedelta(hours=1),
        )

        self.order.status = 1
        self.order.close_price = Decimal("110")
        self.order.closed_at = timezone.now()
        self.order.pnl = Decimal("10")
        self.order.pnl_ratio = Decimal("10")
        self.order.api_key_fingerprint = "fp-old"
        self.order.save(
            update_fields=["status", "close_price", "closed_at", "pnl", "pnl_ratio", "api_key_fingerprint"]
        )

        current_order = Order.objects.create(
            user=self.user,
            api_key_fingerprint="fp-current",
            binance_order_id="binance-order-current",
            symbol="ETHUSDT",
            side=0,
            open_price=Decimal("200"),
            stop_loss_price=Decimal("180"),
            stop_loss_amount=Decimal("20"),
            size=Decimal("1"),
            leverage=10,
            status=1,
            close_price=Decimal("210"),
            pnl=Decimal("10"),
            pnl_ratio=Decimal("5"),
            closed_at=timezone.now(),
        )
        legacy_recent = Order.objects.create(
            user=self.user,
            api_key_fingerprint="",
            binance_order_id="binance-order-legacy-recent",
            symbol="BNBUSDT",
            side=0,
            open_price=Decimal("300"),
            stop_loss_price=Decimal("280"),
            stop_loss_amount=Decimal("20"),
            size=Decimal("1"),
            leverage=10,
            status=1,
            close_price=Decimal("315"),
            pnl=Decimal("15"),
            pnl_ratio=Decimal("5"),
            closed_at=timezone.now(),
        )

        resp = self.client.get("/v1/position/history")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        ids = {item["id"] for item in resp.data["data"]["items"]}
        self.assertIn(current_order.id, ids)
        self.assertIn(legacy_recent.id, ids)
        self.assertNotIn(self.order.id, ids)

    @patch("positions.views.get_binding_api_key_fingerprint", return_value="fp-current")
    @patch("positions.views.get_user_binding")
    @patch("positions.views.get_user_binance_credentials")
    @patch("positions.views.BinanceFuturesClient")
    def test_position_list_scopes_orders_by_api_key_fingerprint(self, mock_client_cls, mock_creds, mock_binding, _mock_fp):
        mock_binding.return_value = SimpleNamespace(
            created_at=timezone.now() - timedelta(hours=1),
            updated_at=timezone.now() + timedelta(hours=1),
        )
        mock_creds.return_value = object()

        self.order.api_key_fingerprint = "fp-current"
        self.order.symbol = "BTCUSDT"
        self.order.save(update_fields=["api_key_fingerprint", "symbol"])

        old_order = Order.objects.create(
            user=self.user,
            api_key_fingerprint="fp-old",
            binance_order_id="binance-order-old-active",
            symbol="ETHUSDT",
            side=0,
            open_price=Decimal("200"),
            stop_loss_price=Decimal("180"),
            stop_loss_amount=Decimal("20"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )

        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [
                {"instId": "BTC-USDT-SWAP", "markPx": "110", "avgPx": "100", "upl": "10", "uplRatio": "0.1", "pos": "1", "ctVal": "1"},
                {"instId": "ETH-USDT-SWAP", "markPx": "220", "avgPx": "200", "upl": "20", "uplRatio": "0.1", "pos": "1", "ctVal": "1"},
            ],
        }
        mock_client_cls.return_value = mock_client

        resp = self.client.get("/v1/position/list")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        ids = {item["id"] for item in resp.data["data"]}
        self.assertIn(self.order.id, ids)
        self.assertNotIn(old_order.id, ids)
