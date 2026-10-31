import Foundation
import Security

protocol AuthSessionStoring: AnyObject {
    func load() throws -> AuthSession?
    func save(_ session: AuthSession) throws
    func delete() throws
}

enum AuthSessionStoreError: LocalizedError {
    case encoding
    case decoding
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encoding:
            return "登录保存失败"
        case .decoding:
            return "请重新登录"
        case .keychain:
            return "安全存储不可用"
        }
    }
}

enum AuthSessionKeychainNamespace {
    static func service(
        bundleIdentifier: String,
        baseURL: URL
    ) -> String {
        let scheme = baseURL.scheme?.lowercased() ?? "unknown"
        let host = baseURL.host?.lowercased() ?? "unknown"
        let port = baseURL.port
            ?? defaultPort(for: scheme)

        return [
            bundleIdentifier,
            "auth-session",
            scheme,
            host,
            port.map(String.init) ?? "default",
        ].joined(separator: ".")
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}

enum LegacyBinanceCredentialScrubber {
    static func deleteAll(bundleIdentifier: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String:
                "\(bundleIdentifier).binance-usdm-api",
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class KeychainAuthSessionStore: AuthSessionStoring {
    private let service: String
    private let account = "authenticated-session"

    init(service: String) {
        self.service = service
    }

    func load() throws -> AuthSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw AuthSessionStoreError.keychain(status)
        }

        guard let data = result as? Data,
              let session = try? JSONDecoder().decode(
                AuthSession.self,
                from: data
              ) else {
            throw AuthSessionStoreError.decoding
        }

        return session
    }

    func save(_ session: AuthSession) throws {
        guard let data = try? JSONEncoder().encode(session) else {
            throw AuthSessionStoreError.encoding
        }

        let attributes = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as [String: Any]

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw AuthSessionStoreError.keychain(updateStatus)
        }

        var insertion = baseQuery
        attributes.forEach { insertion[$0.key] = $0.value }

        let insertionStatus = SecItemAdd(
            insertion as CFDictionary,
            nil
        )

        guard insertionStatus == errSecSuccess else {
            throw AuthSessionStoreError.keychain(insertionStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthSessionStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
