#!/usr/bin/env python3
"""Compare USDT and both USDC deployments using read-only market requests.

Requires requests and websockets >= 15. Credentials remain in ignored local
files; the output contains timings and protocol diagnostics only.
"""
import argparse
import asyncio
import json
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
from websockets.asyncio.client import connect


def credentials(path):
    return dict(line.split("=", 1) for line in Path(path).read_text().splitlines()
                if "=" in line and not line.startswith("#"))


def new_session():
    session = requests.Session()
    session.trust_env = False
    return session


def payload(response, allow_none=False):
    response.raise_for_status()
    result = response.json()
    if result.get("code") not in (0, 200) or (result.get("data") is None and not allow_none):
        raise ValueError("API did not return successful data")
    return result["data"]


def safe_error(error):
    # Avoid exception strings containing request bodies or credentials.
    if isinstance(error, requests.HTTPError):
        return "HTTP " + str(error.response.status_code)
    return type(error).__name__


def login(server, path):
    values = credentials(path)
    body = ({"email": values["TEST_ACCOUNT"], "password": values["TEST_PASSWORD"], "agreed": True}
            if server["kind"] == "usdt" else
            {"account": values["TEST_ACCOUNT"], "password": values["TEST_PASSWORD"]})
    endpoint = "/api/auth/login"
    response = server["session"].post(server["origin"] + endpoint, json=body, timeout=(6, 18))
    data = payload(response)
    server["token"] = data["token" if server["kind"] == "usdt" else "accessToken"]
    server["session"].headers["Authorization"] = "Bearer " + server["token"]


def endpoint(server, metric):
    if server["kind"] == "usdt":
        return {
            "auth_read": "/api/api/info",
            "market_10": "/api/trade/market/prices?symbols=BTCUSDT,ETHUSDT,SOLUSDT,BNBUSDT,XRPUSDT,DOGEUSDT,ADAUSDT,AVAXUSDT,LINKUSDT,DOTUSDT",
            "chart_history_300": "/market-data/klines/BTCUSDT/1h.json",
            "chart_origin_300": "/api/trade/market/klines?symbol=BTCUSDT&interval=1h&limit=300&fresh=1",
        }[metric]
    return {
        "auth_read": "/api/auth/me",
        "market_10": "/api/market/tickers/popular?size=10",
        "chart_history_300": "/api/market/klines?symbol=BTCUSDC&interval=1h&limit=300",
        "chart_origin_300": "/api/market/klines?symbol=BTCUSDC&interval=1h&limit=300",
    }[metric]


