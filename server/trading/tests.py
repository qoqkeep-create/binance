from unittest.mock import MagicMock, call, patch

from decimal import Decimal
from datetime import timedelta
from django.core.cache import cache
from django.db import IntegrityError
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase

from api_bindings.context import TradingAccountContext
from positions.cleanup import ClosedOrderCleanupResult
from positions.models import LimitOrder, Order, OrderStrategyLog, OrderStrategySnapshot, TradeNotificationEvent
from trading.constants import ALLOWED_TRADING_SYMBOLS, PINNED_TRADING_SYMBOLS
from trading.services import (
    MANUAL_TP_SL_MANAGEMENT_ERROR,
    _clear_stop_protection_failure,
    _close_fully_offset_order,
    _converge_stop_loss_order,
    _move_stop_loss,
    _process_single_strategy_order,
    _rebuild_take_profit_for_remaining_position,
    _record_stop_protection_retry_failure,
    _retry_exchange_call,
    _stop_protection_retry_due,
    load_shared_open_algo_rows,
    reconcile_open_orders_protection,
    run_strategy_engine,
    setup_strategy_take_profit_orders,
    sync_all_pending_limit_orders,
    sync_limit_order_status,
)
from trading.account_cache import position_cache_key
from trading.models import Strategy, StrategyLevel, TradeOpenRequest
from trading.execution import (
    FILLED,
    PARTIALLY_FILLED,
    PENDING,
    UNKNOWN,
    confirm_entry_execution,
)
from trading.views import (
    _close_local_order_after_exchange_manual_close,
    _emergency_close_position,
    _has_unresolved_stop_protection,
    _resolve_entry_stop_protection,
    _pending_order_increases_risk,
    check_duplicate_order,
    _set_opening_leverage,
)
from trading.opening import (
    ORDER_RECOVERY_RETRY_DELAYS_SECONDS,
    load_exchange_order_by_client_order_id,
    require_exchange_order_row,
    submit_or_recover_exchange_order,
    validate_recovered_exchange_order,
)
from trading.open_requests import build_client_order_id, open_request_payload_matches
from trading.locks import user_trading_activity_lock
from common.binance import BinanceApiError
from common.binance_rate_limit import RequestPriority
from users.models import User


