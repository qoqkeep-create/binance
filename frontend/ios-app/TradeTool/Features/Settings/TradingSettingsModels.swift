import Combine
import Foundation

struct BinanceFuturesAccountSnapshot: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
    let status: String
    let syncStatus: String?
    let apiKeyMasked: String
    let quoteAsset: String
    let positionMode: String
    let canExecute: Bool
    let totalMarginBalance: Decimal
    let unrealizedProfit: Decimal
    let lastVerifiedAtMillis: Int64?
    let lastSyncedAtMillis: Int64?
    let degradedReason: String?
    let degradedMessage: String?

    var asset: String { quoteAsset }

    var refreshedAt: Date? {
        lastSyncedAtMillis.map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
        }
    }
}

struct TradingPositionSnapshot: Decodable, Equatable, Identifiable {
    let id: String
    let symbol: String
    let positionSide: String
    let generation: Int64
    let quantity: Decimal
    let entryPrice: Decimal
    let breakEvenPrice: Decimal
    let markPrice: Decimal
    let liquidationPrice: Decimal
    let leverage: Int
    let marginType: String
    let isolatedMargin: Decimal
    let unrealizedProfit: Decimal
    let exchangeUpdateMillis: Int64
    let makerCloseOrderId: String?
    let makerClosePrice: Decimal?
    let makerCloseStatus: String?
    let makerCloseCancelable: Bool?
    let takeProfitPrices: [Decimal]
    let stopLossPrices: [Decimal]
    let realizedPnl: Decimal
    let realizedPnlDetails: [TradingPositionRealizedFillSnapshot]
}

struct TradingPositionRealizedFillSnapshot: Decodable, Equatable, Identifiable {
    let id: String
    let side: String
    let price: Decimal
    let quantity: Decimal
    let realizedPnl: Decimal
    let commission: Decimal
    let commissionAsset: String
    let maker: Bool
    let tradeTimeMillis: Int64
}

struct TradingLeverageBracket: Decodable, Equatable {
    let initialLeverage: Int
    let notionalFloor: Double
    let notionalCap: Double
}

struct TradingLeverageSettings: Decodable, Equatable {
    let symbol: String
    let leverage: Int
    let maxLeverage: Int
    let maxNotionalValue: Double
    let brackets: [TradingLeverageBracket]

    func maximumNotional(for leverage: Int) -> Double {
        let eligible = brackets
            .filter { $0.initialLeverage >= leverage }
            .map(\.notionalCap)
            .filter { $0.isFinite && $0 > 0 }
        return eligible.max() ?? maxNotionalValue
    }
}

enum ExitStrategyStopMoveMode: String, Codable, CaseIterable {
    case none = "NONE"
    case fixedR = "FIXED_R"
    case trailingProfitR = "TRAILING_PROFIT_R"
}

struct TradingExitStrategyLevel: Codable, Equatable, Identifiable {
    let id: String?
    let level: Int
    let triggerR: Double
    let reducePercent: Double
    let moveStopMode: ExitStrategyStopMoveMode
    let moveStopR: Double?

    var stableID: String { id ?? "level-\(level)" }
}

struct TradingExitStrategy: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let revision: Int64
    let levels: [TradingExitStrategyLevel]
}

struct TradingLossLimitSettings: Codable, Equatable {
    let accountId: String
    let revision: Int64
    let currentPercentage: Int
    let currentAmount: Double
    let pendingPercentage: Int?
    let pendingAmount: Double?
    let pendingEffectiveAtMillis: Int64?
    let accountBalance: Double
    let settlementAsset: String

    var pendingEffectiveAt: Date? {
        pendingEffectiveAtMillis.map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
        }
    }

    static func previewAmount(
        balance: Double,
        percentage: Int
    ) -> Double {
        let raw = max(balance, 0) * Double(percentage) / 100
        guard raw.isFinite, raw > 0 else { return 0 }
        if raw < 20 {
            return raw.rounded()
        }
        let magnitude = floor(log10(raw))
        let factor = pow(10, magnitude)
        return (raw / factor).rounded() * factor
    }
}

enum TradingOrderType: String, Codable, CaseIterable, Identifiable {
    case makerOnly = "MAKER_ONLY"
    case limit = "LIMIT"
    case market = "MARKET"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .makerOnly: "只做Maker"
        case .limit: "限价单"
        case .market: "市价单"
        }
    }
}

