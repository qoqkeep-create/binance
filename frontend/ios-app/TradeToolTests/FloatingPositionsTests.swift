import XCTest
import Combine
import CoreFoundation
import AVFoundation
import CoreImage
import UIKit
@testable import TradeTool

final class FloatingPositionsTests: XCTestCase {
  func testForegroundToggleRequestsExternalPiPImmediately() {
    XCTAssertEqual(FloatingPiPActivation.requested(enabled: true, bound: true), .external)
    XCTAssertEqual(FloatingPiPActivation.requested(enabled: false, bound: true), .disabled)
    XCTAssertEqual(FloatingPiPActivation.requested(enabled: true, bound: false), .disabled)
  }

  func testExternalStartWaitsForAttachedReadySourceAndIssuesOnlyOnce() {
    var lifecycle = FloatingPiPLifecycle()
    XCTAssertTrue(lifecycle.request())
    XCTAssertTrue(lifecycle.isStarting)
    XCTAssertFalse(lifecycle.isActive)
    XCTAssertFalse(lifecycle.issueStart(sourceReady: false))
    XCTAssertFalse(lifecycle.request())
    XCTAssertTrue(lifecycle.issueStart(sourceReady: true))
    XCTAssertFalse(lifecycle.issueStart(sourceReady: true))
    XCTAssertTrue(lifecycle.didStart())
    XCTAssertTrue(lifecycle.isActive)
    XCTAssertFalse(lifecycle.isStarting)
  }

  func testFailedOrCancelledExternalStartReturnsToClosedAndCanRetry() {
    var lifecycle = FloatingPiPLifecycle()
    XCTAssertTrue(lifecycle.request())
    lifecycle.stop()
    XCTAssertFalse(lifecycle.isStarting)
    XCTAssertFalse(lifecycle.issueStart(sourceReady: true))
    XCTAssertFalse(lifecycle.didStart(), "A late system callback must not reopen a cancelled request")
    XCTAssertTrue(lifecycle.request())
    XCTAssertTrue(lifecycle.issueStart(sourceReady: true))
    XCTAssertTrue(lifecycle.didStart())
    lifecycle.stop()
    XCTAssertFalse(lifecycle.isActive)
    XCTAssertTrue(lifecycle.request(), "The entry must be usable again after a system close")
  }

  func testSystemStartFailureCanRetryWithoutWaitingForAnActiveWindowStopCallback() {
    var lifecycle = FloatingPiPLifecycle()
    XCTAssertTrue(lifecycle.request())
    XCTAssertTrue(lifecycle.issueStart(sourceReady: true))
    lifecycle.stop(awaitingSystemStop: false)
    XCTAssertTrue(lifecycle.request())
    XCTAssertTrue(lifecycle.issueStart(sourceReady: true))
    XCTAssertTrue(lifecycle.didStart())
  }

  func testRapidExternalRetryWaitsForPreviousSystemWindowToFinishClosing() {
    var lifecycle = FloatingPiPLifecycle()
    XCTAssertTrue(lifecycle.request())
    XCTAssertTrue(lifecycle.issueStart(sourceReady: true))
    XCTAssertTrue(lifecycle.didStart())
    lifecycle.stop(awaitingSystemStop: true)
    XCTAssertTrue(lifecycle.request())
    XCTAssertFalse(lifecycle.issueStart(sourceReady: true))
    XCTAssertFalse(lifecycle.didStart(), "The previous window's late callback cannot activate the retry")
    XCTAssertFalse(lifecycle.didStop(), "The old stop callback must preserve the newer request")
    XCTAssertTrue(lifecycle.isStarting)
    XCTAssertTrue(lifecycle.issueStart(sourceReady: true))
    XCTAssertTrue(lifecycle.didStart())
    XCTAssertTrue(lifecycle.didStop(), "System close of the new active window should disable its entry")
    XCTAssertFalse(lifecycle.isActive)
  }

