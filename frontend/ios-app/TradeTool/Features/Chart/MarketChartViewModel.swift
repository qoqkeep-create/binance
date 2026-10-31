import Foundation

enum MarketPriceMovement {
    case unchanged
    case rising
    case falling
}

enum MarketChartRealtimeFeedPolicy {
    static func subscriptionIntervals(
        for selectedInterval: MarketKlineInterval
    ) -> [String] {
        guard selectedInterval != .oneMinute else {
            return [MarketKlineInterval.oneMinute.rawValue]
        }
        return [
            selectedInterval.rawValue,
            MarketKlineInterval.oneMinute.rawValue,
        ]
    }

    static func suppliesLivePrice(
        sourceInterval: String,
        selectedInterval: MarketKlineInterval
    ) -> Bool {
        selectedInterval != .oneMinute
            && sourceInterval
                == MarketKlineInterval.oneMinute.rawValue
    }
}

private struct MarketChartPriceUpdate {
    let price: Double
    let eventTime: Int64
}

@MainActor
final class MarketChartViewModel: ObservableObject {
    @Published private(set) var candles: [MarketCandle] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingOlderHistory = false
    @Published private(set) var hasMoreHistory = true
    @Published private(set) var lastError: String?
    @Published private(set) var ticker: MarketTickerPayload?
    @Published private(set) var realtimePrice: Double?
    @Published private(set) var chartDataFrame: ChartDataFrame?
    @Published private(set) var chartIndicatorSelection: ChartIndicatorSelection
    @Published private(set) var chartIndicatorParameters: ChartIndicatorParameters
    @Published var interval: MarketKlineInterval = .oneHour

    private(set) var latestPriceMovement = MarketPriceMovement.unchanged

    let market: MarketSnapshot

    private let apiClient: any APIClient
    private let realtimeClient: RealtimeClient
    private let chartIndicatorSelectionStore: ChartIndicatorSelectionStore
    private let chartIndicatorParametersStore: ChartIndicatorParametersStore
    private var realtimeTask: Task<Void, Never>?
    private var intervalTask: Task<Void, Never>?
    private var historyRefreshTask: Task<Void, Never>?
    private var historyPageTask: Task<Void, Never>?
    private var chartRecoveryTask: Task<Void, Never>?
    private var chartIndicatorUpdateTask: Task<Void, Never>?
    private var pendingChartPriceUpdate: MarketChartPriceUpdate?
    private var previousRealtimePrice: Double?
    private var latestPriceEventTime: Int64?
    private var chartPipeline: ChartDataPipeline?
    private var chartPipelineEpoch: KlineStreamEpoch?
    private var chartPipelineSessionID = UUID()
    private var chartPipelineGeneration: UInt64 = 0
    private var chartRecoveryCheckRequested = false
    private var chartIndicatorConfigurationRevision: UInt64 = 0

    init(
        market: MarketSnapshot,
        apiClient: any APIClient,
        realtimeClient: RealtimeClient,
        initialInterval: MarketKlineInterval = .oneHour,
        chartIndicatorSelectionStore: ChartIndicatorSelectionStore = .init(),
        chartIndicatorParametersStore: ChartIndicatorParametersStore = .init()
    ) {
        self.market = market
        self.apiClient = apiClient
        self.realtimeClient = realtimeClient
        _interval = Published(initialValue: initialInterval)
        self.chartIndicatorSelectionStore = chartIndicatorSelectionStore
        self.chartIndicatorParametersStore = chartIndicatorParametersStore
        chartIndicatorSelection = chartIndicatorSelectionStore.load()
        chartIndicatorParameters = chartIndicatorParametersStore.load()
    }