enum TradingStopLossOrderType: String, Codable, CaseIterable, Identifiable {
    case limit = "LIMIT"
    case market = "MARKET"
    case none = "NONE"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .limit: "限价单"
        case .market: "市价单"
        case .none: "无止损"
        }
    }
}

struct TradingOrderSettings: Codable, Equatable {
    static let defaultValue = TradingOrderSettings(
        accountId: "",
        revision: 0,
        defaultExitStrategyId: nil,
        defaultExitStrategyName: nil,
        entryOrderType: .makerOnly,
        takeProfitOrderType: .makerOnly,
        stopLossOrderType: .market,
        fallbackMarketStopR: nil
    )

    let accountId: String
    let revision: Int64
    var defaultExitStrategyId: String?
    var defaultExitStrategyName: String?
    var entryOrderType: TradingOrderType
    var takeProfitOrderType: TradingOrderType
    var stopLossOrderType: TradingStopLossOrderType
    var fallbackMarketStopR: Double?

    func validated() throws -> TradingOrderSettings {
        if stopLossOrderType == .limit {
            guard let fallbackMarketStopR,
                  fallbackMarketStopR.isFinite,
                  fallbackMarketStopR > 1 else {
                throw TradingOrderSettingsError.invalidFallbackMarketStop
            }
        } else if fallbackMarketStopR != nil {
            throw TradingOrderSettingsError.unexpectedFallbackMarketStop
        }
        return self
    }
}

struct TradingEntryCommandResult: Decodable, Equatable {
    let commandId: String
    let status: String
    let planId: String?
    let planStatus: String?
    let symbol: String?
    let direction: String?
    let entryOrderType: String?
    let configuredRAmount: Double?
    let referenceEntryPrice: Double?
    let requestedEntryPrice: Double?
    let initialStopPrice: Double?
    let plannedQuantity: Double?
    let plannedRiskAmount: Double?
    let clientOrderId: String?
    let errorCode: String?
    let errorMessage: String?
}

enum TradingOrderSettingsError: LocalizedError {
    case invalidFallbackMarketStop
    case unexpectedFallbackMarketStop

    var errorDescription: String? {
        switch self {
        case .invalidFallbackMarketStop:
            return "保底市价止损必须大于 1R"
        case .unexpectedFallbackMarketStop:
            return "只有限价止损可以设置保底市价止损"
        }
    }
}

struct TradingRiskSettings: Codable, Equatable {
    static let defaultValue = TradingRiskSettings(
        isEnabled: false,
        takeProfitEnabled: true,
        stopLossEnabled: true,
        takeProfitPercent: 3,
        stopLossPercent: 1.5,
        stopLossAmount: 5,
        settlementAsset: "USDC"
    )

    var isEnabled: Bool
    var takeProfitEnabled: Bool
    var stopLossEnabled: Bool
    var takeProfitPercent: Double
    var stopLossPercent: Double
    var stopLossAmount: Double
    var settlementAsset: String

    func validated() throws -> TradingRiskSettings {
        guard !isEnabled || takeProfitEnabled || stopLossEnabled else {
            throw TradingRiskSettingsError.noProtectionSelected
        }
        guard takeProfitPercent.isFinite,
              (0.1...100).contains(takeProfitPercent) else {
            throw TradingRiskSettingsError.invalidTakeProfit
        }
        guard stopLossPercent.isFinite,
              (0.1...100).contains(stopLossPercent) else {
            throw TradingRiskSettingsError.invalidStopLoss
        }
        guard stopLossAmount.isFinite,
              (1...1_000_000).contains(stopLossAmount) else {
            throw TradingRiskSettingsError.invalidStopLossAmount
        }
        return self
    }
}

enum TradingRiskSettingsError: LocalizedError {
    case noProtectionSelected
    case invalidTakeProfit
    case invalidStopLoss
    case invalidStopLossAmount

    var errorDescription: String? {
        switch self {
        case .noProtectionSelected:
            return "至少开启一项止盈或止损保护"
        case .invalidTakeProfit:
            return "止盈比例应在 0.1% 到 100% 之间"
        case .invalidStopLoss:
            return "止损比例应在 0.1% 到 100% 之间"
        case .invalidStopLossAmount:
            return "单笔止损额应在 1 到 1,000,000 之间"
        }
    }
}

enum LegacyTradingSettingsScrubber {
    static func delete(
        bundleIdentifier: String,
        userID: String
    ) {
        UserDefaults.standard.removeObject(
            forKey: "\(bundleIdentifier).trading-risk.\(userID)"
        )
    }
}

