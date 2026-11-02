import asyncio
import logging
import time
from concurrent.futures import ThreadPoolExecutor

from django.core.management.base import BaseCommand
from django.core.cache import cache
from django.conf import settings
from django.db import close_old_connections, transaction
from django.utils import timezone

from market_stream import bus
from mobile.account_stream import run as streams
from mobile.commands import execute_account
from mobile.models import AccountInbox, AccountOutbox, TradingCommand

log = logging.getLogger(__name__)


def bindings_to_process():
    close_old_connections()
    pending = TradingCommand.objects.filter(status__in=["PENDING", "RUNNING", "UNKNOWN"]).values_list("binding_id_snapshot", flat=True).distinct()
    inbox = AccountInbox.objects.filter(processed=False).values_list("binding_id_snapshot", flat=True).distinct()
    return set(pending) | set(inbox)


def publish_outbox():
    close_old_connections()
    with transaction.atomic():
        rows = list(AccountOutbox.objects.select_for_update().filter(published_at__isnull=True).order_by("id")[:100])
        if rows:
            bus.publish_private_batch([
                (row.channel, row.event_key, row.payload, row.user_id, row.trading_mode) for row in rows
            ])
            AccountOutbox.objects.filter(pk__in=[row.pk for row in rows]).update(published_at=timezone.now())


async def run():
    pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="account-worker")
    stream_task = asyncio.create_task(streams())
    running = {}
    try:
        while True:
            if stream_task.done() and settings.ACCOUNT_STREAM_ENABLED:
                await stream_task
                raise RuntimeError("Account stream supervisor stopped")
            for key in list(running):
                if running[key].done():
                    try:
                        running[key].result()
                    except Exception as exc:
                        log.warning("Account worker deferred binding=%s (%s)", key, type(exc).__name__)
                    del running[key]
            for binding_id in await asyncio.to_thread(bindings_to_process):
                if binding_id not in running:
                    running[binding_id] = asyncio.get_running_loop().run_in_executor(pool, execute_account, binding_id)
            try:
                await asyncio.to_thread(publish_outbox)
                await asyncio.to_thread(cache.set, "mobile:worker:heartbeat", int(time.time()*1000), 60)
            except Exception as exc:
                log.warning("Private event delivery deferred (%s)", type(exc).__name__)
            await asyncio.sleep(0.25)
    finally:
        stream_task.cancel()
        await asyncio.gather(stream_task, return_exceptions=True)
        pool.shutdown(wait=True)


class Command(BaseCommand):
    help = "Run durable account commands, user streams and private event outbox"

    def handle(self, *args, **options):
        asyncio.run(run())
