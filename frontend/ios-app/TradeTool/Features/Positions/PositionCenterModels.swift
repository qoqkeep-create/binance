import Combine
import Foundation

struct PositionCenterAccountSummary: Decodable, Equatable {
    let id: String
    let quoteAsset: String
    let syncStatus: String?
}

struct PositionCenterSnapshot: Decodable, Equatable {
    let accountId: String
    let quoteAsset: String
    let totalMarginBalance: Decimal
    let syncStatus: String?
    let updatedAtMillis: Int64
    let positions: [TradingPositionSnapshot]
    let limitOrders: [TradingLimitOrderSnapshot]
    let historyPositions: [TradingPositionHistorySnapshot]
    let historyTruncated: Bool
}

struct TradingPositionLiveMetrics: Equatable {
    let currentPrice: Decimal
    let notional: Decimal
    let margin: Decimal
    let unrealizedProfit: Decimal
    let roe: Decimal
    let marginRatio: Decimal

    init(
        position: TradingPositionSnapshot,
        latestPrice: Decimal?,
        totalMarginBalance: Decimal = 0
    ) {
        let price = latestPrice.flatMap { $0 > 0 ? $0 : nil }
            ?? position.markPrice
        let quantity = position.quantity < 0
            ? -position.quantity
            : position.quantity
        let isShort = position.positionSide.uppercased() == "SHORT"
            || (position.positionSide.uppercased() != "LONG"
                && position.quantity < 0)
        let priceDelta = isShort
            ? position.entryPrice - price
            : price - position.entryPrice
        let liveNotional = quantity * price
        let resolvedMargin = liveNotional
            / Decimal(max(position.leverage, 1))

        currentPrice = price
        notional = liveNotional
        margin = resolvedMargin
        unrealizedProfit = priceDelta * quantity
        roe = resolvedMargin > 0
            ? unrealizedProfit / resolvedMargin * 100
            : 0
        marginRatio = totalMarginBalance > 0
            ? resolvedMargin / totalMarginBalance * 100
            : 0
    }
}

struct TradingLimitOrderSnapshot: Decodable, Equatable, Identifiable {
    let id: String
    let purpose: String
    let symbol: String
    let side: String
    let positionSide: String
    let orderType: String
    let quantity: Decimal
    let price: Decimal
    let triggerPrice: Decimal
    let executedQuantity: Decimal
    let averagePrice: Decimal
    let reduceOnly: Bool
    let status: String
    let exchangeStatus: String?
    let exchangeUpdateMillis: Int64
    let entryCancelable: Bool
}

private struct PositionCenterCommandResult: Decodable {
    let commandId: String
    let status: String
    let errorMessage: String?
}

private struct ClosePositionRequest: Encodable {
    let orderType: String
}

struct TradingPositionHistorySnapshot: Decodable, Equatable, Identifiable {
    let id: String
    let symbol: String
    let positionSide: String
    let direction: String
    let maximumQuantity: Decimal
    let entryPrice: Decimal
    let closePrice: Decimal
    let realizedPnl: Decimal
    let fees: [TradingFeeAmountSnapshot]
    let fillCount: Int
    let openedAtMillis: Int64
    let closedAtMillis: Int64
}

struct TradingFeeAmountSnapshot: Decodable, Equatable {
    let asset: String
    let amount: Decimal
}

private struct PositionCenterAPIService {
    let apiClient: any APIClient

    func accounts() async throws -> [PositionCenterAccountSummary] {
        try await apiClient.send(APIRequest(
            path: "/api/trading/accounts",
            showsErrorToast: false
        ))
    }

    func snapshot(
        accountID: String
    ) async throws -> PositionCenterSnapshot {
        try await apiClient.send(APIRequest(
            path: "/api/trading/accounts/\(accountID)/position-center",
            queryItems: [
                URLQueryItem(name: "historyLimit", value: "100")
            ],
            showsErrorToast: false
        ))
    }