struct TradingAccountAPIService {
    private struct BindRequest: Encodable {
        let apiKey: String
        let secretKey: String
    }

    private struct RiskPolicyResponse: Decodable {
        let accountId: String
        let revision: Int64
        let enabled: Bool
        let takeProfitEnabled: Bool
        let stopLossEnabled: Bool
        let takeProfitPercent: Double
        let stopLossPercent: Double
        let maxLossAmount: Double
        let settlementAsset: String
        let workingType: String

        var settings: TradingRiskSettings {
            TradingRiskSettings(
                isEnabled: enabled,
                takeProfitEnabled: takeProfitEnabled,
                stopLossEnabled: stopLossEnabled,
                takeProfitPercent: takeProfitPercent,
                stopLossPercent: stopLossPercent,
                stopLossAmount: maxLossAmount,
                settlementAsset: settlementAsset
            )
        }
    }

    private struct RiskPolicyRequest: Encodable {
        let enabled: Bool
        let takeProfitEnabled: Bool
        let stopLossEnabled: Bool
        let takeProfitPercent: Double
        let stopLossPercent: Double
        let maxLossAmount: Double
    }

    private struct ExitStrategyLevelRequest: Encodable {
        let triggerR: Double
        let reducePercent: Double
        let moveStopMode: ExitStrategyStopMoveMode
        let moveStopR: Double?
    }

    private struct ExitStrategyRequest: Encodable {
        let name: String
        let levels: [ExitStrategyLevelRequest]
    }

    private struct LossLimitRequest: Encodable {
        let percentage: Int
    }

    private struct OrderSettingsRequest: Encodable {
        let defaultExitStrategyId: String?
        let entryOrderType: TradingOrderType
        let takeProfitOrderType: TradingOrderType
        let stopLossOrderType: TradingStopLossOrderType
        let fallbackMarketStopR: Double?
    }

    private struct LeverageRequest: Encodable {
        let symbol: String
        let leverage: Int
    }

    private struct EntryOrderRequest: Encodable {
        let symbol: String
        let direction: String
        let entryPrice: Double?
        let stopPrice: Double
    }

    private let apiClient: any APIClient

    init(apiClient: any APIClient) {
        self.apiClient = apiClient
    }

    func accounts() async throws -> [BinanceFuturesAccountSnapshot] {
        try await apiClient.send(APIRequest(
            path: "/api/trading/accounts",
            showsErrorToast: false
        ))
    }

    func bind(
        apiKey: String,
        secretKey: String
    ) async throws -> BinanceFuturesAccountSnapshot {
        try await apiClient.send(APIRequest.json(
            path: "/api/trading/accounts",
            method: .post,
            body: BindRequest(apiKey: apiKey, secretKey: secretKey),
            showsErrorToast: false,
            timeoutInterval: 120
        ))
    }

    func refresh(
        accountID: String
    ) async throws -> BinanceFuturesAccountSnapshot {
        try await apiClient.send(APIRequest<BinanceFuturesAccountSnapshot>(
            path: "/api/trading/accounts/\(accountID)/refresh",
            method: .post,
            showsErrorToast: false,
            timeoutInterval: 20
        ))
    }

    func unbind(accountID: String) async throws {
        _ = try await apiClient.send(APIRequest<EmptyResponse>(
            path: "/api/trading/accounts/\(accountID)",
            method: .delete,
            showsErrorToast: false
        ))
    }

    func positions(
        accountID: String
    ) async throws -> [TradingPositionSnapshot] {
        try await apiClient.send(APIRequest(
            path: "/api/trading/accounts/\(accountID)/positions",
            showsErrorToast: false
        ))
    }

    func leverage(
        accountID: String,
        symbol: String
    ) async throws -> TradingLeverageSettings {
        try await apiClient.send(APIRequest(
            path: "/api/trading/accounts/\(accountID)/leverage?symbol=\(symbol)",
            showsErrorToast: false
        ))
    }

    func saveLeverage(
        accountID: String,
        symbol: String,
        leverage: Int
    ) async throws -> TradingLeverageSettings {
        try await apiClient.send(APIRequest.json(
            path: "/api/trading/accounts/\(accountID)/leverage",
            method: .put,
            body: LeverageRequest(symbol: symbol, leverage: leverage),
            showsErrorToast: false,
            timeoutInterval: 20
        ))
    }