  func testPiPShowsAllPositionsTogetherWhenThereAreAtMostThree() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let positions = [try XCTUnwrap(floating(row())),
      try XCTUnwrap(floating(row(symbol: "ETHUSDT", profit: "-3.50", side: 1)))]
    let snapshot = FloatingPiPSnapshot(positions: positions, updatedAt: now)
    let first = snapshot.presentation(at: now, cyclingSince: now, paused: false)
    XCTAssertEqual(first.title, "持仓")
    XCTAssertEqual(first.rows.map(\.symbol), ["BTCUSDT", "ETHUSDT"])
    XCTAssertEqual(first.totalCount, 2)
    XCTAssertEqual(first.page, "")
    XCTAssertEqual(first.rows[1].profit, "-3.5 U")
    XCTAssertTrue(first.rows[1].loss)
    let next = snapshot.presentation(at: now.addingTimeInterval(5), cyclingSince: now, paused: false)
    XCTAssertEqual(next.rows.map(\.id), first.rows.map(\.id), "A short list must never rotate one coin at a time")
  }

  func testPiPGroupsAllPositionsIntoPagesOfThreeAndWrapsWithoutOmittingRows() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let positions = try (0..<7).map { try XCTUnwrap(floating(row(symbol: "COIN\($0)USDT"))) }
    let snapshot = FloatingPiPSnapshot(positions: positions, updatedAt: now)
    let pages = (0..<3).map { snapshot.presentation(at: now.addingTimeInterval(Double($0 * 5)), cyclingSince: now, paused: false) }
    XCTAssertEqual(pages.map { $0.rows.count }, [3, 3, 1])
    XCTAssertEqual(pages.map(\.page), ["1/3", "2/3", "3/3"])
    XCTAssertTrue(pages.allSatisfy { $0.totalCount == 7 })
    XCTAssertEqual(pages.flatMap { $0.rows.map(\.id) }, positions.map(\.id))
    let wrapped = snapshot.presentation(at: now.addingTimeInterval(15), cyclingSince: now, paused: false)
    XCTAssertEqual(wrapped.rows.map(\.id), pages[0].rows.map(\.id))
    let reduced = FloatingPiPSnapshot(positions: Array(positions.prefix(1)), updatedAt: now)
      .presentation(at: now.addingTimeInterval(10), cyclingSince: now, paused: false)
    XCTAssertEqual(reduced.rows.map(\.id), [positions[0].id])
    XCTAssertEqual(reduced.page, "")
  }

  func testPictureInPictureNeverPresentsPausedOrExpiredPriceAsCurrent() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    var snapshot = FloatingPiPSnapshot(positions: [try XCTUnwrap(floating(row()))], updatedAt: now)
    let stale = snapshot.presentation(at: now.addingTimeInterval(13), cyclingSince: nil, paused: false)
    XCTAssertEqual(stale.rows.first?.price, "--")
    XCTAssertEqual(stale.rows.first?.profit, "--")
    XCTAssertTrue(stale.footer.hasPrefix("更新延迟"))
    let paused = snapshot.presentation(at: now, cyclingSince: nil, paused: true)
    XCTAssertEqual(paused.rows.first?.price, "--")
    XCTAssertTrue(paused.footer.hasPrefix("已暂停"))
    snapshot.updatedAt = nil
    XCTAssertEqual(snapshot.presentation(at: now, cyclingSince: nil, paused: false).rows.first?.profit, "--")
  }

  func testPiPEmptySnapshotKeepsLoadingOrEmptyStatusWithoutFakeRows() {
    let snapshot = FloatingPiPSnapshot(status: "正在同步…")
    let loading = snapshot.presentation(at: Date(), cyclingSince: nil, paused: false)
    XCTAssertTrue(loading.rows.isEmpty)
    XCTAssertEqual(loading.totalCount, 0)
    XCTAssertEqual(loading.page, "")
    XCTAssertEqual(loading.footer, "正在同步…")
  }

  @MainActor
  func testPiPVideoFrameHeightFollowsVisibleRowsIncludingShortLastPageAndClosingPositions() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let positions = try (0..<7).map { try XCTUnwrap(floating(row(symbol: "COIN\($0)USDT"))) }
    func height(_ content: FloatingPiPPresentation) throws -> Int {
      let sample = try XCTUnwrap(FloatingPiPFrameRenderer.sample(content))
      XCTAssertTrue(CMSampleBufferDataIsReady(sample))
      let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
      XCTAssertEqual(CVPixelBufferGetWidth(buffer), 640)
      XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer))
      let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
      let dimensions = CMVideoFormatDescriptionGetDimensions(description)
      XCTAssertEqual(Int(dimensions.width), CVPixelBufferGetWidth(buffer))
      XCTAssertEqual(Int(dimensions.height), CVPixelBufferGetHeight(buffer))
      return CVPixelBufferGetHeight(buffer)
    }
    for (count, expected) in [(0, 240), (1, 240), (2, 322), (3, 404)] {
      let content = FloatingPiPSnapshot(positions: Array(positions.prefix(count)), updatedAt: now)
        .presentation(at: now, cyclingSince: now, paused: false)
      XCTAssertEqual(try height(content), expected)
      let source = FloatingPanelPlacement.sourceSize(forRowCount: content.rows.count)
      XCTAssertEqual(source.width, 160)
      XCTAssertEqual(source.height, CGFloat(expected) / 4)
    }
    let snapshot = FloatingPiPSnapshot(positions: positions, updatedAt: now)
    let pages = (0..<3).map { snapshot.presentation(at: now.addingTimeInterval(Double($0 * 5)), cyclingSince: now, paused: false) }
    XCTAssertEqual(try pages.map(height), [404, 404, 240])
    let reduced = FloatingPiPSnapshot(positions: Array(positions.prefix(1)), updatedAt: now)
      .presentation(at: now.addingTimeInterval(10), cyclingSince: now, paused: false)
    XCTAssertEqual(try height(reduced), 240, "Closing positions must shrink the next video frame immediately")
  }

  @MainActor
  func testPictureInPictureProducesReadyVideoFrameFromSnapshot() throws {
    let snapshot = FloatingPiPSnapshot(positions: [try XCTUnwrap(floating(row()))], updatedAt: Date())
    let sample = try XCTUnwrap(FloatingPiPFrameRenderer.sample(snapshot.presentation(at: Date(), cyclingSince: nil, paused: false)))
    XCTAssertTrue(CMSampleBufferDataIsReady(sample))
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
    XCTAssertEqual(CVPixelBufferGetWidth(image), 640)
    XCTAssertEqual(CVPixelBufferGetHeight(image), 240)
    XCTAssertNotNil(CVPixelBufferGetIOSurface(image))
    let bitmap = CIImage(cvPixelBuffer: image)
    let context = CIContext(options: [.useSoftwareRenderer: true])
    let cgImage = try XCTUnwrap(context.createCGImage(bitmap, from: bitmap.extent))
    let attachment = XCTAttachment(image: UIImage(cgImage: cgImage))
    attachment.name = "floating-pip-rendered-card"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testDecimalSnapshotPreservesSmallPriceAndSignedProfit() throws {
    var fields = row(price: "0.000000001234", profit: "25.005").fields
    fields["open_price"] = .string("0.000000001233")
    fields["exchange_size"] = .string("25005000000000")
    let position = try XCTUnwrap(floating(.object(fields)))
    XCTAssertEqual(position.priceText, "0.000000001234")
    XCTAssertEqual(position.profitText, "+25.01 U")
    XCTAssertFalse(position.isShort)
    let loss = try XCTUnwrap(floating(row(price: "2600.5", profit: "-3.50", side: 1)))
    XCTAssertEqual(loss.priceText, "2600.50")
    XCTAssertEqual(loss.profitText, "-3.5 U")
    XCTAssertTrue(loss.isShort)
  }

  func testUnavailableValuesNeverBecomeZeroBalances() throws {
    let position = try XCTUnwrap(FloatingPosition(.object(["symbol": .string("BTCUSDT")])))
    XCTAssertEqual(position.priceText, "--")
    XCTAssertEqual(position.profitText, "--")
    XCTAssertNil(FloatingPosition(.object([:])))
    XCTAssertEqual(floating(row(price: "0", profit: "-0.001"))?.priceText, "--")
    let tinyLoss = floating(row(price: "1", profit: "-0.001"))
    XCTAssertEqual(tinyLoss?.profitText, "0 U")
    XCTAssertEqual(tinyLoss?.profit, Decimal(string: "-0.001"), "Rounding the label must not change the loss sign")
  }

  @MainActor
  func testSnapshotRefreshAndClosedPositionsClearPreviousRows() async {
    let api = FloatingFixtureAPI(responses: [.array([row()]), .array([])])
    let store = USDTStore(api: api)
    let model = FloatingPositionsModel()
    model.reset(scope: store.scope)
    await model.refresh(store)
    XCTAssertEqual(model.rows.first?.value("symbol"), "BTCUSDT")
    XCTAssertEqual(model.rows.first.flatMap { floating($0) }?.profitText, "+25 U")
    XCTAssertNotNil(model.updatedAt)
    await model.refresh(store)
    XCTAssertTrue(model.rows.isEmpty)
    XCTAssertTrue(model.hasLoaded)
    XCTAssertFalse(model.failed)
  }

  @MainActor
  func testFailedRefreshKeepsLastKnownSharedRowsWithoutRenewingTimestamp() async {
    let api = FloatingFixtureAPI(responses: [.array([row()])])
    let store = USDTStore(api: api)
    let model = FloatingPositionsModel()
    model.reset(scope: store.scope)
    await model.refresh(store)
    let lastUpdate = model.updatedAt
    await model.refresh(store)
    XCTAssertEqual(model.rows.count, 1)
    XCTAssertTrue(model.failed)
    XCTAssertEqual(model.updatedAt, lastUpdate)
  }

  @MainActor
  func testResponseFromPreviousIdentityCannotOverwriteNewAccount() async {
    let requested = expectation(description: "Old account snapshot requested")
    let api = FloatingFixtureAPI(responses: [.array([row(symbol: "ETHUSDT")])], gate: requested)
    let store = USDTStore(api: api)
    let model = FloatingPositionsModel()
    model.reset(scope: store.scope)
    let old = Task { await model.refresh(store) }
    await fulfillment(of: [requested], timeout: 2)
    store.invalidate()
    model.reset(scope: store.scope)
    await model.refresh(store)
    await api.release(.array([row(symbol: "BTCUSDT")]))
    await old.value
    XCTAssertEqual(model.rows.map { $0.value("symbol") }, ["ETHUSDT"])
    XCTAssertFalse(model.failed)
  }

  @MainActor
  func testResettingSharedSnapshotRejectsInflightResponse() async {
    let requested = expectation(description: "Snapshot requested")
    let api = FloatingFixtureAPI(responses: [], gate: requested)
    let store = USDTStore(api: api)
    let model = FloatingPositionsModel()
    model.reset(scope: store.scope)
    let pending = Task { await model.refresh(store) }
    await fulfillment(of: [requested], timeout: 2)
    model.reset(scope: "")
    await api.release(.array([row()]))
    await pending.value
    XCTAssertTrue(model.rows.isEmpty)
    XCTAssertFalse(model.hasLoaded)
    XCTAssertFalse(model.failed)
  }

  @MainActor
  func testAccountEventAndPollShareOneInflightRequest() async {
    let requested = expectation(description: "Snapshot requested")
    let api = FloatingFixtureAPI(responses: [], gate: requested)
    let store = USDTStore(api: api)
    let model = FloatingPositionsModel()
    model.reset(scope: store.scope)
    let first = Task { await model.refresh(store) }
    await fulfillment(of: [requested], timeout: 2)
    let joined = expectation(description: "Second reader joined")
    let second = Task { joined.fulfill(); await model.refresh(store) }
    await fulfillment(of: [joined], timeout: 2)
    await api.release(.array([]))
    await first.value
    await second.value
    let paths = await api.paths
    XCTAssertEqual(paths, ["/v1/position/list"])
  }

  func testSameQuoteAndRowProduceTheSameCardAndFloatingValuation() throws {
    var fields = row(price: "110", profit: "19.5").fields
    fields["open_price"] = .string("100")
    fields["exchange_size"] = .string("2")
    fields["size"] = .string("10")
    let position = JSONValue.object(fields)
    let quote = PositionMarketQuote(price: Decimal(110), eventTime: 1_000_000)
    let card = try XCTUnwrap(PositionLiveValuation(row: position, quote: quote))
    let floating = try XCTUnwrap(FloatingPosition(position, quote: quote))
    XCTAssertEqual(card.profit, Decimal(20))
    XCTAssertEqual(floating.price, card.price)
    XCTAssertEqual(floating.profit, card.profit)
    // REST upl/current_price must not become a competing financial source.
    XCTAssertNil(FloatingPosition(position)?.profit)
  }

  @MainActor
  func testSharedSnapshotAndTickerDriveBothSurfacesAcrossPartialPositionChanges() async throws {
    var first = row(price: "110", profit: "19.5").fields
    first["open_price"] = .string("100")
    first["exchange_size"] = .string("2")
    var reduced = first
    reduced["exchange_size"] = .string("0.5")
    let api = FloatingFixtureAPI(responses: [.array([.object(first)]), .array([.object(reduced)])])
    let store = USDTStore(api: api)
    store.binding = .object(["id": .string("fixture")])
    var publications = 0
    let observation = store.objectWillChange.sink { publications += 1 }
    defer { observation.cancel() }
    await store.refreshPositions()
    let beforeQuote = publications
    let page = store.positionQuotes.begin(scope: store.scope, symbols: ["BTCUSDT"], owner: "positions")
    let overlay = store.positionQuotes.begin(scope: store.scope, symbols: ["BTCUSDT"], owner: "floating")
    let now = Date(timeIntervalSince1970: 1_000)
    func assertProfit(_ expected: Decimal, file: StaticString = #filePath, line: UInt = #line) throws {
      let row = try XCTUnwrap(store.positionSnapshots.rows.first, file: file, line: line)
      let quote = store.positionQuotes.quotes["BTCUSDT"]
      XCTAssertEqual(PositionLiveValuation(row: row, quote: quote)?.profit, expected, file: file, line: line)
      XCTAssertEqual(FloatingPosition(row, quote: quote)?.profit, expected, file: file, line: line)
    }
    store.positionQuotes.receive(ticker("110", time: 1_000_000), session: page, now: now)
    XCTAssertGreaterThan(publications, beforeQuote, "Nested quote publications must invalidate the store's SwiftUI consumers")
    try assertProfit(20)
    XCTAssertTrue(store.positionQuotes.end(page))
    store.positionQuotes.receive(ticker("112", time: 1_000_001), session: overlay, now: now)
    try assertProfit(24)
    // An older HTTP price cannot overwrite the fresh ticker, but the remaining quantity must change.
    await store.refreshPositions()
    try assertProfit(6)
    store.positionQuotes.receive(ticker("1", time: 999_999), session: overlay, now: now)
    try assertProfit(6)
    store.invalidate()
    XCTAssertTrue(store.positionSnapshots.rows.isEmpty)
    XCTAssertTrue(store.positionQuotes.quotes.isEmpty)
    store.positionQuotes.receive(ticker("999", time: 1_000_002), session: overlay, now: now)
    XCTAssertTrue(store.positionQuotes.quotes.isEmpty)
  }

  @MainActor
  func testCardAndOverlayReadsShareOneInflightPositionRequest() async {
    let requested = expectation(description: "Shared snapshot requested")
    let api = FloatingFixtureAPI(responses: [], gate: requested)
    let store = USDTStore(api: api)
    store.binding = .object(["id": .string("fixture")])
    let card = Task { await store.refreshPositions() }
    await fulfillment(of: [requested], timeout: 2)
    let joined = expectation(description: "Overlay joined the positions read")
    let overlay = Task { joined.fulfill(); await store.refreshPositions() }
    await fulfillment(of: [joined], timeout: 2)
    await api.release(.array([row()]))
    await card.value
    await overlay.value
    let paths = await api.paths
    XCTAssertEqual(paths, ["/v1/position/list"])
    XCTAssertEqual(store.positionSnapshots.rows.count, 1)
  }

  @MainActor
  func testClosingOverlayCannotCancelAReadNeededByThePositionsPage() async {
    let requested = expectation(description: "Overlay read requested")
    let pageJoined = expectation(description: "Positions page joined shared read")
    let api = FloatingFixtureAPI(responses: [], gate: requested)
    let store = USDTStore(api: api)
    store.binding = .object(["id": .string("fixture")])
    let overlay = Task { await store.refreshPositions() }
    await fulfillment(of: [requested], timeout: 2)
    let page = Task { pageJoined.fulfill(); await store.refreshPositions() }
    await fulfillment(of: [pageJoined], timeout: 2)
    overlay.cancel()
    await api.release(.array([row()]))
    await overlay.value
    await page.value
    XCTAssertEqual(store.positionSnapshots.rows.count, 1)
    XCTAssertTrue(store.positionSnapshots.hasLoaded)
    let paths = await api.paths
    XCTAssertEqual(paths, ["/v1/position/list"])
  }

  func testFreshHttpSnapshotCannotRenewAnExpiredTickerPrice() throws {
    let old = Date(timeIntervalSince1970: 1_000)
    let now = old.addingTimeInterval(20)
    let snapshot = FloatingPiPSnapshot(positions: [try XCTUnwrap(floating(row(), at: old))], updatedAt: now)
    let presentation = snapshot.presentation(at: now, cyclingSince: nil, paused: false)
    XCTAssertEqual(presentation.rows.first?.price, "--")
    XCTAssertEqual(presentation.rows.first?.profit, "--")
    XCTAssertTrue(presentation.footer.hasPrefix("更新延迟"))
  }

  func testAnotherSymbolsNewQuoteCannotRenewTheDisplayedExpiredPosition() throws {
    let old = Date(timeIntervalSince1970: 1_000)
    let now = old.addingTimeInterval(20)
    let snapshot = FloatingPiPSnapshot(positions: [
      try XCTUnwrap(floating(row(symbol: "BTCUSDT"), at: old)),
      try XCTUnwrap(floating(row(symbol: "ETHUSDT"), at: now)),
    ], updatedAt: now)
    let presentation = snapshot.presentation(at: now, cyclingSince: nil, paused: false)
    XCTAssertEqual(presentation.rows.map(\.symbol), ["BTCUSDT", "ETHUSDT"])
    XCTAssertEqual(presentation.rows[0].profit, "--")
    XCTAssertTrue(presentation.rows[0].stale)
    XCTAssertEqual(presentation.rows[1].profit, "+25 U")
    XCTAssertFalse(presentation.rows[1].stale)
    XCTAssertTrue(presentation.footer.hasPrefix("部分行情延迟"))
  }

  @MainActor
  func testBackpressuredPiPDeliversTheLatestFrameWithoutWaitingForAnotherTick() {
    var ready = false
    var callback: (@MainActor () -> Void)?
    var delivered: [Int] = []
    var requests = 0
    var stops = 0
    let delivery = FloatingPiPFrameDelivery<Int>(isReady: { ready }, request: {
      requests += 1; callback = $0
    }, stop: { stops += 1 }, enqueue: { delivered.append($0) })
    delivery.submit(1)
    delivery.submit(2)
    delivery.submit(3)
    XCTAssertTrue(delivered.isEmpty)
    XCTAssertEqual(requests, 1)
    ready = true
    callback?()
    XCTAssertEqual(delivered, [3])
    XCTAssertEqual(stops, 1)
    callback?()
    XCTAssertEqual(delivered, [3])
    ready = false
    delivery.submit(4)
    delivery.cancel()
    ready = true
    callback?()
    XCTAssertEqual(delivered, [3], "Cancelled frames must not resurface")
  }

  @MainActor
  func testPiPTimerContinuesDuringACommonTrackingRunLoopMode() {
    let mode = RunLoop.Mode("FloatingPiPTrackingTests")
    CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(mode.rawValue as CFString))
    var ticks = 0
    let timer = FloatingPiPRenderSchedule.timer(interval: 0.005) { ticks += 1 }
    defer { timer.invalidate() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
    let beforeTracking = ticks
    let limit = Date().addingTimeInterval(0.04)
    while ticks == beforeTracking && Date() < limit { _ = RunLoop.main.run(mode: mode, before: limit) }
    XCTAssertGreaterThan(ticks, beforeTracking)
  }

  private func floating(_ row: JSONValue, at time: Date = Date(timeIntervalSince1970: 1_000)) -> FloatingPosition? {
    let quote = row["current_price"]?.decimal.map {
      PositionMarketQuote(price: $0, eventTime: Int64(time.timeIntervalSince1970 * 1_000))
    }
    return FloatingPosition(row, quote: quote)
  }

  private func ticker(_ price: String, time: Int64) -> RealtimeServerMessage {
    RealtimeServerMessage(version: 1, type: "event", requestId: nil, channel: "market.ticker",
      event: "update", key: "BTCUSDT", sequence: nil, timestamp: time,
      data: .object(["symbol": .string("BTCUSDT"), "lastPrice": .string(price), "eventTime": .number(Double(time))]), error: nil)
  }

  private func row(symbol: String = "BTCUSDT", price: String = "68000.00", profit: String = "25.00", side: Int = 0) -> JSONValue {
    let current = Decimal(string: price) ?? 0
    let pnl = Decimal(string: profit) ?? 0
    let entry = side == 0 ? current - pnl : current + pnl
    return .object(["id": .string(symbol + String(side)), "symbol": .string(symbol), "side": .number(Double(side)),
      "open_price": .string(NSDecimalNumber(decimal: entry).stringValue), "exchange_size": .string("1"),
      "current_price": .string(price), "pnl": .string(profit)])
  }
}

private actor FloatingFixtureAPI: APIClient {
  var responses: [JSONValue]
  var gate: XCTestExpectation?
  var continuation: CheckedContinuation<JSONValue, Never>?
  private(set) var paths: [String] = []
  init(responses: [JSONValue], gate: XCTestExpectation? = nil) {
    self.responses = responses
    self.gate = gate
  }
  func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
    paths.append(request.path)
    let value: JSONValue
    if let gate {
      self.gate = nil
      value = await withCheckedContinuation { continuation in
        self.continuation = continuation
        gate.fulfill()
      }
    } else {
      guard !responses.isEmpty else { throw APIError.invalidResponse }
      value = responses.removeFirst()
    }
    return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(value))
  }
  func release(_ value: JSONValue) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}
