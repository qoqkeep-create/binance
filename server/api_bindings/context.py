from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

from common.binance import BinanceCredentials, BinanceFuturesClient
from common.trading_mode import TradingMode, normalize_trading_mode


def build_trading_account_identity(
    *,
    user_id: int,
    api_key_fingerprint: str = "",
    binding_id: int | None = None,
    trading_mode: str = TradingMode.ORDINARY,
) -> str:
    """Build a stable, non-secret identity for locks, caches, and idempotency."""
    fingerprint = str(api_key_fingerprint or "").strip().lower()
    mode = normalize_trading_mode(trading_mode)
    prefix = "lead:" if mode == TradingMode.LEAD else ""
    if fingerprint:
        return f"{prefix}api-key:{fingerprint}"
    if binding_id:
        return f"{prefix}binding:{int(binding_id)}:legacy"
    return f"{prefix}user:{int(user_id)}"


@dataclass(frozen=True)
class TradingAccountContext:
    """Immutable identity and credentials for one exchange-account binding."""

    user_id: int
    binding_id: int
    api_key_fingerprint: str
    alias: str
    binding_created_at: datetime | None
    credentials: BinanceCredentials
    trading_mode: str = TradingMode.ORDINARY

    @property
    def generation(self) -> tuple[str, datetime | None]:
        return self.api_key_fingerprint, self.binding_created_at

    @property
    def identity(self) -> str:
        return build_trading_account_identity(
            user_id=self.user_id,
            binding_id=self.binding_id,
            api_key_fingerprint=self.api_key_fingerprint,
            trading_mode=self.trading_mode,
        )

    @property
    def cache_namespace(self) -> str:
        namespace = f"trade:account:{self.binding_id}:{self.api_key_fingerprint[:16] or 'legacy'}"
        return f"{namespace}:lead" if self.trading_mode == TradingMode.LEAD else namespace

    def create_futures_client(self) -> BinanceFuturesClient:
        return BinanceFuturesClient(self.credentials)


def record_belongs_to_trading_account(
    *,
    record_fingerprint: str | None,
    record_created_at: datetime | None,
    account_fingerprint: str,
    binding_created_at: datetime | None,
    record_mode: str = TradingMode.ORDINARY,
    account_mode: str = TradingMode.ORDINARY,
) -> bool:
    """Return whether a local exchange record belongs to the current key generation."""
    stored = str(record_fingerprint or "").strip().lower()
    if normalize_trading_mode(record_mode) != normalize_trading_mode(account_mode):
        return False
    current = str(account_fingerprint or "").strip().lower()
    if account_mode == TradingMode.LEAD and (not current or not stored):
        return False
    if stored:
        return bool(current) and stored == current
    if binding_created_at is None:
        return True
    return bool(record_created_at and record_created_at >= binding_created_at)
