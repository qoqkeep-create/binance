import time
import logging

from django.conf import settings
from rest_framework import serializers
from rest_framework.views import APIView
from common.response import fail, ok
from market_stream.core import INTERVAL_MS, symbol_name
from market_stream import service, trading_data
from market_stream.catalog import catalog_response
from market_stream.models import MarketWatchlist
from market_stream.diagnostics import correlation

log = logging.getLogger(__name__)


class TickersView(APIView):
    def get(self, request, kind="all"):
        rows = service.tickers()
        query = request.query_params.get("query", "").strip().upper()
        if query:
            rows = [row for row in rows if query in row["symbol"]]
        if kind != "all":
            try:
                size = min(max(int(request.query_params.get("size", 10)), 1), 100)
                page = max(int(request.query_params.get("page", 0)), 0)
            except ValueError:
                return fail("分页参数不正确")
            selected = rows[page*size:(page+1)*size]
        else:
            selected = rows
            page, size = 0, len(rows)
        return ok({"quoteAsset": settings.MARKET_QUOTE_ASSET, "tickers": selected,
                   "items": selected, "query": query, "page": page, "size": size,
                   "totalElements": len(rows), "totalPages": (len(rows) + size - 1) // size if size else 0,
                   "hasNext": kind != "all" and (page+1)*size < len(rows)})


class SymbolsView(APIView):
    def get(self, request):
        available = service.symbols(cached_only=True)
        if not available:
            return fail("交易对目录正在准备，请稍后重试", code=503, status=503)
        payload = catalog_response(available)
        return ok({"quoteAsset": settings.MARKET_QUOTE_ASSET, "symbols": payload["availableSymbols"],
                   "marketCaps": payload["marketCaps"], "marketCapsUpdatedAt": payload["marketCapsUpdatedAt"]})


class WatchlistView(APIView):
    def get(self, request):
        available = service.symbols(cached_only=True)
        if not available:
            return fail("交易对目录正在准备，请稍后重试", code=503, status=503)
        saved = MarketWatchlist.objects.filter(user=request.user, quote_asset=settings.MARKET_QUOTE_ASSET).first()
        preferred = saved.symbols if saved is not None else [f"{base}{settings.MARKET_QUOTE_ASSET}" for base in ("BTC", "ETH", "SOL", "BNB", "XRP", "DOGE")]
        return ok({**catalog_response(available), "quoteAsset": settings.MARKET_QUOTE_ASSET,
                   "symbols": [symbol for symbol in preferred if symbol in available], "isCustomized": saved is not None})

    def post(self, request):
        serializer = WatchlistInput(data=request.data)
        if not serializer.is_valid():
            return fail("自选交易对格式不正确")
        available = service.symbols(cached_only=True)
        if not available:
            return fail("交易对目录正在准备，请稍后重试", code=503, status=503)
        symbols = list(dict.fromkeys(item.strip().upper() for item in serializer.validated_data["symbols"]))
        if set(symbols) - set(available):
            return fail("部分交易对不存在或已下架，请刷新目录后重试")
        MarketWatchlist.objects.update_or_create(user=request.user, quote_asset=settings.MARKET_QUOTE_ASSET,
                                                 defaults={"symbols": symbols})
        return ok({"symbols": symbols})


class WatchlistInput(serializers.Serializer):
    symbols = serializers.ListField(child=serializers.CharField(max_length=32), max_length=2000, allow_empty=True)


class KlinesView(APIView):
    # Wire compression belongs to nginx (see deploy/integrated/nginx-location.conf):
    # compressing ~400 KiB here would occupy the single shared sync-view thread
    # that every other HTTP request also waits on.
    def get(self, request):
        received_at_ms = int(time.time() * 1000)
        trace = correlation(request)
        try:
            requested = set(filter(None, request.query_params.get("tradingData", "").split(",")))
            if not requested.issubset(trading_data.SERIES):
                raise ValueError("K线统计数据类型不支持")
            symbol = symbol_name(request.query_params.get("symbol", ""), settings.MARKET_QUOTE_ASSET)
            interval = request.query_params.get("interval", "1h")
            limit = int(request.query_params.get("limit", 300))
            before = request.query_params.get("beforeOpenTime")
            before = int(before) if before is not None else None
            if interval not in INTERVAL_MS or not 1 <= limit <= 1500 or (before is not None and before <= 0):
                raise ValueError("K线参数不正确")
            available = service.symbols(cached_only=True)
            if not available:
                return fail("行情目录正在准备，请稍后重试", code=503, status=503)
            if symbol not in available:
                raise ValueError("交易对不存在或已下架")
        except (ValueError, TypeError) as exc:
            return fail(str(exc))
        started = time.perf_counter()
        snapshot = service.load_history(symbol, interval, limit, before)
        loaded = time.perf_counter()
        response = ok(trading_data.attach(snapshot, requested))
        response["Server-Timing"] = (f"history;dur={(loaded-started)*1000:.2f}, "
                                     f"statistics_cache;dur={(time.perf_counter()-loaded)*1000:.2f}")
        if trace:
            response["X-Chart-Trace-ID"], response["X-Chart-Request-ID"] = trace
            response["X-Chart-Server-Received-At"] = str(received_at_ms)
            response["X-Chart-Server-Ready-At"] = str(int(time.time() * 1000))
            log.info("chart_history trace=%s request=%s history_ms=%.2f", *trace, (loaded-started)*1000)
        return response
