import Foundation

enum MarketKlineInterval: String, CaseIterable, Identifiable, Codable {
    case oneMinute = "1m"
    case threeMinutes = "3m"
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case twoHours = "2h"
    case fourHours = "4h"
    case eightHours = "8h"
    case sixteenHours = "16h"
    case oneDay = "1d"
    case threeDays = "3d"
    case oneWeek = "1w"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneMinute:
            return "1分"
        case .threeMinutes:
            return "3分"
        case .fiveMinutes:
            return "5分"
        case .fifteenMinutes:
            return "15分"
        case .thirtyMinutes:
            return "30分"
        case .oneHour:
            return "1小时"
        case .twoHours:
            return "2小时"
        case .fourHours:
            return "4小时"
        case .eightHours:
            return "8小时"
        case .sixteenHours:
            return "16小时"
        case .oneDay:
            return "1天"
        case .threeDays:
            return "3天"
        case .oneWeek:
            return "1周"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .oneMinute:
            return 60
        case .threeMinutes:
            return 3 * 60
        case .fiveMinutes:
            return 5 * 60
        case .fifteenMinutes:
            return 15 * 60
        case .thirtyMinutes:
            return 30 * 60
        case .oneHour:
            return 60 * 60
        case .twoHours:
            return 2 * 60 * 60
        case .fourHours:
            return 4 * 60 * 60
        case .eightHours:
            return 8 * 60 * 60
        case .sixteenHours:
            return 16 * 60 * 60
        case .oneDay:
            return 24 * 60 * 60
        case .threeDays:
            return 3 * 24 * 60 * 60
        case .oneWeek:
            return 7 * 24 * 60 * 60
        }
    }
}

struct MarketKlineHistoryResponse: Decodable, Sendable {
    let symbol: String
    let interval: String
    let items: [MarketCandle]
    var historyPending: Bool? = nil
    var statisticsPending: Bool? = nil
    var hasMoreHistory: Bool? = nil
}

struct MarketChartTradingData: Decodable, Equatable, Hashable, Sendable {
    let openInterest: Double?
    let openInterestNotional: Double?
    let topLongAccount: Double?
    let topShortAccount: Double?
    let topLongShortAccountRatio: Double?
    let topLongPosition: Double?
    let topShortPosition: Double?
    let topLongShortPositionRatio: Double?
    let globalLongAccount: Double?
    let globalShortAccount: Double?
    let globalLongShortAccountRatio: Double?
    let takerBuyVolume: Double?
    let takerSellVolume: Double?
    let basis: Double?
    let basisRate: Double?
    let futuresPrice: Double?
    let indexPrice: Double?

    init(
        openInterest: Double? = nil,
        openInterestNotional: Double? = nil,
        topLongAccount: Double? = nil,
        topShortAccount: Double? = nil,
        topLongShortAccountRatio: Double? = nil,
        topLongPosition: Double? = nil,
        topShortPosition: Double? = nil,
        topLongShortPositionRatio: Double? = nil,
        globalLongAccount: Double? = nil,
        globalShortAccount: Double? = nil,
        globalLongShortAccountRatio: Double? = nil,
        takerBuyVolume: Double? = nil,
        takerSellVolume: Double? = nil,
        basis: Double? = nil,
        basisRate: Double? = nil,
        futuresPrice: Double? = nil,
        indexPrice: Double? = nil
    ) {
        self.openInterest = openInterest
        self.openInterestNotional = openInterestNotional
        self.topLongAccount = topLongAccount
        self.topShortAccount = topShortAccount
        self.topLongShortAccountRatio = topLongShortAccountRatio
        self.topLongPosition = topLongPosition
        self.topShortPosition = topShortPosition
        self.topLongShortPositionRatio = topLongShortPositionRatio
        self.globalLongAccount = globalLongAccount
        self.globalShortAccount = globalShortAccount
        self.globalLongShortAccountRatio = globalLongShortAccountRatio
        self.takerBuyVolume = takerBuyVolume
        self.takerSellVolume = takerSellVolume
        self.basis = basis
        self.basisRate = basisRate
        self.futuresPrice = futuresPrice
        self.indexPrice = indexPrice
    }
}

struct MarketCandle: Decodable, Identifiable, Hashable, Sendable {
    let openTime: Int64
    let closeTime: Int64
    let openPrice: Double
    let highPrice: Double
    let lowPrice: Double
    let closePrice: Double
    let volume: Double
    let quoteVolume: Double
    let tradingData: MarketChartTradingData?

    var id: Int64 { openTime }
    var date: Date {
        Date(timeIntervalSince1970: Double(openTime) / 1_000)
    }
    var isRising: Bool { closePrice >= openPrice }

    init(
        openTime: Int64,
        closeTime: Int64,
        openPrice: Double,
        highPrice: Double,
        lowPrice: Double,
        closePrice: Double,
        volume: Double,
        quoteVolume: Double,
        tradingData: MarketChartTradingData? = nil
    ) {
        self.openTime = openTime
        self.closeTime = closeTime
        self.openPrice = openPrice
        self.highPrice = highPrice
        self.lowPrice = lowPrice
        self.closePrice = closePrice
        self.volume = volume
        self.quoteVolume = quoteVolume
        self.tradingData = tradingData
    }
}

