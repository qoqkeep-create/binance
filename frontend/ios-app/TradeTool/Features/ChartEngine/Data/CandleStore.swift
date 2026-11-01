import Foundation

final class ChartCandleHistory: @unchecked Sendable {
    let candles: [ChartCandle]

    init(candles: [ChartCandle]) {
        self.candles = candles
    }
}

struct ChartCandleSnapshot: Sendable {
    let history: ChartCandleHistory
    let liveTail: ChartCandle?
    let revision: UInt64
}

// Owned synchronously by the pipeline so candle and indicator updates cannot interleave.
struct CandleStorage {
    private var history: ChartCandleHistory
    private var liveTail: ChartCandle?
    private var revision: UInt64 = 0
    private let historyLimit: Int

    init(
        initialClosed: [ChartCandle] = [],
        historyLimit: Int = 3_000
    ) {
        self.historyLimit = max(1, historyLimit)
        history = ChartCandleHistory(
            candles: Self.normalizedClosed(
                initialClosed,
                limit: max(1, historyLimit)
            )
        )
    }

    mutating func apply(
        _ mutation: KlineIngressMutation
    ) -> ChartCandleSnapshot {
        let candle = preservingTradingData(in: mutation.candle)

        switch candle.closure {
        case .provisional, .unverifiedClosed:
            if liveTail == nil
                || candle.openTime
                    >= (liveTail?.openTime ?? Int64.min) {
                liveTail = candle
            }

        case .closed:
            commit(candle)
            if liveTail?.openTime == candle.openTime {
                liveTail = nil
            }
        }

        revision = max(revision &+ 1, mutation.revision)
        return snapshot()
    }

    mutating func installSnapshot(
        closedCandles: [ChartCandle],
        liveCandle: ChartCandle? = nil,
        preservingNewerData: Bool = false
    ) -> ChartCandleSnapshot {
        let previousLive = liveTail
        let merged = Self.normalizedClosed(
            (preservingNewerData ? history.candles : []) + closedCandles,
            limit: historyLimit
        )
        let historyChanged = merged != history.candles
        if historyChanged {
            history = ChartCandleHistory(candles: merged)
        }
        liveTail = liveCandle.map(preservingTradingData(in:))
        if preservingNewerData, let previousLive,
           previousLive.openTime >= (liveCandle?.openTime ?? Int64.min),
           previousLive.openTime > (history.candles.last?.openTime ?? Int64.min) {
            liveTail = previousLive.withTradingData(
                liveCandle?.openTime == previousLive.openTime
                    ? liveCandle?.tradingData ?? previousLive.tradingData : previousLive.tradingData)
        }
        if preservingNewerData, let tail = liveTail,
           tail.openTime <= (history.candles.last?.openTime ?? Int64.min) { liveTail = nil }
        if historyChanged || liveTail != previousLive { revision &+= 1 }
        return snapshot()
    }

    mutating func upsertProvisional(
        _ candle: ChartCandle
    ) -> ChartCandleSnapshot {
        let resolved = preservingTradingData(in: candle)
        guard resolved.isValid,
              resolved.closure != .closed,
              liveTail == nil
                || resolved.openTime
                    >= (liveTail?.openTime ?? Int64.min) else {
            return snapshot()
        }
        liveTail = resolved.withClosure(.provisional)
        revision &+= 1
        return snapshot()
    }

    mutating func prependClosedHistory(
        _ candles: [ChartCandle]
    ) -> ChartCandleSnapshot {
        guard !candles.isEmpty else {
            return snapshot()
        }
        let merged = Self.normalizedClosed(candles + history.candles, limit: historyLimit)
        if merged != history.candles {
            history = ChartCandleHistory(candles: merged)
            revision &+= 1
        }
        return snapshot()
    }

    func snapshot() -> ChartCandleSnapshot {
        ChartCandleSnapshot(
            history: history,
            liveTail: liveTail,
            revision: revision
        )
    }

    private mutating func commit(_ candle: ChartCandle) {
        var candles = history.candles
        let insertion = candles.partitioningIndex {
            $0.openTime >= candle.openTime
        }

        if insertion < candles.count,
           candles[insertion].openTime == candle.openTime {
            candles[insertion] = candle
        } else {
            candles.insert(candle, at: insertion)
        }

        if candles.count > historyLimit {
            candles.removeFirst(candles.count - historyLimit)
        }
        history = ChartCandleHistory(candles: candles)
    }

    private func preservingTradingData(
        in candle: ChartCandle
    ) -> ChartCandle {
        guard candle.tradingData == nil else {
            return candle
        }
        if let current = liveTail,
           current.openTime == candle.openTime,
           let tradingData = current.tradingData {
            return candle.withTradingData(tradingData)
        }
        guard let latestTradingData = history.candles
            .reversed()
            .compactMap(\.tradingData)
            .first else {
            return candle
        }
        return candle.withTradingData(latestTradingData)
    }

    private static func normalizedClosed(
        _ candles: [ChartCandle],
        limit: Int
    ) -> [ChartCandle] {
        var byOpenTime: [Int64: ChartCandle] = [:]
        for candle in candles where candle.isValid {
            byOpenTime[candle.openTime] = candle.withClosure(.closed)
        }
        return Array(
            byOpenTime.values
                .sorted { $0.openTime < $1.openTime }
                .suffix(limit)
        )
    }
}

// Standalone consumers retain actor isolation; the pipeline owns its own value storage.
actor CandleStore {
    private var storage: CandleStorage

    init(initialClosed: [ChartCandle] = [], historyLimit: Int = 3_000) {
        storage = CandleStorage(initialClosed: initialClosed, historyLimit: historyLimit)
    }

    func apply(_ mutation: KlineIngressMutation) -> ChartCandleSnapshot {
        storage.apply(mutation)
    }

    func installSnapshot(closedCandles: [ChartCandle], liveCandle: ChartCandle? = nil,
                         preservingNewerData: Bool = false) -> ChartCandleSnapshot {
        storage.installSnapshot(closedCandles: closedCandles, liveCandle: liveCandle,
                                preservingNewerData: preservingNewerData)
    }

    func upsertProvisional(_ candle: ChartCandle) -> ChartCandleSnapshot {
        storage.upsertProvisional(candle)
    }

    func prependClosedHistory(_ candles: [ChartCandle]) -> ChartCandleSnapshot {
        storage.prependClosedHistory(candles)
    }

    func snapshot() -> ChartCandleSnapshot { storage.snapshot() }
}

private extension Array {
    func partitioningIndex(
        where predicate: (Element) -> Bool
    ) -> Int {
        var lowerBound = startIndex
        var upperBound = endIndex

        while lowerBound < upperBound {
            let distance = self.distance(
                from: lowerBound,
                to: upperBound
            )
            let middle = index(
                lowerBound,
                offsetBy: distance / 2
            )
            if predicate(self[middle]) {
                upperBound = middle
            } else {
                lowerBound = index(after: middle)
            }
        }
        return lowerBound
    }
}
