import Combine
import Foundation
import Network

enum RealtimeLatency: Equatable {
    case measuring, unavailable
    case measured(Double)

    enum Quality: String { case good, fair, poor }
    var quality: Quality {
        switch self {
        case .measuring: .fair
        case .unavailable: .poor
        case .measured(let milliseconds): milliseconds < 200 ? .good : milliseconds < 500 ? .fair : .poor
        }
    }
    var text: String {
        switch self {
        case .measuring: "测量中"
        case .unavailable: "-- ms"
        case .measured(let milliseconds):
            milliseconds.isFinite ? "\(Int(min(999, max(0, milliseconds.rounded())))) ms" : "999 ms"
        }
    }
}

/// Matches application ping/pong by identity and measures only with a monotonic clock.
struct RealtimeLatencyTracker {
    static let sampleInterval: Duration = .seconds(2)
    static let timeout: Duration = .seconds(3)
    private var pending: (id: String, sentAt: ContinuousClock.Instant)?
    private var samples: [Double] = []
    private(set) var reading: RealtimeLatency = .measuring
    var isPending: Bool { pending != nil }

    @discardableResult
    mutating func begin(id: String, at now: ContinuousClock.Instant) -> Bool {
        guard pending == nil else { return false }
        pending = (id, now)
        return true
    }
    mutating func receive(id: String?, at now: ContinuousClock.Instant) {
        guard let pending, pending.id == id else { return }
        let elapsed = pending.sentAt.duration(to: now)
        guard elapsed >= .zero, elapsed < Self.timeout else { expire(at: now); return }
        self.pending = nil
        samples.append(Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15)
        samples = Array(samples.suffix(3))
        reading = .measured(ServerNetworkResult(samplesMilliseconds: samples).medianMilliseconds)
    }
    mutating func expire(at now: ContinuousClock.Instant) {
        guard let pending, pending.sentAt.duration(to: now) >= Self.timeout else { return }
        reset(to: .unavailable)
    }
    mutating func reset(to reading: RealtimeLatency = .measuring) {
        pending = nil
        samples.removeAll()
        self.reading = reading
    }
}

enum RealtimeConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

struct RealtimeSubscription: Codable, Equatable, Sendable {
    let channel: String
    let filters: [String: [String]]

    static func compatible(_ subscriptions: [RealtimeSubscription], capabilities: Set<String>) -> [RealtimeSubscription] {
        subscriptions.filter { $0.channel != "market.history" || capabilities.contains("market.history") }
    }

    static func marketKline(
        symbols: [String],
        intervals: [String] = ["1m"]
    ) -> RealtimeSubscription {
        RealtimeSubscription(
            channel: "market.kline",
            filters: [
                "symbols": symbols,
                "intervals": intervals,
            ]
        )
    }

    static func marketTicker(
        symbols: [String]
    ) -> RealtimeSubscription {
        RealtimeSubscription(
            channel: "market.ticker",
            filters: [
                "symbols": symbols,
            ]
        )
    }

    static func marketHistory(symbols: [String], intervals: [String]) -> RealtimeSubscription {
        RealtimeSubscription(channel: "market.history", filters: ["symbols": symbols, "intervals": intervals])
    }

    static func strategySignal(
        symbols: [String] = []
    ) -> RealtimeSubscription {
        var filters: [String: [String]] = [:]
        if !symbols.isEmpty {
            filters["symbols"] = symbols
        }
        return RealtimeSubscription(
            channel: "strategy.signal",
            filters: filters
        )
    }

    static var tradingAccount: RealtimeSubscription {
        trading(channel: "trading.account")
    }

    static var tradingPosition: RealtimeSubscription {
        trading(channel: "trading.position")
    }

    static var tradingOrder: RealtimeSubscription {
        trading(channel: "trading.order")
    }

    static var tradingFill: RealtimeSubscription {
        trading(channel: "trading.fill")
    }

    private static func trading(
        channel: String
    ) -> RealtimeSubscription {
        RealtimeSubscription(channel: channel, filters: [:])
    }
}

