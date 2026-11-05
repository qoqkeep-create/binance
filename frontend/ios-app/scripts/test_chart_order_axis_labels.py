#!/usr/bin/env python3
"""Run production order-axis geometry and Metal pixel regressions on macOS."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

IOS = Path(__file__).resolve().parents[1]
APP = IOS / "TradeTool"
ENGINE = APP / "Features/ChartEngine"


def run(destination):
    sources, tests = destination / "Sources", destination / "Tests"
    sources.mkdir(parents=True, exist_ok=True)
    tests.mkdir(exist_ok=True)
    inputs = []

    def read(path):
        inputs.append(path)
        return path.read_text()

    for directory in ["Domain", "Data", "Indicators", "Scene", "Viewport"]:
        for path in sorted((ENGINE / directory).glob("*.swift")):
            (sources / path.name).write_text(read(path))
    for path in [APP / "Core/Models/MarketKline.swift", APP / "Core/Presentation/DisplayNumber.swift"]:
        (sources / path.name).write_text(read(path))
    realtime = read(APP / "Core/Networking/RealtimeClient.swift")
    payload = realtime.split("struct RealtimeKlineEventPayload:", 1)[1].split("struct MarketTickerPayload:", 1)[0]
    (sources / "RealtimeKlinePayload.swift").write_text(
        "import Foundation\nstruct RealtimeKlineEventPayload:" + payload)

    metal = ENGINE / "Rendering/Metal"
    shader = metal / "ChartShaders.metal"
    read(shader)
    for name in ["MetalRenderer", "MetalResourceRing", "MetalGlyphTextureCache", "MetalGlyphAtlas",
                 "MetalRendererHealth", "MetalRendererFailurePolicy"]:
        source = read(metal / (name + ".swift"))
        if name == "MetalRenderer":
            # SwiftPM has no app default library; compile the exact production shader.
            source = source.replace("device.makeDefaultLibrary()",
                "try? device.makeLibrary(source: String(contentsOfFile: "
                + json.dumps(str(shader)) + ", encoding: .utf8), options: nil)")
        (sources / (name + ".swift")).write_text(source)

    fixture = read(IOS / "TradeToolTests/ChartEngineCoreTests.swift")
    crosshair_begin = fixture.index("    @MainActor\n    func testCrosshairLabelsFitTimeAndPriceAxesWithoutActionIcon()")
    crosshair_end = fixture.index("    @MainActor\n    func testTimeAxisAndPanelFootersKeepCrosshairInSync()", crosshair_begin)
    begin = fixture.index("    func testPlotStartsAtCanvasEdgeAndRetainsSquarePriceArea()")
    end = fixture.index("    private func makeOffscreenState(", begin)
    helper_begin = fixture.index("    private func marketCandle(")
    helper_end = fixture.index("    /// The fixed right-axis marker", helper_begin)
    (tests / "AxisPriceLabelTests.swift").write_text(
        "import Foundation\nimport Metal\nimport XCTest\n@testable import TradeTool\n"
        "final class AxisPriceLabelTests: XCTestCase {\n"
        'private let stream = ChartStreamKey(symbol: "BTCUSDC", interval: "1h")\n'
        + fixture[crosshair_begin:crosshair_end]
        + fixture[begin:end] + fixture[helper_begin:helper_end] + "}\n")
    (destination / "Package.swift").write_text(
        '// swift-tools-version: 6.0\nimport PackageDescription\n'
        'let package = Package(name: "OrderAxisChecks", platforms: [.macOS(.v14)], '
        'targets: [.target(name: "TradeTool", path: "Sources"), '
        '.testTarget(name: "AxisPriceTests", dependencies: ["TradeTool"], path: "Tests")], '
        'swiftLanguageModes: [.v5])\n')
    (destination / "production-inputs.json").write_text(json.dumps({
        str(path.relative_to(IOS)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs
    }, indent=2) + "\n")
    return subprocess.run(["swift", "test", "--package-path", str(destination)], check=False).returncode


if __name__ == "__main__":
    if len(sys.argv) > 1:
        target = Path(sys.argv[1]).resolve()
        target.mkdir(parents=True, exist_ok=True)
        sys.exit(run(target))
    with tempfile.TemporaryDirectory(prefix="chart-order-axis-") as folder:
        sys.exit(run(Path(folder)))