    func start() {
        guard realtimeTask == nil else {
            return
        }

        configureChartPipeline(for: interval)
        let events = realtimeClient.events(
            bufferingPolicy: .bufferingNewest(64)
        ) { [weak self] in
            self?.handleRealtimeBufferDrop()
        }
        realtimeTask = Task { [weak self] in
            for await message in events {
                guard !Task.isCancelled else {
                    return
                }
                await self?.handle(message)
            }
        }

        subscribe()
        reload()
        historyRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled,
                      let self else {
                    return
                }
                self.reload()
            }
        }
    }

    func stop() {
        realtimeTask?.cancel()
        realtimeTask = nil
        intervalTask?.cancel()
        intervalTask = nil
        historyRefreshTask?.cancel()
        historyRefreshTask = nil
        historyPageTask?.cancel()
        historyPageTask = nil
        isLoadingOlderHistory = false
        chartRecoveryTask?.cancel()
        chartRecoveryTask = nil
        chartRecoveryCheckRequested = false
        chartIndicatorUpdateTask?.cancel()
        chartIndicatorUpdateTask = nil
        pendingChartPriceUpdate = nil
        chartPipelineSessionID = UUID()
        chartPipeline = nil
        chartPipelineEpoch = nil
        previousRealtimePrice = nil
        latestPriceEventTime = nil
        latestPriceMovement = .unchanged
        realtimeClient.unsubscribe(
            channels: ["market.kline", "market.ticker"]
        )
    }

    func selectInterval(_ interval: MarketKlineInterval) {
        guard self.interval != interval else {
            return
        }
        self.interval = interval
        configureChartPipeline(for: interval)
        subscribe()
        reload()
    }

    func isChartIndicatorActive(_ displayName: String) -> Bool {
        guard let indicator = ChartBuiltInIndicator(
            rawValue: displayName
        ) else {
            return false
        }
        return chartIndicatorSelection.contains(indicator)
    }

    var chartIndicatorPanelCount: Int {
        guard let chartDataFrame else {
            return chartIndicatorSelection
                .activePanelIndicatorsInOrder.count
        }
        return ChartPanelLayout.indicatorPanelIDs(
            series: chartDataFrame.indicators.history.series
        ).count
    }

    func toggleChartIndicator(_ displayName: String) {
        guard let indicator = ChartBuiltInIndicator(
            rawValue: displayName
        ) else {
            return
        }
        let next = chartIndicatorSelection.toggling(indicator)
        guard next != chartIndicatorSelection else {
            return
        }
        let tradingDataChanged = next.requestedTradingDataSeries
            != chartIndicatorSelection.requestedTradingDataSeries
        chartIndicatorSelection = next
        chartIndicatorSelectionStore.save(next)
        applyChartIndicatorConfiguration()
        if tradingDataChanged {
            reload()
        }
    }

    func updateChartIndicatorParameters(
        _ parameters: ChartIndicatorParameters
    ) {
        guard parameters != chartIndicatorParameters else {
            return
        }
        chartIndicatorParameters = parameters
        chartIndicatorParametersStore.save(parameters)
        applyChartIndicatorConfiguration()
    }

    func reload() {
        if chartPipeline == nil {
            configureChartPipeline(for: interval)
        }
        intervalTask?.cancel()
        let requestedInterval = interval
        let pipeline = chartPipeline
        let epoch = chartPipelineEpoch
        let sessionID = chartPipelineSessionID
        intervalTask = Task { [weak self] in
            await self?.loadHistory(
                interval: requestedInterval,
                pipeline: pipeline,
                epoch: epoch,
                sessionID: sessionID
            )
        }
    }

    func requestOlderHistory() {
        guard !isLoadingOlderHistory,
              hasMoreHistory,
              let pipeline = chartPipeline,
              let epoch = chartPipelineEpoch,
              let beforeOpenTime = chartDataFrame?
                .candles.history.candles.first?.openTime else {
            return
        }
        let requestedInterval = interval
        let sessionID = chartPipelineSessionID
        let pageLimit = 1_500
        isLoadingOlderHistory = true
        historyPageTask?.cancel()
        historyPageTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.chartPipelineSessionID == sessionID {
                    self.isLoadingOlderHistory = false
                    self.historyPageTask = nil
                }
            }
            do {
                let response = try await self.fetchHistory(
                    interval: requestedInterval,
                    beforeOpenTime: beforeOpenTime,
                    limit: pageLimit
                )
                guard !Task.isCancelled,
                      self.interval == requestedInterval,
                      self.chartPipelineSessionID == sessionID,
                      self.chartPipelineEpoch == epoch else {
                    return
                }
                let older = response.items.filter {
                    $0.openTime < beforeOpenTime
                }
                self.hasMoreHistory = older.count == pageLimit
                guard !older.isEmpty else {
                    return
                }
                let result = await pipeline.prependHistory(
                    older,
                    epoch: epoch
                )
                guard !Task.isCancelled,
                      self.chartPipelineSessionID == sessionID,
                      self.chartPipelineEpoch == epoch else {
                    return
                }
                if let frame = result.frame {
                    self.chartDataFrame = frame
                } else {
                    self.hasMoreHistory = false
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
            }
        }
    }

    var currentPrice: Double {
        realtimePrice
            ?? ticker?.lastPrice
            ?? candles.last?.closePrice
            ?? market.price
    }

    var changePercent24h: Double {
        ticker?.priceChangePercent24h
            ?? market.changePercent24h
    }

    var formattedChange24h: String {
        String(format: "%+.2f%%", changePercent24h)
    }

    var referencePrice: Double {
        let denominator = 1 + changePercent24h / 100
        return denominator == 0 ? market.price : market.price / denominator
    }

    private func subscribe() {
        realtimeClient.subscribe([
            .marketKline(
                symbols: [market.symbol],
                intervals: MarketChartRealtimeFeedPolicy
                    .subscriptionIntervals(for: interval)
            ),
            .marketTicker(symbols: [market.symbol]),
        ])
    }

    private func loadHistory(
        interval requestedInterval: MarketKlineInterval,
        pipeline: ChartDataPipeline?,
        epoch: KlineStreamEpoch?,
        sessionID: UUID
    ) async {
        isLoading = candles.isEmpty
        lastError = nil
        defer {
            isLoading = false
        }

        do {
            let response = try await fetchHistory(
                interval: requestedInterval,
                beforeOpenTime: nil,
                limit: 1_500
            )
            guard interval == requestedInterval else {
                return
            }
            guard !response.items.isEmpty else {
                throw APIError.invalidResponse
            }
            let sorted = response.items.sorted {
                $0.openTime < $1.openTime
            }
            hasMoreHistory = sorted.count == 1_500
            candles = Array(sorted.suffix(500))
            guard let pipeline, let epoch,
                  chartPipelineSessionID == sessionID else {
                return
            }
            let loadedAt = currentTimeMilliseconds()
            let result = await pipeline.installSnapshot(
                sorted,
                fetchedAtMilliseconds: loadedAt,
                epoch: epoch
            )
            guard chartPipelineSessionID == sessionID,
                  chartPipelineEpoch == epoch else {
                return
            }
            if let frame = await initialFrame(
                result.frame,
                interval: requestedInterval,
                loadedAt: loadedAt,
                pipeline: pipeline,
                epoch: epoch,
                sessionID: sessionID
            ) {
                chartDataFrame = frame
                upsertLiveTail(from: frame)
            }
            if let pending = pendingChartPriceUpdate {
                pendingChartPriceUpdate = nil
                await applyChartPriceUpdate(
                    price: pending.price,
                    eventTime: pending.eventTime
                )
            }
            scheduleChartRecoveryIfNeeded(
                result.recoveryRequest,
                pipeline: pipeline,
                epoch: epoch,
                sessionID: sessionID
            )
        } catch {
            guard !Task.isCancelled else {
                return
            }
            lastError = "K线加载失败"
        }
    }

    private func fetchHistory(
        interval requestedInterval: MarketKlineInterval,
        beforeOpenTime: Int64?,
        limit: Int
    ) async throws -> MarketKlineHistoryResponse {
        var queryItems = [
            URLQueryItem(
                name: "symbol",
                value: market.symbol
            ),
            URLQueryItem(
                name: "interval",
                value: requestedInterval.rawValue
            ),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let beforeOpenTime {
            queryItems.append(URLQueryItem(
                name: "beforeOpenTime",
                value: String(beforeOpenTime)
            ))
        } else {
            let tradingData = chartIndicatorSelection
                .requestedTradingDataSeries
                .map(\.rawValue)
                .joined(separator: ",")
            if !tradingData.isEmpty {
                queryItems.append(URLQueryItem(
                    name: "tradingData",
                    value: tradingData
                ))
            }
        }
        let response = try await apiClient.send(
            APIRequest<MarketKlineHistoryResponse>(
                path: "/api/market/klines",
                queryItems: queryItems,
                showsErrorToast: false
            )
        )
        guard response.symbol.uppercased()
                == market.symbol.uppercased(),
              response.interval
                == requestedInterval.rawValue else {
            throw APIError.invalidResponse
        }
        return response
    }

    private func handle(
        _ message: RealtimeServerMessage
    ) async {
        if message.type == "ready" {
            await beginRealtimeEpoch()
            return
        }
        guard message.type == "event" else {
            return
        }

        switch message.channel {
        case "market.kline":
            guard let payload = message.decodeData(
                as: RealtimeKlineEventPayload.self
            ),
            payload.symbol == market.symbol else {
                return
            }
            let isSelectedInterval =
                payload.interval == interval.rawValue
            let suppliesLivePrice = MarketChartRealtimeFeedPolicy
                .suppliesLivePrice(
                    sourceInterval: payload.interval,
                    selectedInterval: interval
                )
            guard isSelectedInterval || suppliesLivePrice else {
                return
            }
            if payload.interval
                == MarketKlineInterval.oneMinute.rawValue {
                await updateRealtimePrice(
                    payload.closePrice,
                    eventTime: payload.eventTime
                )
            }
            guard isSelectedInterval else {
                return
            }
            upsert(payload.candle)
            await handleChartKline(
                message: message,
                payload: payload
            )

        case "market.ticker":
            guard let payload = message.decodeData(
                as: MarketTickerPayload.self
            ),
            payload.symbol == market.symbol else {
                return
            }
            await updateTicker(payload)

        default:
            return
        }
    }

    private func configureChartPipeline(
        for interval: MarketKlineInterval
    ) {
        chartIndicatorUpdateTask?.cancel()
        chartIndicatorUpdateTask = nil
        pendingChartPriceUpdate = nil
        chartRecoveryTask?.cancel()
        chartRecoveryTask = nil
        chartRecoveryCheckRequested = false
        chartPipelineSessionID = UUID()
        historyPageTask?.cancel()
        historyPageTask = nil
        isLoadingOlderHistory = false
        hasMoreHistory = true
        chartPipelineGeneration &+= 1
        let epoch = KlineStreamEpoch(
            generation: chartPipelineGeneration
        )
        let durationMilliseconds =
            interval.duration * 1_000
        guard durationMilliseconds.isFinite,
              durationMilliseconds > 0,
              durationMilliseconds
                <= Double(Int64.max),
              let pipeline = ChartDataPipeline(
                stream: ChartStreamKey(
                    symbol: market.symbol,
                    interval: interval.rawValue
                ),
                intervalMilliseconds:
                    Int64(durationMilliseconds),
                epoch: epoch,
                indicatorSelection: chartIndicatorSelection,
                indicatorParameters: chartIndicatorParameters
              ) else {
            chartPipeline = nil
            chartPipelineEpoch = nil
            chartDataFrame = nil
            return
        }
        chartPipeline = pipeline
        chartPipelineEpoch = epoch
        chartDataFrame = nil
    }

    private func applyChartIndicatorConfiguration() {
        guard let pipeline = chartPipeline,
              let epoch = chartPipelineEpoch else {
            return
        }
        chartIndicatorConfigurationRevision &+= 1
        let revision = chartIndicatorConfigurationRevision
        let selection = chartIndicatorSelection
        let parameters = chartIndicatorParameters
        let sessionID = chartPipelineSessionID
        chartIndicatorUpdateTask?.cancel()
        chartIndicatorUpdateTask = Task { [weak self] in
            let result = await pipeline.updateIndicatorConfiguration(
                selection: selection,
                parameters: parameters,
                revision: revision
            )
            guard let self,
                  !Task.isCancelled,
                  self.chartPipelineSessionID == sessionID,
                  self.chartPipelineEpoch == epoch,
                  self.chartIndicatorConfigurationRevision == revision,
                  self.chartIndicatorSelection == selection,
                  self.chartIndicatorParameters == parameters else {
                return
            }
            self.chartIndicatorUpdateTask = nil
            guard let result else {
                return
            }
            if let frame = result.frame {
                self.chartDataFrame = frame
            }
            self.scheduleChartRecoveryIfNeeded(
                result.recoveryRequest,
                pipeline: pipeline,
                epoch: epoch,
                sessionID: sessionID
            )
        }
    }

    private func beginRealtimeEpoch() async {
        guard let pipeline = chartPipeline else {
            return
        }
        chartRecoveryTask?.cancel()
        chartRecoveryTask = nil
        chartRecoveryCheckRequested = false
        chartPipelineGeneration &+= 1
        let epoch = KlineStreamEpoch(
            generation: chartPipelineGeneration
        )
        chartPipelineEpoch = epoch
        let sessionID = chartPipelineSessionID
        _ = await pipeline.beginEpoch(epoch)
        guard chartPipelineSessionID == sessionID,
              chartPipelineEpoch == epoch else {
            return
        }
        reload()
    }

    private func handleChartKline(
        message: RealtimeServerMessage,
        payload: RealtimeKlineEventPayload
    ) async {
        guard let pipeline = chartPipeline,
              let epoch = chartPipelineEpoch,
              let sequence = message.sequence else {
            handleRealtimeBufferDrop()
            return
        }
        let expectedKey =
            "\(market.symbol.uppercased()):\(interval.rawValue)"
        guard message.key == nil
            || message.key == expectedKey else {
            handleRealtimeBufferDrop()
            return
        }
        let sessionID = chartPipelineSessionID
        let result = await pipeline.accept(
            payload: payload,
            sequence: sequence,
            epoch: epoch
        )
        guard chartPipelineSessionID == sessionID,
              chartPipelineEpoch == epoch else {
            return
        }
        scheduleChartRecoveryIfNeeded(
            result.recoveryRequest,
            pipeline: pipeline,
            epoch: epoch,
            sessionID: sessionID
        )
        if result.shouldDrain {
            let drained = await pipeline.drain()
            guard chartPipelineSessionID == sessionID,
                  chartPipelineEpoch == epoch else {
                return
            }
            if let frame = drained.frame {
                chartDataFrame = frame
            }
            scheduleChartRecoveryIfNeeded(
                drained.recoveryRequest,
                pipeline: pipeline,
                epoch: epoch,
                sessionID: sessionID
            )
        }
    }

    private func handleRealtimeBufferDrop() {
        guard let pipeline = chartPipeline,
              let epoch = chartPipelineEpoch else {
            return
        }
        let sessionID = chartPipelineSessionID
        Task { [weak self] in
            let request =
                await pipeline.markUpstreamBufferDropped()
            guard let self,
                  self.chartPipelineSessionID == sessionID,
                  self.chartPipelineEpoch == epoch else {
                return
            }
            self.scheduleChartRecoveryIfNeeded(
                request,
                pipeline: pipeline,
                epoch: epoch,
                sessionID: sessionID
            )
        }
    }

    private func scheduleChartRecoveryIfNeeded(
        _ request: KlineRecoveryRequest?,
        pipeline: ChartDataPipeline,
        epoch: KlineStreamEpoch,
        sessionID: UUID
    ) {
        guard let request,
              request.epoch == epoch,
              request.stream.symbol
                == market.symbol.uppercased(),
              request.stream.interval
                == interval.rawValue else {
            return
        }
        guard chartRecoveryTask == nil else {
            chartRecoveryCheckRequested = true
            return
        }
        chartRecoveryCheckRequested = false
        let recoveryInterval = interval
        chartRecoveryTask = Task { [weak self] in
            await self?.recoverChartPipeline(
                interval: recoveryInterval,
                pipeline: pipeline,
                epoch: epoch,
                sessionID: sessionID
            )
        }
    }

    private func recoverChartPipeline(
        interval recoveryInterval: MarketKlineInterval,
        pipeline: ChartDataPipeline,
        epoch: KlineStreamEpoch,
        sessionID: UUID
    ) async {
        var attempt = 0
        defer {
            if chartPipelineSessionID == sessionID,
               chartPipelineEpoch == epoch {
                finishChartRecovery(
                    pipeline: pipeline,
                    epoch: epoch,
                    sessionID: sessionID
                )
            }
        }

        while !Task.isCancelled {
            guard chartPipelineSessionID == sessionID,
                  chartPipelineEpoch == epoch,
                  interval == recoveryInterval else {
                return
            }
            do {
                let response = try await fetchHistory(
                    interval: recoveryInterval,
                    beforeOpenTime: nil,
                    limit: 1_500
                )
                let sorted = response.items.sorted {
                    $0.openTime < $1.openTime
                }
                let result = await pipeline.installSnapshot(
                    sorted,
                    fetchedAtMilliseconds:
                        currentTimeMilliseconds(),
                    epoch: epoch
                )
                guard chartPipelineSessionID == sessionID,
                      chartPipelineEpoch == epoch else {
                    return
                }
                candles = Array(sorted.suffix(500))
                if let frame = result.frame {
                    chartDataFrame = frame
                }
                if result.recoveryRequest == nil {
                    return
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
            }

            attempt += 1
            let delaySeconds = min(
                pow(2.0, Double(attempt - 1)),
                30
            )
            try? await Task.sleep(
                for: .seconds(delaySeconds)
            )
        }
    }

    private func finishChartRecovery(
        pipeline: ChartDataPipeline,
        epoch: KlineStreamEpoch,
        sessionID: UUID
    ) {
        chartRecoveryTask = nil
        guard chartRecoveryCheckRequested else {
            return
        }
        chartRecoveryCheckRequested = false
        Task { [weak self] in
            let health = await pipeline.health()
            guard let self,
                  self.chartPipelineSessionID == sessionID,
                  self.chartPipelineEpoch == epoch else {
                return
            }
            self.scheduleChartRecoveryIfNeeded(
                health.recoveryRequest,
                pipeline: pipeline,
                epoch: epoch,
                sessionID: sessionID
            )
        }
    }

    private func currentTimeMilliseconds() -> Int64 {
        let milliseconds =
            Date().timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds > 0,
              milliseconds <= Double(Int64.max) else {
            return 0
        }
        return Int64(milliseconds)
    }

    private func updateTicker(_ payload: MarketTickerPayload) async {
        ticker = payload
        await updateRealtimePrice(
            payload.lastPrice,
            eventTime: payload.eventTime
        )
    }

    private func updateRealtimePrice(
        _ price: Double,
        eventTime: Int64
    ) async {
        guard price.isFinite,
              price > 0,
              eventTime >= 0,
              latestPriceEventTime == nil
                || eventTime >= (latestPriceEventTime ?? Int64.min) else {
            return
        }

        if let previousRealtimePrice {
            if price > previousRealtimePrice {
                latestPriceMovement = .rising
            } else if price < previousRealtimePrice {
                latestPriceMovement = .falling
            } else {
                latestPriceMovement = .unchanged
            }
        } else {
            latestPriceMovement = .unchanged
        }

        latestPriceEventTime = eventTime
        previousRealtimePrice = price
        realtimePrice = price
        await applyChartPriceUpdate(
            price: price,
            eventTime: eventTime
        )
    }

    private func applyChartPriceUpdate(
        price: Double,
        eventTime: Int64
    ) async {
        guard interval != .oneMinute else {
            return
        }
        guard chartDataFrame != nil,
              let pipeline = chartPipeline,
              let epoch = chartPipelineEpoch else {
            pendingChartPriceUpdate = MarketChartPriceUpdate(
                price: price,
                eventTime: eventTime
            )
            return
        }
        let sessionID = chartPipelineSessionID
        let result = await pipeline.mergeLatestPrice(
            price,
            eventTimeMilliseconds: eventTime,
            epoch: epoch
        )
        guard chartPipelineSessionID == sessionID,
              chartPipelineEpoch == epoch else {
            return
        }
        if let frame = result.frame {
            chartDataFrame = frame
            upsertLiveTail(from: frame)
        }
    }

    private func initialFrame(
        _ installedFrame: ChartDataFrame?,
        interval requestedInterval: MarketKlineInterval,
        loadedAt: Int64,
        pipeline: ChartDataPipeline,
        epoch: KlineStreamEpoch,
        sessionID: UUID
    ) async -> ChartDataFrame? {
        guard let installedFrame else {
            return nil
        }
        if requestedInterval == .oneMinute,
           installedFrame.candles.liveTail != nil {
            return installedFrame
        }

        let intervalMilliseconds = Int64(
            requestedInterval.duration * 1_000
        )
        let loadedBucket = loadedAt
            - loadedAt % intervalMilliseconds
        let pending = pendingChartPriceUpdate.flatMap { update in
            let updateBucket = update.eventTime
                - update.eventTime % intervalMilliseconds
            return updateBucket == loadedBucket ? update : nil
        }
        let price = pending?.price
            ?? realtimePrice
            ?? ticker?.lastPrice
            ?? market.price
        guard price.isFinite, price > 0 else {
            return installedFrame
        }
        let eventTime = pending?.eventTime
            ?? loadedAt
        if let buffered = pendingChartPriceUpdate,
           buffered.eventTime <= eventTime {
            pendingChartPriceUpdate = nil
        }
        let merged = await pipeline.mergeLatestPrice(
            price,
            eventTimeMilliseconds: eventTime,
            epoch: epoch
        )
        guard chartPipelineSessionID == sessionID,
              chartPipelineEpoch == epoch else {
            return nil
        }
        return merged.frame ?? installedFrame
    }

    private func upsertLiveTail(from frame: ChartDataFrame) {
        guard let live = frame.candles.liveTail else {
            return
        }
        upsert(MarketCandle(
            openTime: live.openTime,
            closeTime: live.closeTime,
            openPrice: live.openPrice,
            highPrice: live.highPrice,
            lowPrice: live.lowPrice,
            closePrice: live.closePrice,
            volume: live.volume,
            quoteVolume: live.quoteVolume,
            tradingData: live.tradingData
        ))
    }

    private func upsert(_ candle: MarketCandle) {
        if let index = candles.firstIndex(where: {
            $0.openTime == candle.openTime
        }) {
            candles[index] = candle
        } else {
            candles.append(candle)
            candles.sort { $0.openTime < $1.openTime }
            if candles.count > 500 {
                candles.removeFirst(candles.count - 500)
            }
        }
    }

}
