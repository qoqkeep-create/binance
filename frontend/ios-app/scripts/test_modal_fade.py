#!/usr/bin/env python3
"""Render the actual modal card/backdrop composition without launching a simulator."""
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
    path = IOS / "TradeTool/Features/USDT/USDTComponents.swift"
    raw = path.read_text()
    start = raw.index("private struct WebModalCloseKey:")
    end = raw.index("extension View {", start)
    source = "import SwiftUI\n" + raw[start:end]
    source += "extension View { func webModalCard() -> some View { modifier(WebModalCard()) } }\n"
    (sources / "Modal.swift").write_text(source)
    fixture = IOS / "TradeToolTests/AppearanceTests.swift"
    body = fixture.read_text()
    start = body.index("@MainActor\nfinal class WebModalRenderingTests:")
    end = body.index("final class AppearanceTests:", start)
    (tests / "ModalTests.swift").write_text("import SwiftUI\nimport XCTest\n@testable import TradeTool\n" + body[start:end])
    (destination / "Package.swift").write_text(
        '// swift-tools-version: 6.0\nimport PackageDescription\n'
        'let package = Package(name: "ModalFadeChecks", platforms: [.macOS(.v14)], '
        'targets: [.target(name: "TradeTool", path: "Sources"), '
        '.testTarget(name: "ModalTests", dependencies: ["TradeTool"], path: "Tests")], '
        'swiftLanguageModes: [.v5])\n')
    (destination / "production-inputs.json").write_text(json.dumps({
        str(p.relative_to(IOS)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [path, fixture]
    }, indent=2) + "\n")
    return subprocess.run(["swift", "test", "--package-path", str(destination)], check=False).returncode


if __name__ == "__main__":
    if len(sys.argv) > 1:
        raise SystemExit(run(Path(sys.argv[1]).resolve()))
    with tempfile.TemporaryDirectory(prefix="modal-fade-") as folder:
        raise SystemExit(run(Path(folder)))
