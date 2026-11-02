import XCTest
@testable import TradeTool

final class PositionTrendAdviceTests: XCTestCase {
  func testLongRequiresBothMissingBullishAlignmentAndDownSupertrend() {
    XCTAssertFalse(snapshot(3, 2, 1, .down).isCountertrend(isLong: true))
    XCTAssertFalse(snapshot(2, 3, 1, .up).isCountertrend(isLong: true))
    XCTAssertTrue(snapshot(2, 3, 1, .down).isCountertrend(isLong: true))
    XCTAssertTrue(snapshot(1, 2, 3, .down).isCountertrend(isLong: true))
    XCTAssertTrue(snapshot(2, 2, 1, .down).isCountertrend(isLong: true))
  }

  func testShortRequiresBothMissingBearishAlignmentAndUpSupertrend() {
    XCTAssertFalse(snapshot(1, 2, 3, .up).isCountertrend(isLong: false))
    XCTAssertFalse(snapshot(2, 1, 3, .down).isCountertrend(isLong: false))
    XCTAssertTrue(snapshot(2, 1, 3, .up).isCountertrend(isLong: false))
    XCTAssertTrue(snapshot(3, 2, 1, .up).isCountertrend(isLong: false))
    XCTAssertTrue(snapshot(1, 2, 2, .up).isCountertrend(isLong: false))
  }

  func testRealIndicatorCalculationForBothDirectionsAndHigherIntervals() throws {
    for interval in [MarketKlineInterval.oneHour, .fourHours, .oneDay] {
      let rising = candles(interval: interval, falling: false)
      let up = try XCTUnwrap(PositionTrendSnapshot.calculate(candles: rising, interval: interval, now: now(rising)))
      XCTAssertEqual(up.superTrend, .up)
      XCTAssertFalse(up.isCountertrend(isLong: true))
      XCTAssertTrue(up.isCountertrend(isLong: false))
      let falling = candles(interval: interval, falling: true)
      let down = try XCTUnwrap(PositionTrendSnapshot.calculate(candles: falling, interval: interval, now: now(falling)))
      XCTAssertEqual(down.superTrend, .down)
      XCTAssertTrue(down.isCountertrend(isLong: true))
      XCTAssertFalse(down.isCountertrend(isLong: false))
    }
  }

  func testInsufficientStaleAndSubhourDataDoNotProduceAdvice() {
    let data = candles()
    XCTAssertNil(PositionTrendSnapshot.calculate(candles: Array(data.suffix(100)), interval: .oneHour, now: now(data)))
    XCTAssertNil(PositionTrendSnapshot.calculate(candles: data, interval: .oneHour, now: now(data).addingTimeInterval(7_200)))
    XCTAssertNil(PositionTrendSnapshot.calculate(candles: data, interval: .fifteenMinutes, now: now(data)))
    XCTAssertNil(PositionTrendSnapshot.calculate(candles: [], interval: .oneHour, now: now(data)))
  }

  func testRecentGapRestartsWarmupInsteadOfCombiningDisconnectedHistory() {
    var data = candles()
    data.remove(at: data.count - 20)
    XCTAssertNil(PositionTrendSnapshot.calculate(candles: data, interval: .oneHour, now: now(data)))
  }

  func testCurrentUnclosedCandleParticipatesInAdvice() throws {
    var data = candles()
    let last = data.removeLast()
    data.append(MarketCandle(openTime: last.openTime, closeTime: last.closeTime,
      openPrice: last.openPrice, highPrice: last.highPrice, lowPrice: 10, closePrice: 10,
      volume: 1, quoteVolume: 10))
    let liveNow = Date(timeIntervalSince1970: Double(last.openTime + 1_000) / 1_000)
    let result = try XCTUnwrap(PositionTrendSnapshot.calculate(candles: data, interval: .oneHour, now: liveNow))
    XCTAssertEqual(result.superTrend, .down)
    XCTAssertTrue(result.isCountertrend(isLong: true))
  }

