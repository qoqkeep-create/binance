import SwiftUI

struct LoginView: View {
  @EnvironmentObject private var authStore: AuthStore
  @EnvironmentObject private var container: AppContainer
  @EnvironmentObject private var store: USDTStore
  @State private var register = false
  @State private var reset = false
  @State private var account = ""
  @State private var password = ""
  @State private var confirmPassword = ""
  @State private var agreed = false
  @State private var legal: String? = nil
  @State private var agreementPrompt = false
  @State private var notice = ""
  @State private var resetSent = false
  @State private var registrationClosed = false
  @State private var resetUID = ""
  @State private var resetToken = ""
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: 0) {
          VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 24).fill(WebTheme.gradient).frame(width: 80, height: 80)
              .overlay {
                WebTrendIcon().stroke(
                  .black, style: StrokeStyle(lineWidth: 3.3, lineCap: .round, lineJoin: .round)
                ).frame(width: 40, height: 40)
              }
              .shadow(color: WebTheme.brand.opacity(0.2), radius: 8, y: 4).padding(.bottom, 24)
            Text("RISKON").font(.system(size: 30, weight: .bold)).foregroundStyle(WebTheme.text)
              .frame(height: 36).padding(.bottom, 8)
            Text(reset ? "重置密码" : register ? "创建新账号" : "欢迎回来").font(.system(size: 16))
              .foregroundStyle(
                Color(uiColor: .init(red: 156 / 255, green: 163 / 255, blue: 175 / 255, alpha: 1))
              ).frame(height: 24).padding(.bottom, 32)
            VStack(spacing: 20) {
              if resetSent {
                USDTNotice(text: "如果该邮箱已注册，重置邮件会在几分钟内发送。请在 30 分钟内打开邮件中的链接。")
              } else {
                if register && registrationClosed {
                  Text("暂未开放注册，请联系管理员").font(.system(size: 14, weight: .medium)).foregroundStyle(
                    WebTheme.danger
                  ).frame(maxWidth: .infinity).padding(.vertical, 12).padding(.horizontal, 16)
                    .background(
                      WebTheme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 14)
                    ).overlay {
                      RoundedRectangle(cornerRadius: 14).stroke(
                        WebTheme.danger.opacity(0.3), lineWidth: 1)
                    }
                }
                if resetToken.isEmpty {
                  loginField(
                    register ? "邮箱" : reset ? "邮箱账号" : "账号",
                    placeholder: register || reset ? "请输入邮箱" : "请输入邮箱账号", text: $account)
                }
                if !reset || !resetToken.isEmpty {
                  loginField(
                    reset ? "新密码" : "密码", placeholder: reset ? "请输入新密码" : "请输入密码", text: $password,
                    secure: true)
                  if register {
                    loginField("确认密码", placeholder: "请再次输入密码", text: $confirmPassword, secure: true)
                  }
                  if !resetToken.isEmpty {
                    loginField(
                      "确认新密码", placeholder: "请再次输入新密码", text: $confirmPassword, secure: true)
                  }
                  if !reset { agreement }
                }
                Button(
                  authStore.isSubmitting
                    ? "正在进入..."
                    : !resetToken.isEmpty ? "确认重置密码" : reset ? "发送重置邮件" : register ? "注册" : "登录"
                ) { submit() }
                .buttonStyle(WebButtonStyle(height: 52, radius: 14, weight: .bold)).disabled(
                  authStore.isSubmitting || (register && registrationClosed)
                ).padding(.top, 12)
              }
              HStack(spacing: 16) {
                if !reset && !register {
                  Button("忘记密码？") {
                    reset = true
                    notice = ""
                  }
                  Text("|").foregroundStyle(WebTheme.secondary)
                  Button("注册账号") {
                    register = true
                    password = ""
                    notice = ""
                  }
                } else {
                  Button("返回登录") {
                    reset = false
                    register = false
                    resetSent = false
                    resetUID = ""
                    resetToken = ""
                    password = ""
                    notice = ""
                  }
                }
              }.font(.system(size: 14)).foregroundStyle(WebTheme.brand).buttonStyle(.plain).frame(
                maxWidth: .infinity)
              USDTNotice(text: notice)
            }
          }.padding(32).frame(maxWidth: 448)
            .background {
              RoundedRectangle(cornerRadius: 24).fill(
                colorScheme == .dark
                  ? AnyShapeStyle(
                    LinearGradient(
                      colors: [WebTheme.surface, WebTheme.page], startPoint: .topLeading,
                      endPoint: .bottomTrailing)) : AnyShapeStyle(WebTheme.surface))
            }.shadow(color: .black.opacity(0.25), radius: 25, y: 25)
        }.padding(16).frame(maxWidth: .infinity).frame(minHeight: geometry.size.height)
      }.scrollDismissesKeyboard(.interactively).scrollIndicators(.hidden)
    }.background(WebTheme.page.ignoresSafeArea()).tint(WebTheme.brand)
      .fullScreenCover(isPresented: Binding(get: { legal != nil }, set: { if !$0 { legal = nil } }))
    { NavigationStack { USDTLegalView(document: legal ?? "用户协议") } }
      .task {
        if let settings = try? await store.get("/v1/auth/admin-settings") {
          registrationClosed = settings["open_registration"]?.flag == false
        }
      }
      .onOpenURL { url in
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let uid = items.first(where: { $0.name == "reset_uid" })?.value,
          let token = items.first(where: { $0.name == "reset_token" })?.value, !uid.isEmpty,
          !token.isEmpty
        {
          resetUID = uid
          resetToken = token
          reset = true
          register = false
          resetSent = false
        }
      }
      .webModal(isPresented: $agreementPrompt) {
        WebModal(title: "用户协议与隐私政策") {
          Text("您还没有阅读和同意用户协议和隐私政策，确认已阅读并同意？").font(.system(size: 16)).lineSpacing(6)
          HStack(spacing: 12) {
            Button("不同意") { agreementPrompt = false }.buttonStyle(
              WebButtonStyle(kind: .secondary, radius: 14))
            Button("同意") {
              agreed = true
              agreementPrompt = false
            }.buttonStyle(WebButtonStyle(radius: 14))
          }
        }
      }
  }
  private var agreement: some View {
    HStack(alignment: .top, spacing: 8) {
      WebCheckbox(checked: $agreed, size: 16).padding(.top, 2).accessibilityIdentifier(
        "login.agreement")
      Text(agreementText).font(.system(size: 14)).lineSpacing(2)
        .environment(
          \.openURL,
          OpenURLAction { url in
            legal = url.host == "privacy" ? "隐私政策" : "用户协议"
            return .handled
          })
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private var agreementText: AttributedString {
    var result = AttributedString("我已阅读并同意 ")
    result.foregroundColor = WebTheme.secondary
    var terms = AttributedString("用户协议")
    terms.link = URL(string: "riskon://terms")
    terms.foregroundColor = WebTheme.brand
    terms.underlineStyle = .single
    var and = AttributedString(" 和 ")
    and.foregroundColor = WebTheme.secondary
    var privacy = AttributedString("隐私政策")
    privacy.link = URL(string: "riskon://privacy")
    privacy.foregroundColor = WebTheme.brand
    privacy.underlineStyle = .single
    result += terms
    result += and
    result += privacy
    return result
  }
  private func loginField(
    _ title: String, placeholder: String, text: Binding<String>, secure: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.system(size: 14)).foregroundStyle(WebTheme.secondary).frame(height: 20)
      USDTField(title: "", text: text, secure: secure, placeholder: placeholder, radius: 14)
        .accessibilityIdentifier(secure ? "login.password" : "login.account")
    }
  }
  private func submit() {
    if reset {
      Task {
        do {
          if resetToken.isEmpty {
            _ = try await store.send("/v1/auth/password-reset/request", ["email": .string(account)])
            resetSent = true
          } else {
            _ = try await store.send(
              "/v1/auth/password-reset/confirm",
              [
                "uid": .string(resetUID), "token": .string(resetToken),
                "new_password": .string(password), "confirm_password": .string(confirmPassword),
              ])
            reset = false
            resetUID = ""
            resetToken = ""
            password = ""
            confirmPassword = ""
            notice = "密码已重置，请重新登录"
          }
        } catch { notice = error.localizedDescription }
      }
      return
    }
    guard agreed else {
      agreementPrompt = true
      return
    }
    Task {
      if register {
        await authStore.register(
          account: account, password: password, confirmPassword: confirmPassword)
      } else {
        await authStore.login(account: account, password: password)
      }
    }
  }
}

private struct WebTrendIcon: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: x / 24 * rect.width, y: y / 24 * rect.height)
    }
    p.move(to: point(22, 7))
    p.addLine(to: point(13.5, 15.5))
    p.addLine(to: point(8.5, 10.5))
    p.addLine(to: point(2, 17))
    p.move(to: point(16, 7))
    p.addLine(to: point(22, 7))
    p.addLine(to: point(22, 13))
    return p
  }
}
