import Foundation
import UIKit
import UserNotifications

enum PushInstallationIdentity {
    private static let installationIDDefaultsKey = "pushInstallationID"
    private static let apnsEnvironmentInfoKey =
        "TradeToolAPNsEnvironment"

    static func current(
        userDefaults: UserDefaults = .standard
    ) -> String {
        if let stored = userDefaults.string(
            forKey: installationIDDefaultsKey
        ), UUID(uuidString: stored) != nil {
            return stored
        }
        let generated = UUID().uuidString.lowercased()
        userDefaults.set(generated, forKey: installationIDDefaultsKey)
        return generated
    }

    static var apnsEnvironment: String? {
        normalizedAPNsEnvironment(
            Bundle.main.object(
                forInfoDictionaryKey: apnsEnvironmentInfoKey
            )
        )
    }

    static var bundleIdentifier: String? {
        guard let value = Bundle.main.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func normalizedAPNsEnvironment(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        switch value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased() {
        case "development", "sandbox":
            return "sandbox"
        case "production":
            return "production"
        default:
            return nil
        }
    }
}

@MainActor
final class AppContainer: ObservableObject {
    let id = UUID()
    let baseURL: URL
    private let networkSession: URLSession
    let toastCenter: AppToastCenter
    let apiClient: any APIClient
    let usdt: USDTStore
    let authStore: AuthStore
    let realtimeClient: RealtimeClient
    let dashboardViewModel: DashboardViewModel
    let strategySignalNotifications: StrategySignalNotificationManager

    init(
        baseURL: URL = AppEnvironment.apiBaseURL,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.waibao2025.trade.integrated"
    ) {
        self.baseURL = baseURL
        let networkSession = URLSession(configuration: .default)
        self.networkSession = networkSession
        let sessionEvents = NotificationCenter()
        let toastCenter = AppToastCenter()
        LegacyBinanceCredentialScrubber.deleteAll(
            bundleIdentifier: bundleIdentifier
        )
        let legacySessionStore = KeychainAuthSessionStore(
            service: bundleIdentifier
        )
        try? legacySessionStore.delete()
        let sessionStore: any AuthSessionStoring
#if DEBUG && targetEnvironment(macCatalyst)
        if ProcessInfo.processInfo.arguments.contains("--integration-ephemeral-session") {
            sessionStore = EphemeralDevelopmentSessionStore()
        } else {
            sessionStore = KeychainAuthSessionStore(service: AuthSessionKeychainNamespace.service(bundleIdentifier: bundleIdentifier, baseURL: baseURL))
        }
#else
        sessionStore = KeychainAuthSessionStore(service: AuthSessionKeychainNamespace.service(bundleIdentifier: bundleIdentifier, baseURL: baseURL))
#endif

        self.toastCenter = toastCenter
        var apiClient = URLSessionAPIClient(
            baseURL: baseURL,
            session: networkSession,
            interceptors: [
                CommonHeadersInterceptor(),
                BearerTokenInterceptor {
                    try? sessionStore.load()?.accessToken
                },
                HTTPStatusInterceptor(),
            ],
            errorReporter: toastCenter,
            notificationCenter: sessionEvents,
            readRecovery: APIReadRecovery(notificationCenter: sessionEvents)
        )
        let refresher = MobileSessionRefresher(baseURL: baseURL, network: networkSession, store: sessionStore)
        apiClient.refreshAccessToken = { try await refresher.refresh() }
        self.apiClient = apiClient
        self.usdt = USDTStore(api: apiClient)
        let realtimeClient = RealtimeClient(
            baseURL: baseURL,
            session: networkSession,
            notificationCenter: sessionEvents
        ) {
            try? sessionStore.load()?.accessToken
        }
        realtimeClient.refreshAccessToken = { try await refresher.refresh() }
        self.realtimeClient = realtimeClient
        let strategySignalNotifications = StrategySignalNotificationManager(
            apiClient: apiClient
        )
        self.strategySignalNotifications = strategySignalNotifications
        dashboardViewModel = DashboardViewModel(
            apiClient: apiClient,
            realtimeClient: realtimeClient,
            watchlistStore: UserDefaultsMarketWatchlistStore(
                service: bundleIdentifier
            )
        )
        authStore = AuthStore(
            service: APIAuthenticationService(
                apiClient: apiClient,
                sessionStore: sessionStore
            ),
            toastCenter: toastCenter,
            notificationCenter: sessionEvents
        )
    }

