"""Pay UID budget contracts against isolated Redis and separate processes."""
import os
import subprocess
import sys
import unittest

from django.core.cache import cache, caches
from django.test import SimpleTestCase, override_settings

from common.binance_rate_limit import (
    _clear_local_budget_state,
    classify_request,
    reserve_request_budget,
)


@override_settings(BINANCE_BACKGROUND_WEIGHT_RATIO=0.65)
class PayBudgetRedisContractTests(SimpleTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        if os.getenv("RUN_INTEGRATION_TESTS") != "1":
            raise unittest.SkipTest("set RUN_INTEGRATION_TESTS=1 with isolated Redis")

    def setUp(self):
        self.assertIn("redis", type(caches["default"]).__module__, "Requires isolated Redis")
        cache.clear()
        _clear_local_budget_state()
        self.spec = classify_request(
            method="GET", path="/sapi/v1/pay/transactions", base_url="https://api.binance.com",
        )

    def _worker(self, operation, identity):
        result = subprocess.run(
            [sys.executable, "-m", "integration_tests.redis_worker", operation, identity],
            check=True, capture_output=True, text=True, timeout=20,
        )
        return result.stdout.strip().splitlines()[-1]

    def test_same_key_shares_budget_across_processes_and_other_key_is_independent(self):
        # 180000 UID allowance * 0.65 background ratio / 3000 request weight = 39.
        for _ in range(38):
            reserve_request_budget(self.spec, account_api_key="integration-pay-a", now=120)

        self.assertEqual(self._worker("pay-budget", "integration-pay-a"), "reserved")
        self.assertEqual(self._worker("pay-budget", "integration-pay-a"), "limited")
        self.assertEqual(self._worker("pay-budget", "integration-pay-b"), "reserved")

    def test_uid_header_is_shared_only_by_corresponding_pay_key(self):
        self.assertEqual(self._worker("pay-observe", "integration-pay-a"), "observed")
        self.assertEqual(self._worker("pay-budget", "integration-pay-a"), "limited")
        self.assertEqual(self._worker("pay-budget", "integration-pay-b"), "reserved")
        self.assertEqual(self._worker("deposit-budget", "integration-pay-a"), "reserved")

    def test_third_pay_request_does_not_exhaust_ip_budget(self):
        for _ in range(3):
            self.assertEqual(self._worker("pay-budget", "integration-pay-a"), "reserved")
        self.assertEqual(self._worker("deposit-budget", "integration-pay-a"), "reserved")
