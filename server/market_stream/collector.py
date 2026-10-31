"""One market collector per environment; HTTP and WebSocket workers share Redis."""
import asyncio
import json
import logging
import os
import time

from django.conf import settings
from django.core.cache import cache
from websockets.asyncio.client import connect

from market_stream import service
from market_stream.core import INTERVAL_MS, normalize_kline

log = logging.getLogger(__name__)


class MarketCollector:
    def __init__(self):
        self.pending = {}
        self.ticker_pending = {}
        self.symbols = []
        self.last_seen_written = 0

    async def consume(self, streams):
        url = settings.MARKET_WS_URL.rstrip("/") + "/stream?streams=" + "/".join(streams)
        backoff = 1
        while True:
            try:
                async with connect(url, ping_interval=20, ping_timeout=20, open_timeout=15,
                                   max_size=4_000_000, max_queue=64, proxy=os.getenv("MARKET_WS_PROXY") or None) as socket:
                    backoff = 1
                    async for message in socket:
                        data = json.loads(message).get("data")
                        if data and time.monotonic() - self.last_seen_written >= 1:
                            self.last_seen_written = time.monotonic()
                            await asyncio.to_thread(cache.set, "market:collector:last_message", int(time.time()*1000), 300)
                        if isinstance(data, list):
                            for ticker in data:
                                self.ticker_pending[ticker["s"]] = ticker
                        elif isinstance(data, dict) and "k" in data:
                            candle = normalize_kline(data)
                            # Keep closed and next-minute candles distinct while coalescing live updates.
                            key = (candle["symbol"], candle["openTime"])
                            previous = self.pending.get(key)
                            if not previous or candle["eventTime"] >= previous["eventTime"]:
                                self.pending[key] = candle
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                log.warning("Market stream disconnected (%s); retry in %ss", type(exc).__name__, backoff)
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 30)

    async def flush(self):
        while True:
            await asyncio.sleep(0.2)
            candles, self.pending = self.pending, {}
            tickers, self.ticker_pending = self.ticker_pending, {}
            try:
                if candles:
                    await asyncio.to_thread(service.consume_batch, list(candles.values()))
                if tickers:
                    await asyncio.to_thread(service.update_tickers, list(tickers.values()))
                await asyncio.to_thread(cache.set, "market:collector:heartbeat", int(time.time()*1000), 30)
            except Exception as exc:
                # Database repair is authoritative after a failure; avoid replaying stale live quotes.
                log.warning("Market batch deferred (%s); continuity repair will recover closed candles", type(exc).__name__)

    async def backfill(self):
        while True:
            for symbol in self.symbols:
                try:
                    await asyncio.to_thread(service.load_history, symbol, "1m", 500)
                    await asyncio.to_thread(service.repair_minute_gaps, symbol)
                except Exception as exc:
                    log.warning("Minute repair deferred symbol=%s (%s)", symbol, type(exc).__name__)
                await asyncio.sleep(0.15)
            await asyncio.sleep(60)

    async def retention(self):
        while True:
            try:
                await asyncio.to_thread(service.prune_history)
            except Exception as exc:
                log.warning("Market retention deferred (%s)", type(exc).__name__)
            await asyncio.sleep(3600)

    async def run(self):
        tasks = []
        try:
            while True:
                try:
                    discovered = await asyncio.to_thread(service.symbols, True)
                except Exception as exc:
                    log.warning("Market universe unavailable (%s)", type(exc).__name__)
                    await asyncio.sleep(10)
                    continue
                if discovered != self.symbols:
                    for task in tasks:
                        task.cancel()
                    await asyncio.gather(*tasks, return_exceptions=True)
                    self.symbols = discovered
                    streams = [f"{symbol.lower()}_perpetual@continuousKline_1m" for symbol in discovered]
                    tasks = [asyncio.create_task(self.consume(streams[i:i+80])) for i in range(0, len(streams), 80)]
                    tasks += [asyncio.create_task(self.consume(["!ticker@arr"])),
                              asyncio.create_task(self.flush()), asyncio.create_task(self.backfill()),
                              asyncio.create_task(self.retention())]
                    log.info("Market collector subscribed to %s %s contracts", len(discovered), settings.MARKET_QUOTE_ASSET)
                await asyncio.sleep(300)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
