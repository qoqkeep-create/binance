import Foundation
import Combine
#if DEBUG
import os
#endif

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

enum MarketChartRecoveryState: Equatable {
    case idle, restoring, disconnected
    case failed(String)

    var message: String? {
        switch self {
        case .idle: nil
        // Recovery is represented by the chart loading animation. A second
        // status banner makes a normal background return look like a reload.
        case .restoring, .disconnected: nil
        case .failed(let message): message
        }
    }

    var failureMessage: String? {
        switch self {
        case .disconnected, .failed: message
        case .idle, .restoring: nil
        }
    }
}

@MainActor
final class MarketChartViewModel: ObservableObject {
    @Published private(set) var candles: [MarketCandle] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingOlderHistory = false
    @Published private(set) var hasMoreHistory = true
    @Published private(set) var lastError: String?
    @Published private(set) var recoveryState = MarketChartRecoveryState.idle
    @Published private(set) var ticker: MarketTickerPayload?
    @Published private(set) var realtimePrice: Double?
    @Published private(set) var chartDataFrame: ChartDataFrame?
    @Published private(set) var preservesPresentedChart = false
    @Published private(set) var chartIndicatorSelection: ChartIndicatorSelection
    @Published private(set) var chartIndicatorParameters: ChartIndicatorParameters
    @Published var interval: MarketKlineInterval = .oneHour

    private(set) var latestPriceMovement = MarketPriceMovement.unchanged

    let market: MarketSnapshot
    private(set) var loadDiagnostics: ChartLoadDiagnostics?
    private var diagnosticEpoch: KlineStreamEpoch?
    private let diagnosticUpload: ((Data) -> Void)?
    private var diagnosticTimeout: Task<Void, Never>?

    var frameLoadDiagnostics: ChartLoadDiagnostics? {
        guard let epoch = chartDataFrame?.epoch, epoch == diagnosticEpoch else { return nil }
        return loadDiagnostics
    }

    private let apiClient: any APIClient
    private let realtimeClient: RealtimeClient
    private let chartIndicatorSelectionStore: ChartIndicatorSelectionStore
    private let chartIndicatorParametersStore: ChartIndicatorParametersStore
    private var realtimeTask: Task<Void, Never>?
    private var intervalTask: Task<Void, Never>?
    private var historyRequestID = UUID()
    private var historyRefreshPending = false
    private var historyRefreshTask: Task<Void, Never>?
    private var historyPageTask: Task<Void, Never>?
    private var historyPageRequestID = UUID()
    private var historyPageRefreshPending = false
    private var historyPageAwaitingSnapshot = false
    private var pendingHistoryBoundary: Int64?
    private var historyNoticeTask: Task<Void, Never>?
    private var waitingForHistory = false
    private var chartIndicatorUpdateTask: Task<Void, Never>?
    private var pendingChartPriceUpdate: MarketChartPriceUpdate?
    private var previousRealtimePrice: Double?
    private var latestPriceEventTime: Int64?
    private var chartPipeline: ChartDataPipeline?
    private var chartPipelineEpoch: KlineStreamEpoch?
    private var chartPipelineSessionID = UUID()
    private var chartPipelineGeneration: UInt64 = 0
    private var chartRecoveryNeeded = false
    private var hasRealtimeConnection = false
    private var hasReceivedReadyHandshake = false
    private var isSuspendedForBackground = false
    private var connectionObservation: AnyCancellable?
    private var unavailableSince: Date?
    private var isRealtimeDisconnected = false
    private var staleChartTask: Task<Void, Never>?
    private var recoveryDeadlineTask: Task<Void, Never>?
    private var recoveryDeadlineID: UUID?
    private var awaitsRecoveryPresentation = false
    private var recoveryRequiresRetry = false
    private let recoveryWait: (Duration) async throws -> Void
    private static let staleChartInterval: TimeInterval = 30 * 60
    private var chartIndicatorConfigurationRevision: UInt64 = 0
    private struct CachedInterval {
        let pipeline: ChartDataPipeline
        let frame: ChartDataFrame
        let candles: [MarketCandle]
        let hasMoreHistory: Bool
        let verifiedAt: Date
        let bucketOpenTime: Int64
        let selection: ChartIndicatorSelection
        let parameters: ChartIndicatorParameters
        let tradingMode: String
        let useOrder: UInt64
    }
    private var intervalCache: [MarketKlineInterval: CachedInterval] = [:]
    private var cacheUseOrder: UInt64 = 0
    private let cacheTimeProvider: () -> Date
    private var snapshotVerifiedAt: Date?
    private var snapshotVerifiedBucket: Int64?
    private var cacheRestoreTask: Task<Void, Never>?
    private var isUsingVerifiedIntervalCache = false
    private var cachedTradingMode: String?
    private struct PendingHistorySignals {
        var acknowledgementTime: Int64?
        var noticeTime: Int64?
        var unknownAcknowledgement = false
        var unknownNotice = false
        var isEmpty: Bool {
            acknowledgementTime == nil && noticeTime == nil && !unknownAcknowledgement && !unknownNotice
        }
        mutating func record(timestamp: Int64, acknowledgement: Bool) {
            if acknowledgement {
                if timestamp > 0 { acknowledgementTime = max(acknowledgementTime ?? timestamp, timestamp) }
                else { unknownAcknowledgement = true }
            } else {
                if timestamp > 0 { noticeTime = max(noticeTime ?? timestamp, timestamp) }
                else { unknownNotice = true }
            }
        }
        mutating func removeCovered(by serverTime: Int64?) {
            guard let serverTime, serverTime > 0 else { return }
            if let time = acknowledgementTime, time < serverTime { acknowledgementTime = nil }
            if let time = noticeTime, time < serverTime { noticeTime = nil }
        }
    }
    private var pendingHistorySignals = PendingHistorySignals()
    private var firstFrameGateToken: UUID?
    private var firstFrameFallback: Task<Void, Never>?
    private var firstFrameGateWasReleased = false
    private var latestHistoryServerTime: Int64?
    private var activeHistoryLimit: Int?
    private var isInstallingTailSnapshot = false
#if DEBUG
    private static let performanceLog = Logger(subsystem: "BinanceTools", category: "MarketChart")
#endif

