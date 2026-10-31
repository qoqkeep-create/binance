import Foundation

struct ChartStreamKey: Hashable, Sendable {
    let symbol: String
    let interval: String

    init(symbol: String, interval: String) {
        self.symbol = symbol.uppercased()
        self.interval = interval
    }
}

struct KlineStreamEpoch: Hashable, Sendable {
    let connectionID: UUID
    let generation: UInt64

    init(connectionID: UUID = UUID(), generation: UInt64) {
        self.connectionID = connectionID
        self.generation = generation
    }
}

enum ChartCandleClosure: Equatable, Sendable {
    case provisional
    case unverifiedClosed
    case closed
}

struct ChartCandle: Equatable, Sendable {
    let openTime: Int64
    let closeTime: Int64
    let openPrice: Double
    let highPrice: Double
    let lowPrice: Double
    let closePrice: Double
    let volume: Double
    let quoteVolume: Double
    let tradingData: MarketChartTradingData?
    let closure: ChartCandleClosure

    init(
        openTime: Int64,
        closeTime: Int64,
        openPrice: Double,
        highPrice: Double,
        lowPrice: Double,
        closePrice: Double,
        volume: Double,
        quoteVolume: Double,
        tradingData: MarketChartTradingData? = nil,
        closure: ChartCandleClosure
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
        self.closure = closure
    }

    var isValid: Bool {
        let prices = [
            openPrice,
            highPrice,
            lowPrice,
            closePrice,
            volume,
            quoteVolume,
        ]
        guard openTime >= 0,
              closeTime >= openTime,
              prices.allSatisfy(\.isFinite),
              volume >= 0,
              quoteVolume >= 0 else {
            return false
        }
        return highPrice >= max(openPrice, closePrice)
            && lowPrice <= min(openPrice, closePrice)
            && highPrice >= lowPrice
    }

    func withClosure(_ closure: ChartCandleClosure) -> ChartCandle {
        ChartCandle(
            openTime: openTime,
            closeTime: closeTime,
            openPrice: openPrice,
            highPrice: highPrice,
            lowPrice: lowPrice,
            closePrice: closePrice,
            volume: volume,
            quoteVolume: quoteVolume,
            tradingData: tradingData,
            closure: closure
        )
    }

    func withTradingData(
        _ tradingData: MarketChartTradingData?
    ) -> ChartCandle {
        ChartCandle(
            openTime: openTime,
            closeTime: closeTime,
            openPrice: openPrice,
            highPrice: highPrice,
            lowPrice: lowPrice,
            closePrice: closePrice,
            volume: volume,
            quoteVolume: quoteVolume,
            tradingData: tradingData,
            closure: closure
        )
    }
}

extension ChartCandle {
    init(
        marketCandle: MarketCandle,
        closure: ChartCandleClosure
    ) {
        self.init(
            openTime: marketCandle.openTime,
            closeTime: marketCandle.closeTime,
            openPrice: marketCandle.openPrice,
            highPrice: marketCandle.highPrice,
            lowPrice: marketCandle.lowPrice,
            closePrice: marketCandle.closePrice,
            volume: marketCandle.volume,
            quoteVolume: marketCandle.quoteVolume,
            tradingData: marketCandle.tradingData,
            closure: closure
        )
    }
}
