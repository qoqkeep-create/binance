from __future__ import annotations

from django.core.cache import cache

from api_bindings.context import build_trading_account_identity


POSITION_CACHE_KINDS = ("exchange_rows", "open_algo_rows", "last_success")


def normalize_account_identity(account_identity: str | int) -> str:
    if isinstance(account_identity, int):
        return build_trading_account_identity(user_id=account_identity)
    identity = str(account_identity or "").strip()
    if not identity:
        raise ValueError("account_identity is required")
    return identity


def position_cache_key(kind: str, account_identity: str | int) -> str:
    if kind not in POSITION_CACHE_KINDS:
        raise ValueError(f"unsupported position cache kind: {kind}")
    return f"position:list:{kind}:{normalize_account_identity(account_identity)}"


def invalidate_position_caches(
    account_identity: str | int,
    *,
    legacy_user_id: int | None = None,
) -> None:
    identity = normalize_account_identity(account_identity)
    keys = [position_cache_key(kind, identity) for kind in POSITION_CACHE_KINDS]
    if legacy_user_id is not None:
        keys.extend(f"position:list:{kind}:{int(legacy_user_id)}" for kind in POSITION_CACHE_KINDS)
    cache.delete_many(keys)
