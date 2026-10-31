import Foundation

protocol APIClient {
    func send<Response: Decodable>(
        _ request: APIRequest<Response>
    ) async throws -> Response
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

            for interceptor in interceptors {
                urlRequest = try await interceptor.adapt(urlRequest)
            }

            var (data, response) = try await session.data(for: urlRequest)
            if (response as? HTTPURLResponse)?.statusCode == 401,
               !["/api/auth/login", "/api/auth/register", "/api/auth/refresh", "/api/auth/logout"].contains(request.path), let refreshAccessToken {
                let token = try await refreshAccessToken()
                urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                (data, response) = try await session.data(for: urlRequest)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            for interceptor in interceptors {
                try interceptor.validate(data: data, response: httpResponse)
            }

            return try decode(
                Response.self,
                from: data,
                mode: request.responseMode
            )
        } catch {
            let apiError = APIError.map(error)

            if case .unauthorized = apiError {
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