    func cancelEntryOrder(
        accountID: String,
        orderID: String
    ) async throws -> PositionCenterCommandResult {
        try await apiClient.send(APIRequest(
            path: "/api/trading/accounts/\(accountID)/entry-orders/\(orderID)",
            method: .delete,
            headers: ["Idempotency-Key": "cancel-entry:\(orderID)"],
            showsErrorToast: false,
            timeoutInterval: 20
        ))
    }

    func closePosition(
        accountID: String,
        positionID: String,
        orderType: String,
        idempotencyKey: String
    ) async throws -> PositionCenterCommandResult {
        try await apiClient.send(APIRequest.json(
            path: "/api/trading/accounts/\(accountID)/positions/\(positionID)/close",
            method: .post,
            body: ClosePositionRequest(orderType: orderType),
            headers: ["Idempotency-Key": idempotencyKey],
            showsErrorToast: false,
            timeoutInterval: 20
        ))
    }

    func cancelMakerClose(
        accountID: String,
        positionID: String,
        orderID: String
    ) async throws -> PositionCenterCommandResult {
        try await apiClient.send(APIRequest(
            path: "/api/trading/accounts/\(accountID)/positions/\(positionID)/maker-close-orders/\(orderID)",
            method: .delete,
            headers: ["Idempotency-Key": "cancel-maker:\(orderID)"],
            showsErrorToast: false,
            timeoutInterval: 20
        ))
    }

    func command(
        accountID: String,
        commandID: String
    ) async throws -> PositionCenterCommandResult {
        try await apiClient.send(APIRequest(
            path: "/api/trading/accounts/\(accountID)/commands/\(commandID)",
            showsErrorToast: false
        ))
    }
}

@MainActor
final class PositionCenterViewModel: ObservableObject {
    @Published private(set) var account: PositionCenterAccountSummary?
    @Published private(set) var snapshot: PositionCenterSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var cancellingOrderIDs: Set<String> = []
    @Published private(set) var actingPositionIDs: Set<String> = []
    @Published private(set) var latestPriceBySymbol: [String: Decimal] = [:]

    private let service: PositionCenterAPIService
    private let realtimeClient: RealtimeClient
    private let restoreMarketSubscriptions: () -> Void
    private let tradingChannels = [
        "trading.account",
        "trading.position",
        "trading.order",
        "trading.fill",
    ]
    private let tickerChannel = "market.ticker"
    private let klineChannel = "market.kline"
    private var latestPriceEventTimeBySymbol: [String: Int64] = [:]
    private var isMonitoringRealtime = false
    private var tradingReloadTask: Task<Void, Never>?
    private var tradingReloadID: UUID?
    private var tradingReloadRequested = false
    private var accountLookupRequested = false

    init(
        apiClient: any APIClient,
        realtimeClient: RealtimeClient,
        restoreMarketSubscriptions: @escaping () -> Void = {}
    ) {
        service = PositionCenterAPIService(apiClient: apiClient)
        self.realtimeClient = realtimeClient
        self.restoreMarketSubscriptions = restoreMarketSubscriptions
    }

    func monitor() async {
        await reload(forceAccountLookup: true, showsLoading: true)
        guard account != nil, !Task.isCancelled else { return }

        isMonitoringRealtime = true
        realtimeClient.subscribe([
            .tradingAccount,
            .tradingPosition,
            .tradingOrder,
            .tradingFill,
        ])
        updateMarketSubscriptions()
        defer {
            isMonitoringRealtime = false
            tradingReloadTask?.cancel()
            tradingReloadTask = nil
            tradingReloadID = nil
            tradingReloadRequested = false
            accountLookupRequested = false
            realtimeClient.unsubscribe(
                channels: tradingChannels + [tickerChannel, klineChannel]
            )
            restoreMarketSubscriptions()
        }

        let events = realtimeClient.events(
            bufferingPolicy: .bufferingNewest(100)
        )
        for await message in events {
            guard !Task.isCancelled else { break }
            guard message.type == "event",
                  let channel = message.channel else {
                continue
            }

            if channel == tickerChannel,
               let payload = message.decodeData(
                   as: MarketTickerPayload.self
               ) {
                applyTicker(payload)
                continue
            }

            if channel == klineChannel,
               let payload = message.decodeData(
                   as: RealtimeKlineEventPayload.self
               ) {
                applyKline(payload)
                continue
            }

            guard tradingChannels.contains(channel) else { continue }
            scheduleTradingReload(
                forceAccountLookup: channel == "trading.account"
            )
        }
    }

