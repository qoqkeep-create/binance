# iOS Chart Markers, Foreground Recovery, and Take-Profit Labels Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make position entry markers use the exchange position time, repair stale realtime connections immediately when the app returns to the foreground, and render take-profit labels with the same compact filled style as stop-loss labels while showing projected PnL.

**Architecture:** Preserve the existing Metal candle lookup and chart recovery state machine. Add the exchange position timestamp only to the position projection, let the client prefer that timestamp for external/manual positions, and make the app-level foreground transition call the existing reconnect path so pending backoff and stale socket tasks are cleared. Keep the price-axis label owned by Metal.

**Tech Stack:** SwiftUI, URLSessionWebSocketTask, XCTest, Django REST projections, Binance Futures positionRisk response.

---

## Tasks

1. Add regression coverage for external position timestamps, marker time selection, take-profit PnL/details/layout, and foreground reconnect behavior.
2. Return a validated `opened_at` value from the exchange position snapshot for manually adopted positions, with local creation time as fallback.
3. Update chart marker selection and take-profit label rendering/calculation.
4. Reconnect the shared realtime client on an app foreground transition and ensure latency monitoring resumes from the repaired connection.
5. Run focused and full applicable checks, update the chart/development documentation, inspect the complete diff, and commit the integrated workspace.
