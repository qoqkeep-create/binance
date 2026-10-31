from __future__ import annotations

from datetime import datetime, timedelta, timezone
from unittest.mock import patch

from django.test import SimpleTestCase

from market_analysis.trend import evaluate_trend, parse_closed_candles


class ParseClosedCandlesTests(SimpleTestCase):
    @staticmethod
    def _row(close_time: int) -> dict[str, str | int]:
        return {
            "open_time": close_time - 60_000,
            "close_time": close_time,
            "open": "100",
            "high": "110",
            "low": "90",
            "close": "105",
            "volume": "12",
        }

    def test_uses_standard_utc_when_now_is_omitted(self):
        now = datetime.now(timezone.utc)
        closed_at = int((now - timedelta(minutes=1)).timestamp() * 1000)
        open_until = int((now + timedelta(minutes=1)).timestamp() * 1000)

        candles = parse_closed_candles([self._row(closed_at), self._row(open_until)])

        self.assertEqual([candle.close_time for candle in candles], [closed_at])


class EvaluateTrendTests(SimpleTestCase):
    @staticmethod
    def _row(index: int, *, open_price: float, high: float, low: float, close: float) -> dict[str, str | int]:
        return {
            "open_time": index * 60_000,
            "close_time": (index + 1) * 60_000,
            "open": str(open_price),
            "high": str(high),
            "low": str(low),
            "close": str(close),
            "volume": "12",
        }

    @classmethod
    def _candles_with_bull_flip(cls, *, include_entry: bool) -> list[dict[str, str | int]]:
        rows = [
            cls._row(index, open_price=100, high=101, low=99, close=100)
            for index in range(198)
        ]
        rows.append(cls._row(198, open_price=100, high=201, low=99, close=200))
        if include_entry:
            rows.append(cls._row(199, open_price=140, high=170, low=140, close=160))
        return rows

    @classmethod
    def _candles_with_bear_flip(cls) -> list[dict[str, str | int]]:
        rows = [
            cls._row(index, open_price=100, high=101, low=99, close=100)
            for index in range(197)
        ]
        rows.append(cls._row(197, open_price=100, high=201, low=99, close=200))
        rows.append(cls._row(198, open_price=200, high=201, low=49, close=50))
        return rows

    @staticmethod
    def _ema_values(period: int, length: int) -> list[float]:
        if period == 21:
            return [160.0] * length
        if period == 55:
            return [150.0] * length
        return [150.0] * length

    @patch("market_analysis.trend._wilder_atr")
    @patch("market_analysis.trend._ema_stream")
    @patch("market_analysis.trend.binance_get_historical_candles")
    def test_trend_flip_starts_tracking_without_emitting_alert(
        self,
        get_candles,
        ema_stream,
        wilder_atr,
    ):
        rows = self._candles_with_bull_flip(include_entry=False)
        get_candles.return_value = rows
        ema_stream.side_effect = lambda closes, period: self._ema_values(period, len(closes))
        wilder_atr.side_effect = lambda candles, _period: [1.0] * len(candles)

        events = evaluate_trend("BTCUSDT", "1h")

        self.assertEqual(events, [])

    @patch("market_analysis.trend._wilder_atr")
    @patch("market_analysis.trend._ema_stream")
    @patch("market_analysis.trend.binance_get_historical_candles")
    def test_bear_trend_flip_starts_tracking_without_emitting_alert(
        self,
        get_candles,
        ema_stream,
        wilder_atr,
    ):
        rows = self._candles_with_bear_flip()
        get_candles.return_value = rows
        ema_stream.side_effect = lambda closes, period: self._ema_values(period, len(closes))
        wilder_atr.side_effect = lambda candles, _period: [1.0] * len(candles)

        events = evaluate_trend("BTCUSDT", "1h")

        self.assertEqual(events, [])

    @patch("market_analysis.trend._wilder_atr")
    @patch("market_analysis.trend._ema_stream")
    @patch("market_analysis.trend.binance_get_historical_candles")
    def test_entry_after_silent_trend_flip_still_emits_alert(
        self,
        get_candles,
        ema_stream,
        wilder_atr,
    ):
        rows = self._candles_with_bull_flip(include_entry=True)
        get_candles.return_value = rows
        ema_stream.side_effect = lambda closes, period: self._ema_values(period, len(closes))
        wilder_atr.side_effect = lambda candles, _period: [1.0] * len(candles)

        events = evaluate_trend("BTCUSDT", "1h")

        self.assertEqual([event.kind for event in events], ["entry_ema55", "entry_ema144"])
        self.assertEqual([event.direction for event in events], ["long", "long"])