    func riskSettings(
        accountID: String
    ) async throws -> TradingRiskSettings {
        let response: RiskPolicyResponse = try await apiClient.send(APIRequest(
            path: "/api/trading/accounts/\(accountID)/risk-policy",
            showsErrorToast: false
        ))
        return response.settings
    }

    func saveRiskSettings(
        _ settings: TradingRiskSettings,
        accountID: String
    ) async throws -> TradingRiskSettings {
        let validated = try settings.validated()
        let response: RiskPolicyResponse = try await apiClient.send(
            APIRequest.json(
                path: "/api/trading/accounts/\(accountID)/risk-policy",
                method: .put,
                body: RiskPolicyRequest(
                    enabled: validated.isEnabled,
                    takeProfitEnabled: validated.takeProfitEnabled,
                    stopLossEnabled: validated.stopLossEnabled,
                    takeProfitPercent: validated.takeProfitPercent,
                    stopLossPercent: validated.stopLossPercent,
                    maxLossAmount: validated.stopLossAmount
                ),
                showsErrorToast: false
            )
        )
        return response.settings
    }

    func exitStrategies(
        accountID: String
    ) async throws -> [TradingExitStrategy] {
        try await apiClient.send(APIRequest(
            path: "/api/trading/accounts/\(accountID)/exit-strategies",
            showsErrorToast: false
        ))
    }

    func saveExitStrategy(
        id: String?,
        name: String,
        levels: [TradingExitStrategyLevel],
        accountID: String
    ) async throws -> TradingExitStrategy {
        let request = ExitStrategyRequest(
            name: name,
            levels: levels.map {
                ExitStrategyLevelRequest(
                    triggerR: $0.triggerR,
                    reducePercent: $0.reducePercent,
                    moveStopMode: $0.moveStopMode,
                    moveStopR: $0.moveStopR
                )
            }
        )
        let path = id.map {
            "/api/trading/accounts/\(accountID)/exit-strategies/\($0)"
        } ?? "/api/trading/accounts/\(accountID)/exit-strategies"
        return try await apiClient.send(APIRequest.json(
            path: path,
            method: id == nil ? .post : .put,
            body: request,
            showsErrorToast: false
        ))
    }

    func deleteExitStrategy(
        id: String,
        accountID: String
    ) async throws {
        _ = try await apiClient.send(APIRequest<EmptyResponse>(
            path: "/api/trading/accounts/\(accountID)/exit-strategies/\(id)",
            method: .delete,
            showsErrorToast: false
        ))
    }

    func lossLimit(
        accountID: String
    ) async throws -> TradingLossLimitSettings {
        try await apiClient.send(APIRequest(
            path: "/api/trading/accounts/\(accountID)/loss-limit",
            showsErrorToast: false
        ))
    }

    func saveLossLimit(
        percentage: Int,
        accountID: String
    ) async throws -> TradingLossLimitSettings {
        try await apiClient.send(APIRequest.json(
            path: "/api/trading/accounts/\(accountID)/loss-limit",
            method: .put,
            body: LossLimitRequest(percentage: percentage),
            showsErrorToast: false
        ))
    }

    func orderSettings(
        accountID: String
    ) async throws -> TradingOrderSettings {
        try await apiClient.send(APIRequest(
            path: "/api/trading/accounts/\(accountID)/order-settings",
            showsErrorToast: false
        ))
    }

    func saveOrderSettings(
        _ settings: TradingOrderSettings,
        accountID: String
    ) async throws -> TradingOrderSettings {
        let validated = try settings.validated()
        return try await apiClient.send(APIRequest.json(
            path: "/api/trading/accounts/\(accountID)/order-settings",
            method: .put,
            body: OrderSettingsRequest(
                defaultExitStrategyId: validated.defaultExitStrategyId,
                entryOrderType: validated.entryOrderType,
                takeProfitOrderType: validated.takeProfitOrderType,
                stopLossOrderType: validated.stopLossOrderType,
                fallbackMarketStopR: validated.fallbackMarketStopR
            ),
            showsErrorToast: false
        ))
    }

    func createEntry(
        accountID: String,
        symbol: String,
        direction: String,
        entryPrice: Double?,
        stopPrice: Double,
        idempotencyKey: String
    ) async throws -> TradingEntryCommandResult {
        try await apiClient.send(APIRequest.json(
            path: "/api/trading/accounts/\(accountID)/orders",
            method: .post,
            body: EntryOrderRequest(
                symbol: symbol,
                direction: direction,
                entryPrice: entryPrice,
                stopPrice: stopPrice
            ),
            headers: ["Idempotency-Key": idempotencyKey],
            showsErrorToast: false,
            timeoutInterval: 20
        ))
    }