def http_sample(server, metric):
    start = time.perf_counter()
    # Public CDN requests never carry the private API token or refresh cookie.
    session = server["public_session"] if server["kind"] == "usdt" and metric == "chart_history_300" else server["session"]
    response = session.get(server["origin"] + endpoint(server, metric), timeout=(6, 12))
    data = payload(response, allow_none=metric == "auth_read")
    if metric.startswith("chart_"):
        candles = data["candles" if server["kind"] == "usdt" else "items"]
        if len(candles) != 300:
            raise ValueError("Expected exactly 300 candles")
        stamps = [int(c["t"] if server["kind"] == "usdt" else c["openTime"]) for c in candles]
        if server["kind"] == "usdc":
            stamps = [stamp // 1000 for stamp in stamps]
        if any(b - a != 3600 for a, b in zip(stamps, stamps[1:])):
            raise ValueError("Kline continuity validation failed")
    if metric == "market_10":
        rows = data["prices" if server["kind"] == "usdt" else "items"]
        if len(rows) != 10:
            raise ValueError("Expected 10 market entries")
    return {
        "ms": (time.perf_counter() - start) * 1000,
        "ttfb_ms": response.elapsed.total_seconds() * 1000,
        "decoded_bytes": len(response.content),
        "cache": response.headers.get("X-Cache", ""),
        "age": response.headers.get("Age", ""),
    }


def event_stamp(server, message):
    if server["kind"] == "usdt":
        data = message.get("data", message)
        if data.get("k", {}).get("s") == "BTCUSDT" and data["k"].get("i") == "1m":
            return data.get("E")
    elif message.get("type") == "event" and message.get("channel") == "market.kline":
        data = message.get("data", {})
        if data.get("symbol") == "BTCUSDC" and data.get("interval") == "1m":
            return data.get("eventTime")
    return None


async def websocket_trial(server, seconds):
    result = {"errors": [], "event_lag_ms": [], "event_gaps_ms": [], "control_ping_ms": []}
    url = ("wss://stream.ba.wow211.com/market-stream/btcusdt@kline_1m"
           if server["kind"] == "usdt" else server["origin"].replace("https://", "wss://") + "/ws/v1")
    headers = None if server["kind"] == "usdt" else {"Authorization": "Bearer " + server["token"]}
    start = time.perf_counter()
    try:
        async with connect(url, additional_headers=headers, proxy=None, open_timeout=10,
                           close_timeout=2, ping_interval=None) as socket:
            result["handshake_ms"] = (time.perf_counter() - start) * 1000
            if server["kind"] == "usdc":
                ready = json.loads(await asyncio.wait_for(socket.recv(), timeout=5))
                if ready.get("type") != "ready":
                    raise ValueError("Expected ready")
                result["ready_ms"] = (time.perf_counter() - start) * 1000
                await socket.send(json.dumps({"version": 1, "type": "subscribe", "requestId": "readonly-benchmark",
                                              "subscriptions": [{"channel": "market.kline", "filters": {
                                                  "symbols": ["BTCUSDC"], "intervals": ["1m"]}}]}))
            subscribed = time.perf_counter()
            async def control_pings():
                while True:
                    ping_start = time.perf_counter()
                    try:
                        pong = await socket.ping()
                        await asyncio.wait_for(pong, timeout=3)
                        result["control_ping_ms"].append((time.perf_counter() - ping_start) * 1000)
                    except Exception as error:
                        result["errors"].append("control ping: " + type(error).__name__)
                    await asyncio.sleep(10)

            ping_task = asyncio.create_task(control_pings())
            previous = None
            deadline = subscribed + seconds
            try:
                while time.perf_counter() < deadline:
                    remaining = deadline - time.perf_counter()
                    if remaining <= 0:
                        break
                    try:
                        message = json.loads(await asyncio.wait_for(socket.recv(), timeout=min(8, remaining)))
                    except asyncio.TimeoutError:
                        if remaining > 8:
                            result["errors"].append("no valid message within 8s")
                        continue
                    stamp = event_stamp(server, message)
                    if not stamp:
                        continue
                    now = time.perf_counter()
                    if "first_event_ms" not in result:
                        result["first_event_ms"] = (now - subscribed) * 1000
                        result["start_to_first_event_ms"] = (now - start) * 1000
                    if previous is not None:
                        result["event_gaps_ms"].append((now - previous) * 1000)
                    previous = now
                    result["event_lag_ms"].append(time.time() * 1000 - stamp)
            finally:
                ping_task.cancel()
                await asyncio.gather(ping_task, return_exceptions=True)
            if "first_event_ms" not in result:
                result["errors"].append("no matching Kline event")
    except Exception as error:
        result["errors"].append(type(error).__name__)
    return result


async def realtime(servers, seconds):
    results = await asyncio.gather(*(websocket_trial(server, seconds) for server in servers))
    for server, result in zip(servers, results):
        server["report"]["websocket_observation"] = result
    # Controlled client reconnects; no server restart or network setting changes.
    for attempt in range(2):
        results = await asyncio.gather(*(websocket_trial(server, 10) for server in servers))
        for server, result in zip(servers, results):
            server["report"].setdefault("reconnects", []).append(result)


def run(args):
    servers = [
        {"name": "USDT", "kind": "usdt", "origin": "https://ba.wow211.com"},
        {"name": "USDC-original", "kind": "usdc", "origin": "https://binance.oovso.com:8443"},
        {"name": "USDC-Seoul", "kind": "usdc", "origin": "https://47.80.22.243"},
    ]
    report = {"started_at": datetime.now(timezone.utc).isoformat(), "http_samples": args.samples,
              "observation_seconds": args.seconds, "client": "Python requests + websockets; TLS verified; system proxy bypassed; no local response cache",
              "servers": []}
    try:
        for server, path in zip(servers, [args.usdt, args.original, args.seoul]):
            server["session"] = new_session()
            server["public_session"] = new_session()
            server["report"] = {"name": server["name"], "origin": server["origin"], "http": {}}
            report["servers"].append(server["report"])
            login(server, path)
            print(server["name"], "authenticated", flush=True)
        for metric in ["auth_read", "market_10", "chart_history_300", "chart_origin_300"]:
            targets = servers if metric != "chart_origin_300" else servers[:1]
            for server in targets:
                server["report"]["http"][metric] = {"samples": [], "errors": [], "path": endpoint(server, metric)}
                try:
                    http_sample(server, metric)
                except Exception as error:
                    print(server["name"], metric, "warmup", safe_error(error), flush=True)
            for index in range(args.samples):
                order = targets[index % len(targets):] + targets[:index % len(targets)]
                for server in order:
                    results = server["report"]["http"][metric]
                    try:
                        results["samples"].append(http_sample(server, metric))
                    except Exception as error:
                        results["errors"].append(safe_error(error))
            print(metric, "complete", flush=True)
        asyncio.run(realtime(servers, args.seconds))
    finally:
        for server in servers:
            if "token" in server:
                try:
                    response = server["session"].post(server["origin"] + "/api/auth/logout", json={}, timeout=(6, 8))
                    server["report"]["logout_http_status"] = response.status_code
                except Exception as error:
                    server["report"]["logout_error"] = safe_error(error)
            for key in ["session", "public_session"]:
                if key in server:
                    server[key].close()
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        Path(args.output).write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["usdt", "original", "seoul", "output"]:
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--seconds", type=int, default=60)
    run(parser.parse_args())
