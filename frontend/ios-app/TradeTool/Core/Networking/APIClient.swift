import Foundation

protocol APIClient {
    func send<Response: Decodable>(
        _ request: APIRequest<Response>
    ) async throws -> Response
}

/// Callers sharing a read also share its completion, without owning or cancelling
/// the original request. Resetting its presentation releases obsolete waiters.
@MainActor
final class SharedReadCompletion {
    private var finished = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !finished, !Task.isCancelled else { continuation.resume(); return }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(id) }
        }
    }

    func finish() {
        finished = true
        let pending = waiters.values
        waiters = [:]
        for continuation in pending { continuation.resume() }
    }

    private func resume(_ id: UUID) { waiters.removeValue(forKey: id)?.resume() }
}

struct URLSessionAPIClient: APIClient {
    let baseURL: URL
    let session: URLSession
    let interceptors: [any APIInterceptor]
    let errorReporter: (any APIErrorReporting)?
    let notificationCenter: NotificationCenter
    var refreshAccessToken: (() async throws -> String)? = nil

    init(
        baseURL: URL,
        session: URLSession = .shared,
        interceptors: [any APIInterceptor] = [
            CommonHeadersInterceptor(),
            HTTPStatusInterceptor(),
        ],
        errorReporter: (any APIErrorReporting)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.baseURL = baseURL
        self.session = session
        self.interceptors = interceptors
        self.errorReporter = errorReporter
        self.notificationCenter = notificationCenter
    }

    func send<Response: Decodable>(
        _ request: APIRequest<Response>
    ) async throws -> Response {
        do {
            var urlRequest = try request.makeURLRequest(baseURL: baseURL)
            let metricsDelegate = request.diagnostics.map(RequestMetricsDelegate.init)
            if let diagnostics = request.diagnostics {
                urlRequest.setValue(diagnostics.traceID.uuidString, forHTTPHeaderField: "X-Chart-Trace-ID")
                urlRequest.setValue(diagnostics.requestID.uuidString, forHTTPHeaderField: "X-Chart-Request-ID")
            }

            for interceptor in interceptors {
                urlRequest = try await interceptor.adapt(urlRequest)
            }

            request.diagnostics?.mark("request_adapted")
            var (data, response) = try await session.data(for: urlRequest, delegate: metricsDelegate)
            if (response as? HTTPURLResponse)?.statusCode == 401,
               !["/api/auth/login", "/api/auth/register", "/api/auth/refresh", "/api/auth/logout"].contains(request.path), let refreshAccessToken {
                request.diagnostics?.mark("auth_refresh_started")
                let token = try await refreshAccessToken()
                request.diagnostics?.mark("auth_refresh_finished")
                urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                (data, response) = try await session.data(for: urlRequest, delegate: metricsDelegate)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            request.diagnostics?.received(httpResponse, bytes: data.count)

            for interceptor in interceptors {
                try interceptor.validate(data: data, response: httpResponse)
            }

            request.diagnostics?.mark("decode_started")
            let result = try decode(
                Response.self,
                from: data,
                mode: request.responseMode
            )
            request.diagnostics?.mark("decode_finished")
            request.diagnostics?.finished()
            return result
        } catch {
            request.diagnostics?.finished(error: error)
            let apiError = APIError.map(error)

            if case .unauthorized = apiError, request.invalidatesSessionOnUnauthorized {
                notificationCenter.post(
                    name: .apiSessionUnauthorized,
                    object: nil
                )
            }

            if request.showsErrorToast, apiError.shouldPresent {
                await errorReporter?.report(apiError)
            }

            throw apiError
        }
    }

    private func decode<Response: Decodable>(
        _ responseType: Response.Type,
        from data: Data,
        mode: APIResponseMode
    ) throws -> Response {
        if data.isEmpty, let emptyResponse = EmptyResponse() as? Response {
            return emptyResponse
        }

        let decoder = JSONDecoder.api

        switch mode {
        case .plain:
            return try decoder.decode(responseType, from: data)

        case .envelope:
            let envelope = try decoder.decode(
                APIEnvelope<Response>.self,
                from: data
            )

            guard envelope.isSuccess else {
                throw APIError.business(
                    code: envelope.code,
                    message: envelope.message ?? "请求处理失败"
                )
            }

            if let payload = envelope.data {
                return payload
            }

            if let emptyResponse = EmptyResponse() as? Response {
                return emptyResponse
            }
            if let null = JSONValue.null as? Response { return null }

            throw APIError.emptyData
        }
    }
}

private extension JSONDecoder {
    static var api: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