    func prepareForServerChange() {
        dashboardViewModel.stopRealtime()
        realtimeClient.disconnect()
        strategySignalNotifications.deactivateSession()
        networkSession.invalidateAndCancel()
    }
}

enum SignalNotificationDestination: Equatable, Sendable {
    case strategy(StrategySignal)
    case chart(symbol: String, interval: String, tradingMode: String?)
    case positions(tradingMode: String?)
}

struct SignalNotificationNavigationRequest: Equatable, Sendable {
    let id: UUID
    let destination: SignalNotificationDestination
    var recipientUserID: String? = nil
}

@MainActor
final class StrategySignalNotificationManager:
    NSObject,
    ObservableObject,
    UNUserNotificationCenterDelegate {

    static let enabledDefaultsKey = "notificationsEnabled"

    @Published private(set) var navigationRequest:
        SignalNotificationNavigationRequest?
    @Published private(set) var signalReceiptRevision = 0
    @Published private(set) var isEnabled: Bool
    @Published private(set) var systemNotificationsDenied = false

    private let notificationCenter: UNUserNotificationCenter
    private let userDefaults: UserDefaults
    private let apiClient: any APIClient
    private let installationID: String
    private var isSessionActive = false
    private var acceptsLaunchNavigation = true
    private var deviceTokenObserver: NSObjectProtocol?
    private var registrationFailureObserver: NSObjectProtocol?
    private var registrationTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var systemRegistrationTask: Task<Void, Never>?
    private var systemRegistrationAttempt = 0

    init(
        apiClient: any APIClient,
        notificationCenter: UNUserNotificationCenter = .current(),
        userDefaults: UserDefaults = .standard
    ) {
        self.apiClient = apiClient
        self.notificationCenter = notificationCenter
        self.userDefaults = userDefaults
        isEnabled = userDefaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
        installationID = PushInstallationIdentity.current(
            userDefaults: userDefaults
        )
        super.init()
        notificationCenter.delegate = self
        deviceTokenObserver = NotificationCenter.default.addObserver(
            forName: .apnsDeviceTokenReceived,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let token = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.receivedDeviceToken(token)
            }
        }
        registrationFailureObserver = NotificationCenter.default.addObserver(
            forName: .apnsRegistrationFailed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
#if DEBUG
            if let error = notification.object as? Error {
                print("APNs registration failed: \(error.localizedDescription)")
            }
#endif
            Task { @MainActor [weak self] in
                self?.retrySystemRegistration()
            }
        }
    }

    deinit {
        if let deviceTokenObserver {
            NotificationCenter.default.removeObserver(deviceTokenObserver)
        }
        if let registrationFailureObserver {
            NotificationCenter.default.removeObserver(
                registrationFailureObserver
            )
        }
        registrationTask?.cancel()
        authorizationTask?.cancel()
        systemRegistrationTask?.cancel()
    }

    func activateSession() {
        isSessionActive = true
        acceptsLaunchNavigation = true
        if isEnabled {
            scheduleAuthorization()
        } else {
            scheduleUnregistration()
        }
    }

    func deactivateSession() {
        isSessionActive = false
        acceptsLaunchNavigation = false
        navigationRequest = nil
        registrationTask?.cancel()
        registrationTask = nil
        authorizationTask?.cancel()
        authorizationTask = nil
        systemRegistrationTask?.cancel()
        systemRegistrationTask = nil
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled { navigationRequest = nil }
        userDefaults.set(enabled, forKey: Self.enabledDefaultsKey)
        isEnabled = enabled
        if enabled {
            registrationTask?.cancel()
            registrationTask = nil
            scheduleAuthorization()
        } else {
            authorizationTask?.cancel()
            authorizationTask = nil
            systemRegistrationTask?.cancel()
            systemRegistrationTask = nil
            scheduleUnregistration()
            notificationCenter.removeAllDeliveredNotifications()
        }
    }

    /// Recheck Settings changes without prompting merely because this page opens.
    func refreshAuthorizationStatus() async {
        await enableRemoteNotifications(requestingPermission: false)
    }

