import Foundation

/// Opt-in measurements only. Headers, bodies, URLs and error messages are never retained.
final class RequestDiagnostics: @unchecked Sendable {
    let traceID: UUID
    let requestID = UUID()
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var fields: [String: Any]
    private var network: [[String: Any]] = []
    private let event: @Sendable (String, UUID) -> Void

    init(traceID: UUID, event: @escaping @Sendable (String, UUID) -> Void) {
        self.traceID = traceID
        self.event = event
        fields = ["startedAtMs": Self.wallMilliseconds(), "result": "pending"]
    }

    static func wallMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func mark(_ stage: String) { event(stage, requestID) }

    func received(_ response: HTTPURLResponse?, bytes: Int) {
        lock.lock()
        fields["statusCode"] = response?.statusCode
        fields["decodedBytes"] = bytes
        for (header, key) in [("X-Chart-Server-Received-At", "serverReceivedAtMs"),
                              ("X-Chart-Server-Ready-At", "serverReadyAtMs")] {
            fields[key] = response?.value(forHTTPHeaderField: header).flatMap(Int64.init)
        }
        let timing = response?.value(forHTTPHeaderField: "Server-Timing") ?? ""
        for part in timing.split(separator: ",") {
            let pieces = part.trimmingCharacters(in: .whitespaces).components(separatedBy: ";dur=")
            if pieces.count == 2, let ms = Double(pieces[1]), ms.isFinite, ms >= 0 {
                if pieces[0] == "history" { fields["serverHistoryMs"] = ms }
                if pieces[0] == "statistics_cache" { fields["serverStatsMs"] = ms }
            }
        }
        lock.unlock()
        mark("response_received")
    }

    func finished(error: Error? = nil) {
        let cancelled = error != nil && (Task.isCancelled || (error as NSError?)?.code == NSURLErrorCancelled)
        lock.lock()
        fields["completedAtMs"] = Self.wallMilliseconds()
        fields["elapsedMs"] = max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        fields["result"] = error == nil ? "success" : cancelled ? "cancelled" : "error"
        if let error { fields["errorCode"] = max(-100000, min(100000, (error as NSError).code)) }
        lock.unlock()
        if error != nil { mark(cancelled ? "request_cancelled" : "request_failed") }
    }

    func collected(_ metrics: URLSessionTaskMetrics) {
        var rows: [[String: Any]] = []
        for metric in metrics.transactionMetrics.prefix(3) {
            let protocolName = metric.networkProtocolName ?? "unknown"
            let source: String
            switch metric.resourceFetchType {
            case .networkLoad: source = "network"
            case .localCache: source = "localCache"
            case .serverPush: source = "serverPush"
            default: source = "unknown"
            }
            var row: [String: Any] = ["protocol": ["h2", "h3", "http/1.1", "http/1.0"].contains(protocolName) ? protocolName : "unknown",
                                      "source": source,
                                      "reused": metric.isReusedConnection, "proxy": metric.isProxyConnection,
                                      "wireBytes": max(0, metric.countOfResponseBodyBytesReceived),
                                      "decodedBytes": max(0, metric.countOfResponseBodyBytesAfterDecoding)]
            for (key, date) in [("requestAtMs", metric.requestStartDate), ("firstByteAtMs", metric.responseStartDate),
                                ("responseEndAtMs", metric.responseEndDate)] {
                if let date { row[key] = Int64(date.timeIntervalSince1970 * 1000) }
            }
            for (key, start, end) in [("dnsMs", metric.domainLookupStartDate, metric.domainLookupEndDate),
                                      ("connectMs", metric.connectStartDate, metric.connectEndDate),
                                      ("tlsMs", metric.secureConnectionStartDate, metric.secureConnectionEndDate),
                                      ("ttfbMs", metric.requestStartDate, metric.responseStartDate),
                                      ("transferMs", metric.responseStartDate, metric.responseEndDate),
                                      ("totalMs", metric.fetchStartDate, metric.responseEndDate)] {
                if let start, let end { row[key] = max(0, end.timeIntervalSince(start) * 1000) }
            }
            rows.append(row)
        }
        lock.lock()
        network.append(contentsOf: rows.prefix(max(0, 3 - network.count)))
        lock.unlock()
    }

    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return fields.merging(["requestId": requestID.uuidString, "network": network]) { _, new in new }
    }
}

final class RequestMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let diagnostics: RequestDiagnostics
    init(_ diagnostics: RequestDiagnostics) { self.diagnostics = diagnostics }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        diagnostics.collected(metrics)
    }
}
