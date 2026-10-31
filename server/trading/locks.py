from common.trading_mode import request_trading_mode
from contextlib import contextmanager
from functools import wraps
import logging
from uuid import uuid4
from contextvars import ContextVar
import threading

_held_lifecycle = ContextVar("held_api_lifecycle", default=frozenset())

from django.core.cache import cache

from common.errors import safe_error_summary

logger = logging.getLogger(__name__)


@contextmanager
def distributed_cache_lock(lock_key: str, *, timeout: int):
    """Acquire a non-blocking cache lock without releasing a newer owner's lease."""
    lock_factory = getattr(cache, "lock", None)
    if callable(lock_factory):
        try:
            redis_lock = lock_factory(lock_key, timeout=timeout, blocking_timeout=0, thread_local=False)
            locked = bool(redis_lock.acquire(blocking=False))
        except Exception as exc:  # noqa: BLE001
            logger.error(
                "distributed lock acquisition failed key=%s err=%s",
                lock_key,
                safe_error_summary(exc),
            )
            yield False
            return
        stop = threading.Event()
        def renew():
            while not stop.wait(max(timeout / 3, 0.05)):
                try:
                    if not redis_lock.extend(timeout, replace_ttl=True):
                        return
                except Exception:
                    logger.error("distributed lock renewal failed key=%s", lock_key)
                    return
        thread = threading.Thread(target=renew, daemon=True, name="trade-lock-renewal") if locked else None
        if thread:
            thread.start()
        try:
            yield locked
        finally:
            stop.set()
            if thread:
                thread.join(timeout=2)
            if locked:
                try:
                    redis_lock.release()
                except Exception:  # noqa: BLE001
                    # Expired locks must never delete a newer owner's token.
                    pass
        return

    lock_value = uuid4().hex
    try:
        locked = cache.add(lock_key, lock_value, timeout=timeout)
    except Exception as exc:  # noqa: BLE001
        logger.error(
            "distributed lock acquisition failed key=%s err=%s",
            lock_key,
            safe_error_summary(exc),
        )
        yield False
        return
    try:
        yield locked
    finally:
        if locked:
            try:
                if cache.get(lock_key) == lock_value:
                    cache.delete(lock_key)
            except Exception as exc:  # noqa: BLE001
                logger.error(
                    "distributed lock release failed key=%s err=%s",
                    lock_key,
                    safe_error_summary(exc),
                )


@contextmanager
def trading_activity_lock(account_identity: str | int, *, timeout: int = 120):
    """Serialize exchange mutations for one resolved trading account."""
    normalized_identity = str(account_identity or "").strip()
    if not normalized_identity:
        raise ValueError("account_identity is required")
    lock_key = f"trade:user-activity-lock:{normalized_identity}"
    with distributed_cache_lock(lock_key, timeout=timeout) as locked:
        yield locked


@contextmanager
def user_trading_activity_lock(account_identity: str | int, *, timeout: int = 120):
    """Backward-compatible name for the canonical account mutation lock."""
    with trading_activity_lock(account_identity, timeout=timeout) as locked:
        yield locked


@contextmanager
def trade_submit_lock(
    action: str,
    account_identity: str | int,
    symbol: str,
    *,
    timeout: int = 120,
):
    """Prevent concurrent entry submissions for one account and symbol."""
    del action  # Kept in the signature for existing call sites and trace labels.
    lock_key = f"trade:submit-lock:entry:{account_identity}:{symbol}"
    with distributed_cache_lock(lock_key, timeout=timeout) as locked:
        yield locked


@contextmanager
def api_binding_registration_lock(api_key_fingerprint: str, *, timeout: int = 30):
    """Serialize registration of the same non-secret API key fingerprint."""
    fingerprint = str(api_key_fingerprint or "").strip().lower()
    if not fingerprint:
        raise ValueError("api_key_fingerprint is required")
    with distributed_cache_lock(
        f"trade:api-binding-lock:{fingerprint}",
        timeout=timeout,
    ) as locked:
        yield locked


@contextmanager
def api_binding_lifecycle_lock(user_id: int, *, timeout: int = 120, reentrant: bool = False):
    """Serialize bind and unbind transitions for one Web account."""
    normalized_user_id = int(user_id)
    if normalized_user_id <= 0:
        raise ValueError("user_id is required")
    held = _held_lifecycle.get()
    if normalized_user_id in held:
        yield True
        return
    with distributed_cache_lock(f"trade:api-binding-lifecycle:{normalized_user_id}", timeout=timeout) as locked:
        token = _held_lifecycle.set(held | {normalized_user_id}) if locked and reentrant else None
        try:
            yield locked
        finally:
            if token is not None:
                _held_lifecycle.reset(token)



def serialized_exchange_mutation(method=None, *, timeout: int = 120):
    """Serialize one authenticated exchange mutation with a stable API binding.

    Lifecycle is always acquired before the account activity lock. Bind/unbind
    paths use the same order, which prevents lock inversion while keeping the
    binding generation stable for the whole mutation.
    """

    def decorate(view_method):
        @wraps(view_method)
        def wrapped(view, request, *args, **kwargs):
            from api_bindings.services import (
                get_user_binding_generation,
                get_user_trading_account_identity,
            )
            from common.response import fail

            with api_binding_lifecycle_lock(request.user.id, timeout=timeout) as lifecycle_locked:
                if not lifecycle_locked:
                    return fail("API 绑定正在变更，请稍后重试")
                binding_generation = get_user_binding_generation(request.user, trading_mode=request_trading_mode(request))
                identity = get_user_trading_account_identity(request.user, trading_mode=request_trading_mode(request))
                with user_trading_activity_lock(identity, timeout=timeout) as locked:
                    if not locked:
                        return fail("资金或交易请求正在处理中，请稍后重试")
                    if get_user_binding_generation(request.user, trading_mode=request_trading_mode(request)) != binding_generation:
                        return fail("API 绑定已发生变化，请刷新后重试")
                    return view_method(view, request, *args, **kwargs)

        return wrapped

    if method is None:
        return decorate
    return decorate(method)