    private func scheduleAuthorization() {
        authorizationTask?.cancel()
        authorizationTask = Task { [weak self] in
            await self?.enableRemoteNotifications()
        }
    }

    func consumeNavigationRequest(_ id: UUID) {
        guard navigationRequest?.id == id else { return }
        navigationRequest = nil
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        let route = userInfo["route"] as? String
        guard await isEnabled else { return [] }
        guard Self.allowsPresentation(route: route, source: userInfo["source"] as? String) else { return [] }
        if route == "strategy.signal" {
            await recordSignalReceipt()
        }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let destination = Self.destination(
            from: response.notification.request.content.userInfo
        )
        let recipient = response.notification.request.content.userInfo["recipientUserId"] as? String
        completionHandler()
        guard let destination else { return }

        Task { @MainActor [weak self] in
            self?.handleNavigation(destination, recipientUserID: recipient)
        }
    }

    private func handleNavigation(_ destination: SignalNotificationDestination, recipientUserID: String?) {
        // Preserve a cold-launch tap until session restoration creates MainAppView.
        guard isEnabled, isSessionActive || acceptsLaunchNavigation else { return }
        if case .strategy = destination { recordSignalReceipt() }
        navigationRequest = SignalNotificationNavigationRequest(
            id: UUID(), destination: destination, recipientUserID: recipientUserID)
    }

    nonisolated static func destination(
        from userInfo: [AnyHashable: Any]
    ) -> SignalNotificationDestination? {
        guard allowsPresentation(route: userInfo["route"] as? String, source: userInfo["source"] as? String) else { return nil }
        switch userInfo["route"] as? String {
        case "trade.notification":
            let mode = userInfo["tradingMode"] as? String
            let tradingMode = mode.flatMap { ["ordinary", "lead"].contains($0) ? $0 : nil }
            if let symbol = chartSymbol(userInfo["symbol"]) {
                return .chart(symbol: symbol, interval: userInfo["interval"] as? String ?? "1h", tradingMode: tradingMode)
            }
            return .positions(tradingMode: tradingMode)
        case "strategy.signal":
            guard let signal = signal(from: userInfo) else { return nil }
            return .strategy(signal)
        default:
            return nil
        }
    }

    nonisolated static func allowsPresentation(route: String?, source: String? = nil) -> Bool {
        let source = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return route != "reference.trade.notification"
            && !["external", "tradingview", "tv"].contains(source ?? "")
    }

    nonisolated private static func chartSymbol(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let symbol = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard symbol.range(of: "^[A-Z0-9]{1,24}USDT$", options: .regularExpression) != nil else { return nil }
        return symbol
    }

    private func recordSignalReceipt() {
        guard isSessionActive else { return }
        signalReceiptRevision += 1
    }

    nonisolated static func signal(
        from userInfo: [AnyHashable: Any]
    ) -> StrategySignal? {
        guard allowsPresentation(route: userInfo["route"] as? String, source: userInfo["source"] as? String),
              userInfo["route"] as? String == "strategy.signal",
              let idValue = userInfo["id"] as? String,
              let id = UUID(uuidString: idValue),
              let symbol = chartSymbol(userInfo["symbol"]),
              let strategyName = userInfo["strategyName"] as? String,
              let directionValue = userInfo["direction"] as? String,
              let direction = StrategySignal.Direction(
                  rawValue: directionValue
              ),
              let triggerPrice = number(userInfo["triggerPrice"]),
              let triggeredAt = number(userInfo["triggeredAt"]) else {
            return nil
        }

        return StrategySignal(
            id: id,
            symbol: symbol,
            interval: userInfo["interval"] as? String
                ?? MarketKlineInterval.oneHour.rawValue,
            strategyName: strategyName,
            direction: direction,
            triggerPrice: triggerPrice,
            triggeredAt: Date(timeIntervalSince1970: triggeredAt)
        )
    }

