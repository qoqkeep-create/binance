import SwiftUI
import UIKit

/// USDC's native form layout, connected to the integrated Python authentication API.
struct LoginView: View {
  @State private var destination: AuthDestination?

  var body: some View {
    AuthForm(mode: .login, open: { destination = $0 })
      .webSheet(item: $destination) { destination in
        AuthSheet(destination: destination)
      }
      .onOpenURL { url in
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let uid = items.first(where: { $0.name == "reset_uid" })?.value,
          let token = items.first(where: { $0.name == "reset_token" })?.value,
          !uid.isEmpty, !token.isEmpty {
          destination = .confirmReset(uid: uid, token: token)
        }
      }
  }
}

private enum AuthDestination: Identifiable {
  case register(email: String)
  case requestReset(email: String)
  case confirmReset(uid: String, token: String)

  var id: String {
    switch self {
    case .register: "register"
    case .requestReset: "request-reset"
    case .confirmReset: "confirm-reset"
    }
  }
}

private enum AuthMode {
  case login, register, requestReset, confirmReset

  var identifier: String {
    switch self {
    case .login: "login"
    case .register: "register"
    case .requestReset: "passwordReset"
    case .confirmReset: "passwordConfirm"
    }
  }

  var title: String {
    switch self {
    case .login: "登录"
    case .register: "注册"
    case .requestReset: "找回密码"
    case .confirmReset: "重置密码"
    }
  }
  var subtitle: String {
    switch self {
    case .login: "登录后查看行情与管理交易"
    case .register: "创建账号，开启你的交易工具箱"
    case .requestReset: "输入注册邮箱，接收密码重置邮件"
    case .confirmReset: "设置新密码，恢复账号访问"
    }
  }
  var action: String {
    switch self {
    case .login: "登录"
    case .register: "注册"
    case .requestReset: "发送重置邮件"
    case .confirmReset: "确认重置密码"
    }
  }
  var needsAgreement: Bool { self == .login || self == .register }
}

private struct AuthSheet: View {
  @Environment(\.webDismiss) private var dismiss
  @EnvironmentObject private var toastCenter: AppToastCenter
  let destination: AuthDestination

  var body: some View {
    NavigationStack {
      Group {
        switch destination {
        case let .register(email): AuthForm(mode: .register, initialEmail: email)
        case let .requestReset(email): AuthForm(mode: .requestReset, initialEmail: email)
        case let .confirmReset(uid, token): AuthForm(mode: .confirmReset, resetUID: uid, resetToken: token)
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.medium)) }
            .accessibilityLabel("关闭")
            .accessibilityIdentifier("auth.sheet.close")
        }
      }
      .toolbarBackground(BinanceTheme.background, for: .navigationBar)
      .globalAPIToasts(using: toastCenter)
    }
  }
}

private struct AuthLegalDocument: Identifiable {
  let title: String
  var id: String { title }
}

private struct AuthForm: View {
  private enum Field { case email, password, confirmation }
  private enum Registration { case loading, open, closed, unavailable }

  @EnvironmentObject private var authStore: AuthStore
  @EnvironmentObject private var store: USDTStore
  @Environment(\.webDismiss) private var dismiss
  let mode: AuthMode
  var initialEmail = ""
  var resetUID = ""
  var resetToken = ""
  var open: ((AuthDestination) -> Void)?
  @State private var email = ""
  @State private var password = ""
  @State private var confirmation = ""
  @State private var showsPassword = false
  @State private var agreed = false
  @State private var legal: AuthLegalDocument?
  @State private var registration: Registration = .loading
  @State private var notice = ""
  @State private var completed = false
  @State private var isResetting = false
  @State private var submission: Task<Void, Never>?
  @State private var focusedField: Field?

