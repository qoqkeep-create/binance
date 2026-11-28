import XCTest
@testable import TradeTool

final class MarketRealtimeStoreTests: XCTestCase {
    func testStoreRejectsOlderKlineAndTickerPackets() async throws {
        let store = MarketRealtimeStore(symbol: "BTCUSDT")
        let forming = RealtimeKlineEventPayload(
            symbol: "BTCUSDT", contractType: "PERPETUAL", interval: "1h",
            eventTime: 2_000, openTime: 0, closeTime: 3_599_999,
            openPrice: 100, highPrice: 105, lowPrice: 99, closePrice: 104,
            volume: 1, quoteVolume: 100, closed: false
        )
        let first = await store.ingestKline(forming, sequence: 10, closedSequence: nil)
        XCTAssertNotNil(first)

        let stale = RealtimeKlineEventPayload(
            symbol: "BTCUSDT", contractType: "PERPETUAL", interval: "1h",
            eventTime: 1_999, openTime: 0, closeTime: 3_599_999,
            openPrice: 100, highPrice: 105, lowPrice: 99, closePrice: 103,
            volume: 1, quoteVolume: 100, closed: false
        )
        let staleUpdate = await store.ingestKline(stale, sequence: 11, closedSequence: nil)
        XCTAssertNil(staleUpdate)

        let ticker = MarketTickerPayload(
            symbol: "BTCUSDT", lastPrice: 104, quoteVolume24h: 1,
            priceChangePercent24h: 1, eventTime: 2_000
        )
        let firstTicker = await store.ingestTicker(ticker)
        XCTAssertNotNil(firstTicker)
        let staleTicker = await store.ingestTicker(ticker)
        XCTAssertNil(staleTicker)
    }

    func testIngressAllowsSkippedFormingSequenceButChecksClosedSequence() {
        let stream = ChartStreamKey(symbol: "BTCUSDT", interval: "1h")
        let epoch = KlineStreamEpoch(generation: 1)
        var state = KlineIngressState()
        state.beginEpoch(epoch, stream: stream)
        state.completeRecovery(newestOpenTime: nil)

        XCTAssertEqual(state.accept(event(epoch: epoch, stream: stream, sequence: 10,
            closedSequence: nil, openTime: 0, closed: false)), .accepted)
        XCTAssertEqual(state.accept(event(epoch: epoch, stream: stream, sequence: 11,
            closedSequence: nil, openTime: 0, closed: false)), .coalesced)
        XCTAssertEqual(state.accept(event(epoch: epoch, stream: stream, sequence: 15,
            closedSequence: 1, openTime: 0, closed: true)), .accepted)
        XCTAssertNil(state.recoveryRequest)

        XCTAssertEqual(state.accept(event(epoch: epoch, stream: stream, sequence: 21,
            closedSequence: 3, openTime: 3_600_000, closed: true)),
            .recoveryRequired(.sequenceGap(expected: 2, received: 3)))
    }

    private func event(
        epoch: KlineStreamEpoch,
        stream: ChartStreamKey,
        sequence: Int64,
        closedSequence: Int64?,
        openTime: Int64,
        closed: Bool
    ) -> KlineIngressEvent {
        KlineIngressEvent(
            epoch: epoch,
            stream: stream,
            sequence: sequence,
            eventTime: openTime + 1,
            candle: ChartCandle(
                openTime: openTime,
                closeTime: openTime + 3_599_999,
                openPrice: 100,
                highPrice: 105,
                lowPrice: 99,
                closePrice: 104,
                volume: 1,
                quoteVolume: 100,
                closure: closed ? .closed : .provisional
            ),
            closedSequence: closedSequence
        )
    }
}
