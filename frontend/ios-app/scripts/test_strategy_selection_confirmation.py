#!/usr/bin/env python3
"""Run production strategy selection methods on macOS without an iOS simulator.

The generated host target copies the real store, JSON, request, and error code.
Only SwiftUI property wrappers/navigation and the network/event boundaries are
substituted. No test calls URLSession or a trading/exchange endpoint.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


IOS = Path(__file__).resolve().parents[1]
APP = IOS / "TradeTool"


def read(relative):
    return (APP / relative).read_text()


def generate(destination):
    sources = destination / "Sources"
    tests = destination / "Tests"
    sources.mkdir(parents=True, exist_ok=True)
    tests.mkdir(exist_ok=True)
    view = read("Features/USDT/USDTStrategyViews.swift")
    properties = view.split("struct USDTStrategiesView: View {\n", 1)[1].split("  var body: some View {", 1)[0]
    properties = properties.replace("  @Environment(\\.dismiss) private var dismiss", "  var dismiss: () -> Void = {}")
    properties = properties.replace("  @EnvironmentObject private var store: USDTStore", "  let store: USDTStore")
    properties = properties.replace("@State private var", "var")
    assert "@" not in properties, "Unmapped SwiftUI property wrapper"
    methods = view.split("  private func chooseStrategy", 1)[1].split("\n}\n\nstruct USDTStrategyLevel", 1)[0]
    methods = "  func chooseStrategy" + methods.replace("private func", "func")
    harness = "import Foundation\n@MainActor\nfinal class StrategySelectionHarness {\n" + properties
    harness += "  init(store: USDTStore) { self.store = store }\n" + methods + "\n}\n"
    (sources / "Selection.swift").write_text(harness)
    store = read("Features/USDT/USDTStore.swift").split("/// Read-only chart context.", 1)[0]
    json_value = read("Core/Networking/RealtimeClient.swift").split("enum JSONValue:", 1)[1]
    json_value = "enum JSONValue:" + json_value.split("\n@MainActor\nfinal class RealtimeClient", 1)[0]
    # The networking implementation is deliberately excluded; every request is
    # delivered to the in-memory API implementation in the regression tests.
    protocol = read("Core/Networking/APIClient.swift").split("struct URLSessionAPIClient", 1)[0]
    (sources / "Store.swift").write_text(store)
    (sources / "JSONValue.swift").write_text("import Foundation\n" + json_value)
    (sources / "APIClient.swift").write_text(protocol)
    (sources / "APIRequest.swift").write_text(read("Core/Networking/APIRequest.swift"))
    (sources / "APIError.swift").write_text(read("Core/Networking/APIError.swift"))
    (sources / "Boundaries.swift").write_text(
        "import Foundation\nfinal class RequestDiagnostics {}\n"
        "struct RealtimeServerMessage { let type: String; let channel: String? }\n")
    fixture = IOS / "scripts/fixtures/StrategySelectionConfirmationTests.swift"
    (tests / fixture.name).write_text(fixture.read_text())
    (destination / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "StrategySelectionChecks", platforms: [.macOS(.v14)], targets: [
    .target(name: "TradeTool", path: "Sources"),
    .testTarget(name: "StrategySelectionTests", dependencies: ["TradeTool"], path: "Tests")
], swiftLanguageModes: [.v5])
''')
    inputs = [APP / name for name in (
        "Features/USDT/USDTStrategyViews.swift", "Features/USDT/USDTStore.swift",
        "Core/Networking/RealtimeClient.swift", "Core/Networking/APIClient.swift",
        "Core/Networking/APIRequest.swift", "Core/Networking/APIError.swift")]
    inputs.append(fixture)
    (destination / "production-inputs.json").write_text(json.dumps({
        str(path.relative_to(IOS)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in inputs}, indent=2) + "\n")


def run(destination):
    generate(destination)
    return subprocess.run(["swift", "test", "--package-path", str(destination)], check=False).returncode


if __name__ == "__main__":
    if len(sys.argv) > 1:
        target = Path(sys.argv[1]).resolve()
        target.mkdir(parents=True, exist_ok=True)
        sys.exit(run(target))
    with tempfile.TemporaryDirectory(prefix="strategy-selection-") as directory:
        sys.exit(run(Path(directory)))
