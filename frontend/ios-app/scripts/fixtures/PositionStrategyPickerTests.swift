import Foundation
import XCTest
@testable import TradeTool

@MainActor
final class PositionStrategyPickerTests: XCTestCase {
  private let first = JSONValue.object(["id": .string("2"), "name": .string("趋势止盈")])
  private let second = JSONValue.object(["id": .string("3"), "name": .string("分层止盈"), "is_active": .bool(true)])

  func testPickerFiltersManualAndMissingIdentifiersAndCannotConfirmThem() {
    let (picker, api, events) = fixture()
    picker.store.strategies += [.null, .object(["name": .string("手动止盈")]), .object(["id": .string("")])]
    XCTAssertEqual(picker.automaticStrategies.map { $0.value("id") }, ["2", "3"])
    picker.chooseStrategy(.null)
    picker.confirmSelection()
    XCTAssertFalse(picker.confirmingSelection)
    XCTAssertTrue(picker.selection.isEmpty)
    XCTAssertTrue(api.commands.isEmpty)
    XCTAssertEqual(events.closes, 0)
  }

  func testTapOnlyStagesAndCancelNeverChangesSelectionOrSendsCommand() {
    let (picker, api, events) = fixture()
    picker.selection = "3"
    picker.chooseStrategy(first)
    XCTAssertTrue(picker.confirmingSelection)
    XCTAssertEqual(picker.pendingName, "趋势止盈")
    XCTAssertEqual(picker.selection, "3")
    XCTAssertTrue(api.commands.isEmpty)
    picker.cancelSelection()
    picker.confirmSelection()
    XCTAssertEqual(picker.selection, "3")
    XCTAssertTrue(api.commands.isEmpty)
    XCTAssertEqual(events.closes, 0)
  }

  func testConfirmedChoiceBindsOnlyExplicitPositionAndSuccessClosesOnce() async {
    let (picker, api, events) = fixture()
    picker.chooseStrategy(first)
    picker.confirmSelection()
    picker.confirmSelection()
    await settle(picker)
    XCTAssertEqual(api.commands.count, 1)
    XCTAssertEqual(api.commands[0].body["action"], .string("strategy-rebind"))
    XCTAssertEqual(api.commands[0].body["payload"]?["strategy_id"], .string("2"))
    XCTAssertEqual(api.commands[0].body["payload"]?["position_id"], .string("position-11"))
    XCTAssertEqual(picker.selection, "2")
    XCTAssertEqual(picker.store.activeStrategy?.value("id"), "3", "Binding must not change future entry defaults")
    XCTAssertEqual(events.closes, 1)
    XCTAssertEqual(events.completions, ["操作成功"])
    XCTAssertFalse(api.paths.contains("/v1/strategy/set-active"))
  }

  func testExplicitFailureStaysOpenAndAllowsAnotherConfirmedChoiceWithNewKey() async {
    let (picker, api, events) = fixture()
    api.states = ["FAILED", "SUCCEEDED"]
    picker.chooseStrategy(first)
    picker.confirmSelection()
    await settle(picker)
    XCTAssertEqual(picker.notice, "绑定失败")
    XCTAssertFalse(picker.pending)
    XCTAssertEqual(events.closes, 0)
    picker.chooseStrategy(second)
    picker.confirmSelection()
    await settle(picker)
    XCTAssertEqual(api.commands.count, 2)
    XCTAssertNotEqual(api.commands[0].key, api.commands[1].key)
    XCTAssertEqual(api.commands[1].body["payload"]?["strategy_id"], .string("3"))
    XCTAssertEqual(events.closes, 1)
  }

  func testUnknownOrTransportFailureStaysOpenAndRetriesFrozenPayloadWithSameKey() async {
    for failure in ["UNKNOWN", "timeout"] {
      let (picker, api, events) = fixture()
      if failure == "timeout" { api.failNextCommand = true } else { api.states = ["UNKNOWN", "SUCCEEDED"] }
      picker.chooseStrategy(first)
      picker.confirmSelection()
      await settle(picker)
      XCTAssertTrue(picker.pending)
      XCTAssertEqual(events.closes, 0)
      picker.chooseStrategy(second)
      XCTAssertFalse(picker.confirmingSelection)
      XCTAssertEqual(picker.selection, "2")
      // A late UI binding write cannot replace the persisted command intent.
      picker.selection = "3"
      picker.queryPendingSelection()
      await settle(picker)
      XCTAssertEqual(api.commands.count, 2)
      XCTAssertEqual(api.commands[0].body, api.commands[1].body)
      XCTAssertEqual(api.commands[0].key, api.commands[1].key)
      XCTAssertEqual(events.closes, 1)
    }
  }

  func testAccountChangeBeforeConfirmationCannotBindOldPositionInNewAccount() {
    let (picker, api, events) = fixture()
    picker.chooseStrategy(first)
    picker.store.prepareSession(userID: UUID().uuidString)
    picker.store.strategies = [first]
    picker.confirmSelection()
    XCTAssertTrue(api.commands.isEmpty)
    // Even a new selection in the stale controls cannot cross its opening scope.
    picker.chooseStrategy(first)
    picker.confirmSelection()
    XCTAssertTrue(api.commands.isEmpty)
    XCTAssertEqual(events.closes, 0)
  }

