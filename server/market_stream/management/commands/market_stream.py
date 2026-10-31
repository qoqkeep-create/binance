import asyncio
from django.conf import settings
from django.core.management.base import BaseCommand
from market_stream.collector import MarketCollector


class Command(BaseCommand):
    help = "Collect public Binance 1m and ticker streams; no private trading operations"

    def handle(self, *args, **options):
        if not settings.MARKET_STREAM_ENABLED:
            return
        asyncio.run(MarketCollector().run())
