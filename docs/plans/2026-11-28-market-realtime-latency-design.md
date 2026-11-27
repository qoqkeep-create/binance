# Web Market Realtime Latency Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Keep selected-symbol K-line updates responsive while the Web market list continues receiving prices for the full contract universe.

**Architecture:** Preserve the existing Binance collector, Redis sequence model, and iOS `market.ticker` contract. The Web client will use separate ticker and K-line sockets, while the ASGI sender will apply latest-wins coalescing to ticker frames and priority delivery to K-line frames. Closed K-line events will use an independent sequence scope so the Web client can request a history refresh after a real gap.

**Tech Stack:** Django ASGI WebSocket, Redis Pub/Sub, Python asyncio, React, TypeScript, lightweight-charts.

---

### Task 1: Add a deterministic realtime contract test seam

**Files:**
- Modify: `server/market_stream/bus.py`
- Modify: `server/market_stream/test_fast_path.py`
- Modify: `server/market_stream/test_coordination.py`

Add closed-bar sequence scoping and verify that forming and closed K-line sequences do not share a counter. Keep existing ticker and iOS payloads unchanged.

### Task 2: Prioritize K-line frames in each ASGI connection

**Files:**
- Modify: `server/market_stream/websocket.py`
- Modify: `server/market_stream/fanout.py`
- Modify: `server/market_stream/test_fanout.py`
- Modify: `server/market_stream/test_coordination.py`

Introduce a bounded outgoing buffer that stores K-line and control frames ahead of ticker frames. Ticker frames use latest-wins per symbol and may evict older ticker entries when the buffer is full. K-line and private frames retain the existing slow-consumer failure behavior.

### Task 3: Split Web ticker and K-line sockets

**Files:**
- Modify: `frontend/trade-web/src/lib/realtime.ts`
- Modify: `frontend/trade-web/src/lib/binance.ts`
- Add: `frontend/trade-web/tests/realtime.test.mjs`

Maintain one shared Web client with two physical connections. The ticker socket carries only ticker subscriptions and latency probes. The K-line socket carries only selected-symbol 1m K-lines. Reconnects reset sequence state and retain the current bearer-token flow.

### Task 4: Add closed K-line gap recovery

**Files:**
- Modify: `frontend/trade-web/src/lib/realtime.ts`
- Modify: `frontend/trade-web/src/KlineChart.tsx`
- Modify: `frontend/trade-web/tests/klineChart.test.mjs`

Track per-stream sequence values. Emit a gap event only for the independent closed-bar sequence. The chart debounces a history reload through its existing `attempt` path, preserving cached candles until the replacement snapshot is ready.

### Task 5: Reduce browser render churn

**Files:**
- Modify: `frontend/trade-web/src/KlineChart.tsx`
- Modify: `frontend/trade-web/src/App.tsx`

Coalesce chart tick state updates through one animation-frame callback and avoid treating ticker events as chart-render triggers. Keep list updates at the existing 500ms cadence and keep indicator semantics unchanged.

### Task 6: Verify locally and document the production boundary

Run the Web test suite, TypeScript build, targeted Django market-stream tests, `git diff --check`, and untracked-file checks. Update `docs/market-data.md` with the new Web realtime lanes, sequence recovery, and the remaining online validation boundary. Do not deploy until explicitly requested.