  func testAccountChangeDuringCommandDoesNotPublishCompletionOrDismissNewScope() async {
    let (picker, api, events) = fixture()
    api.pausesCommand = true
    picker.chooseStrategy(first)
    picker.confirmSelection()
    await api.waitForCommand()
    picker.store.prepareSession(userID: UUID().uuidString)
    api.completeCommand()
    await settle(picker)
    XCTAssertEqual(api.commands.count, 1)
    XCTAssertTrue(picker.notice.isEmpty)
    XCTAssertTrue(events.completions.isEmpty)
    XCTAssertEqual(events.closes, 0)
  }

  func testAccountChangeBeforeScheduledSendPreventsOldPositionCommand() async {
    let (picker, api, events) = fixture()
    picker.chooseStrategy(first)
    picker.confirmSelection()
    // No suspension before switching: execute's Task has not started yet.
    picker.store.prepareSession(userID: UUID().uuidString)
    await settle(picker)
    XCTAssertTrue(api.commands.isEmpty)
    XCTAssertFalse(picker.pending)
    XCTAssertTrue(events.completions.isEmpty)
    XCTAssertEqual(events.closes, 0)
  }

  func testRemovedChoiceOrBusyCommandCannotBeConfirmedAgain() async {
    let (picker, api, events) = fixture()
    picker.chooseStrategy(first)
    picker.store.strategies = [second]
    picker.confirmSelection()
    XCTAssertTrue(api.commands.isEmpty)
    picker.chooseStrategy(second)
    api.pausesCommand = true
    picker.confirmSelection()
    await api.waitForCommand()
    picker.chooseStrategy(first)
    picker.confirmSelection()
    picker.queryPendingSelection()
    XCTAssertEqual(api.commands.count, 1)
    api.completeCommand()
    await settle(picker)
    XCTAssertEqual(events.closes, 1)
  }

  func testReloadIsReadOnlyAndCancellationDoesNotDisplayAnError() async {
    let (picker, api, events) = fixture()
    api.list = [first]
    await picker.reload()
    XCTAssertEqual(picker.automaticStrategies, [first])
    XCTAssertTrue(api.commands.isEmpty)
    XCTAssertEqual(events.closes, 0)
    api.listError = APIError.cancelled
    await picker.reload()
    XCTAssertTrue(picker.loadNotice.isEmpty)
    XCTAssertFalse(picker.loading)
    api.listError = APIError.business(code: "fixture", message: "策略读取失败")
    await picker.reload()
    XCTAssertEqual(picker.loadNotice, "策略读取失败")
    XCTAssertTrue(api.commands.isEmpty)
    XCTAssertEqual(events.closes, 0)
  }

  private func fixture() -> (PositionStrategyPickerHarness, PositionPickerAPI, PositionPickerEvents) {
    let api = PositionPickerAPI()
    let store = USDTStore(api: api)
    store.prepareSession(userID: UUID().uuidString)
    store.strategies = [first, second]
    let events = PositionPickerEvents()
    let controls = PositionStrategyControlsHarness(store: store) {
      events.completions.append($0)
      events.presentation.completePositionOperation($0)
    }
    controls.dismiss = { XCTFail("Terminal completion must close the outer presentation, independently of busy dismissal blocking") }
    return (PositionStrategyPickerHarness(controls: controls), api, events)
  }

  private func settle(_ picker: PositionStrategyPickerHarness) async {
    for _ in 0..<200 {
      if !picker.busy { return }
      try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Position strategy command did not settle")
  }
}

@MainActor
private final class PositionPickerEvents {
  var completions: [String] = []
  let presentation = PositionOperationPresentationHarness()
  var closes: Int { presentation.operation == nil ? 1 : 0 }
}

@MainActor
private final class PositionPickerAPI: APIClient {
  struct Command { let body: JSONValue; let key: String }
  var commands: [Command] = []
  var paths: [String] = []
  var list: [JSONValue] = []
  var listError: Error?
  var states: [String] = []
  var failNextCommand = false
  var pausesCommand = false
  private var commandGate: CheckedContinuation<Void, Never>?
  private var commandStarted: CheckedContinuation<Void, Never>?

  func waitForCommand() async {
    if commandGate != nil { return }
    await withCheckedContinuation { commandStarted = $0 }
  }
  func completeCommand() { commandGate?.resume(); commandGate = nil }

  func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
    paths.append(request.path)
    let result: JSONValue
    switch request.path {
    case "/v1/strategy/list":
      if let listError { throw listError }
      result = .array(list)
    case "/api/commands":
      XCTAssertEqual(request.method, .post)
      let body = try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data())
      commands.append(Command(body: body, key: request.headers["Idempotency-Key"] ?? ""))
      if pausesCommand {
        await withCheckedContinuation {
          commandGate = $0
          commandStarted?.resume(); commandStarted = nil
        }
      }
      if failNextCommand { failNextCommand = false; throw APIError.timeout }
      let state = states.isEmpty ? "SUCCEEDED" : states.removeFirst()
      result = .object(["id": .string("command-1"), "status": .string(state),
        "result": .object(["message": .string("绑定失败")])])
    default:
      XCTFail("Unexpected network boundary: " + request.path)
      throw APIError.invalidResponse
    }
    return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(result))
  }
}
