import Foundation

private struct Samples: Codable {
    var milliseconds: [Double] = []
    var failures: Int = 0
    var errors: [String] = []
}

private struct ServerReport: Codable {
    let name: String
    let origin: String
    var metrics: [String: Samples] = [:]
}

private struct Report: Codable {
    let testedAt: Date
    let client: String
    let apiSamples: Int
    var servers: [ServerReport]
}

private struct SymbolItem: Decodable { let symbol: String }
private struct TickerPage: Decodable { let items: [SymbolItem] }
private struct CandleStamp: Decodable { let openTime: Int64 }
private struct CandlePage: Decodable { let items: [CandleStamp] }

private struct TestSession {
    let server: AppServer
    let session: URLSession
    let client: URLSessionAPIClient
    let token: String
}

private enum BenchmarkError: LocalizedError {
    case invalidCredentialsFile
    case unexpectedPayload
    case websocketTimeout

    var errorDescription: String? {
        switch self {
        case .invalidCredentialsFile: return "测试账号文件缺少必要字段"
        case .unexpectedPayload: return "接口或实时连接响应不符合预期"
        case .websocketTimeout: return "实时连接测试超时"
        }
    }
}

@main
private struct ServerBenchmark {
    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }

    static func credentials(_ path: String) throws -> [String: String] {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        var values: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        guard values["TEST_ACCOUNT"] != nil, values["TEST_PASSWORD"] != nil else {
            throw BenchmarkError.invalidCredentialsFile
        }
        return values
    }

    static func login(server: AppServer, file: String) async throws -> TestSession {
        let values = try credentials(file)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        let client = URLSessionAPIClient(baseURL: server.url, session: session)
        do {
            let auth: AuthSession = try await client.send(.json(
                path: "/api/auth/login", method: .post,
                body: LoginRequestBody(account: values["TEST_ACCOUNT"]!, password: values["TEST_PASSWORD"]!)
            ))
            let authenticated = URLSessionAPIClient(
                baseURL: server.url, session: session,
                interceptors: [CommonHeadersInterceptor(), BearerTokenInterceptor { auth.accessToken }, HTTPStatusInterceptor()],
                notificationCenter: NotificationCenter()
            )
            return TestSession(server: server, session: session, client: authenticated, token: auth.accessToken)
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }

    static func websocket(_ test: TestSession) async throws -> [String: Double] {
        var components = URLComponents(url: test.server.url, resolvingAgainstBaseURL: true)!
        components.scheme = "wss"
        components.path = "/ws/v1"
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(test.token)", forHTTPHeaderField: "Authorization")
        let socket = test.session.webSocketTask(with: request)
        defer { socket.cancel(with: .goingAway, reason: nil) }
        let start = ContinuousClock.now
        socket.resume()
        return try await withThrowingTaskGroup(of: [String: Double].self) { group in
            group.addTask {
                let first = try await receive(socket)
                guard first["type"] as? String == "ready" else { throw BenchmarkError.unexpectedPayload }
                let ready = milliseconds(since: start)
                try await socket.send(.string("{\"version\":1,\"type\":\"subscribe\",\"requestId\":\"benchmark-subscribe\",\"subscriptions\":[{\"channel\":\"market.ticker\",\"filters\":{\"symbols\":[\"BTCUSDC\"]}},{\"channel\":\"market.kline\",\"filters\":{\"symbols\":[\"BTCUSDC\"],\"intervals\":[\"1m\"]}}]}"))
                let pingStart = ContinuousClock.now
                try await socket.send(.string("{\"version\":1,\"type\":\"ping\",\"requestId\":\"benchmark-ping\"}"))
                var ping: Double?
                var event: Double?
                while ping == nil || event == nil {
                    let payload = try await receive(socket)
                    if payload["type"] as? String == "pong" { ping = milliseconds(since: pingStart) }
                    if payload["type"] as? String == "event", event == nil { event = milliseconds(since: pingStart) }
                    if payload["type"] as? String == "error" { throw BenchmarkError.unexpectedPayload }
                }
                return ["wss_ready": ready, "wss_ping": ping!, "wss_first_event": event!]
            }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                socket.cancel(with: .goingAway, reason: nil)
                throw BenchmarkError.websocketTimeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func receive(_ socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case let .string(value): data = Data(value.utf8)
        case let .data(value): data = value
        @unknown default: throw BenchmarkError.unexpectedPayload
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BenchmarkError.unexpectedPayload
        }
        return result
    }

    static func progress(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    static func main() async {
        do {
            try await run()
        } catch {
            progress("Benchmark stopped: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else {
            print("Usage: benchmark_servers OLD_ACCOUNT_FILE SEOUL_ACCOUNT_FILE OUTPUT_JSON")
            return
        }
        let endpoints = [AppServer.original, .seoul]
        var report = Report(
            testedAt: Date(),
            client: "macOS native Swift; production URLSessionAPIClient and ServerNetworkProbe; ephemeral sessions; no local HTTP cache",
            apiSamples: 12,
            servers: endpoints.map { ServerReport(name: $0.name, origin: $0.address) }
        )
        var sessions: [TestSession] = []
        do {
            for i in endpoints.indices {
                progress("\(endpoints[i].name): connecting for login")
                sessions.append(try await login(server: endpoints[i], file: args[i + 1]))
                progress("\(endpoints[i].name): authenticated; credentials hidden")
            }
            for round in 0..<5 {
                for i in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                    do {
                        let result = try await ServerNetworkProbe().check(endpoints[i], samples: 1)
                        report.servers[i].metrics["fresh_session_probe", default: Samples()].milliseconds.append(contentsOf: result.samplesMilliseconds)
                    } catch {
                        record(error, metric: "fresh_session_probe", server: i, report: &report)
                    }
                }
            }
            let metrics = ["authenticated_me", "popular_10", "btc_1h_500"]
            for metric in metrics {
                // Warm both services once before recording samples.
                for test in sessions { try? await apiCall(metric, test: test) }
                for round in 0..<12 {
                    for i in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                        let start = ContinuousClock.now
                        do {
                            try await apiCall(metric, test: sessions[i])
                            report.servers[i].metrics[metric, default: Samples()].milliseconds.append(milliseconds(since: start))
                        } catch {
                            record(error, metric: metric, server: i, report: &report)
                        }
                    }
                }
                progress("\(metric): both servers measured")
            }
            for round in 0..<5 {
                for i in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                    do {
                        for (metric, value) in try await websocket(sessions[i]) {
                            report.servers[i].metrics[metric, default: Samples()].milliseconds.append(value)
                        }
                    } catch {
                        for metric in ["wss_ready", "wss_ping", "wss_first_event"] {
                            record(error, metric: metric, server: i, report: &report)
                        }
                    }
                }
            }
        } catch {
            await logout(sessions)
            throw error
        }
        await logout(sessions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: URL(fileURLWithPath: args[3]))
        progress("Benchmark complete; JSON report contains timings only")
    }

    static func apiCall(_ metric: String, test: TestSession) async throws {
        switch metric {
        case "authenticated_me":
            let _: AuthUser = try await test.client.send(APIRequest(path: "/api/auth/me"))
        case "popular_10":
            let page: TickerPage = try await test.client.send(APIRequest(path: "/api/market/tickers/popular", queryItems: [URLQueryItem(name: "size", value: "10")]))
            guard page.items.count == 10 else { throw BenchmarkError.unexpectedPayload }
        default:
            let page: CandlePage = try await test.client.send(APIRequest(path: "/api/market/klines", queryItems: [URLQueryItem(name: "symbol", value: "BTCUSDC"), URLQueryItem(name: "interval", value: "1h"), URLQueryItem(name: "limit", value: "500")]))
            guard page.items.count == 500 else { throw BenchmarkError.unexpectedPayload }
        }
    }

    static func record(_ error: Error, metric: String, server: Int, report: inout Report) {
        report.servers[server].metrics[metric, default: Samples()].failures += 1
        report.servers[server].metrics[metric, default: Samples()].errors.append(error.localizedDescription)
    }

    static func logout(_ sessions: [TestSession]) async {
        for test in sessions {
            let _: EmptyResponse? = try? await test.client.send(APIRequest(path: "/api/auth/logout", method: .post))
            test.session.invalidateAndCancel()
        }
    }
}
