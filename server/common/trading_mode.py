from django.db import models


class TradingMode(models.TextChoices):
    ORDINARY = "ordinary", "普通合约"
    LEAD = "lead", "带单合约"


def normalize_trading_mode(value=TradingMode.ORDINARY) -> str:
    if value not in TradingMode.values:
        raise ValueError("交易模式无效，请刷新后重试")
    return str(value)


def request_trading_mode(request) -> str:
    return normalize_trading_mode(request.headers.get("X-Trading-Mode", TradingMode.ORDINARY))
