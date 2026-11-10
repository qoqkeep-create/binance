#!/usr/bin/env python3
"""Run actual unified-order presentation without network or simulator."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from test_launch_layout import block
from test_strategy_selection_confirmation import APP, IOS, generate


def run(destination):
    generate(destination)
    for test in (destination / "Tests").glob("*.swift"):
        test.unlink()
    view = APP / "Features/USDT/USDTTradingViews.swift"
    content = view.read_text()
    source = block(content, "enum PositionEntryFeePresentation {") + "\n" + block(content, "struct OrderCardPresentation {")
    (destination / "Sources/OrderCardPresentation.swift").write_text("import Foundation\n" + source)
    number = APP / "Core/Presentation/DisplayNumber.swift"
    (destination / "Sources/DisplayNumber.swift").write_text(number.read_text())
    tests = IOS / "TradeToolTests/ServerSwitchingTests.swift"
    suite = block(tests.read_text(), "@MainActor\nfinal class OrderCardPresentationTests:")
    (destination / "Tests/OrderCardPresentationTests.swift").write_text(
        "import Foundation\nimport XCTest\n@testable import TradeTool\n" + suite)
    manifest = destination / "production-inputs.json"
    inputs = json.loads(manifest.read_text())
    for path in [view, number, tests, Path(__file__).resolve()]:
        inputs[str(path.relative_to(IOS))] = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest.write_text(json.dumps(inputs, indent=2) + "\n")
    return subprocess.run(["swift", "test", "--package-path", str(destination)], check=False).returncode


if __name__ == "__main__":
    if len(sys.argv) > 1:
        target = Path(sys.argv[1]).resolve()
        target.mkdir(parents=True, exist_ok=True)
        sys.exit(run(target))
    with tempfile.TemporaryDirectory(prefix="order-card-checks-") as directory:
        sys.exit(run(Path(directory)))