    func refresh() async {
        await reload(forceAccountLookup: true, showsLoading: snapshot == nil)
    }

    func isCancelling(_ orderID: String) -> Bool {
        cancellingOrderIDs.contains(orderID)
    }

    func isActing(on positionID: String) -> Bool {
        actingPositionIDs.contains(positionID)
    }

    func latestPrice(
        for position: TradingPositionSnapshot
    ) -> Decimal? {
        latestPriceBySymbol[position.symbol.uppercased()]
    }

    func liveMarginBalance() -> Decimal {
        guard let snapshot else { return 0 }
        return snapshot.positions.reduce(snapshot.totalMarginBalance) {
            balance, position in
            guard let latestPrice = latestPrice(for: position) else {
                return balance
            }
            let metrics = TradingPositionLiveMetrics(
                position: position,
                latestPrice: latestPrice
            )
            return balance + metrics.unrealizedProfit
                - position.unrealizedProfit
        }
    }

    func applyTicker(_ payload: MarketTickerPayload) {
        applyPrice(
            payload.lastPrice,
            symbol: payload.symbol,
            eventTime: payload.eventTime
        )
    }

    func applyKline(_ payload: RealtimeKlineEventPayload) {
        guard payload.interval == "1m" else {
            return
        }
        applyPrice(
            payload.closePrice,
            symbol: payload.symbol,
            eventTime: payload.eventTime
        )
    }

    private func applyPrice(
        _ price: Double,
        symbol rawSymbol: String,
        eventTime: Int64
    ) {
        guard price.isFinite, price > 0, eventTime >= 0 else {
            return
        }
        let symbol = rawSymbol.uppercased()
        guard snapshot?.positions.contains(where: {
            $0.symbol.uppercased() == symbol
        }) == true else {
            return
        }
        if let latestEventTime = latestPriceEventTimeBySymbol[symbol],
           latestEventTime > eventTime {
            return
        }
        latestPriceEventTimeBySymbol[symbol] = eventTime
        latestPriceBySymbol[symbol] = Decimal(
            string: String(price),
            locale: Locale(identifier: "en_US_POSIX")
        ) ?? Decimal(price)
    }