struct MarketChartIndicators: Equatable, Sendable {
    let ema21: [Double]
    let ema55: [Double]
    let ema144: [Double]
    let superTrend: [Double]
    let volumeMA5: [Double]
    let volumeMA10: [Double]
    let macd: [Double]
    let signal: [Double]
    let histogram: [Double]

    static let empty = MarketChartIndicators(
        ema21: [],
        ema55: [],
        ema144: [],
        superTrend: [],
        volumeMA5: [],
        volumeMA10: [],
        macd: [],
        signal: [],
        histogram: []
    )

    static func calculate(
        candles: [MarketCandle]
    ) -> MarketChartIndicators {
        guard !candles.isEmpty else {
            return .empty
        }

        let closes = candles.map(\.closePrice)
        let volumes = candles.map(\.volume)
        let ema12 = exponentialMovingAverage(closes, period: 12)
        let ema26 = exponentialMovingAverage(closes, period: 26)
        let macd = zip(ema12, ema26).map { pair in
            pair.0 - pair.1
        }
        let signal = exponentialMovingAverage(macd, period: 9)
        let histogram = zip(macd, signal).map {
            ($0 - $1) * 2
        }

        return MarketChartIndicators(
            ema21: exponentialMovingAverage(closes, period: 21),
            ema55: exponentialMovingAverage(closes, period: 55),
            ema144: exponentialMovingAverage(closes, period: 144),
            superTrend: superTrend(
                candles: candles,
                period: 10,
                multiplier: 6
            ),
            volumeMA5: simpleMovingAverage(volumes, period: 5),
            volumeMA10: simpleMovingAverage(volumes, period: 10),
            macd: macd,
            signal: signal,
            histogram: histogram
        )
    }

    private static func exponentialMovingAverage(
        _ values: [Double],
        period: Int
    ) -> [Double] {
        guard let first = values.first else {
            return []
        }
        let multiplier = 2.0 / Double(period + 1)
        var result = [Double]()
        result.reserveCapacity(values.count)
        var previous = first
        for value in values {
            previous = value * multiplier
                + previous * (1 - multiplier)
            result.append(previous)
        }
        return result
    }

    private static func simpleMovingAverage(
        _ values: [Double],
        period: Int
    ) -> [Double] {
        guard !values.isEmpty else {
            return []
        }
        var result = Array(repeating: Double.nan, count: values.count)
        var sum = 0.0
        for index in values.indices {
            sum += values[index]
            if index >= period {
                sum -= values[index - period]
            }
            if index >= period - 1 {
                result[index] = sum / Double(period)
            }
        }
        return result
    }

    private static func superTrend(
        candles: [MarketCandle],
        period: Int,
        multiplier: Double
    ) -> [Double] {
        let count = candles.count
        guard count > 0 else {
            return []
        }

        var trueRanges = Array(repeating: 0.0, count: count)
        for index in candles.indices {
            let candle = candles[index]
            if index == 0 {
                trueRanges[index] = candle.highPrice - candle.lowPrice
            } else {
                let previousClose = candles[index - 1].closePrice
                trueRanges[index] = max(
                    candle.highPrice - candle.lowPrice,
                    max(
                        abs(candle.highPrice - previousClose),
                        abs(candle.lowPrice - previousClose)
                    )
                )
            }
        }

        var atr = Array(repeating: 0.0, count: count)
        atr[0] = trueRanges[0]
        for index in 1..<count {
            atr[index] = (
                atr[index - 1] * Double(period - 1)
                    + trueRanges[index]
            ) / Double(period)
        }

        var upper = Array(repeating: 0.0, count: count)
        var lower = Array(repeating: 0.0, count: count)
        var trend = Array(repeating: 0.0, count: count)

        for index in candles.indices {
            let candle = candles[index]
            let middle = (candle.highPrice + candle.lowPrice) / 2
            let basicUpper = middle + multiplier * atr[index]
            let basicLower = middle - multiplier * atr[index]

            if index == 0 {
                upper[index] = basicUpper
                lower[index] = basicLower
                trend[index] = candle.closePrice >= middle
                    ? basicLower
                    : basicUpper
                continue
            }

            let previous = candles[index - 1]
            upper[index] =
                basicUpper < upper[index - 1]
                || previous.closePrice > upper[index - 1]
                ? basicUpper
                : upper[index - 1]
            lower[index] =
                basicLower > lower[index - 1]
                || previous.closePrice < lower[index - 1]
                ? basicLower
                : lower[index - 1]

            if trend[index - 1] == upper[index - 1] {
                trend[index] = candle.closePrice <= upper[index]
                    ? upper[index]
                    : lower[index]
            } else {
                trend[index] = candle.closePrice >= lower[index]
                    ? lower[index]
                    : upper[index]
            }
        }
        return trend
    }
}
