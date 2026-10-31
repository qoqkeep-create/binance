import SwiftUI
import UIKit

struct LoginView: View {
    private static let modeSwitchPromptWidth: CGFloat = 58
    private static let modeSwitchActionWidth: CGFloat = 68

    private enum Mode {
        case login
        case register

        var title: String {
            switch self {
            case .login:
                return "登录"
            case .register:
                return "注册"
            }
        }

        var subtitle: String {
            switch self {
            case .login:
                return "登录后查看 USD-M 永续行情与策略信号"
            case .register:
                return "注册账号后查看 USD-M 永续行情与策略信号"
            }
        }

        var primaryActionTitle: String {
            switch self {
            case .login:
                return "登录"
            case .register:
                return "注册"
            }
        }

        var secondaryPrompt: String {
            switch self {
            case .login:
                return "没有账号"
            case .register:
                return "已有账号"
            }
        }

        var secondaryActionTitle: String {
            switch self {
            case .login:
                return "注册账号"
            case .register:
                return "返回登录"
            }
        }
    }

    private enum Field {
        case account
        case password
        case confirmPassword
    }

    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var runtime: AppRuntime
    @State private var showsServerSettings = false

    @State private var mode: Mode = .login
    @State private var account = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showsPassword = false
    @State private var agreed = false
    @State private var showsLegal = false
    @State private var showsPasswordReset = false
    @FocusState private var focusedField: Field?

    var body: some View {
        ZStack {
            BinanceTheme.background
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    brandHeader
                        .padding(.bottom, 48)

                    Text(mode.title)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(BinanceTheme.primaryText)

                    Text(mode.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(BinanceTheme.secondaryText)
                        .padding(.top, 9)
                        .padding(.bottom, 32)

                    accountField
                    passwordField
                        .padding(.top, 18)

                    if mode == .register {
                        confirmPasswordField
                            .padding(.top, 18)
                            .transition(.identity)
                    }

                    Toggle("我已阅读并同意用户协议与风险提示", isOn: $agreed)
                        .font(.footnote).padding(.top, 20)
                    HStack {
                        Button("查看协议") { showsLegal = true }
                        Spacer()
                        Button("忘记密码") { showsPasswordReset = true }
                    }.font(.footnote).padding(.top, 12)

                    Button {
                        submit()
                    } label: {
                        if authStore.isSubmitting {
                            ProgressView()
                                .tint(BinanceTheme.onAccent)
                        } else {
                            Text(mode.primaryActionTitle)
                        }
                    }
                    .buttonStyle(BinancePrimaryButtonStyle())
                    .disabled(authStore.isSubmitting || !agreed)
                    .opacity(authStore.isSubmitting ? 0.72 : 1)
                    .padding(.top, 28)

                    modeSwitch
                        .padding(.top, 18)
                        .transaction { transaction in
                            transaction.disablesAnimations = true
                            transaction.animation = nil
                        }

                    securityNotice
                        .padding(.top, 28)
                    Button {
                        focusedField = nil
                        showsServerSettings = true
                    } label: {
                        Label(runtime.currentServer.name, systemImage: "server.rack")
                            .font(BinanceTheme.Typography.text(.caption))
                            .foregroundStyle(BinanceTheme.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .padding(.top, 12)
                    .accessibilityIdentifier("login.server")
                }
                .padding(.horizontal, 24)
                .padding(.top, 36)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $showsLegal) { NavigationStack { USDTLegalView() } }
        .sheet(isPresented: $showsPasswordReset) { NavigationStack { USDTPasswordResetView() } }
        .sheet(isPresented: $showsServerSettings) {
            ServerSettingsView()
                .environmentObject(runtime)
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 12) {
            BinanceLogoMark(size: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("TRADE TOOL")
                    .font(.headline.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(BinanceTheme.primaryText)

                Text("MARKET & SIGNALS")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(BinanceTheme.secondaryText)
            }
        }
    }

    private var accountField: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("账号或邮箱")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(BinanceTheme.primaryText)

            TextField(
                "",
                text: $account,
                prompt: Text("请输入账号或邮箱")
                    .foregroundColor(BinanceTheme.secondaryText)
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.default)
            .textContentType(.username)
            .submitLabel(.next)
            .focused($focusedField, equals: .account)
            .binanceInput(isFocused: focusedField == .account)
            .onSubmit {
                focusedField = .password
            }
        }
    }

    private var passwordField: some View {
        passwordInput(
            title: "密码",
            text: $password,
            prompt: "请输入密码",
            contentType: mode == .register ? .newPassword : .password,
            field: .password,
            submitLabel: mode == .register ? .next : .go
        ) {
            if mode == .register {
                focusedField = .confirmPassword
            } else {
                submit()
            }
        }
    }

    private var confirmPasswordField: some View {
        passwordInput(
            title: "确认密码",
            text: $confirmPassword,
            prompt: "请再次输入密码",
            contentType: .newPassword,
            field: .confirmPassword,
            submitLabel: .go
        ) {
            submit()
        }
    }

    private func passwordInput(
        title: String,
        text: Binding<String>,
        prompt: String,
        contentType: UITextContentType,
        field: Field,
        submitLabel: SubmitLabel,
        onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(BinanceTheme.primaryText)

            HStack(spacing: 8) {
                Group {
                    if showsPassword {
                        TextField(
                            "",
                            text: text,
                            prompt: passwordPrompt(prompt)
                        )
                    } else {
                        SecureField(
                            "",
                            text: text,
                            prompt: passwordPrompt(prompt)
                        )
                    }
                }
                .textContentType(contentType)
                .submitLabel(submitLabel)
                .focused($focusedField, equals: field)
                .onSubmit(onSubmit)

                Button {
                    showsPassword.toggle()
                } label: {
                    Image(
                        systemName: showsPassword
                            ? "eye.slash"
                            : "eye"
                    )
                    .foregroundStyle(BinanceTheme.secondaryText)
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    showsPassword ? "隐藏密码" : "显示密码"
                )
            }
            .binanceInput(isFocused: focusedField == field)
        }
    }

    private func passwordPrompt(_ value: String) -> Text {
        Text(value)
            .foregroundColor(BinanceTheme.secondaryText)
    }

    private var modeSwitch: some View {
        HStack(spacing: 8) {
            Text(mode.secondaryPrompt)
                .font(.footnote)
                .foregroundStyle(BinanceTheme.secondaryText)
                .contentTransition(.identity)
                .frame(
                    width: Self.modeSwitchPromptWidth,
                    alignment: .trailing
                )

            Button {
                switchMode()
            } label: {
                Text(mode.secondaryActionTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(BinanceTheme.accentText)
                    .contentTransition(.identity)
                    .frame(
                        width: Self.modeSwitchActionWidth,
                        alignment: .leading
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    private var securityNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(BinanceTheme.accentText)

            Text("登录令牌仅保存在本机 Keychain，不会写入普通偏好设置")
                .font(.caption)
                .foregroundStyle(BinanceTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func switchMode() {
        focusedField = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            mode = mode == .login ? .register : .login
            password = ""
            confirmPassword = ""
        }
    }

    private func submit() {
        guard agreed else { return }
        focusedField = nil
        Task {
            switch mode {
            case .login:
                await authStore.login(
                    account: account,
                    password: password
                )

            case .register:
                await authStore.register(
                    account: account,
                    password: password,
                    confirmPassword: confirmPassword
                )
            }
        }
    }
}
