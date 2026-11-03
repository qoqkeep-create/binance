"""Durable, budgeted public-data repair, executed by the market collector only."""
import hashlib
import logging
import time
import random

from django.core.cache import cache
from django.db import close_old_connections, transaction

from market_stream.core import INTERVAL_MS, PREWARM_INTERVALS, aggregate_bucket, bucket_open_time, rest_candle
from market_stream.models import MarketCandle, MarketHistoryTask

log = logging.getLogger(__name__)


def schedule(symbol, interval, *, before=None, kind="history", priority=1):
    # Limits share a task; repair fetches one bounded 1500-row page.
    before = int(before or 0)
    key = hashlib.sha256(f"{symbol}:{interval}:{before}:{kind}".encode()).hexdigest()
    task, _ = MarketHistoryTask.objects.get_or_create(key=key, defaults={
        "symbol": symbol, "interval": interval, "before": before,
        "kind": kind, "priority": priority})
    now = time.time()
    cooldown = 30 if kind.startswith("stats:") else 60
    if task.completed_at and not task.attempts and now - task.completed_at >= cooldown:
        MarketHistoryTask.objects.filter(pk=task.pk, lease_until__lte=now).update(
            due_at=now, priority=min(priority, task.priority))
        task.due_at = now
    elif not task.completed_at and task.priority > priority:
        MarketHistoryTask.objects.filter(pk=task.pk).update(priority=priority)
    return task


def seed(symbols):
    MarketHistoryTask.objects.exclude(symbol__in=symbols).delete()
    MarketHistoryTask.objects.exclude(kind="maintenance").filter(completed_at__gt=0, completed_at__lt=time.time()-86400).delete()
    for symbol in symbols:
        for interval in PREWARM_INTERVALS:
            schedule(symbol, interval, kind="maintenance", priority=10)


def _fetch(task, *, start=None, end=None):
    from market_stream import service
    now = int(time.time() * 1000)
    source_interval = "8h" if task.interval == "16h" else task.interval
    params = {"pair": task.symbol, "contractType": "PERPETUAL", "interval": source_interval, "limit": 1500}
    if start is not None:
        params["startTime"] = start
    if end is not None:
        params["endTime"] = end
    raw = service.public_request("/fapi/v1/continuousKlines", params)
    if task.interval == "16h":
        # Binance has no native 16h interval. Two bounded 8h pages produce up to 1500 16h bars.
        if len(raw) == 1500 and (start is None or min(row[0] for row in raw) > start):
            older = service.public_request("/fapi/v1/continuousKlines",
                {**params, "endTime": min(row[0] for row in raw) - 1})
            raw = older + raw
        sources = {int(row[0]): rest_candle(task.symbol, source_interval, row, now) for row in raw}
        groups = {}
        for row in sources.values():
            groups.setdefault(bucket_open_time(row["openTime"], "16h"), []).append(row)
        rows = []
        for at, group in sorted(groups.items()):
            row = aggregate_bucket(group, "16h", source_interval="8h",
                partial=at == bucket_open_time(now, "16h"))
            if row is not None:
                rows.append(row)
    else:
        rows = [rest_candle(task.symbol, task.interval, row, now) for row in raw]
    cutoff = bucket_open_time(now - service.RETENTION_DAYS[task.interval] * 86400000, task.interval)
    rows = [row for row in rows if row["openTime"] >= cutoff
            and (start is None or row["openTime"] >= start) and (end is None or row["openTime"] <= end)]
    with transaction.atomic():
        service.persist(rows)
    # HTTP readers see a repaired snapshot immediately, without replaying old
    # REST candles into the ordered live Socket stream.
    service.publish_live_batch([row for row in rows if not row["closed"]], emit=False)
    return rows


