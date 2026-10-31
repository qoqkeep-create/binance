import Foundation

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

enum APIResponseMode {
    case plain
    case envelope
}

struct APIRequest<Response: Decodable> {
    let path: String
    let method: HTTPMethod
    let queryItems: [URLQueryItem]
    let headers: [String: String]
    let body: Data?
    let responseMode: APIResponseMode
    let showsErrorToast: Bool
    let timeoutInterval: TimeInterval

    init(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        responseMode: APIResponseMode = .envelope,
        showsErrorToast: Bool = true,
        timeoutInterval: TimeInterval = 30
    ) {
        self.path = path
        self.method = method
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
        self.responseMode = responseMode
        self.showsErrorToast = showsErrorToast
        self.timeoutInterval = timeoutInterval
    }

    static func json<Body: Encodable>(
        path: String,
        method: HTTPMethod,
        body: Body,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        responseMode: APIResponseMode = .envelope,
        showsErrorToast: Bool = true,
        timeoutInterval: TimeInterval = 30
    ) throws -> Self {
        var jsonHeaders = headers
        jsonHeaders["Content-Type"] = "application/json"

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let encodedBody = try? encoder.encode(body) else {
            throw APIError.requestEncoding
        }

        return Self(
            path: path,
            method: method,
            queryItems: queryItems,
            headers: jsonHeaders,
            body: encodedBody,
            responseMode: responseMode,
            showsErrorToast: showsErrorToast,
            timeoutInterval: timeoutInterval
        )
    }

    func makeURLRequest(baseURL: URL) throws -> URLRequest {
        guard let resolvedURL = URL(string: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), relativeTo: baseURL.appendingPathComponent("")),
              var components = URLComponents(
                url: resolvedURL,
                resolvingAgainstBaseURL: true
              ) else {
            throw APIError.invalidURL
        }

        if !queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(
            url: url,
            timeoutInterval: timeoutInterval
        )
        request.httpMethod = method.rawValue
        request.httpBody = body

        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        return request
    }
}

struct EmptyResponse: Decodable {
    init() {}
}
