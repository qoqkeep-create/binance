import Foundation

struct ChartDataFrame: Sendable {
    let stream: ChartStreamKey
    let epoch: KlineStreamEpoch
    let candles: ChartCandleSnapshot
    let indicators: ChartIndicatorSnapshot
    let recoveryRequest: KlineRecoveryRequest?
    let readyTime: TimeInterval
}

struct ChartDataPipelineIngressResult: Sendable {
    let disposition: KlineIngressDisposition
    let recoveryRequest: KlineRecoveryRequest?
    let shouldDrain: Bool
}

struct ChartDataPipelineDrainResult: Sendable {
    let frame: ChartDataFrame?
    let recoveryRequest: KlineRecoveryRequest?
}

struct ChartDataPipelineHealth: Sendable {
    let stream: ChartStreamKey
    let epoch: KlineStreamEpoch
    let historyCount: Int
    let hasLiveTail: Bool
    let lastReceivedSequence: Int64?
    let lastAppliedRevision: UInt64
    let pendingLiveCount: Int
    let pendingBarrierCount: Int
    let recoveryRequest: KlineRecoveryRequest?
    let indicatorSelection: ChartIndicatorSelection
    let indicatorParameters: ChartIndicatorParameters
    let indicatorConfigurationRevision: UInt64
}

