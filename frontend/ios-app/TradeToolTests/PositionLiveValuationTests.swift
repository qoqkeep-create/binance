import XCTest
@testable import TradeTool

@MainActor
final class PositionLiveValuationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000)

  func testEveryTickerUpdatesPriceAndProfitWithoutUsingApiFinancialValues() throws {
    let quotes = PositionLiveQuotes()
    let session = quotes.begin(scope: "account", symbols: ["BTCUSDT"])
    quotes.receive(ticker("101", time: 1_000_000), session: session, now: now)
    let first = try XCTUnwrap(PositionLiveValuation(row: row(), quote: quotes.quotes["BTCUSDT"]))
    XCTAssertEqual(first.price, Decimal(101))
    XCTAssertEqual(first.profit, Decimal(2))
    quotes.receive(ticker("99", time: 1_000_001), session: session, now: now)
    let second = try XCTUnwrap(PositionLiveValuation(row: row(), quote: quotes.quotes["BTCUSDT"]))
    XCTAssertEqual(second.price, Decimal(99))
    XCTAssertEqual(second.profit, Decimal(-2))
  }

  func testRemainingQuantityAndUpdatedAverageReplaceInitialOrderSize() throws {
    var position = row()
    var fields = position.fields
    fields["exchange_size"] = .string("0.4")
    fields["open_price"] = .string("105")
    fields["leverage"] = .string("100")
    position = .object(fields)
    let value = try XCTUnwrap(PositionLiveValuation(row: position, quote: quote("110")))
    XCTAssertEqual(value.profit, Decimal(2))
  }

  func testShortProfitReversesPriceDifferenceWithoutMultiplyingLeverage() throws {
    var fields = row().fields
    fields["side"] = .string("1")
    fields["leverage"] = .string("100")
    let value = try XCTUnwrap(PositionLiveValuation(row: .object(fields), quote: quote("90")))
    XCTAssertEqual(value.profit, Decimal(20))
  }

  func testSmallPricesUseDecimalArithmetic() throws {
    var fields = row().fields
    fields["open_price"] = .string("0.000000001111")
    fields["exchange_size"] = .string("100000000")
    let value = try XCTUnwrap(PositionLiveValuation(row: .object(fields), quote: quote("0.000000001234")))
    XCTAssertEqual(value.profit, Decimal(string: "0.0123"))
  }

  func testUnknownOrZeroQuantityDoesNotBecomeInitialSizeOrPlatformProfit() {
    for quantity in [JSONValue.string("0"), .string("-1"), .string("invalid"), .null] {
      var fields = row().fields
      fields["exchange_size"] = quantity
      XCTAssertNil(PositionLiveValuation(row: .object(fields), quote: quote("110")))
    }
    XCTAssertNil(PositionLiveValuation(row: row(), quote: nil))
    var fields = row().fields
    fields.removeValue(forKey: "exchange_size")
    fields.removeValue(forKey: "size")
    fields["position_amount"] = .string("10000")
    XCTAssertNil(PositionLiveValuation(row: .object(fields), quote: quote("110")))
  }

  func testLegacyQuantityFallbackAndInvalidDirection() throws {
    var fields = row().fields
    fields.removeValue(forKey: "exchange_size")
    XCTAssertEqual(try XCTUnwrap(PositionLiveValuation(row: .object(fields), quote: quote("110"))).profit, Decimal(20))
    fields["side"] = .string("unexpected")
    XCTAssertNil(PositionLiveValuation(row: .object(fields), quote: quote("110")))
  }

  func testOutOfOrderUnrelatedAndInvalidTicksCannotOverwriteLatestPrice() {
    let quotes = PositionLiveQuotes()
    let session = quotes.begin(scope: "account", symbols: ["BTCUSDT"])
    quotes.receive(ticker("101", time: 1_000_000), session: session, now: now)
    quotes.receive(ticker("50", time: 999_999), session: session, now: now)
    quotes.receive(ticker("200", time: 1_000_001, symbol: "ETHUSDT"), session: session, now: now)
    quotes.receive(ticker("0", time: 1_000_001), session: session, now: now)
    quotes.receive(ticker("NaN", time: 1_000_001), session: session, now: now)
    XCTAssertEqual(quotes.quotes["BTCUSDT"]?.price, Decimal(101))
    XCTAssertNil(quotes.quotes["ETHUSDT"])
  }

  func testOldSessionAndOldCleanupCannotModifyNewSession() {
    let quotes = PositionLiveQuotes()
    let old = quotes.begin(scope: "account", symbols: ["BTCUSDT"])
    quotes.receive(ticker("101", time: 1_000_000), session: old, now: now)
    let current = quotes.begin(scope: "account", symbols: ["BTCUSDT"])
    XCTAssertEqual(quotes.quotes["BTCUSDT"]?.price, Decimal(101))
    quotes.receive(ticker("102", time: 1_000_001), session: current, now: now)
    quotes.receive(ticker("999", time: 1_000_002), session: old, now: now)
    XCTAssertFalse(quotes.end(old))
    XCTAssertEqual(quotes.quotes["BTCUSDT"]?.price, Decimal(102))
    XCTAssertTrue(quotes.end(current))
    XCTAssertEqual(quotes.quotes["BTCUSDT"]?.price, Decimal(102))
  }

  func testPausingAndReconnectingKeepLastPriceUntilANewerTickArrives() {
    let quotes = PositionLiveQuotes()
    let first = quotes.begin(scope: "account", symbols: ["BTCUSDT"])
    quotes.receive(ticker("101", time: 1_000_000), session: first, now: now)
    quotes.end(first)
    let paused = quotes.begin(scope: "account", symbols: [])
    quotes.end(paused)
    let resumed = quotes.begin(scope: "account", symbols: ["BTCUSDT"])
    quotes.receive(RealtimeServerMessage(version: 1, type: "ready", requestId: nil, channel: nil,
      event: nil, key: nil, sequence: nil, timestamp: 0, data: nil, error: nil), session: resumed, now: now)
    XCTAssertEqual(PositionLiveValuation(row: row(), quote: quotes.quotes["BTCUSDT"])?.profit, Decimal(2))
    quotes.receive(ticker("103", time: 1_000_001), session: resumed, now: now)
    XCTAssertEqual(PositionLiveValuation(row: row(), quote: quotes.quotes["BTCUSDT"])?.profit, Decimal(6))
  }

  func testAccountOrBindingChangeClearsSnapshotAndRejectsPreviousSession() {
    let quotes = PositionLiveQuotes()
    let old = quotes.begin(scope: "user:ordinary:1", symbols: ["BTCUSDT"])
    quotes.receive(ticker("101", time: 1_000_000), session: old, now: now)
    let current = quotes.begin(scope: "user:lead:2", symbols: ["BTCUSDT"])
    XCTAssertTrue(quotes.quotes.isEmpty)
    quotes.receive(ticker("999", time: 1_000_002), session: old, now: now)
    XCTAssertTrue(quotes.quotes.isEmpty)
    quotes.receive(ticker("102", time: 1_000_001), session: current, now: now)
    quotes.reset()
    XCTAssertTrue(quotes.quotes.isEmpty)
    quotes.receive(ticker("999", time: 1_000_002), session: current, now: now)
    XCTAssertTrue(quotes.quotes.isEmpty)
  }

  func testDelayedAndFuturePacketsAreIgnoredOnArrival() {
    let quotes = PositionLiveQuotes()
    let session = quotes.begin(scope: "account", symbols: ["BTCUSDT"])
    quotes.receive(ticker("100", time: 900_000), session: session, now: now)
    quotes.receive(ticker("100", time: 1_100_000), session: session, now: now)
    XCTAssertTrue(quotes.quotes.isEmpty)
  }

  private func quote(_ price: String) -> PositionMarketQuote {
    PositionMarketQuote(price: Decimal(string: price)!, eventTime: 1_000_000)
  }

  private func row() -> JSONValue {
    .object(["symbol": .string("BTCUSDT"), "side": .string("0"), "open_price": .string("100"),
      "size": .string("2"), "exchange_size": .string("2"),
      "current_price": .string("9999"), "pnl": .string("9999")])
  }

  private func ticker(_ price: String, time: Int64, symbol: String = "BTCUSDT") -> RealtimeServerMessage {
    RealtimeServerMessage(version: 1, type: "event", requestId: nil, channel: "market.ticker",
      event: "update", key: symbol, sequence: nil, timestamp: time,
      data: .object(["symbol": .string(symbol), "lastPrice": .string(price), "eventTime": .number(Double(time))]), error: nil)
  }
}
