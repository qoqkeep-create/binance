import Foundation

@MainActor
final class AuthStore: ObservableObject {
    enum State {
        case restoring
        case signedOut
        case signedIn(AuthSession)
    }

    @Published private(set) var state: State = .restoring
    @Published private(set) var isSubmitting = false

    private let service: any AuthenticationService
    private let toastCenter: AppToastCenter
    private let notificationCenter: NotificationCenter
    private var unauthorizedObserver: NSObjectProtocol?

    init(
        service: any AuthenticationService,
        toastCenter: AppToastCenter,
        notificationCenter: NotificationCenter = .default
    ) {
        self.service = service
        self.toastCenter = toastCenter
        self.notificationCenter = notificationCenter

        unauthorizedObserver = notificationCenter.addObserver(
            forName: .apiSessionUnauthorized,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.expireSession()
            }
        }
    }

    deinit {
        if let unauthorizedObserver {
            notificationCenter.removeObserver(
                unauthorizedObserver
            )
        }
    }

    var session: AuthSession? {
        guard case let .signedIn(session) = state else {
            return nil
        }
        return session
    }

    func restore() async {
        do {
            if let session = try service.storedSession() {
                state = .signedIn(
                    (try? await service.refresh(session)) ?? session
                )
            } else {
                state = .signedOut
            }
        } catch {
            state = .signedOut
            toastCenter.error(
                error.localizedDescription,
                title: "登录信息不可用"
            )
        }
    }

    func login(account: String, password: String) async {
        let normalizedAccount = account.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !normalizedAccount.isEmpty else {
            toastCenter.warning("请输入邮箱或账号")
            return
        }

        guard password.count >= 6 else {
            toastCenter.warning("密码至少6位")
            return
        }

        guard !isSubmitting else {
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let session = try await service.login(
                account: normalizedAccount,
                password: password
            )
            state = .signedIn(session)
            toastCenter.success("登录成功")
        } catch let apiError as APIError {
            // APIClient has already presented globally intercepted errors.
            _ = apiError
        } catch {
            toastCenter.error(error.localizedDescription)
        }
    }

    func register(
        account: String,
        password: String,
        confirmPassword: String
    ) async {
        let normalizedAccount = account.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !normalizedAccount.isEmpty else {
            toastCenter.warning("请输入账号")
            return
        }

        guard password.count >= 8 else {
            toastCenter.warning("密码至少8位")
            return
        }

        guard password == confirmPassword else {
            toastCenter.warning("两次密码不一致")
            return
        }

        guard !isSubmitting else {
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let session = try await service.register(
                account: normalizedAccount,
                password: password
            )
            state = .signedIn(session)
            toastCenter.success("注册成功")
        } catch let apiError as APIError {
            // APIClient has already presented globally intercepted errors.
            _ = apiError
        } catch {
            toastCenter.error(error.localizedDescription)
        }
    }

    func logout() {
        guard session != nil else {
            return
        }

        notificationCenter.post(name: .apiReadContextChanged, object: nil)
        state = .signedOut
        toastCenter.success("已退出登录")

        Task {
            await service.logout()
        }
    }

    private func expireSession() {
        guard session != nil else {
            return
        }

        notificationCenter.post(name: .apiReadContextChanged, object: nil)
        try? service.clearStoredSession()
        state = .signedOut
    }
}
