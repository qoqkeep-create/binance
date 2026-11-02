"""Durable pair ordering. HTTP reads never wait for the public data provider."""
import json
import re
import time
from datetime import timedelta
from decimal import Decimal, InvalidOperation
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from market_stream.models import MarketCapitalization, MarketSymbol


def coin_symbol(symbol):
    base = symbol.removesuffix(settings.MARKET_QUOTE_ASSET)
    # Binance bundles such as 1000SHIB represent the underlying coin's cap.
    return re.sub(r"^[1-9]0{3,}(?=[A-Z])", "", base)


def _amount(value):
    try:
        number = Decimal(str(value))
        return number if number.is_finite() and number > 0 else Decimal(0)
    except (InvalidOperation, ValueError, TypeError):
        return Decimal(0)


def catalog_response(available):
    snapshot = MarketCapitalization.objects.filter(pk="coingecko").first()
    coins = snapshot.coins if snapshot else {}
    caps = {symbol: str(coins.get(coin_symbol(symbol), {}).get("market_cap", "0")) for symbol in available}
    return {
        "availableSymbols": sorted(available, key=lambda symbol: (-_amount(caps[symbol]), symbol)),
        "marketCaps": caps,
        "marketCapsUpdatedAt": snapshot.refreshed_at.isoformat() if snapshot and snapshot.refreshed_at else None,
    }


def _fetch_coins(symbols):
    query = urlencode({"vs_currency": "usd", "symbols": ",".join(symbol.lower() for symbol in symbols),
                       "include_tokens": "top", "order": "market_cap_desc", "per_page": 250,
                       "page": 1, "sparkline": "false"})
    request = Request("https://api.coingecko.com/api/v3/coins/markets?" + query,
                      headers={"User-Agent": "BinanceTools/1.0", "Accept": "application/json"})
    with urlopen(request, timeout=15) as response:
        payload = json.loads(response.read(), parse_float=Decimal)
    if not isinstance(payload, list):
        raise ValueError("Invalid market capitalization response")
    return payload


def refresh_market_caps():
    """Weekly on success; bounded retry after failures. Never touches trading state."""
    now = timezone.now()
    available = list(MarketSymbol.objects.filter(active=True, quote_asset=settings.MARKET_QUOTE_ASSET)
                     .values_list("symbol", flat=True))
    if not available:
        return False
    with transaction.atomic():
        MarketCapitalization.objects.get_or_create(pk="coingecko")
        snapshot = MarketCapitalization.objects.select_for_update().get(pk="coingecko")
        if snapshot.refreshed_at and now - snapshot.refreshed_at < timedelta(days=7):
            return False
        if snapshot.attempted_at and now - snapshot.attempted_at < timedelta(hours=6):
            return False
        snapshot.attempted_at = now
        snapshot.save(update_fields=["attempted_at"])
    bases = sorted({coin_symbol(symbol) for symbol in available})
    coins = {}
    for offset in range(0, len(bases), 50):
        if offset:
            time.sleep(2.1)
        for item in _fetch_coins(bases[offset:offset + 50]):
            if not isinstance(item, dict):
                raise ValueError("Invalid market capitalization item")
            base = str(item.get("symbol", "")).upper()
            amount = _amount(item.get("market_cap"))
            if base in bases and amount > _amount(coins.get(base, {}).get("market_cap")):
                coins[base] = {"id": str(item.get("id", "")), "market_cap": str(amount)}
    if not coins:
        raise ValueError("Empty market capitalization snapshot")
    # Commit only after every page succeeded. A timeout preserves the last good snapshot.
    MarketCapitalization.objects.filter(pk="coingecko").update(coins=coins, refreshed_at=now)
    return True
