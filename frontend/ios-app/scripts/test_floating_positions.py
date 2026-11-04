#!/usr/bin/env python3
"""Run real shared-position, valuation, and PiP scheduling tests without a simulator.

Production Store, API request/JSON, snapshot, quote ownership, presentation, and
frame-delivery code are extracted unchanged. Video buffers use the production
renderer with AppKit font/context adapters on macOS; all API calls use in-memory
fixtures and no network request occurs.
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
    for fixture in (destination / "Tests").glob("*.swift"):
        fixture.unlink()
    floating_path = APP / "Features/USDT/FloatingPositionsView.swift"
    pip_path = APP / "Features/USDT/FloatingPositionsPiP.swift"
    floating = floating_path.read_text()
    pure = floating[floating.index("enum FloatingPiPActivation:"):floating.index("/// One read-only position snapshot")]
    pure += floating[floating.index("enum FloatingPanelPlacement {"):floating.index("private struct FloatingPositionsOverlay:")]
    (destination / "Sources/FloatingPresentation.swift").write_text("import Foundation\n" + pure)
    pip = pip_path.read_text()
    pure = pip[pip.index("struct FloatingPiPSnapshot:"):pip.index("/// The system owns the external window;")]
    (destination / "Sources/PiPScheduling.swift").write_text("import Foundation\n" + pure)
    renderer = pip[pip.index("enum FloatingPiPFrameRenderer {"):]
    renderer = renderer.replace("UIColor", "NSColor").replace("UIFont.", "NSFont.")
    (destination / "Sources/PiPFrameRenderer.swift").write_text(
        "import AppKit\nimport AVFoundation\n" +
        "func UIGraphicsPushContext(_ context: CGContext) {\n"
        "  NSGraphicsContext.saveGraphicsState()\n"
        "  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)\n}\n"
        "func UIGraphicsPopContext() { NSGraphicsContext.restoreGraphicsState() }\n" + renderer)
    number_path = APP / "Core/Presentation/DisplayNumber.swift"
    (destination / "Sources/DisplayNumber.swift").write_text(number_path.read_text())
    fixture_paths = [IOS / "TradeToolTests/FloatingPositionsTests.swift", IOS / "TradeToolTests/PositionLiveValuationTests.swift"]
    tests = fixture_paths[0].read_text()
    tests = tests.replace("import UIKit\n", "")
    begin = tests.index("  @MainActor\n  func testPictureInPictureProducesReadyVideoFrameFromSnapshot")
    end = tests.index("  func testDecimalSnapshotPreservesSmallPriceAndSignedProfit", begin)
    tests = tests[:begin] + tests[end:]
    (destination / "Tests/FloatingPositionsTests.swift").write_text(tests)
    (destination / "Tests/PositionLiveValuationTests.swift").write_text(fixture_paths[1].read_text())
    live_path = APP / "Features/USDT/PositionLiveActivity.swift"
    live = live_path.read_text()
    identity = live[live.index("enum PositionLiveIdentity {"):live.index("/// ActivityKit owns the surface;")]
    (destination / "Sources/LiveIdentity.swift").write_text("import Foundation\nimport CryptoKit\n" + identity)
    schema_path = IOS / "Shared/PositionLiveActivityAttributes.swift"
    (destination / "Sources/LiveSchema.swift").write_text(schema_path.read_text())
    live_tests = IOS / "TradeToolTests/PositionLiveActivityTests.swift"
    (destination / "Tests/PositionLiveActivityTests.swift").write_text(live_tests.read_text())
    manifest_path = destination / "production-inputs.json"
    manifest = json.loads(manifest_path.read_text())
    for path in [floating_path, pip_path, number_path, live_path, schema_path, live_tests, *fixture_paths]:
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
    with tempfile.TemporaryDirectory(prefix="floating-positions-") as directory:
        sys.exit(run(Path(directory)))
