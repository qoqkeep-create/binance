import Combine
import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    private static let maxRealtimeTickerSymbols = 200

    @Published private(set) var markets: [MarketSnapshot]
    @Published private(set) var signals: [StrategySignal]
    @Published private(set) var lastUpdated: Date
    @Published private(set) var isRefreshing = false
    @Published private(set) var realtimeTickerRevision = 0
    @Published private(set) var catalogSymbols: [String] = []
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var catalogLoadFailed = false
    private var catalogLoadedAt: Date?
    private var catalogRevision = 0
    private var tradeTickerSymbol: String?
    @Published private(set) var isLoadingSignals = false
    @Published private(set) var isLoadingMoreSignals = false
    @Published private(set) var hasMoreSignals = false
    @Published private(set) var signalLoadFailed = false

    private let apiClient: (any APIClient)?
    private let realtimeClient: RealtimeClient?
    private let watchlistStore: (any MarketWatchlistStoring)?
    private var realtimeEventsTask: Task<Void, Never>?
    private var defaultWatchlistTask: Task<Void, Never>?
    private var tickerSnapshotTask: Task<Void, Never>?
    private var tickerFlushTask: Task<Void, Never>?
    private var pendingTickerUpdates: [String: MarketTickerPayload] = [:]
    private var latestTickerBySymbol: [String: MarketTickerPayload] = [:]
    private var searchTickerSymbols: Set<String> = []
    private var activeUserID: String?
    private var activeQuoteAsset: String?
    private var watchlistIsCustomized = false
    private var hasLoadedSignals = false
    private var nextSignalCursor: String?
    private var signalRequestRevision = 0
    private var signalNotificationPreferences =
        SignalNotificationPreferences.allEnabled
    private var hasLoadedSignalNotificationPreferences = false
    private var pendingNotificationSignal: StrategySignal?

    init(
        markets: [MarketSnapshot] = [],
        signals: [StrategySignal] = [],
        apiClient: (any APIClient)? = nil,
        realtimeClient: RealtimeClient? = nil,
        watchlistStore: (any MarketWatchlistStoring)? = nil
    ) {
        self.markets = markets.map { var market = $0; market.isPinned = false; return market }
        self.signals = signals
        self.apiClient = apiClient
        self.realtimeClient = realtimeClient
        self.watchlistStore = watchlistStore
        lastUpdated = .now
    }

    func startRealtime(userID: String) {
        guard realtimeEventsTask == nil,
              let realtimeClient,
              !userID.isEmpty else {
            return
        }

        activeUserID = userID
        _ = restorePreferences(for: userID)

        let events = realtimeClient.events()
        realtimeEventsTask = Task { [weak self] in
            for await message in events {
                guard !Task.isCancelled else {
                    return
                }
                self?.handleRealtimeMessage(message)
            }
        }

        realtimeClient.subscribe([
            .strategySignal(),
        ])
        defaultWatchlistTask = Task { [weak self] in
            await self?.loadDefaultWatchlist(for: userID)
        }
    }

    func stopRealtime() {
        defaultWatchlistTask?.cancel()
        defaultWatchlistTask = nil
        realtimeEventsTask?.cancel()
        realtimeEventsTask = nil
        realtimeClient?.unsubscribe(
            channels: ["market.ticker", "strategy.signal"]
        )
        tickerSnapshotTask?.cancel()
        tickerSnapshotTask = nil
        tickerFlushTask?.cancel()
        tickerFlushTask = nil
        pendingTickerUpdates.removeAll()
        latestTickerBySymbol.removeAll()
        searchTickerSymbols.removeAll()
        tradeTickerSymbol = nil
        catalogRevision += 1
        catalogSymbols = []
        catalogLoadedAt = nil
        isLoadingCatalog = false
        catalogLoadFailed = false
        realtimeTickerRevision &+= 1
        activeUserID = nil
        activeQuoteAsset = nil
        watchlistIsCustomized = false
        signalNotificationPreferences = .allEnabled
        hasLoadedSignalNotificationPreferences = false
        pendingNotificationSignal = nil
        resetSignalFeed()
    }

    func markets(
        matching query: String = "",
        onlyVisible: Bool
    ) -> [MarketSnapshot] {
        let normalizedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        return markets.filter { market in
            if onlyVisible, !market.isVisible {
                return false
            }

            guard !normalizedQuery.isEmpty else {
                return true
            }

            return market.symbol.contains(normalizedQuery)
                || market.name.uppercased().contains(normalizedQuery)
        }
    }

    func trackSearchTickerSymbols(_ symbols: [String]) {
        var normalizedSymbols: [String] = []
        var seen = Set<String>()

        for symbol in symbols {
            let normalized = symbol
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard !normalized.isEmpty else {
                continue
            }
            if let activeQuoteAsset,
               !normalized.hasSuffix(activeQuoteAsset) {
                continue
            }
            guard seen.insert(normalized).inserted else {
                continue
            }
            normalizedSymbols.append(normalized)
            if normalizedSymbols.count
                == Self.maxRealtimeTickerSymbols {
                break
            }
        }

        let updatedSymbols = Set(normalizedSymbols)
        guard updatedSymbols != searchTickerSymbols else {
            return
        }
        searchTickerSymbols = updatedSymbols
        updateRealtimeSubscriptions()
    }

    func stopTrackingSearchTickers() {
        guard !searchTickerSymbols.isEmpty else {
            return
        }
        searchTickerSymbols.removeAll()
        updateRealtimeSubscriptions()
    }

    func realtimeSnapshot(
        for market: MarketSnapshot
    ) -> MarketSnapshot {
        guard let payload = latestTickerBySymbol[market.symbol] else {
            return market
        }

        let eventDate = Date(
            timeIntervalSince1970:
                Double(payload.eventTime) / 1_000
        )
        guard eventDate >= market.updatedAt else {
            return market
        }

        var updated = market
        updated.price = payload.lastPrice
        updated.quoteVolume24h = payload.quoteVolume24h
        updated.turnoverText = Self.formattedTurnover(
            payload.quoteVolume24h
        )
        updated.changePercent24h = payload.priceChangePercent24h
        updated.updatedAt = eventDate
        return updated
    }

    func containsInWatchlist(_ symbol: String) -> Bool {
        markets.contains { $0.symbol == symbol && $0.isVisible }
    }

    func addToWatchlist(_ symbol: String) {
        guard let index = markets.firstIndex(where: { $0.symbol == symbol }),
              !markets[index].isVisible else { return }
        markets[index].isVisible = true
        persistPreferences(customized: true)
        updateRealtimeSubscriptions()
    }

    func moveVisibleMarkets(from source: IndexSet, to destination: Int) {
        let visible = markets.filter(\.isVisible)
        guard source.allSatisfy(visible.indices.contains), destination <= visible.count else { return }
        let moved = source.sorted().map { visible[$0] }
        var reordered = visible.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = max(0, destination - source.filter { $0 < destination }.count)
        reordered.insert(contentsOf: moved, at: insertion)
        markets = reordered + markets.filter { !$0.isVisible }
        persistPreferences(customized: true)
    }

    func trackTradeTickerSymbol(_ symbol: String) {
        let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard tradeTickerSymbol != normalized else { return }
        tradeTickerSymbol = normalized.isEmpty ? nil : normalized
        updateRealtimeSubscriptions()
    }

    func tradeQuote(for symbol: String) -> String {
        _ = realtimeTickerRevision
        let price = latestTickerBySymbol[symbol]?.lastPrice
            ?? markets.first(where: { $0.symbol == symbol })?.price ?? 0
        return price > 0 ? NSDecimalNumber(value: price).stringValue : ""
    }

    func loadSymbolCatalog(force: Bool = false) async {
        guard !isLoadingCatalog, let apiClient else { return }
        if !force, let loaded = catalogLoadedAt, Date().timeIntervalSince(loaded) < 300 { return }
        let revision = catalogRevision
        isLoadingCatalog = true
        defer { if revision == catalogRevision { isLoadingCatalog = false } }
        do {
            let response = try await apiClient.send(APIRequest<MarketSymbolCatalogResponse>(
                path: "/api/market/symbols", showsErrorToast: false))
            guard revision == catalogRevision, !Task.isCancelled else { return }
            let quote = Self.normalizedQuoteAsset(response.quoteAsset)
            guard !quote.isEmpty, activeQuoteAsset == nil || activeQuoteAsset == quote else {
                catalogLoadFailed = true; return
            }
            activeQuoteAsset = quote
            let symbols = Self.normalizedSymbols(response.symbols, quoteAsset: quote).sorted()
            guard !symbols.isEmpty else { catalogLoadFailed = true; return }
            catalogSymbols = symbols
            catalogLoadedAt = .now
            catalogLoadFailed = false
            let available = Set(symbols)
            markets.removeAll { !available.contains($0.symbol) }
            let existing = Set(markets.map(\.symbol))
            markets.append(contentsOf: symbols.filter { !existing.contains($0) }.map {
                var market = Self.placeholderMarket(symbol: $0, quoteAsset: quote)
                market.isVisible = false
                return market
            })
            persistPreferences()
            updateRealtimeSubscriptions()
        } catch {
            if revision == catalogRevision, !Task.isCancelled { catalogLoadFailed = true }
        }
    }

    func moveMarketToTop(_ symbol: String) {
        guard let index = markets.firstIndex(where: { $0.symbol == symbol }) else {
            return
        }

        let market = markets.remove(at: index)
        markets.insert(market, at: 0)
        persistPreferences(customized: true)
    }

    func toggleMarketVisibility(_ symbol: String) {
        guard let index = markets.firstIndex(where: { $0.symbol == symbol }) else {
            return
        }

        markets[index].isVisible.toggle()
        persistPreferences(customized: true)
        updateRealtimeSubscriptions()
    }

    func hideMarkets(_ symbols: Set<String>) {
        guard !symbols.isEmpty else {
            return
        }

        for index in markets.indices where symbols.contains(markets[index].symbol) {
            markets[index].isVisible = false
        }
        persistPreferences(customized: true)
        updateRealtimeSubscriptions()
    }

    func refresh() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        realtimeClient?.connect()
        await loadMarketTickerSnapshot()
        lastUpdated = .now
    }

    func loadSignalsIfNeeded() async {
        guard !hasLoadedSignals else { return }
        await loadFirstSignalPage(showsErrorToast: false)
    }

    func refreshSignals() async {
        await loadFirstSignalPage(showsErrorToast: true)
    }

    func updateSignalNotificationPreferences(
        _ preferences: SignalNotificationPreferences
    ) async {
        signalNotificationPreferences = preferences
        hasLoadedSignalNotificationPreferences = true
        // Invalidate requests made before the save, including paginated responses.
        resetSignalFeed()
        await loadFirstSignalPage(showsErrorToast: true)
    }

    func loadMoreSignals() async {
        guard let apiClient,
              let activeUserID,
              let cursor = nextSignalCursor,
              hasMoreSignals,
              !isLoadingSignals,
              !isLoadingMoreSignals else {
            return
        }

        let revision = signalRequestRevision
        isLoadingMoreSignals = true
        signalLoadFailed = false
        defer {
            if signalRequestRevision == revision {
                isLoadingMoreSignals = false
            }
        }

        do {
            let response = try await apiClient.send(
                APIRequest<StrategySignalPageResponse>(
                    path: "/api/strategy/signals",
                    queryItems: [
                        URLQueryItem(name: "cursor", value: cursor),
                    ],
                    showsErrorToast: false
                )
            )
            guard signalRequestRevision == revision,
                  self.activeUserID == activeUserID,
                  !Task.isCancelled else {
                return
            }
            let existingIDs = Set(signals.map(\.id))
            signals.append(contentsOf: response.items.filter {
                signalNotificationPreferences.allows(interval: $0.interval)
                    && !existingIDs.contains($0.id)
            })
            hasMoreSignals = response.hasNext
            nextSignalCursor = response.nextCursor
            signalLoadFailed = false
        } catch {
            guard signalRequestRevision == revision,
                  self.activeUserID == activeUserID,
                  !Task.isCancelled else {
                return
            }
            signalLoadFailed = true
        }
    }

    func markSignalRead(_ signalID: UUID) async {
        guard let apiClient,
              let activeUserID,
              let index = signals.firstIndex(where: {
                  $0.id == signalID
              }),
              !signals[index].isRead else {
            return
        }

        do {
            let _: EmptyResponse = try await apiClient.send(
                APIRequest<EmptyResponse>(
                    path: "/api/strategy/signals/\(signalID.uuidString)/read",
                    method: .put
                )
            )
            guard self.activeUserID == activeUserID,
                  let currentIndex = signals.firstIndex(where: {
                      $0.id == signalID
                  }) else {
                return
            }
            signals[currentIndex].isRead = true
        } catch {
            // Keep the unread marker when persistence fails; APIClient shows the error.
        }
    }

    func activateReversalAlert(_ signalID: UUID) async {
        guard let apiClient,
              let activeUserID,
              signals.contains(where: { $0.id == signalID }) else {
            return
        }

        do {
            let response = try await apiClient.send(
                APIRequest<ReversalAlertMutationResponse>(
                    path: "/api/strategy/signals/\(signalID.uuidString)/reversal-alert",
                    method: .put
                )
            )
            guard self.activeUserID == activeUserID,
                  let index = signals.firstIndex(where: {
                      $0.id == signalID
                  }) else {
                return
            }
            signals[index].reversalAlertState =
                StrategySignal.ReversalAlertState(
                    rawValue: response.state
                ) ?? .active
            signals[index].reversalPatternName = nil
        } catch {
            // APIClient already presents the localized server error.
        }
    }

    func deleteSignal(_ signalID: UUID) async {
        guard let apiClient,
              let activeUserID,
              signals.contains(where: { $0.id == signalID }) else {
            return
        }

        do {
            let _: EmptyResponse = try await apiClient.send(
                APIRequest<EmptyResponse>(
                    path: "/api/strategy/signals/\(signalID.uuidString)",
                    method: .delete
                )
            )
            guard self.activeUserID == activeUserID else {
                return
            }
            signals.removeAll(where: { $0.id == signalID })
        } catch {
            // Keep the row when persistence fails; APIClient shows the error.
        }
    }

    private func loadFirstSignalPage(
        showsErrorToast: Bool
    ) async {
        guard let apiClient,
              let activeUserID,
              !isLoadingSignals else {
            return
        }

        signalRequestRevision += 1
        let revision = signalRequestRevision
        isLoadingSignals = true
        isLoadingMoreSignals = false
        signalLoadFailed = false
        defer {
            if signalRequestRevision == revision {
                isLoadingSignals = false
            }
        }

        do {
            async let preferences = apiClient.send(
                APIRequest<SignalNotificationPreferences>(
                    path: "/api/strategy/notification-preferences",
                    showsErrorToast: showsErrorToast
                )
            )
            let response = try await apiClient.send(
                APIRequest<StrategySignalPageResponse>(
                    path: "/api/strategy/signals",
                    showsErrorToast: showsErrorToast
                )
            )
            let loadedPreferences = try await preferences
            guard signalRequestRevision == revision,
                  self.activeUserID == activeUserID,
                  !Task.isCancelled else {
                return
            }
            signalNotificationPreferences = loadedPreferences
            hasLoadedSignalNotificationPreferences = true
            signals = response.items.filter {
                loadedPreferences.allows(interval: $0.interval)
            }
            if let pendingNotificationSignal {
                self.pendingNotificationSignal = nil
                restoreNotificationSignal(pendingNotificationSignal)
            }
            hasMoreSignals = response.hasNext
            nextSignalCursor = response.nextCursor
            hasLoadedSignals = true
            signalLoadFailed = false
            lastUpdated = .now
        } catch {
            guard signalRequestRevision == revision,
                  self.activeUserID == activeUserID,
                  !Task.isCancelled else {
                return
            }
            signalLoadFailed = true
        }
    }

    private func resetSignalFeed() {
        signalRequestRevision += 1
        signals.removeAll()
        hasLoadedSignals = false
        nextSignalCursor = nil
        hasMoreSignals = false
        signalLoadFailed = false
        isLoadingSignals = false
        isLoadingMoreSignals = false
    }

    private func restorePreferences(for userID: String) -> Bool {
        guard let preferences = watchlistStore?.load(for: userID) else {
            return false
        }

        activeQuoteAsset = Self.normalizedQuoteAsset(
            preferences.quoteAsset
        )
        watchlistIsCustomized = preferences.isCustomized
        applyPreferences(
            preferences,
            availableSymbols: preferences.orderedSymbols
        )
        return true
    }

    private func loadDefaultWatchlist(for userID: String) async {
        guard let apiClient else {
            return
        }

        do {
            let response = try await apiClient.send(
                APIRequest<DefaultMarketWatchlistResponse>(
                    path: "/api/market/watchlist/defaults",
                    showsErrorToast: false
                )
            )
            guard activeUserID == userID else {
                return
            }
            applyMarketConfiguration(
                response,
                storedPreferences: watchlistStore?.load(for: userID)
            )
            persistPreferences()
            updateRealtimeSubscriptions()
            await loadMarketTickerSnapshot()
        } catch {
            // Keep the last market configuration and retry next launch.
            updateRealtimeSubscriptions()
            await loadMarketTickerSnapshot()
        }
    }

    private func applyMarketConfiguration(
        _ response: DefaultMarketWatchlistResponse,
        storedPreferences: MarketWatchlistPreferences?
    ) {
        let quoteAsset = Self.normalizedQuoteAsset(response.quoteAsset)
        guard !quoteAsset.isEmpty else {
            return
        }

        activeQuoteAsset = quoteAsset
        let availableSymbols = Self.normalizedSymbols(
            response.availableSymbols,
            quoteAsset: quoteAsset
        )
        catalogSymbols = availableSymbols.sorted()
        catalogLoadedAt = .now
        catalogLoadFailed = false
        let defaults = Self.normalizedSymbols(
            response.symbols,
            quoteAsset: quoteAsset
        )

        if let storedPreferences,
           Self.normalizedQuoteAsset(
               storedPreferences.quoteAsset
           ) == quoteAsset,
           storedPreferences.isCustomized {
            watchlistIsCustomized = true
            applyPreferences(
                storedPreferences,
                availableSymbols: availableSymbols
            )
            return
        }

        watchlistIsCustomized = false
        applyDefaultSymbols(
            defaults,
            availableSymbols: availableSymbols,
            quoteAsset: quoteAsset
        )
    }

    private func applyPreferences(
        _ preferences: MarketWatchlistPreferences,
        availableSymbols: [String]
    ) {
        let quoteAsset = Self.normalizedQuoteAsset(
            preferences.quoteAsset
        )
        let normalizedAvailableSymbols = Self.normalizedSymbols(
            availableSymbols,
            quoteAsset: quoteAsset
        )
        let availableSet = Set(normalizedAvailableSymbols)
        let orderedSymbols = Self.normalizedSymbols(
            preferences.orderedSymbols,
            quoteAsset: quoteAsset
        ).filter(availableSet.contains)
        let visibleSymbols = Set(Self.normalizedSymbols(
            Array(preferences.visibleSymbols),
            quoteAsset: quoteAsset
        ))
        let existingBySymbol = Dictionary(
            uniqueKeysWithValues: markets.map { ($0.symbol, $0) }
        )
        var restoredMarkets: [MarketSnapshot] = []
        var restoredSymbols = Set<String>()

        for symbol in orderedSymbols {
            var market = existingBySymbol[symbol]
                ?? Self.placeholderMarket(
                    symbol: symbol,
                    quoteAsset: quoteAsset
                )
            market.isVisible = visibleSymbols.contains(symbol)
            market.isPinned = false
            restoredMarkets.append(market)
            restoredSymbols.insert(symbol)
        }

        for symbol in normalizedAvailableSymbols
        where !restoredSymbols.contains(symbol) {
            var market = existingBySymbol[symbol]
                ?? Self.placeholderMarket(
                    symbol: symbol,
                    quoteAsset: quoteAsset
                )
            market.isVisible = false
            market.isPinned = false
            restoredMarkets.append(market)
        }

        markets = restoredMarkets
        lastUpdated = .now
    }

    private func applyDefaultSymbols(
        _ symbols: [String],
        availableSymbols: [String],
        quoteAsset: String
    ) {
        let defaultSymbols = Self.normalizedSymbols(
            symbols,
            quoteAsset: quoteAsset
        )
        let defaultSymbolSet = Set(defaultSymbols)
        let existingBySymbol = Dictionary(
            uniqueKeysWithValues: markets.map { ($0.symbol, $0) }
        )

        var updatedMarkets = defaultSymbols.map { symbol in
            var market = existingBySymbol[symbol]
                ?? Self.placeholderMarket(
                    symbol: symbol,
                    quoteAsset: quoteAsset
                )
            market.isVisible = true
            market.isPinned = false
            return market
        }

        for symbol in availableSymbols
        where !defaultSymbolSet.contains(symbol) {
            var market = existingBySymbol[symbol]
                ?? Self.placeholderMarket(
                    symbol: symbol,
                    quoteAsset: quoteAsset
                )
            market.isVisible = false
            market.isPinned = false
            updatedMarkets.append(market)
        }

        markets = updatedMarkets
        lastUpdated = .now
    }

    private func persistPreferences(
        customized: Bool? = nil
    ) {
        if let customized {
            watchlistIsCustomized = customized
        }

        guard let activeUserID,
              let activeQuoteAsset,
              let watchlistStore else {
            return
        }

        watchlistStore.save(
            MarketWatchlistPreferences(
                quoteAsset: activeQuoteAsset,
                orderedSymbols: markets.map(\.symbol),
                visibleSymbols: Set(
                    markets.filter(\.isVisible).map(\.symbol)
                ),
                pinnedSymbols: [],
                isCustomized: watchlistIsCustomized
            ),
            for: activeUserID
        )
    }

    func restoreRealtimeSubscriptions() {
        updateRealtimeSubscriptions()
    }

    private func updateRealtimeSubscriptions() {
        guard let realtimeClient else {
            return
        }

        let visibleSymbols = markets
            .filter(\.isVisible)
            .map(\.symbol)
            .sorted()
        let candidates = [tradeTickerSymbol].compactMap { $0 }
            + searchTickerSymbols.sorted() + visibleSymbols
        var seen = Set<String>()
        let subscribedSymbols = Array(candidates.filter { seen.insert($0).inserted }
            .prefix(Self.maxRealtimeTickerSymbols))

        if subscribedSymbols.isEmpty {
            realtimeClient.unsubscribe(
                channels: ["market.ticker"]
            )
        } else {
            realtimeClient.subscribe([
                .marketTicker(symbols: subscribedSymbols),
            ])
        }
        realtimeClient.subscribe([
            .strategySignal(),
        ])
    }

    private func handleRealtimeMessage(
        _ message: RealtimeServerMessage
    ) {
        if message.type == "ready" {
            scheduleTickerSnapshotReload()
            return
        }

        switch message.channel {
        case "market.ticker":
            guard let payload = message.decodeData(
                as: MarketTickerPayload.self
            ) else {
                return
            }
            enqueueTickerUpdate(payload)

        case "strategy.signal":
            if message.event == "created",
               let payload = message.decodeData(
                   as: RealtimeStrategySignalEventPayload.self
               ) {
                applyStrategySignal(payload)
            } else if message.event == "reversalTriggered",
                      let payload = message.decodeData(
                          as: RealtimeReversalAlertEventPayload.self
                      ) {
                applyReversalAlert(payload)
            }

        default:
            break
        }
    }

    private func scheduleTickerSnapshotReload() {
        guard activeQuoteAsset != nil else {
            return
        }
        tickerSnapshotTask?.cancel()
        tickerSnapshotTask = Task { [weak self] in
            await self?.loadMarketTickerSnapshot()
        }
    }

    private func loadMarketTickerSnapshot() async {
        guard let apiClient,
              let activeQuoteAsset else {
            return
        }

        do {
            let response = try await apiClient.send(
                APIRequest<MarketTickersResponse>(
                    path: "/api/market/tickers",
                    showsErrorToast: false
                )
            )
            guard Self.normalizedQuoteAsset(response.quoteAsset)
                    == activeQuoteAsset else {
                return
            }
            applyTickerBatch(response.tickers)
        } catch {
            // The WebSocket increment remains active; retry on reconnect or pull-to-refresh.
        }
    }

    private func enqueueTickerUpdate(
        _ payload: MarketTickerPayload
    ) {
        if let pending = pendingTickerUpdates[payload.symbol],
           pending.eventTime > payload.eventTime {
            return
        }
        pendingTickerUpdates[payload.symbol] = payload

        guard tickerFlushTask == nil else {
            return
        }
        tickerFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else {
                return
            }
            self?.flushTickerUpdates()
        }
    }

    private func flushTickerUpdates() {
        tickerFlushTask = nil
        guard !pendingTickerUpdates.isEmpty else {
            return
        }
        let updates = Array(pendingTickerUpdates.values)
        pendingTickerUpdates.removeAll(keepingCapacity: true)
        applyTickerBatch(updates)
    }

    private func applyTickerBatch(
        _ updates: [MarketTickerPayload]
    ) {
        guard !updates.isEmpty else {
            return
        }

        var updatedMarkets = markets
        var latestTickers = latestTickerBySymbol
        let indices = Dictionary(
            uniqueKeysWithValues: updatedMarkets.indices.map {
                (updatedMarkets[$0].symbol, $0)
            }
        )
        var changed = false
        var realtimeCacheChanged = false

        for payload in updates {
            if let latest = latestTickers[payload.symbol],
               latest.eventTime > payload.eventTime {
                continue
            }
            latestTickers[payload.symbol] = payload
            realtimeCacheChanged = true

            guard let index = indices[payload.symbol] else {
                continue
            }
            let eventDate = Date(
                timeIntervalSince1970:
                    Double(payload.eventTime) / 1_000
            )
            if updatedMarkets[index].price > 0,
               eventDate < updatedMarkets[index].updatedAt {
                continue
            }

            updatedMarkets[index].price = payload.lastPrice
            updatedMarkets[index].quoteVolume24h =
                payload.quoteVolume24h
            updatedMarkets[index].turnoverText = Self.formattedTurnover(
                payload.quoteVolume24h
            )
            updatedMarkets[index].changePercent24h =
                payload.priceChangePercent24h
            updatedMarkets[index].updatedAt = eventDate
            changed = true
        }

        if realtimeCacheChanged {
            latestTickerBySymbol = latestTickers
            realtimeTickerRevision &+= 1
        }
        guard changed else {
            return
        }
        markets = updatedMarkets
        lastUpdated = .now
    }

    private func applyStrategySignal(
        _ payload: RealtimeStrategySignalEventPayload
    ) {
        guard hasLoadedSignalNotificationPreferences,
              signalNotificationPreferences.allows(interval: payload.interval),
              payload.strategyCode != "EMA21_55_MACD_GOLDEN_CROSS",
              payload.strategyCode != "EMA21_55_MACD_DEATH_CROSS",
              let id = UUID(uuidString: payload.id),
              let direction = StrategySignal.Direction(
                  rawValue: payload.direction
              ),
              !signals.contains(where: { $0.id == id }) else {
            return
        }

        let signal = StrategySignal(
            id: id,
            symbol: payload.symbol,
            interval: payload.interval,
            strategyName: strategyName(for: payload.strategyCode),
            direction: direction,
            triggerPrice: payload.price,
            triggeredAt: Date(
                timeIntervalSince1970:
                    Double(payload.signalTime) / 1_000
            ),
            isRead: false
        )
        signals.insert(signal, at: 0)
        lastUpdated = .now
    }

    private func applyReversalAlert(
        _ payload: RealtimeReversalAlertEventPayload
    ) {
        guard signalNotificationPreferences.allows(interval: payload.interval),
              let id = UUID(uuidString: payload.sourceSignalId),
              let index = signals.firstIndex(where: { $0.id == id }) else {
            return
        }
        signals[index].reversalAlertState = .triggered
        signals[index].reversalPatternName = payload.patternName
        lastUpdated = .now
    }

    func restoreNotificationSignal(_ signal: StrategySignal) {
        guard hasLoadedSignalNotificationPreferences else {
            pendingNotificationSignal = signal
            return
        }
        guard signalNotificationPreferences.allows(interval: signal.interval),
              !signals.contains(where: { $0.id == signal.id }) else {
            return
        }
        signals.insert(signal, at: 0)
        lastUpdated = .now
    }

    func marketSnapshot(forSymbol symbol: String) -> MarketSnapshot {
        if let market = markets.first(where: { $0.symbol == symbol }) {
            return market
        }
        return MarketSnapshot(
            symbol: symbol, quoteAsset: resolvedQuoteAsset(for: symbol),
            price: 0, changePercent24h: 0, updatedAt: .now,
            isVisible: containsInWatchlist(symbol)
        )
    }

    func marketSnapshot(for signal: StrategySignal) -> MarketSnapshot {
        if var market = markets.first(where: {
            $0.symbol.caseInsensitiveCompare(signal.symbol) == .orderedSame
        }) {
            if market.price <= 0, signal.triggerPrice > 0 {
                market.price = signal.triggerPrice
                market.updatedAt = signal.triggeredAt
            }
            return market
        }

        let symbol = signal.symbol.uppercased()
        let quoteAsset = resolvedQuoteAsset(for: symbol)
        return MarketSnapshot(
            symbol: symbol,
            quoteAsset: quoteAsset,
            price: signal.triggerPrice,
            changePercent24h: 0,
            updatedAt: signal.triggeredAt
        )
    }

    func usdcMarket(
        for notification: ReferenceTradeNotification
    ) -> MarketSnapshot? {
        guard let symbol = notification.summary.usdcSymbol else {
            return nil
        }
        return markets.first {
            $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame
                && $0.quoteAsset.caseInsensitiveCompare("USDC") == .orderedSame
        }
    }

    private func resolvedQuoteAsset(for symbol: String) -> String {
        if let activeQuoteAsset,
           symbol.hasSuffix(activeQuoteAsset) {
            return activeQuoteAsset
        }
        if symbol.hasSuffix("USDC") {
            return "USDC"
        }
        if symbol.hasSuffix("USDT") {
            return "USDT"
        }
        return activeQuoteAsset ?? ""
    }

    private func strategyName(for code: String) -> String {
        switch code {
        case "EMA21_55_MACD_GOLDEN_CROSS":
            return "EMA21/EMA55金叉"
        case "EMA21_55_MACD_DEATH_CROSS":
            return "EMA21/EMA55死叉"
        case "SUPER_EMA144_PULLBACK_REVERSAL":
            return "EMA144回踩"
        case "SUPER_TREND_PULLBACK_REVERSAL":
            return "SuperTrend回踩"
        default:
            return code
        }
    }

    private static func normalizedSymbols(
        _ symbols: [String],
        quoteAsset: String
    ) -> [String] {
        var seen = Set<String>()

        return symbols.compactMap { symbol in
            let normalized = symbol
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard !normalized.isEmpty else {
                return nil
            }
            guard normalized.hasSuffix(quoteAsset) else {
                return nil
            }
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }

    private static func normalizedQuoteAsset(
        _ quoteAsset: String
    ) -> String {
        quoteAsset
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    private static func formattedTurnover(_ quoteVolume: Double) -> String {
        DisplayNumber.turnover(quoteVolume)
    }

    private static func placeholderMarket(
        symbol: String,
        quoteAsset: String
    ) -> MarketSnapshot {
        MarketSnapshot(
            symbol: symbol,
            quoteAsset: quoteAsset,
            price: 0,
            changePercent24h: 0,
            updatedAt: .distantPast
        )
    }
}

private struct DefaultMarketWatchlistResponse: Decodable {
    let quoteAsset: String
    let symbols: [String]
    let availableSymbols: [String]
}

private struct MarketTickersResponse: Decodable {
    let quoteAsset: String
    let tickers: [MarketTickerPayload]
}

private struct StrategySignalPageResponse: Decodable {
    let size: Int
    let hasNext: Bool
    let nextCursor: String?
    let items: [StrategySignal]
}

private struct ReversalAlertMutationResponse: Decodable {
    let state: String
}

struct MarketSymbolCatalogResponse: Decodable {
    let quoteAsset: String
    let symbols: [String]
}
