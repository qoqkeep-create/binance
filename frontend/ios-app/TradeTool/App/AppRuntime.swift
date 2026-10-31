import Foundation

@MainActor
final class AppRuntime: ObservableObject {
    @Published private(set) var container: AppContainer
    @Published private(set) var isSwitching = false

    private let store: ServerSelectionStore
    private let probe: any ServerNetworkProbing
    private let makeContainer: @MainActor (URL) -> AppContainer

    var servers: [AppServer] { store.servers }
    var currentServer: AppServer {
        servers.first(where: { $0.url == container.baseURL })!
    }

    init(
        store: ServerSelectionStore? = nil,
        probe: any ServerNetworkProbing = ServerNetworkProbe(),
        makeContainer: (@MainActor (URL) -> AppContainer)? = nil
    ) {
        let store = store ?? ServerSelectionStore(
            defaults: .standard,
            configuredURL: AppEnvironment.apiBaseURL
        )
        self.store = store
        self.probe = probe
        let factory = makeContainer ?? { AppContainer(baseURL: $0) }
        self.makeContainer = factory
        container = factory(store.current.url)
    }

    func switchServer(to server: AppServer) async throws {
        guard servers.contains(server), server != currentServer, !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }
        _ = try await probe.check(server, samples: 1)
        try Task.checkCancellation()
        container.prepareForServerChange()
        store.save(server)
        container = makeContainer(server.url)
    }
}
