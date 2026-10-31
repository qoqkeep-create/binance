import signal
import time

from django.core.management.base import BaseCommand

from trading.scheduler import start_scheduler, stop_scheduler


class Command(BaseCommand):
    help = "Run the trading APScheduler worker as a standalone process"

    def handle(self, *args, **options):
        self.stdout.write(self.style.SUCCESS("Starting trading scheduler"))
        start_scheduler()

        should_exit = False

        def _handle_signal(signum, frame):  # noqa: ARG001
            nonlocal should_exit
            should_exit = True
            self.stdout.write(self.style.WARNING(f"Received signal {signum}, stopping scheduler"))

        signal.signal(signal.SIGINT, _handle_signal)
        signal.signal(signal.SIGTERM, _handle_signal)

        try:
            while not should_exit:
                time.sleep(1)
        finally:
            stop_scheduler()
            self.stdout.write(self.style.SUCCESS("Trading scheduler stopped"))
