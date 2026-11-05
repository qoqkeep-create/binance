#!/usr/bin/env python3
"""Exercise the real fee helpers and position-card call sites without a simulator."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

IOS = Path(__file__).resolve().parents[1]
APP = IOS / "TradeTool"


def generate(destination, view_source=None):
    sources, tests = destination / "Sources", destination / "Tests"
    sources.mkdir(parents=True, exist_ok=True)
    tests.mkdir(exist_ok=True)
    view_path = APP / "Features/USDT/USDTTradingViews.swift"
    view = (view_source or view_path).read_text()
    helpers = view.split("struct USDTTradeView: View {", 1)[0].replace("import SwiftUI", "import Foundation")
    (sources / "PositionFees.swift").write_text(helpers)
    realtime_path = APP / "Core/Networking/RealtimeClient.swift"
    raw = realtime_path.read_text()
    model = "enum JSONValue:" + raw.split("enum JSONValue:", 1)[1].split("\n@MainActor\nfinal class RealtimeClient", 1)[0]
    store_path = APP / "Features/USDT/USDTStore.swift"
    accessors = "extension JSONValue {" + store_path.read_text().split("extension JSONValue {", 1)[1].split("\n@MainActor", 1)[0]
    (sources / "JSONValue.swift").write_text("import Foundation\n" + model + "\n" + accessors)
    number_path = APP / "Core/Presentation/DisplayNumber.swift"
    (sources / "DisplayNumber.swift").write_text(number_path.read_text())
    fixture_path = IOS / "TradeToolTests/DisplayNumberTests.swift"
    fixture = fixture_path.read_text().split("final class PositionEntryFeePresentationTests:", 1)[1]
    fixture = "import XCTest\n@testable import TradeTool\nfinal class PositionEntryFeePresentationTests:" + fixture
    card = view.split("  private func positionCard(_ row: JSONValue)", 1)[1].split("  private func inline(", 1)[0]
    fee = re.search(r"Text\((Position\w+Presentation\.[^\n]+)\)\.foregroundStyle\(WebTheme\.danger\)", card).group(1)
    fee = fee.replace("valuation?.price", "price")
    profit = re.search(r'"持仓盈亏：", ([^\n]+),\n', card).group(1)
    profit = profit.replace("valuation?.profit", "profit").replace("$0.profit", "$0").replace("valuation", "profit")
    fixture = re.sub(r"^  private func cardFee[^\n]+$", lambda _: "  private func cardFee(_ row: JSONValue, price: Decimal? = nil) -> String { " + fee + " }", fixture, flags=re.M)
    fixture = re.sub(r"^  private func cardProfit[^\n]+$", lambda _: "  private func cardProfit(_ profit: Decimal?) -> String { " + profit + " }", fixture, flags=re.M)
    warning = re.search(r'if !(.*?)\.isEmpty \{\n\s*Text\(', card).group(1)
    fixture = re.sub(r"^  private func cardStrategyError[^\n]+$", lambda _: "  private func cardStrategyError(_ row: JSONValue) -> String { " + warning + " }", fixture, flags=re.M)
    (tests / "PositionFeeTests.swift").write_text(fixture)
    (destination / "Package.swift").write_text(
        '// swift-tools-version: 6.0\nimport PackageDescription\n'
        'let package = Package(name: "PositionFeeChecks", platforms: [.macOS(.v14)], '
        'targets: [.target(name: "TradeTool", path: "Sources"), '
        '.testTarget(name: "PositionFeeTests", dependencies: ["TradeTool"], path: "Tests")], '
        'swiftLanguageModes: [.v5])\n')
    manifest = {
        str(path.relative_to(IOS)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [view_path, realtime_path, store_path, number_path, fixture_path]
    }
    manifest[str(view_path.relative_to(IOS))] = hashlib.sha256(view.encode()).hexdigest()
    (destination / "production-inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")


def run(destination, view_source=None):
    generate(destination, view_source)
    return subprocess.run(["swift", "test", "--package-path", str(destination)], check=False).returncode


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, nargs="?")
    parser.add_argument("--view-source", type=Path, help="Replay a saved production view, including its real rendering expressions.")
    args = parser.parse_args()
    if args.destination:
        raise SystemExit(run(args.destination.resolve(), args.view_source))
    with tempfile.TemporaryDirectory(prefix="position-fees-") as folder:
        raise SystemExit(run(Path(folder), args.view_source))