  private var isSubmitting: Bool { authStore.isSubmitting || isResetting }
  private var canSubmit: Bool { !isSubmitting && (mode != .register || registration == .open) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        brandHeader.padding(.bottom, 48)
        Text(mode.title).font(.system(size: 32, weight: .bold))
          .foregroundStyle(BinanceTheme.primaryText)
          .accessibilityAddTraits(.isHeader)
        Text(mode.subtitle).font(.subheadline).foregroundStyle(BinanceTheme.secondaryText)
          .padding(.top, 9).padding(.bottom, 32)
        if completed { completion }
        else {
          if mode == .register { registrationStatus }
          if mode != .confirmReset { emailField }
          if mode != .requestReset {
            passwordField(title: mode == .confirmReset ? "新密码" : "密码", text: $password,
              field: .password, prompt: mode == .login ? "请输入密码" : "至少 8 位密码")
              .padding(.top, mode == .confirmReset ? 0 : 18)
          }
          if mode == .register || mode == .confirmReset {
            passwordField(title: "确认密码", text: $confirmation, field: .confirmation, prompt: "请再次输入密码")
              .padding(.top, 18)
          }
          if mode == .login {
            Button("忘记密码？") {
              dismissKeyboard()
              password = ""
              showsPassword = false
              open?(.requestReset(email: email))
            }.font(.footnote.weight(.semibold)).foregroundStyle(BinanceTheme.accentText)
              .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 14)
          }
          if mode.needsAgreement { agreement.padding(.top, 20) }
          if !notice.isEmpty {
            Text(notice).font(.footnote).foregroundStyle(BinanceTheme.negative)
              .fixedSize(horizontal: false, vertical: true).padding(.top, 16)
              .accessibilityIdentifier("auth.notice")
          }
          Button(action: submit) {
            if isSubmitting { ProgressView().tint(BinanceTheme.onAccent) }
            else { Text(mode.action) }
          }.buttonStyle(BinancePrimaryButtonStyle()).disabled(!canSubmit)
            .accessibilityIdentifier(mode == .login ? "auth.submit" : "\(mode.identifier).submit").padding(.top, 28)
          modeSwitch.padding(.top, 18)
          securityNotice.padding(.top, 28)
        }
      }.padding(.horizontal, 24).padding(.top, mode == .login ? 36 : 16).padding(.bottom, 40)
        .frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(BinanceTheme.background.ignoresSafeArea())
    .tint(BinanceTheme.accentText)
    .webModalDismissDisabled(isSubmitting)
    .sheet(item: $legal) { document in
      USDTLegalView(document: document.title)
    }
    .task {
      email = initialEmail
      if mode == .register { await loadRegistration() }
    }
    .onDisappear { submission?.cancel() }
  }

  private var brandHeader: some View {
    HStack(spacing: 12) {
      BinanceLogoMark(size: 42)
      VStack(alignment: .leading, spacing: 2) {
        Text("Binance Tools").font(.headline.weight(.bold)).tracking(0.3)
          .foregroundStyle(BinanceTheme.primaryText)
        Text("MARKET & TRADING").font(.caption2.weight(.semibold)).tracking(0.8)
          .foregroundStyle(BinanceTheme.secondaryText)
      }
    }
  }

  private var emailField: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("邮箱").font(.subheadline.weight(.medium)).foregroundStyle(BinanceTheme.primaryText)
      AuthTextInput(text: $email, reveals: .constant(true), isPassword: false, keyboard: .emailAddress,
        placeholder: "请输入邮箱", contentType: mode == .register ? .emailAddress : .username,
        returnKey: mode == .requestReset ? .go : .next, isFocused: focusedField == .email,
        identifier: "\(mode.identifier).account", visibilityIdentifier: "",
        onFocus: { focused in
          if focused { focusedField = .email }
          else if focusedField == .email { focusedField = nil }
        }, onSubmit: {
          if mode == .requestReset { submit() } else { focusedField = .password }
        })
        .frame(height: 24).binanceInput(isFocused: focusedField == .email)
    }
  }

  private func passwordField(title: String, text: Binding<String>, field: Field, prompt: String) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title).font(.subheadline.weight(.medium)).foregroundStyle(BinanceTheme.primaryText)
      AuthTextInput(text: text, reveals: $showsPassword, isPassword: true,
        placeholder: prompt, contentType: mode == .login ? .password : .newPassword,
        returnKey: field == .password && mode != .login ? .next : .go,
        isFocused: focusedField == field,
        identifier: "\(mode.identifier).\(field == .confirmation ? "confirmPassword" : "password")",
        visibilityIdentifier: "\(mode == .login ? "auth" : mode.identifier).\(field == .confirmation ? "confirmVisibility" : "passwordVisibility")",
        onFocus: { focused in
          if focused { focusedField = field }
          else if focusedField == field { focusedField = nil }
        }, onSubmit: {
          if field == .password && mode != .login { focusedField = .confirmation }
          else { submit() }
        })
        .frame(height: 28).binanceInput(isFocused: focusedField == field)
    }
  }

  private var agreement: some View {
    HStack(alignment: .top, spacing: 8) {
      Button { agreed.toggle() } label: {
        Image(systemName: agreed ? "checkmark.square.fill" : "square")
          .font(.system(size: 18)).foregroundStyle(agreed ? BinanceTheme.accentText : BinanceTheme.secondaryText)
          .frame(width: 24, height: 24)
      }.buttonStyle(.plain).accessibilityLabel("同意用户协议和隐私政策")
        .accessibilityValue(agreed ? "已同意" : "未同意").accessibilityIdentifier("\(mode.identifier).agreement")
      Text(agreementText).font(.footnote).lineSpacing(3).padding(.top, 3)
        .accessibilityIdentifier("auth.agreementText")
        .environment(\.openURL, OpenURLAction { url in
          dismissKeyboard()
          legal = AuthLegalDocument(title: url.host == "privacy" ? "隐私政策" : "用户协议")
          return .handled
        })
    }
  }

  private var agreementText: AttributedString {
    var text = AttributedString("我已阅读并同意 ")
    text.foregroundColor = BinanceTheme.secondaryText
    var terms = AttributedString("用户协议")
    terms.link = URL(string: "riskon://terms")
    terms.foregroundColor = BinanceTheme.accentText
    var and = AttributedString(" 和 ")
    and.foregroundColor = BinanceTheme.secondaryText
    var privacy = AttributedString("隐私政策")
    privacy.link = URL(string: "riskon://privacy")
    privacy.foregroundColor = BinanceTheme.accentText
    return text + terms + and + privacy
  }

  @ViewBuilder private var registrationStatus: some View {
    switch registration {
    case .loading:
      Text("正在确认注册状态…").font(.footnote).foregroundStyle(BinanceTheme.secondaryText).padding(.bottom, 20)
    case .closed:
      Text("暂未开放注册，请联系管理员").font(.footnote).foregroundStyle(BinanceTheme.negative).padding(.bottom, 20)
    case .unavailable:
      VStack(alignment: .leading, spacing: 8) {
        Text("暂时无法获取注册状态，请重试").font(.footnote).foregroundStyle(BinanceTheme.negative)
        Button("重试") { submission = Task { await loadRegistration() } }
          .font(.footnote.weight(.semibold)).foregroundStyle(BinanceTheme.accentText)
      }.padding(.bottom, 20)
    case .open: EmptyView()
    }
  }

  @ViewBuilder private var modeSwitch: some View {
    if mode == .login {
      Button("注册账号") {
        dismissKeyboard()
        password = ""
        showsPassword = false
        open?(.register(email: email))
      }.font(.footnote.weight(.semibold)).foregroundStyle(BinanceTheme.accentText)
        .buttonStyle(.plain).frame(maxWidth: .infinity)
    } else {
      Button("返回登录") { dismiss() }.font(.footnote.weight(.semibold))
        .foregroundStyle(BinanceTheme.accentText).buttonStyle(.plain).frame(maxWidth: .infinity)
        .disabled(isSubmitting)
    }
  }

  private var securityNotice: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "lock.shield.fill").foregroundStyle(BinanceTheme.accentText)
      Text("妥善保管账号信息，保护你的交易安全")
        .font(.caption).foregroundStyle(BinanceTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var completion: some View {
    VStack(alignment: .leading, spacing: 24) {
      Image(systemName: "checkmark.circle.fill").font(.system(size: 36)).foregroundStyle(BinanceTheme.positive)
      Text(mode == .requestReset
        ? "如果该邮箱已注册，重置邮件会在几分钟内发送。请在 30 分钟内打开邮件中的链接。"
        : "密码已重置，请使用新密码登录")
        .font(.subheadline).foregroundStyle(BinanceTheme.primaryText)
        .fixedSize(horizontal: false, vertical: true)
      Button("返回登录") { dismiss() }.buttonStyle(BinancePrimaryButtonStyle())
    }
  }

  private func loadRegistration() async {
    registration = .loading
    do {
      let settings = try await store.get("/v1/auth/admin-settings")
      guard !Task.isCancelled else { return }
      if case let .bool(allowed) = settings["open_registration"] {
        registration = allowed ? .open : .closed
      } else { registration = .unavailable }
    } catch {
      if !Task.isCancelled { registration = .unavailable }
    }
  }

  private func dismissKeyboard() {
    focusedField = nil
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }

  private func submit() {
    guard canSubmit else { return }
    dismissKeyboard()
    notice = ""
    if mode.needsAgreement && !agreed {
      notice = "请先阅读并同意用户协议和隐私政策"
      return
    }
    let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
    if mode != .confirmReset && (!normalizedEmail.contains("@") || normalizedEmail.hasSuffix("@")) {
      notice = "请输入有效的邮箱地址"
      return
    }
    if (mode == .register || mode == .confirmReset) && (password.count < 8 || password != confirmation) {
      notice = password.count < 8 ? "密码至少8位" : "两次密码不一致"
      return
    }
    // Claim the reset submission synchronously so repeated taps cannot launch duplicate requests.
    if !mode.needsAgreement { isResetting = true }
    submission = Task {
      if mode == .login {
        await authStore.login(account: normalizedEmail, password: password)
      } else if mode == .register {
        await authStore.register(account: normalizedEmail, password: password, confirmPassword: confirmation)
      } else {
        defer { isResetting = false }
        do {
          if mode == .requestReset {
            _ = try await store.send("/v1/auth/password-reset/request", ["email": .string(normalizedEmail)])
          } else {
            _ = try await store.send("/v1/auth/password-reset/confirm", [
              "uid": .string(resetUID), "token": .string(resetToken),
              "new_password": .string(password), "confirm_password": .string(confirmation),
            ])
          }
          guard !Task.isCancelled else { return }
          password = ""
          confirmation = ""
          completed = true
        } catch {
          if !Task.isCancelled { notice = error.localizedDescription }
        }
      }
    }
  }
}

