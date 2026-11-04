#!/usr/bin/env python3
"""Exercise the actual capital view's read/selection and submission methods.

Only SwiftUI state wrappers and the store transport are replaced. All requests
stay in an in-memory fixture; no wallet or exchange endpoint is contacted.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys
import tempfile

IOS = Path(__file__).resolve().parents[1]
APP = IOS / "TradeTool"


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        if source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise ValueError(marker)


def generate(destination):
    sources = destination / "Sources/CapitalChecks"
    tests = destination / "Tests/CapitalChecksTests"
    sources.mkdir(parents=True, exist_ok=True)
    tests.mkdir(parents=True, exist_ok=True)
    view_path = APP / "Features/USDT/USDTAccountViews.swift"
    view = block(view_path.read_text(), "struct USDTCapitalView: View")
    properties = view.split("struct USDTCapitalView: View {", 1)[1].split("  var body: some View {", 1)[0]
    properties = properties.replace("  @Environment(\\.dismiss) private var dismiss", "  var dismiss: () -> Void = {}")
    properties = properties.replace("  @EnvironmentObject private var store: USDTStore", "  let store: USDTStore")
    properties = re.sub(r"^  @(?:Environment|Namespace).*\n", "", properties, flags=re.M)
    properties = properties.replace("@State private var", "var").replace("private var", "var")
    properties = properties.replace("init(initialTab: Tab = .move) { _tab = State(initialValue: initialTab) }", "init(store: USDTStore, initialTab: Tab = .move) { self.store = store; tab = initialTab }")
    assert "@" not in properties, "Unmapped platform wrapper"
    methods = "\n".join(block(view, marker).replace("private func", "func") for marker in (
        "private func apply(", "private func load()", "private func execute()"))
    if "private func selectTab(" in view:
        methods += "\n" + block(view, "private func selectTab(").replace("private func", "func")
    tabs = view.split("  private var tabs: some View {", 1)[1].split("  private var walletContent:", 1)[0]
    disabled = re.findall(r"\.disabled\(([^\n]+)\)", tabs)[-1]
    tap = re.search(r"Button \{ ([^}]+) \} label:", tabs).group(1)
    methods += f"\n  var tabsDisabled: Bool {{ {disabled} }}\n  func tap(_ item: Tab) {{ guard !tabsDisabled else {{ return }}; {tap} }}\n"
    (sources / "Capital.swift").write_text("import Foundation\n@MainActor\nfinal class CapitalHarness {\n" + properties + methods + "\n}\n")
    realtime_path = APP / "Core/Networking/RealtimeClient.swift"
    store_path = APP / "Features/USDT/USDTStore.swift"
    (sources / "JSONValue.swift").write_text("import Foundation\n" + block(realtime_path.read_text(), "enum JSONValue:") + "\n" + block(store_path.read_text(), "extension JSONValue {"))
    (sources / "Store.swift").write_text('''import Foundation
@MainActor
final class USDTStore {
  var scope = UUID().uuidString
  var requests: [(path: String, payload: [String: JSONValue])] = []
  var waiting: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  var refreshes = 0
  func send(_ path: String, _ payload: [String: JSONValue]) async throws -> JSONValue {
    let index = requests.count
    requests.append((path, payload))
    return try await withCheckedThrowingContinuation { waiting[index] = $0 }
  }
  func refresh() async { refreshes += 1 }
  func finish(_ index: Int, _ result: JSONValue) { waiting.removeValue(forKey: index)?.resume(returning: result) }
  func fail(_ index: Int) { waiting.removeValue(forKey: index)?.resume(throwing: FixtureError.delayed) }
}
enum FixtureError: LocalizedError { case delayed; var errorDescription: String? { "fixture delayed failure" } }
''')
    (tests / "CapitalChecksTests.swift").write_text(TESTS)
    (destination / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CapitalChecks", platforms: [.macOS(.v14)], targets: [
  .target(name: "CapitalChecks"), .testTarget(name: "CapitalChecksTests", dependencies: ["CapitalChecks"])
], swiftLanguageModes: [.v5])
''')
    inputs = [view_path, realtime_path, store_path, Path(__file__).resolve()]
    (destination / "production-inputs.json").write_text(json.dumps({
        str(path.relative_to(IOS)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in inputs}, indent=2) + "\n")


TESTS = '''import Foundation
import XCTest
@testable import CapitalChecks
@MainActor
final class CapitalChecksTests: XCTestCase {
  func waitForRequests(_ count: Int, _ store: USDTStore) async {
    for _ in 0..<500 {
      if store.requests.count >= count { return }
      try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Expected \\(count) requests, received \\(store.requests.count)")
  }
  func result(_ action: String, amount: String = "10", status: String = "normalization_required") -> JSONValue {
    .object(["operation": .string(action), "operation_amount": .string(amount), "status": .string(status), "plan_token": .string("fixture-plan")])
  }
  func testTabsSelectImmediatelyWhileReadIsPending() async {
    let store = USDTStore(), view: CapitalHarness
    view = CapitalHarness(store: store)
    let first = Task { await view.load() }
    await waitForRequests(1, store)
    XCTAssertFalse(view.tabsDisabled, "Wallet reads must not disable selection or dim selected text")
    view.tap(.transfer)
    XCTAssertEqual(view.tab, .transfer, "Tap must select before the old read finishes")
    store.finish(0, result("to_spot"))
    await first.value
  }
  func testOldMoveReadCannotPullUserBackOutOfRecords() async {
    let store = USDTStore(), view: CapitalHarness
    view = CapitalHarness(store: store)
    let first = Task { await view.load() }
    await waitForRequests(1, store)
    // Simulates the current .task cancellation arriving after a callback.
    view.tab = .records
    store.finish(0, result("to_spot", status: "collection_pending"))
    await first.value
    XCTAssertEqual(view.tab, .records)
    XCTAssertEqual(view.preview, .null)
  }
  func testOldTabFailureCannotWriteItsErrorIntoNewTab() async {
    let store = USDTStore(), view: CapitalHarness
    view = CapitalHarness(store: store)
    let first = Task { await view.load() }
    await waitForRequests(1, store)
    view.tab = .transfer
    store.fail(0)
    await first.value
    XCTAssertEqual(view.notice, "")
  }
  func testCancelledReadDoesNotDisplayTransportFailure() async {
    let store = USDTStore(), view: CapitalHarness
    view = CapitalHarness(store: store)
    let first = Task { await view.load() }
    await waitForRequests(1, store)
    first.cancel()
    store.fail(0)
    await first.value
    XCTAssertEqual(view.notice, "")
  }
  func testLatestReadOwnsLoadingAndResult() async {
    let store = USDTStore(), view: CapitalHarness
    view = CapitalHarness(store: store)
    let first = Task { await view.load() }
    await waitForRequests(1, store)
    let second = Task { await view.load() }
    await waitForRequests(2, store)
    if store.requests.count == 2 {
      store.finish(0, result("to_spot", amount: "1"))
      await first.value
      XCTAssertFalse(view.canSubmit, "An obsolete completion must not finish the newer read")
      store.finish(1, result("to_spot", amount: "2"))
      await second.value
      XCTAssertEqual(view.preview.value("operation_amount"), "2")
      XCTAssertTrue(view.canSubmit)
    } else {
      store.finish(0, result("to_spot"))
      await first.value; await second.value
    }
  }
  func testOlderSameActionSuccessCannotOverwriteNewerSuccess() async {
    let store = USDTStore(), view: CapitalHarness
    view = CapitalHarness(store: store)
    let first = Task { await view.load() }
    await waitForRequests(1, store)
    let second = Task { await view.load() }
    await waitForRequests(2, store)
    if store.requests.count == 2 {
      store.finish(1, result("to_spot", amount: "2"))
      await second.value
      store.finish(0, result("to_spot", amount: "1"))
      await first.value
      XCTAssertEqual(view.preview.value("operation_amount"), "2")
    } else {
      store.finish(0, result("to_spot"))
      await first.value; await second.value
    }
  }
  func testScopeChangeRejectsReadSuccessAndError() async {
    for fail in [false, true] {
      let store = USDTStore(), view: CapitalHarness
      view = CapitalHarness(store: store)
      let read = Task { await view.load() }
      await waitForRequests(1, store)
      store.scope = UUID().uuidString
      if fail { store.fail(0) } else { store.finish(0, result("to_spot")) }
      await read.value
      XCTAssertEqual(view.preview, .null)
      XCTAssertEqual(view.notice, "")
    }
  }
  func testPendingAndSubmittedOperationsStillLockTabsAndKeepIdentity() async {
    let store = USDTStore(), view: CapitalHarness
    view = CapitalHarness(store: store)
    view.preview = result("to_spot")
    let requestID = view.requestID, storageKey = view.requestStorageKey
    defer { UserDefaults.standard.removeObject(forKey: storageKey) }
    let execute = Task { await view.execute() }
    await waitForRequests(1, store)
    XCTAssertTrue(view.tabsDisabled)
    view.tap(.transfer)
    XCTAssertEqual(view.tab, .move)
    XCTAssertEqual(store.requests[0].path, "/v1/trade/capital/wallet/execute")
    XCTAssertEqual(store.requests[0].payload["request_id"], .string(requestID))
    XCTAssertEqual(store.requests[0].payload["expected_plan"], .string("fixture-plan"))
    XCTAssertEqual(UserDefaults.standard.string(forKey: storageKey), requestID)
    store.finish(0, result("to_spot", status: "collection_pending"))
    await execute.value
    XCTAssertTrue(view.tabsDisabled)
    XCTAssertEqual(view.requestID, requestID)
    XCTAssertEqual(store.refreshes, 1)
  }
}
'''


def run(destination):
    generate(destination)
    return subprocess.run(["swift", "test", "--package-path", str(destination)], check=False).returncode


if __name__ == "__main__":
    if len(sys.argv) > 1:
        target = Path(sys.argv[1]).resolve()
        target.mkdir(parents=True, exist_ok=True)
        sys.exit(run(target))
    with tempfile.TemporaryDirectory(prefix="capital-tabs-") as directory:
        sys.exit(run(Path(directory)))