  @MainActor
  func testLaterScopeRejectsOldResponsesAndCancellationClearsAdvice() async throws {
    let model = PositionTrendAdviceModel()
    let oldAPI = PositionAdviceAPI(blocked: true)
    let oldTask = Task { await model.monitor(symbols: ["BTCUSDT"], api: oldAPI) }
    for _ in 0..<200 {
      if await oldAPI.requestCount == 3 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let oldRequestCount = await oldAPI.requestCount
    XCTAssertEqual(oldRequestCount, 3)
    let newAPI = PositionAdviceAPI()
    let newTask = Task { await model.monitor(symbols: ["ETHUSDT"], api: newAPI) }
    for _ in 0..<200 {
      if model.isCountertrend(symbol: "ETHUSDT", side: "1") { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(model.isCountertrend(symbol: "ETHUSDT", side: "1"))
    XCTAssertFalse(model.isCountertrend(symbol: "ETHUSDT", side: "0"))
    XCTAssertFalse(model.isCountertrend(symbol: "ETHUSDT", side: "unexpected"))
    await oldAPI.release()
    await oldTask.value
    XCTAssertNil(model.snapshots["BTCUSDT"])
    XCTAssertTrue(model.isCountertrend(symbol: "ETHUSDT", side: "1"))
    newTask.cancel()
    await newTask.value
    XCTAssertTrue(model.snapshots.isEmpty)
  }

  @MainActor
  func testFailedRefreshDoesNotReusePreviousAdvice() async throws {
    let model = PositionTrendAdviceModel()
    let api = PositionAdviceAPI()
    let first = Task { await model.monitor(symbols: ["BTCUSDT"], api: api) }
    for _ in 0..<200 {
      if model.isCountertrend(symbol: "BTCUSDT", side: "1") { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(model.isCountertrend(symbol: "BTCUSDT", side: "1"))
    let failedAPI = PositionAdviceAPI(fails: true)
    let next = Task { await model.monitor(symbols: ["BTCUSDT"], api: failedAPI) }
    for _ in 0..<200 {
      if await failedAPI.requestCount == 3 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertFalse(model.isCountertrend(symbol: "BTCUSDT", side: "1"))
    first.cancel(); next.cancel()
    await first.value; await next.value
  }

  private func snapshot(_ fast: Double, _ middle: Double, _ slow: Double,
                        _ trend: SuperTrendDirection) -> PositionTrendSnapshot {
    PositionTrendSnapshot(ema21: fast, ema55: middle, ema144: slow, superTrend: trend)
  }

  private func candles(interval: MarketKlineInterval = .oneHour, falling: Bool = false) -> [MarketCandle] {
    let step = Int64(interval.duration * 1_000)
    return (0..<300).map { index in
      let close = falling ? 1_000 - Double(index) * 2 : 100 + Double(index) * 2
      return MarketCandle(openTime: Int64(index) * step, closeTime: Int64(index + 1) * step - 1,
        openPrice: close, highPrice: close + 1, lowPrice: close - 1, closePrice: close,
        volume: 1, quoteVolume: close)
    }
  }

  private func now(_ data: [MarketCandle]) -> Date {
    Date(timeIntervalSince1970: Double(data.last!.closeTime + 1) / 1_000)
  }
}

private actor PositionAdviceAPI: APIClient {
  private var blocked: Bool
  private let fails: Bool
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private(set) var requestCount = 0
  init(blocked: Bool = false, fails: Bool = false) {
    self.blocked = blocked
    self.fails = fails
  }
  func release() {
    blocked = false
    waiters.forEach { $0.resume() }
    waiters.removeAll()
  }
  func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
    requestCount += 1
    if blocked { await withCheckedContinuation { waiters.append($0) } }
    if fails { throw URLError(.notConnectedToInternet) }
    let symbol = request.queryItems.first { $0.name == "symbol" }!.value!
    let interval = request.queryItems.first { $0.name == "interval" }!.value!
    let step = Int64(MarketKlineInterval(rawValue: interval)!.duration * 1_000)
    let bucket = Int64(Date().timeIntervalSince1970 * 1_000) / step * step
    let items = (0..<300).map { index in
      let close = 100 + Double(index) * 2
      let open = bucket - Int64(300 - index) * step
      return MarketCandle(openTime: open, closeTime: open + step - 1,
        openPrice: close, highPrice: close + 1, lowPrice: close - 1, closePrice: close,
        volume: 1, quoteVolume: close)
    }
    return MarketKlineHistoryResponse(symbol: symbol, interval: interval, items: items) as! Response
  }
}
