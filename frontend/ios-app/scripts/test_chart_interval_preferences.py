#!/usr/bin/env python3
"""Run the production shortcut preference model and its regression tests on macOS."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

IOS = Path(__file__).resolve().parents[1]


def run(destination):
    sources, tests = destination / "Sources", destination / "Tests"
    sources.mkdir(parents=True, exist_ok=True)
    tests.mkdir(exist_ok=True)
    chart_path = IOS / "TradeTool/Features/Chart/MarketChartView.swift"
    interval_path = IOS / "TradeTool/Core/Models/MarketKline.swift"
    tests_path = IOS / "TradeToolTests/ServerSwitchingTests.swift"
    chart = chart_path.read_text()
    model = chart[chart.index("enum ChartIntervalPreferences {"):chart.index("private struct ChartAutoFitToggleStyle:")]
    interval = interval_path.read_text().split("struct MarketKlineHistoryResponse:", 1)[0]
    (sources / "IntervalPreferences.swift").write_text(interval + "\n" + model)
    fixture = tests_path.read_text()
    fixture = fixture[fixture.index("    func testIntervalFavoritesKeepDefaultsAndNormalizeStoredValues()"):fixture.index("final class StrategyDraftEditingTests:")]
    (tests / "IntervalPreferencesTests.swift").write_text(
        "import XCTest\n@testable import TradeTool\nfinal class IntervalPreferencesTests: XCTestCase {\n" + fixture)
    (destination / "Package.swift").write_text(
        '// swift-tools-version: 6.0\nimport PackageDescription\n'
        'let package = Package(name: "IntervalPreferenceChecks", platforms: [.macOS(.v14)], '
        'targets: [.target(name: "TradeTool", path: "Sources"), '
        '.testTarget(name: "IntervalTests", dependencies: ["TradeTool"], path: "Tests")], '
        'swiftLanguageModes: [.v5])\n')
    (destination / "production-inputs.json").write_text(json.dumps({
        str(path.relative_to(IOS)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [chart_path, interval_path, tests_path]
    }, indent=2) + "\n")
    return subprocess.run(["swift", "test", "--package-path", str(destination)], check=False).returncode


if __name__ == "__main__":
    if len(sys.argv) > 1:
        target = Path(sys.argv[1]).resolve()
        target.mkdir(parents=True, exist_ok=True)
        sys.exit(run(target))
    with tempfile.TemporaryDirectory(prefix="chart-interval-preferences-") as folder:
        sys.exit(run(Path(folder)))
