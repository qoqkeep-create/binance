#!/usr/bin/env python3
"""Exercise the actual position strategy picker and command flow without iOS.

SwiftUI bindings/navigation are replaced by a shared harness. Production picker
methods, position execute(), store, request and error code run unchanged against
an in-memory API; no exchange or network operation is performed.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from test_strategy_selection_confirmation import APP, IOS, generate as generate_base


def generate(destination):
    generate_base(destination)
    store_path = APP / "Features/USDT/USDTStore.swift"
    store_extensions = "extension USDTStore {" + store_path.read_text().split("extension USDTStore {", 1)[1]
    (destination / "Sources/StoreCommands.swift").write_text("import Foundation\n" + store_extensions)
    strategy_path = APP / "Features/USDT/USDTStrategyViews.swift"
    trading_path = APP / "Features/USDT/USDTTradingViews.swift"
    strategy = strategy_path.read_text()
    picker = strategy.split("struct WebStrategyPicker: View {\n", 1)[1]
    properties = picker.split("  var body: some View {", 1)[0]
    properties = properties.replace("  @EnvironmentObject private var store: USDTStore", "  let store: USDTStore")
    properties = properties.replace("  @Environment(\\.webDismiss) private var dismiss", "")
    properties = properties.replace("  @Binding var selection: String", "  var selection: String { get { controls.strategyID } set { controls.strategyID = newValue } }")
    properties = properties.replace("  var busy = false", "  var busy: Bool { controls.busy }")
    properties = properties.replace("  var pending = false", "  var pending: Bool { controls.pending }")
    properties = properties.replace("  var notice = \"\"", "  var notice: String { controls.notice }")
    properties = properties.replace("  let confirmed: () -> Void", "  var confirmed: () -> Void { { self.controls.execute(\"strategy-rebind\", extra: [\"strategy_id\": .string(self.selection)]) } }")
    properties = properties.replace("@State private var", "var").replace("private var", "var")
    assert "@" not in properties, "Unmapped SwiftUI wrapper"
    methods = "  func chooseStrategy" + picker.split("  private func chooseStrategy", 1)[1]
    methods = methods.rsplit("\n}", 1)[0].replace("private func", "func")
    harness = "import Foundation\n@MainActor\nfinal class PositionStrategyPickerHarness {\n"
    harness += properties + "  let controls: PositionStrategyControlsHarness\n"
    harness += "  init(controls: PositionStrategyControlsHarness) { self.controls = controls; self.store = controls.store }\n"
    harness += methods + "\n}\n"
    (destination / "Sources/PositionPicker.swift").write_text(harness)

    controls = trading_path.read_text().split("private struct USDTPositionControls: View {\n", 1)[1]
    properties = controls.split("  var body: some View {", 1)[0]
    properties = properties.replace("  @EnvironmentObject private var store: USDTStore", "  let store: USDTStore")
    properties = properties.replace("  @Environment(\\.webDismiss) private var dismiss", "  var dismiss: () -> Void = {}")
    properties = properties.replace("@State private var", "var").replace("private var", "var")
    assert "@" not in properties, "Unmapped SwiftUI wrapper"
    execute = "  func execute" + controls.split("  private func execute", 1)[1].split("  private func cancelTakeProfit", 1)[0]
    harness = "import Foundation\n@MainActor\nfinal class PositionStrategyControlsHarness {\n" + properties
    harness += """  init(store: USDTStore, completed: @escaping (String) -> Void) {
    self.store = store
    self.position = .object(["id": .string("position-11"), "symbol": .string("BTCUSDT"), "strategy_status": .string("0")])
    self.action = "strategy"
    self.completed = completed
    self.strategyScope = store.scope
  }
""" + execute + "\n}\n"
    (destination / "Sources/PositionControls.swift").write_text(harness)
    completion = "  func completePositionOperation" + trading_path.read_text().split(
        "  private func completePositionOperation", 1)[1].split("  private func historyCard", 1)[0]
    (destination / "Sources/PositionPresentation.swift").write_text("""import Foundation
@MainActor
final class PositionMarginRefreshProbe {
  var afterChanges: [Bool] = []
  func refresh(_ store: USDTStore, afterChange: Bool) async { afterChanges.append(afterChange) }
}
@MainActor
final class PositionOperationPresentationHarness {
  let store: USDTStore
  let margin = PositionMarginRefreshProbe()
  init(store: USDTStore) { self.store = store }
  var operation: String? = "operation-1"
  var notice = ""
  var reloads = 0
  func reload() async { reloads += 1 }
""" + completion + "}\n")
    fixture = IOS / "scripts/fixtures/PositionStrategyPickerTests.swift"
    (destination / "Tests" / fixture.name).write_text(fixture.read_text())
    manifest_path = destination / "production-inputs.json"
    manifest = json.loads(manifest_path.read_text())
    for path in [strategy_path, trading_path, store_path, fixture]:
        manifest[str(path.relative_to(IOS))] = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


def run(destination):
    generate(destination)
    return subprocess.run(["swift", "test", "--package-path", str(destination)], check=False).returncode


if __name__ == "__main__":
    if len(sys.argv) > 1:
        target = Path(sys.argv[1]).resolve()
        target.mkdir(parents=True, exist_ok=True)
        sys.exit(run(target))
    with tempfile.TemporaryDirectory(prefix="position-strategy-picker-") as directory:
        sys.exit(run(Path(directory)))
