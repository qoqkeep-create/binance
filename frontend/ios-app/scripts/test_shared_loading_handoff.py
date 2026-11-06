#!/usr/bin/env python3
"""Run shared read/refresh handoff regressions against actual store/page methods.

Uses only gated in-memory HTTP fixtures; no simulator, network, or trade action.
The same XCTest class is also compiled in the iOS unit-test target.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from test_launch_layout import block
from test_strategy_selection_confirmation import APP, IOS, generate as generate_base


def run(destination):
    generate_base(destination)
    for path in (destination / "Tests").glob("*.swift"):
        path.unlink()
    store_path = APP / "Features/USDT/USDTStore.swift"
    store = store_path.read_text()
    page = block(store, "@MainActor\nfinal class USDTPageModel:")
    (destination / "Sources/PageModel.swift").write_text("import Foundation\nimport Combine\n" + page)
    dashboard_inputs = [
        APP / "Features/Dashboard/DashboardViewModel.swift",
        APP / "Features/Dashboard/MarketWatchlistStore.swift",
        APP / "Core/Models/MarketSnapshot.swift", APP / "Core/Models/MarketKline.swift",
        APP / "Core/Models/StrategySignal.swift",
        APP / "Core/Models/ReferenceTradeNotification.swift", APP / "Core/Presentation/DisplayNumber.swift",
    ]
    for path in dashboard_inputs:
        (destination / "Sources" / path.name).write_text(path.read_text())
    margin_path = APP / "Features/USDT/PositionMargin.swift"
    margin = margin_path.read_text().split("@MainActor extension PositionMarginLevel", 1)[0]
    (destination / "Sources/PositionMargin.swift").write_text(margin.replace("import UIKit\n", ""))
    realtime = (APP / "Core/Networking/RealtimeClient.swift").read_text()
    boundaries = destination / "Sources/Boundaries.swift"
    payloads = [block(realtime, declaration) for declaration in [
        "struct RealtimeSubscription:", "struct MarketTickerPayload:",
        "struct RealtimeStrategySignalEventPayload:", "struct RealtimeReversalAlertEventPayload:",
    ]]
    boundaries.write_text(boundaries.read_text() + "\n" + "\n".join(payloads) + '''
@MainActor final class RealtimeClient {
    init(baseURL: URL, tokenProvider: @escaping () -> String?) {}
    func events() -> AsyncStream<RealtimeServerMessage> { AsyncStream { $0.finish() } }
    func connect() {}
    func subscribe(_ subscriptions: [RealtimeSubscription]) {}
    func unsubscribe(channels: [String]) {}
}
''')
    test_path = IOS / "TradeToolTests/ServerSwitchingTests.swift"
    test_source = test_path.read_text()
    tests = block(test_source, "@MainActor\nfinal class SharedLoadingHandoffTests:")
    fixture = block(test_source, "private actor SharedLoadingFixtureAPI:")
    (destination / "Tests/SharedLoadingHandoffTests.swift").write_text(
        "import Foundation\nimport XCTest\n@testable import TradeTool\n" + tests + "\n" + fixture)
    manifest = destination / "production-inputs.json"
    inputs = json.loads(manifest.read_text())
    for path in (store_path, test_path, margin_path, *dashboard_inputs, Path(__file__).resolve()):
        inputs[str(path.relative_to(IOS))] = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest.write_text(json.dumps(inputs, indent=2) + "\n")
    return subprocess.run(["swift", "test", "--package-path", str(destination)], check=False).returncode


if __name__ == "__main__":
    if len(sys.argv) > 1:
        target = Path(sys.argv[1]).resolve()
        target.mkdir(parents=True, exist_ok=True)
        sys.exit(run(target))
    with tempfile.TemporaryDirectory(prefix="shared-loading-") as folder:
        sys.exit(run(Path(folder)))
