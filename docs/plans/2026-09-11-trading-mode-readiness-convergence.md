# Trading Mode Readiness Convergence Implementation Plan

**状态（2026-09-11）：** 第一阶段已完成并通过本地全量验证。普通模式三类开仓入口已统一账户上下文与提交守卫，资金终态持久化已收敛；带单适配器、模式身份隔离和 MySQL / Redis 集成证据尚未完成，因此不开放带单入口。

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reduce duplicated entry and capital-transfer orchestration without changing current trading behavior, then define an evidence-based gate for adding a copy-trading mode.

**Architecture:** Keep market, limit, and chase order semantics separate while sharing only immutable account identity and lock/generation checks. Keep the existing capital state machine and exchange reconciliation rules, but route terminal state persistence through common helpers. A future copy-trading mode must select its exchange adapter before entering these shared safety services instead of branching inside current views.

**Tech Stack:** Django REST Framework, Django ORM, Redis-backed locks, Binance futures/capital adapters, unittest/APITestCase.

---

### Task 1: Freeze current behavior with focused tests

**Files:**
- Modify: `server/trading/tests.py`
- Modify: `server/trading/test_balance_cap.py`

**Step 1:** Add tests proving all three entry paths use one captured account generation and preserve their existing rejection messages.

**Step 2:** Add tests proving capital completion, failure, and uncertain results release or retain the active slot exactly as before.

**Step 3:** Run the focused tests and confirm they pass against the current implementation or fail only where the new structural contract is absent.

### Task 2: Use one immutable account context in entry paths

**Files:**
- Modify: `server/api_bindings/context.py`
- Modify: `server/api_bindings/services.py`
- Create: `server/trading/entry_guard.py`
- Modify: `server/trading/views.py`
- Test: `server/trading/tests.py`

**Step 1:** Expose the binding generation on `TradingAccountContext` and add focused unit coverage.

**Step 2:** Add a small entry guard that owns only account-level locking and generation revalidation.

**Step 3:** Change market open, limit create, and chase to consume the captured context and guard while leaving request calculation, submission, recovery, and protection behavior in their existing services.

**Step 4:** Run entry-path tests and confirm response messages, exchange writes, and idempotent recovery are unchanged.

### Task 3: Centralize capital terminal persistence

**Files:**
- Modify: `server/trading/balance_cap.py`
- Test: `server/trading/test_balance_cap.py`

**Step 1:** Route completed, failed, and pending master-transfer outcomes through the existing state helpers.

**Step 2:** Deduplicate withdrawal-history result handling without changing retry or reconciliation policy.

**Step 3:** Run the complete capital suite, including uncertain transfer and active-slot tests.

### Task 4: Define the copy-trading readiness gate

**Files:**
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md`
- Modify: `docs/known-issues.md`
- Modify: `docs/trading-safety.md`

**Step 1:** Record that trade mode selection must occur before exchange mutation and must resolve to a dedicated adapter.

**Step 2:** Define readiness evidence: shared account context in all entry mutations, contract tests for entry/recovery/protection, MySQL/Redis concurrency verification, and no mode checks inside current regular-trading business rules.

**Step 3:** Mark only evidence actually obtained; keep unresolved production or integration checks open.

### Task 5: Full verification and release assessment

**Files:**
- Modify after deployment only: `docs/changes.md`

**Step 1:** Run focused backend tests, then the full backend/frontend/webhook suites and static/security checks appropriate to the diff.

**Step 2:** Inspect the final diff for behavior drift, secrets, unrelated files, and migration changes.

**Step 3:** Decide whether the copy-trading readiness gate is met. Do not implement copy trading in this change.

**Step 4:** If the diff is safe for existing positions, commit and deploy through the documented production path, then record only the checks actually completed.
