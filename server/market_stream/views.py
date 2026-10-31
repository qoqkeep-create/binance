from django.conf import settings
from rest_framework.views import APIView
from common.response import fail, ok
from market_stream.core import INTERVAL_MS, symbol_name
from market_stream import service, trading_data


class TickersView(APIView):
    def get(self, request, kind="all"):
        rows = service.tickers()
        query = request.query_params.get("query", "").upper()
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
        return ok({"quoteAsset": settings.MARKET_QUOTE_ASSET, "tickers": selected,
                   "items": selected, "hasNext": kind != "all" and (page+1)*size < len(rows)})


class WatchlistView(APIView):
    def get(self, request):
        available = service.symbols()
        preferred = [f"{base}{settings.MARKET_QUOTE_ASSET}" for base in ("BTC", "ETH", "SOL", "BNB", "XRP", "DOGE")]
        return ok({"quoteAsset": settings.MARKET_QUOTE_ASSET,
                   "symbols": [symbol for symbol in preferred if symbol in available], "availableSymbols": available})


class KlinesView(APIView):
    def get(self, request):
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
            if symbol not in service.symbols():
                raise ValueError("交易对不存在或已下架")
        except (ValueError, TypeError) as exc:
            return fail(str(exc))
        return ok(trading_data.attach(service.load_history(symbol, interval, limit, before), requested))
