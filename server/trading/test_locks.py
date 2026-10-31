from contextlib import contextmanager
from unittest.mock import MagicMock, patch

from django.core.cache import cache
from django.test import SimpleTestCase

from trading.locks import (
    api_binding_lifecycle_lock,
    serialized_exchange_mutation,
    trade_submit_lock,
    user_trading_activity_lock,
)


class TradingLockTests(SimpleTestCase):
    def test_api_binding_lifecycle_lock_serializes_same_web_user(self):
        with api_binding_lifecycle_lock(42) as first:
            with api_binding_lifecycle_lock(42) as duplicate:
                with api_binding_lifecycle_lock(43) as other_user:
                    self.assertTrue(first)
                    self.assertFalse(duplicate)
                    self.assertTrue(other_user)

    def setUp(self):
        cache.clear()

    def test_local_cache_fallback_serializes_same_account_and_symbol(self):
        with trade_submit_lock("open", "account-a", "BTCUSDT") as first:
            with trade_submit_lock("chase", "account-a", "BTCUSDT") as second:
                self.assertTrue(first)
                self.assertFalse(second)
        with trade_submit_lock("limit", "account-a", "BTCUSDT") as third:
            self.assertTrue(third)

    def test_account_activity_lock_serializes_entry_and_capital_actions(self):
        with user_trading_activity_lock("api-key:fingerprint-a") as entry_locked:
            with user_trading_activity_lock("api-key:fingerprint-a") as capital_locked:
                self.assertTrue(entry_locked)
                self.assertFalse(capital_locked)
            with user_trading_activity_lock("api-key:fingerprint-b") as other_account:
                self.assertTrue(other_account)

    @patch(
        "api_bindings.services.get_user_trading_account_identity",
        return_value="api-key:fingerprint-a",
    )
    @patch(
        "api_bindings.services.get_user_binding_generation",
        return_value=("fingerprint-a", None),
    )
    def test_serialized_exchange_mutation_rejects_busy_account(
        self,
        _mock_generation,
        _mock_identity,
    ):
        request = MagicMock(headers={})

        @serialized_exchange_mutation
        def mutate(_view, _request):
            return "executed"

        with user_trading_activity_lock("api-key:fingerprint-a") as locked:
            response = mutate(MagicMock(), request)

        self.assertTrue(locked)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.data["message"], "资金或交易请求正在处理中，请稍后重试")

    @patch(
        "api_bindings.services.get_user_trading_account_identity",
        return_value="api-key:fingerprint-a",
    )
    @patch(
        "api_bindings.services.get_user_binding_generation",
        side_effect=[("fingerprint-a", None), ("fingerprint-b", None)],
    )
    def test_serialized_exchange_mutation_rejects_binding_change_inside_lock(
        self,
        _mock_generation,
        _mock_identity,
    ):
        request = MagicMock(headers={})
        executed = MagicMock(return_value="executed")
        mutate = serialized_exchange_mutation(executed)

        response = mutate(MagicMock(), request)

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.data["message"], "API 绑定已发生变化，请刷新后重试")
        executed.assert_not_called()

    @patch(
        "api_bindings.services.get_user_trading_account_identity",
        return_value="api-key:fingerprint-a",
    )
    @patch(
        "api_bindings.services.get_user_binding_generation",
        return_value=("fingerprint-a", None),
    )
    def test_serialized_exchange_mutation_uses_canonical_lock_order(
        self,
        _mock_generation,
        _mock_identity,
    ):
        events = []

        @contextmanager
        def lifecycle_lock(_user_id, *, timeout):
            events.append(("enter", "lifecycle", timeout))
            yield True
            events.append(("exit", "lifecycle", timeout))

        @contextmanager
        def activity_lock(_identity, *, timeout):
            events.append(("enter", "activity", timeout))
            yield True
            events.append(("exit", "activity", timeout))

        @serialized_exchange_mutation
        def mutate(_view, _request):
            events.append(("execute", "mutation", 120))
            return "executed"

        request = MagicMock(headers={})
        request.user.id = 42
        with (
            patch("trading.locks.api_binding_lifecycle_lock", lifecycle_lock),
            patch("trading.locks.user_trading_activity_lock", activity_lock),
        ):
            result = mutate(MagicMock(), request)

        self.assertEqual(result, "executed")
        self.assertEqual(
            events,
            [
                ("enter", "lifecycle", 120),
                ("enter", "activity", 120),
                ("execute", "mutation", 120),
                ("exit", "activity", 120),
                ("exit", "lifecycle", 120),
            ],
        )

    @patch("trading.locks.cache")
    def test_redis_backend_uses_atomic_lock_release(self, mock_cache):
        redis_lock = MagicMock()
        redis_lock.acquire.return_value = True
        mock_cache.lock.return_value = redis_lock

        with trade_submit_lock("open", "account-a", "BTCUSDT") as locked:
            self.assertTrue(locked)

        mock_cache.lock.assert_called_once_with(
            "trade:submit-lock:entry:account-a:BTCUSDT",
            timeout=120,
            blocking_timeout=0,
            thread_local=False,
        )
        redis_lock.acquire.assert_called_once_with(blocking=False)
        redis_lock.release.assert_called_once_with()

    @patch("trading.locks.cache")
    def test_lock_backend_failure_fails_closed(self, mock_cache):
        mock_cache.lock.side_effect = ConnectionError("redis unavailable")

        with user_trading_activity_lock("account-a") as locked:
            self.assertFalse(locked)
