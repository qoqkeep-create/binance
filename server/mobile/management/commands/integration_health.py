import time

from django.core.cache import cache
from django.core.management.base import BaseCommand, CommandError


class Command(BaseCommand):
    help = "Read process heartbeats without performing trading operations"

    def add_arguments(self, parser):
        parser.add_argument("component", choices=["market", "worker", "scheduler"])

    def handle(self, *args, **options):
        component = options["component"]
        keys = {"market": ["market:collector:heartbeat", "market:collector:last_message"],
                "worker": ["mobile:worker:heartbeat"], "scheduler": ["ops:scheduler:heartbeat"]}[component]
        now = int(time.time()*1000)
        for key in keys:
            value = cache.get(key)
            if not value or (isinstance(value, (int, float)) and now-value > 120000):
                raise CommandError(f"{component} heartbeat unavailable")
        self.stdout.write(f"{component} healthy")
