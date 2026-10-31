from unittest.mock import patch

from django.test import SimpleTestCase

from common.binance import BinanceApiError, BinanceCredentials, BinanceFuturesClient


class DepositHistoryContractTests(SimpleTestCase):
    def setUp(self):
        self.client = BinanceFuturesClient(BinanceCredentials("test-api-key", "test-secret"))

    def test_uses_read_only_get_and_omits_unspecified_status(self):
        with patch.object(self.client, "_request", return_value=[]) as request:
            self.assertEqual(self.client.get_deposit_history(), [])

        self.assertEqual(request.call_args.args, (
            "GET", "/sapi/v1/capital/deposit/hisrec", {"coin": "USDT", "limit": 1000},
        ))
        self.assertTrue(request.call_args.kwargs["signed"])

    def test_status_filters_and_pagination_are_forwarded(self):
        for status in (1, 6):
            with self.subTest(status=status), patch.object(self.client, "_request", return_value=[]) as request:
                self.client.get_deposit_history(
                    ccy="usdt", status=status, start_time_ms=100, end_time_ms=200,
                    offset=1000, limit=500,
                )
                self.assertEqual(request.call_args.args[2], {
                    "coin": "USDT", "status": status, "startTime": 100, "endTime": 200,
                    "offset": 1000, "limit": 500,
                })

    def test_spot_and_funding_wallet_records_are_returned_without_filtering(self):
        rows = [
            {"id": "spot-deposit", "walletType": 0, "status": 1, "amount": "10", "offset": 0},
            {"id": "funding-deposit", "walletType": 1, "status": 6, "amount": "20", "offset": 1},
        ]
        with patch.object(self.client, "_request", return_value=rows):
            actual = self.client.get_deposit_history(status=None, offset=1000)
        self.assertEqual(actual, rows)

    def test_malformed_response_does_not_look_like_empty_completed_page(self):
        for payload in (None, {}, {"data": []}, "", [None], ["row"], [{"id": "valid"}, 1]):
            with self.subTest(payload=payload), patch.object(self.client, "_request", return_value=payload):
                with self.assertRaises(BinanceApiError):
                    self.client.get_deposit_history()
