import Foundation

/// One small report per load; recording is synchronous memory work, upload is independent.
final class ChartLoadDiagnostics: @unchecked Sendable {
    let id = UUID()
    let symbol: String
    let interval: String
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private let startedAt = RequestDiagnostics.wallMilliseconds()
    private var events: [[String: Any]] = []
    private var requests: [RequestDiagnostics] = []
    private var finished = false
    private var truncated = false

    init(symbol: String, interval: String) {
        self.symbol = symbol; self.interval = interval
        record("load_started")
    }

    func record(_ stage: String, requestID: UUID? = nil, value: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        var row: [String: Any] = ["stage": stage, "atMs": RequestDiagnostics.wallMilliseconds(),
                                  "elapsedMs": max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000)]
        if let requestID { row["requestId"] = requestID.uuidString }
        if let value { row["value"] = max(0, min(10_000_000, value)) }
        if events.count < 63 { events.append(row) } else { truncated = true }
    }

    func request() -> RequestDiagnostics? {
        lock.lock()
        guard !finished, requests.count < 8 else { truncated = true; lock.unlock(); return nil }
        let child = RequestDiagnostics(traceID: id) { [weak self] stage, request in
            self?.record(stage, requestID: request)
        }
        requests.append(child)
        lock.unlock()
        child.mark("request_started")
        return child
    }

    func report(outcome: String, presentedAt: TimeInterval? = nil, completionKind: String = "none") -> Data? {
        let now = ProcessInfo.processInfo.systemUptime
        let end = presentedAt ?? now
        guard end >= started else { return nil }
        lock.lock()
        guard !finished else { lock.unlock(); return nil }
        finished = true
        let at = RequestDiagnostics.wallMilliseconds() - Int64(max(0, now - end) * 1000)
        let duration = max(0, (end - started) * 1000)
        events.append(["stage": outcome == "displayed" ? "first_frame" : "load_" + (outcome == "timeout" ? "timeout" : outcome == "superseded" ? "superseded" : "cancelled"),
                       "atMs": at, "elapsedMs": duration])
#if targetEnvironment(simulator)
        let platform = "iosSimulator"
#else
        let platform = "iosDevice"
#endif
        let savedEvents = events
        let savedRequests = requests
        let wasTruncated = truncated
        lock.unlock()
        let payload: [String: Any] = ["traceId": id.uuidString, "symbol": symbol, "interval": interval,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            "platform": platform, "startedAtMs": startedAt, "completedAtMs": at,
            "durationMs": duration, "outcome": outcome, "completionKind": completionKind,
            "events": savedEvents, "requests": savedRequests.map { $0.snapshot() }, "truncated": wasTruncated]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), data.count <= 24 * 1024 else { return nil }
        return data
    }

    static func upload(_ data: Data, using api: any APIClient) {
        // Detached from chart cancellation, bounded to two short attempts. No disk queue or toast.
        Task(priority: .utility) {
            for attempt in 0..<2 {
                do {
                    let _: EmptyResponse = try await api.send(APIRequest(path: "/api/market/chart-load-reports",
                        method: .post, headers: ["Content-Type": "application/json"], body: data,
                        showsErrorToast: false, timeoutInterval: 5, invalidatesSessionOnUnauthorized: false))
                    return
                } catch {
                    guard attempt == 0 else { return }
                    if let error = error as? APIError {
                        switch error {
                        case .unauthorized, .forbidden, .notFound, .rateLimited, .business, .cancelled: return
                        case .http(let code, _) where (400..<500).contains(code): return
                        default: break
                        }
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
}
