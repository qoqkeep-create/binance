from django.test import SimpleTestCase

from signal_research.ai import (
    MAX_AI_RESPONSE_BYTES,
    StrategyAiError,
    _decode_ai_response,
    validate_ai_base_url,
)
from signal_research.services import calculate_features, enrich_candles, strategy_signal


class SignalResearchIndicatorTests(SimpleTestCase):
    def test_enriched_candles_include_ema_and_supertrend_after_warmup(self):
        rows = []
        for index in range(180):
            price = 100 + index * 0.5
            rows.append({"open_time": str(index * 60_000), "close_time": str(index * 60_000 + 59_999), "open": str(price - 0.2), "high": str(price + 1), "low": str(price - 1), "close": str(price), "volume": "10"})
        candles = enrich_candles(rows)
        self.assertIsNotNone(candles[-1]["ema21"])
        self.assertIsNotNone(candles[-1]["ema55"])
        self.assertIsNotNone(candles[-1]["ema144"])
        self.assertIsNotNone(candles[-1]["supertrend"])
        self.assertTrue(calculate_features(candles, len(candles) - 1)["ready"])

    def test_strategy_never_signals_before_indicator_warmup(self):
        rows = [{"open_time": str(index * 60_000), "close_time": str(index * 60_000 + 59_999), "open": "100", "high": "101", "low": "99", "close": "100", "volume": "10"} for index in range(50)]
        candles = enrich_candles(rows)
        self.assertIsNone(strategy_signal(candles, 49))


class AiBaseUrlValidationTests(SimpleTestCase):
    def test_accepts_http_and_https_urls_with_paths(self):
        self.assertEqual(
            validate_ai_base_url("https://provider.example/v1/"),
            "https://provider.example/v1",
        )
        self.assertEqual(
            validate_ai_base_url("http://ai-service:8080/api"),
            "http://ai-service:8080/api",
        )

    def test_rejects_unsafe_or_malformed_urls(self):
        invalid_urls = [
            "file:///etc/passwd",
            "https://user:secret@provider.example/v1",
            "https://provider.example/v1?token=secret",
            "https://provider.example/v1#fragment",
            "https://provider.example:invalid/v1",
            "provider.example/v1",
        ]
        for value in invalid_urls:
            with self.subTest(value=value), self.assertRaises(StrategyAiError):
                validate_ai_base_url(value)

    def test_ai_response_has_a_bounded_valid_json_contract(self):
        self.assertEqual(_decode_ai_response(b'{"choices": []}'), {"choices": []})
        for raw in (b"not-json", b"x" * (MAX_AI_RESPONSE_BYTES + 1)):
            with self.subTest(size=len(raw)), self.assertRaises(StrategyAiError):
                _decode_ai_response(raw)
