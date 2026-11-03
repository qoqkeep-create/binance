import Foundation
import XCTest
@testable import TradeTool

final class PositionLiveActivityTests: XCTestCase {
  func testServerContentStateDecodesUnixTimestampAndMissingProfitWithoutLosingPrecision() throws {
    let payload = Data(#"{"positions":[{"id":"BTCUSDT:short","symbol":"BTCUSDT","isShort":true,"profit":"-0.00001234 U"},{"id":"ETHUSDT:long","symbol":"ETHUSDT","isShort":false,"profit":"--"}],"totalCount":2,"updatedAt":1793715000,"status":""}"#.utf8)
    let state = try JSONDecoder().decode(PositionLiveContentState.self, from: payload)
    XCTAssertEqual(state.updatedDate.timeIntervalSince1970, 1_793_715_000)
    XCTAssertEqual(state.positions[0].profit, "-0.00001234 U")
    XCTAssertEqual(state.positions[1].profit, "--")
    XCTAssertTrue(state.positions[0].isShort)
    XCTAssertFalse(state.isExpired(at: Date(timeIntervalSince1970: 1_793_715_090)))
    XCTAssertTrue(state.isExpired(at: Date(timeIntervalSince1970: 1_793_715_091)))
  }

  func testInitialCardUsesDecimalSnapshotAndBoundsPayloadWithoutLosingTotalCount() throws {
    let positions = (0..<7).map { index in
      JSONValue.object(["id": .string(String(index)), "symbol": .string("COIN\(index)USDT"),
        "side": .string("1"), "current_price": .string("0.0000001"), "pnl": .string("-0.000012345")])
    }
    let state = PositionLiveIdentity.content(rows: positions, at: Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(state.positions.count, 4)
    XCTAssertEqual(state.totalCount, 7)
    XCTAssertEqual(state.positions.first?.profit, "-0.00001235 U")
    XCTAssertEqual(state.positions.first?.symbol, "COIN0USDT")
    XCTAssertEqual(state.updatedAt, 1_000)
    let empty = PositionLiveIdentity.content(rows: [], at: Date(timeIntervalSince1970: 1_001))
    XCTAssertEqual(empty.status, "暂无持仓")
    XCTAssertEqual(empty.totalCount, 0)
    XCTAssertTrue(empty.positions.isEmpty)
  }

  func testLiveInitialFrameKeepsServerProfitProjectionIndependentFromTickerValuation() {
    let row = JSONValue.object(["id": .string("position"), "symbol": .string("BTCUSDT"),
      "side": .string("0"), "open_price": .string("100"), "exchange_size": .string("2"),
      "current_price": .string("110"), "pnl": .string("19.5")])
    let state = PositionLiveIdentity.content(rows: [row, .object([:])], at: Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(state.positions.first?.profit, "+19.500 U")
    XCTAssertEqual(state.totalCount, 1)
    let missing = PositionLiveIdentity.content(rows: [.object(["symbol": .string("BTCUSDT"), "pnl": .string("NaN")])],
      at: Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(missing.positions.first?.profit, "--")
  }

  func testActivityIdentitySeparatesServersUsersAndModes() {
    let key = PositionLiveIdentity.key(server: "https://one.invalid/", userID: "1", mode: "ordinary")
    XCTAssertEqual(key.count, 64)
    XCTAssertNotEqual(key, PositionLiveIdentity.key(server: "https://two.invalid/", userID: "1", mode: "ordinary"))
    XCTAssertNotEqual(key, PositionLiveIdentity.key(server: "https://one.invalid/", userID: "2", mode: "ordinary"))
    XCTAssertNotEqual(key, PositionLiveIdentity.key(server: "https://one.invalid/", userID: "1", mode: "lead"))
  }
}