    func entryCommand(
        accountID: String,
        commandID: String
    ) async throws -> TradingEntryCommandResult {
        try await apiClient.send(APIRequest(
            path: "/api/trading/accounts/\(accountID)/commands/\(commandID)",
            showsErrorToast: false
        ))
    }
}

@MainActor
final class SettingsAccountViewModel: ObservableObject {
    @Published private(set) var isRefreshing = false
    @Published private(set) var snapshot: BinanceFuturesAccountSnapshot?
    @Published private(set) var riskSettings = TradingRiskSettings.defaultValue
    @Published private(set) var exitStrategies: [TradingExitStrategy] = []
    @Published private(set) var lossLimit: TradingLossLimitSettings?
    @Published private(set) var orderSettings: TradingOrderSettings?
    @Published private(set) var leverageSettings: TradingLeverageSettings?

    private let accountService: TradingAccountAPIService

    var isBound: Bool { snapshot != nil }
    var maskedAPIKey: String? { snapshot?.apiKeyMasked }
    var canSubmitEntry: Bool {
        snapshot?.canExecute == true
    }
    var entryReadinessMessage: String {
        guard let snapshot else { return "请先绑定 Binance API" }
        if snapshot.status.uppercased() != "ACTIVE" {
            return "交易账户状态异常（\(snapshot.status)）"
        }
        let syncStatus = snapshot.syncStatus?.uppercased() ?? "UNKNOWN"
        if syncStatus != "SYNCED" {
            return snapshot.degradedMessage
                ?? "账户同步尚未完成（\(syncStatus)）"
        }
        return "账户暂不可下单，请刷新后重试"
    }

    init(apiClient: any APIClient) {
        accountService = TradingAccountAPIService(apiClient: apiClient)
    }

    func load() async throws {
        snapshot = nil
        riskSettings = .defaultValue
        exitStrategies = []
        lossLimit = nil
        orderSettings = nil
        leverageSettings = nil
        snapshot = try await accountService.accounts().first
        if let accountID = snapshot?.id {
            riskSettings = try await accountService.riskSettings(
                accountID: accountID
            )
            exitStrategies = try await accountService.exitStrategies(
                accountID: accountID
            )
            lossLimit = try await accountService.lossLimit(
                accountID: accountID
            )
            orderSettings = try await accountService.orderSettings(
                accountID: accountID
            )
        } else {
            riskSettings = .defaultValue
        }
    }

    func loadOrderSettingsContext() async throws {
        snapshot = try await accountService.accounts().first
        exitStrategies = []
        orderSettings = nil
        lossLimit = nil
        guard let accountID = snapshot?.id else { return }

        async let strategies = accountService.exitStrategies(
            accountID: accountID
        )
        async let settings = accountService.orderSettings(
            accountID: accountID
        )
        async let currentLossLimit = accountService.lossLimit(
            accountID: accountID
        )
        exitStrategies = try await strategies
        orderSettings = try await settings
        lossLimit = try await currentLossLimit
    }

    func refreshExecutionReadiness() async throws {
        snapshot = try await accountService.accounts().first
    }

    func bind(
        apiKey: String,
        secretKey: String
    ) async throws {
        let normalizedAPIKey = apiKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedSecretKey = secretKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedAPIKey.isEmpty, !normalizedSecretKey.isEmpty else {
            throw APIError.business(
                code: nil,
                message: "请输入 API Key 和 Secret Key"
            )
        }

        isRefreshing = true
        defer { isRefreshing = false }
        snapshot = try await accountService.bind(
            apiKey: normalizedAPIKey,
            secretKey: normalizedSecretKey
        )
        if let accountID = snapshot?.id {
            riskSettings = try await accountService.riskSettings(
                accountID: accountID
            )
            exitStrategies = try await accountService.exitStrategies(
                accountID: accountID
            )
            lossLimit = try await accountService.lossLimit(
                accountID: accountID
            )
            orderSettings = try await accountService.orderSettings(
                accountID: accountID
            )
        }
    }

    func refresh() async throws {
        guard !isRefreshing, let accountID = snapshot?.id else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        snapshot = try await accountService.refresh(accountID: accountID)
        lossLimit = try await accountService.lossLimit(accountID: accountID)
    }

    func unbind() async throws {
        guard let accountID = snapshot?.id else { return }
        try await accountService.unbind(accountID: accountID)
        snapshot = nil
        riskSettings = .defaultValue
        exitStrategies = []
        lossLimit = nil
        orderSettings = nil
        leverageSettings = nil
    }