struct RealtimeServerMessage: Decodable, Sendable {
    let version: Int
    let type: String
    let requestId: String?
    let channel: String?
    let event: String?
    let key: String?
    let sequence: Int64?
    let timestamp: Int64
    let data: JSONValue?
    let error: RealtimeServerError?

    func decodeData<Value: Decodable>(
        as type: Value.Type
    ) -> Value? {
        guard let data,
              let encoded = try? JSONEncoder().encode(data) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: encoded)
    }
}

struct RealtimeServerError: Decodable, Sendable {
    let code: String
    let message: String
}

struct RealtimeSubscriptionAcknowledgement: Decodable {
    let subscriptions: [RealtimeSubscription]
}

struct MarketHistoryReadyPayload: Decodable {
    let symbol: String
    let interval: String
    let kind: String
    let beforeOpenTime: Int64?
}

struct RealtimeKlineEventPayload: Decodable, Sendable {
    let symbol: String
    let contractType: String
    let interval: String
    let eventTime: Int64
    let openTime: Int64
    let closeTime: Int64
    let openPrice: Double
    let highPrice: Double
    let lowPrice: Double
    let closePrice: Double
    let volume: Double
    let quoteVolume: Double
    let closed: Bool

    var candle: MarketCandle {
        MarketCandle(
            openTime: openTime,
            closeTime: closeTime,
            openPrice: openPrice,
            highPrice: highPrice,
            lowPrice: lowPrice,
            closePrice: closePrice,
            volume: volume,
            quoteVolume: quoteVolume
        )
    }
}

struct MarketTickerPayload: Decodable, Sendable {
    let symbol: String
    let lastPrice: Double
    let quoteVolume24h: Double
    let priceChangePercent24h: Double
    let eventTime: Int64
}

struct RealtimeStrategySignalEventPayload: Decodable, Sendable {
    let id: String
    let symbol: String
    let interval: String
    let strategyCode: String
    let direction: String
    let signalTime: Int64
    let price: Double
}

struct RealtimeReversalAlertEventPayload: Decodable, Sendable {
    let sourceSignalId: String
    let symbol: String
    let interval: String
    let direction: String
    let signalTime: Int64
    let triggerOpenTime: Int64
    let price: Double
    let patternCode: String
    let patternName: String
}

enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var integerValue: Int64? {
        guard case let .number(value) = self else {
            return nil
        }
        return Int64(value)
    }

    subscript(key: String) -> JSONValue? {
        guard case let .object(value) = self else {
            return nil
        }
        return value[key]
    }
}

@MainActor
final class RealtimeClient: ObservableObject {
    @Published private(set) var state: RealtimeConnectionState = .disconnected
    @Published private(set) var latency: RealtimeLatency = .unavailable
    @Published private(set) var isTestingLatency = false
    private var latencyTracker = RealtimeLatencyTracker()
    private var monitorsLatency = false
    #if DEBUG
    private var fixtureLatencyTask: Task<Void, Never>?
    #endif
    private var pathMonitor: NWPathMonitor?
    private var pathGeneration = UUID()
    private var pathSignature = ""
    private var networkAvailable = true
    private var serverCapabilities: Set<String> = []

    private let baseURL: URL
    private let session: URLSession
    var refreshAccessToken: (() async throws -> String)?
    private let tokenProvider: () -> String?
    private let notificationCenter: NotificationCenter

    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var subscriptions: [String: RealtimeSubscription] = [:]
    private var observers: [
        UUID: RealtimeEventObserver
    ] = [:]

    private var shouldStayConnected = false
    private var reconnectAttempt = 0
    private var heartbeatInterval: Duration = .seconds(20)
    private var serverTimeout: Duration = .seconds(60)
    private var lastServerMessageAt = ContinuousClock.now

    init(
        baseURL: URL,
        session: URLSession = .shared,
        notificationCenter: NotificationCenter = .default,
        tokenProvider: @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        self.notificationCenter = notificationCenter
    }

