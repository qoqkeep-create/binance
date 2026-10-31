from django.core.cache import cache
from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.http import JsonResponse
from django.views.decorators.http import require_GET


SCHEDULER_HEARTBEAT_KEY = "ops:scheduler:heartbeat"
SCHEDULER_HEARTBEAT_TIMEOUT_SECONDS = 60


def touch_scheduler_heartbeat() -> None:
    from django.utils import timezone

    cache.set(
        SCHEDULER_HEARTBEAT_KEY,
        timezone.now().isoformat(),
        timeout=SCHEDULER_HEARTBEAT_TIMEOUT_SECONDS,
    )


def _database_ready() -> bool:
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            return cursor.fetchone() == (1,)
    except Exception:
        return False


def _migrations_ready() -> bool:
    try:
        executor = MigrationExecutor(connection)
        return not executor.migration_plan(executor.loader.graph.leaf_nodes())
    except Exception:
        return False


def _scheduler_heartbeat():
    try:
        return cache.get(SCHEDULER_HEARTBEAT_KEY)
    except Exception:
        return None


@require_GET
def deep_health(request):  # noqa: ARG001
    heartbeat = _scheduler_heartbeat()
    checks = {
        "database": _database_ready(),
        "migrations": _migrations_ready(),
        "scheduler": bool(heartbeat),
    }
    ready = all(checks.values())
    return JsonResponse(
        {
            "status": "ok" if ready else "unavailable",
            "checks": checks,
            "scheduler_heartbeat": heartbeat,
        },
        status=200 if ready else 503,
    )
