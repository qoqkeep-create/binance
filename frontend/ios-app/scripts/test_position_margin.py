#!/usr/bin/env python3
"""Compile actual account state/presentation and paging with in-memory HTTP."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from test_strategy_selection_confirmation import APP, IOS, generate as generate_base
from test_launch_layout import block


def visual_sources(destination):
    components = (APP / "Features/USDT/USDTComponents.swift").read_text()
    theme = block(components, "@MainActor enum WebTheme {")
    original = block(theme, "static func color(")
    theme = theme.replace(original, '''static var dark = false
  static func color(_ light: UInt32, _ dark: UInt32, leadLight: UInt32? = nil, leadDark: UInt32? = nil) -> Color {
    let hex = Self.dark ? dark : light
    return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255)
  }''')
    tabs = block(components, "struct WebTabs: View").replace("UIFont.", "NSFont.")
    source = (APP / "Features/USDT/PositionMargin.swift").read_text()
    badge = source[source.index("@MainActor extension PositionMarginLevel"):source.index("struct PositionMarginDetails:")]
    view = (APP / "Features/USDT/USDTTradingViews.swift").read_text()
    start = view.index("      HStack(spacing: 4) {", view.index("struct USDTPositionsView:"))
    header = view[start:view.index("      GeometryReader", start)]
    header = header.replace("marginDetails = true\n          Task { await margin.refresh(store) }", "")
    header = header.replace("liveActivity.toggle(store: store, container: container)", "")
    header = header.replace("floatingPositions.toggle()", "")
    harness = '''@MainActor struct PositionHeaderHarness: View {
  let store: USDTStore
  let margin: PositionMarginModel
  @State var segment = "positions"
  var floatingPositions = false
  var liveActivity = VisualLiveState()
  init(store: USDTStore, margin: PositionMarginModel, selection: String = "positions") {
    self.store = store; self.margin = margin; _segment = State(initialValue: selection)
  }
  var body: some View {
''' + header + "\n  }\n}\n"
    adapters = '''struct VisualLiveState { var isStarting = false; var isRegistering = false; var isActive = false }
enum BinanceTheme { static let accent = Color.yellow }
'''
    (destination / "Sources/MarginVisual.swift").write_text("import AppKit\nimport SwiftUI\n" + "\n".join([theme, tabs, badge, adapters, harness]))
    fixture = IOS / "scripts/fixtures/PositionMarginHeaderTests.swift"
    (destination / "Tests/PositionMarginHeaderTests.swift").write_text(fixture.read_text())
    return [APP / "Features/USDT/USDTComponents.swift", APP / "Features/USDT/USDTTradingViews.swift", fixture]


def run(destination):
    generate_base(destination)
    for path in (destination / "Tests").glob("*.swift"):
        path.unlink()
    margin_path = APP / "Features/USDT/PositionMargin.swift"
    source = margin_path.read_text().split("/// Page-wide horizontal gesture", 1)[0]
    source = source.replace("import UIKit\n", "")
    (destination / "Sources/PositionMargin.swift").write_text(source)
    store = (APP / "Features/USDT/USDTStore.swift").read_text()
    paging = store[store.index("@MainActor\nfinal class USDTPageModel:"):store.index("extension USDTStore {\n    func preflight")]
    (destination / "Sources/PageModel.swift").write_text("import Foundation\nimport Combine\n" + paging)
    number_path = APP / "Core/Presentation/DisplayNumber.swift"
    (destination / "Sources/DisplayNumber.swift").write_text(number_path.read_text())
    fixture = IOS / "scripts/fixtures/PositionMarginTests.swift"
    (destination / "Tests/PositionMarginTests.swift").write_text(fixture.read_text())
    visuals = visual_sources(destination)
    manifest = destination / "production-inputs.json"
    inputs = json.loads(manifest.read_text())
    for path in (margin_path, number_path, fixture, Path(__file__).resolve(), *visuals):
        inputs[str(path.relative_to(IOS))] = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest.write_text(json.dumps(inputs, indent=2) + "\n")
    return subprocess.run(["swift", "test", "--package-path", str(destination)], check=False).returncode


if __name__ == "__main__":
    if len(sys.argv) > 1:
        target = Path(sys.argv[1]).resolve()
        target.mkdir(parents=True, exist_ok=True)
        sys.exit(run(target))
    with tempfile.TemporaryDirectory(prefix="margin-checks-") as folder:
        sys.exit(run(Path(folder)))
