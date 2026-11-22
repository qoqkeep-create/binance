import Foundation

struct AppServer: Identifiable, Equatable, Sendable {
    let name: String
    let url: URL

    var id: String { url.absoluteString }
    var address: String { url.absoluteString }

    static let original = AppServer(
        name: "本地开发",
        url: URL(string: "http://127.0.0.1:8787/")!
    )
    static let seoul = AppServer(
        name: "整合服务器",
        url: URL(string: "https://47.80.22.243/integrated/")!
    )
}

struct ServerSelectionStore {
    static let storageKey = "selectedAPIOrigin"

    let defaults: UserDefaults
    let configuredURL: URL

    var servers: [AppServer] {
#if DEBUG
        let publicServers = [AppServer.seoul, .original]
        if publicServers.contains(where: { $0.url == configuredURL }) {
            return publicServers
        }
        return publicServers + [AppServer(name: "开发服务器", url: configuredURL)]
#else
        // A production/TestFlight build must never inherit the local
        // 127.0.0.1 development origin from a previous debug installation.
        // The phone's localhost is the phone itself, so API binding would
        // otherwise fail before the request reaches the integrated server.
        return [AppServer(name: "整合服务器", url: configuredURL)]
#endif
    }

    var current: AppServer {
        if let saved = defaults.string(forKey: Self.storageKey),
           let server = servers.first(where: { $0.id == saved }) {
            return server
        }
        return servers.first(where: { $0.url == configuredURL })!
    }

    func save(_ server: AppServer) {
        guard servers.contains(server) else { return }
        defaults.set(server.id, forKey: Self.storageKey)
    }
}