    init(
        market: MarketSnapshot,
        apiClient: any APIClient,
        realtimeClient: RealtimeClient,
        initialInterval: MarketKlineInterval = .oneHour,
        chartIndicatorSelectionStore: ChartIndicatorSelectionStore = .init(),
        chartIndicatorParametersStore: ChartIndicatorParametersStore = .init(),
        diagnosticUpload: ((Data) -> Void)? = nil,
        cacheTimeProvider: @escaping () -> Date = Date.init,
        recoveryWait: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.market = market
        self.apiClient = apiClient
        self.realtimeClient = realtimeClient
        self.diagnosticUpload = diagnosticUpload
        self.cacheTimeProvider = cacheTimeProvider
        self.recoveryWait = recoveryWait
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

        startLoadDiagnostics()
        hasRealtimeConnection = realtimeClient.state == .connected
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
                await self?.receive(message)
            }
        }

        connectionObservation = realtimeClient.$state.dropFirst().sink { [weak self] state in
            self?.realtimeConnectionChanged(state)
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
                guard !self.isSuspendedForBackground else { continue }
                self.refreshHistoryWhenIdle()
                if let before = self.pendingHistoryBoundary, !self.isLoadingOlderHistory {
                    self.loadOlderHistory(before: before)
                }
            }
        }
    }

    func stop() {
        cancelRecoveryDeadline()
        connectionObservation = nil
        staleChartTask?.cancel()
        staleChartTask = nil
        unavailableSince = nil
        isRealtimeDisconnected = false
        recoveryRequiresRetry = false
        recoveryState = .idle
        preservesPresentedChart = false
        invalidateIntervalCache()
        cacheRestoreTask?.cancel()
        cacheRestoreTask = nil
        resetHistoryPresentationGate()
        finishLoadDiagnostics(outcome: "cancelled")
        realtimeTask?.cancel()
        realtimeTask = nil
        intervalTask?.cancel()
        intervalTask = nil
        historyRequestID = UUID()
        historyRefreshPending = false
        historyRefreshTask?.cancel()
        historyRefreshTask = nil
        historyPageTask?.cancel()
        historyPageTask = nil
        historyPageRequestID = UUID()
        historyPageRefreshPending = false
        historyPageAwaitingSnapshot = false
        pendingHistoryBoundary = nil
        historyNoticeTask?.cancel()
        historyNoticeTask = nil
        waitingForHistory = false
        isLoading = false
        isLoadingOlderHistory = false
        chartRecoveryNeeded = false
        hasRealtimeConnection = false
        hasReceivedReadyHandshake = false
        isSuspendedForBackground = false
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
            channels: ["market.kline", "market.ticker", "market.history"]
        )
    }

    func suspendForBackground() {
        guard realtimeTask != nil, !isSuspendedForBackground else { return }
        isSuspendedForBackground = true
        finishLoadDiagnostics(outcome: "cancelled")
        if unavailableSince == nil { unavailableSince = cacheTimeProvider() }
        cancelRecoveryDeadline()
        staleChartTask?.cancel()
        staleChartTask = nil
        invalidateIntervalCache()
        cacheRestoreTask?.cancel()
        cacheRestoreTask = nil
        resetHistoryPresentationGate()
        intervalTask?.cancel()
        intervalTask = nil
        historyRequestID = UUID()
        historyRefreshPending = false
        historyNoticeTask?.cancel()
        historyNoticeTask = nil
        historyPageTask?.cancel()
        historyPageTask = nil
        historyPageRequestID = UUID()
        isLoadingOlderHistory = false
    }

    func resumeFromBackground() async {
        guard realtimeTask != nil, isSuspendedForBackground else { return }
        isSuspendedForBackground = false
        startLoadDiagnostics(trigger: .backgroundResume)
        // The socket may survive backgrounding. Always repair before publishing
        // its queued events, even if it sends no new ready handshake.
        let elapsed = unavailableSince.map {
            cacheTimeProvider().timeIntervalSince($0)
        } ?? Self.staleChartInterval
        // A short return updates the existing frame in place. Only the stale
        // branch shows the recovery animation above the retained chart.
        await beginRealtimeEpoch(showLoading: elapsed >= Self.staleChartInterval)
    }

    func realtimeConnectionChanged(_ state: RealtimeConnectionState) {
        guard realtimeTask != nil, hasRealtimeConnection, state != .connected else { return }
        invalidateIntervalCache()
        isRealtimeDisconnected = true
        if unavailableSince == nil { unavailableSince = cacheTimeProvider() }
        guard !isSuspendedForBackground else { return }
        recoveryState = .disconnected
        startRecoveryDiagnosticsIfNeeded()
        scheduleStaleChartCover()
    }

    func retryLoading() async {
        guard realtimeTask != nil, !isSuspendedForBackground, recoveryState != .restoring else { return }
        startLoadDiagnostics(trigger: .retry)
        if realtimeClient.state == .disconnected { realtimeClient.connect() }
        await beginRealtimeEpoch()
    }

    private func scheduleStaleChartCover() {
        staleChartTask?.cancel()
        staleChartTask = nil
        guard let since = unavailableSince, !isSuspendedForBackground else { return }
        let remaining = Self.staleChartInterval - cacheTimeProvider().timeIntervalSince(since)
        if remaining <= 0 {
            // Keep the last complete chart on screen while the replacement
            // snapshot is loading. Clearing the frame here causes a visible
            // flash before the new snapshot is ready.
            staleChartTask = nil
            guard recoveryState != .restoring else { return }
            Task { [weak self] in
                guard let self, self.realtimeTask != nil,
                      !self.isSuspendedForBackground,
                      self.recoveryState != .restoring else { return }
                await self.beginRealtimeEpoch(showLoading: true)
            }
            return
        }
        staleChartTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, !Task.isCancelled, self.realtimeTask != nil,
                  !self.isSuspendedForBackground, self.unavailableSince == since else { return }
            self.staleChartTask = nil
            guard self.recoveryState != .restoring else { return }
            await self.beginRealtimeEpoch(showLoading: true)
        }
    }

    private func beginRecoveryPresentation() {
        recoveryRequiresRetry = false
        recoveryState = .restoring
        awaitsRecoveryPresentation = true
        preservesPresentedChart = chartDataFrame != nil
        scheduleStaleChartCover()
        // Repeated reconnects share a deadline; they cannot extend loading forever.
        guard recoveryDeadlineTask == nil else { return }
        let id = UUID()
        recoveryDeadlineID = id
        let wait = recoveryWait
        recoveryDeadlineTask = Task { [weak self] in
            do { try await wait(.seconds(20)) } catch { return }
            guard let self, !Task.isCancelled, self.recoveryDeadlineID == id,
                  self.realtimeTask != nil, !self.isSuspendedForBackground,
                  self.awaitsRecoveryPresentation else { return }
            self.intervalTask?.cancel()
            self.intervalTask = nil
            self.historyRequestID = UUID()
            self.historyRefreshPending = false
            self.activeHistoryLimit = nil
            self.waitingForHistory = false
            self.finishLoadDiagnostics(outcome: "timeout")
            self.failRecovery(self.isRealtimeDisconnected
                ? "连接已断开，请检查网络后重试" : "K线加载超时，请重试", requiresRetry: true)
        }
    }

    private func cancelRecoveryDeadline() {
        recoveryDeadlineTask?.cancel()
        recoveryDeadlineTask = nil
        recoveryDeadlineID = nil
        awaitsRecoveryPresentation = false
    }

    private func failRecovery(_ message: String, requiresRetry: Bool = false) {
        cancelRecoveryDeadline()
        recoveryRequiresRetry = requiresRetry
        recoveryState = .failed(message)
        lastError = message
    }

    func selectInterval(_ interval: MarketKlineInterval) {
        guard self.interval != interval else {
            return
        }
        let cached = takeCachedInterval(interval)
        cacheCurrentIntervalIfVerified()
        self.interval = interval
        startLoadDiagnostics(trigger: .intervalChange)
        configureChartPipeline(for: interval, restoring: cached)
        if cached == nil {
            subscribe()
            reload()
        }
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
        reloadHistory(limit: 1_500)
    }

    private func reloadHistory(limit: Int) {
        guard !isSuspendedForBackground, !recoveryRequiresRetry else { return }
        if case .failed = recoveryState {
            if chartDataFrame == nil || chartDataFrame?.epoch != chartPipelineEpoch {
                beginRecoveryPresentation()
            } else {
                recoveryState = .restoring
            }
        }
        if chartPipeline == nil {
            configureChartPipeline(for: interval)
        }
        if intervalTask != nil { loadDiagnostics?.record("request_cancelled") }
        intervalTask?.cancel()
        let requestID = UUID()
        historyRequestID = requestID
        isInstallingTailSnapshot = false
        historyRefreshPending = false
        let requestedInterval = interval
        let pipeline = chartPipeline
        let epoch = chartPipelineEpoch
        let sessionID = chartPipelineSessionID
        let restore = cacheRestoreTask
        activeHistoryLimit = limit
        intervalTask = Task { [weak self] in
            guard let self else { return }
            await restore?.value
            guard !Task.isCancelled, self.chartPipelineSessionID == sessionID,
                  self.chartPipelineEpoch == epoch, self.historyRequestID == requestID else { return }
            var recoveryAttempt = 0
            var requestLimit = limit
            while !Task.isCancelled {
                if !self.pendingHistorySignals.isEmpty || self.chartRecoveryNeeded {
                    requestLimit = 1_500
                }
                self.activeHistoryLimit = requestLimit
                await self.loadHistory(
                    interval: requestedInterval,
                    pipeline: pipeline,
                    epoch: epoch,
                    sessionID: sessionID,
                    requestID: requestID,
                    limit: requestLimit
                )
                guard !Task.isCancelled, self.historyRequestID == requestID,
                      self.chartPipelineSessionID == sessionID,
                      self.chartPipelineEpoch == epoch else { return }
                if self.recoveryRequiresRetry {
                    self.intervalTask = nil
                    self.activeHistoryLimit = nil
                    return
                }
                let health = await pipeline?.health()
                guard !Task.isCancelled, self.historyRequestID == requestID,
                      self.chartPipelineSessionID == sessionID,
                      self.chartPipelineEpoch == epoch else { return }
                // A snapshot already in flight can satisfy a new recovery request.
                // Only retry if the pipeline still needs repair after installing it.
                self.chartRecoveryNeeded = !self.waitingForHistory
                    && self.chartRecoveryNeeded && (requestLimit == 2 || health?.recoveryRequest != nil)
                if self.historyRefreshPending {
                    self.historyRefreshPending = false
                    requestLimit = 1_500
                    continue
                }
                if !self.pendingHistorySignals.isEmpty, self.firstFrameGateToken == nil {
                    requestLimit = 1_500
                    continue
                }
                if self.chartRecoveryNeeded {
                    if requestLimit == 2 { requestLimit = 1_500; continue }
                    let delay = min(30, pow(2, Double(min(recoveryAttempt, 5))) * Double.random(in: 0.8...1.2))
                    recoveryAttempt += 1
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                    continue
                }
                self.intervalTask = nil
                self.activeHistoryLimit = nil
                if self.historyPageAwaitingSnapshot,
                   self.chartDataFrame?.epoch == epoch {
                    self.historyPageAwaitingSnapshot = false
                    if let before = self.pendingHistoryBoundary {
                        self.loadOlderHistory(before: before)
                    }
                }
                return
            }
        }
    }

    // Ready notices and reconciliation must not restart a downloading snapshot.
    // Present that response first, then recover all overlapping notices in one read.
    private func refreshHistoryWhenIdle() {
        guard !isSuspendedForBackground, !recoveryRequiresRetry else { return }
        if intervalTask != nil {
            historyRefreshPending = true
        } else {
            reload()
        }
    }

    func requestOlderHistory() {
        guard pendingHistoryBoundary == nil,
              !isLoadingOlderHistory,
              hasMoreHistory,
              let beforeOpenTime = chartDataFrame?
                .candles.history.candles.first?.openTime else {
            return
        }
        loadOlderHistory(before: beforeOpenTime)
    }

    private func loadOlderHistory(before beforeOpenTime: Int64) {
        guard !isSuspendedForBackground else { return }
        guard let pipeline = chartPipeline, let epoch = chartPipelineEpoch else { return }
        guard !historyPageAwaitingSnapshot else { return }
        if historyPageTask != nil {
            historyPageRefreshPending = true
            return
        }
        let requestedInterval = interval
        let sessionID = chartPipelineSessionID
        let pageLimit = 1_500
        isLoadingOlderHistory = true
        let requestID = UUID()
        historyPageRequestID = requestID
        pendingHistoryBoundary = beforeOpenTime
        let restore = cacheRestoreTask
        historyPageTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.chartPipelineSessionID == sessionID && self.historyPageRequestID == requestID {
                    self.isLoadingOlderHistory = false
                    self.historyPageTask = nil
                    if self.historyPageRefreshPending {
                        self.historyPageRefreshPending = false
                        if let before = self.pendingHistoryBoundary {
                            self.loadOlderHistory(before: before)
                        }
                    }
                }
            }
            await restore?.value
            guard !Task.isCancelled, self.chartPipelineSessionID == sessionID,
                  self.chartPipelineEpoch == epoch, self.historyPageRequestID == requestID else { return }
            do {
                let response = try await self.fetchHistory(
                    interval: requestedInterval, beforeOpenTime: beforeOpenTime, limit: pageLimit)
                guard !Task.isCancelled,
                      self.interval == requestedInterval,
                      self.chartPipelineSessionID == sessionID,
                      self.chartPipelineEpoch == epoch else {
                    return
                }
                let older = response.items.filter {
                    $0.openTime < beforeOpenTime
                }
                self.hasMoreHistory = response.hasMoreHistory ?? (older.count == pageLimit)
                self.pendingHistoryBoundary = response.historyPending == true ? beforeOpenTime : nil
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
        DisplayNumber.text(changePercent24h, signed: true) + "%"
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
            .marketHistory(symbols: [market.symbol], intervals: [interval.rawValue]),
        ])
    }

    private func loadHistory(
        interval requestedInterval: MarketKlineInterval,
        pipeline: ChartDataPipeline?,
        epoch: KlineStreamEpoch?,
        sessionID: UUID,
        requestID: UUID,
        limit: Int
    ) async {
#if DEBUG
        let snapshotStarted = Date.timeIntervalSinceReferenceDate
#endif
        isLoading = candles.isEmpty
        // Signals already observed before this request are covered by this new
        // read. Signals arriving during it need the response's server watermark.
        if limit == 1_500 { pendingHistorySignals = PendingHistorySignals() }
        let requestDate = cacheTimeProvider()
        let tailBaseRevision = limit == 2 ? chartDataFrame?.candles.revision : nil
        lastError = nil
        defer {
            if chartPipelineSessionID == sessionID, chartPipelineEpoch == epoch,
               historyRequestID == requestID {
                isLoading = candles.isEmpty && waitingForHistory
            }
        }

        do {
            let response = try await fetchHistory(
                interval: requestedInterval,
                beforeOpenTime: nil,
                limit: limit
            )
            guard !Task.isCancelled, interval == requestedInterval,
                  chartPipelineSessionID == sessionID, chartPipelineEpoch == epoch,
                  historyRequestID == requestID else {
                return
            }
            let verificationDate = cacheTimeProvider()
            let responseBucket = cacheBucket(for: requestedInterval, at: verificationDate)
            let serverBucketMatches = response.serverTime.map { serverTime in
                serverTime > 0 && cacheBucket(for: requestedInterval,
                    at: Date(timeIntervalSince1970: Double(serverTime) / 1_000)) == responseBucket
            } ?? true
            if limit == 1_500 {
                waitingForHistory = response.historyPending == true
                pendingHistorySignals.removeCovered(by: response.serverTime)
            } else if response.historyPending == true || response.items.isEmpty || chartRecoveryNeeded
                || cacheBucket(for: requestedInterval, at: requestDate) != responseBucket
                || snapshotVerifiedBucket != responseBucket || !serverBucketMatches {
                invalidateIntervalCache()
                historyRefreshPending = true
                return
            }
            if response.items.isEmpty {
                if response.historyPending == true {
                    return
                }
                throw APIError.invalidResponse
            }
            isLoading = false
            let sorted = response.items.sorted {
                $0.openTime < $1.openTime
            }
            if limit == 1_500 { hasMoreHistory = response.hasMoreHistory ?? (sorted.count == 1_500) }
            guard let pipeline, let epoch,
                  chartPipelineSessionID == sessionID else {
                return
            }
            let loadedAt = currentTimeMilliseconds()
            loadDiagnostics?.record("snapshot_started", value: sorted.count)
            if limit == 2 { isInstallingTailSnapshot = true }
            let result = await pipeline.installSnapshot(
                sorted,
                fetchedAtMilliseconds: loadedAt,
                epoch: epoch,
                preservingNewerData: true,
                tailOnly: limit == 2,
                tailBaseRevision: tailBaseRevision
            )
            if chartPipelineSessionID == sessionID, historyRequestID == requestID {
                isInstallingTailSnapshot = false
            }
            guard !Task.isCancelled, chartPipelineSessionID == sessionID,
                  chartPipelineEpoch == epoch else {
                return
            }
            loadDiagnostics?.record("snapshot_installed")
            if let frame = await initialFrame(
                result.frame,
                interval: requestedInterval,
                loadedAt: loadedAt,
                pipeline: pipeline,
                epoch: epoch,
                sessionID: sessionID
            ) {
                guard !Task.isCancelled, historyRequestID == requestID else { return }
                if limit == 1_500 { candles = Array(sorted.suffix(500)) }
                armHistoryPresentationGate()
                chartDataFrame = frame
                if !awaitsRecoveryPresentation {
                    recoveryState = isRealtimeDisconnected ? .disconnected : .idle
                }
                loadDiagnostics?.record("frame_ready")
                upsertLiveTail(from: frame)
                if limit == 1_500 {
                    latestHistoryServerTime = response.serverTime
                    pendingHistorySignals.removeCovered(by: response.serverTime)
                }
                let verifiedBucket = cacheBucket(for: requestedInterval, at: verificationDate)
                if limit == 1_500, response.historyPending != true, response.statisticsPending != true,
                   frame.recoveryRequest == nil,
                   cacheBucket(for: requestedInterval, at: requestDate) == verifiedBucket,
                   serverBucketMatches {
                    snapshotVerifiedAt = verificationDate
                    snapshotVerifiedBucket = verifiedBucket
                } else if limit == 1_500 || response.statisticsPending == true {
                    snapshotVerifiedAt = nil
                    snapshotVerifiedBucket = nil
                }
                if limit == 1_500 { isUsingVerifiedIntervalCache = false }
#if DEBUG
                let elapsed = (Date.timeIntervalSinceReferenceDate - snapshotStarted) * 1000
                Self.performanceLog.debug("chart_snapshot_ready symbol=\(self.market.symbol, privacy: .public) interval=\(requestedInterval.rawValue, privacy: .public) duration_ms=\(elapsed)")
#endif
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
            guard !Task.isCancelled, historyRequestID == requestID else {
                return
            }
            waitingForHistory = false
            snapshotVerifiedAt = nil
            snapshotVerifiedBucket = nil
            isUsingVerifiedIntervalCache = false
            switch APIError.map(error) {
            case .networkUnavailable:
                failRecovery("网络未连接，请检查连接后重试")
            case .connectionFailed:
                failRecovery("连接失败，请检查网络后重试")
            case .timeout:
                failRecovery("K线加载超时，请重试")
            default:
                failRecovery("K线加载失败，请重试")
            }
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
        } else if limit == 1_500 {
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
#if DEBUG
        let requestStarted = Date.timeIntervalSinceReferenceDate
#endif
        let response = try await apiClient.send(
            APIRequest<MarketKlineHistoryResponse>(
                path: "/api/market/klines",
                queryItems: queryItems,
                showsErrorToast: false,
                diagnostics: loadDiagnostics?.request()
            )
        )
#if DEBUG
        let requestElapsed = (Date.timeIntervalSinceReferenceDate - requestStarted) * 1000
        Self.performanceLog.debug("history_http symbol=\(self.market.symbol, privacy: .public) interval=\(requestedInterval.rawValue, privacy: .public) duration_ms=\(requestElapsed) items=\(response.items.count)")
#endif
        guard response.symbol.uppercased()
                == market.symbol.uppercased(),
              response.interval
                == requestedInterval.rawValue else {
            throw APIError.invalidResponse
        }
        return response
    }

    func receive(
        _ message: RealtimeServerMessage
    ) async {
        let receivingSession = chartPipelineSessionID
        if let restore = cacheRestoreTask {
            await restore.value
            guard receivingSession == chartPipelineSessionID else { return }
        }
        if message.type == "ready" {
            if !isSuspendedForBackground, hasRealtimeConnection || recoveryState.failureMessage != nil {
                startRecoveryDiagnosticsIfNeeded()
            }
            loadDiagnostics?.record("socket_ready")
            isRealtimeDisconnected = false
            guard !isSuspendedForBackground else { hasRealtimeConnection = true; return }
            if hasRealtimeConnection {
                // The first history request and the first socket handshake
                // start together. Replacing its epoch here briefly hides the
                // chart and creates the recurring open-screen flash.
                if !hasReceivedReadyHandshake,
                   chartDataFrame == nil,
                   intervalTask != nil || cacheRestoreTask != nil {
                    hasReceivedReadyHandshake = true
                    return
                }
                hasReceivedReadyHandshake = true
                await beginRealtimeEpoch()
            } else {
                // HTTP and the first handshake start together. That response
                // already belongs to this connection; do not cancel its download.
                hasRealtimeConnection = true
                hasReceivedReadyHandshake = true
                if recoveryState.failureMessage != nil { await beginRealtimeEpoch() }
            }
            return
        }
        guard !isSuspendedForBackground, !recoveryRequiresRetry else { return }
        if message.type == "ack", let ack = message.decodeData(as: RealtimeSubscriptionAcknowledgement.self),
           ack.subscriptions.contains(where: { $0.channel == "market.history"
               && ($0.filters["symbols"]?.contains(market.symbol) ?? false)
               && ($0.filters["intervals"]?.contains(interval.rawValue) ?? false) }) {
            // A subscription acknowledgement is not a data-change event. A
            // verified same-bucket cache already has complete closed history;
            // cumulative OHLC resumes after the cache-restore barrier above.
            if !canTrustActiveIntervalCache() {
                scheduleHistoryNoticeRefresh(timestamp: message.timestamp, acknowledgement: true)
            }
            return
        }
        guard message.type == "event" else {
            return
        }

        switch message.channel {
        case "market.history":
            guard let payload = message.decodeData(as: MarketHistoryReadyPayload.self),
                  payload.symbol == market.symbol else { return }
            if let changed = MarketKlineInterval(rawValue: payload.interval) {
                intervalCache.removeValue(forKey: changed)
            }
            guard payload.interval == interval.rawValue else { return }
            if let before = payload.beforeOpenTime {
                if pendingHistoryBoundary == before { loadOlderHistory(before: before) }
            } else {
                if message.timestamp > 0, let watermark = latestHistoryServerTime,
                   message.timestamp < watermark { return }
                snapshotVerifiedAt = nil
                snapshotVerifiedBucket = nil
                isUsingVerifiedIntervalCache = false
                scheduleHistoryNoticeRefresh(timestamp: message.timestamp)
            }
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

    private func scheduleHistoryNoticeRefresh(timestamp: Int64, acknowledgement: Bool = false) {
        loadDiagnostics?.record("history_notice")
        pendingHistorySignals.record(timestamp: timestamp, acknowledgement: acknowledgement)
        pendingHistorySignals.removeCovered(by: latestHistoryServerTime)
        guard !pendingHistorySignals.isEmpty else { return }
        guard historyNoticeTask == nil else { return }
        let sessionID = chartPipelineSessionID
        let epoch = chartPipelineEpoch
        historyNoticeTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.chartPipelineSessionID == sessionID,
                  self.chartPipelineEpoch == epoch else { return }
            self.historyNoticeTask = nil
            self.refreshForHistorySignalsIfReady()
            if let before = self.pendingHistoryBoundary { self.loadOlderHistory(before: before) }
        }
    }

    private func refreshForHistorySignalsIfReady() {
        guard !isSuspendedForBackground, !recoveryRequiresRetry, !pendingHistorySignals.isEmpty,
              intervalTask == nil, cacheRestoreTask == nil, firstFrameGateToken == nil else { return }
        reload()
    }

    private func armHistoryPresentationGate() {
        guard !firstFrameGateWasReleased, firstFrameGateToken == nil,
              let epoch = chartPipelineEpoch else { return }
        let token = UUID(), sessionID = chartPipelineSessionID
        firstFrameGateToken = token
        firstFrameFallback = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.chartPipelineSessionID == sessionID,
                  self.chartPipelineEpoch == epoch, self.firstFrameGateToken == token else { return }
            self.releaseHistoryPresentationGate()
        }
    }

    private func releaseHistoryPresentationGate() {
        firstFrameFallback?.cancel()
        firstFrameFallback = nil
        firstFrameGateToken = nil
        firstFrameGateWasReleased = true
        refreshForHistorySignalsIfReady()
    }

    private func resetHistoryPresentationGate() {
        historyNoticeTask?.cancel()
        historyNoticeTask = nil
        firstFrameFallback?.cancel()
        firstFrameFallback = nil
        firstFrameGateToken = nil
        firstFrameGateWasReleased = false
        pendingHistorySignals = PendingHistorySignals()
        latestHistoryServerTime = nil
    }

    private func canTrustActiveIntervalCache() -> Bool {
        guard isUsingVerifiedIntervalCache, !waitingForHistory, !chartRecoveryNeeded,
              pendingHistorySignals.isEmpty, cachedTradingMode == NativeTradingMode.current,
              let verified = snapshotVerifiedAt, let bucket = snapshotVerifiedBucket else { return false }
        let now = cacheTimeProvider(), age = now.timeIntervalSince(verified)
        return age >= 0 && age < 10 && bucket == cacheBucket(for: interval, at: now)
    }

    private func cacheBucket(for interval: MarketKlineInterval, at date: Date) -> Int64 {
        let width = Int64(interval.duration * 1_000)
        let time = Int64(date.timeIntervalSince1970 * 1_000)
        let offset: Int64 = interval == .oneWeek ? 345_600_000 : 0
        let remainder = ((time - offset) % width + width) % width
        return time - remainder
    }

    private func cacheCurrentIntervalIfVerified() {
        guard !isSuspendedForBackground, (intervalTask == nil || activeHistoryLimit == 2),
              !isInstallingTailSnapshot,
              historyPageTask == nil, !isLoadingOlderHistory, !historyPageAwaitingSnapshot,
              pendingHistoryBoundary == nil, !historyRefreshPending, historyNoticeTask == nil,
              pendingHistorySignals.isEmpty,
              chartIndicatorUpdateTask == nil, cacheRestoreTask == nil,
              !waitingForHistory, !chartRecoveryNeeded,
              let pipeline = chartPipeline, let frame = chartDataFrame,
              frame.epoch == chartPipelineEpoch, frame.stream.interval == interval.rawValue,
              frame.stream.symbol == market.symbol.uppercased(), frame.recoveryRequest == nil,
              let verifiedAt = snapshotVerifiedAt, let bucket = snapshotVerifiedBucket,
              cacheTimeProvider().timeIntervalSince(verifiedAt) >= 0,
              cacheTimeProvider().timeIntervalSince(verifiedAt) < 10,
              cacheBucket(for: interval, at: cacheTimeProvider()) == bucket else { return }
        if activeHistoryLimit == 2 {
            intervalTask?.cancel()
            intervalTask = nil
            activeHistoryLimit = nil
            historyRequestID = UUID()
        }
        cacheUseOrder &+= 1
        intervalCache[interval] = CachedInterval(pipeline: pipeline, frame: frame,
            candles: candles, hasMoreHistory: hasMoreHistory, verifiedAt: verifiedAt,
            bucketOpenTime: bucket, selection: chartIndicatorSelection,
            parameters: chartIndicatorParameters, tradingMode: NativeTradingMode.current,
            useOrder: cacheUseOrder)
        while intervalCache.count > 3,
              let oldest = intervalCache.min(by: { $0.value.useOrder < $1.value.useOrder })?.key {
            intervalCache.removeValue(forKey: oldest)
        }
    }

    private func takeCachedInterval(_ requested: MarketKlineInterval) -> CachedInterval? {
        let now = cacheTimeProvider()
        intervalCache = intervalCache.filter { key, cached in
            let age = now.timeIntervalSince(cached.verifiedAt)
            return age >= 0 && age < 10 && cached.bucketOpenTime == cacheBucket(for: key, at: now)
                && cached.selection == chartIndicatorSelection && cached.parameters == chartIndicatorParameters
                && cached.tradingMode == NativeTradingMode.current
        }
        return intervalCache.removeValue(forKey: requested)
    }

    private func invalidateIntervalCache() {
        intervalCache.removeAll()
        snapshotVerifiedAt = nil
        snapshotVerifiedBucket = nil
        isUsingVerifiedIntervalCache = false
        cachedTradingMode = nil
    }

    private func configureChartPipeline(
        for interval: MarketKlineInterval,
        restoring cached: CachedInterval? = nil
    ) {
        cancelRecoveryDeadline()
        resetHistoryPresentationGate()
        cacheRestoreTask?.cancel()
        cacheRestoreTask = nil
        intervalTask?.cancel()
        intervalTask = nil
        activeHistoryLimit = nil
        isInstallingTailSnapshot = false
        historyRequestID = UUID()
        snapshotVerifiedAt = nil
        snapshotVerifiedBucket = nil
        isUsingVerifiedIntervalCache = false
        cachedTradingMode = nil
        historyNoticeTask?.cancel()
        historyNoticeTask = nil
        pendingHistoryBoundary = nil
        historyPageRequestID = UUID()
        historyPageRefreshPending = false
        historyPageAwaitingSnapshot = false
        historyRefreshPending = false
        waitingForHistory = false
        chartIndicatorUpdateTask?.cancel()
        chartIndicatorUpdateTask = nil
        pendingChartPriceUpdate = nil
        chartRecoveryNeeded = false
        chartPipelineSessionID = UUID()
        historyPageTask?.cancel()
        historyPageTask = nil
        isLoadingOlderHistory = false
        hasMoreHistory = true
        chartPipelineGeneration &+= 1
        let epoch = KlineStreamEpoch(
            generation: chartPipelineGeneration
        )
        diagnosticEpoch = epoch
        beginRecoveryPresentation()
        if let cached {
            chartPipeline = cached.pipeline
            chartPipelineEpoch = epoch
            snapshotVerifiedAt = cached.verifiedAt
            snapshotVerifiedBucket = cached.bucketOpenTime
            isUsingVerifiedIntervalCache = true
            cachedTradingMode = cached.tradingMode
            candles = cached.candles
            hasMoreHistory = cached.hasMoreHistory
            isLoading = false
            lastError = nil
            chartDataFrame = ChartDataFrame(stream: cached.frame.stream, epoch: epoch,
                candles: cached.frame.candles, indicators: cached.frame.indicators,
                recoveryRequest: nil, readyTime: ProcessInfo.processInfo.systemUptime)
            // Existing stage names remain compatible with deployed diagnostics.
            loadDiagnostics?.record("snapshot_installed", value: 0)
            loadDiagnostics?.record("frame_ready", value: 1)
            armHistoryPresentationGate()
            let sessionID = chartPipelineSessionID
            cacheRestoreTask = Task { [weak self] in
                let frame = await cached.pipeline.resumeCachedEpoch(epoch,
                    from: cached.frame.epoch, bucketOpenTime: cached.bucketOpenTime)
                guard let self, !Task.isCancelled,
                      self.chartPipelineSessionID == sessionID,
                      self.chartPipelineEpoch == epoch else { return }
                self.cacheRestoreTask = nil
                guard let frame else {
                    self.invalidateIntervalCache()
                    self.configureChartPipeline(for: interval)
                    self.subscribe()
                    self.reload()
                    return
                }
                self.chartDataFrame = frame
                if let price = self.realtimePrice, let eventTime = self.latestPriceEventTime,
                   self.cacheBucket(for: interval,
                       at: Date(timeIntervalSince1970: Double(eventTime) / 1_000)) == cached.bucketOpenTime {
                    await self.applyChartPriceUpdate(price: price, eventTime: eventTime)
                }
                guard !Task.isCancelled, self.chartPipelineSessionID == sessionID,
                      self.chartPipelineEpoch == epoch else { return }
                self.subscribe()
                if self.intervalTask == nil { self.reloadHistory(limit: 2) }
            }
            return
        }
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
        let restore = cacheRestoreTask
        invalidateIntervalCache()
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
            await restore?.value
            guard !Task.isCancelled else { return }
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
                  self.chartIndicatorParameters == parameters,
                  !self.isSuspendedForBackground else {
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

    private func beginRealtimeEpoch(showLoading: Bool = true) async {
        invalidateIntervalCache()
        cacheRestoreTask?.cancel()
        cacheRestoreTask = nil
        resetHistoryPresentationGate()
        guard let pipeline = chartPipeline else {
            return
        }
        startRecoveryDiagnosticsIfNeeded()
        loadDiagnostics?.record("epoch_changed")
        chartRecoveryNeeded = false
        // A page belongs to the connection epoch that requested it. Keep its
        // boundary, but invalidate its completion before starting a new epoch.
        historyPageTask?.cancel()
        historyPageTask = nil
        historyPageRequestID = UUID()
        historyPageRefreshPending = false
        historyPageAwaitingSnapshot = pendingHistoryBoundary != nil
        isLoadingOlderHistory = false
        chartPipelineGeneration &+= 1
        let epoch = KlineStreamEpoch(
            generation: chartPipelineGeneration
        )
        chartPipelineEpoch = epoch
        diagnosticEpoch = epoch
        if showLoading {
            beginRecoveryPresentation()
        } else {
            cancelRecoveryDeadline()
            recoveryRequiresRetry = false
            recoveryState = .idle
            // A short background return keeps the old Metal frame visible;
            // the new snapshot is installed behind it without a loading cover.
            preservesPresentedChart = chartDataFrame != nil
        }
        let sessionID = chartPipelineSessionID
        _ = await pipeline.beginEpoch(epoch)
        guard chartPipelineSessionID == sessionID,
              chartPipelineEpoch == epoch, !isSuspendedForBackground, !recoveryRequiresRetry else {
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
              chartPipelineEpoch == epoch, !isSuspendedForBackground else {
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
                  chartPipelineEpoch == epoch, !isSuspendedForBackground else {
                return
            }
            if let frame = drained.frame {
                chartDataFrame = frame
                upsert(payload.candle)
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
        let restore = cacheRestoreTask
        invalidateIntervalCache()
        guard let pipeline = chartPipeline,
              let epoch = chartPipelineEpoch else {
            return
        }
        let sessionID = chartPipelineSessionID
        Task { [weak self] in
            await restore?.value
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
        guard !isSuspendedForBackground,
              chartPipelineSessionID == sessionID, chartPipelineEpoch == epoch,
              chartPipeline === pipeline, !waitingForHistory else { return }
        invalidateIntervalCache()
        chartRecoveryNeeded = true
        loadDiagnostics?.record("recovery_requested")
        if intervalTask == nil { reload() }
    }

    private func startRecoveryDiagnosticsIfNeeded() {
        guard loadDiagnostics?.isFinished != false else { return }
        startLoadDiagnostics(trigger: .reconnect)
    }

    private func startLoadDiagnostics(trigger: ChartLoadDiagnostics.Trigger = .initial) {
        guard diagnosticUpload != nil else { return }
        finishLoadDiagnostics(outcome: "superseded")
        let trace = ChartLoadDiagnostics(symbol: market.symbol, interval: interval.rawValue, trigger: trigger)
        loadDiagnostics = trace
        // Retained content belongs to the preceding load until the new epoch is assigned.
        diagnosticEpoch = nil
        diagnosticTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(40)) } catch { return }
            guard let self, self.loadDiagnostics?.id == trace.id else { return }
            self.finishLoadDiagnostics(outcome: "timeout")
        }
    }

    func chartFirstFramePresented(epoch: KlineStreamEpoch, at time: TimeInterval) {
        guard realtimeTask != nil, !isSuspendedForBackground,
              chartPipelineEpoch == epoch, chartDataFrame?.epoch == epoch else { return }
        cancelRecoveryDeadline()
        recoveryRequiresRetry = false
        lastError = nil
        staleChartTask?.cancel()
        staleChartTask = nil
        unavailableSince = isRealtimeDisconnected ? cacheTimeProvider() : nil
        recoveryState = isRealtimeDisconnected ? .disconnected : .idle
        preservesPresentedChart = false
        if isRealtimeDisconnected { scheduleStaleChartCover() }
        releaseHistoryPresentationGate()
        if diagnosticEpoch == epoch {
            finishLoadDiagnostics(outcome: "displayed", presentedAt: time)
        }
    }

    private func finishLoadDiagnostics(outcome: String, presentedAt: TimeInterval? = nil) {
        diagnosticTimeout?.cancel()
        diagnosticTimeout = nil
#if targetEnvironment(simulator)
        let kind = "gpu_completion_proxy"
#else
        let kind = "presented"
#endif
        guard let data = loadDiagnostics?.report(outcome: outcome, presentedAt: presentedAt,
            completionKind: presentedAt == nil ? "none" : kind) else { return }
        diagnosticEpoch = nil
        diagnosticUpload?(data)
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
        guard let pipeline = chartPipeline,
              let epoch = chartPipelineEpoch,
              chartDataFrame?.epoch == epoch else {
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
              chartPipelineEpoch == epoch, !isSuspendedForBackground else {
            return
        }
        if let frame = result.frame {
            chartDataFrame = frame
            upsertLiveTail(from: frame)
        } else if result.recoveryRequest != nil {
            pendingChartPriceUpdate = MarketChartPriceUpdate(price: price, eventTime: eventTime)
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
        // A fetched OHLC tail is authoritative. Do not overwrite it with a
        // cached quote from the previous interval or an older ticker snapshot.
        if pending == nil, installedFrame.candles.liveTail != nil { return installedFrame }
        let recentPrice = latestPriceEventTime.flatMap { timestamp in
            timestamp >= loadedBucket ? realtimePrice : nil
        }
        let price = pending?.price
            ?? recentPrice
            ?? installedFrame.candles.history.candles.last?.closePrice
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
