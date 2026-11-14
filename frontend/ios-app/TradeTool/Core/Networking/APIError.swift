import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case requestEncoding
    case invalidResponse
    case networkUnavailable
    case connectionFailed
    case timeout
    case insecureHTTPBlocked
    case unauthorized(message: String?)
    case forbidden(message: String?)
    case notFound(message: String?)
    case rateLimited(message: String?)
    case http(statusCode: Int, message: String?)
    case business(code: String?, message: String)
    case decoding
    case emptyData
    case cancelled
    case unknown(message: String?)

    var errorDescription: String? {
        userMessage
    }

    var userMessage: String {
        switch self {
        case .invalidURL:
            return "服务配置错误"
        case .requestEncoding:
            return "请求参数错误"
        case .invalidResponse:
            return "响应异常"
        case .networkUnavailable:
            return "网络不可用"
        case .connectionFailed:
            return "无法连接服务器"
        case .timeout:
            return "请求超时"
        case .insecureHTTPBlocked:
            return "HTTP访问被系统拦截"
        case let .unauthorized(message):
            return message ?? "登录失效"
        case let .forbidden(message):
            return message ?? "无权操作"
        case let .notFound(message):
            return message ?? "内容不存在"
        case let .rateLimited(message):
            return message ?? "操作频繁"
        case let .http(statusCode, message):
            return message ?? "请求失败 \(statusCode)"
        case let .business(_, message):
            return message
        case .decoding:
            return "数据解析失败"
        case .emptyData:
            return "无有效数据"
        case .cancelled:
            return "请求已取消"
        case let .unknown(message):
            return message ?? "未知错误"
        }
    }

    var presentationTitle: String {
        switch self {
        case .networkUnavailable,
             .connectionFailed,
             .timeout,
             .insecureHTTPBlocked:
            return "网络异常"
        case .unauthorized:
            return "登录状态失效"
        case .forbidden:
            return "无权访问"
        default:
            return "请求失败"
        }
    }

    var shouldPresent: Bool {
        if case .cancelled = self {
            return false
        }
        return true
    }

    static func map(_ error: Error) -> APIError {
        if let apiError = error as? APIError {
            return apiError
        }

        if error is CancellationError {
            return .cancelled
        }

        if error is DecodingError {
            return .decoding
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .timeout
            case .notConnectedToInternet:
                return .networkUnavailable
            case .networkConnectionLost,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .dnsLookupFailed:
                return .connectionFailed
            case .appTransportSecurityRequiresSecureConnection:
                return .insecureHTTPBlocked
            default:
                return .unknown(message: urlError.localizedDescription)
            }
        }

        return .unknown(message: error.localizedDescription)
    }
}

protocol APIErrorReporting: AnyObject {
    @MainActor
    func report(_ error: APIError)
}

extension Notification.Name {
    static let apiReadContextChanged = Notification.Name(
        "com.oovso.tradetool.api-read-context-changed"
    )
    static let apiNetworkPathChanged = Notification.Name(
        "com.oovso.tradetool.api-network-path-changed"
    )
    static let apiSessionUnauthorized = Notification.Name(
        "com.oovso.tradetool.api-session-unauthorized"
    )
}