class TradingApiTests(APITestCase):
    def setUp(self):
        cache.clear()
        capital_gate_patcher = patch("trading.views._entry_capital_error", return_value=None)
        self.mock_entry_capital_error = capital_gate_patcher.start()
        self.addCleanup(capital_gate_patcher.stop)
        self.user = User.objects.create_user(email="trade_test@example.com", password="123456")
        entry_account_patcher = patch("trading.views.get_user_trading_account")
        self.mock_entry_account = entry_account_patcher.start()
        self.mock_entry_account.return_value = TradingAccountContext(
            user_id=self.user.id,
            binding_id=0,
            api_key_fingerprint="",
            alias="test",
            binding_created_at=None,
            credentials=object(),
        )
        self.addCleanup(entry_account_patcher.stop)
        login_resp = self.client.post(
            "/v1/auth/login",
            {"email": "trade_test@example.com", "password": "123456", "agreed": True},
            format="json",
        )
        token = login_resp.data["data"]["token"]
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")

    def test_direct_trade_mutations_reject_json_arrays(self):
        for path in (
            "/v1/trade/limit-order/cancel",
            "/v1/trade/limit-order/chase",
            "/v1/strategy/delete",
            "/v1/strategy/set-active",
        ):
            with self.subTest(path=path):
                response = self.client.post(path, [], format="json")
                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertEqual(response.data["message"], "请求参数必须是对象")

    def test_generated_client_order_id_remains_unique_for_long_account_identity(self):
        identity = "account:" + ("x" * 128)

        first = build_client_order_id("market-open", identity, "BTCUSDT", None)
        second = build_client_order_id("market-open", identity, "BTCUSDT", None)

        self.assertNotEqual(first, second)
        self.assertLessEqual(len(first), 36)
        self.assertLessEqual(len(second), 36)

    def test_opening_leverage_only_ignores_already_effective_response(self):
        client = MagicMock()
        client.set_leverage.side_effect = BinanceApiError(
            "Leverage 10 already exists with 10",
            code="-4028",
        )

        _set_opening_leverage(
            client,
            inst_id="BTC-USDT-SWAP",
            leverage=10,
            pos_side="long",
        )

        client.set_leverage.assert_called_once()

    def test_fully_offset_close_classifies_before_cleaning_protection_orders(self):
        order = Order.objects.create(
            user=self.user,
            binance_order_id="fully-offset-order",
            binance_stop_order_id="stop-before-cleanup",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )
        observed = []
        anchor = {
            "closed_at": timezone.now(),
            "close_price": Decimal("90"),
            "close_binance_order_id": "fully-offset-close",
            "is_fully_closed": True,
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
            patch("trading.services._fully_offset_check_due", return_value=True),
            patch("trading.services._load_order_close_trade_rows", return_value=[]),
            patch("trading.services.build_close_anchor_from_trade_rows", return_value=anchor),
            patch(
                "trading.services.infer_exchange_close_notification",
                side_effect=lambda *_args, **_kwargs: observed.append("classify")
                or {
                    "event_type": "stop_loss",
                    "trigger_price": Decimal("90"),
                    "classification_confidence": 3,
                },
            ),
            patch(
                "trading.services.best_effort_cleanup_closed_order_exchange_artifacts",
                side_effect=lambda *_args, **_kwargs: observed.append("cleanup")
                or cleanup_result,
            ),
            patch("positions.lifecycle.enqueue_close_notification"),
        ):
            closed = _close_fully_offset_order(order, MagicMock(), source="test")

        self.assertTrue(closed)
        self.assertEqual(observed, ["classify", "cleanup"])

    def test_fully_offset_close_does_not_clean_protection_when_close_event_insert_fails(self):
        order = Order.objects.create(
            user=self.user,
            binance_order_id="fully-offset-event-failure",
            binance_stop_order_id="stop-must-remain",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )
        anchor = {
            "closed_at": timezone.now(),
            "close_price": Decimal("90"),
            "close_binance_order_id": "fully-offset-close",
            "is_fully_closed": True,
        }

        with (
            patch("trading.services._fully_offset_check_due", return_value=True),
            patch("trading.services._load_order_close_trade_rows", return_value=[]),
            patch("trading.services.build_close_anchor_from_trade_rows", return_value=anchor),
            patch(
                "trading.services.infer_exchange_close_notification",
                return_value={
                    "event_type": TradeNotificationEvent.TYPE_STOP_LOSS,
                    "trigger_price": Decimal("90"),
                    "classification_confidence": 3,
                },
            ),
            patch(
                "positions.lifecycle.enqueue_close_notification",
                side_effect=IntegrityError("event database unavailable"),
            ),
            patch(
                "trading.services.best_effort_cleanup_closed_order_exchange_artifacts"
            ) as cleanup,
        ):
            with self.assertRaises(IntegrityError):
                _close_fully_offset_order(order, MagicMock(), source="test")

        cleanup.assert_not_called()
        order.refresh_from_db()
        self.assertEqual(order.status, 0)
        self.assertEqual(order.binance_stop_order_id, "stop-must-remain")

    def test_only_risk_increasing_exchange_orders_consume_entry_slots(self):
        self.assertFalse(
            _pending_order_increases_risk(
                {"side": "sell", "positionSide": "LONG", "reduceOnly": False}
            )
        )
        self.assertFalse(
            _pending_order_increases_risk(
                {"side": "buy", "positionSide": "BOTH", "reduceOnly": True}
            )
        )
        self.assertTrue(
            _pending_order_increases_risk(
                {"side": "buy", "positionSide": "LONG", "reduceOnly": False}
            )
        )
        self.assertTrue(_pending_order_increases_risk({}))

    def test_unresolved_stop_protection_is_scoped_to_current_api_binding(self):
        binding_created_at = timezone.now() - timedelta(minutes=5)
        Order.objects.create(
            user=self.user,
            api_key_fingerprint="old-fingerprint",
            binance_order_id="old-unprotected-order",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            stop_protection_status=Order.STOP_PROTECTION_PENDING,
        )

        self.assertFalse(
            _has_unresolved_stop_protection(
                self.user,
                api_key_fingerprint="new-fingerprint",
                binding_created_at=binding_created_at,
            )
        )

        Order.objects.create(
            user=self.user,
            api_key_fingerprint="new-fingerprint",
            binance_order_id="new-unprotected-order",
            symbol="ETHUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            stop_protection_status=Order.STOP_PROTECTION_PENDING,
        )

        self.assertTrue(
            _has_unresolved_stop_protection(
                self.user,
                api_key_fingerprint="new-fingerprint",
                binding_created_at=binding_created_at,
            )
        )

    @patch("trading.views.refresh_capital_precheck")
    @patch("trading.views.get_user_binance_credentials", return_value=object())
    def test_capital_precheck_returns_exchange_rate_limit_reason(
        self, _mock_creds, mock_precheck
    ):
        mock_precheck.side_effect = BinanceApiError(
            "Binance 请求过于频繁，系统已暂停查询，请稍后再试",
            code="-1003",
        )

        response = self.client.post(
            "/v1/trade/capital/precheck",
            {"purpose": "manual_sweep"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            response.data["message"],
            "Binance 请求过于频繁，系统已暂停查询，请稍后再试",
        )

    @patch("trading.views.normalize_capital")
    @patch("trading.views.get_user_binance_credentials", return_value=object())
    def test_capital_normalize_returns_exchange_rate_limit_reason(
        self, _mock_creds, mock_normalize
    ):
        mock_normalize.side_effect = BinanceApiError(
            "Binance 请求过于频繁，系统已暂停查询，请稍后再试",
            code="-1003",
        )

        response = self.client.post(
            "/v1/trade/capital/normalize",
            {"expected_status": "normalization_required", "purpose": "manual_sweep"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            response.data["message"],
            "Binance 请求过于频繁，系统已暂停查询，请稍后再试",
        )

    @patch("trading.views.normalize_capital", return_value={"status": "collection_pending", "collection_id": 22})
    @patch("trading.views.get_user_binance_credentials", return_value=object())
    def test_capital_resume_passes_the_explicit_collection_id(self, _mock_creds, normalize):
        response = self.client.post("/v1/trade/capital/normalize", {
            "expected_status": "collection_pending", "purpose": "manual_sweep", "collection_id": 22,
        }, format="json")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(normalize.call_args.kwargs["collection_id"], 22)

    @patch("trading.views.refresh_capital_precheck", return_value={"status": "ready"})
    @patch("trading.views.capital_precheck", return_value={"status": "ready"})
    @patch("trading.views.get_user_binance_credentials", return_value=object())
    def test_entry_precheck_does_not_reconcile_capital_receipts(self, _creds, precheck, refresh):
        response = self.client.post("/v1/trade/capital/precheck", {"purpose": "entry"}, format="json")
        self.assertEqual(response.status_code, 200)
        precheck.assert_called_once()
        refresh.assert_not_called()

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views.get_user_binance_credentials", return_value=object())
    def test_market_open_enforces_capital_gate_before_exchange_write(
        self,
        _mock_creds,
        mock_client_cls,
    ):
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {"data": []}
        mock_client.get_pending_orders.return_value = {"data": []}
        mock_client.get_pending_algo_orders.return_value = {"data": []}
        mock_client_cls.return_value = mock_client
        self.mock_entry_capital_error.return_value = "请先处理账户资金"

        response = self.client.post(
            "/v1/trade/open",
            {
                "symbol": "BTCUSDT",
                "stop_loss_price": "90",
                "stop_loss_amount": "30",
                "include_fee": True,
                "ema_check_id": "not-reached",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["message"], "请先处理账户资金")
        self.mock_entry_capital_error.assert_called_once()
        self.assertEqual(self.mock_entry_capital_error.call_args.kwargs["purpose"], "entry")
        mock_client.place_market_order.assert_not_called()

    @patch("trading.entry_guard.get_user_binding_generation", return_value=("changed", None))
    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views.get_user_binance_credentials", return_value=object())
    def test_market_open_rejects_binding_change_before_creating_exchange_client(
        self,
        _mock_creds,
        mock_client_cls,
        _mock_binding_generation,
    ):
        response = self.client.post(
            "/v1/trade/open",
            {
                "symbol": "BTCUSDT",
                "stop_loss_price": "90",
                "stop_loss_amount": "30",
                "include_fee": True,
                "ema_check_id": "not-reached",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["message"], "API 绑定已发生变化，请刷新后重试")
        mock_client_cls.assert_not_called()

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views.get_user_binance_credentials", return_value=object())
    def test_limit_open_enforces_capital_gate_before_exchange_write(
        self,
        _mock_creds,
        mock_client_cls,
    ):
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {"data": []}
        mock_client.get_pending_orders.return_value = {"data": []}
        mock_client.get_pending_algo_orders.return_value = {"data": []}
        mock_client_cls.return_value = mock_client
        self.mock_entry_capital_error.return_value = "请先处理账户资金"

        response = self.client.post(
            "/v1/trade/limit-order/create",
            {
                "symbol": "BTCUSDT",
                "limit_price": "100",
                "stop_loss_price": "90",
                "stop_loss_amount": "30",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["message"], "请先处理账户资金")
        self.mock_entry_capital_error.assert_called_once()
        self.assertEqual(self.mock_entry_capital_error.call_args.kwargs["purpose"], "entry")
        mock_client.place_limit_order.assert_not_called()

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views.get_user_binance_credentials", return_value=object())
    def test_limit_chase_enforces_capital_gate_before_cancel(
        self,
        _mock_creds,
        mock_client_cls,
    ):
        limit_order = self._create_limit_order_for_chase(order_id="capital-gated-chase")
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {"data": []}
        mock_client.get_pending_orders.return_value = {"data": []}
        mock_client.get_pending_algo_orders.return_value = {"data": []}
        mock_client_cls.return_value = mock_client
        self.mock_entry_capital_error.return_value = "请先处理账户资金"

        response = self.client.post(
            "/v1/trade/limit-order/chase",
            {"limit_order_id": limit_order.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["message"], "请先处理账户资金")
        self.mock_entry_capital_error.assert_called_once()
        self.assertEqual(self.mock_entry_capital_error.call_args.kwargs["purpose"], "chase")
        mock_client.cancel_order.assert_not_called()
        mock_client.place_market_order.assert_not_called()

    def test_stop_protection_retry_alerts_without_closing_order(self):
        order = Order.objects.create(
            user=self.user,
            binance_order_id="stop-alert-state",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            exchange_size=Decimal("1.5"),
            has_manual_addition=True,
            leverage=10,
            status=0,
            stop_protection_status=Order.STOP_PROTECTION_PENDING,
        )

        for attempt in range(1, 4):
            _record_stop_protection_retry_failure(order, "temporary network failure")
            order.refresh_from_db()
            self.assertEqual(order.stop_protection_retry_count, attempt)

        self.assertEqual(order.status, 0)
        self.assertEqual(order.stop_protection_status, Order.STOP_PROTECTION_ALERTED)
        self.assertIsNotNone(order.stop_protection_first_failed_at)
        self.assertIsNotNone(order.stop_protection_alerted_at)

        _clear_stop_protection_failure(order)
        order.refresh_from_db()
        self.assertEqual(order.stop_protection_status, Order.STOP_PROTECTION_COMPLETE)
        self.assertEqual(order.stop_protection_retry_count, 0)
        self.assertIsNone(order.stop_protection_first_failed_at)
        self.assertIsNone(order.stop_protection_last_retry_at)
        self.assertIsNone(order.stop_protection_alerted_at)

    def test_stop_protection_retry_uses_fast_then_bounded_backoff(self):
        now = timezone.now()
        order = Order(
            stop_protection_last_retry_at=now,
            stop_protection_retry_count=1,
        )
        self.assertFalse(_stop_protection_retry_due(order, now=now + timedelta(seconds=9)))
        self.assertTrue(_stop_protection_retry_due(order, now=now + timedelta(seconds=10)))

        order.stop_protection_retry_count = 3
        self.assertFalse(_stop_protection_retry_due(order, now=now + timedelta(seconds=29)))
        self.assertTrue(_stop_protection_retry_due(order, now=now + timedelta(seconds=30)))

        order.stop_protection_retry_count = 99
        self.assertFalse(_stop_protection_retry_due(order, now=now + timedelta(seconds=599)))
        self.assertTrue(_stop_protection_retry_due(order, now=now + timedelta(seconds=600)))

    def test_shared_open_algo_snapshot_queries_each_symbol_once(self):
        client = MagicMock()

        def load_rows(*, inst_id, **_kwargs):
            return {"code": "0", "data": [{"algoId": inst_id, "instId": inst_id}]}

        client.get_pending_algo_orders.side_effect = load_rows

        first = load_shared_open_algo_rows(
            client,
            self.user.id,
            ["ETH-USDT-SWAP", "BTCUSDT", "BTC-USDT-SWAP"],
        )
        second = load_shared_open_algo_rows(
            client,
            self.user.id,
            ["BTC-USDT-SWAP", "ETHUSDT"],
        )

        self.assertEqual([row["instId"] for row in first], ["BTC-USDT-SWAP", "ETH-USDT-SWAP"])
        self.assertEqual(second, first)
        self.assertEqual(client.get_pending_algo_orders.call_count, 2)
        self.assertEqual(
            [item.kwargs["inst_id"] for item in client.get_pending_algo_orders.call_args_list],
            ["BTC-USDT-SWAP", "ETH-USDT-SWAP"],
        )

    def test_shared_open_algo_snapshot_does_not_use_expired_rows_after_query_failure(self):
        cache.set(
            position_cache_key("open_algo_rows", self.user.id),
            {
                "entries": {
                    "BTC-USDT-SWAP": {
                        "loaded_at": 0,
                        "rows": [{"algoId": "stale-stop", "instId": "BTC-USDT-SWAP"}],
                    }
                }
            },
            timeout=60,
        )
        client = MagicMock()
        client.get_pending_algo_orders.side_effect = BinanceApiError("权限不足", code="-2015")

        with self.assertRaises(BinanceApiError):
            load_shared_open_algo_rows(client, self.user.id, ["BTC-USDT-SWAP"])

        self.assertEqual(client.get_pending_algo_orders.call_count, 1)

    def test_shared_open_algo_snapshot_is_isolated_by_api_key_identity(self):
        client = MagicMock()
        client.get_pending_algo_orders.side_effect = [
            {"code": "0", "data": [{"algoId": "old-key"}]},
            {"code": "0", "data": [{"algoId": "new-key"}]},
        ]

        old_rows = load_shared_open_algo_rows(
            client,
            "api-key:old-fingerprint",
            ["BTC-USDT-SWAP"],
        )
        new_rows = load_shared_open_algo_rows(
            client,
            "api-key:new-fingerprint",
            ["BTC-USDT-SWAP"],
        )

        self.assertEqual(old_rows, [{"algoId": "old-key"}])
        self.assertEqual(new_rows, [{"algoId": "new-key"}])
        self.assertEqual(client.get_pending_algo_orders.call_count, 2)

    def _create_strategy(self, name: str = "稳健通用") -> Strategy:
        strategy = Strategy.objects.create(user=self.user, name=name, is_active=True)
        StrategyLevel.objects.create(
            strategy=strategy,
            sort_order=1,
            profit_rr=Decimal("1.5"),
            reduce_position=Decimal("40"),
            stop_loss_type=StrategyLevel.STOP_LOSS_TYPE_FIXED_RR,
            stop_loss_rr=Decimal("1.5"),
        )
        StrategyLevel.objects.create(
            strategy=strategy,
            sort_order=2,
            profit_rr=Decimal("2.0"),
            reduce_position=Decimal("30"),
            stop_loss_type=StrategyLevel.STOP_LOSS_TYPE_FIXED_RR,
            stop_loss_rr=Decimal("1"),
        )
        return strategy

    def _create_limit_order_for_chase(self, *, order_id: str = "limit-chase-source") -> LimitOrder:
        return LimitOrder.objects.create(
            user=self.user,
            binance_order_id=order_id,
            symbol="BTCUSDT",
            side=0,
            limit_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("3"),
            leverage=10,
            status=LimitOrder.STATUS_PENDING,
        )

    @patch("trading.execution.time.sleep")
    @patch("trading.views.get_user_binance_credentials")
    @patch("trading.views.BinanceFuturesClient")
    def test_limit_cancel_keeps_pending_until_exchange_returns_terminal_state(
        self,
        mock_client_cls,
        mock_creds,
        _mock_sleep,
    ):
        limit_order = self._create_limit_order_for_chase(order_id="cancel-still-live")
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.cancel_order.return_value = {"code": "0", "data": []}
        mock_client.get_order.return_value = {
            "code": "0",
            "data": [{"ordId": limit_order.binance_order_id, "state": "new", "fillSz": "0", "avgPx": "0"}],
        }
        mock_client_cls.return_value = mock_client

        response = self.client.post(
            "/v1/trade/limit-order/cancel",
            {"limit_order_id": limit_order.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        limit_order.refresh_from_db()
        self.assertEqual(limit_order.status, LimitOrder.STATUS_PENDING)

    @patch("trading.views.get_user_binance_credentials")
    @patch("trading.views.BinanceFuturesClient")
    def test_limit_cancel_recovers_lost_response_from_exchange_terminal_state(
        self,
        mock_client_cls,
        mock_creds,
    ):
        limit_order = self._create_limit_order_for_chase(order_id="cancel-response-lost")
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.cancel_order.side_effect = BinanceApiError(
            "请求超时",
            code="-1007",
            outcome_unknown=True,
        )
        mock_client.get_order.return_value = {
            "code": "0",
            "data": [{"ordId": limit_order.binance_order_id, "state": "canceled", "fillSz": "0", "avgPx": "0"}],
        }
        mock_client_cls.return_value = mock_client

        response = self.client.post(
            "/v1/trade/limit-order/cancel",
            {"limit_order_id": limit_order.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        limit_order.refresh_from_db()
        self.assertEqual(limit_order.status, LimitOrder.STATUS_CANCELLED)

    @patch("trading.views.get_user_binance_credentials")
    @patch("trading.views.BinanceFuturesClient")
    def test_limit_cancel_rate_limited_confirmation_returns_business_error(
        self,
        mock_client_cls,
        mock_creds,
    ):
        limit_order = self._create_limit_order_for_chase(order_id="cancel-confirm-rate-limit")
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.cancel_order.return_value = {"code": "0", "data": []}
        mock_client.get_order.side_effect = BinanceApiError(
            "Binance 请求预算保护中",
            code="LOCAL_RATE_BUDGET",
        )
        mock_client_cls.return_value = mock_client

        response = self.client.post(
            "/v1/trade/limit-order/cancel",
            {"limit_order_id": limit_order.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("本地委托保持待确认", response.data["message"])
        limit_order.refresh_from_db()
        self.assertEqual(limit_order.status, LimitOrder.STATUS_PENDING)

    @patch("trading.views.get_user_binance_credentials")
    @patch("trading.views.BinanceFuturesClient")
    def test_limit_cancel_returns_definitive_rejection_without_querying(
        self,
        mock_client_cls,
        mock_creds,
    ):
        limit_order = self._create_limit_order_for_chase(order_id="cancel-rejected")
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.cancel_order.side_effect = BinanceApiError("权限不足", code="-2015")
        mock_client_cls.return_value = mock_client

        response = self.client.post(
            "/v1/trade/limit-order/cancel",
            {"limit_order_id": limit_order.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("权限不足", response.data["message"])
        limit_order.refresh_from_db()
        self.assertEqual(limit_order.status, LimitOrder.STATUS_PENDING)
        mock_client.get_order.assert_not_called()

    def test_open_request_idempotency_rejects_different_payload(self):
        request_row = TradeOpenRequest.objects.create(
            user=self.user,
            symbol="BTCUSDT",
            client_request_id="11111111-1111-4111-8111-111111111111",
            client_order_id="rtmo-idempotency-test",
            request_payload={"symbol": "BTCUSDT", "stop_loss_price": "90"},
        )
        self.assertTrue(
            open_request_payload_matches(
                request_row,
                {"symbol": "BTCUSDT", "stop_loss_price": "90"},
            )
        )
        self.assertFalse(
            open_request_payload_matches(
                request_row,
                {"symbol": "BTCUSDT", "stop_loss_price": "91"},
            )
        )

    def test_entry_execution_uses_exchange_accumulated_fill_only(self):
        client = MagicMock()
        result = confirm_entry_execution(
            client,
            inst_id="BTC-USDT-SWAP",
            order_id="partial-1",
            requested_size=Decimal("3"),
            initial_row={
                "ordId": "partial-1",
                "state": "partially_filled",
                "fillSz": "0.5",
                "accFillSz": "1.25",
                "avgPx": "100.2",
            },
        )
        self.assertEqual(result.state, PARTIALLY_FILLED)
        self.assertEqual(result.filled_size, Decimal("1.25"))
        self.assertEqual(result.average_price, Decimal("100.2"))
        client.get_order.assert_not_called()

    def test_entry_execution_reports_pending_without_fabricating_fill(self):
        client = MagicMock()
        client.get_order.return_value = {
            "data": [{"ordId": "pending-1", "state": "new", "fillSz": "0", "avgPx": "0"}],
        }
        result = confirm_entry_execution(
            client,
            inst_id="BTC-USDT-SWAP",
            order_id="pending-1",
            requested_size=Decimal("3"),
            retry_delays=(0,),
        )
        self.assertEqual(result.state, PENDING)
        self.assertFalse(result.has_fill)
        self.assertEqual(result.filled_size, Decimal("0"))

    def test_entry_execution_reports_unknown_when_queries_fail(self):
        client = MagicMock()
        client.get_order.side_effect = BinanceApiError("temporary network failure")
        result = confirm_entry_execution(
            client,
            inst_id="BTC-USDT-SWAP",
            order_id="unknown-1",
            requested_size=Decimal("3"),
            retry_delays=(0, 0),
        )
        self.assertEqual(result.state, UNKNOWN)
        self.assertFalse(result.has_fill)

    def test_entry_execution_stops_immediately_on_shared_rate_limit(self):
        client = MagicMock()
        rate_limit = BinanceApiError(
            "request budget unavailable",
            code="LOCAL_RATE_BUDGET",
        )
        client.get_order.side_effect = rate_limit

        with self.assertRaises(BinanceApiError) as raised:
            confirm_entry_execution(
                client,
                inst_id="BTC-USDT-SWAP",
                order_id="rate-limited-1",
                requested_size=Decimal("3"),
                retry_delays=(0, 0, 0),
            )

        self.assertIs(raised.exception, rate_limit)
        client.get_order.assert_called_once()

    def test_recovered_limit_order_must_match_persisted_execution_intent(self):
        intent = {
            "entry_price": "100",
            "open_side": "buy",
            "size": "3",
            "pos_side": "long",
        }
        validate_recovered_exchange_order(
            {"side": "buy", "sz": "3", "posSide": "long", "px": "100"},
            intent,
            action_label="限价委托",
            require_limit_price=True,
        )

        for row in (
            {"side": "sell", "sz": "3", "posSide": "long", "px": "100"},
            {"side": "buy", "sz": "4", "posSide": "long", "px": "100"},
            {"side": "buy", "sz": "3", "posSide": "long", "px": "101"},
        ):
            with self.subTest(row=row), self.assertRaises(BinanceApiError):
                validate_recovered_exchange_order(
                    row,
                    intent,
                    action_label="限价委托",
                    require_limit_price=True,
                )

    def test_order_recovery_stops_immediately_on_local_cooldown(self):
        client = MagicMock()
        client.get_order.side_effect = BinanceApiError(
            "币安限频保护中",
            code="LOCAL_RATE_COOLDOWN",
        )

        row = load_exchange_order_by_client_order_id(
            client,
            inst_id="BTC-USDT-SWAP",
            client_order_id="cooldown-order",
        )

        self.assertIsNone(row)
        client.get_order.assert_called_once()

    def test_entry_execution_treats_requested_quantity_as_filled_only_after_exchange_confirmation(self):
        client = MagicMock()
        client.get_order.return_value = {
            "data": [{"ordId": "filled-1", "state": "partially_filled", "accFillSz": "3", "avgPx": "100"}],
        }
        result = confirm_entry_execution(
            client,
            inst_id="BTC-USDT-SWAP",
            order_id="filled-1",
            requested_size=Decimal("3"),
            retry_delays=(0,),
        )
        self.assertEqual(result.state, FILLED)

    def test_order_write_envelope_requires_exchange_order_id(self):
        with self.assertRaisesMessage(BinanceApiError, "开仓结果未确认，未获取到订单号") as raised:
            require_exchange_order_row({"data": [{"sCode": "0"}]}, action_label="开仓")
        self.assertTrue(raised.exception.outcome_unknown)

    @patch("trading.opening.load_exchange_order_by_client_order_id")
    def test_malformed_successful_order_response_recovers_by_client_order_id(self, mock_load):
        open_request = TradeOpenRequest.objects.create(
            user=self.user,
            symbol="BTCUSDT",
            client_request_id="malformed-response",
            client_order_id="rtmalformedresponse",
        )
        mock_load.return_value = {"ordId": "recovered-order-1", "state": "filled"}

        submission = submit_or_recover_exchange_order(
            client=MagicMock(),
            open_request=open_request,
            inst_id="BTC-USDT-SWAP",
            client_order_id=open_request.client_order_id,
            submit=lambda: {"code": "0", "data": [{"sCode": "0"}]},
        )

        self.assertTrue(submission.confirmed)
        self.assertEqual(submission.payload["data"][0]["ordId"], "recovered-order-1")
        open_request.refresh_from_db()
        self.assertEqual(open_request.status, TradeOpenRequest.STATUS_RECOVERED)
        self.assertEqual(open_request.binance_order_id, "recovered-order-1")

    @patch("trading.opening.load_exchange_order_by_client_order_id", return_value=None)
    def test_malformed_successful_order_response_stays_recoverable(self, _mock_load):
        open_request = TradeOpenRequest.objects.create(
            user=self.user,
            symbol="BTCUSDT",
            client_request_id="malformed-pending",
            client_order_id="rtmalformedpending",
        )

        submission = submit_or_recover_exchange_order(
            client=MagicMock(),
            open_request=open_request,
            inst_id="BTC-USDT-SWAP",
            client_order_id=open_request.client_order_id,
            submit=lambda: {"code": "0", "data": []},
        )

        self.assertFalse(submission.confirmed)
        open_request.refresh_from_db()
        self.assertEqual(open_request.status, TradeOpenRequest.STATUS_PENDING)
        self.assertIn("结果未确认", open_request.error)

    @patch("trading.views._resolve_pos_side", return_value="long")
    def test_emergency_close_requires_exchange_position_confirmation(self, _mock_pos_side):
        client = MagicMock()
        close_payload = {
            "data": [
                {
                    "ordId": "emergency-close-1",
                    "avgPx": "89.5",
                    "state": "filled",
                    "sCode": "0",
                }
            ]
        }
        client.close_position.return_value = close_payload
        client.get_positions.return_value = {"data": []}
        confirmed, receipt = _emergency_close_position(client, "BTC-USDT-SWAP", 0)

        self.assertTrue(confirmed)
        self.assertEqual(receipt, close_payload)
        client.close_position.assert_called_once()
        self.assertEqual(client.get_positions.call_count, 2)
        client.get_positions.assert_called_with(
            "SWAP",
            "BTC-USDT-SWAP",
            budget_priority=RequestPriority.CRITICAL,
        )

    @patch("trading.views._resolve_pos_side", return_value="long")
    def test_emergency_close_recovers_when_submit_response_is_lost(self, _mock_pos_side):
        client = MagicMock()
        client.close_position.side_effect = BinanceApiError(
            "请求超时",
            code="-1007",
            outcome_unknown=True,
        )
        client.get_positions.return_value = {"data": []}

        confirmed, receipt = _emergency_close_position(client, "BTC-USDT-SWAP", 0)

        self.assertTrue(confirmed)
        self.assertIsNone(receipt)
        client.close_position.assert_called_once()

    @patch("trading.views._emergency_close_position", return_value=(False, None))
    @patch("trading.views._should_emergency_close_after_stop_loss_fail", return_value=True)
    def test_entry_stop_protection_marks_emergency_when_close_is_not_confirmed(
        self,
        _mock_should_close,
        _mock_close,
    ):
        order = Order.objects.create(
            user=self.user,
            binance_order_id="chase-emergency-unconfirmed",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            stop_protection_status=Order.STOP_PROTECTION_PENDING,
        )

        _, response_error = _resolve_entry_stop_protection(
            order=order,
            client=MagicMock(),
            inst_id="BTC-USDT-SWAP",
            side_code=0,
            stop_loss_price=Decimal("90"),
            stop_loss_error=BinanceApiError("stop create failed"),
            action_label="追单开仓",
            pending_message="追单已成交，止损保护正在后台重试；恢复前不可继续开仓",
        )

        order.refresh_from_db()
        self.assertEqual(order.stop_protection_status, Order.STOP_PROTECTION_EMERGENCY)
        self.assertIn("紧急平仓未确认", order.stop_protection_error)
        self.assertIn("追单开仓后", response_error)

    @patch("trading.views._mark_order_closed_after_emergency")
    @patch("trading.views._emergency_close_position")
    @patch("trading.views._should_emergency_close_after_stop_loss_fail", return_value=True)
    def test_entry_emergency_close_keeps_exchange_receipt_for_settlement(
        self,
        _mock_should_close,
        mock_close,
        mock_mark_closed,
    ):
        order = Order.objects.create(
            user=self.user,
            binance_order_id="entry-emergency-receipt",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            stop_protection_status=Order.STOP_PROTECTION_PENDING,
        )
        close_payload = {
            "data": [{"ordId": "emergency-close-2", "avgPx": "89.25", "state": "filled"}]
        }
        mock_close.return_value = (True, close_payload)
        client = MagicMock()

        _, response_error = _resolve_entry_stop_protection(
            order=order,
            client=client,
            inst_id="BTC-USDT-SWAP",
            side_code=0,
            stop_loss_price=Decimal("90"),
            stop_loss_error=BinanceApiError("stop create failed"),
            action_label="开仓",
            pending_message="开仓已成交，止损保护正在后台重试",
        )

        mock_mark_closed.assert_called_once_with(order, client, close_payload=close_payload)
        self.assertIn("系统已自动平仓保护", response_error)

    @patch("trading.views.fetch_close_anchor")
    def test_duplicate_check_does_not_close_local_order_after_one_empty_position_read(
        self,
        mock_fetch_close_anchor,
    ):
        order = Order.objects.create(
            user=self.user,
            binance_order_id="transient-empty-position",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )
        client = MagicMock()
        client.get_positions.side_effect = [
            {"data": []},
            {"data": [{"instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "1"}]},
        ]

        error = check_duplicate_order(self.user, "BTCUSDT", client=client)

        self.assertIn("已有持仓", error)
        order.refresh_from_db()
        self.assertEqual(order.status, 0)
        mock_fetch_close_anchor.assert_not_called()

    @patch(
        "positions.cleanup.cleanup_closed_order_exchange_artifacts",
        side_effect=RuntimeError("cleanup crashed"),
    )
    @patch("trading.views.time.sleep", return_value=None)
    @patch("trading.views.fetch_close_anchor")
    def test_duplicate_check_close_persists_and_enqueues_one_notification_when_cleanup_fails(
        self,
        mock_fetch_close_anchor,
        _mock_sleep,
        _mock_cleanup,
    ):
        order = Order.objects.create(
            user=self.user,
            binance_order_id="manual-close-recovery",
            binance_stop_order_id="residual-stop",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )
        client = MagicMock()
        client.get_positions.return_value = {"data": []}
        mock_fetch_close_anchor.return_value = {
            "closed_at": timezone.now(),
            "close_price": Decimal("101.2"),
            "close_binance_order_id": "manual-close-fill",
            "is_fully_closed": True,
        }

        with self.captureOnCommitCallbacks(execute=True):
            self.assertTrue(_close_local_order_after_exchange_manual_close(order, client))
            self.assertFalse(_close_local_order_after_exchange_manual_close(order, client))

        order.refresh_from_db()
        self.assertEqual(order.status, 1)
        self.assertEqual(order.close_binance_order_id, "manual-close-fill")
        self.assertEqual(order.binance_stop_order_id, "residual-stop")
        self.assertEqual(order.exchange_size, Decimal("0"))
        self.assertFalse(order.has_manual_addition)
        events = TradeNotificationEvent.objects.filter(
            event_key=f"trade:close:{order.id}",
        )
        self.assertEqual(events.count(), 1)
        self.assertEqual(events.get().event_type, TradeNotificationEvent.TYPE_MANUAL_TAKE_PROFIT)

    def test_symbols_returns_list(self):
        resp = self.client.get("/v1/trade/symbols")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"], ALLOWED_TRADING_SYMBOLS)
        for symbol in PINNED_TRADING_SYMBOLS:
            self.assertIn(symbol, resp.data["data"])

    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    def test_symbol_info(self, mock_inst, mock_ticker):
        mock_ticker.return_value = {"last": "123.4"}
        mock_inst.return_value = {"lever": "75"}
        resp = self.client.get("/v1/trade/symbol/info?symbol=BTCUSDT")
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["data"]["current_price"], "123.4")
        self.assertEqual(resp.data["data"]["max_leverage"], 75)

    def test_retired_ema_check_route_is_not_available(self):
        from django.urls import Resolver404, resolve
        with self.assertRaises(Resolver404):
            resolve("/v1/trade/ema-check")

    @patch("trading.views.binance_get_candles", side_effect=AssertionError("entry must not read klines"))
    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker", return_value={"last": "100.125"})
    @patch("trading.views._extract_instrument", return_value={"ctVal": "0.01", "lotSz": "1"})
    def test_market_open_ignores_legacy_ema_values_and_keeps_capital_decimal_boundary(
        self, instrument, _ticker, factory, candles,
    ):
        exchange = factory.return_value
        exchange.get_positions.return_value = {"data": []}
        exchange.get_pending_orders.return_value = {"data": []}
        exchange.get_pending_algo_orders.return_value = {"data": []}
        cache.set(f"trade:ema-check:{self.user.id}:expired-check", {
            "symbol": "ETHUSDT", "side": "short", "stop_loss_price": "999",
            "has_any_supported_interval": False, "has_any_matching_interval": False,
            "expires_at_ts": timezone.now().timestamp() - 5,
        }, timeout=180)
        body = {"symbol": "BTCUSDT", "stop_loss_price": "90.12345678",
            "stop_loss_amount": "30.001", "include_fee": False}
        for legacy, expected_legacy in (({}, ""), ({"ema_check_id": "expired-check"}, "expired-check"),
                ({"ema_check_id": "arbitrary-check"}, "arbitrary-check"), ({"ema_check_id": ""}, ""),
                ({"ema_check_id": None}, ""), ({"ema_check_id": {"retired": True}}, "{'retired': True}"),
                ({"ema_check_id": "  legacy-id  "}, "legacy-id"), ({"ema_check_id": 0}, "0"),
                ({"ema_check_id": 0.0}, "0.0")):
            with self.subTest(legacy=legacy):
                self.mock_entry_capital_error.reset_mock()
                sequence = []
                self.mock_entry_capital_error.side_effect = lambda *_args, **_kwargs: sequence.append("capital")

                def reached_calculation(**kwargs):
                    sequence.append("calculation")
                    self.assertEqual(kwargs["entry_price"], Decimal("100.125"))
                    self.assertEqual(kwargs["stop_loss_price"], Decimal("90.12345678"))
                    self.assertEqual(kwargs["stop_loss_amount"], Decimal("30.001"))
                    self.assertEqual(kwargs["instrument"], instrument.return_value)
                    raise BinanceApiError("reached original entry calculation")

                with patch("trading.views.standardize_open_order_request", side_effect=reached_calculation):
                    response = self.client.post("/v1/trade/open", {**body, **legacy}, format="json")
                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST, response.data)
                self.assertEqual(response.data["message"], "reached original entry calculation")
                self.assertEqual(sequence, ["capital", "calculation"])
                self.mock_entry_capital_error.assert_called_once()
                self.assertEqual(self.mock_entry_capital_error.call_args.kwargs["purpose"], "entry")
                self.assertEqual(TradeOpenRequest.objects.order_by("-id").first().request_payload["ema_check_id"],
                    expected_legacy)
        candles.assert_not_called()
        exchange.set_leverage.assert_not_called()
        exchange.place_market_order.assert_not_called()

    @patch("trading.views.binance_get_candles", side_effect=AssertionError("entry must not read klines"))
    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker", return_value={"last": "100"})
    @patch("trading.views._extract_instrument", return_value={"ctVal": "0.01", "lotSz": "1"})
    def test_market_open_without_ema_uses_existing_execution_and_stable_request_identity(
        self, _instrument, _ticker, factory, candles,
    ):
        exchange = factory.return_value
        exchange.get_account_config.return_value = {"data": [{"posMode": "long_short_mode"}]}
        exchange.get_positions.return_value = {"data": []}
        exchange.get_pending_orders.return_value = {"data": []}
        exchange.get_pending_algo_orders.return_value = {"data": []}
        exchange.place_market_order.return_value = {"data": [{"ordId": "direct-open"}]}
        exchange.get_order.return_value = {"data": [{"state": "filled", "fillSz": "3", "avgPx": "100.1"}]}
        exchange.place_stop_market_order.return_value = {"data": [{"algoId": "direct-stop"}]}
        body = {"symbol": "BTCUSDT", "stop_loss_price": "90", "stop_loss_amount": "30",
            "include_fee": False, "client_request_id": "77777777-7777-4777-8777-777777777777"}
        first = self.client.post("/v1/trade/open", body, format="json")
        second = self.client.post("/v1/trade/open", body, format="json")
        self.assertEqual(first.status_code, status.HTTP_200_OK, first.data)
        self.assertEqual(second.status_code, status.HTTP_200_OK, second.data)
        self.assertEqual(first.data["data"]["position_id"], second.data["data"]["position_id"])
        self.assertEqual(exchange.place_market_order.call_count, 1)
        record = TradeOpenRequest.objects.get(client_request_id=body["client_request_id"])
        self.assertEqual(record.request_payload["ema_check_id"], "")
        # The retired field keeps its old fingerprint role. Changing an old
        # caller field must not turn one persisted request into a second order.
        conflict = self.client.post("/v1/trade/open", {**body, "ema_check_id": "legacy-token"}, format="json")
        self.assertEqual(conflict.status_code, status.HTTP_409_CONFLICT, conflict.data)
        self.assertEqual(exchange.place_market_order.call_count, 1)
        self.assertEqual(Order.objects.get(pk=first.data["data"]["position_id"]).exchange_size, Decimal("3"))
        self.mock_entry_capital_error.assert_called_once()
        candles.assert_not_called()

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    @patch("trading.views.get_user_binance_credentials")
    def test_trade_open_creates_order(
        self,
        mock_creds,
        mock_inst,
        mock_ticker,
        mock_client_cls,
    ):
        mock_creds.return_value = object()
        mock_ticker.return_value = {"last": "100"}
        mock_inst.return_value = {"ctVal": "0.01", "lotSz": "1"}

        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.place_market_order.return_value = {"code": "0", "data": [{"ordId": "12345"}]}
        mock_client.get_order.return_value = {"code": "0", "data": [{"state": "filled", "fillSz": "3", "avgPx": "100.1"}]}
        mock_client.place_stop_loss_order.return_value = {"code": "0", "data": [{"algoId": "999"}]}
        mock_client.place_stop_market_order.return_value = {"code": "0", "data": [{"algoId": "999m"}]}
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": [{"algoId": "999", "sz": "3"}]}
        mock_client_cls.return_value = mock_client

        resp = self.client.post(
            "/v1/trade/open",
            {
                "symbol": "BTCUSDT",
                "stop_loss_price": "90",
                "stop_loss_amount": "30",
                "include_fee": True,
                "ema_check_id": "ema-1",
            },
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertTrue(Order.objects.filter(user=self.user, binance_order_id="12345").exists())

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker", return_value={"last": "100"})
    @patch(
        "trading.views._extract_instrument",
        return_value={"ctVal": "0.01", "lotSz": "1", "lever": "10"},
    )
    @patch("trading.views.get_user_binance_credentials", return_value=object())
    def test_market_open_stops_when_leverage_setting_hits_shared_rate_limit(
        self,
        _mock_creds,
        _mock_inst,
        _mock_ticker,
        mock_client_cls,
    ):
        mock_client = mock_client_cls.return_value
        mock_client.get_positions.return_value = {"data": []}
        mock_client.get_pending_orders.return_value = {"data": []}
        mock_client.get_pending_algo_orders.return_value = {"data": []}
        mock_client.get_account_config.return_value = {
            "data": [{"posMode": "long_short_mode"}]
        }
        mock_client.get_leverage_bracket.return_value = {
            "data": [{"maxLever": "10", "notionalCap": "1000000"}]
        }
        mock_client.get_balance.return_value = {
            "data": [{"details": [{"availEq": "1000"}]}]
        }
        mock_client.set_leverage.side_effect = BinanceApiError(
            "Binance 请求预算保护中",
            code="LOCAL_RATE_BUDGET",
        )

        response = self.client.post(
            "/v1/trade/open",
            {
                "symbol": "BTCUSDT",
                "stop_loss_price": "90",
                "stop_loss_amount": "30",
                "include_fee": True,
                "ema_check_id": "rate-limited",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["message"], "Binance 请求预算保护中")
        mock_client.place_market_order.assert_not_called()

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    @patch("trading.views.get_user_binance_credentials")
    def test_trade_open_succeeds_when_stop_order_visibility_is_delayed(
        self,
        mock_creds,
        mock_inst,
        mock_ticker,
        mock_client_cls,
    ):
        mock_creds.return_value = object()
        mock_ticker.return_value = {"last": "100"}
        mock_inst.return_value = {"ctVal": "0.01", "lotSz": "1"}

        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.place_market_order.return_value = {"code": "0", "data": [{"ordId": "12345-delay"}]}
        mock_client.get_order.return_value = {"code": "0", "data": [{"state": "filled", "fillSz": "3", "avgPx": "100.1"}]}
        mock_client.place_stop_market_order.return_value = {"code": "0", "data": [{"algoId": "sl-delay-m"}]}
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": []}
        mock_client_cls.return_value = mock_client

        resp = self.client.post(
            "/v1/trade/open",
            {
                "symbol": "BTCUSDT",
                "stop_loss_price": "90",
                "stop_loss_amount": "30",
                "include_fee": True,
                "ema_check_id": "ema-2",
            },
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        order = Order.objects.get(user=self.user, binance_order_id="12345-delay")
        self.assertEqual(order.binance_stop_order_id, "")
        self.assertEqual(order.binance_stop_market_order_id, "sl-delay-m")
        self.assertIn("开仓", resp.data["message"])

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    @patch("trading.views.get_user_binance_credentials")
    def test_trade_open_uses_market_order_fill_from_submit_response(
        self,
        mock_creds,
        mock_inst,
        mock_ticker,
        mock_client_cls,
    ):
        mock_creds.return_value = object()
        mock_ticker.return_value = {"last": "100"}
        mock_inst.return_value = {"ctVal": "0.01", "lotSz": "1"}

        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.place_market_order.return_value = {
            "code": "0",
            "data": [{"ordId": "12345-fast", "state": "filled", "fillSz": "3", "accFillSz": "3", "avgPx": "100.1"}],
        }
        mock_client.get_order.side_effect = AssertionError("should not poll filled market order")
        mock_client.place_stop_loss_order.return_value = {"code": "0", "data": [{"algoId": "sl-fast"}]}
        mock_client.place_stop_market_order.return_value = {"code": "0", "data": [{"algoId": "sl-fast-m"}]}
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": [{"algoId": "sl-fast", "sz": "3"}]}
        mock_client_cls.return_value = mock_client

        resp = self.client.post(
            "/v1/trade/open",
            {
                "symbol": "BTCUSDT",
                "stop_loss_price": "90",
                "stop_loss_amount": "30",
                "include_fee": True,
                "ema_check_id": "ema-3",
            },
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        mock_client.get_order.assert_not_called()
        order = Order.objects.get(user=self.user, binance_order_id="12345-fast")
        self.assertEqual(order.open_price, Decimal("100.1"))

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    @patch("trading.views.get_user_binance_credentials")
    def test_trade_open_does_not_create_position_when_fill_is_unknown(
        self,
        mock_creds,
        mock_inst,
        mock_ticker,
        mock_client_cls,
    ):
        mock_creds.return_value = object()
        mock_ticker.return_value = {"last": "100"}
        mock_inst.return_value = {"ctVal": "0.01", "lotSz": "1"}
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.place_market_order.return_value = {"code": "0", "data": [{"ordId": "unknown-fill-1"}]}
        mock_client.get_order.side_effect = BinanceApiError("temporary network failure")
        mock_client_cls.return_value = mock_client

        resp = self.client.post(
            "/v1/trade/open",
            {
                "symbol": "BTCUSDT",
                "stop_loss_price": "90",
                "stop_loss_amount": "30",
                "include_fee": True,
                "ema_check_id": "ema-unknown",
                "client_request_id": "22222222-2222-4222-8222-222222222222",
            },
            format="json",
        )

        self.assertEqual(resp.status_code, status.HTTP_409_CONFLICT)
        self.assertFalse(Order.objects.filter(user=self.user, binance_order_id="unknown-fill-1").exists())
        open_request = TradeOpenRequest.objects.get(client_request_id="22222222-2222-4222-8222-222222222222")
        self.assertEqual(open_request.status, TradeOpenRequest.STATUS_SUBMITTED)
        self.assertEqual(open_request.binance_order_id, "unknown-fill-1")
        mock_client.place_stop_market_order.assert_not_called()

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    @patch("trading.views.get_user_binance_credentials")
    def test_trade_open_protects_only_confirmed_partial_fill(
        self,
        mock_creds,
        mock_inst,
        mock_ticker,
        mock_client_cls,
    ):
        mock_creds.return_value = object()
        mock_ticker.return_value = {"last": "100"}
        mock_inst.return_value = {"ctVal": "0.01", "lotSz": "1"}
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.place_market_order.return_value = {
            "code": "0",
            "data": [{
                "ordId": "partial-fill-1",
                "state": "partially_filled",
                "fillSz": "1",
                "accFillSz": "1",
                "avgPx": "100.2",
            }],
        }
        mock_client.place_stop_market_order.return_value = {"code": "0", "data": [{"algoId": "partial-stop-1"}]}
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": []}
        mock_client_cls.return_value = mock_client

        resp = self.client.post(
            "/v1/trade/open",
            {
                "symbol": "BTCUSDT",
                "stop_loss_price": "90",
                "stop_loss_amount": "30",
                "include_fee": True,
                "ema_check_id": "ema-partial",
            },
            format="json",
        )

        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        order = Order.objects.get(user=self.user, binance_order_id="partial-fill-1")
        self.assertEqual(order.size, Decimal("1"))
        self.assertIn("部分成交", resp.data["message"])
        self.assertEqual(Decimal(mock_client.place_stop_market_order.call_args.kwargs["size"]), Decimal("1"))

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    @patch("trading.views.get_user_binance_credentials")
    def test_trade_open_recovers_when_submit_response_is_lost(
        self,
        mock_creds,
        mock_inst,
        mock_ticker,
        mock_client_cls,
    ):
        mock_creds.return_value = object()
        mock_ticker.return_value = {"last": "100"}
        mock_inst.return_value = {"ctVal": "0.01", "lotSz": "1"}

        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.place_market_order.side_effect = BinanceApiError(
            "连接 Binance Futures 实盘 失败，请稍后重试",
            outcome_unknown=True,
        )
        mock_client.get_order.return_value = {
            "code": "0",
            "data": [{
                "ordId": "recovered-open-1",
                "state": "filled",
                "fillSz": "3",
                "accFillSz": "3",
                "avgPx": "100.2",
                "side": "buy",
                "sz": "3",
            }],
        }
        mock_client.place_stop_loss_order.return_value = {"code": "0", "data": [{"algoId": "sl-recovered"}]}
        mock_client.place_stop_market_order.return_value = {"code": "0", "data": [{"algoId": "slm-recovered"}]}
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": [{"algoId": "sl-recovered", "sz": "3"}]}
        mock_client_cls.return_value = mock_client

        resp = self.client.post(
            "/v1/trade/open",
            {
                "symbol": "BTCUSDT",
                "stop_loss_price": "90",
                "stop_loss_amount": "30",
                "include_fee": True,
                "ema_check_id": "ema-recover",
                "client_request_id": "11111111-1111-4111-8111-111111111111",
            },
            format="json",
        )

        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        order = Order.objects.get(user=self.user, binance_order_id="recovered-open-1")
        self.assertEqual(order.open_price, Decimal("100.2"))
        open_request = TradeOpenRequest.objects.get(order_id=order.id)
        self.assertEqual(open_request.status, TradeOpenRequest.STATUS_RECOVERED)
        self.assertEqual(open_request.binance_order_id, "recovered-open-1")

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker", return_value={"last": "100"})
    @patch("trading.views._extract_instrument", return_value={"ctVal": "0.01", "lotSz": "1"})
    @patch("trading.views.get_user_binance_credentials", return_value=object())
    def test_trade_open_retry_uses_persisted_direction_instead_of_new_market_price(
        self,
        _mock_creds,
        _mock_inst,
        mock_ticker,
        mock_client_cls,
    ):
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {
            "code": "0",
            "data": [{"posMode": "long_short_mode"}],
        }
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.place_market_order.return_value = {
            "code": "0",
            "data": [{"ordId": "recover-after-unknown"}],
        }
        lookup_count = {"value": 0}

        def get_order(**_kwargs):
            lookup_count["value"] += 1
            if lookup_count["value"] <= 6:
                raise BinanceApiError("temporary network failure")
            submitted_size = str(mock_client.place_market_order.call_args.kwargs["size"])
            return {
                "code": "0",
                "data": [{
                    "ordId": "recover-after-unknown",
                    "state": "filled",
                    "fillSz": submitted_size,
                    "accFillSz": submitted_size,
                    "avgPx": "100.2",
                    "side": "buy",
                    "sz": submitted_size,
                }],
            }

        mock_client.get_order.side_effect = get_order
        mock_client.place_stop_market_order.return_value = {
            "code": "0",
            "data": [{"algoId": "recover-after-unknown-stop"}],
        }
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": []}
        mock_client_cls.return_value = mock_client
        payload = {
            "symbol": "BTCUSDT",
            "stop_loss_price": "90",
            "stop_loss_amount": "30",
            "include_fee": False,
            "ema_check_id": "ema-retry-intent",
            "client_request_id": "33333333-3333-4333-8333-333333333333",
        }

        first = self.client.post("/v1/trade/open", payload, format="json")
        second = self.client.post("/v1/trade/open", payload, format="json")

        self.assertEqual(first.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(second.status_code, status.HTTP_200_OK)
        order = Order.objects.get(binance_order_id="recover-after-unknown")
        self.assertEqual(order.side, 0)
        self.assertEqual(mock_ticker.call_count, 1)
        self.assertEqual(mock_client.place_market_order.call_count, 1)

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker", return_value={"last": "101"})
    @patch(
        "trading.views._extract_instrument",
        return_value={"ctVal": "0.01", "lotSz": "1", "tickSz": "0.1", "lever": "10"},
    )
    @patch("trading.views.get_user_binance_credentials", return_value=object())
    def test_limit_open_stops_when_leverage_setting_hits_shared_rate_limit(
        self,
        _mock_creds,
        _mock_inst,
        _mock_ticker,
        mock_client_cls,
    ):
        mock_client = mock_client_cls.return_value
        mock_client.get_positions.return_value = {"data": []}
        mock_client.get_pending_orders.return_value = {"data": []}
        mock_client.get_pending_algo_orders.return_value = {"data": []}
        mock_client.get_account_config.return_value = {
            "data": [{"posMode": "long_short_mode"}]
        }
        mock_client.get_leverage_bracket.return_value = {
            "data": [{"maxLever": "10", "notionalCap": "1000000"}]
        }
        mock_client.get_balance.return_value = {
            "data": [{"details": [{"availEq": "1000"}]}]
        }
        mock_client.set_leverage.side_effect = BinanceApiError(
            "Binance 请求预算保护中",
            code="LOCAL_RATE_BUDGET",
        )

        response = self.client.post(
            "/v1/trade/limit-order/create",
            {
                "symbol": "BTCUSDT",
                "limit_price": "100",
                "stop_loss_price": "90",
                "stop_loss_amount": "30",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["message"], "Binance 请求预算保护中")
        mock_client.place_limit_order.assert_not_called()

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    @patch("trading.views.get_user_binance_credentials")
    def test_limit_create_recovers_lost_submit_response_without_duplicate_order(
        self,
        mock_creds,
        mock_inst,
        mock_ticker,
        mock_client_cls,
    ):
        mock_creds.return_value = object()
        mock_ticker.return_value = {"last": "101"}
        mock_inst.return_value = {"ctVal": "0.01", "lotSz": "1", "tickSz": "0.1", "lever": "10"}
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.place_limit_order.side_effect = BinanceApiError(
            "temporary network failure",
            outcome_unknown=True,
        )
        def get_recovered_order(**_kwargs):
            open_request = TradeOpenRequest.objects.get(
                client_request_id="33333333-3333-4333-8333-333333333333"
            )
            intent = open_request.request_payload["_execution_intent"]
            return {
                "code": "0",
                "data": [{
                    "ordId": "recovered-limit-1",
                    "state": "live",
                    "fillSz": "0",
                    "avgPx": intent["entry_price"],
                    "px": intent["entry_price"],
                    "side": intent["open_side"],
                    "sz": intent["size"],
                    "posSide": intent["pos_side"],
                }],
            }

        mock_client.get_order.side_effect = get_recovered_order
        mock_client_cls.return_value = mock_client
        payload = {
            "symbol": "BTCUSDT",
            "limit_price": "100",
            "stop_loss_price": "90",
            "stop_loss_amount": "30",
            "client_request_id": "33333333-3333-4333-8333-333333333333",
        }

        first = self.client.post("/v1/trade/limit-order/create", payload, format="json")
        second = self.client.post("/v1/trade/limit-order/create", payload, format="json")

        self.assertEqual(first.status_code, status.HTTP_200_OK)
        self.assertEqual(second.status_code, status.HTTP_200_OK)
        self.assertEqual(LimitOrder.objects.filter(user=self.user, binance_order_id="recovered-limit-1").count(), 1)
        self.assertEqual(mock_client.place_limit_order.call_count, 1)
        open_request = TradeOpenRequest.objects.get(client_request_id=payload["client_request_id"])
        self.assertEqual(open_request.status, TradeOpenRequest.STATUS_RECOVERED)

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    @patch("trading.views.get_user_binance_credentials")
    def test_limit_create_recovers_after_local_persistence_failure(
        self,
        mock_creds,
        mock_inst,
        mock_ticker,
        mock_client_cls,
    ):
        mock_creds.return_value = object()
        mock_ticker.return_value = {"last": "101"}
        mock_inst.return_value = {"ctVal": "0.01", "lotSz": "1", "tickSz": "0.1", "lever": "10"}
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.place_limit_order.return_value = {
            "code": "0",
            "data": [{"ordId": "persist-limit-1", "sCode": "0", "sMsg": ""}],
        }
        def get_persisted_order(**_kwargs):
            open_request = TradeOpenRequest.objects.get(
                client_request_id="44444444-4444-4444-8444-444444444444"
            )
            intent = open_request.request_payload["_execution_intent"]
            return {
                "code": "0",
                "data": [{
                    "ordId": "persist-limit-1",
                    "state": "live",
                    "fillSz": "0",
                    "avgPx": intent["entry_price"],
                    "px": intent["entry_price"],
                    "side": intent["open_side"],
                    "sz": intent["size"],
                    "posSide": intent["pos_side"],
                }],
            }

        mock_client.get_order.side_effect = get_persisted_order
        mock_client_cls.return_value = mock_client
        payload = {
            "symbol": "BTCUSDT",
            "limit_price": "100",
            "stop_loss_price": "90",
            "stop_loss_amount": "30",
            "client_request_id": "44444444-4444-4444-8444-444444444444",
        }

        with patch("trading.views.LimitOrder.objects.create", side_effect=RuntimeError("database unavailable")):
            first = self.client.post("/v1/trade/limit-order/create", payload, format="json")
        self.assertEqual(first.status_code, status.HTTP_409_CONFLICT)
        open_request = TradeOpenRequest.objects.get(client_request_id=payload["client_request_id"])
        self.assertEqual(open_request.status, TradeOpenRequest.STATUS_SUBMITTED)
        self.assertEqual(open_request.binance_order_id, "persist-limit-1")

        second = self.client.post("/v1/trade/limit-order/create", payload, format="json")
        self.assertEqual(second.status_code, status.HTTP_200_OK)
        self.assertEqual(LimitOrder.objects.filter(user=self.user, binance_order_id="persist-limit-1").count(), 1)
        self.assertEqual(mock_client.place_limit_order.call_count, 1)

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    @patch("trading.views.get_user_binance_credentials")
    def test_limit_create_recovery_does_not_revalidate_against_new_market_price(
        self,
        mock_creds,
        mock_inst,
        mock_ticker,
        mock_client_cls,
    ):
        mock_creds.return_value = object()
        mock_ticker.return_value = {"last": "101"}
        mock_inst.return_value = {
            "ctVal": "0.01",
            "lotSz": "1",
            "tickSz": "0.1",
            "lever": "10",
        }
        mock_client = MagicMock()
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.get_account_config.return_value = {
            "code": "0",
            "data": [{"posMode": "long_short_mode"}],
        }
        mock_client.place_limit_order.side_effect = BinanceApiError("timeout", outcome_unknown=True)
        lookup_count = {"value": 0}

        def get_order(**_kwargs):
            lookup_count["value"] += 1
            if lookup_count["value"] <= len(ORDER_RECOVERY_RETRY_DELAYS_SECONDS):
                return {"code": "0", "data": []}
            open_request = TradeOpenRequest.objects.get(
                client_request_id="55555555-5555-4555-8555-555555555555"
            )
            intent = open_request.request_payload["_execution_intent"]
            return {
                "code": "0",
                "data": [{
                    "ordId": "crossed-market-limit",
                    "state": "live",
                    "fillSz": "0",
                    "avgPx": intent["entry_price"],
                    "px": intent["entry_price"],
                    "side": intent["open_side"],
                    "sz": intent["size"],
                    "posSide": intent["pos_side"],
                }],
            }

        mock_client.get_order.side_effect = get_order
        mock_client_cls.return_value = mock_client
        payload = {
            "symbol": "BTCUSDT",
            "limit_price": "100",
            "stop_loss_price": "90",
            "stop_loss_amount": "30",
            "client_request_id": "55555555-5555-4555-8555-555555555555",
        }

        first = self.client.post("/v1/trade/limit-order/create", payload, format="json")
        mock_ticker.return_value = {"last": "99"}
        second = self.client.post("/v1/trade/limit-order/create", payload, format="json")

        self.assertEqual(first.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(second.status_code, status.HTTP_200_OK)
        self.assertEqual(mock_ticker.call_count, 1)
        self.assertEqual(mock_client.place_limit_order.call_count, 1)

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views.get_user_binance_credentials")
    def test_limit_chase_stops_when_cancel_is_not_confirmed(self, mock_creds, mock_client_cls):
        mock_creds.return_value = object()
        limit_order = self._create_limit_order_for_chase(order_id="chase-cancel-unknown")
        mock_client = MagicMock()
        mock_client.get_order.return_value = {
            "code": "0",
            "data": [{"ordId": limit_order.binance_order_id, "state": "live", "fillSz": "0", "avgPx": "0"}],
        }
        mock_client_cls.return_value = mock_client

        with patch("trading.execution.time.sleep", return_value=None):
            resp = self.client.post(
                "/v1/trade/limit-order/chase",
                {"limit_order_id": limit_order.id},
                format="json",
            )

        self.assertEqual(resp.status_code, status.HTTP_400_BAD_REQUEST)
        limit_order.refresh_from_db()
        self.assertEqual(limit_order.status, LimitOrder.STATUS_PENDING)
        mock_client.place_market_order.assert_not_called()

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views.get_user_binance_credentials")
    def test_limit_chase_adopts_fill_that_occurs_during_cancel(self, mock_creds, mock_client_cls):
        cache.set(
            "trade:inst_rules:BTC-USDT-SWAP",
            {"lotSz": "0.001", "minSz": "0.001", "marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"},
            timeout=300,
        )
        mock_creds.return_value = object()
        limit_order = self._create_limit_order_for_chase(order_id="chase-race-fill")
        mock_client = MagicMock()
        mock_client.get_order.side_effect = [
            {"code": "0", "data": [{"ordId": limit_order.binance_order_id, "state": "live", "fillSz": "0", "avgPx": "0"}]},
            {"code": "0", "data": [{"ordId": limit_order.binance_order_id, "state": "partially_filled", "accFillSz": "1", "avgPx": "100.1"}]},
        ]
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": []}
        mock_client.place_stop_market_order.return_value = {"code": "0", "data": [{"algoId": "chase-race-stop"}]}
        mock_client_cls.return_value = mock_client

        resp = self.client.post(
            "/v1/trade/limit-order/chase",
            {"limit_order_id": limit_order.id},
            format="json",
        )

        self.assertEqual(resp.status_code, status.HTTP_400_BAD_REQUEST)
        limit_order.refresh_from_db()
        self.assertEqual(limit_order.status, LimitOrder.STATUS_PENDING)
        self.assertEqual(limit_order.filled_size, Decimal("1"))
        self.assertIsNotNone(limit_order.order_id)
        self.assertEqual(Order.objects.get(id=limit_order.order_id).size, Decimal("1"))
        mock_client.place_market_order.assert_not_called()

    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views.get_user_binance_credentials")
    def test_limit_chase_recovers_lost_market_response_idempotently(
        self,
        mock_creds,
        mock_client_cls,
        mock_inst,
        mock_ticker,
    ):
        cache.set(
            "trade:inst_rules:BTC-USDT-SWAP",
            {"lotSz": "0.001", "minSz": "0.001", "marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"},
            timeout=300,
        )
        mock_creds.return_value = object()
        mock_ticker.return_value = {"last": "101"}
        mock_inst.return_value = {"ctVal": "0.01", "lotSz": "1", "tickSz": "0.1"}
        limit_order = self._create_limit_order_for_chase(order_id="chase-recover-source")
        mock_client = MagicMock()
        cancel_state = {"confirmed": False}

        def cancel_order(**_kwargs):
            cancel_state["confirmed"] = True
            return {"code": "0", "data": [{"ordId": limit_order.binance_order_id, "state": "canceled"}]}

        def get_order(*, order_id="", orig_client_order_id="", **_kwargs):
            if orig_client_order_id:
                open_request = TradeOpenRequest.objects.get(
                    client_request_id=f"chase:{limit_order.id}"
                )
                intent = open_request.request_payload["_execution_intent"]
                return {
                    "code": "0",
                    "data": [{
                        "ordId": "chase-market-1",
                        "state": "filled",
                        "accFillSz": intent["size"],
                        "avgPx": "101.2",
                        "side": intent["open_side"],
                        "sz": intent["size"],
                        "posSide": intent["pos_side"],
                    }],
                }
            return {
                "code": "0",
                "data": [{
                    "ordId": order_id,
                    "state": "canceled" if cancel_state["confirmed"] else "live",
                    "fillSz": "0",
                    "avgPx": "0",
                }],
            }

        mock_client.cancel_order.side_effect = cancel_order
        mock_client.get_order.side_effect = get_order
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": []}
        mock_client.place_market_order.side_effect = BinanceApiError(
            "temporary network failure",
            outcome_unknown=True,
        )
        mock_client.place_stop_market_order.return_value = {"code": "0", "data": [{"algoId": "chase-market-stop"}]}
        mock_client_cls.return_value = mock_client

        first = self.client.post(
            "/v1/trade/limit-order/chase",
            {"limit_order_id": limit_order.id},
            format="json",
        )
        second = self.client.post(
            "/v1/trade/limit-order/chase",
            {"limit_order_id": limit_order.id},
            format="json",
        )

        self.assertEqual(first.status_code, status.HTTP_200_OK)
        self.assertEqual(second.status_code, status.HTTP_200_OK)
        self.assertEqual(Order.objects.filter(user=self.user, binance_order_id="chase-market-1").count(), 1)
        self.assertEqual(mock_client.place_market_order.call_count, 1)
        limit_order.refresh_from_db()
        self.assertEqual(limit_order.status, LimitOrder.STATUS_CANCELLED)
        self.assertEqual(limit_order.order.binance_order_id, "chase-market-1")

    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views.get_user_binance_credentials")
    def test_limit_chase_retry_reuses_intent_after_market_moves(
        self,
        mock_creds,
        mock_client_cls,
        mock_inst,
        mock_ticker,
    ):
        cache.set(
            "trade:inst_rules:BTC-USDT-SWAP",
            {
                "lotSz": "0.001",
                "minSz": "0.001",
                "marketLotSz": "0.001",
                "marketMinSz": "0.001",
                "tickSz": "0.1",
            },
            timeout=300,
        )
        mock_creds.return_value = object()
        mock_ticker.return_value = {"last": "101"}
        mock_inst.return_value = {"ctVal": "0.01", "lotSz": "1", "tickSz": "0.1"}
        limit_order = self._create_limit_order_for_chase(order_id="chase-intent-source")
        mock_client = MagicMock()
        cancel_state = {"confirmed": False}
        recovery_lookups = {"value": 0}

        def cancel_order(**_kwargs):
            cancel_state["confirmed"] = True
            return {
                "code": "0",
                "data": [{"ordId": limit_order.binance_order_id, "state": "canceled"}],
            }

        def get_order(*, order_id="", orig_client_order_id="", **_kwargs):
            if orig_client_order_id:
                recovery_lookups["value"] += 1
                if recovery_lookups["value"] <= len(ORDER_RECOVERY_RETRY_DELAYS_SECONDS):
                    return {"code": "0", "data": []}
                open_request = TradeOpenRequest.objects.get(
                    client_request_id=f"chase:{limit_order.id}"
                )
                intent = open_request.request_payload["_execution_intent"]
                return {
                    "code": "0",
                    "data": [{
                        "ordId": "chase-intent-market",
                        "state": "filled",
                        "accFillSz": intent["size"],
                        "avgPx": "101.2",
                        "side": intent["open_side"],
                        "sz": intent["size"],
                        "posSide": intent["pos_side"],
                    }],
                }
            return {
                "code": "0",
                "data": [{
                    "ordId": order_id,
                    "state": "canceled" if cancel_state["confirmed"] else "live",
                    "fillSz": "0",
                    "avgPx": "0",
                }],
            }

        mock_client.cancel_order.side_effect = cancel_order
        mock_client.get_order.side_effect = get_order
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.get_account_config.return_value = {
            "code": "0",
            "data": [{"posMode": "long_short_mode"}],
        }
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": []}
        mock_client.place_market_order.side_effect = BinanceApiError("timeout", outcome_unknown=True)
        mock_client.place_stop_market_order.return_value = {
            "code": "0",
            "data": [{"algoId": "chase-intent-stop"}],
        }
        mock_client_cls.return_value = mock_client

        first = self.client.post(
            "/v1/trade/limit-order/chase",
            {"limit_order_id": limit_order.id},
            format="json",
        )
        mock_ticker.return_value = {"last": "80"}
        second = self.client.post(
            "/v1/trade/limit-order/chase",
            {"limit_order_id": limit_order.id},
            format="json",
        )

        self.assertEqual(first.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(second.status_code, status.HTTP_200_OK)
        self.assertEqual(mock_ticker.call_count, 1)
        mock_client.place_market_order.assert_called_once()
        limit_order.refresh_from_db()
        self.assertEqual(limit_order.order.binance_order_id, "chase-intent-market")

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    @patch("trading.views.get_user_binance_credentials")
    def test_trade_open_with_strategy_creates_snapshot_and_log(
        self,
        mock_creds,
        mock_inst,
        mock_ticker,
        mock_client_cls,
    ):
        mock_creds.return_value = object()
        mock_ticker.return_value = {"last": "100"}
        mock_inst.return_value = {"ctVal": "0.01", "lotSz": "1"}

        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.place_market_order.return_value = {"code": "0", "data": [{"ordId": "12346"}]}
        mock_client.get_order.return_value = {"code": "0", "data": [{"state": "filled", "fillSz": "3", "avgPx": "100.1"}]}
        mock_client.place_stop_loss_order.return_value = {"code": "0", "data": [{"algoId": "998"}]}
        mock_client.place_stop_market_order.return_value = {"code": "0", "data": [{"algoId": "998m"}]}
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": [{"algoId": "998", "sz": "3"}]}
        mock_client.place_take_profit_order.return_value = {"code": "0", "data": [{"algoId": "tp-001"}]}
        mock_client_cls.return_value = mock_client
        strategy = self._create_strategy()

        resp = self.client.post(
            "/v1/trade/open-position",
            {
                "symbol": "BTCUSDT",
                "stop_loss_price": "90",
                "stop_loss_amount": "30",
                "include_fee": True,
                "ema_check_id": "ema-4",
                "strategy_id": str(strategy.id),
                "strategy_name": "前端篡改名称",
                "strategy_config": [
                    {"profitRR": 9.9, "reducePosition": 99, "stopLossType": "none"},
                ],
            },
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        order = Order.objects.get(user=self.user, binance_order_id="12346")
        self.assertEqual(order.strategy_status, Order.STRATEGY_STATUS_RUNNING)
        self.assertIsNotNone(order.strategy_snapshot_id)
        self.assertGreaterEqual(len(order.strategy_tp_algo_ids), 1)
        snapshot = OrderStrategySnapshot.objects.get(id=order.strategy_snapshot_id)
        self.assertEqual(snapshot.strategy_name, "稳健通用")
        self.assertEqual(snapshot.strategy_config[0]["profitRR"], 1.5)
        self.assertEqual(snapshot.strategy_config[0]["reducePosition"], 40.0)
        self.assertTrue(OrderStrategyLog.objects.filter(order=order, snapshot=snapshot).exists())

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    @patch("trading.views.get_user_binance_credentials")
    def test_trade_open_auto_closes_stale_local_order_during_duplicate_check(
        self,
        mock_creds,
        mock_inst,
        mock_ticker,
        mock_client_cls,
    ):
        mock_creds.return_value = object()
        mock_ticker.return_value = {"last": "100"}
        mock_inst.return_value = {"ctVal": "0.01", "lotSz": "1"}

        # 本地残留未平仓（交易所实际已无持仓）
        stale = Order.objects.create(
            user=self.user,
            binance_order_id="stale-1",
            binance_stop_order_id="",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            initial_stop_price=Decimal("90"),
            current_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )

        mock_client = MagicMock()
        mock_client.get_positions.return_value = {"code": "0", "data": []}
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "side": "sell",
                    "time": str(int(timezone.now().timestamp() * 1000)),
                    "fillPx": "101.2",
                    "fillSz": "1",
                    "ordId": "manual-close-1",
                }
            ],
        }
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.place_market_order.return_value = {"code": "0", "data": [{"ordId": "12347"}]}
        mock_client.get_order.return_value = {"code": "0", "data": [{"state": "filled", "fillSz": "3", "avgPx": "100.1"}]}
        mock_client.place_stop_loss_order.return_value = {"code": "0", "data": [{"algoId": "997"}]}
        mock_client.place_stop_market_order.return_value = {"code": "0", "data": [{"algoId": "997m"}]}
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": [{"algoId": "997", "sz": "3"}]}
        mock_client_cls.return_value = mock_client

        resp = self.client.post(
            "/v1/trade/open",
            {
                "symbol": "BTCUSDT",
                "stop_loss_price": "90",
                "stop_loss_amount": "30",
                "include_fee": True,
                "ema_check_id": "ema-5",
            },
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        stale.refresh_from_db()
        self.assertEqual(stale.status, 1)
        self.assertEqual(stale.close_binance_order_id, "manual-close-1")
        self.assertEqual(stale.close_price, Decimal("101.2"))
        self.assertTrue(Order.objects.filter(user=self.user, binance_order_id="12347").exists())

    @patch("trading.views.BinanceFuturesClient")
    @patch("trading.views._extract_ticker")
    @patch("trading.views._extract_instrument")
    @patch("trading.views.get_user_binance_credentials")
    def test_trade_open_blocks_when_exchange_position_exists_without_local_order(
        self,
        mock_creds,
        mock_inst,
        mock_ticker,
        mock_client_cls,
    ):
        mock_creds.return_value = object()
        mock_ticker.return_value = {"last": "100"}
        mock_inst.return_value = {"ctVal": "0.01", "lotSz": "1"}

        mock_client = MagicMock()
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [
                {
                    "instId": "BTC-USDT-SWAP",
                    "posSide": "long",
                    "pos": "1",
                }
            ],
        }
        mock_client_cls.return_value = mock_client

        resp = self.client.post(
            "/v1/trade/open",
            {
                "symbol": "BTCUSDT",
                "stop_loss_price": "90",
                "stop_loss_amount": "30",
                "include_fee": True,
                "ema_check_id": "ema-6",
            },
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("Binance", resp.data["message"])
        mock_client.place_market_order.assert_not_called()

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_strategy_engine_triggers_reduce_and_move_stop(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_mark_price_candles.return_value = {
            "code": "0",
            "data": [["1700000000000", "109", "115", "108", "112", "0", "0", "1"]],
        }
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{"instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "1", "last": "112", "markPx": "112"}],
        }
        mock_client.get_pending_algo_orders.return_value = {
            "code": "0",
            "data": [
                {
                    "algoId": "sl-1",
                    "instId": "BTC-USDT-SWAP",
                    "algoType": "STOP_MARKET",
                    "side": "sell",
                    "posSide": "long",
                    "state": "live",
                    "sz": "1.000",
                    "slTriggerPx": "110.00",
                }
            ],
        }
        mock_client.place_stop_market_order.return_value = {"code": "0", "data": [{"algoId": "sl-1m"}]}
        mock_client_cls.return_value = mock_client

        order = Order.objects.create(
            user=self.user,
            binance_order_id="binance-engine-1",
            binance_stop_market_order_id="sl-algo-1",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            current_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
        )
        snapshot = OrderStrategySnapshot.objects.create(
            order=order,
            user=self.user,
            strategy_id="s-1",
            strategy_name="测试策略",
            strategy_config=[
                {"profitRR": 1, "reducePosition": 50, "stopLossType": "fixedRR", "stopLossRR": 0.5},
            ],
        )
        order.strategy_snapshot_id = snapshot.id
        order.save(update_fields=["strategy_snapshot_id"])

        processed = run_strategy_engine()
        self.assertEqual(processed, 1)
        order.refresh_from_db()
        self.assertGreater(order.current_stop_price, Decimal("90"))
        self.assertEqual(order.binance_stop_order_id, "")
        self.assertEqual(order.binance_stop_market_order_id, "sl-1")
        mock_client.get_mark_price_candles.assert_called_once()
        mock_client.get_candles.assert_not_called()
        self.assertTrue(
            OrderStrategyLog.objects.filter(order=order, snapshot=snapshot, result=OrderStrategyLog.RESULT_SUCCESS).exists()
        )

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_strategy_engine_reuses_user_exchange_snapshot_within_same_cycle(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()

        def candles_side_effect(inst_id, bar, limit):
            if inst_id == "BTC-USDT-SWAP":
                return {"code": "0", "data": [["1700000000000", "109", "115", "108", "112", "0", "0", "1"]]}
            return {"code": "0", "data": [["1700000000000", "209", "215", "208", "212", "0", "0", "1"]]}

        def pending_algo_side_effect(ord_type=None, inst_type=None, inst_id=None, **_kwargs):
            if inst_id == "BTC-USDT-SWAP":
                return {
                    "code": "0",
                    "data": [
                        {
                            "algoId": "sl-btc",
                            "instId": "BTC-USDT-SWAP",
                            "algoType": "STOP_MARKET",
                            "side": "sell",
                            "posSide": "long",
                            "state": "live",
                            "sz": "1.000",
                            "slTriggerPx": "110.00",
                        }
                    ],
                }
            return {
                "code": "0",
                "data": [
                    {
                        "algoId": "sl-eth",
                        "instId": "ETH-USDT-SWAP",
                        "algoType": "STOP_MARKET",
                        "side": "sell",
                        "posSide": "long",
                        "state": "live",
                        "sz": "1.000",
                        "slTriggerPx": "210.00",
                    }
                ],
            }

        mock_client.get_mark_price_candles.side_effect = candles_side_effect
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [
                {"instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "1", "last": "112", "markPx": "112"},
                {"instId": "ETH-USDT-SWAP", "posSide": "long", "pos": "1", "last": "212", "markPx": "212"},
            ],
        }
        mock_client.get_pending_algo_orders.side_effect = pending_algo_side_effect
        mock_client.place_stop_loss_order.side_effect = [{"code": "0", "data": [{"algoId": "sl-btc"}]}, {"code": "0", "data": [{"algoId": "sl-eth"}]}]
        mock_client.place_stop_market_order.side_effect = [{"code": "0", "data": [{"algoId": "slm-btc"}]}, {"code": "0", "data": [{"algoId": "slm-eth"}]}]
        mock_client_cls.return_value = mock_client

        order_btc = Order.objects.create(
            user=self.user,
            binance_order_id="binance-engine-btc",
            binance_stop_order_id="sl-btc-old",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            current_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
        )
        snapshot_btc = OrderStrategySnapshot.objects.create(
            order=order_btc,
            user=self.user,
            strategy_id="s-btc",
            strategy_name="测试策略BTC",
            strategy_config=[{"profitRR": 1, "reducePosition": 0, "stopLossType": "fixedRR", "stopLossRR": 0.5}],
        )
        order_btc.strategy_snapshot_id = snapshot_btc.id
        order_btc.save(update_fields=["strategy_snapshot_id"])

        order_eth = Order.objects.create(
            user=self.user,
            binance_order_id="binance-engine-eth",
            binance_stop_order_id="sl-eth-old",
            symbol="ETHUSDT",
            side=0,
            open_price=Decimal("200"),
            stop_loss_price=Decimal("190"),
            current_stop_price=Decimal("190"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
        )
        snapshot_eth = OrderStrategySnapshot.objects.create(
            order=order_eth,
            user=self.user,
            strategy_id="s-eth",
            strategy_name="测试策略ETH",
            strategy_config=[{"profitRR": 1, "reducePosition": 0, "stopLossType": "fixedRR", "stopLossRR": 0.5}],
        )
        order_eth.strategy_snapshot_id = snapshot_eth.id
        order_eth.save(update_fields=["strategy_snapshot_id"])

        processed = run_strategy_engine()
        self.assertEqual(processed, 2)
        self.assertEqual(mock_client.get_account_config.call_count, 1)
        self.assertEqual(mock_client.get_positions.call_count, 1)
        self.assertEqual(mock_client.get_mark_price_candles.call_count, 2)
        order_btc.refresh_from_db()
        order_eth.refresh_from_db()
        self.assertGreater(order_btc.current_stop_price, Decimal("90"))
        self.assertGreater(order_eth.current_stop_price, Decimal("190"))

    @patch("trading.services._move_stop_loss")
    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_strategy_engine_continues_trailing_fixed_rr_after_level_moved(
        self,
        mock_client_cls,
        mock_creds,
        mock_move_stop_loss,
    ):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{"instId": "ETC-USDT-SWAP", "posSide": "long", "pos": "100", "last": "7.29", "markPx": "7.29"}],
        }
        mock_client.get_mark_price_candles.return_value = {
            "code": "0",
            "data": [["1700000000000", "7.28", "7.30337892", "7.27", "7.29", "0", "0", "1"]],
        }
        mock_client_cls.return_value = mock_client

        order = Order.objects.create(
            user=self.user,
            binance_order_id="binance-engine-etc",
            symbol="ETCUSDT",
            side=0,
            open_price=Decimal("7.07000000"),
            stop_loss_price=Decimal("7.22400000"),
            current_stop_price=Decimal("7.22400000"),
            initial_stop_price=Decimal("7.02000000"),
            last_extreme_price=Decimal("7.27427568"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("100"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
        )
        snapshot = OrderStrategySnapshot.objects.create(
            order=order,
            user=self.user,
            strategy_id="s-trailing-fixed",
            strategy_name="测试持续移动",
            strategy_config=[
                {"profitRR": 1.5, "reducePosition": 30, "stopLossType": "absoluteRR", "stopLossAbsoluteRR": 0},
                {"profitRR": 2.5, "reducePosition": 20, "stopLossType": "absoluteRR", "stopLossAbsoluteRR": 0.5},
                {"profitRR": 3, "reducePosition": 0, "stopLossType": "absoluteRR", "stopLossAbsoluteRR": 1.5},
                {"profitRR": 4, "reducePosition": 0, "stopLossType": "fixedRR", "stopLossRR": 1},
                {"profitRR": 7, "reducePosition": 0, "stopLossType": "fixedRR", "stopLossRR": 0.5},
            ],
        )
        order.strategy_snapshot_id = snapshot.id
        order.save(update_fields=["strategy_snapshot_id"])
        for idx, trigger_r, stop_price in [
            (1, Decimal("1.5"), Decimal("7.07000000")),
            (2, Decimal("2.5"), Decimal("7.09500000")),
            (3, Decimal("3"), Decimal("7.14500000")),
            (4, Decimal("4"), Decimal("7.22427568")),
        ]:
            OrderStrategyLog.objects.create(
                order=order,
                snapshot=snapshot,
                behavior_desc=f"L{idx} 达到 {format(trigger_r, 'f')}R",
                result=OrderStrategyLog.RESULT_SUCCESS,
                trigger_r=trigger_r,
            )
            OrderStrategyLog.objects.create(
                order=order,
                snapshot=snapshot,
                behavior_desc=f"L{idx} 止损移动到 {format(stop_price, 'f')}",
                result=OrderStrategyLog.RESULT_SUCCESS,
                trigger_r=trigger_r,
            )

        def move_side_effect(_client, move_order, candidate, *_args, **_kwargs):
            move_order.current_stop_price = candidate
            move_order.stop_loss_price = candidate
            move_order.save(update_fields=["current_stop_price", "stop_loss_price"])
            return True

        mock_move_stop_loss.side_effect = move_side_effect

        processed = run_strategy_engine()

        self.assertEqual(processed, 1)
        order.refresh_from_db()
        self.assertEqual(order.last_extreme_price, Decimal("7.30337892"))
        self.assertEqual(order.current_stop_price, Decimal("7.25337892"))
        mock_move_stop_loss.assert_called_once()
        self.assertEqual(mock_move_stop_loss.call_args.args[2], Decimal("7.25337892"))
        self.assertTrue(
            OrderStrategyLog.objects.filter(
                order=order,
                snapshot=snapshot,
                behavior_desc="L4 止损移动到 7.25337892",
                result=OrderStrategyLog.RESULT_SUCCESS,
                trigger_r=Decimal("4"),
            ).exists()
        )

    def test_move_stop_loss_skips_when_candidate_does_not_improve_by_tick(self):
        cache.set(
            "trade:inst_rules:BTC-USDT-SWAP",
            {"lotSz": "0.001", "minSz": "0.001", "marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"},
            timeout=300,
        )
        mock_client = MagicMock()
        order = Order.objects.create(
            user=self.user,
            binance_order_id="binance-engine-noop-stop",
            binance_stop_order_id="sl-keep",
            binance_stop_market_order_id="slm-keep",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("105"),
            current_stop_price=Decimal("105"),
            initial_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
        )

        moved = _move_stop_loss(
            mock_client,
            order,
            Decimal("105"),
            Decimal("112"),
            pos_mode="long_short_mode",
            positions=[{"instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "1", "last": "112", "markPx": "112"}],
        )

        self.assertFalse(moved)
        mock_client.get_pending_algo_orders.assert_not_called()
        mock_client.cancel_algos.assert_not_called()
        mock_client.place_stop_loss_order.assert_not_called()
        mock_client.place_stop_market_order.assert_not_called()

    @patch("trading.services.time.sleep", return_value=None)
    def test_stop_replacement_failure_keeps_existing_protection(self, _mock_sleep):
        cache.set(
            "trade:inst_rules:BTC-USDT-SWAP",
            {"lotSz": "0.001", "minSz": "0.001", "marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"},
            timeout=300,
        )
        order = Order.objects.create(
            user=self.user,
            binance_order_id="protected-replacement-failure",
            binance_stop_market_order_id="sl-old",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            current_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )
        client = MagicMock()
        client.place_stop_market_order.side_effect = BinanceApiError("replacement rejected")
        stale = [{
            "algoId": "sl-old",
            "instId": "BTC-USDT-SWAP",
            "algoType": "STOP_MARKET",
            "side": "sell",
            "posSide": "long",
            "state": "live",
            "sz": "1",
            "slTriggerPx": "90",
        }]

        with self.assertRaisesMessage(BinanceApiError, "replacement rejected"):
            _converge_stop_loss_order(
                client,
                order,
                exchange_size=Decimal("1"),
                stop_price=Decimal("95"),
                pos_mode="long_short_mode",
                current_price=Decimal("100"),
                algo_rows=stale,
                action="test_replace_stop",
            )

        order.refresh_from_db()
        self.assertEqual(order.binance_stop_market_order_id, "sl-old")
        self.assertEqual(order.current_stop_price, Decimal("90"))
        client.cancel_algos.assert_not_called()

    def test_strategy_take_profit_partial_creation_is_rolled_back(self):
        cache.set(
            "trade:inst_rules:BTC-USDT-SWAP",
            {"lotSz": "0.001", "minSz": "0.001", "marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"},
            timeout=300,
        )
        order = Order.objects.create(
            user=self.user,
            binance_order_id="strategy-partial-create",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            initial_stop_price=Decimal("90"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
        )
        snapshot = OrderStrategySnapshot.objects.create(
            order=order,
            user=self.user,
            strategy_id="partial-create",
            strategy_name="两级止盈",
            strategy_config=[
                {"profitRR": 1, "reducePosition": 50},
                {"profitRR": 2, "reducePosition": 50},
            ],
        )
        client = MagicMock()
        client.place_take_profit_order.side_effect = [
            {"code": "0", "data": [{"algoId": "tp-created-first", "sCode": "0"}]},
            BinanceApiError("second level rejected", code="-1130"),
        ]
        client.get_pending_algo_orders.return_value = {"code": "0", "data": []}
        client.cancel_algos.return_value = {
            "code": "0",
            "data": [{"algoId": "tp-created-first"}],
        }

        with self.assertRaisesMessage(BinanceApiError, "second level rejected"):
            setup_strategy_take_profit_orders(order, snapshot, client, "long")

        client.cancel_algos.assert_called_once_with(
            algo_id="tp-created-first",
            inst_id="BTC-USDT-SWAP",
        )

    def test_strategy_take_profit_keeps_unconfirmed_rollback_ids_for_reconciliation(self):
        cache.set(
            "trade:inst_rules:BTC-USDT-SWAP",
            {"lotSz": "0.001", "minSz": "0.001", "marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"},
            timeout=300,
        )
        order = Order.objects.create(
            user=self.user,
            binance_order_id="strategy-rollback-unknown",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            initial_stop_price=Decimal("90"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
        )
        snapshot = OrderStrategySnapshot.objects.create(
            order=order,
            user=self.user,
            strategy_id="rollback-unknown",
            strategy_name="两级止盈",
            strategy_config=[
                {"profitRR": 1, "reducePosition": 50},
                {"profitRR": 2, "reducePosition": 50},
            ],
        )
        order.strategy_snapshot_id = snapshot.id
        order.save(update_fields=["strategy_snapshot_id"])
        client = MagicMock()
        client.place_take_profit_order.side_effect = [
            {"code": "0", "data": [{"algoId": "tp-created-first", "sCode": "0"}]},
            BinanceApiError("second level rejected", code="-1130"),
        ]
        client.cancel_algos.side_effect = BinanceApiError("权限不足", code="-2015")

        with self.assertRaisesMessage(BinanceApiError, "second level rejected"):
            _rebuild_take_profit_for_remaining_position(
                client,
                order,
                "long_short_mode",
                exchange_size=Decimal("1"),
                algo_rows=[],
            )

        order.refresh_from_db()
        self.assertEqual(order.strategy_tp_algo_ids, ["tp-created-first"])

    def test_rebuild_take_profit_keeps_unconfirmed_stale_ids_for_next_reconcile(self):
        cache.set(
            "trade:inst_rules:BTC-USDT-SWAP",
            {"lotSz": "0.001", "minSz": "0.001", "marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"},
            timeout=300,
        )
        order = Order.objects.create(
            user=self.user,
            binance_order_id="strategy-stale-cancel-unknown",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            initial_stop_price=Decimal("90"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
            strategy_tp_algo_ids=["tp-old"],
        )
        snapshot = OrderStrategySnapshot.objects.create(
            order=order,
            user=self.user,
            strategy_id="stale-cancel-unknown",
            strategy_name="单级止盈",
            strategy_config=[{"profitRR": 1, "reducePosition": 100}],
        )
        order.strategy_snapshot_id = snapshot.id
        order.save(update_fields=["strategy_snapshot_id"])
        client = MagicMock()
        client.place_take_profit_order.return_value = {
            "code": "0",
            "data": [{"algoId": "tp-new", "sCode": "0"}],
        }
        client.get_pending_algo_orders.return_value = {
            "code": "0",
            "data": [
                {
                    "algoId": "tp-new",
                    "instId": "BTC-USDT-SWAP",
                    "algoType": "TAKE_PROFIT_MARKET",
                    "side": "sell",
                    "posSide": "long",
                    "state": "live",
                    "sz": "1",
                    "tpTriggerPx": "110",
                },
                {
                    "algoId": "tp-old",
                    "instId": "BTC-USDT-SWAP",
                    "algoType": "TAKE_PROFIT_MARKET",
                    "side": "sell",
                    "posSide": "long",
                    "state": "live",
                    "sz": "1",
                    "tpTriggerPx": "120",
                },
            ],
        }
        client.cancel_algos.side_effect = BinanceApiError("权限不足", code="-2015")

        changed = _rebuild_take_profit_for_remaining_position(
            client,
            order,
            "long_short_mode",
            exchange_size=Decimal("1"),
            algo_rows=client.get_pending_algo_orders.return_value["data"],
        )

        self.assertTrue(changed)
        order.refresh_from_db()
        self.assertEqual(order.strategy_tp_algo_ids, ["tp-new", "tp-old"])
        client.cancel_algos.assert_called_once_with(
            algo_id="tp-old",
            inst_id="BTC-USDT-SWAP",
        )

    @patch("trading.services.detect_public_egress_ip", return_value="47.236.86.243")
    @patch("trading.services.time.sleep", return_value=None)
    def test_retry_exchange_call_logs_rate_limit_context(self, _mock_sleep, _mock_ip):
        attempts = {"count": 0}

        def get_positions():
            attempts["count"] += 1
            raise Exception("Too many requests per minute")

        with self.assertLogs("trading.services", level="WARNING") as cm:
            with self.assertRaises(Exception):
                _retry_exchange_call(
                    get_positions,
                    retry_label="strategy_engine_load_positions",
                    retry_context={
                        "user_id": self.user.id,
                        "order_id": 321,
                        "symbol": "BTCUSDT",
                        "inst_id": "BTC-USDT-SWAP",
                    },
                )

        # 限频错误不重试：重试会放大请求量并延长封禁，必须快速失败
        self.assertEqual(attempts["count"], 1)
        joined = "\n".join(cm.output)
        self.assertIn("exchange_rate_limit", joined)
        self.assertIn("action=strategy_engine_load_positions", joined)
        self.assertIn("interface=get_positions", joined)
        self.assertIn("attempt=1", joined)
        self.assertIn("final=True", joined)
        self.assertIn(f"user={self.user.id}", joined)
        self.assertIn("order=321", joined)
        self.assertIn("symbol=BTCUSDT", joined)
        self.assertIn("inst_id=BTC-USDT-SWAP", joined)
        self.assertIn("observed_egress_ip=47.236.86.243", joined)

    @patch("trading.services.time.sleep", return_value=None)
    def test_retry_exchange_call_does_not_retry_deterministic_exchange_error(self, _mock_sleep):
        request = MagicMock(side_effect=BinanceApiError("权限不足", code="-2015"))

        with self.assertRaises(BinanceApiError):
            _retry_exchange_call(request)

        self.assertEqual(request.call_count, 1)

    @patch("trading.services.time.sleep", return_value=None)
    def test_retry_exchange_call_retries_normalized_network_error(self, _mock_sleep):
        request = MagicMock(
            side_effect=BinanceApiError("连接 Binance Futures 实盘失败，请稍后重试")
        )

        with self.assertRaises(BinanceApiError):
            _retry_exchange_call(request)

        self.assertEqual(request.call_count, 3)

    @patch("trading.services.time.sleep", return_value=None)
    def test_retry_exchange_call_retries_invalid_exchange_response(self, _mock_sleep):
        request = MagicMock(
            side_effect=BinanceApiError("Binance 返回了无效响应，请稍后重试 (http: 502)")
        )

        with self.assertRaises(BinanceApiError):
            _retry_exchange_call(request)

        self.assertEqual(request.call_count, 3)

    @patch("trading.services.time.sleep", return_value=None)
    def test_retry_exchange_call_retries_transient_exchange_code(self, _mock_sleep):
        request = MagicMock(
            side_effect=BinanceApiError("unexpected response", code="-1006")
        )

        with self.assertRaises(BinanceApiError):
            _retry_exchange_call(request)

        self.assertEqual(request.call_count, 3)

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_limit_order_filled_with_strategy_creates_snapshot(self, mock_client_cls, mock_creds):
        cache.set(
            "trade:inst_rules:BTC-USDT-SWAP",
            {"lotSz": "0.001", "minSz": "0.001", "marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"},
            timeout=300,
        )
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_order.return_value = {
            "code": "0",
            "data": [{"state": "filled", "fillSz": "2", "avgPx": "101"}],
        }
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.place_stop_loss_order.return_value = {"code": "0", "data": [{"algoId": "algo-123"}]}
        mock_client.place_stop_market_order.return_value = {"code": "0", "data": [{"algoId": "algo-123m"}]}
        mock_client.place_take_profit_order.return_value = {"code": "0", "data": [{"algoId": "tp-123"}]}
        mock_client_cls.return_value = mock_client

        limit_order = LimitOrder.objects.create(
            user=self.user,
            binance_order_id="limit-001",
            symbol="BTCUSDT",
            side=0,
            limit_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("2"),
            filled_size=Decimal("0"),
            leverage=10,
            strategy_id="strategy-1",
            strategy_name="稳健通用",
            strategy_config=[{"profitRR": 1, "reducePosition": 50, "stopLossType": "fixedRR", "stopLossRR": 0.5}],
            status=LimitOrder.STATUS_PENDING,
        )

        updated = sync_limit_order_status(limit_order)
        self.assertTrue(updated)
        mock_client.get_order.assert_called_once_with(
            inst_id="BTC-USDT-SWAP",
            order_id="limit-001",
            budget_priority=RequestPriority.BACKGROUND,
        )
        limit_order.refresh_from_db()
        self.assertEqual(limit_order.status, LimitOrder.STATUS_FILLED)
        self.assertIsNotNone(limit_order.order_id)

        order = Order.objects.get(id=limit_order.order_id)
        self.assertEqual(order.strategy_status, Order.STRATEGY_STATUS_RUNNING)
        self.assertIsNotNone(order.strategy_snapshot_id)
        self.assertGreaterEqual(len(order.strategy_tp_algo_ids), 1)
        self.assertTrue(OrderStrategyLog.objects.filter(order=order).exists())

    @patch("trading.services.sync_limit_order_status")
    def test_limit_order_batch_stops_after_shared_rate_limit(self, mock_sync):
        self._create_limit_order_for_chase(order_id="rate-limit-1")
        self._create_limit_order_for_chase(order_id="rate-limit-2")
        mock_sync.side_effect = BinanceApiError(
            "Binance 请求预算保护中",
            code="LOCAL_RATE_BUDGET",
        )

        with patch("trading.services.logger.exception") as exception_log:
            self.assertEqual(sync_all_pending_limit_orders(), 0)
        self.assertEqual(mock_sync.call_count, 1)
        exception_log.assert_not_called()

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_limit_order_batch_stops_when_internal_query_hits_shared_rate_limit(
        self,
        mock_client_cls,
        mock_credentials,
    ):
        self._create_limit_order_for_chase(order_id="internal-rate-limit-1")
        self._create_limit_order_for_chase(order_id="internal-rate-limit-2")
        mock_credentials.return_value = object()
        mock_client = MagicMock()
        mock_client.get_order.side_effect = BinanceApiError(
            "Binance 请求预算保护中",
            code="LOCAL_RATE_BUDGET",
        )
        mock_client_cls.return_value = mock_client

        self.assertEqual(sync_all_pending_limit_orders(), 0)
        self.assertEqual(mock_client.get_order.call_count, 1)

    @patch("trading.services.get_user_binding_generation")
    @patch("trading.services.get_user_binance_credentials")
    def test_limit_order_sync_never_uses_current_key_for_stale_key_order(
        self,
        mock_credentials,
        mock_generation,
    ):
        mock_generation.return_value = ("current-fingerprint", timezone.now() - timedelta(days=1))
        limit_order = LimitOrder.objects.create(
            user=self.user,
            api_key_fingerprint="stale-fingerprint",
            binance_order_id="stale-limit-order",
            symbol="BTCUSDT",
            side=0,
            limit_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=LimitOrder.STATUS_PENDING,
        )

        self.assertFalse(sync_limit_order_status(limit_order))
        mock_credentials.assert_not_called()

    @patch("trading.services.get_user_binding_generation")
    @patch("trading.services.get_user_binance_credentials")
    def test_strategy_and_protection_tasks_skip_stale_key_orders(
        self,
        mock_credentials,
        mock_generation,
    ):
        mock_generation.return_value = ("current-fingerprint", timezone.now() - timedelta(days=1))
        order = Order.objects.create(
            user=self.user,
            api_key_fingerprint="stale-fingerprint",
            binance_order_id="stale-strategy-order",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
        )
        snapshot = OrderStrategySnapshot.objects.create(
            order=order,
            user=self.user,
            strategy_id="stale-strategy",
            strategy_name="旧 Key 策略",
            strategy_config=[],
        )
        order.strategy_snapshot_id = snapshot.id
        order.save(update_fields=["strategy_snapshot_id"])

        self.assertEqual(run_strategy_engine(), 0)
        self.assertEqual(reconcile_open_orders_protection(), 0)
        mock_credentials.assert_not_called()

    def test_strategy_order_propagates_only_shared_rate_limit_errors(self):
        order = Order.objects.create(
            user=self.user,
            binance_order_id="strategy-rate-limit",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
        )
        snapshot = OrderStrategySnapshot.objects.create(
            order=order,
            user=self.user,
            strategy_id="rate-limit-strategy",
            strategy_name="限频测试策略",
            strategy_config=[],
        )
        order.strategy_snapshot_id = snapshot.id
        order.save(update_fields=["strategy_snapshot_id"])
        exchange_context = {
            "client": MagicMock(),
            "pos_mode": "long_short_mode",
            "positions": [],
        }

        with patch(
            "trading.services._get_current_extreme",
            side_effect=BinanceApiError("请求过于频繁", code="-1003"),
        ):
            with self.assertRaises(BinanceApiError):
                _process_single_strategy_order(order, exchange_context=exchange_context)

        with patch(
            "trading.services._get_current_extreme",
            side_effect=ValueError("single order data error"),
        ):
            _process_single_strategy_order(order, exchange_context=exchange_context)

    def test_protection_batch_stops_after_shared_rate_limit(self):
        for index in range(2):
            Order.objects.create(
                user=self.user,
                binance_order_id=f"protection-rate-limit-{index}",
                symbol=f"{index}BTCUSDT",
                side=0,
                open_price=Decimal("100"),
                stop_loss_price=Decimal("90"),
                stop_loss_amount=Decimal("30"),
                size=Decimal("1"),
                leverage=10,
                status=0,
            )

        with (
            patch("trading.services._load_protection_account_snapshot", return_value=MagicMock()),
            patch(
                "trading.services._reconcile_single_order_protection",
                side_effect=BinanceApiError("Binance 请求预算保护中", code="LOCAL_RATE_BUDGET"),
            ) as reconcile,
            patch("trading.services.logger.exception") as exception_log,
        ):
            self.assertEqual(reconcile_open_orders_protection(), 0)

        self.assertEqual(reconcile.call_count, 1)
        exception_log.assert_not_called()

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_limit_order_partial_fill_creates_and_expands_one_protected_position(self, mock_client_cls, mock_creds):
        cache.set(
            "trade:inst_rules:BTC-USDT-SWAP",
            {"lotSz": "0.001", "minSz": "0.001", "marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"},
            timeout=300,
        )
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": []}
        mock_client.place_stop_market_order.side_effect = [
            {"code": "0", "data": [{"algoId": "partial-stop-1"}]},
            {"code": "0", "data": [{"algoId": "partial-stop-2"}]},
        ]
        mock_client.get_order.side_effect = [
            {"code": "0", "data": [{"state": "partially_filled", "accFillSz": "0.75", "avgPx": "100"}]},
            {"code": "0", "data": [{"state": "partially_filled", "accFillSz": "1.25", "avgPx": "100.4"}]},
        ]
        mock_client_cls.return_value = mock_client
        limit_order = LimitOrder.objects.create(
            user=self.user,
            binance_order_id="limit-partial-1",
            symbol="BTCUSDT",
            side=0,
            limit_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("2"),
            leverage=10,
            status=LimitOrder.STATUS_PENDING,
        )

        self.assertTrue(sync_limit_order_status(limit_order))
        limit_order.refresh_from_db()
        first_order_id = limit_order.order_id
        order = Order.objects.get(id=first_order_id)
        self.assertEqual(limit_order.status, LimitOrder.STATUS_PENDING)
        self.assertEqual(order.size, Decimal("0.75"))
        self.assertEqual(order.binance_stop_market_order_id, "partial-stop-1")

        self.assertTrue(sync_limit_order_status(limit_order))
        limit_order.refresh_from_db()
        order.refresh_from_db()
        self.assertEqual(limit_order.order_id, first_order_id)
        self.assertEqual(Order.objects.filter(binance_order_id="limit-partial-1").count(), 1)
        self.assertEqual(order.size, Decimal("1.25"))
        self.assertEqual(order.open_price, Decimal("100.4"))
        self.assertEqual(order.binance_stop_market_order_id, "partial-stop-2")

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_limit_partial_fill_records_pending_protection_when_position_mode_query_fails(
        self,
        mock_client_cls,
        mock_creds,
    ):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_order.return_value = {
            "code": "0",
            "data": [{"state": "partially_filled", "accFillSz": "1", "avgPx": "100"}],
        }
        mock_client.get_account_config.side_effect = BinanceApiError("temporary network failure")
        mock_client_cls.return_value = mock_client
        limit_order = self._create_limit_order_for_chase(order_id="limit-pos-mode-failure")

        self.assertTrue(sync_limit_order_status(limit_order))
        limit_order.refresh_from_db()
        order = Order.objects.get(id=limit_order.order_id)
        self.assertEqual(order.stop_protection_status, Order.STOP_PROTECTION_PENDING)
        self.assertIn("temporary network failure", order.stop_protection_error)
        mock_client.place_stop_market_order.assert_not_called()

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_limit_fill_snapshot_cannot_shrink_position_or_stop_protection(self, mock_client_cls, mock_creds):
        cache.set(
            "trade:inst_rules:BTC-USDT-SWAP",
            {"lotSz": "0.001", "minSz": "0.001", "marketLotSz": "0.001", "marketMinSz": "0.001", "tickSz": "0.1"},
            timeout=300,
        )
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_order.return_value = {
            "code": "0",
            "data": [{"state": "partially_filled", "accFillSz": "1", "avgPx": "100"}],
        }
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": []}
        mock_client.place_stop_market_order.return_value = {"code": "0", "data": [{"algoId": "monotonic-stop"}]}
        mock_client_cls.return_value = mock_client
        limit_order = self._create_limit_order_for_chase(order_id="limit-monotonic-fill")
        limit_order.filled_size = Decimal("1.5")
        limit_order.save(update_fields=["filled_size"])
        order = Order.objects.create(
            user=self.user,
            binance_order_id=limit_order.binance_order_id,
            symbol=limit_order.symbol,
            side=limit_order.side,
            open_price=Decimal("100"),
            initial_stop_price=limit_order.stop_loss_price,
            stop_loss_price=limit_order.stop_loss_price,
            current_stop_price=limit_order.stop_loss_price,
            stop_loss_amount=limit_order.stop_loss_amount,
            size=Decimal("1.5"),
            exchange_size=Decimal("1.5"),
            binance_stop_market_order_id="confirmed-stop-for-1.5",
            leverage=limit_order.leverage,
            status=0,
        )
        limit_order.order = order
        limit_order.save(update_fields=["order"])

        sync_limit_order_status(limit_order)

        limit_order.refresh_from_db()
        order.refresh_from_db()
        self.assertEqual(limit_order.filled_size, Decimal("1.5"))
        self.assertEqual(order.size, Decimal("1.5"))
        self.assertEqual(order.binance_stop_market_order_id, "confirmed-stop-for-1.5")
        mock_client.place_stop_market_order.assert_not_called()

    def test_strategy_crud_api(self):
        save_resp = self.client.post(
            "/v1/strategy/save",
            {
                "name": "测试策略A",
                "levels": [
                    {"profitRR": 1.0, "reducePosition": 50, "stopLossType": "fixedRR", "stopLossRR": 0.5},
                    {"profitRR": 2.0, "reducePosition": 50, "stopLossType": "none"},
                ],
            },
            format="json",
        )
        self.assertEqual(save_resp.status_code, status.HTTP_200_OK)
        strategy_id = save_resp.data["data"]["id"]
        self.assertTrue(Strategy.objects.filter(id=strategy_id, user=self.user).exists())

        list_resp = self.client.get("/v1/strategy/list")
        self.assertEqual(list_resp.status_code, status.HTTP_200_OK)
        self.assertGreaterEqual(len(list_resp.data["data"]), 1)

        set_active_resp = self.client.post("/v1/strategy/set-active", {"strategy_id": strategy_id}, format="json")
        self.assertEqual(set_active_resp.status_code, status.HTTP_200_OK)
        self.assertTrue(Strategy.objects.get(id=strategy_id).is_active)

        delete_resp = self.client.post("/v1/strategy/delete", {"strategy_id": strategy_id}, format="json")
        self.assertEqual(delete_resp.status_code, status.HTTP_200_OK)
        self.assertFalse(Strategy.objects.filter(id=strategy_id).exists())

    @patch("trading.services._reconcile_single_order_protection", return_value=1)
    @patch("trading.services._load_protection_account_snapshot")
    def test_reconcile_open_orders_continues_after_one_account_snapshot_fails(
        self,
        mock_load_snapshot,
        mock_reconcile_order,
    ):
        second_user = User.objects.create_user(
            email="trade_test_second@example.com",
            password="test-only-password",
        )
        failed_order = Order.objects.create(
            user=self.user,
            binance_order_id="snapshot-failed-account",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )
        healthy_order = Order.objects.create(
            user=second_user,
            binance_order_id="snapshot-healthy-account",
            symbol="ETHUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )
        healthy_snapshot = MagicMock()

        def load_snapshot(order, _inst_ids, _account_identity, **_generation):
            if order.user_id == failed_order.user_id:
                raise BinanceApiError("temporary account snapshot failure")
            return healthy_snapshot

        mock_load_snapshot.side_effect = load_snapshot

        repaired = reconcile_open_orders_protection()

        self.assertEqual(repaired, 1)
        self.assertEqual(mock_load_snapshot.call_count, 2)
        mock_reconcile_order.assert_called_once_with(healthy_order, healthy_snapshot)
        self.assertNotEqual(failed_order.user_id, healthy_order.user_id)

    @patch("trading.services._load_protection_account_snapshot")
    def test_reconcile_open_orders_skips_account_while_user_mutation_is_running(
        self,
        mock_load_snapshot,
    ):
        Order.objects.create(
            user=self.user,
            binance_order_id="locked-protection-account",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )

        with user_trading_activity_lock(f"user:{self.user.id}") as locked:
            repaired = reconcile_open_orders_protection()

        self.assertTrue(locked)
        self.assertEqual(repaired, 0)
        mock_load_snapshot.assert_not_called()

    @patch("trading.services._process_single_strategy_order")
    @patch("trading.services.get_user_binance_credentials")
    def test_strategy_engine_skips_account_while_user_mutation_is_running(
        self,
        mock_credentials,
        mock_process,
    ):
        strategy = self._create_strategy("锁测试策略")
        order = Order.objects.create(
            user=self.user,
            binance_order_id="locked-strategy-account",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
        )
        snapshot = OrderStrategySnapshot.objects.create(
            order=order,
            user=self.user,
            strategy_id=str(strategy.id),
            strategy_name=strategy.name,
            strategy_config=[],
        )
        order.strategy_snapshot_id = snapshot.id
        order.save(update_fields=["strategy_snapshot_id"])

        with user_trading_activity_lock(f"user:{self.user.id}") as locked:
            processed = run_strategy_engine()

        self.assertTrue(locked)
        self.assertEqual(processed, 0)
        mock_credentials.assert_not_called()
        mock_process.assert_not_called()

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_reconcile_open_orders_rebuilds_protection_when_position_reduced(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [
                {
                    "instId": "BTC-USDT-SWAP",
                    "posSide": "long",
                    "pos": "0.5",
                    "last": "108",
                    "markPx": "108",
                }
            ],
        }
        mock_client.get_pending_algo_orders.return_value = {
            "code": "0",
            "data": [
                {
                    "algoId": "sl-new",
                    "instId": "BTC-USDT-SWAP",
                    "algoType": "STOP_MARKET",
                    "side": "sell",
                    "posSide": "long",
                    "state": "live",
                    "sz": "0.5",
                    "slTriggerPx": "90",
                },
                {
                    "algoId": "slm-new",
                    "instId": "BTC-USDT-SWAP",
                    "algoType": "STOP_MARKET",
                    "side": "sell",
                    "posSide": "long",
                    "state": "live",
                    "sz": "0.5",
                    "slTriggerPx": "90",
                },
            ],
        }
        mock_client.place_stop_market_order.return_value = {"code": "0", "data": [{"algoId": "sl-created-m", "sCode": "0"}]}
        mock_client.place_take_profit_order.return_value = {"code": "0", "data": [{"algoId": "tp-new", "sCode": "0"}]}
        mock_client_cls.return_value = mock_client

        order = Order.objects.create(
            user=self.user,
            binance_order_id="reconcile-1",
            binance_stop_order_id="sl-old",
            binance_stop_market_order_id="slm-new",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            initial_stop_price=Decimal("90"),
            stop_loss_price=Decimal("90"),
            current_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
            strategy_tp_algo_ids=["tp-old"],
        )
        snapshot = OrderStrategySnapshot.objects.create(
            order=order,
            user=self.user,
            strategy_id="s-reconcile",
            strategy_name="测试策略",
            strategy_config=[
                {"profitRR": 1, "reducePosition": 50, "stopLossType": "fixedRR", "stopLossRR": 0.5},
            ],
        )
        order.strategy_snapshot_id = snapshot.id
        order.save(update_fields=["strategy_snapshot_id"])
        Order.objects.filter(id=order.id).update(created_at=timezone.now() - timedelta(minutes=5))
        order.refresh_from_db()

        repaired = reconcile_open_orders_protection()
        self.assertGreaterEqual(repaired, 1)
        order.refresh_from_db()
        self.assertEqual(order.size, Decimal("1"))
        self.assertEqual(order.exchange_size, Decimal("0.5"))
        self.assertEqual(order.binance_stop_order_id, "")
        self.assertEqual(order.binance_stop_market_order_id, "slm-new")
        self.assertEqual(order.strategy_tp_algo_ids, [])
        mock_client.place_stop_loss_order.assert_not_called()
        mock_client.place_take_profit_order.assert_not_called()
        self.assertTrue(mock_client.get_pending_algo_orders.call_args_list)
        self.assertTrue(
            all(
                item.kwargs.get("inst_id") == "BTC-USDT-SWAP"
                for item in mock_client.get_pending_algo_orders.call_args_list
            )
        )

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_reconcile_open_orders_skips_manual_tp_sl_management(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client_cls.return_value = mock_client

        Order.objects.create(
            user=self.user,
            binance_order_id="manual-tp-sl-1",
            symbol="BTCUSDT",
            side=1,
            open_price=Decimal("62437.5"),
            initial_stop_price=Decimal("62760"),
            stop_loss_price=Decimal("62760"),
            current_stop_price=Decimal("62760"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("0.312"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_CANCELLED,
            strategy_tp_algo_ids=[],
            binance_stop_order_id="",
            binance_stop_market_order_id="",
            stop_protection_status=Order.STOP_PROTECTION_PENDING,
            stop_protection_error=MANUAL_TP_SL_MANAGEMENT_ERROR,
        )

        repaired = reconcile_open_orders_protection()

        self.assertEqual(repaired, 0)
        mock_creds.assert_not_called()
        mock_client_cls.assert_not_called()

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_reconcile_open_orders_protects_external_manual_added_position_without_changing_initial_size(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [
                {
                    "instId": "BTC-USDT-SWAP",
                    "posSide": "long",
                    "pos": "1.5",
                    "last": "108",
                    "markPx": "108",
                }
            ],
        }
        mock_client.get_pending_algo_orders.side_effect = [
            {
                "code": "0",
                "data": [
                    {
                        "algoId": "sl-old",
                        "instId": "BTC-USDT-SWAP",
                        "algoType": "STOP_MARKET",
                        "side": "sell",
                        "posSide": "long",
                        "state": "live",
                        "sz": "1",
                        "slTriggerPx": "90",
                    }
                ],
            },
            {
                "code": "0",
                "data": [
                    {
                        "algoId": "sl-expanded-m",
                        "instId": "BTC-USDT-SWAP",
                        "algoType": "STOP_MARKET",
                        "side": "sell",
                        "posSide": "long",
                        "state": "live",
                        "sz": "1.5",
                        "slTriggerPx": "90",
                    }
                ],
            },
        ]
        mock_client.place_stop_market_order.return_value = {"code": "0", "data": [{"algoId": "sl-expanded-m", "sCode": "0"}]}
        mock_client.place_take_profit_order.return_value = {"code": "0", "data": [{"algoId": "tp-new", "sCode": "0"}]}
        mock_client_cls.return_value = mock_client

        order = Order.objects.create(
            user=self.user,
            binance_order_id="reconcile-mixed-1",
            binance_stop_order_id="sl-old",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            initial_stop_price=Decimal("90"),
            stop_loss_price=Decimal("90"),
            current_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
            strategy_tp_algo_ids=["tp-old"],
        )

        repaired = reconcile_open_orders_protection()
        self.assertEqual(repaired, 1)
        order.refresh_from_db()
        self.assertEqual(order.size, Decimal("1"))
        self.assertEqual(order.exchange_size, Decimal("1.5"))
        self.assertTrue(order.has_manual_addition)
        self.assertEqual(order.binance_stop_order_id, "")
        self.assertEqual(order.binance_stop_market_order_id, "sl-expanded-m")
        self.assertEqual(order.strategy_tp_algo_ids, ["tp-old"])
        mock_client.place_stop_loss_order.assert_not_called()
        mock_client.place_take_profit_order.assert_not_called()

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_reconcile_open_orders_closes_fully_offset_order_before_attaching_external_reopen(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [
                {
                    "instId": "BTC-USDT-SWAP",
                    "posSide": "long",
                    "pos": "1",
                    "last": "108",
                    "markPx": "108",
                }
            ],
        }
        mock_client.get_pending_algo_orders.return_value = {
            "code": "0",
            "data": [
                {
                    "algoId": "sl-old",
                    "instId": "BTC-USDT-SWAP",
                    "algoType": "STOP_MARKET",
                    "side": "sell",
                    "posSide": "long",
                    "state": "live",
                    "sz": "1",
                    "slTriggerPx": "90",
                }
            ],
        }
        mock_client.cancel_algos.return_value = {"code": "0", "data": [{"algoId": "sl-old"}]}
        mock_client_cls.return_value = mock_client

        order = Order.objects.create(
            user=self.user,
            binance_order_id="reconcile-fully-offset-1",
            binance_stop_order_id="sl-old",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            initial_stop_price=Decimal("90"),
            stop_loss_price=Decimal("90"),
            current_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
        )
        close_trade_time = str(int((order.created_at + timedelta(seconds=1)).timestamp() * 1000))
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": "manual-close-1",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "fillSz": "1",
                    "fillPx": "109",
                    "realizedPnl": "9",
                    "fee": "0.2",
                    "time": close_trade_time,
                }
            ],
        }

        repaired = reconcile_open_orders_protection()
        self.assertEqual(repaired, 1)
        order.refresh_from_db()
        self.assertEqual(order.status, 1)
        self.assertEqual(order.close_binance_order_id, "manual-close-1")
        self.assertEqual(order.exchange_size, Decimal("0"))
        mock_client.place_stop_loss_order.assert_not_called()

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_strategy_engine_closes_fully_offset_order_before_managing_external_reopen(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{"instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "1", "last": "112", "markPx": "112"}],
        }
        mock_client.cancel_algos.return_value = {"code": "0", "data": [{"algoId": "sl-old"}]}
        mock_client_cls.return_value = mock_client

        order = Order.objects.create(
            user=self.user,
            binance_order_id="engine-fully-offset-1",
            binance_stop_order_id="sl-old",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            current_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
        )
        close_trade_time = str(int((order.created_at + timedelta(seconds=1)).timestamp() * 1000))
        mock_client.get_user_trades.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": "manual-close-2",
                    "instId": "BTC-USDT-SWAP",
                    "side": "sell",
                    "fillSz": "1",
                    "fillPx": "111",
                    "realizedPnl": "11",
                    "fee": "0.2",
                    "time": close_trade_time,
                }
            ],
        }
        snapshot = OrderStrategySnapshot.objects.create(
            order=order,
            user=self.user,
            strategy_id="s-engine-offset",
            strategy_name="测试策略",
            strategy_config=[
                {"profitRR": 1, "reducePosition": 50, "stopLossType": "fixedRR", "stopLossRR": 0.5},
            ],
        )
        order.strategy_snapshot_id = snapshot.id
        order.save(update_fields=["strategy_snapshot_id"])

        processed = run_strategy_engine()
        self.assertEqual(processed, 0)
        order.refresh_from_db()
        self.assertEqual(order.status, 1)
        self.assertEqual(order.close_binance_order_id, "manual-close-2")
        mock_client.get_mark_price_candles.assert_not_called()

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_reconcile_open_orders_deduplicates_stop_loss_by_business_signature(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [
                {
                    "instId": "BTC-USDT-SWAP",
                    "posSide": "long",
                    "pos": "0.5",
                    "last": "108",
                    "markPx": "108",
                }
            ],
        }
        mock_client.get_pending_algo_orders.return_value = {
            "code": "0",
            "data": [
                {"algoId": "sl-a", "instId": "BTC-USDT-SWAP", "algoType": "STOP", "side": "sell", "posSide": "long", "state": "live", "sz": "0.5", "slTriggerPx": "90"},
                {"algoId": "sl-b", "instId": "BTC-USDT-SWAP", "algoType": "STOP", "side": "sell", "posSide": "long", "state": "live", "sz": "0.5", "slTriggerPx": "90"},
                {"algoId": "slm-a", "instId": "BTC-USDT-SWAP", "algoType": "STOP_MARKET", "side": "sell", "posSide": "long", "state": "live", "sz": "0.5", "slTriggerPx": "90"},
            ],
        }
        mock_client.cancel_algos.return_value = {"code": "0", "data": [{"algoId": "sl-b"}]}
        mock_client_cls.return_value = mock_client

        order = Order.objects.create(
            user=self.user,
            binance_order_id="reconcile-duplicate-stop",
            binance_stop_order_id="sl-missing",
            binance_stop_market_order_id="slm-a",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            initial_stop_price=Decimal("90"),
            stop_loss_price=Decimal("90"),
            current_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )

        repaired = reconcile_open_orders_protection()
        self.assertEqual(repaired, 1)
        order.refresh_from_db()
        self.assertEqual(order.size, Decimal("1"))
        self.assertEqual(order.binance_stop_order_id, "")
        self.assertEqual(order.binance_stop_market_order_id, "slm-a")
        mock_client.place_stop_loss_order.assert_not_called()
        self.assertEqual(mock_client.cancel_algos.call_count, 2)

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_reconcile_open_orders_defers_new_stop_on_old_position_when_visibility_delayed(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{"instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "0.5", "last": "108", "markPx": "108"}],
        }
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": []}
        mock_client_cls.return_value = mock_client

        order = Order.objects.create(
            user=self.user,
            binance_order_id="recent-stop-visibility",
            binance_stop_order_id="sl-newly-created",
            binance_stop_market_order_id="slm-newly-created",
            stop_loss_order_created_at=timezone.now(),
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            initial_stop_price=Decimal("90"),
            stop_loss_price=Decimal("90"),
            current_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("0.5"),
            leverage=10,
            status=0,
        )
        Order.objects.filter(id=order.id).update(created_at=timezone.now() - timedelta(days=1))

        repaired = reconcile_open_orders_protection()
        self.assertEqual(repaired, 0)
        mock_client.place_stop_loss_order.assert_not_called()
        mock_client.cancel_algos.assert_not_called()

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    @patch("trading.services.time.sleep", return_value=None)
    def test_reconcile_stop_trigger_confirms_close_with_symbol_scoped_positions(
        self,
        _mock_sleep,
        mock_client_cls,
        mock_creds,
    ):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {
            "code": "0",
            "data": [{"posMode": "long_short_mode"}],
        }
        mock_client.get_positions.side_effect = [
            {
                "code": "0",
                "data": [
                    {
                        "instId": "BTC-USDT-SWAP",
                        "posSide": "long",
                        "pos": "1",
                        "last": "89",
                        "markPx": "89",
                    }
                ],
            },
            {"code": "0", "data": []},
            {"code": "0", "data": []},
        ]
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": []}
        mock_client.get_pending_orders.return_value = {"code": "0", "data": []}
        mock_client.get_user_trades.return_value = {"code": "0", "data": []}
        mock_client.close_position.return_value = {
            "code": "0",
            "data": [
                {
                    "ordId": "emergency-reconcile-close-1",
                    "avgPx": "89",
                    "fillSz": "1",
                    "state": "filled",
                    "sCode": "0",
                }
            ],
        }
        mock_client_cls.return_value = mock_client
        order = Order.objects.create(
            user=self.user,
            binance_order_id="stop-trigger-symbol-scope",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )

        with self.captureOnCommitCallbacks(execute=True):
            repaired = reconcile_open_orders_protection()

        self.assertEqual(repaired, 1)
        mock_client.close_position.assert_called_once_with(
            inst_id="BTC-USDT-SWAP",
            pos_side="long",
            expected_side="long",
        )
        self.assertEqual(
            mock_client.get_positions.call_args_list,
            [
                call("SWAP", budget_priority=RequestPriority.CRITICAL),
                call(
                    "SWAP",
                    "BTC-USDT-SWAP",
                    budget_priority=RequestPriority.CRITICAL,
                ),
                call(
                    "SWAP",
                    "BTC-USDT-SWAP",
                    budget_priority=RequestPriority.CRITICAL,
                ),
            ],
        )
        order.refresh_from_db()
        self.assertIn("交易所已确认仓位平清", order.stop_protection_error)
        self.assertEqual(order.close_binance_order_id, "emergency-reconcile-close-1")
        self.assertEqual(order.status, 1)
        self.assertIsNotNone(order.closed_at)
        self.assertEqual(order.close_price, Decimal("89"))
        self.assertEqual(order.exchange_size, Decimal("0"))
        self.assertFalse(order.has_manual_addition)
        self.assertEqual(order.settlement_status, Order.SETTLEMENT_STATUS_PENDING)
        event = TradeNotificationEvent.objects.get(order=order)
        self.assertEqual(event.event_type, TradeNotificationEvent.TYPE_STOP_LOSS)

    @patch("positions.cleanup.cleanup_closed_order_exchange_artifacts", side_effect=RuntimeError("cleanup crashed"))
    def test_emergency_close_persists_confirmed_close_when_artifact_cleanup_crashes(
        self,
        _mock_cleanup,
    ):
        from trading.services import finalize_confirmed_emergency_close

        order = Order.objects.create(
            user=self.user,
            binance_order_id="emergency-cleanup-failure",
            binance_stop_order_id="residual-stop",
            strategy_tp_algo_ids=["residual-tp"],
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )

        finalize_confirmed_emergency_close(
            order,
            MagicMock(),
            close_payload={
                "data": [{"ordId": "emergency-close", "avgPx": "89", "state": "filled"}],
            },
            trigger_price=Decimal("90"),
        )

        order.refresh_from_db()
        self.assertEqual(order.status, 1)
        self.assertEqual(order.close_binance_order_id, "emergency-close")
        self.assertEqual(order.binance_stop_order_id, "residual-stop")
        self.assertEqual(order.strategy_tp_algo_ids, ["residual-tp"])

    @patch("common.binance.time.sleep")
    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_reconcile_open_orders_marks_stop_loss_pending_and_recovered(
        self,
        mock_client_cls,
        mock_creds,
        _mock_sleep,
    ):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{"instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "1", "last": "108", "markPx": "108"}],
        }
        mock_client.get_pending_algo_orders.return_value = {"code": "0", "data": []}
        mock_client.place_stop_market_order.side_effect = [
            BinanceApiError(
                "network timeout while creating stop loss",
                code="-1007",
                outcome_unknown=True,
            ),
            {"code": "0", "data": [{"algoId": "sl-restored-m", "sCode": "0"}]},
        ]
        mock_client_cls.return_value = mock_client

        order = Order.objects.create(
            user=self.user,
            binance_order_id="reconcile-stop-recover-1",
            binance_stop_order_id="sl-old",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            initial_stop_price=Decimal("90"),
            stop_loss_price=Decimal("90"),
            current_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
        )
        snapshot = OrderStrategySnapshot.objects.create(
            order=order,
            user=self.user,
            strategy_id="s-stop-recover",
            strategy_name="测试策略",
            strategy_config=[],
        )
        order.strategy_snapshot_id = snapshot.id
        order.save(update_fields=["strategy_snapshot_id"])
        Order.objects.filter(id=order.id).update(created_at=timezone.now() - timedelta(minutes=5))
        order.refresh_from_db()

        repaired = reconcile_open_orders_protection()
        self.assertEqual(repaired, 0)
        order.refresh_from_db()
        self.assertEqual(order.binance_stop_order_id, "sl-old")
        pending_log = OrderStrategyLog.objects.filter(order=order, snapshot=snapshot).order_by("-created_at").first()
        self.assertIsNotNone(pending_log)
        self.assertEqual(pending_log.behavior_desc, "止损保护待恢复")
        self.assertIn("network timeout", pending_log.error or "")

        Order.objects.filter(id=order.id).update(
            stop_protection_last_retry_at=timezone.now() - timedelta(seconds=11)
        )
        repaired = reconcile_open_orders_protection()
        self.assertGreaterEqual(repaired, 1)
        order.refresh_from_db()
        self.assertEqual(order.binance_stop_order_id, "")
        self.assertEqual(order.binance_stop_market_order_id, "sl-restored-m")
        last_two_desc = list(
            OrderStrategyLog.objects.filter(order=order, snapshot=snapshot)
            .order_by("-created_at")
            .values_list("behavior_desc", flat=True)[:2]
        )
        self.assertEqual(last_two_desc[0], "止损保护已恢复")
        self.assertEqual(last_two_desc[1], "止损保护待恢复")

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_reconcile_open_orders_deduplicates_take_profit_by_business_signature(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{"instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "1", "last": "108", "markPx": "108"}],
        }
        mock_client.get_pending_algo_orders.return_value = {
            "code": "0",
            "data": [
                {"algoId": "sl-a", "instId": "BTC-USDT-SWAP", "algoType": "STOP", "side": "sell", "posSide": "long", "state": "live", "sz": "1", "slTriggerPx": "90"},
                {"algoId": "slm-a", "instId": "BTC-USDT-SWAP", "algoType": "STOP_MARKET", "side": "sell", "posSide": "long", "state": "live", "sz": "1", "slTriggerPx": "87.5"},
                {"algoId": "tp-a", "instId": "BTC-USDT-SWAP", "algoType": "TAKE_PROFIT_MARKET", "side": "sell", "posSide": "long", "state": "live", "sz": "0.5", "tpTriggerPx": "110"},
                {"algoId": "tp-b", "instId": "BTC-USDT-SWAP", "algoType": "TAKE_PROFIT_MARKET", "side": "sell", "posSide": "long", "state": "live", "sz": "0.5", "tpTriggerPx": "110"},
            ],
        }
        mock_client.cancel_algos.return_value = {"code": "0", "data": [{"algoId": "tp-b"}]}
        mock_client_cls.return_value = mock_client

        order = Order.objects.create(
            user=self.user,
            binance_order_id="reconcile-duplicate-tp",
            binance_stop_order_id="sl-a",
            binance_stop_market_order_id="slm-a",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            initial_stop_price=Decimal("90"),
            stop_loss_price=Decimal("90"),
            current_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
            strategy_tp_algo_ids=["tp-missing"],
        )
        snapshot = OrderStrategySnapshot.objects.create(
            order=order,
            user=self.user,
            strategy_id="s-tp-dedupe",
            strategy_name="测试策略",
            strategy_config=[{"profitRR": 1, "reducePosition": 50, "stopLossType": "none"}],
        )
        order.strategy_snapshot_id = snapshot.id
        order.save(update_fields=["strategy_snapshot_id"])

        repaired = reconcile_open_orders_protection()
        self.assertGreaterEqual(repaired, 1)
        order.refresh_from_db()
        self.assertEqual(order.strategy_tp_algo_ids, ["tp-a"])
        mock_client.place_take_profit_order.assert_not_called()
        self.assertIn(
            call(algo_id="tp-b", inst_id="BTC-USDT-SWAP"),
            mock_client.cancel_algos.call_args_list,
        )

    @patch("trading.services.get_user_binance_credentials")
    @patch("trading.services.BinanceFuturesClient")
    def test_reconcile_open_orders_does_not_recreate_reached_missing_take_profit_level(self, mock_client_cls, mock_creds):
        mock_creds.return_value = object()
        mock_client = MagicMock()
        mock_client.get_account_config.return_value = {"code": "0", "data": [{"posMode": "long_short_mode"}]}
        mock_client.get_positions.return_value = {
            "code": "0",
            "data": [{"instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "0.5", "last": "115", "markPx": "115"}],
        }
        mock_client.get_pending_algo_orders.return_value = {
            "code": "0",
            "data": [
                {"algoId": "sl-a", "instId": "BTC-USDT-SWAP", "algoType": "STOP_MARKET", "side": "sell", "posSide": "long", "state": "live", "sz": "0.5", "slTriggerPx": "90"},
            ],
        }
        mock_client.place_take_profit_order.return_value = {"code": "0", "data": [{"algoId": "tp-l2-new", "sCode": "0"}]}
        mock_client_cls.return_value = mock_client

        order = Order.objects.create(
            user=self.user,
            binance_order_id="reconcile-reached-tp",
            binance_stop_order_id="sl-a",
            symbol="BTCUSDT",
            side=0,
            open_price=Decimal("100"),
            initial_stop_price=Decimal("90"),
            stop_loss_price=Decimal("90"),
            current_stop_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
            strategy_status=Order.STRATEGY_STATUS_RUNNING,
            strategy_tp_algo_ids=["tp-l1-old", "tp-l2-old"],
        )
        snapshot = OrderStrategySnapshot.objects.create(
            order=order,
            user=self.user,
            strategy_id="s-tp-reached",
            strategy_name="测试策略",
            strategy_config=[
                {"profitRR": 1, "reducePosition": 50, "stopLossType": "none"},
                {"profitRR": 2, "reducePosition": 50, "stopLossType": "none"},
            ],
        )
        order.strategy_snapshot_id = snapshot.id
        order.save(update_fields=["strategy_snapshot_id"])
        OrderStrategyLog.objects.create(
            order=order,
            snapshot=snapshot,
            behavior_desc="L1 达到 1R，触发减仓条件 50%",
            result=OrderStrategyLog.RESULT_SUCCESS,
            trigger_r=Decimal("1"),
        )

        repaired = reconcile_open_orders_protection()
        self.assertGreaterEqual(repaired, 1)
        order.refresh_from_db()
        self.assertEqual(order.strategy_tp_algo_ids, ["tp-l2-new"])
        mock_client.place_take_profit_order.assert_called_once()
        self.assertEqual(Decimal(mock_client.place_take_profit_order.call_args.kwargs["trigger_price"]), Decimal("120"))


class ConcurrencyPositionCapTests(APITestCase):
    """全局持仓上限：持仓 + 待成交限价单合计最多 2 个。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(email="cap_limit@example.com", password="123456")
        self.exchange_client = MagicMock()
        self.exchange_client.get_positions.return_value = {"data": []}
        self.exchange_client.get_pending_orders.return_value = {"data": []}

    def test_exchange_positions_across_symbols_enforce_global_cap(self):
        self.exchange_client.get_positions.return_value = {
            "data": [
                {"instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "1"},
                {"instId": "ETH-USDT-SWAP", "posSide": "short", "pos": "1"},
            ]
        }

        error = check_duplicate_order(self.user, "SOLUSDT", client=self.exchange_client)

        self.assertIn("交易所当前持仓及普通挂单共 2 个", error)

    def test_exchange_position_and_pending_order_enforce_global_cap(self):
        self.exchange_client.get_positions.return_value = {
            "data": [{"instId": "BTC-USDT-SWAP", "posSide": "long", "pos": "1"}]
        }
        self.exchange_client.get_pending_orders.return_value = {
            "data": [{"ordId": "pending-eth", "instId": "ETH-USDT-SWAP"}]
        }

        error = check_duplicate_order(self.user, "SOLUSDT", client=self.exchange_client)

        self.assertIn("交易所当前持仓及普通挂单共 2 个", error)

    def _create_open_order(self, symbol: str, binance_order_id: str) -> Order:
        return Order.objects.create(
            user=self.user,
            binance_order_id=binance_order_id,
            symbol=symbol,
            side=0,
            open_price=Decimal("100"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=0,
        )

    def _create_pending_limit(self, symbol: str, binance_order_id: str) -> LimitOrder:
        return LimitOrder.objects.create(
            user=self.user,
            binance_order_id=binance_order_id,
            symbol=symbol,
            side=0,
            limit_price=Decimal("95"),
            stop_loss_price=Decimal("90"),
            stop_loss_amount=Decimal("30"),
            size=Decimal("1"),
            leverage=10,
            status=LimitOrder.STATUS_PENDING,
        )

    def test_stale_local_positions_do_not_block_when_exchange_confirms_no_exposure(self):
        self._create_open_order("BTCUSDT", "cap-open-1")
        self._create_open_order("ETHUSDT", "cap-open-2")
        error = check_duplicate_order(self.user, "SOLUSDT", client=self.exchange_client)
        self.assertIsNone(error)
        self.exchange_client.get_positions.assert_called_once()

    def test_stale_local_position_and_limit_do_not_override_exchange_snapshot(self):
        self._create_open_order("BTCUSDT", "cap-open-1")
        self._create_pending_limit("ETHUSDT", "cap-limit-1")
        error = check_duplicate_order(self.user, "SOLUSDT", client=self.exchange_client)
        self.assertIsNone(error)

    def test_exchange_failure_blocks_when_local_records_cannot_be_verified(self):
        self._create_open_order("BTCUSDT", "cap-open-1")
        self._create_open_order("ETHUSDT", "cap-open-2")
        self.exchange_client.get_positions.side_effect = BinanceApiError("temporary outage")

        error = check_duplicate_order(self.user, "SOLUSDT", client=self.exchange_client)

        self.assertIn("暂时无法确认交易所持仓状态", error)

    def test_one_open_position_still_allows_new_entry(self):
        self._create_open_order("BTCUSDT", "cap-open-1")
        self.assertIsNone(check_duplicate_order(self.user, "SOLUSDT", client=self.exchange_client))

    def test_cancelled_limit_does_not_count_toward_cap(self):
        self._create_open_order("BTCUSDT", "cap-open-1")
        limit = self._create_pending_limit("ETHUSDT", "cap-limit-1")
        limit.status = LimitOrder.STATUS_CANCELLED
        limit.save(update_fields=["status", "updated_at"])
        self.assertIsNone(check_duplicate_order(self.user, "SOLUSDT", client=self.exchange_client))
