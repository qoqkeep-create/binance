#!/usr/bin/env python3
"""Run the real chart model, stream and indicator pipeline on a macOS host."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

IOS = Path(__file__).resolve().parents[1]
APP = IOS / "TradeTool"


def run(destination, model_source=None, test_filter=None):
    sources, tests = destination / "Sources", destination / "Tests"
    sources.mkdir(parents=True, exist_ok=True)
    tests.mkdir(exist_ok=True)
    inputs = {}

    def read(path):
        raw = path.read_bytes()
        inputs[str(path)] = hashlib.sha256(raw).hexdigest()
        return raw.decode()

    engine = APP / "Features/ChartEngine"
    for directory in ["Domain", "Data", "Indicators", "Scene", "Viewport"]:
        for path in sorted((engine / directory).glob("*.swift")):
            (sources / path.name).write_text(read(path))
    path = engine / "Rendering/Metal/MetalGlyphAtlas.swift"
    (sources / path.name).write_text(read(path))
    for path in (APP / "Core/Networking").glob("*.swift"):
        if path.name != "ServerNetworkProbe.swift":
            (sources / path.name).write_text(read(path))
    probe = read(APP / "Core/Networking/ServerNetworkProbe.swift")
    mode = read(APP / "Features/USDT/USDTStore.swift")
    (sources / "NetworkContext.swift").write_text(
        "import Foundation\n" + probe[probe.index("struct ServerNetworkResult:"):probe.index("protocol ServerNetworkProbing")]
        + "@MainActor\n" + mode[mode.index("enum NativeTradingMode {"):mode.index("/// List IDs")])
    for name in ["MarketKline", "MarketSnapshot"]:
        path = APP / "Core/Models" / (name + ".swift")
        (sources / path.name).write_text(read(path))
    path = APP / "Core/Presentation/DisplayNumber.swift"
    (sources / path.name).write_text(read(path))
    model = model_source or APP / "Features/Chart/MarketChartViewModel.swift"
    # Xcode imports Combine through the app build; make the standalone file explicit.
    (sources / "MarketChartViewModel.swift").write_text("import Combine\n" + read(model))
    fixture = read(IOS / "TradeToolTests/ServerSwitchingTests.swift")
    begin = fixture.index("final class MarketFastPathTests:")
    end = fixture.index("final class ChartLoadDiagnosticsTests:", begin)
    extracted = fixture[begin:end]
    # Session preparation tests belong to USDTStore; keep the chart target focused.
    session_test = extracted.index("    func testPreparingSessionMakesNoAccountRequests()")
    session_end = extracted.index("\n    func ", session_test + 10)
    extracted = extracted[:session_test] + extracted[session_end:]
    (tests / "ChartRecoveryTests.swift").write_text(
        "import Combine\nimport Foundation\nimport XCTest\n@testable import TradeTool\n@MainActor\n"
        + extracted)
    core = read(IOS / "TradeToolTests/ChartEngineCoreTests.swift").split("final class ChartOrderOverlayRenderingTests:")[0]
    methods = []
    selected = {"testCancelledSnapshotAndPageCannotMutateThePipeline",
                "testConcurrentSnapshotPageAndConfigurationKeepFramesConsistent",
                "testRepairSnapshotKeepsNewerSocketTailAndClosedBars",
                "testRepairSnapshotCorrectsQuoteOnlyOpenWithoutLosingLatestClose",
                "testWeeklyQuoteTailUsesMondayBucketAndKeepsSnapshotOHLC",
                "candle", "marketCandle", "realtimePayload"}
    for match in re.finditer(r"^    (?:private )?func (\w+)\(", core, re.M):
        if match[1].startswith("testChartDataPipeline") or match[1] in selected:
            end = core.index("\n    }", match.start()) + len("\n    }")
            methods.append(core[match.start():end])
    (tests / "PipelineChecks.swift").write_text(
        "import Foundation\nimport XCTest\n@testable import TradeTool\nfinal class PipelineChecks: XCTestCase {\n"
        'private let stream = ChartStreamKey(symbol: "BTCUSDC", interval: "1h")\n'
        + "\n".join(methods) + "\n}\n")
    (destination / "Package.swift").write_text(
        '// swift-tools-version: 6.0\nimport PackageDescription\n'
        'let package = Package(name: "ChartRecoveryChecks", platforms: [.macOS(.v14)], '
        'targets: [.target(name: "TradeTool", path: "Sources"), '
        '.testTarget(name: "ChartRecoveryTests", dependencies: ["TradeTool"], path: "Tests")], '
        'swiftLanguageModes: [.v5])\n')
    (destination / "production-inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
    command = ["swift", "test", "--package-path", str(destination)]
    if test_filter:
        command += ["--filter", test_filter]
    return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", nargs="?", type=Path)
    parser.add_argument("--model-source", type=Path)
    parser.add_argument("--filter")
    args = parser.parse_args()
    if args.destination:
        args.destination.mkdir(parents=True, exist_ok=True)
        raise SystemExit(run(args.destination.resolve(), args.model_source, args.filter))
    with tempfile.TemporaryDirectory(prefix="chart-recovery-") as folder:
        raise SystemExit(run(Path(folder), args.model_source, args.filter))
