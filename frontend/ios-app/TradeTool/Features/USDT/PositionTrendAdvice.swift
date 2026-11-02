import Foundation
import Combine

struct PositionTrendSnapshot: Equatable, Sendable {
  let ema21: Double
  let ema55: Double
  let ema144: Double
  let superTrend: SuperTrendDirection

  func isCountertrend(isLong: Bool) -> Bool {
    let aligned = isLong
      ? ema21 > ema55 && ema55 > ema144
      : ema21 < ema55 && ema55 < ema144
    return !aligned && superTrend == (isLong ? .down : .up)
  }

  static func calculate(
    candles: [MarketCandle], interval: MarketKlineInterval, now: Date
  ) -> Self? {
    guard interval.duration >= MarketKlineInterval.oneHour.duration else { return nil }
    let step = Int64(interval.duration * 1_000)
    let nowMS = Int64(now.timeIntervalSince1970 * 1_000)
    // A live bucket or the immediately preceding closed bucket is required.
    guard let latest = candles.last, latest.openTime <= nowMS,
      latest.closeTime >= nowMS - step else { return nil }
    var fast = EMAIndicatorCalculator(period: 21, intervalMilliseconds: step)!
    var middle = EMAIndicatorCalculator(period: 55, intervalMilliseconds: step)!
    var slow = EMAIndicatorCalculator(period: 144, intervalMilliseconds: step)!
    let parameters = ChartIndicatorParameters.standard
    var trend = SuperTrendIndicatorCalculator(
      atrPeriod: parameters.superTrendATRPeriod,
      multiplier: parameters.superTrendMultiplier, intervalMilliseconds: step)!
    var values: (IndicatorPoint, IndicatorPoint, IndicatorPoint, SuperTrendPoint)?
    for item in candles {
      let candle = ChartCandle(marketCandle: item,
        closure: item.closeTime < nowMS ? .closed : .provisional)
      guard candle.isValid else { return nil }
      if candle.closure == .closed {
        values = (fast.commit(candle), middle.commit(candle), slow.commit(candle), trend.commit(candle))
      } else {
        guard item.openTime == latest.openTime,
          let a = fast.provisional(candle), let b = middle.provisional(candle),
          let c = slow.provisional(candle), let d = trend.provisional(candle) else { return nil }
        values = (a, b, c, d)
      }
    }
    guard let (a, b, c, d) = values,
      a.validity == .valid, b.validity == .valid, c.validity == .valid, d.validity == .valid,
      let ema21 = a.value, let ema55 = b.value, let ema144 = c.value,
      let direction = d.direction else { return nil }
    return Self(ema21: ema21, ema55: ema55, ema144: ema144, superTrend: direction)
  }
}

@MainActor
final class PositionTrendAdviceModel: ObservableObject {
  static let message = "当前处于逆势，建议设置保本损。"
  @Published private(set) var snapshots: [String: [PositionTrendSnapshot]] = [:]
  private var generation = UUID()

  func isCountertrend(symbol: String, side: String) -> Bool {
    guard side == "0" || side == "1" else { return false }
    return snapshots[symbol.uppercased()]?.contains { $0.isCountertrend(isLong: side == "0") } == true
  }

  func monitor(symbols: [String], api: any APIClient) async {
    let current = UUID()
    generation = current
    snapshots = [:]
    defer { if generation == current { snapshots = [:] } }
    guard !symbols.isEmpty else { return }
    while !Task.isCancelled, generation == current {
      for symbol in symbols {
        async let hour = fetch(symbol: symbol, interval: .oneHour, api: api)
        async let fourHours = fetch(symbol: symbol, interval: .fourHours, api: api)
        async let day = fetch(symbol: symbol, interval: .oneDay, api: api)
        let values = await [hour, fourHours, day].compactMap { $0 }
        guard !Task.isCancelled, generation == current else { return }
        snapshots[symbol] = values
      }
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
    }
  }

  private func fetch(
    symbol: String, interval: MarketKlineInterval, api: any APIClient
  ) async -> PositionTrendSnapshot? {
    do {
      let response = try await api.send(APIRequest<MarketKlineHistoryResponse>(
        path: "/api/market/klines", queryItems: [
          .init(name: "symbol", value: symbol), .init(name: "interval", value: interval.rawValue),
          .init(name: "limit", value: "1500"),
        ], showsErrorToast: false))
      guard !Task.isCancelled, response.symbol.uppercased() == symbol,
        response.interval == interval.rawValue else { return nil }
      return PositionTrendSnapshot.calculate(candles: response.items, interval: interval, now: .now)
    } catch { return nil }
  }
}
