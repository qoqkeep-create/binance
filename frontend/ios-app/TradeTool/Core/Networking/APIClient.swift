import Foundation

protocol APIClient {
    func send<Response: Decodable>(
        _ request: APIRequest<Response>
    ) async throws -> Response
}

protocol APIReadContextInvalidating {
    @MainActor func invalidateReadContext()
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

/// Only idempotent reads participate in path recovery. A trade or transfer write
/// retains its original transport/result and is never cancelled or replayed here.
@MainActor
final class APIReadRecovery {
    @MainActor
    final class Context {
        let id: Int
        var retried = false
        init(id: Int) { self.id = id }
    }
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?
    private var contextObserver: NSObjectProtocol?
    private var generation = 0
    private var contextID = 0
    private var available = true
    private var reads: [UUID: Task<(Data, URLResponse), Error>] = [:]
    private var readSessions: [ObjectIdentifier: URLSession] = [:]

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
        observer = notificationCenter.addObserver(forName: .apiNetworkPathChanged, object: nil, queue: .main) {
            [weak self] notification in
            guard let available = notification.userInfo?["available"] as? Bool else { return }
            let initial = notification.userInfo?["initial"] as? Bool ?? false
            MainActor.assumeIsolated { self?.pathChanged(available: available, initial: initial) }
        }
        contextObserver = notificationCenter.addObserver(forName: .apiReadContextChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateContext() }
        }
    }

    deinit {
        if let observer { notificationCenter.removeObserver(observer) }
        if let contextObserver { notificationCenter.removeObserver(contextObserver) }
        for session in readSessions.values { session.invalidateAndCancel() }
    }

    func invalidateContext() {
        contextID += 1
        for read in reads.values { read.cancel() }
        resetReadSessions()
    }

    func makeContext() -> Context { Context(id: contextID) }
    func isCurrent(_ context: Context) -> Bool { context.id == contextID }

    private func pathChanged(available: Bool, initial: Bool) {
        if initial && self.available == available { return }
        self.available = available
        generation += 1
        for read in reads.values { read.cancel() }
        resetReadSessions()
    }

    private func resetReadSessions() {
        for session in readSessions.values { session.invalidateAndCancel() }
        readSessions = [:]
    }

    private func readSession(for original: URLSession) -> URLSession {
        let key = ObjectIdentifier(original)
        if let session = readSessions[key] { return session }
        let configuration = original.configuration
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: original.delegate,
            delegateQueue: original.delegateQueue)
        readSessions[key] = session
        return session
    }

    func data(for request: URLRequest, context: Context, session: URLSession,
              delegate: (any URLSessionTaskDelegate)?) async throws -> (Data, URLResponse) {
        while true {
            try Task.checkCancellation()
            guard context.id == contextID else { throw CancellationError() }
            guard available else { throw URLError(.notConnectedToInternet) }
            let requestGeneration = generation
            let id = UUID()
            let transport = readSession(for: session)
            let read = Task { try await transport.data(for: request, delegate: delegate) }
            reads[id] = read
            do {
                let result = try await withTaskCancellationHandler {
                    try await read.value
                } onCancel: { read.cancel() }
                reads.removeValue(forKey: id)
                try Task.checkCancellation()
                guard context.id == contextID else { throw CancellationError() }
                guard requestGeneration == generation else {
                    if !available { throw URLError(.notConnectedToInternet) }
                    guard !context.retried else { throw CancellationError() }
                    context.retried = true
                    continue
                }
                return result
            } catch {
                reads.removeValue(forKey: id)
                try Task.checkCancellation()
                guard context.id == contextID else { throw CancellationError() }
                if requestGeneration != generation {
                    guard available else { throw URLError(.notConnectedToInternet) }
                    if !context.retried { context.retried = true; continue }
                }
                throw error
            }
        }
    }
}

struct URLSessionAPIClient: APIClient, APIReadContextInvalidating {
    let baseURL: URL
    let session: URLSession
    let interceptors: [any APIInterceptor]
    let errorReporter: (any APIErrorReporting)?
    let notificationCenter: NotificationCenter
    let readRecovery: APIReadRecovery?
    var refreshAccessToken: (() async throws -> String)? = nil

    init(
        baseURL: URL,
        session: URLSession = .shared,
        interceptors: [any APIInterceptor] = [
            CommonHeadersInterceptor(),
            HTTPStatusInterceptor(),
        ],
        errorReporter: (any APIErrorReporting)? = nil,
        notificationCenter: NotificationCenter = .default,
        readRecovery: APIReadRecovery? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.interceptors = interceptors
        self.errorReporter = errorReporter
        self.notificationCenter = notificationCenter
        self.readRecovery = readRecovery
    }

    func send<Response: Decodable>(
        _ request: APIRequest<Response>
    ) async throws -> Response {
        let readContext = [HTTPMethod.get, .head].contains(request.method)
            ? await readRecovery?.makeContext() : nil
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
            var (data, response) = try await performDataRequest(for: urlRequest, context: readContext, delegate: metricsDelegate)
            if (response as? HTTPURLResponse)?.statusCode == 401,
               !["/api/auth/login", "/api/auth/register", "/api/auth/refresh", "/api/auth/logout"].contains(request.path), let refreshAccessToken {
                try await requireCurrentReadContext(readContext)
                request.diagnostics?.mark("auth_refresh_started")
                let token = try await refreshAccessToken()
                try await requireCurrentReadContext(readContext)
                request.diagnostics?.mark("auth_refresh_finished")
                urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                (data, response) = try await performDataRequest(for: urlRequest, context: readContext, delegate: metricsDelegate)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            try await requireCurrentReadContext(readContext)
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
            let effectiveError: Error
            if let readContext, let readRecovery, !(await readRecovery.isCurrent(readContext)) {
                effectiveError = CancellationError()
            } else { effectiveError = error }
            request.diagnostics?.finished(error: effectiveError)
            let apiError = APIError.map(effectiveError)

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

    @MainActor func invalidateReadContext() { readRecovery?.invalidateContext() }

    private func requireCurrentReadContext(_ context: APIReadRecovery.Context?) async throws {
        guard let context, let readRecovery else { return }
        guard !Task.isCancelled, await readRecovery.isCurrent(context) else { throw CancellationError() }
    }

    private func performDataRequest(for request: URLRequest, context: APIReadRecovery.Context?, delegate: (any URLSessionTaskDelegate)?) async throws -> (Data, URLResponse) {
        if ["GET", "HEAD"].contains(request.httpMethod ?? "GET"), let readRecovery, let context {
            return try await readRecovery.data(for: request, context: context, session: session, delegate: delegate)
        }
        return try await session.data(for: request, delegate: delegate)
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
