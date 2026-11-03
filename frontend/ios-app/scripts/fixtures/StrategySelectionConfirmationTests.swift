import Foundation
import XCTest
@testable import TradeTool

@MainActor
final class StrategySelectionConfirmationTests: XCTestCase {
  private let automatic = JSONValue.object([
    "id": .string("2"), "name": .string("趋势止盈"), "is_active": .bool(true)
  ])

  func testManualAndAutomaticRequireConfirmationAndCancellationDoesNotSaveOrReturn() async {
    for choice in [JSONValue.null, automatic] {
      let (flow, api, navigation) = fixture(returnAfterSelection: true)
      flow.chooseStrategy(choice)
      XCTAssertTrue(flow.confirmingSelection)
      XCTAssertEqual(flow.pendingSelection, choice)
      XCTAssertTrue(api.saves.isEmpty)
      XCTAssertEqual(navigation.returns, 0)
      flow.cancelSelection()
      flow.confirmSelection()
      await settle(flow)
      XCTAssertFalse(flow.confirmingSelection)
      XCTAssertTrue(api.saves.isEmpty)
      XCTAssertEqual(api.reads, 0)
      XCTAssertTrue(navigation.selections.isEmpty)
      XCTAssertEqual(navigation.returns, 0)
    }
  }

  func testConfirmedManualAndAutomaticSaveThenCallbackAndReturnToChart() async {
    for choice in [JSONValue.null, automatic] {
      let (flow, api, navigation) = fixture(returnAfterSelection: true)
      flow.chooseStrategy(choice)
      flow.confirmSelection()
      await settle(flow)
      XCTAssertEqual(api.saves.count, 1)
      XCTAssertEqual(api.reads, 1)
      XCTAssertEqual(navigation.selections.count, 1)
      XCTAssertEqual(navigation.selections.first!, choice == .null ? nil : choice)
      XCTAssertEqual(navigation.returns, 1)
      XCTAssertTrue(flow.notice.isEmpty)
      if choice == .null {
        XCTAssertEqual(api.saves[0]["manual"], .bool(true))
        XCTAssertNil(flow.store.activeStrategy)
      } else {
        XCTAssertEqual(api.saves[0]["strategy_id"], .string("2"))
        XCTAssertEqual(flow.store.activeStrategy?.value("id"), "2")
      }
    }
  }

  func testSettingsEntrySavesBothChoicesAndStaysOnList() async {
    for choice in [JSONValue.null, automatic] {
      let (flow, api, navigation) = fixture(returnAfterSelection: false)
      flow.chooseStrategy(choice)
      flow.confirmSelection()
      await settle(flow)
      XCTAssertEqual(api.saves.count, 1)
      XCTAssertEqual(api.reads, 1)
      XCTAssertEqual(navigation.returns, 0)
      XCTAssertTrue(navigation.selections.isEmpty)
    }
  }

  func testSaveOrReloadFailureStaysOnListAndShowsErrorForBothChoices() async {
    for choice in [JSONValue.null, automatic] {
      for failure in ["save", "reload"] {
        let (flow, api, navigation) = fixture(returnAfterSelection: true)
        api.failure = failure
        flow.chooseStrategy(choice)
        flow.confirmSelection()
        await settle(flow)
        XCTAssertFalse(flow.mutating)
        XCTAssertEqual(flow.notice, "测试保存失败")
        XCTAssertEqual(navigation.returns, 0)
        XCTAssertTrue(navigation.selections.isEmpty)
      }
    }
  }

  func testAccountChangeBeforeConfirmationDoesNotSaveSelectionInNewAccount() async {
    let (flow, api, navigation) = fixture(returnAfterSelection: true)
    flow.chooseStrategy(automatic)
    flow.store.prepareSession(userID: UUID().uuidString)
    flow.confirmSelection()
    await settle(flow)
    XCTAssertTrue(api.saves.isEmpty)
    XCTAssertEqual(navigation.returns, 0)
    XCTAssertTrue(navigation.selections.isEmpty)
  }

  func testAccountChangeDuringSaveCannotCallbackOrReturnWithOldSelection() async {
    let (flow, api, navigation) = fixture(returnAfterSelection: true)
    api.pausesSave = true
    flow.chooseStrategy(automatic)
    flow.confirmSelection()
    await api.waitForSave()
    flow.store.prepareSession(userID: UUID().uuidString)
    api.completeSave()
    await settle(flow)
    XCTAssertEqual(api.reads, 0)
    XCTAssertTrue(flow.store.strategies.isEmpty)
    XCTAssertTrue(flow.notice.isEmpty)
    XCTAssertEqual(navigation.returns, 0)
    XCTAssertTrue(navigation.selections.isEmpty)
  }

  func testRepeatedConfirmationOnlySavesOnceAndExplicitCloseReturnsOnce() async {
    let (flow, api, navigation) = fixture(returnAfterSelection: true)
    var closes = 0
    flow.onClose = { closes += 1 }
    flow.chooseStrategy(automatic)
    flow.confirmSelection()
    flow.confirmSelection()
    await settle(flow)
    XCTAssertEqual(api.saves.count, 1)
    XCTAssertEqual(navigation.selections.count, 1)
    XCTAssertEqual(closes, 1)
    XCTAssertEqual(navigation.returns, 0)
  }

  private func fixture(returnAfterSelection: Bool) -> (StrategySelectionHarness, SelectionAPI, Navigation) {
    let api = SelectionAPI()
    let store = USDTStore(api: api)
    store.prepareSession(userID: UUID().uuidString)
    store.strategies = [automatic]
    let flow = StrategySelectionHarness(store: store)
    let navigation = Navigation()
    flow.returnAfterSelection = returnAfterSelection
    flow.onSelection = { navigation.selections.append($0) }
    flow.dismiss = { navigation.returns += 1 }
    return (flow, api, navigation)
  }

  private func settle(_ flow: StrategySelectionHarness) async {
    for _ in 0..<200 {
      if !flow.mutating { return }
      try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Selection did not finish")
  }
}

@MainActor
private final class Navigation {
  var selections: [JSONValue?] = []
  var returns = 0
}

@MainActor
private final class SelectionAPI: APIClient {
  var saves: [JSONValue] = []
  var reads = 0
  var failure = ""
  var pausesSave = false
  private var saveGate: CheckedContinuation<Void, Never>?
  private var saveStarted: CheckedContinuation<Void, Never>?

  func waitForSave() async {
    if saveGate != nil { return }
    await withCheckedContinuation { saveStarted = $0 }
  }

  func completeSave() { saveGate?.resume(); saveGate = nil }

  func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
    let result: JSONValue
    switch request.path {
    case "/v1/strategy/set-active":
      let body = try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data())
      saves.append(body)
      if pausesSave {
        await withCheckedContinuation {
          saveGate = $0
          saveStarted?.resume(); saveStarted = nil
        }
      }
      if failure == "save" { throw APIError.business(code: "fixture", message: "测试保存失败") }
      result = .object([:])
    case "/v1/strategy/list":
      reads += 1
      if failure == "reload" { throw APIError.business(code: "fixture", message: "测试保存失败") }
      result = .array([.object(["id": .string("2"), "name": .string("趋势止盈"),
        "is_active": .bool(saves.last?["manual"] != .bool(true))])])
    default:
      throw APIError.invalidResponse
    }
    return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(result))
  }
}
