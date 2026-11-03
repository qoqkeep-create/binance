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
    let positions = (0..<7).compactMap { index in
      FloatingPosition(.object(["id": .string(String(index)), "symbol": .string("COIN\(index)USDT"),
        "side": .string("1"), "current_price": .string("0.0000001"), "pnl": .string("-0.000012345")]))
    }
    let state = PositionLiveIdentity.content(positions: positions, at: Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(state.positions.count, 4)
    XCTAssertEqual(state.totalCount, 7)
    XCTAssertEqual(state.positions.first?.profit, "-0.00001235 U")
    XCTAssertEqual(state.positions.first?.symbol, "COIN0USDT")
    XCTAssertEqual(state.updatedAt, 1_000)
    let empty = PositionLiveIdentity.content(positions: [], at: Date(timeIntervalSince1970: 1_001))
    XCTAssertEqual(empty.status, "暂无持仓")
    XCTAssertEqual(empty.totalCount, 0)
    XCTAssertTrue(empty.positions.isEmpty)
  }

  func testActivityIdentitySeparatesServersUsersAndModes() {
    let key = PositionLiveIdentity.key(server: "https://one.invalid/", userID: "1", mode: "ordinary")
    XCTAssertEqual(key.count, 64)
    XCTAssertNotEqual(key, PositionLiveIdentity.key(server: "https://two.invalid/", userID: "1", mode: "ordinary"))
    XCTAssertNotEqual(key, PositionLiveIdentity.key(server: "https://one.invalid/", userID: "2", mode: "ordinary"))
    XCTAssertNotEqual(key, PositionLiveIdentity.key(server: "https://one.invalid/", userID: "1", mode: "lead"))
  }
}
