"""One market collector per environment; HTTP and WebSocket workers share Redis."""
import asyncio
import json
import logging
import os
import time

from django.conf import settings
from django.core.cache import cache
from websockets.asyncio.client import connect

from market_stream import repair, service, upstream
from market_stream.core import INTERVAL_MS, normalize_kline

log = logging.getLogger(__name__)
MAX_PENDING_CLOSED = 10000


class MarketCollector:
    def __init__(self):
        self.pending = {}
        self.ticker_pending = {}
        self.closed_pending = {}
        self.closed_overflow = 0
        self.live_ready = asyncio.Event()
        self.closed_ready = asyncio.Event()
        self.tickers_ready = asyncio.Event()
        self.warm_ready = asyncio.Event()
        self.symbols = []
        self.last_seen_written = 0

    def accept(self, candle):
        if candle["closed"]:
            key = (candle["symbol"], candle["interval"], candle["openTime"])
            self.closed_pending[key] = candle
            if len(self.closed_pending) > MAX_PENDING_CLOSED:
                self.closed_pending.pop(next(iter(self.closed_pending)))
                self.closed_overflow += 1
            self.closed_ready.set()
        else:
            key = (candle["symbol"], candle["interval"])
            previous = self.pending.get(key)
            if not previous or (candle["openTime"], candle["eventTime"]) >= (previous["openTime"], previous["eventTime"]):
                self.pending[key] = candle
                self.live_ready.set()

    async def consume(self, streams):
        url = settings.MARKET_WS_URL.rstrip("/") + "/stream?streams=" + "/".join(streams)
        attempt = 0
        while True:
            wait = await asyncio.to_thread(upstream.reserve_connection)
            if wait > 0:
                await asyncio.sleep(min(wait, 60))
                continue
            connected_at = None
            try:
                async with connect(url, ping_interval=20, ping_timeout=20, open_timeout=15,
                                   max_size=4_000_000, max_queue=64, proxy=os.getenv("MARKET_WS_PROXY") or None) as socket:
                    connected_at = time.monotonic()
                    try:
                        # Spread rotations before Binance's 24h connection expiry.
                        async with asyncio.timeout(upstream.rotation_seconds()):
                            await self.receive_messages(socket)
                    except TimeoutError:
                        log.info("Market stream rotating before expiry")
                        attempt = 0
                        continue
                    raise ConnectionError("Market stream ended")
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                # Brief handshakes must not reset the retry delay in an outage.
                if connected_at is not None and time.monotonic() - connected_at >= 60:
                    attempt = 0
                attempt += 1
                cooldown = await asyncio.to_thread(upstream.defer_handshake, exc)
                delay = max(cooldown, upstream.reconnect_delay(attempt))
                log.warning("Market stream disconnected (%s); retry in %.1fs", type(exc).__name__, delay)
                await asyncio.sleep(delay)

    async def receive_messages(self, socket):
        async for message in socket:
            try:
                data = json.loads(message).get("data")
                if data and time.monotonic() - self.last_seen_written >= 1:
                    self.last_seen_written = time.monotonic()
                    await asyncio.to_thread(cache.set, "market:collector:last_message", int(time.time()*1000), 300)
                if isinstance(data, list):
                    for ticker in data:
                        self.ticker_pending[ticker["s"]] = ticker
                    self.tickers_ready.set()
                elif isinstance(data, dict) and "k" in data:
                    self.accept(normalize_kline(data))
            except (ValueError, TypeError, KeyError, AttributeError):
                log.warning("Market stream invalid public event skipped")

    async def flush(self):
        while True:
            await self.live_ready.wait()
            self.live_ready.clear()
            candles, self.pending = self.pending, {}
            try:
                if candles:
                    await asyncio.to_thread(service.publish_live_batch, list(candles.values()))
            except Exception as exc:
                log.warning("Market live delivery deferred (%s)", type(exc).__name__)

    async def store_closed(self):
        while True:
            await self.closed_ready.wait()
            self.closed_ready.clear()
            candles, self.closed_pending = self.closed_pending, {}
            if self.closed_overflow:
                log.warning("Market closed buffer dropped %s old entries; continuity repair will recover them", self.closed_overflow)
                self.closed_overflow = 0
            try:
                if candles:
                    await asyncio.to_thread(service.consume_batch, list(candles.values()))
            except Exception as exc:
                log.warning("Market closed storage deferred (%s); continuity repair will recover it", type(exc).__name__)

    async def flush_tickers(self):
        while True:
            await self.tickers_ready.wait()
            self.tickers_ready.clear()
            tickers, self.ticker_pending = self.ticker_pending, {}
            try:
                if tickers:
                    await asyncio.to_thread(service.update_tickers, list(tickers.values()))
            except Exception as exc:
                log.warning("Market ticker delivery deferred (%s)", type(exc).__name__)

    async def backfill(self, lane="history"):
        while True:
            try:
                worked = await asyncio.to_thread(repair.run_next, lane=lane)
            except Exception as exc:
                worked = False
                log.warning("Market repair worker deferred (%s)", type(exc).__name__)
            await asyncio.sleep(0.2 if worked else 1)

    async def warm(self):
        while True:
            await self.warm_ready.wait()
            self.warm_ready.clear()
            tickers = await asyncio.to_thread(cache.get, "market:tickers", {})
            ranked = sorted(self.symbols, key=lambda symbol: tickers.get(symbol, {}).get("quoteVolume24h", 0), reverse=True)
            for symbol in ranked:
                for interval in INTERVAL_MS:
                    try:
                        await asyncio.to_thread(service.warm_history, symbol, interval, prewarm=True)
                    except Exception as exc:
                        log.warning("Market warmup deferred (%s)", type(exc).__name__)
                    await asyncio.sleep(0)

    async def heartbeat(self):
        while True:
            await asyncio.to_thread(cache.set, "market:collector:heartbeat", int(time.time()*1000), 30)
            await asyncio.sleep(5)

    async def retention(self):
        while True:
            try:
                await asyncio.to_thread(service.prune_history)
            except Exception as exc:
                log.warning("Market retention deferred (%s)", type(exc).__name__)
            try:
                from market_stream.diagnostics import prune_reports
                await asyncio.to_thread(prune_reports)
            except Exception as exc:
                log.warning("Chart diagnostics retention deferred (%s)", type(exc).__name__)
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
                await asyncio.to_thread(repair.seed, discovered)
                if discovered != self.symbols:
                    for task in tasks:
                        task.cancel()
                    await asyncio.gather(*tasks, return_exceptions=True)
                    self.symbols = discovered
                    streams = [f"{symbol.lower()}_perpetual@continuousKline_1m" for symbol in discovered]
                    tasks = [asyncio.create_task(self.consume(streams[i:i+80])) for i in range(0, len(streams), 80)]
                    tasks += [asyncio.create_task(self.consume(["!ticker@arr"])),
                              asyncio.create_task(self.flush()), asyncio.create_task(self.store_closed()),
                              asyncio.create_task(self.flush_tickers()), asyncio.create_task(self.backfill()),
                              *[asyncio.create_task(self.backfill("statistics")) for _ in range(6)],
                              asyncio.create_task(self.warm()), asyncio.create_task(self.heartbeat()),
                              asyncio.create_task(self.retention())]
                    log.info("Market collector subscribed to %s %s contracts", len(discovered), settings.MARKET_QUOTE_ASSET)
                self.warm_ready.set()
                await asyncio.sleep(300)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