def repair_history(task):
    from market_stream.service import RETENTION_DAYS
    width = INTERVAL_MS[task.interval]
    now = int(time.time() * 1000)
    cutoff = bucket_open_time(now - RETENTION_DAYS[task.interval] * 86400000, task.interval)
    onboard = cache.get("market:onboard", {}).get(task.symbol, 0)
    if onboard > 0:
        cutoff = max(cutoff, bucket_open_time(onboard - 1, task.interval) + width)
    if task.kind != "maintenance":
        if task.before and task.before <= cutoff:
            return True, 3600
        rows = _fetch(task, end=task.before - 1 if task.before else None)
        return not rows, 3600 if task.before else 60

    query = MarketCandle.objects.filter(symbol=task.symbol, interval=task.interval, open_time__gte=cutoff)
    latest = query.order_by("-open_time").values_list("open_time", flat=True).first()
    if latest is None or latest < bucket_open_time(now, task.interval) - width:
        # No startTime: ask for the newest page first, then grow backwards.
        rows = _fetch(task)
        advanced = any(row["closed"] and row["openTime"] >= bucket_open_time(now, task.interval) - width for row in rows)
        return False, 1 if advanced else 60
    previous = None
    earliest = None
    for at in query.order_by("open_time").values_list("open_time", flat=True).iterator(chunk_size=2000):
        earliest = at if earliest is None else earliest
        if previous is not None and at > previous + width:
            rows = _fetch(task, start=previous + width, end=min(at - 1, previous + 1500 * width - 1))
            # Empty gaps may represent a suspension. Back off instead of spinning.
            return task.exhausted, 60 if not rows else 1
        previous = at
    if earliest is not None and earliest > cutoff and not task.exhausted:
        rows = _fetch(task, start=max(cutoff, earliest - 1500 * width), end=earliest - 1)
        return not any(row["openTime"] < earliest for row in rows), 1
    return task.exhausted, 60


def notify_ready(task):
    from market_stream import bus
    try:
        bus.publish_batch("market.history", [(f"{task.symbol}:{task.interval}", {
            "symbol": task.symbol, "interval": task.interval, "kind": task.kind,
            "beforeOpenTime": task.before or None,
        })])
    except Exception as exc:
        # A missing notice is repaired by the client's periodic reconciliation;
        # it must not turn a committed history job into a failed REST retry.
        log.warning("Market readiness notice deferred (%s)", type(exc).__name__)


def run_next(lane="history"):
    """One bounded task per pass. Failed/abandoned leases become retryable."""
    close_old_connections()
    now = time.time()
    from common.binance import rate_limit_cooldown_remaining
    if rate_limit_cooldown_remaining("futures") > 0:
        close_old_connections()
        return False
    try:
        with transaction.atomic():
            query = MarketHistoryTask.objects.filter(due_at__lte=now, lease_until__lte=now)
            query = query.filter(kind__startswith="stats:") if lane == "statistics" else query.exclude(kind__startswith="stats:")
            task = query.select_for_update().order_by("priority", "due_at", "id").first()
            if task is None:
                return False
            lease = now + 180
            task.lease_until = lease
            task.save(update_fields=["lease_until"])
        try:
            if task.kind.startswith("stats:"):
                from market_stream import service, trading_data
                snapshot = service.load_history(task.symbol, task.interval, 1500, schedule_repair=False)
                trading_data.load_series(snapshot, task.kind.removeprefix("stats:"))
                exhausted, delay = False, 30
            else:
                exhausted, delay = repair_history(task)
                from market_stream import service
                service.warm_history(task.symbol, task.interval, task.before or None)
            completed = time.time()
            # On-demand tasks stop after success; maintenance rotates fairly.
            due = completed + delay if task.kind == "maintenance" else completed + 86400 * 365
            updated = MarketHistoryTask.objects.filter(pk=task.pk, lease_until=lease).update(
                exhausted=exhausted, completed_at=completed, attempts=0, lease_until=0,
                due_at=due, priority=10 if task.kind == "maintenance" else 5)
            if updated and task.kind != "maintenance":
                transaction.on_commit(lambda: notify_ready(task))
        except Exception as exc:
            attempts = min(task.attempts + 1, 16)
            budget_wait = getattr(exc.__cause__, "retry_after", 0)
            delay = max(min(300, 2 ** attempts), budget_wait, rate_limit_cooldown_remaining("futures"))
            MarketHistoryTask.objects.filter(pk=task.pk, lease_until=lease).update(
                attempts=attempts, lease_until=0, due_at=time.time() + delay + random.uniform(0, 1), priority=5)
            log.warning("Market repair deferred symbol=%s interval=%s kind=%s (%s)",
                        task.symbol, task.interval, task.kind, type(exc).__name__)
        return True
    finally:
        close_old_connections()
