from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from typing import Iterator

from api_bindings.context import TradingAccountContext
from api_bindings.services import get_user_binding_generation

from trading.locks import trade_submit_lock, user_trading_activity_lock


@dataclass(frozen=True)
class EntryGuardState:
    allowed: bool
    error: str = ""


@contextmanager
def entry_submission_guard(
    user,
    account: TradingAccountContext,
    *,
    action: str,
    symbol: str,
) -> Iterator[EntryGuardState]:
    """Serialize one entry mutation and reject a changed binding generation."""
    with user_trading_activity_lock(account.identity) as account_locked:
        if not account_locked:
            yield EntryGuardState(False, "请求处理中，请勿重复提交")
            return
        with trade_submit_lock(action, account.identity, symbol) as submit_locked:
            if not submit_locked:
                yield EntryGuardState(False, "请求处理中，请勿重复提交")
                return
            if get_user_binding_generation(user, trading_mode=account.trading_mode) != account.generation:
                yield EntryGuardState(False, "API 绑定已发生变化，请刷新后重试")
                return
            yield EntryGuardState(True)
