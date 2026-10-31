"""Separate process for isolated Redis contracts; never uses exchange credentials."""
import os
import sys


def main():
    if os.environ.get("RUN_INTEGRATION_TESTS") != "1":
        raise RuntimeError("Only run with isolated integration services")
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "riskon.settings")
    import django
    django.setup()
    from trading.locks import trading_activity_lock
    from common.binance_rate_limit import (
        RequestBudgetExceeded, RequestBudgetSpec, RequestPriority, classify_request,
        observe_response_headers, reserve_request_budget,
    )
    operation, identity = sys.argv[1:]
    if operation == "lock":
        with trading_activity_lock(identity, timeout=30) as locked:
            print("acquired" if locked else "blocked")
    elif operation == "budget":
        try:
            reserve_request_budget(RequestBudgetSpec("futures", RequestPriority.NORMAL, 1, True),
                                   account_api_key=identity, lead_trading=True, now=120)
            print("reserved")
        except RequestBudgetExceeded:
            print("limited")
    elif operation in {"pay-budget", "deposit-budget"}:
        path = (
            "/sapi/v1/pay/transactions"
            if operation == "pay-budget"
            else "/sapi/v1/capital/deposit/hisrec"
        )
        spec = classify_request(method="GET", path=path, base_url="https://api.binance.com")
        try:
            reserve_request_budget(spec, account_api_key=identity, now=120)
            print("reserved")
        except RequestBudgetExceeded:
            print("limited")
    elif operation == "pay-observe":
        observe_response_headers(
            {"X-SAPI-USED-UID-WEIGHT-1M": "117000"},
            scope="sapi", account_api_key=identity, account_weight=True, now=120,
        )
        print("observed")
    else:
        raise ValueError("Unknown integration operation")


if __name__ == "__main__":
    main()
