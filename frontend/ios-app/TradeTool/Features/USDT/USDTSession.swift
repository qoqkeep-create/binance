import Foundation

/// One refresh per server session. A logout or account change cannot be overwritten.
actor MobileSessionRefresher {
    let baseURL: URL
    let network: URLSession
    let store: any AuthSessionStoring
    private var pending: Task<String, Error>?
    init(baseURL: URL, network: URLSession, store: any AuthSessionStoring) {
        self.baseURL = baseURL; self.network = network; self.store = store
    }
    func refresh() async throws -> String {
        if let pending { return try await pending.value }
        guard let original = try store.load() else { throw APIError.unauthorized(message: "请重新登录") }
        let task = Task<String, Error> {
            let request = APIRequest<JSONValue>(path: "/api/auth/refresh", method: .post)
            let (data, response) = try await network.data(for: request.makeURLRequest(baseURL: baseURL))
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let envelope = try? JSONDecoder().decode(APIEnvelope<JSONValue>.self, from: data),
                  envelope.isSuccess, let token = envelope.data?["accessToken"]?.text, !token.isEmpty,
                  try store.load()?.user.id == original.user.id,
                  try store.load()?.accessToken == original.accessToken else {
                throw APIError.unauthorized(message: "登录已过期，请重新登录")
            }
            try store.save(AuthSession(accessToken: token, user: original.user))
            return token
        }
        pending = task
        defer { pending = nil }
        return try await task.value
    }
}

#if DEBUG && targetEnvironment(macCatalyst)
/// Local UI checks without an Apple signing identity. Never persists a login.
final class EphemeralDevelopmentSessionStore: AuthSessionStoring {
    private var session: AuthSession?
    func load() throws -> AuthSession? { session }
    func save(_ session: AuthSession) throws { self.session = session }
    func delete() throws { session = nil }
}
#endif