    func saveRiskSettings(
        _ settings: TradingRiskSettings
    ) async throws -> TradingRiskSettings {
        guard let accountID = snapshot?.id else {
            throw APIError.business(
                code: nil,
                message: "请先绑定 Binance API"
            )
        }
        let saved = try await accountService.saveRiskSettings(
            settings,
            accountID: accountID
        )
        riskSettings = saved
        return saved
    }

    func saveExitStrategy(
        id: String?,
        name: String,
        levels: [TradingExitStrategyLevel]
    ) async throws {
        guard let accountID = snapshot?.id else {
            throw APIError.business(code: nil, message: "请先绑定 Binance API")
        }
        let saved = try await accountService.saveExitStrategy(
            id: id,
            name: name,
            levels: levels,
            accountID: accountID
        )
        if let index = exitStrategies.firstIndex(where: { $0.id == saved.id }) {
            exitStrategies[index] = saved
        } else {
            exitStrategies.append(saved)
        }
    }

    func deleteExitStrategy(id: String) async throws {
        guard let accountID = snapshot?.id else {
            throw APIError.business(code: nil, message: "请先绑定 Binance API")
        }
        try await accountService.deleteExitStrategy(
            id: id,
            accountID: accountID
        )
        exitStrategies.removeAll { $0.id == id }
        if orderSettings?.defaultExitStrategyId == id {
            orderSettings?.defaultExitStrategyId = nil
            orderSettings?.defaultExitStrategyName = nil
        }
    }

    func saveLossLimit(
        percentage: Int
    ) async throws -> TradingLossLimitSettings {
        guard let accountID = snapshot?.id else {
            throw APIError.business(code: nil, message: "请先绑定 Binance API")
        }
        let saved = try await accountService.saveLossLimit(
            percentage: percentage,
            accountID: accountID
        )
        lossLimit = saved
        return saved
    }

    func saveOrderSettings(
        _ settings: TradingOrderSettings
    ) async throws -> TradingOrderSettings {
        guard let accountID = snapshot?.id else {
            throw APIError.business(code: nil, message: "请先绑定 Binance API")
        }
        let saved = try await accountService.saveOrderSettings(
            settings,
            accountID: accountID
        )
        orderSettings = saved
        return saved
    }

    func loadLeverage(symbol: String) async throws {
        guard let accountID = snapshot?.id else {
            throw APIError.business(code: nil, message: "请先绑定 Binance API")
        }
        leverageSettings = try await accountService.leverage(
            accountID: accountID,
            symbol: symbol
        )
    }

    func saveLeverage(
        symbol: String,
        leverage: Int
    ) async throws -> TradingLeverageSettings {
        guard let accountID = snapshot?.id else {
            throw APIError.business(code: nil, message: "请先绑定 Binance API")
        }
        let saved = try await accountService.saveLeverage(
            accountID: accountID,
            symbol: symbol,
            leverage: leverage
        )
        leverageSettings = saved
        return saved
    }

    func submitEntry(
        symbol: String,
        direction: String,
        entryPrice: Double?,
        stopPrice: Double,
        idempotencyKey: String
    ) async throws -> TradingEntryCommandResult {
        guard let accountID = snapshot?.id else {
            throw APIError.business(code: nil, message: "请先绑定 Binance API")
        }
        guard canSubmitEntry else {
            throw APIError.business(
                code: nil,
                message: "账户尚未完成监听与对账，暂时无法下单"
            )
        }
        let accepted = try await accountService.createEntry(
            accountID: accountID,
            symbol: symbol,
            direction: direction,
            entryPrice: entryPrice,
            stopPrice: stopPrice,
            idempotencyKey: idempotencyKey
        )
        return try await awaitEntryCommand(
            accepted,
            accountID: accountID
        )
    }

    private func awaitEntryCommand(
        _ accepted: TradingEntryCommandResult,
        accountID: String
    ) async throws -> TradingEntryCommandResult {
        var current = accepted
        let terminal = Set([
            "SUCCEEDED", "FAILED_KNOWN", "UNRESOLVED",
        ])
        for _ in 0..<30 {
            if terminal.contains(current.status) {
                return current
            }
            try await Task.sleep(for: .milliseconds(500))
            current = try await accountService.entryCommand(
                accountID: accountID,
                commandID: accepted.commandId
            )
        }
        return current
    }
}
