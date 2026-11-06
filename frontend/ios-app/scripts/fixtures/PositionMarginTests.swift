import Foundation
import XCTest
@testable import TradeTool

@MainActor
final class PositionMarginTests: XCTestCase {
  private func data(_ ratio: String = "35", now: Date = .now) -> JSONValue {
    .object(["supported": .bool(true), "observed_at": .number(now.timeIntervalSince1970 * 1000),
      "max_age_seconds": .string("20"), "margin_ratio_percent": .string(ratio),
      "liquidation_reached": .bool(false)])
  }
  func testColorThresholdsAndUnclampedLiquidationRatio() {
    for (ratio, expected) in [("0", PositionMarginLevel.normal), ("49.99", .normal), ("50", .caution),
      ("79.99", .caution), ("80", .danger), ("100", .danger), ("121.25", .danger)] {
      let value = PositionMarginPresentation(snapshot: data(ratio), isCurrent: true)
      XCTAssertEqual(value.level, expected, ratio)
      XCTAssertFalse(value.percentText.contains(","))
    }
    XCTAssertEqual(PositionMarginPresentation(snapshot: data("121.25"), isCurrent: true).percentText, "121.25%")
  }
  func testCompactBadgeKeepsTwoDigitsAndLiquidationWarning() {
    for (ratio, expected) in [("0", "00%"), ("0.99", "00%"), ("3.45", "03%"), ("9.99", "09%"),
      ("49.99", "49%"), ("50", "50%"), ("79.99", "79%"), ("80", "80%"),
      ("99.99", "99%"), ("100", "100%"), ("121.25", "121%")] {
      XCTAssertEqual(PositionMarginPresentation(snapshot: data(ratio), isCurrent: true).badgePercentText, expected)
    }
    XCTAssertEqual(PositionMarginPresentation(snapshot: data("3.45"), isCurrent: false).badgePercentText, "--%")
    XCTAssertEqual(PositionMarginPresentation(snapshot: .object([
      "supported": .bool(true), "liquidation_reached": .bool(true)]), isCurrent: true).badgePercentText, "100%")
  }
  func testUnavailableNeverLooksLikeGreenZero() {
    for snapshot in [JSONValue.null, .object([:]), data("NaN"), data("-1"),
      .object(["supported": .bool(false), "margin_ratio_percent": .string("0")])] {
      let value = PositionMarginPresentation(snapshot: snapshot, isCurrent: true)
      XCTAssertEqual(value.level, .unavailable)
      XCTAssertEqual(value.percentText, "--%")
    }
    XCTAssertEqual(PositionMarginPresentation(snapshot: data("0"), isCurrent: false).level, .unavailable)
    let negativeEquity: JSONValue = .object(["supported": .bool(true), "liquidation_reached": .bool(true)])
    let critical = PositionMarginPresentation(snapshot: negativeEquity, isCurrent: true)
    XCTAssertEqual(critical.level, .danger)
    XCTAssertEqual(critical.percentText, "100%")
  }
  func testConfirmedEmptyExchangeSnapshotDisplaysZeroEvenWithoutEquity() {
    let empty: JSONValue = .object(["supported": .bool(true), "positions": .array([]),
      "margin_ratio_percent": .null, "liquidation_reached": .bool(false)])
    XCTAssertEqual(PositionMarginPresentation(snapshot: empty, isCurrent: true).badgePercentText, "0%")
    XCTAssertEqual(PositionMarginPresentation(snapshot: empty, isCurrent: false).badgePercentText, "--%")
  }
  func testInvalidNumbersCannotBecomeZeroAndNonpositiveEquityCannotDivide() {
    for invalid in [JSONValue.null, .bool(false), .string("--"), .string("12x"), .string("NaN"), .number(.infinity)] {
      XCTAssertNil(PositionMarginNumber.decimal(invalid))
    }
    XCTAssertEqual(PositionMarginNumber.usage(.string("35"), equity: .string("80")), Decimal(string: "43.75"))
    XCTAssertNil(PositionMarginNumber.usage(.string("35"), equity: .string("0")))
    XCTAssertNil(PositionMarginNumber.usage(.string("35"), equity: .string("-80")))
    let critical: JSONValue = .object(["supported": .bool(true), "liquidation_reached": .bool(true),
      "margin_ratio_percent": .null])
    XCTAssertEqual(PositionMarginPresentation(snapshot: critical, isCurrent: true).badgePercentText, "100%")
  }
  func testOnlySuccessfulRecentPositionReadCanOverrideMarginFailureWithEmpty() async {
    let api = MarginFixtureAPI(), model = PositionMarginModel()
    let store = bound(api)
    XCTAssertEqual(model.exposure(in: store), .unknown)
    let positions = Task { await store.refreshPositions() }
    await wait(api, count: 1); await api.finish(0, value: .array([])); await positions.value
    let margin = Task { await model.refresh(store) }
    await wait(api, count: 2); await api.fail(1); await margin.value
    XCTAssertEqual(model.exposure(in: store), .empty)
    XCTAssertEqual(PositionMarginPresentation(snapshot: model.snapshot, isCurrent: false,
      exposure: model.exposure(in: store)).badgePercentText, "0%")
    XCTAssertEqual(model.exposure(in: store, now: .now.addingTimeInterval(21)), .unknown)
    let failed = Task { await store.refreshPositions() }
    await wait(api, count: 3); await api.fail(2); await failed.value
    XCTAssertEqual(model.exposure(in: store), .unknown, "Read failure must not confirm empty")
    store.revision += 1
    XCTAssertEqual(model.exposure(in: store), .unknown)
  }
  func testNewerAccountSnapshotWinsAndOrderOnlyRowsAreEmpty() async {
    let api = MarginFixtureAPI(), model = PositionMarginModel()
    let store = bound(api)
    let positions = Task { await store.refreshPositions() }
    await wait(api, count: 1)
    await api.finish(0, value: .array([.object(["id": .string("open")])]))
    await positions.value
    func account(_ quantity: String, at date: Date) -> JSONValue {
      .object(["supported": .bool(true), "observed_at": .number(date.timeIntervalSince1970 * 1000),
        "max_age_seconds": .number(20), "margin_ratio_percent": .string("25"),
        "positions": .array([.object(["quantity": .string(quantity), "open_order_initial_margin": .string("50")])])])
    }
    let monitor = Task { await model.monitor(store) }
    await wait(api, count: 2); await api.finish(1, value: account("0", at: .now.addingTimeInterval(-10)))
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(model.exposure(in: store), .open, "Older empty account snapshot cannot hide a newer position")
    let open = Task { await model.refresh(store, afterChange: true) }
    await wait(api, count: 3); await api.finish(2, value: account("10", at: .now.addingTimeInterval(1))); await open.value
    XCTAssertEqual(model.exposure(in: store), .open)
    let close = Task { await model.refresh(store, afterChange: true) }
    await wait(api, count: 4); await api.finish(3, value: account("0", at: .now.addingTimeInterval(1))); await close.value
    XCTAssertEqual(model.exposure(in: store), .empty)
    monitor.cancel(); await monitor.value
  }
  func testExchangePositionCannotBeHiddenByNewerEmptyAppList() async {
    let api = MarginFixtureAPI(), model = PositionMarginModel()
    let store = bound(api)
    let monitor = Task { await model.monitor(store) }
    await wait(api, count: 1)
    await api.finish(0, value: .object(["supported": .bool(true),
      "observed_at": .number(Date.now.addingTimeInterval(-1).timeIntervalSince1970 * 1000),
      "max_age_seconds": .number(20), "positions": .array([.object(["quantity": .string("10")])])]))
    for _ in 0..<20 { await Task.yield() }
    let positions = Task { await store.refreshPositions() }
    await wait(api, count: 2); await api.finish(1, value: .array([])); await positions.value
    XCTAssertEqual(model.exposure(in: store), .open)
    monitor.cancel(); await monitor.value
  }
  func testEventsDuringReadCoalesceIntoFreshFollowup() async {
    let api = MarginFixtureAPI(), model = PositionMarginModel()
    let store = bound(api)
    let first = Task { await model.refresh(store) }
    await wait(api, count: 1)
    await model.refresh(store, afterChange: true)
    await model.refresh(store, afterChange: true)
    await api.finish(0, value: data("5"))
    await wait(api, count: 2)
    let request = await api.requests[1]
    XCTAssertEqual(request.queryItems.first(where: { $0.name == "fresh" })?.value, "1")
    await api.finish(1, value: data("85")); await first.value
    XCTAssertEqual(model.snapshot.value("margin_ratio_percent"), "85")
    let count = await api.requests.count
    XCTAssertEqual(count, 2)
  }
  func testSuspensionDropsQueuedEventRead() async {
    let api = MarginFixtureAPI(), model = PositionMarginModel()
    let store = bound(api)
    let first = Task { await model.refresh(store) }
    await wait(api, count: 1); await model.refresh(store, afterChange: true)
    model.suspend()
    await api.finish(0, value: data("5")); await first.value
    XCTAssertEqual(model.snapshot, .null)
    let count = await api.requests.count
    XCTAssertEqual(count, 1)
  }
  func testPositionEventPublishesBeforeUnrelatedMetadataReadsFinish() async {
    let api = MarginFixtureAPI(), store = bound(api)
    let event = RealtimeServerMessage(version: 1, type: "event", requestId: nil, channel: "trading.position",
      event: "changed", key: nil, sequence: nil, timestamp: 0, data: nil, error: nil)
    store.receive(event); store.receive(event)
    for _ in 0..<200 {
      if await api.requests.count >= 1 { break }
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(store.positionDataRevision, 1, "Coalesced event must invalidate position/risk before metadata returns")
    XCTAssertEqual(store.liveRevision, 0)
    await api.finish(0, value: store.binding)
    await wait(api, count: 3)
    await api.finish(1, value: .array([])); await api.finish(2, value: .array([]))
    for _ in 0..<100 where store.liveRevision == 0 { await Task.yield() }
    XCTAssertEqual(store.liveRevision, 1)
  }
  func testHorizontalSwipeOnlyAndEdgesDoNotWrap() {
    XCTAssertEqual(PositionPageSwipe.destination(from: "positions", horizontal: -100, vertical: 10), "limits")
    XCTAssertEqual(PositionPageSwipe.destination(from: "limits", horizontal: -100, vertical: 0), "history")
    XCTAssertEqual(PositionPageSwipe.destination(from: "history", horizontal: 100, vertical: 0), "limits")
    XCTAssertEqual(PositionPageSwipe.destination(from: "limits", horizontal: 100, vertical: 0), "positions")
    XCTAssertNil(PositionPageSwipe.destination(from: "positions", horizontal: 100, vertical: 0))
    XCTAssertNil(PositionPageSwipe.destination(from: "history", horizontal: -100, vertical: 0))
    for (x, y) in [(10.0, 100.0), (40, 0), (60, 60), (100, 100), (.nan, 0), (.infinity, 0)] {
      XCTAssertNil(PositionPageSwipe.destination(from: "limits", horizontal: x, vertical: y))
    }
  }
  func testSnapshotExpirySuspensionAndTradingModeHeader() async {
    let api = MarginFixtureAPI()
    let store = bound(api)
    let model = PositionMarginModel()
    let monitor = Task { await model.monitor(store) }
    await wait(api, count: 1)
    await api.finish(0, value: data())
    for _ in 0..<20 { await Task.yield() }
    XCTAssertTrue(model.isCurrent(scope: store.scope, now: .now))
    XCTAssertFalse(model.isCurrent(scope: "another-account", now: .now))
    XCTAssertFalse(model.isCurrent(scope: store.scope, now: .now.addingTimeInterval(21)))
    let request = await api.requests[0]
    XCTAssertEqual(request.path, "/v1/position/margin")
    XCTAssertEqual(request.headers["X-Trading-Mode"], "ordinary")
    model.suspend()
    XCTAssertFalse(model.isCurrent(scope: store.scope, now: .now))
    monitor.cancel(); await monitor.value
  }
  func testFailedReadRetainsDetailsButDisablesRiskColor() async {
    let api = MarginFixtureAPI(), model = PositionMarginModel()
    let store = bound(api)
    let monitor = Task { await model.monitor(store) }
    await wait(api, count: 1); await api.finish(0, value: data())
    for _ in 0..<20 { await Task.yield() }
    let read = Task { await model.refresh(store) }
    await wait(api, count: 2); await api.fail(1); await read.value
    XCTAssertEqual(model.snapshot.value("margin_ratio_percent"), "35")
    XCTAssertFalse(model.error.isEmpty)
    XCTAssertFalse(model.isCurrent(scope: store.scope, now: .now))
    monitor.cancel(); await monitor.value
  }
  func testDelayedResponseCannotCrossAccountGeneration() async {
    let api = MarginFixtureAPI(), model = PositionMarginModel()
    let store = bound(api)
    let old = Task { await model.refresh(store) }
    await wait(api, count: 1)
    store.revision += 1
    let new = Task { await model.refresh(store) }
    await wait(api, count: 2)
    await api.finish(1, value: data("85")); await new.value
    await api.finish(0, value: data("5")); await old.value
    XCTAssertEqual(model.snapshot.value("margin_ratio_percent"), "85")
    XCTAssertEqual(model.scope, store.scope)
  }
  func testOverlappingReadsJoinWithoutDuplicateRequests() async {
    let api = MarginFixtureAPI(), model = PositionMarginModel()
    let store = bound(api)
    let first = Task { await model.refresh(store) }
    await wait(api, count: 1)
    await model.refresh(store)
    let count = await api.requests.count
    XCTAssertEqual(count, 1)
    await api.finish(0, value: data()); await first.value
  }
  func testLateCancelledMonitorCannotKeepBadgeActiveOrBlockForegroundRead() async {
    let api = MarginFixtureAPI(), model = PositionMarginModel()
    let store = bound(api)
    let first = Task { await model.monitor(store) }
    await wait(api, count: 1)
    model.suspend(); first.cancel()
    let second = Task { await model.monitor(store) }
    await wait(api, count: 2)
    await api.finish(1, value: data("90"))
    for _ in 0..<20 { await Task.yield() }
    await api.finish(0, value: data("1")); await first.value
    XCTAssertTrue(model.isCurrent(scope: store.scope, now: .now))
    XCTAssertEqual(model.snapshot.value("margin_ratio_percent"), "90")
    second.cancel(); await second.value
  }
  func testSeparatePageModelsRetainPaginationWithoutCrossingLateResponses() async {
    let api = MarginFixtureAPI(), limits = USDTPageModel(), history = USDTPageModel()
    let store = bound(api)
    let first = Task { await limits.load(store, path: "/limits", query: page(1), reuseIfLoaded: true) }
    await wait(api, count: 1)
    let second = Task { await history.load(store, path: "/history", query: page(1), reuseIfLoaded: true) }
    await wait(api, count: 2)
    await api.finish(1, value: rows("history", next: false)); await second.value
    await api.finish(0, value: rows("limit1", next: true)); await first.value
    XCTAssertEqual(history.items.first?.value("id"), "history")
    let append = Task { await limits.load(store, path: "/limits", query: page(2), append: true) }
    await wait(api, count: 3)
    await api.finish(2, value: rows("limit2", next: false)); await append.value
    limits.page = 1
    await limits.load(store, path: "/limits", query: page(1), reuseIfLoaded: true)
    XCTAssertEqual(limits.page, 2)
    XCTAssertEqual(limits.items.map { $0.value("id") }, ["limit1", "limit2"])
    let reads = await api.requests.count
    XCTAssertEqual(reads, 3, "Switching back to a loaded page must not send a new read")
    XCTAssertEqual(history.items.first?.value("id"), "history")
  }
  private func rows(_ id: String, next: Bool) -> JSONValue {
    .object(["items": .array([.object(["id": .string(id)])]), "pagination": .object(["has_next": .bool(next)])])
  }
  private func page(_ number: Int) -> [URLQueryItem] { [.init(name: "page", value: String(number))] }
  private func bound(_ api: MarginFixtureAPI) -> USDTStore {
    let store = USDTStore(api: api); store.binding = .object(["id": .string("fixture")]); return store
  }
  private func wait(_ api: MarginFixtureAPI, count: Int) async {
    for _ in 0..<1000 {
      if await api.requests.count >= count { return }
      await Task.yield()
    }
    XCTFail("Expected \(count) in-memory reads")
  }
}

private actor MarginFixtureAPI: APIClient {
  var requests: [APIRequest<JSONValue>] = []
  var waiting: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
    let index = requests.count
    let value = APIRequest<JSONValue>(path: request.path, queryItems: request.queryItems, headers: request.headers)
    requests.append(value)
    return try await withCheckedThrowingContinuation { waiting[index] = $0 } as! Response
  }
  func finish(_ index: Int, value: JSONValue) { waiting.removeValue(forKey: index)?.resume(returning: value) }
  func fail(_ index: Int) { waiting.removeValue(forKey: index)?.resume(throwing: URLError(.timedOut)) }
}
