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
    private let stream: ChartStreamKey
    private let intervalMilliseconds: Int64
    private let historyLimit: Int
    private let store: CandleStore

    private var epoch: KlineStreamEpoch
    private var ingress: KlineIngressState
    private var indicatorEngine: ChartIndicatorEngine
    private var indicatorSelection: ChartIndicatorSelection
    private var indicatorParameters: ChartIndicatorParameters
    private var indicatorConfigurationRevision: UInt64 = 0
    private var lastMergedPriceEventTime: Int64?

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
        store = CandleStore(historyLimit: historyLimit)

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
        lastMergedPriceEventTime = nil
        ingress.beginEpoch(newEpoch, stream: stream)
        return ingress.recoveryRequest
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
        preservingNewerData: Bool = false
    ) async -> ChartDataPipelineDrainResult {
        guard snapshotEpoch == epoch else {
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
        let closed = normalized
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

        let installed = await store.installSnapshot(
            closedCandles: closed,
            liveCandle: live,
            preservingNewerData: preservingNewerData
        )
        rebuildIndicators(
            from: installed.history.candles
        )
        ingress.completeRecovery(
            newestOpenTime:
                live?.openTime
                ?? installed.history.candles.last?.openTime
        )

        let drained = await applyPendingMutations()
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
        await applyPendingMutations()
    }

    func mergeLatestPrice(
        _ price: Double,
        eventTimeMilliseconds: Int64,
        epoch priceEpoch: KlineStreamEpoch
    ) async -> ChartDataPipelineDrainResult {
        guard priceEpoch == epoch,
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

        let bucketOpenTime = eventTimeMilliseconds
            - eventTimeMilliseconds % intervalMilliseconds
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

        let current = await store.snapshot()
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

        let candle = ChartCandle(
            openTime: bucketOpenTime,
            closeTime: base?.closeTime ?? bucketCloseTime,
            openPrice: base?.openPrice ?? price,
            highPrice: max(base?.highPrice ?? price, price),
            lowPrice: min(base?.lowPrice ?? price, price),
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
        let updated = await store.upsertProvisional(candle)
        return ChartDataPipelineDrainResult(
            frame: makeFrame(candles: updated),
            recoveryRequest: ingress.recoveryRequest
        )
    }

    func prependHistory(
        _ marketCandles: [MarketCandle],
        epoch pageEpoch: KlineStreamEpoch
    ) async -> ChartDataPipelineDrainResult {
        guard pageEpoch == epoch else {
            return ChartDataPipelineDrainResult(
                frame: nil,
                recoveryRequest: ingress.recoveryRequest
            )
        }
        let current = await store.snapshot()
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
        let installed = await store.prependClosedHistory(older)
        rebuildIndicators(from: installed.history.candles)
        return ChartDataPipelineDrainResult(
            frame: makeFrame(candles: installed),
            recoveryRequest: ingress.recoveryRequest
        )
    }

    func currentFrame() async -> ChartDataFrame {
        makeFrame(candles: await store.snapshot())
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

        while true {
            let candles = await store.snapshot()
            guard revision == indicatorConfigurationRevision else {
                return nil
            }
            guard var nextEngine = ChartIndicatorEngine(
                registry: registry,
                configurations: configurations,
                intervalMilliseconds: intervalMilliseconds,
                historyLimit: historyLimit
            ) else {
                return nil
            }
            let indicatorHealth = nextEngine.installHistory(
                candles.history.candles
            )
            let currentCandles = await store.snapshot()
            guard revision == indicatorConfigurationRevision else {
                return nil
            }
            guard currentCandles.revision == candles.revision else {
                continue
            }

            indicatorEngine = nextEngine
            if indicatorHealth.requiresRecovery {
                ingress.requireDownstreamRecovery(
                    openTime:
                        currentCandles.history.candles.last?.openTime
                        ?? currentCandles.liveTail?.openTime
                        ?? 0
                )
            }
            return ChartDataPipelineDrainResult(
                frame: makeFrame(candles: currentCandles),
                recoveryRequest: ingress.recoveryRequest
            )
        }
    }

    func health() async -> ChartDataPipelineHealth {
        let candles = await store.snapshot()
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

    private func applyPendingMutations()
        async -> ChartDataPipelineDrainResult {
        let drain = ingress.drain()
        guard !drain.mutations.isEmpty else {
            return ChartDataPipelineDrainResult(
                frame: nil,
                recoveryRequest: drain.recoveryRequest
            )
        }

        var candleSnapshot = await store.snapshot()
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
                candleSnapshot = await store.apply(mutation)
                ingress.requireDownstreamRecovery(
                    openTime: candle.openTime
                )
                ingress.confirmApplied(
                    revision: mutation.revision
                )
                continue
            }

            candleSnapshot = await store.apply(mutation)
            if candle.closure == .closed {
                appendCommittedIndicators(candle)
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

    private func rebuildIndicators(
        from candles: [ChartCandle]
    ) {
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
            return
        }
        _ = nextEngine.installHistory(candles)
        indicatorEngine = nextEngine
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
            indicators: indicatorEngine.snapshot(
                provisional: live
            ),
            recoveryRequest:
                ingress.recoveryRequest,
            readyTime:
                ProcessInfo.processInfo.systemUptime
        )
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