/// Keep the native editor and its eye button mounted while changing secure entry.
private struct AuthTextInput: UIViewRepresentable {
  @Binding var text: String
  @Binding var reveals: Bool
  let isPassword: Bool
  var keyboard: UIKeyboardType = .default
  let placeholder: String
  let contentType: UITextContentType
  let returnKey: UIReturnKeyType
  let isFocused: Bool
  let identifier: String
  let visibilityIdentifier: String
  let onFocus: (Bool) -> Void
  let onSubmit: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeUIView(context: Context) -> UITextField {
    let field = UITextField()
    field.delegate = context.coordinator
    field.borderStyle = .none
    field.font = .preferredFont(forTextStyle: .body)
    field.adjustsFontForContentSizeCategory = true
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.spellCheckingType = .no
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
    if isPassword {
      let eye = UIButton(type: .custom)
      eye.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
      eye.addTarget(context.coordinator, action: #selector(Coordinator.toggleVisibility), for: .touchUpInside)
      field.rightView = eye
      field.rightViewMode = .always
    }
    field.keyboardType = keyboard
    return field
  }

  func updateUIView(_ field: UITextField, context: Context) {
    context.coordinator.parent = self
    if isPassword && field.isSecureTextEntry == reveals {
      let selection = field.selectedTextRange
      field.isSecureTextEntry = !reveals
      field.text = text
      field.selectedTextRange = selection
    } else if field.text != text { field.text = text }
    field.textColor = UIColor(BinanceTheme.primaryText)
    field.attributedPlaceholder = NSAttributedString(string: placeholder,
      attributes: [.foregroundColor: UIColor(BinanceTheme.secondaryText)])
    field.textContentType = contentType
    field.returnKeyType = returnKey
    field.accessibilityIdentifier = identifier
    if let eye = field.rightView as? UIButton {
      eye.setImage(UIImage(systemName: reveals ? "eye.slash" : "eye"), for: .normal)
      eye.tintColor = UIColor(BinanceTheme.secondaryText)
      eye.accessibilityLabel = reveals ? "隐藏密码" : "显示密码"
      eye.accessibilityIdentifier = visibilityIdentifier
    }
    context.coordinator.synchronizeFocus(field)
  }

  static func dismantleUIView(_ field: UITextField, coordinator: Coordinator) {
    field.delegate = nil
    field.resignFirstResponder()
  }

  final class Coordinator: NSObject, UITextFieldDelegate {
    var parent: AuthTextInput
    private var requestedFocus = false
    init(parent: AuthTextInput) { self.parent = parent }
    @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
    @objc func toggleVisibility() { parent.reveals.toggle() }
    func textFieldDidBeginEditing(_ textField: UITextField) {
      requestedFocus = true
      parent.onFocus(true)
    }
    func textFieldDidEndEditing(_ textField: UITextField) {
      requestedFocus = false
      parent.onFocus(false)
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { parent.onSubmit(); return false }
    func synchronizeFocus(_ field: UITextField) {
      // An old "not focused" render must not resign a new focus acquired by a native tap.
      guard requestedFocus != parent.isFocused else { return }
      requestedFocus = parent.isFocused
      DispatchQueue.main.async { [weak self, weak field] in
        guard let self, let field, field.window != nil,
          self.requestedFocus == self.parent.isFocused else { return }
        if self.parent.isFocused && !field.isFirstResponder { field.becomeFirstResponder() }
        // Native blur events and explicit form actions own resignation; do not replay an old false state.
      }
    }
  }
}
