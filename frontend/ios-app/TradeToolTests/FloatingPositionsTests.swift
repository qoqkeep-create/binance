import XCTest
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
    let positions = [try XCTUnwrap(FloatingPosition(row())),
      try XCTUnwrap(FloatingPosition(row(symbol: "ETHUSDT", profit: "-3.50", side: 1)))]
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
    var snapshot = FloatingPiPSnapshot(positions: [try XCTUnwrap(FloatingPosition(row()))], updatedAt: now)
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
    let snapshot = FloatingPiPSnapshot(positions: [try XCTUnwrap(FloatingPosition(row()))], updatedAt: Date())
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
    let position = try XCTUnwrap(FloatingPosition(row(price: "0.000000001234", profit: "25.005")))
    XCTAssertEqual(position.priceText, "0.000000001234")
    XCTAssertEqual(position.profitText, "+25.005 U")
    XCTAssertFalse(position.isShort)
    let loss = try XCTUnwrap(FloatingPosition(row(price: "2600.5", profit: "-3.50", side: 1)))
    XCTAssertEqual(loss.priceText, "2600.50")
    XCTAssertEqual(loss.profitText, "-3.500 U")
    XCTAssertTrue(loss.isShort)
  }

  func testUnavailableValuesNeverBecomeZeroBalances() throws {
    let position = try XCTUnwrap(FloatingPosition(.object(["symbol": .string("BTCUSDT")])))
    XCTAssertEqual(position.priceText, "--")
    XCTAssertEqual(position.profitText, "--")
    XCTAssertNil(FloatingPosition(.object([:])))
    XCTAssertEqual(FloatingPosition(row(price: "0", profit: "-0.001"))?.priceText, "--")
    XCTAssertEqual(FloatingPosition(row(price: "1", profit: "-0.001"))?.profitText, "-0.001 U")
  }

  @MainActor
  func testSnapshotRefreshAndClosedPositionsClearPreviousRows() async {
    let api = FloatingFixtureAPI(responses: [.array([row()]), .array([])])
    let store = USDTStore(api: api)
    let model = FloatingPositionsModel()
    model.reset(scope: store.scope)
    await model.refresh(store)
    XCTAssertEqual(model.positions.first?.symbol, "BTCUSDT")
    XCTAssertEqual(model.positions.first?.profitText, "+25.000 U")
    XCTAssertNotNil(model.updatedAt)
    await model.refresh(store)
    XCTAssertTrue(model.positions.isEmpty)
    XCTAssertTrue(model.hasLoaded)
    XCTAssertFalse(model.failed)
  }

  @MainActor
  func testFailedRefreshClearsOldPrice() async {
    let api = FloatingFixtureAPI(responses: [.array([row()])])
    let store = USDTStore(api: api)
    let model = FloatingPositionsModel()
    model.reset(scope: store.scope)
    await model.refresh(store)
    await model.refresh(store)
    XCTAssertTrue(model.positions.isEmpty)
    XCTAssertTrue(model.failed)
    XCTAssertNil(model.updatedAt)
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
    XCTAssertEqual(model.positions.map(\.symbol), ["ETHUSDT"])
    XCTAssertFalse(model.failed)
  }

  @MainActor
  func testClosingPanelRejectsInflightSnapshot() async {
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
    XCTAssertTrue(model.positions.isEmpty)
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
    await model.refresh(store)
    let paths = await api.paths
    XCTAssertEqual(paths, ["/v1/position/list"])
    await api.release(.array([]))
    await first.value
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

  private func row(symbol: String = "BTCUSDT", price: String = "68000.00", profit: String = "25.00", side: Int = 0) -> JSONValue {
    .object(["id": .string(symbol + String(side)), "symbol": .string(symbol), "side": .number(Double(side)),
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