    func events(
        bufferingPolicy:
            AsyncStream<RealtimeServerMessage>
            .Continuation.BufferingPolicy = .unbounded,
        onDropped: (() -> Void)? = nil
    ) -> AsyncStream<RealtimeServerMessage> {
        let observerID = UUID()
        return AsyncStream(
            bufferingPolicy: bufferingPolicy
        ) { continuation in
            observers[observerID] = RealtimeEventObserver(
                continuation: continuation,
                onDropped: onDropped
            )
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.observers.removeValue(forKey: observerID)
                }
            }
        }
    }

    func connect() {
        shouldStayConnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        openConnectionIfNeeded()
    }

    func disconnect() {
        setLatencyMonitoring(false)
        shouldStayConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        closeCurrentConnection(
            code: .goingAway,
            reason: "Client disconnected"
        )
        reconnectAttempt = 0
    }

    func reconnect() {
        shouldStayConnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        closeCurrentConnection(
            code: .goingAway,
            reason: "Client reconnecting"
        )
        openConnectionIfNeeded()
    }

    func setLatencyMonitoring(_ enabled: Bool) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--web-parity-fixture") {
            fixtureLatencyTask?.cancel()
            fixtureLatencyTask = nil
            isTestingLatency = false
            let args = ProcessInfo.processInfo.arguments
            latency = args.contains("--fixture-latency-unavailable") ? .unavailable
                : args.contains("--fixture-latency-overflow") ? .measured(1_520)
                : args.contains("--fixture-latency-measuring") ? .measuring
                : args.contains("--fixture-latency-slow") ? .measured(780)
                : args.contains("--fixture-latency-fair") ? .measured(280) : .measured(86)
            return
        }
        #endif
        guard monitorsLatency != enabled else { return }
        monitorsLatency = enabled
        resetLatency()
        pathMonitor?.cancel()
        pathMonitor = nil
        pathGeneration = UUID()
        pathSignature = ""
        networkAvailable = true
        if enabled {
            let generation = pathGeneration
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                let signature = "\(path.status):\(path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name).sorted())"
                Task { @MainActor [weak self] in
                    guard let self, self.pathGeneration == generation, self.monitorsLatency,
                          self.pathSignature != signature else { return }
                    self.pathSignature = signature
                    self.networkAvailable = available
                    self.resetLatency()
                    if self.state == .connected { self.startHeartbeat() }
                }
            }
            pathMonitor = monitor
            monitor.start(queue: DispatchQueue(label: "tradetool.latency-path"))
        }
        if state == .connected { startHeartbeat() }
    }

    private func resetLatency() {
        isTestingLatency = false
        latencyTracker.reset(to: state == .connected && networkAvailable ? .measuring : .unavailable)
        latency = latencyTracker.reading
    }

    func requestLatencyTest() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--web-parity-fixture") {
            guard fixtureLatencyTask == nil else { return }
            isTestingLatency = true
            fixtureLatencyTask = Task { [weak self] in
                let delay: Duration = ProcessInfo.processInfo.arguments.contains("--fixture-latency-refresh-slow")
                    ? .seconds(6) : .milliseconds(800)
                do { try await Task.sleep(for: delay) } catch { return }
                self?.latency = .measured(86)
                self?.isTestingLatency = false
                self?.fixtureLatencyTask = nil
            }
            return
        }
        #endif
        guard monitorsLatency else { return }
        guard networkAvailable else { resetLatency(); return }
        guard state == .connected else {
            isTestingLatency = true
            connect()
            return
        }
        guard !isTestingLatency else { return }
        isTestingLatency = true
        // A manual reading starts fresh; late replies to the previous sample are ignored.
        latencyTracker.reset(to: latency)
        startHeartbeat()
    }

    func subscribe(_ desiredSubscriptions: [RealtimeSubscription]) {
        var changed: [RealtimeSubscription] = []

        for subscription in desiredSubscriptions {
            if subscriptions[subscription.channel] != subscription {
                subscriptions[subscription.channel] = subscription
                changed.append(subscription)
            }
        }

        guard state == .connected, !changed.isEmpty else {
            return
        }
        Task { [weak self] in
            await self?.sendSubscriptionChange(
                type: "subscribe",
                subscriptions: changed
            )
        }
    }

    func unsubscribe(channels: [String]) {
        let removed = channels.compactMap { channel -> RealtimeSubscription? in
            subscriptions.removeValue(forKey: channel)
        }

        guard state == .connected, !removed.isEmpty else {
            return
        }
        Task { [weak self] in
            await self?.sendSubscriptionChange(
                type: "unsubscribe",
                subscriptions: removed
            )
        }
    }

    private func openConnectionIfNeeded() {
        // Re-entering the screen must preserve an existing connection and its heartbeat.
        guard socketTask == nil else { return }
        guard shouldStayConnected,
              let token = tokenProvider(),
              !token.isEmpty,
              let websocketURL = websocketURL else {
            state = .disconnected
            return
        }

        var request = URLRequest(url: websocketURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ios", forHTTPHeaderField: "X-Platform")
        request.setValue(NativeTradingMode.current, forHTTPHeaderField: "X-Trading-Mode")

        let task = session.webSocketTask(with: request)
        socketTask = task
        state = .connecting
        lastServerMessageAt = ContinuousClock.now
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveMessages(from: task)
        }
    }

    private var websocketURL: URL? {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        default:
            return nil
        }

        let basePath = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty
            ? "/ws/v1"
            : "/\(basePath)/ws/v1"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func receiveMessages(
        from task: URLSessionWebSocketTask
    ) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                guard socketTask === task else {
                    return
                }
                try await handle(message)
            }
        } catch {
            handleTransportEnd(task: task, error: error)
        }
    }

    private func handle(
        _ message: URLSessionWebSocketTask.Message
    ) async throws {
        let data: Data

        switch message {
        case let .data(value):
            data = value
        case let .string(value):
            guard let value = value.data(using: .utf8) else {
                return
            }
            data = value
        @unknown default:
            return
        }

        let serverMessage = try JSONDecoder().decode(
            RealtimeServerMessage.self,
            from: data
        )
        guard serverMessage.version == 1 else {
            return
        }

        lastServerMessageAt = ContinuousClock.now

        switch serverMessage.type {
        case "ready":
            state = .connected
            if case let .array(values) = serverMessage.data?["capabilities"] {
                serverCapabilities = Set(values.compactMap { value in
                    if case let .string(text) = value { return text }
                    return nil
                })
            } else {
                serverCapabilities = []
            }
            resetLatency()
            updateHeartbeatConfiguration(from: serverMessage)
            startHeartbeat()
            await sendSubscriptionChange(
                type: "subscribe",
                subscriptions: Array(subscriptions.values)
            )
            publish(serverMessage)

        case "pong":
            if monitorsLatency {
                let wasPending = latencyTracker.isPending
                latencyTracker.receive(id: serverMessage.requestId, at: .now)
                latency = latencyTracker.reading
                if wasPending && !latencyTracker.isPending { isTestingLatency = false }
            }
            reconnectAttempt = 0

        case "ack":
            reconnectAttempt = 0
            publish(serverMessage)

        case "event":
            reconnectAttempt = 0
            publish(serverMessage)

        case "error":
            if serverMessage.error?.code == "UNAUTHORIZED" {
                expireSession()
            }

        default:
            break
        }
    }

    private func publish(
        _ message: RealtimeServerMessage
    ) {
        for observer in observers.values {
            switch observer.continuation.yield(message) {
            case .enqueued:
                break
            case .dropped:
                observer.onDropped?()
            case .terminated:
                break
            @unknown default:
                break
            }
        }
    }

    private func updateHeartbeatConfiguration(
        from message: RealtimeServerMessage
    ) {
        if let milliseconds = message.data?[
            "heartbeatIntervalMillis"
        ]?.integerValue {
            heartbeatInterval = .milliseconds(
                max(1_000, milliseconds)
            )
        }
        if let milliseconds = message.data?[
            "clientTimeoutMillis"
        ]?.integerValue {
            serverTimeout = .milliseconds(
                max(2_000, milliseconds)
            )
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }

            var nextPing = ContinuousClock.now
            while !Task.isCancelled, state == .connected {
                let now = ContinuousClock.now
                if monitorsLatency {
                    let wasPending = latencyTracker.isPending
                    latencyTracker.expire(at: now)
                    latency = latencyTracker.reading
                    if wasPending && !latencyTracker.isPending { isTestingLatency = false }
                }

                if ContinuousClock.now - lastServerMessageAt > serverTimeout {
                    reconnect()
                    return
                }

                if now >= nextPing, !monitorsLatency || (networkAvailable && !latencyTracker.isPending) {
                  let requestID = UUID().uuidString
                  if monitorsLatency { latencyTracker.begin(id: requestID, at: now) }
                  await send(
                    ClientMessage(
                        type: "ping",
                        requestId: requestID,
                        subscriptions: nil,
                        timestamp: Int64(
                            Date().timeIntervalSince1970 * 1_000
                        )
                    )
                  )
                  nextPing = now.advanced(by: monitorsLatency ? RealtimeLatencyTracker.sampleInterval : heartbeatInterval)
                }
                do { try await Task.sleep(for: monitorsLatency ? .milliseconds(250) : heartbeatInterval) }
                catch { return }
            }
        }
    }

    private func sendSubscriptionChange(
        type: String,
        subscriptions: [RealtimeSubscription]
    ) async {
        let subscriptions = RealtimeSubscription.compatible(subscriptions, capabilities: serverCapabilities)
        guard !subscriptions.isEmpty else {
            return
        }
        await send(
            ClientMessage(
                type: type,
                requestId: UUID().uuidString,
                subscriptions: subscriptions,
                timestamp: Int64(
                    Date().timeIntervalSince1970 * 1_000
                )
            )
        )
    }

    private func send(_ message: ClientMessage) async {
        guard let task = socketTask else {
            return
        }
        do {
            let data = try JSONEncoder().encode(message)
            guard let payload = String(data: data, encoding: .utf8) else {
                return
            }
            try await task.send(.string(payload))
        } catch {
            handleTransportEnd(task: task, error: error)
        }
    }

    private func handleTransportEnd(
        task: URLSessionWebSocketTask,
        error: Error
    ) {
        guard socketTask === task else {
            return
        }

        let closeCode = task.closeCode
        task.cancel(
            with: .goingAway,
            reason: "Transport ended".data(using: .utf8)
        )
        receiveTask?.cancel()
        socketTask = nil
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        state = .disconnected
        resetLatency()

        if closeCode.rawValue == 4_401 {
            Task { [weak self] in
                guard let self else { return }
                do {
                    guard let refreshAccessToken else { self.expireSession(); return }
                    _ = try await refreshAccessToken()
                    self.scheduleReconnect()
                } catch { self.expireSession() }
            }
            return
        }

        #if DEBUG
        print("TradeTool WebSocket disconnected: \(error.localizedDescription)")
        #endif

        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldStayConnected, reconnectTask == nil else {
            return
        }

        reconnectAttempt += 1
        let exponent = min(reconnectAttempt - 1, 5)
        let baseDelay = min(pow(2.0, Double(exponent)), 30)
        let jitter = Double.random(in: 0...0.35)
        let delay = Duration.seconds(baseDelay + jitter)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            self?.reconnectTask = nil
            self?.openConnectionIfNeeded()
        }
    }

    private func closeCurrentConnection(
        code: URLSessionWebSocketTask.CloseCode,
        reason: String
    ) {
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socketTask?.cancel(
            with: code,
            reason: reason.data(using: .utf8)
        )
        socketTask = nil
        state = .disconnected
        resetLatency()
    }

    private func expireSession() {
        shouldStayConnected = false
        closeCurrentConnection(
            code: .policyViolation,
            reason: "Session expired"
        )
        notificationCenter.post(
            name: .apiSessionUnauthorized,
            object: nil
        )
    }
}

private struct ClientMessage: Encodable {
    let version = 1
    let type: String
    let requestId: String
    let subscriptions: [RealtimeSubscription]?
    let timestamp: Int64
}

private struct RealtimeEventObserver {
    let continuation:
        AsyncStream<RealtimeServerMessage>.Continuation
    let onDropped: (() -> Void)?
}
