import asyncio
import json
import logging
import os
import time

from django.conf import settings
from django.db import close_old_connections
from websockets.asyncio.client import connect

from api_bindings.models import ApiBinding
from api_bindings.services import get_user_trading_account
from market_stream.bus import connection
from mobile.account_events import ingest

log = logging.getLogger(__name__)


def active_bindings():
    close_old_connections()
    return list(ApiBinding.objects.filter(status=1).select_related("user"))


def account_for(binding):
    close_old_connections()
    account = get_user_trading_account(binding.user, active_only=True, trading_mode=binding.trading_mode)
    if not account or account.binding_id != binding.pk or account.binding_created_at != binding.created_at:
        raise ValueError("Binding changed")
    return account


async def stream(binding):
    client = None
    lock = None
    try:
        lock = connection().lock(f"integrated:account-stream:{binding.pk}", timeout=60, blocking_timeout=0, thread_local=False)
        if not await asyncio.to_thread(lock.acquire, blocking=False):
            return
        account = await asyncio.to_thread(account_for, binding)
        client = account.create_futures_client()
        result = await asyncio.to_thread(client._request, "POST", "/fapi/v1/listenKey", signed=False)
        listen_key = result["listenKey"]
        url = settings.ACCOUNT_WS_URL.rstrip("/") + "/ws/" + listen_key
        # Never log exceptions with the socket URL: the path includes a private listenKey.
        async with connect(url, open_timeout=15, ping_interval=20, ping_timeout=20, proxy=os.getenv("MARKET_WS_PROXY") or None) as socket:
            await asyncio.to_thread(ingest, binding, {"e": "RECONCILE", "T": int(time.time()*1000)})
            next_keepalive = time.monotonic() + 1800
            next_lease = time.monotonic() + 20
            started = time.monotonic()
            while time.monotonic() - started < 23 * 3600:
                try:
                    raw = await asyncio.wait_for(socket.recv(), 5)
                except asyncio.TimeoutError:
                    raw = None
                if raw:
                    event = json.loads(raw)
                    if event.get("e") == "listenKeyExpired":
                        return
                    await asyncio.to_thread(ingest, binding, event)
                now = time.monotonic()
                if now >= next_lease:
                    await asyncio.to_thread(account_for, binding)
                    if not await asyncio.to_thread(lock.extend, 60, replace_ttl=True):
                        return
                    next_lease = now + 20
                if now >= next_keepalive:
                    await asyncio.to_thread(client._request, "PUT", "/fapi/v1/listenKey", signed=False)
                    next_keepalive = now + 1800
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        log.warning("Account stream unavailable binding=%s (%s); REST maintenance remains active", binding.pk, type(exc).__name__)
    finally:
        if client is not None:
            try:
                await asyncio.to_thread(ingest, binding, {"e": "RECONCILE", "T": int(time.time()*1000)})
            except Exception:
                pass
        if lock is not None:
            try:
                await asyncio.to_thread(lock.release)
            except Exception:
                pass


async def run():
    if not settings.ACCOUNT_STREAM_ENABLED:
        return
    tasks = {}
    try:
        while True:
            bindings = await asyncio.to_thread(active_bindings)
            active = {item.pk for item in bindings}
            for key in list(tasks):
                if key not in active or tasks[key].done():
                    tasks[key].cancel()
                    await asyncio.gather(tasks.pop(key), return_exceptions=True)
            for binding in bindings:
                if binding.pk not in tasks:
                    tasks[binding.pk] = asyncio.create_task(stream(binding))
            await asyncio.sleep(10)
    finally:
        for task in tasks.values():
            task.cancel()
        await asyncio.gather(*tasks.values(), return_exceptions=True)
