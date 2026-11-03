import XCTest
import Combine
import CoreFoundation
import AVFoundation
import CoreImage
import UIKit
@testable import TradeTool

final class FloatingPositionsTests: XCTestCase {
  func testEnablingInlineFloatingArmsPiPWithoutOpeningAnExternalWindow() {
    XCTAssertEqual(FloatingPiPActivation.requested(enabled: true, bound: true, inBackground: false), .inline)
    // Inactive scenes (Control Center and permission dialogs) are not background transitions.
    XCTAssertNotEqual(FloatingPiPActivation.requested(enabled: true, bound: true, inBackground: false), .external)
  }

  func testHomeRequestsExternalPiPAndReturningRestoresInlineIntent() {
    let transitions = [false, true, false, true].map {
      FloatingPiPActivation.requested(enabled: true, bound: true, inBackground: $0)
    }
    XCTAssertEqual(transitions, [.inline, .external, .inline, .external])
  }

  func testDisabledOrUnboundFloatingNeverRequestsAutomaticPiP() {
    for inBackground in [false, true] {
      XCTAssertEqual(FloatingPiPActivation.requested(enabled: false, bound: true, inBackground: inBackground), .disabled)
      XCTAssertEqual(FloatingPiPActivation.requested(enabled: true, bound: false, inBackground: inBackground), .disabled)
    }
  }

  func testPictureInPictureRotatesAcrossPositionsWithoutLosingSnapshotTime() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let positions = [try XCTUnwrap(floating(row())),
      try XCTUnwrap(floating(row(symbol: "ETHUSDT", profit: "-3.50", side: 1)))]
    let snapshot = FloatingPiPSnapshot(positions: positions, updatedAt: now)
    XCTAssertEqual(snapshot.presentation(at: now, cyclingSince: now, paused: false).title, "BTCUSDT")
    let second = snapshot.presentation(at: now.addingTimeInterval(5), cyclingSince: now, paused: false)
    XCTAssertEqual(second.title, "ETHUSDT")
    XCTAssertEqual(second.page, "2/2")
    XCTAssertEqual(second.profit, "-3.500 U")
    XCTAssertTrue(second.loss)
    XCTAssertEqual(snapshot.presentation(at: now.addingTimeInterval(10), cyclingSince: now, paused: false).title, "BTCUSDT")
  }

  func testPictureInPictureNeverPresentsPausedOrExpiredPriceAsCurrent() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    var snapshot = FloatingPiPSnapshot(positions: [try XCTUnwrap(floating(row()))], updatedAt: now)
    let stale = snapshot.presentation(at: now.addingTimeInterval(13), cyclingSince: nil, paused: false)
    XCTAssertEqual(stale.price, "--")
    XCTAssertEqual(stale.profit, "--")
    XCTAssertTrue(stale.footer.hasPrefix("更新延迟"))
    let paused = snapshot.presentation(at: now, cyclingSince: nil, paused: true)
    XCTAssertEqual(paused.price, "--")
    XCTAssertTrue(paused.footer.hasPrefix("已暂停"))
    snapshot.updatedAt = nil
    XCTAssertEqual(snapshot.presentation(at: now, cyclingSince: nil, paused: false).profit, "--")
  }

  @MainActor
  func testPictureInPictureProducesReadyVideoFrameFromSnapshot() throws {
    let snapshot = FloatingPiPSnapshot(positions: [try XCTUnwrap(floating(row()))], updatedAt: Date())
    let sample = try XCTUnwrap(FloatingPiPFrameRenderer.sample(snapshot.presentation(at: Date(), cyclingSince: nil, paused: false)))
    XCTAssertTrue(CMSampleBufferDataIsReady(sample))
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
    XCTAssertEqual(CVPixelBufferGetWidth(image), 640)
    XCTAssertEqual(CVPixelBufferGetHeight(image), 320)
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
    XCTAssertEqual(position.profitText, "+25.005 U")
    XCTAssertFalse(position.isShort)
    let loss = try XCTUnwrap(floating(row(price: "2600.5", profit: "-3.50", side: 1)))
    XCTAssertEqual(loss.priceText, "2600.50")
    XCTAssertEqual(loss.profitText, "-3.500 U")
    XCTAssertTrue(loss.isShort)
  }

  func testUnavailableValuesNeverBecomeZeroBalances() throws {
    let position = try XCTUnwrap(FloatingPosition(.object(["symbol": .string("BTCUSDT")])))
    XCTAssertEqual(position.priceText, "--")
    XCTAssertEqual(position.profitText, "--")
    XCTAssertNil(FloatingPosition(.object([:])))
    XCTAssertEqual(floating(row(price: "0", profit: "-0.001"))?.priceText, "--")
    XCTAssertEqual(floating(row(price: "1", profit: "-0.001"))?.profitText, "-0.001 U")
  }

  @MainActor
  func testSnapshotRefreshAndClosedPositionsClearPreviousRows() async {
    let api = FloatingFixtureAPI(responses: [.array([row()]), .array([])])
    let store = USDTStore(api: api)
    let model = FloatingPositionsModel()
    model.reset(scope: store.scope)
    await model.refresh(store)
    XCTAssertEqual(model.rows.first?.value("symbol"), "BTCUSDT")
    XCTAssertEqual(model.rows.first.flatMap { floating($0) }?.profitText, "+25.000 U")
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

  func testDraggingClampsPanelInsideScreenAndAboveNavigation() {
    let screen = CGSize(width: 402, height: 780)
    let bottom = FloatingPanelPlacement.center(in: screen, fraction: .zero, translation: CGSize(width: 5000, height: 5000))
    XCTAssertLessThanOrEqual(bottom.x + FloatingPanelPlacement.size.width / 2, screen.width - 12)
    XCTAssertLessThanOrEqual(bottom.y + FloatingPanelPlacement.size.height / 2, screen.height - 76)
    let top = FloatingPanelPlacement.center(in: screen, fraction: .zero, translation: CGSize(width: -5000, height: -5000))
    XCTAssertGreaterThanOrEqual(top.x - FloatingPanelPlacement.size.width / 2, 12)
    XCTAssertGreaterThanOrEqual(top.y - FloatingPanelPlacement.size.height / 2, 12)
    let fraction = FloatingPanelPlacement.fraction(for: bottom, in: screen)
    XCTAssertEqual(fraction.x, 1)
    XCTAssertEqual(fraction.y, 1)
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
    XCTAssertEqual(presentation.price, "--")
    XCTAssertEqual(presentation.profit, "--")
    XCTAssertTrue(presentation.footer.hasPrefix("更新延迟"))
  }

  func testAnotherSymbolsNewQuoteCannotRenewTheDisplayedExpiredPosition() throws {
    let old = Date(timeIntervalSince1970: 1_000)
    let now = old.addingTimeInterval(20)
    let snapshot = FloatingPiPSnapshot(positions: [
      try XCTUnwrap(floating(row(symbol: "BTCUSDT"), at: old)),
      try XCTUnwrap(floating(row(symbol: "ETHUSDT"), at: now)),
    ], updatedAt: now)
    let bitcoin = snapshot.presentation(at: now, cyclingSince: nil, paused: false)
    XCTAssertEqual(bitcoin.title, "BTCUSDT")
    XCTAssertEqual(bitcoin.profit, "--")
    let ether = snapshot.presentation(at: now, cyclingSince: now.addingTimeInterval(-5), paused: false)
    XCTAssertEqual(ether.title, "ETHUSDT")
    XCTAssertEqual(ether.profit, "+25.000 U")
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