    nonisolated private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        return (value as? NSNumber)?.doubleValue
    }

    private func enableRemoteNotifications(requestingPermission: Bool = true) async {
        let settings = await notificationCenter.notificationSettings()
        guard !Task.isCancelled else { return }
        var status = settings.authorizationStatus
        systemNotificationsDenied = status == .denied
        guard isEnabled, isSessionActive else { return }
        if status == .notDetermined, requestingPermission {
            do {
                _ = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
                status = await notificationCenter.notificationSettings().authorizationStatus
            } catch { return }
        }
        guard !Task.isCancelled, isEnabled, isSessionActive else { return }
        systemNotificationsDenied = status == .denied
        guard [.authorized, .provisional, .ephemeral].contains(status) else {
            if status == .denied { scheduleUnregistration() }
            return
        }

        UIApplication.shared.registerForRemoteNotifications()
    }

    private func receivedDeviceToken(_ token: String) {
        let normalized = token.lowercased()
        systemRegistrationAttempt = 0
        systemRegistrationTask?.cancel()
        systemRegistrationTask = nil
        guard isEnabled, isSessionActive else { return }
        scheduleRegistration(deviceToken: normalized)
    }

    private func retrySystemRegistration() {
        guard isEnabled,
              isSessionActive,
              systemRegistrationAttempt < 3 else {
            return
        }
        systemRegistrationAttempt += 1
        let delay = UInt64(systemRegistrationAttempt * 2) * 1_000_000_000
        systemRegistrationTask?.cancel()
        systemRegistrationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self,
                  !Task.isCancelled,
                  self.isEnabled,
                  self.isSessionActive else {
                return
            }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private func scheduleRegistration(deviceToken: String) {
        guard let environment = PushInstallationIdentity.apnsEnvironment,
              let bundleIdentifier =
                PushInstallationIdentity.bundleIdentifier else {
#if DEBUG
            print(
                "APNs registration skipped: missing signed environment "
                    + "or bundle identifier"
            )
#endif
            return
        }
        registrationTask?.cancel()
        registrationTask = Task { [weak self] in
            guard let self else { return }
            let body = PushDeviceRegistrationBody(
                installationId: installationID,
                deviceToken: deviceToken,
                environment: environment,
                bundleIdentifier: bundleIdentifier
            )
            await retryingRequest {
                let request: APIRequest<EmptyResponse> = try .json(
                    path: "/api/push/devices/register",
                    method: .post,
                    body: body,
                    showsErrorToast: false,
                    timeoutInterval: 10
                )
                _ = try await self.apiClient.send(request)
            }
        }
    }

    private func scheduleUnregistration() {
        guard isSessionActive else { return }
        registrationTask?.cancel()
        registrationTask = Task { [weak self] in
            guard let self else { return }
            let body = PushDeviceIdentityBody(
                installationId: installationID
            )
            await retryingRequest {
                let request: APIRequest<EmptyResponse> = try .json(
                    path: "/api/push/devices/unregister",
                    method: .post,
                    body: body,
                    showsErrorToast: false,
                    timeoutInterval: 10
                )
                _ = try await self.apiClient.send(request)
            }
        }
    }

    private func retryingRequest(
        operation: @escaping () async throws -> Void
    ) async {
        let delays: [UInt64] = [0, 1_000_000_000, 3_000_000_000]
        for delay in delays {
            guard !Task.isCancelled else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            do {
                try await operation()
                return
            } catch {
                continue
            }
        }
    }

}

private struct PushDeviceRegistrationBody: Encodable {
    let installationId: String
    let deviceToken: String
    let environment: String
    let bundleIdentifier: String
}

private struct PushDeviceIdentityBody: Encodable {
    let installationId: String
}

enum AppEnvironment {
    static var apiBaseURL: URL {
        if let configuredURL = Bundle.main.object(
            forInfoDictionaryKey: "API_BASE_URL"
        ) as? String {
            let trimmedURL = configuredURL.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmedURL.isEmpty,
               !trimmedURL.contains("$("),
               let url = URL(string: trimmedURL),
               url.scheme != nil,
               url.host != nil {
                logResolvedURL(url)
                return url
            }
        }

        let fallbackURL = URL(string: fallbackURLString)!
        logResolvedURL(fallbackURL)
        return fallbackURL
    }

    private static var fallbackURLString: String {
        #if DEBUG
        return "https://47.80.22.243/integrated/"
        #else
        return "https://47.80.22.243/integrated/"
        #endif
    }

    private static func logResolvedURL(_ url: URL) {
        #if DEBUG
        print("TradeTool API_BASE_URL = \(url.absoluteString)")
        #endif
    }
}