    private func scheduleTradingReload(forceAccountLookup: Bool) {
        tradingReloadRequested = true
        accountLookupRequested = accountLookupRequested || forceAccountLookup
        guard tradingReloadTask == nil else { return }

        let reloadID = UUID()
        tradingReloadID = reloadID
        tradingReloadTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  self.tradingReloadID == reloadID,
                  self.tradingReloadRequested {
                self.tradingReloadRequested = false
                let lookupAccount = self.accountLookupRequested
                self.accountLookupRequested = false
                await self.reload(
                    forceAccountLookup: lookupAccount,
                    showsLoading: false
                )
            }
            guard self.tradingReloadID == reloadID else { return }
            self.tradingReloadID = nil
            self.tradingReloadTask = nil
        }
    }

    func closePosition(
        _ position: TradingPositionSnapshot,
        orderType: String
    ) async throws {
        guard let account else {
            throw APIError.business(code: nil, message: "请先绑定 Binance API")
        }
        guard actingPositionIDs.insert(position.id).inserted else { return }
        defer { actingPositionIDs.remove(position.id) }

        let result = try await service.closePosition(
            accountID: account.id,
            positionID: position.id,
            orderType: orderType,
            idempotencyKey: "close:\(position.id):\(UUID().uuidString)"
        )
        try await waitForSuccess(result, accountID: account.id)
        await reload(forceAccountLookup: false, showsLoading: false)
    }

    func cancelMakerClose(
        _ position: TradingPositionSnapshot
    ) async throws {
        guard position.makerCloseCancelable == true,
              let orderID = position.makerCloseOrderId else {
            throw APIError.business(
                code: nil,
                message: "Maker 平仓委托已结束，请刷新后重试"
            )
        }
        guard let account else {
            throw APIError.business(code: nil, message: "请先绑定 Binance API")
        }
        guard actingPositionIDs.insert(position.id).inserted else { return }
        defer { actingPositionIDs.remove(position.id) }

        let result = try await service.cancelMakerClose(
            accountID: account.id,
            positionID: position.id,
            orderID: orderID
        )
        try await waitForSuccess(result, accountID: account.id)
        await reload(forceAccountLookup: false, showsLoading: false)
    }

    func cancelEntryOrder(_ order: TradingLimitOrderSnapshot) async throws {
        guard order.entryCancelable else {
            throw APIError.business(
                code: nil,
                message: "该订单不支持撤单"
            )
        }
        guard let account else {
            throw APIError.business(code: nil, message: "请先绑定 Binance API")
        }
        guard cancellingOrderIDs.insert(order.id).inserted else { return }
        defer { cancellingOrderIDs.remove(order.id) }

        let result = try await service.cancelEntryOrder(
            accountID: account.id,
            orderID: order.id
        )
        try await waitForSuccess(result, accountID: account.id)
        await reload(forceAccountLookup: false, showsLoading: false)
    }

    private func waitForSuccess(
        _ initial: PositionCenterCommandResult,
        accountID: String
    ) async throws {
        var result = initial
        let terminal = Set(["SUCCEEDED", "FAILED_KNOWN", "UNRESOLVED"])
        for _ in 0..<30 where !terminal.contains(result.status) {
            try await Task.sleep(for: .milliseconds(500))
            result = try await service.command(
                accountID: accountID,
                commandID: result.commandId
            )
        }
        guard result.status == "SUCCEEDED" else {
            throw APIError.business(
                code: result.status,
                message: result.errorMessage ?? "订单操作尚未完成，请刷新后重试"
            )
        }
    }

    private func reload(
        forceAccountLookup: Bool,
        showsLoading: Bool
    ) async {
        if showsLoading {
            isLoading = true
        }
        defer {
            if showsLoading {
                isLoading = false
            }
        }

        do {
            if forceAccountLookup || account == nil {
                account = try await service.accounts().first
            }
            guard let account else {
                snapshot = nil
                errorMessage = nil
                return
            }
            let loadedSnapshot = try await service.snapshot(
                accountID: account.id
            )
            guard !Task.isCancelled else { return }
            snapshot = loadedSnapshot
            prunePriceState(for: loadedSnapshot.positions)
            if isMonitoringRealtime {
                updateMarketSubscriptions()
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            let apiError = APIError.map(error)
            guard apiError.shouldPresent else { return }
            errorMessage = apiError.localizedDescription
        }
    }

    private func updateMarketSubscriptions() {
        let symbols = Array(Set(
            snapshot?.positions.map { $0.symbol.uppercased() } ?? []
        )).sorted()
        if symbols.isEmpty {
            realtimeClient.unsubscribe(channels: [
                tickerChannel, klineChannel,
            ])
        } else {
            realtimeClient.subscribe([
                .marketKline(symbols: symbols, intervals: ["1m"]),
                .marketTicker(symbols: symbols),
            ])
        }
    }

    private func prunePriceState(
        for positions: [TradingPositionSnapshot]
    ) {
        let activeSymbols = Set(
            positions.map { $0.symbol.uppercased() }
        )
        latestPriceBySymbol = latestPriceBySymbol.filter {
            activeSymbols.contains($0.key)
        }
        latestPriceEventTimeBySymbol =
            latestPriceEventTimeBySymbol.filter {
                activeSymbols.contains($0.key)
            }
    }
}
