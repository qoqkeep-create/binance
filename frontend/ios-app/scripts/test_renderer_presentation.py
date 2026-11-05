#!/usr/bin/env python3
"""Run production presentation observers and stream watermarks without an iOS runtime."""
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

    domain = read(APP / "Features/ChartEngine/Domain/ChartCandle.swift")
    identifiers = domain[:domain.index("/// A fixed-size annotation")]
    state = read(APP / "Features/ChartEngine/Scene/RenderState.swift")
    identifiers += state[state.index("struct ChartPresentationID:"):state.index("struct RenderState:")]
    (sources / "PresentationIdentity.swift").write_text(identifiers)
    health = APP / "Features/ChartEngine/Rendering/Metal/MetalRendererHealth.swift"
    (sources / health.name).write_text(read(health))

    core = read(IOS / "TradeToolTests/ChartEngineCoreTests.swift")
    diagnostics = read(IOS / "TradeToolTests/ServerSwitchingTests.swift")
    methods = []
    names = ["testFirstPresentationMatchesTheSubmittedStreamAndEpoch",
             "testLivePresentationWatermarkFollowsCurrentStreamAndRejectsOldGPUCallbacks",
             "testPresentationHealthRingIsFixedAndOrdered",
             "testDroppedPresentationDiagnosticsAreBoundedAndOrdered",
             "testCommandBufferFailureSummariesAreBoundedAndOrdered",
             "testPresentationObserverIgnoresZeroAndCallsOnceOutsideHealthLock"]
    for name in names:
        fixture = diagnostics if name == names[-1] else core
        begin = fixture.index("    func " + name + "(")
        end = fixture.index("\n    }", begin) + len("\n    }")
        methods.append(fixture[begin:end])
    (tests / "PresentationTests.swift").write_text(
        "import Foundation\nimport XCTest\n@testable import TradeTool\n"
        "final class PresentationTests: XCTestCase {\n"
        'private let stream = ChartStreamKey(symbol: "BTCUSDC", interval: "1h")\n'
        + "\n".join(methods) + "\n}\n")
    (destination / "Package.swift").write_text(
        '// swift-tools-version: 6.0\nimport PackageDescription\n'
        'let package = Package(name: "RendererPresentationChecks", platforms: [.macOS(.v14)], '
        'targets: [.target(name: "TradeTool", path: "Sources"), '
        '.testTarget(name: "PresentationTests", dependencies: ["TradeTool"], path: "Tests")], '
        'swiftLanguageModes: [.v5])\n')
    (destination / "production-inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
    return subprocess.run(["swift", "test", "--package-path", str(destination)], check=False).returncode


if __name__ == "__main__":
    if len(sys.argv) > 1:
        target = Path(sys.argv[1]).resolve()
        target.mkdir(parents=True, exist_ok=True)
        raise SystemExit(run(target))
    with tempfile.TemporaryDirectory(prefix="renderer-presentation-") as folder:
        raise SystemExit(run(Path(folder)))
