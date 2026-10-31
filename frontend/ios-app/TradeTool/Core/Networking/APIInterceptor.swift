import Foundation

protocol APIInterceptor {
    func adapt(_ request: URLRequest) async throws -> URLRequest
    func validate(data: Data, response: HTTPURLResponse) throws
}

extension APIInterceptor {
    func adapt(_ request: URLRequest) async throws -> URLRequest {
        request
    }

    func validate(data: Data, response: HTTPURLResponse) throws {}
}

struct CommonHeadersInterceptor: APIInterceptor {
    func adapt(_ request: URLRequest) async throws -> URLRequest {
        var request = request

        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Accept"
            )
        }

        request.setValue(
            Locale.preferredLanguages.first ?? "zh-Hans",
            forHTTPHeaderField: "Accept-Language"
        )

        if let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String {
            request.setValue(version, forHTTPHeaderField: "X-App-Version")
        }

        request.setValue("ios", forHTTPHeaderField: "X-Platform")
        return request
    }
}

struct BearerTokenInterceptor: APIInterceptor {
    let tokenProvider: () async -> String?

    func adapt(_ request: URLRequest) async throws -> URLRequest {
        guard let token = await tokenProvider(), !token.isEmpty else {
            return request
        }

        var request = request
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }
}

struct HTTPStatusInterceptor: APIInterceptor {
    func validate(data: Data, response: HTTPURLResponse) throws {
        guard !(200..<300).contains(response.statusCode) else {
            return
        }

        let message = HTTPErrorPayload.message(from: data)

        switch response.statusCode {
        case 401:
            throw APIError.unauthorized(message: message)
        case 403:
            throw APIError.forbidden(message: message)
        case 404:
            throw APIError.notFound(message: message)
        case 429:
            throw APIError.rateLimited(message: message)
        default:
            throw APIError.http(
                statusCode: response.statusCode,
                message: message
            )
        }
    }
}

private struct HTTPErrorPayload: Decodable {
    let message: String?
    let msg: String?
    let error: String?

    static func message(from data: Data) -> String? {
        guard !data.isEmpty,
              let payload = try? JSONDecoder().decode(
                HTTPErrorPayload.self,
                from: data
              ) else {
            return nil
        }

        return payload.message ?? payload.msg ?? payload.error
    }
}
