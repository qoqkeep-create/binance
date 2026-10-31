import Foundation

struct ServerNetworkResult: Equatable, Sendable {
    let samplesMilliseconds: [Double]

    var medianMilliseconds: Double {
        let sorted = samplesMilliseconds.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

protocol ServerNetworkProbing {
    func check(_ server: AppServer, samples: Int) async throws -> ServerNetworkResult
}

enum ServerNetworkProbeError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "服务器未返回有效的服务响应"
    }
}

struct ServerNetworkProbe: ServerNetworkProbing {
    var configuration: URLSessionConfiguration = .ephemeral

    func check(_ server: AppServer, samples: Int = 3) async throws -> ServerNetworkResult {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var durations: [Double] = []
        for _ in 0..<max(1, samples) {
            try Task.checkCancellation()
            var request = URLRequest(url: server.url.appendingPathComponent("api/auth/me"))
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let start = ContinuousClock.now
            let (data, response) = try await session.data(for: request)
            let elapsed = start.duration(to: .now)
            guard let response = response as? HTTPURLResponse,
                  response.url?.host == server.url.host,
                  response.url?.scheme == server.url.scheme,
                  response.url?.port == server.url.port,
                  [200, 401].contains(response.statusCode),
                  let envelope = try? JSONDecoder().decode(ProbeEnvelope.self, from: data),
                  envelope.code == response.statusCode else {
                throw ServerNetworkProbeError.invalidResponse
            }
            durations.append(
                Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1e15
            )
        }
        return ServerNetworkResult(samplesMilliseconds: durations)
    }
}

private struct ProbeEnvelope: Decodable {
    let code: Int
}
