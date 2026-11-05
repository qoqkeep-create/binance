#!/usr/bin/env python3
"""Render the production SwiftUI order overlay on macOS without an iOS simulator."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

IOS = Path(__file__).resolve().parents[1]
APP = IOS / "TradeTool"


def run(destination):
    sources, tests = destination / "Sources", destination / "Tests"
    sources.mkdir(parents=True, exist_ok=True)
    tests.mkdir(exist_ok=True)
    inputs = {}

    def read(path):
        raw = path.read_bytes()
        inputs[str(path.relative_to(IOS))] = hashlib.sha256(raw).hexdigest()
        return raw.decode()

    source = read(APP / "Features/Chart/ChartOrderDrawingView.swift")
    drawing = source[:source.index("struct ChartPositionLine:")]
    drawing += source[source.index("struct ChartPriceLineLabelLayout {"):]
    drawing = drawing.replace("import UIKit", "import AppKit").replace("UIFont.systemFont", "NSFont.systemFont")
    (sources / "OrderDrawing.swift").write_text(drawing)
    scene = read(APP / "Features/ChartEngine/Host/KlineChartSceneView.swift")
    (sources / "Projection.swift").write_text(scene[:scene.index("@MainActor\nfinal class KlineChartSceneController")])
    (sources / "DisplayNumber.swift").write_text(read(APP / "Core/Presentation/DisplayNumber.swift"))
    # Theme adapters only: all geometry, clipping, labels and gestures above are production code.
    (sources / "Theme.swift").write_text('''import SwiftUI
enum BinanceTheme {
  static let negative = Color.red
  static let positive = Color.green
  static let accentText = Color.yellow
  static let background = Color.black
  static let onColor = Color.white
  static let primaryText = Color.white
  static let secondaryText = Color.gray
  static let border = Color.gray
  static let surface = Color.black
}
''')
    fixture = read(IOS / "TradeToolTests/ChartEngineCoreTests.swift")
    start = fixture.index("final class ChartOrderOverlayRenderingTests:")
    end = fixture.index("final class ChartPositionContextTests:", start)
    (tests / "OverlayTests.swift").write_text(
        "import SwiftUI\nimport XCTest\n@testable import TradeTool\n@MainActor\n" + fixture[start:end].removesuffix("@MainActor\n"))
    (destination / "Package.swift").write_text(
        '// swift-tools-version: 6.0\nimport PackageDescription\n'
        'let package = Package(name: "OrderOverlayChecks", platforms: [.macOS(.v14)], '
        'targets: [.target(name: "TradeTool", path: "Sources"), '
        '.testTarget(name: "OverlayTests", dependencies: ["TradeTool"], path: "Tests")], '
        'swiftLanguageModes: [.v5])\n')
    (destination / "production-inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
    return subprocess.run(["swift", "test", "--package-path", str(destination)], check=False).returncode


if __name__ == "__main__":
    if len(sys.argv) > 1:
        raise SystemExit(run(Path(sys.argv[1]).resolve()))
    with tempfile.TemporaryDirectory(prefix="order-overlay-") as folder:
        raise SystemExit(run(Path(folder)))
