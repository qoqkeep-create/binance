import Foundation

struct MarketRealtimeKlineUpdate: Sendable {
    let payload: RealtimeKlineEventPayload
    let sequence: Int64
    let closedSequence: Int64?
}

struct MarketRealtimeStoreHealth: Sendable, Equatable {
    let symbol: String
    let klineCount: Int
    let tickerCount: Int
    let discardedKlines: Int
    let discardedTickers: Int
}

/// Normalizes one symbol's public market stream before it reaches the chart.
/// Forming values are latest-wins per interval and older ticker snapshots are
/// ignored. Closed K-lines are never replaced by a later forming value.
actor MarketRealtimeStore {
    private let symbol: String
    private var latestKlines: [String: RealtimeKlineEventPayload] = [:]
    private var latestTickers: [String: MarketTickerPayload] = [:]
    private var discardedKlines = 0
    private var discardedTickers = 0

    init(symbol: String) {
        self.symbol = symbol.uppercased()
    }

    func ingestKline(
        _ payload: RealtimeKlineEventPayload,
        sequence: Int64,
        closedSequence: Int64?
    ) -> MarketRealtimeKlineUpdate? {
        guard payload.symbol.uppercased() == symbol,
              sequence > 0,
              payload.eventTime >= 0,
              payload.openTime >= 0 else {
            discardedKlines += 1
            return nil
        }

        let key = payload.interval
        if let previous = latestKlines[key] {
            guard payload.eventTime >= previous.eventTime else {
                discardedKlines += 1
                return nil
            }
            if payload.eventTime == previous.eventTime,
               payload.closed == previous.closed,
               payload.openTime == previous.openTime {
                discardedKlines += 1
                return nil
            }
            // A closed candle is authoritative for its bucket. A stale
            // forming packet must not reopen it after a reconnect.
            if previous.closed,
               payload.openTime == previous.openTime,
               !payload.closed {
                discardedKlines += 1
                return nil
            }
        }

        latestKlines[key] = payload
        return MarketRealtimeKlineUpdate(
            payload: payload,
            sequence: sequence,
            closedSequence: closedSequence
        )
    }

    func ingestTicker(_ payload: MarketTickerPayload) -> MarketTickerPayload? {
        guard payload.symbol.uppercased() == symbol,
              payload.eventTime >= 0,
              payload.lastPrice.isFinite,
              payload.lastPrice > 0 else {
            discardedTickers += 1
            return nil
        }
        if let previous = latestTickers[payload.symbol.uppercased()],
           payload.eventTime <= previous.eventTime {
            discardedTickers += 1
            return nil
        }
        latestTickers[payload.symbol.uppercased()] = payload
        return payload
    }

    func reset() {
        latestKlines.removeAll(keepingCapacity: true)
        latestTickers.removeAll(keepingCapacity: true)
        discardedKlines = 0
        discardedTickers = 0
    }

    func health() -> MarketRealtimeStoreHealth {
        MarketRealtimeStoreHealth(
            symbol: symbol,
            klineCount: latestKlines.count,
            tickerCount: latestTickers.count,
            discardedKlines: discardedKlines,
            discardedTickers: discardedTickers
        )
    }
}