actor ChartDataPipeline {
    private struct RolloverIndicatorCache {
        let candles: ChartCandleHistory
        let committed: ChartIndicatorHistorySnapshot
        let engine: ChartIndicatorEngine
    }

    private let stream: ChartStreamKey
    private let intervalMilliseconds: Int64
    private let historyLimit: Int
    private var store: CandleStorage
    private var indicatorHistoryDirty = false
    private var rolloverIndicatorCache: RolloverIndicatorCache?

    private var epoch: KlineStreamEpoch
    private var ingress: KlineIngressState
    private var indicatorEngine: ChartIndicatorEngine
    private var indicatorSelection: ChartIndicatorSelection
    private var indicatorParameters: ChartIndicatorParameters
    private var indicatorConfigurationRevision: UInt64 = 0
    private var lastMergedPriceEventTime: Int64?
    private var awaitingEpochSnapshot = true

    init?(
        stream: ChartStreamKey,
        intervalMilliseconds: Int64,
        epoch: KlineStreamEpoch,
        indicatorSelection: ChartIndicatorSelection = .standard,
        indicatorParameters: ChartIndicatorParameters = .standard,
        historyLimit: Int = 10_000,
        barrierCapacity: Int = 8
    ) {
        guard intervalMilliseconds > 0,
              historyLimit > 0,
              let registry = ChartIndicatorRegistry.standard,
              let configurations = ChartIndicatorEngine
                .productionConfigurations(
                    selection: indicatorSelection,
                    parameters: indicatorParameters
                ),
              let indicatorEngine = ChartIndicatorEngine(
                registry: registry,
                configurations: configurations,
                intervalMilliseconds: intervalMilliseconds,
                historyLimit: historyLimit
              ) else {
            return nil
        }

        self.stream = stream
        self.intervalMilliseconds = intervalMilliseconds
        self.historyLimit = historyLimit
        self.epoch = epoch
        self.indicatorEngine = indicatorEngine
        self.indicatorSelection = indicatorSelection
        self.indicatorParameters = indicatorParameters
        store = CandleStorage(historyLimit: historyLimit)

        var ingress = KlineIngressState(
            barrierCapacity: barrierCapacity
        )
        ingress.beginEpoch(epoch, stream: stream)
        self.ingress = ingress
    }

    func beginEpoch(
        _ newEpoch: KlineStreamEpoch
    ) -> KlineRecoveryRequest? {
        epoch = newEpoch
        awaitingEpochSnapshot = true
        lastMergedPriceEventTime = nil
        ingress.beginEpoch(newEpoch, stream: stream)
        return ingress.recoveryRequest
    }

    /// Re-enter a recently verified, unchanged candle bucket without rebuilding
    /// its closed history or indicators. The caller enforces TTL and session scope.
    func resumeCachedEpoch(
        _ newEpoch: KlineStreamEpoch,
        from previousEpoch: KlineStreamEpoch,
        bucketOpenTime: Int64
    ) -> ChartDataFrame? {
        guard !Task.isCancelled, epoch == previousEpoch,
              !awaitingEpochSnapshot, ingress.recoveryRequest == nil,
              ingress.pendingLiveUpsert == nil, ingress.pendingBarrierCount == 0 else { return nil }
        let snapshot = store.snapshot()
        guard !snapshot.history.candles.isEmpty,
              snapshot.liveTail.map({ $0.openTime == bucketOpenTime })
                ?? (snapshot.history.candles.last?.closeTime == bucketOpenTime - 1) else { return nil }
        epoch = newEpoch
        lastMergedPriceEventTime = nil
        ingress.beginEpoch(newEpoch, stream: stream)
        ingress.completeRecovery(newestOpenTime:
            snapshot.liveTail?.openTime ?? snapshot.history.candles.last?.openTime)
        return makeFrame(candles: snapshot)
    }

    func accept(
        payload: RealtimeKlineEventPayload,
        sequence: Int64,
        epoch eventEpoch: KlineStreamEpoch
    ) -> ChartDataPipelineIngressResult {
        guard payload.symbol.uppercased() == stream.symbol,
              payload.interval == stream.interval else {
            return ChartDataPipelineIngressResult(
                disposition: .ignoredWrongEpochOrStream,
                recoveryRequest: ingress.recoveryRequest,
                shouldDrain: false
            )
        }

        let event = KlineIngressEvent(
            epoch: eventEpoch,
            stream: stream,
            sequence: sequence,
            eventTime: payload.eventTime,
            candle: ChartCandle(
                marketCandle: payload.candle,
                closure: payload.closed
                    ? .closed
                    : .provisional
            )
        )
        let disposition = ingress.accept(event)
        let shouldDrain: Bool
        switch disposition {
        case .accepted, .coalesced, .recoveryRequired:
            shouldDrain = true
        case .ignoredDuplicateOrLate,
             .ignoredWrongEpochOrStream:
            shouldDrain = false
        }
        return ChartDataPipelineIngressResult(
            disposition: disposition,
            recoveryRequest: ingress.recoveryRequest,
            shouldDrain: shouldDrain
        )
    }

    func markUpstreamBufferDropped()
        -> KlineRecoveryRequest? {
        ingress.markUpstreamBufferDropped()
        return ingress.recoveryRequest
    }

    func installSnapshot(
        _ marketCandles: [MarketCandle],
        fetchedAtMilliseconds: Int64,
        epoch snapshotEpoch: KlineStreamEpoch,
        preservingNewerData: Bool = false,
        tailOnly: Bool = false,
        tailBaseRevision: UInt64? = nil
    ) async -> ChartDataPipelineDrainResult {
        guard !Task.isCancelled, snapshotEpoch == epoch,
              !tailOnly || (!awaitingEpochSnapshot && ingress.recoveryRequest == nil) else {
            return ChartDataPipelineDrainResult(
                frame: nil,
                recoveryRequest: ingress.recoveryRequest
            )
        }

        let normalized = normalizedSnapshot(marketCandles)
        guard !normalized.isEmpty else {
            return ChartDataPipelineDrainResult(
                frame: nil,
                recoveryRequest: ingress.recoveryRequest
            )
        }
        var closed = normalized
            .filter { $0.closeTime < fetchedAtMilliseconds }
            .map {
                ChartCandle(
                    marketCandle: $0,
                    closure: .closed
                )
            }
        let live = normalized
            .filter { $0.closeTime >= fetchedAtMilliseconds }
            .last
            .map {
                ChartCandle(
                    marketCandle: $0,
                    closure: .provisional
                )
            }

        let previousHistory = store.snapshot().history
        if tailOnly {
            // A small response cannot repair a gap or replace the full window.
            // Preserve cached statistics when the OHLC-only read omits them.
            let previous = Dictionary(uniqueKeysWithValues:
                previousHistory.candles.map { ($0.openTime, $0) })
            closed = closed.map { candle in
                guard candle.tradingData == nil, let saved = previous[candle.openTime]?.tradingData else { return candle }
                return candle.withTradingData(saved)
            }
            var expected = previousHistory.candles.last.map { $0.closeTime + 1 }
            for candle in closed where candle.openTime > (previousHistory.candles.last?.openTime ?? Int64.min) {
                guard candle.openTime == expected else {
                    ingress.requireDownstreamRecovery(openTime: candle.openTime)
                    return ChartDataPipelineDrainResult(frame: nil, recoveryRequest: ingress.recoveryRequest)
                }
                expected = candle.closeTime + 1
            }
            guard let live, live.openTime == expected else {
                ingress.requireDownstreamRecovery(openTime: expected ?? 0)
                return ChartDataPipelineDrainResult(frame: nil, recoveryRequest: ingress.recoveryRequest)
            }
            if store.snapshot().revision == tailBaseRevision {
                // No quote/OHLC arrived during this request: the REST tail is
                // newer than the displayed cache, including its close/range.
                _ = store.upsertProvisional(live)
            }
        }
        let installed = store.installSnapshot(
            closedCandles: closed,
            liveCandle: live,
            preservingNewerData: preservingNewerData
        )
        if previousHistory !== installed.history || indicatorHistoryDirty {
            rebuildIndicators(from: installed.history.candles)
        }
        ingress.completeRecovery(
            newestOpenTime:
                installed.liveTail?.openTime
                ?? installed.history.candles.last?.openTime
        )
        awaitingEpochSnapshot = false

        let drained = applyPendingMutations()
        if drained.frame != nil {
            return drained
        }
        return ChartDataPipelineDrainResult(
            frame: makeFrame(
                candles: installed
            ),
            recoveryRequest: ingress.recoveryRequest
        )
    }

    func drain() async -> ChartDataPipelineDrainResult {
        applyPendingMutations()
    }

    func mergeLatestPrice(
        _ price: Double,
        eventTimeMilliseconds: Int64,
        epoch priceEpoch: KlineStreamEpoch
    ) async -> ChartDataPipelineDrainResult {
        // Ticker updates must obey the same recovery barrier as OHLC events.
        // Otherwise they can publish a new epoch using the previous history.
        guard ingress.recoveryRequest == nil,
              priceEpoch == epoch,
              price.isFinite,
              price > 0,
              eventTimeMilliseconds >= 0,
              lastMergedPriceEventTime == nil
                || eventTimeMilliseconds
                    >= (lastMergedPriceEventTime ?? Int64.min) else {
            return ChartDataPipelineDrainResult(
                frame: nil,
                recoveryRequest: ingress.recoveryRequest
            )
        }

        // Binance weekly candles begin Monday 00:00 UTC, four days after the Unix epoch.
        let offset: Int64 = stream.interval == "1w" ? 345_600_000 : 0
        let shifted = eventTimeMilliseconds - offset
        let rawRemainder = shifted % intervalMilliseconds
        let remainder = rawRemainder < 0 ? rawRemainder + intervalMilliseconds : rawRemainder
        let bucketOpenTime = eventTimeMilliseconds - remainder
        let (bucketCloseTime, closeTimeOverflow) =
            bucketOpenTime.addingReportingOverflow(
                intervalMilliseconds - 1
            )
        guard !closeTimeOverflow else {
            return ChartDataPipelineDrainResult(
                frame: nil,
                recoveryRequest: ingress.recoveryRequest
            )
        }

        let current = store.snapshot()
        let base: ChartCandle?
        if let live = current.liveTail {
            guard bucketOpenTime >= live.openTime else {
                return ChartDataPipelineDrainResult(
                    frame: nil,
                    recoveryRequest: ingress.recoveryRequest
                )
            }
            base = live.openTime == bucketOpenTime
                ? live
                : nil
        } else {
            guard bucketOpenTime
                    > (current.history.candles.last?.openTime
                        ?? Int64.min) else {
                return ChartDataPipelineDrainResult(
                    frame: nil,
                    recoveryRequest: ingress.recoveryRequest
                )
            }
            base = nil
        }

        let previous = current.liveTail ?? current.history.candles.last
        let adjacentClose = previous.flatMap { $0.closeTime == bucketOpenTime - 1 ? $0.closePrice : nil }
        let openingPrice = base?.openPrice ?? adjacentClose ?? price
        let candle = ChartCandle(
            openTime: bucketOpenTime,
            closeTime: base?.closeTime ?? bucketCloseTime,
            openPrice: openingPrice,
            highPrice: max(base?.highPrice ?? openingPrice, price),
            lowPrice: min(base?.lowPrice ?? openingPrice, price),
            closePrice: price,
            volume: base?.volume ?? 0,
            quoteVolume: base?.quoteVolume ?? 0,
            tradingData: base?.tradingData,
            closure: .provisional
        )
        guard candle.isValid else {
            return ChartDataPipelineDrainResult(
                frame: nil,
                recoveryRequest: ingress.recoveryRequest
            )
        }

        lastMergedPriceEventTime = eventTimeMilliseconds
        let updated = store.upsertProvisional(candle, quotedPrice: price)
        return ChartDataPipelineDrainResult(
            frame: makeFrame(candles: updated),
            recoveryRequest: ingress.recoveryRequest
        )
    }

    func prependHistory(
        _ marketCandles: [MarketCandle],
        epoch pageEpoch: KlineStreamEpoch
    ) async -> ChartDataPipelineDrainResult {
        guard !Task.isCancelled, pageEpoch == epoch, !awaitingEpochSnapshot else {
            return ChartDataPipelineDrainResult(
                frame: nil,
                recoveryRequest: ingress.recoveryRequest
            )
        }
        let current = store.snapshot()
        guard let oldestOpenTime = current.history.candles
            .first?.openTime else {
            return ChartDataPipelineDrainResult(
                frame: nil,
                recoveryRequest: ingress.recoveryRequest
            )
        }
        let older = normalizedSnapshot(marketCandles)
            .filter { $0.openTime < oldestOpenTime }
            .map {
                ChartCandle(
                    marketCandle: $0,
                    closure: .closed
                )
            }
        guard !older.isEmpty else {
            return ChartDataPipelineDrainResult(
                frame: nil,
                recoveryRequest: ingress.recoveryRequest
            )
        }
        let installed = store.prependClosedHistory(older)
        rebuildIndicators(from: installed.history.candles)
        return ChartDataPipelineDrainResult(
            frame: makeFrame(candles: installed),
            recoveryRequest: ingress.recoveryRequest
        )
    }

    func currentFrame() async -> ChartDataFrame {
        makeFrame(candles: store.snapshot())
    }

    func updateIndicatorConfiguration(
        selection: ChartIndicatorSelection,
        parameters: ChartIndicatorParameters,
        revision: UInt64
    ) async -> ChartDataPipelineDrainResult? {
        guard revision > indicatorConfigurationRevision,
              let registry = ChartIndicatorRegistry.standard,
              let configurations = ChartIndicatorEngine
                .productionConfigurations(
                    selection: selection,
                    parameters: parameters
                ),
              ChartIndicatorEngine(
                registry: registry,
                configurations: configurations,
                intervalMilliseconds: intervalMilliseconds,
                historyLimit: historyLimit
              ) != nil else {
            return nil
        }

        indicatorSelection = selection
        indicatorParameters = parameters
        indicatorConfigurationRevision = revision

        let candles = store.snapshot()
        if rebuildIndicators(from: candles.history.candles) {
            ingress.requireDownstreamRecovery(openTime:
                candles.history.candles.last?.openTime ?? candles.liveTail?.openTime ?? 0)
        }
        return ChartDataPipelineDrainResult(
            frame: awaitingEpochSnapshot ? nil : makeFrame(candles: candles),
            recoveryRequest: ingress.recoveryRequest
        )
    }

    func health() async -> ChartDataPipelineHealth {
        let candles = store.snapshot()
        return ChartDataPipelineHealth(
            stream: stream,
            epoch: epoch,
            historyCount: candles.history.candles.count,
            hasLiveTail: candles.liveTail != nil,
            lastReceivedSequence:
                ingress.lastReceivedSequence,
            lastAppliedRevision:
                ingress.lastAppliedRevision,
            pendingLiveCount:
                ingress.pendingLiveUpsert == nil ? 0 : 1,
            pendingBarrierCount:
                ingress.pendingBarrierCount,
            recoveryRequest:
                ingress.recoveryRequest,
            indicatorSelection: indicatorSelection,
            indicatorParameters: indicatorParameters,
            indicatorConfigurationRevision:
                indicatorConfigurationRevision
        )
    }

    private func applyPendingMutations() -> ChartDataPipelineDrainResult {
        guard !awaitingEpochSnapshot else {
            return ChartDataPipelineDrainResult(frame: nil, recoveryRequest: ingress.recoveryRequest)
        }
        let drain = ingress.drain()
        guard !drain.mutations.isEmpty else {
            return ChartDataPipelineDrainResult(
                frame: nil,
                recoveryRequest: drain.recoveryRequest
            )
        }

        var candleSnapshot = store.snapshot()
        for mutation in drain.mutations {
            let candle = mutation.candle
            if candle.closure == .closed,
               let lastOpenTime =
                    indicatorEngine.lastCommittedOpenTime,
               candle.openTime <= lastOpenTime {
                let existing = candleSnapshot.history.candles
                    .first {
                        $0.openTime == candle.openTime
                    }
                if existing == candle {
                    ingress.confirmApplied(
                        revision: mutation.revision
                    )
                    continue
                }
                candleSnapshot = store.apply(mutation)
                indicatorHistoryDirty = true
                ingress.requireDownstreamRecovery(
                    openTime: candle.openTime
                )
                ingress.confirmApplied(
                    revision: mutation.revision
                )
                continue
            }

            candleSnapshot = store.apply(mutation)
            if candle.closure == .closed {
                // Only a contiguous, trusted prefix can advance committed state.
                // A close for a later bar can arrive before an earlier trusted close.
                let hasUnverifiedPredecessor = candleSnapshot.history.candles.contains {
                    $0.openTime < candle.openTime && $0.closure == .unverifiedClosed
                }
                if !indicatorHistoryDirty && !hasUnverifiedPredecessor {
                    appendCommittedIndicators(candle)
                } else {
                    indicatorHistoryDirty = true
                    ingress.requireDownstreamRecovery(openTime: candle.openTime)
                }
            }
            ingress.confirmApplied(
                revision: mutation.revision
            )
        }

        return ChartDataPipelineDrainResult(
            frame: makeFrame(candles: candleSnapshot),
            recoveryRequest: ingress.recoveryRequest
        )
    }

    @discardableResult
    private func rebuildIndicators(
        from candles: [ChartCandle]
    ) -> Bool {
        guard let registry = ChartIndicatorRegistry.standard,
              let configurations = ChartIndicatorEngine
                .productionConfigurations(
                    selection: indicatorSelection,
                    parameters: indicatorParameters
                ),
              var nextEngine = ChartIndicatorEngine(
                registry: registry,
                configurations: configurations,
                intervalMilliseconds: intervalMilliseconds,
                historyLimit: historyLimit
              ) else {
            return false
        }
        let health = nextEngine.installHistory(Array(candles.prefix { $0.closure == .closed }))
        indicatorEngine = nextEngine
        indicatorHistoryDirty = false
        return health.requiresRecovery
    }

    private func appendCommittedIndicators(
        _ candle: ChartCandle
    ) {
        let health = indicatorEngine.commit(candle)
        if health.requiresRecovery {
            ingress.requireDownstreamRecovery(
                openTime: candle.openTime
            )
        }
    }

    private func makeFrame(
        candles: ChartCandleSnapshot
    ) -> ChartDataFrame {
        let live = candles.liveTail
        return ChartDataFrame(
            stream: stream,
            epoch: epoch,
            candles: candles,
            indicators: displayedIndicators(candles: candles, live: live),
            recoveryRequest:
                ingress.recoveryRequest,
            readyTime:
                ProcessInfo.processInfo.systemUptime
        )
    }

    private func displayedIndicators(candles: ChartCandleSnapshot, live: ChartCandle?) -> ChartIndicatorSnapshot {
        guard !indicatorEngine.history.series.isEmpty,
              let latest = candles.history.candles.last,
              latest.openTime > (indicatorEngine.lastCommittedOpenTime ?? Int64.min) else {
            rolloverIndicatorCache = nil
            return indicatorEngine.snapshot(provisional: live)
        }
        if let cached = rolloverIndicatorCache,
           cached.candles === candles.history, cached.committed === indicatorEngine.history {
            return cached.engine.snapshot(provisional: live)
        }
        // Replay pending rollover bars into a value copy for drawing only. Their
        // real closure remains unverified and the committed calculators stay put.
        // Cache this projection so ordinary ticks do not rebuild indicator history.
        var displayEngine = indicatorEngine
        let committedOpenTime = indicatorEngine.lastCommittedOpenTime ?? Int64.min
        for candle in candles.history.candles where candle.openTime > committedOpenTime {
            _ = displayEngine.commit(candle.withClosure(.closed))
        }
        rolloverIndicatorCache = RolloverIndicatorCache(candles: candles.history,
            committed: indicatorEngine.history, engine: displayEngine)
        return displayEngine.snapshot(provisional: live)
    }

    private func normalizedSnapshot(
        _ candles: [MarketCandle]
    ) -> [MarketCandle] {
        var byOpenTime: [Int64: MarketCandle] = [:]
        for marketCandle in candles {
            let chartCandle = ChartCandle(
                marketCandle: marketCandle,
                closure: .provisional
            )
            if chartCandle.isValid {
                byOpenTime[marketCandle.openTime] =
                    marketCandle
            }
        }
        return Array(
            byOpenTime.values
                .sorted { $0.openTime < $1.openTime }
                .suffix(historyLimit)
        )
    }
}
