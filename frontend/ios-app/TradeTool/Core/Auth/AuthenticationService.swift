import Foundation

protocol AuthenticationService {
    func storedSession() throws -> AuthSession?
    func refresh(_ session: AuthSession) async throws -> AuthSession
    func clearStoredSession() throws

    func login(
        account: String,
        password: String
    ) async throws -> AuthSession

    func register(
        account: String,
        password: String
    ) async throws -> AuthSession

    func logout() async
}

struct APIAuthenticationService: AuthenticationService {
    let apiClient: any APIClient
    let sessionStore: any AuthSessionStoring

    func storedSession() throws -> AuthSession? {
        try sessionStore.load()
    }

    func refresh(_ session: AuthSession) async throws -> AuthSession {
        let user = try await apiClient.send(
            APIRequest<AuthUser>(
                path: "/api/auth/me",
                showsErrorToast: false
            )
        )
        let refreshed = AuthSession(
            accessToken: (try sessionStore.load())?.accessToken ?? session.accessToken,
            user: user
        )
        try sessionStore.save(refreshed)
        return refreshed
    }

    func clearStoredSession() throws {
        try sessionStore.delete()
    }

    func login(
        account: String,
        password: String
    ) async throws -> AuthSession {
        let request: APIRequest<AuthSession> = try .json(
            path: "/api/auth/login",
            method: .post,
            body: LoginRequestBody(
                account: account,
                password: password
            )
        )

        let session = try await apiClient.send(request)
        try sessionStore.save(session)
        return session
    }

    func register(
        account: String,
        password: String
    ) async throws -> AuthSession {
        let request: APIRequest<AuthSession> = try .json(
            path: "/api/auth/register",
            method: .post,
            body: RegisterRequestBody(
                account: account,
                password: password
            )
        )

        let session = try await apiClient.send(request)
        try sessionStore.save(session)
        return session
    }

    func logout() async {
        let token = try? sessionStore.load()?.accessToken
        try? clearStoredSession()

        var headers: [String: String] = [:]
        if let token, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        headers["X-Push-Installation-ID"] = PushInstallationIdentity.current()

        let request = APIRequest<EmptyResponse>(
            path: "/api/auth/logout",
            method: .post,
            headers: headers,
            showsErrorToast: false,
            timeoutInterval: 8
        )

        _ = try? await apiClient.send(request)
    }
}
