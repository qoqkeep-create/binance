import SwiftUI

struct USDTProfileView: View {
  @EnvironmentObject private var store: USDTStore
  @EnvironmentObject private var auth: AuthStore
  @AppStorage(FloatingPositionsPreferences.enabledKey, store: FloatingPositionsPreferences.defaults)
  private var floatingPositions = false
  @State private var logout = false
  @State private var more = false
  @State private var binding = false
  @State private var stopLoss = false
  @State private var normalize = false
  @State private var capitalTab: USDTCapitalView.Tab = .move
  @State private var modeConfirm = false
  @State private var collectAccount: JSONValue = .null
  @Environment(\.colorScheme) private var scheme
  private var lead: Bool { store.mode == "lead" }
  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .center, spacing: 12) {
            AsyncImage(url: store.isBound ? URL(string: store.profile.value("avatar_url", fallback: "")) : nil) { phase in
              if let image = phase.image {
                image.resizable().scaledToFill()
              } else {
                RoundedRectangle(cornerRadius: 14).fill(WebTheme.gradient).overlay {
                  Text("B").font(.system(size: 20, weight: .bold)).foregroundStyle(.black)
                }
              }
            }.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 14))
              .accessibilityLabel("头像").accessibilityIdentifier("profile.avatar")
            if store.isBound {
              VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                  Text(store.binding.value("alias", fallback: store.profile.value("display_name")))
                    .font(.system(size: 16, weight: .bold)).lineLimit(1).layoutPriority(1)
                  Text(collectAccount.value("account_type") == "master" ? "主账户"
                    : collectAccount.value("account_type") == "sub" ? "子账户" : "同步中")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(WebTheme.brand)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(WebTheme.brand.opacity(0.1), in: Capsule()).fixedSize()
                    .accessibilityIdentifier("profile.accountType")
                }.frame(minHeight: 24).padding(.bottom, 4)
                Button("解除 API 绑定") { binding = true }.font(.system(size: 12)).underline()
                  .foregroundStyle(WebTheme.danger).frame(height: 32)
              }
            }
            Spacer(minLength: 0)
            if !store.isBound {
              Button { binding = true } label: {
                WebLabel("请先绑定 API", "link")
                  .font(.system(size: 12, weight: .semibold)).foregroundStyle(WebTheme.danger)
                  .padding(.horizontal, 12).frame(height: 34)
                  .background(WebTheme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                  .contentShape(RoundedRectangle(cornerRadius: 8))
              }.buttonStyle(.plain).accessibilityIdentifier("profile.bind")
            }
          }.padding(.bottom, 20)
          HStack {
            Spacer()
            Button(lead ? "切换合约模式" : "切换带单模式") { modeConfirm = true }
              .font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).frame(minHeight: 44)
              .background(WebTheme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
              .accessibilityIdentifier("profile.switchMode")
          }.padding(.bottom, 16)
          Rectangle().fill(accountBorder.opacity(0.5)).frame(height: 1).padding(.bottom, 16)
          HStack(spacing: 8) {
            Text(lead ? "带单组合可用余额 (USDT)" : "合约余额 (USDT)").font(.system(size: 14, weight: .medium))
              .foregroundStyle(WebTheme.secondary)
            Button {
              Task { await store.refresh() }
            } label: {
              HStack(spacing: 4) {
                WebIcon("refresh-cw", size: 12)
                Text("刷新").underline()
              }.font(.system(size: 12)).foregroundStyle(WebTheme.muted)
            }
          }
          .frame(height: 20).padding(.bottom, 8)
          HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
              Text(balance("balance")).font(.system(size: 36, weight: .bold)).tracking(-0.9).frame(
                height: 40
              ).foregroundStyle(scheme == .dark ? WebTheme.brand : WebTheme.text).lineLimit(1)
                .minimumScaleFactor(0.6)
              if !lead {
                VStack(alignment: .leading, spacing: 6) {
                  wallet("资金", "funding_balance")
                  wallet("现货", "spot_balance")
                }
              }
            }
            Spacer(minLength: 0)
            if !lead {
              VStack {
                Spacer(minLength: 0)
                Button {
                  capitalTab = .move
                  normalize = true
                } label: {
                  WebLabel("归集余额", "wallet.bifold")
                }.buttonStyle(WebButtonStyle(height: 36, fontSize: 12, fullWidth: false)).disabled(
                  !store.isBound)
              }.frame(height: 80)
            }
          }
          if lead {
            Text("组合充值、转出请在币安「我的带单」页面操作。此处止损额度仅用于带单交易。").font(.system(size: 12)).foregroundStyle(
              WebTheme.secondary
            ).lineSpacing(4).padding(.top, 16)
          }
        }.padding(24).background(accountBackground, in: RoundedRectangle(cornerRadius: 16)).overlay
        {
          RoundedRectangle(cornerRadius: 16).stroke(accountBorder, lineWidth: 1)
        }.shadow(color: scheme == .dark ? .clear : .black.opacity(0.1), radius: 3, y: 3)
        VStack(spacing: 0) {
          Button {
            stopLoss = true
          } label: {
            menuRow(
              "止损额设置", "chart.line.uptrend.xyaxis",
              value: "\(store.riskAmount.isEmpty ? "--" : store.riskAmount) USDT", amount: true)
          }
          separator
          if !lead {
            Button {
              capitalTab = .records
              normalize = true
            } label: {
              menuRow("资金归集", "paperplane")
            }
            separator
          }
          NavigationLink {
            USDTStrategiesView()
          } label: {
            menuRow("止盈止损策略", "target")
          }
          separator
          Button {
            more.toggle()
          } label: {
            menuRow("更多功能", "doc.text", arrow: more ? "chevron.up" : "chevron.down")
          }
          if more {
            NavigationLink {
              USDTRecordsView(kind: .operations)
            } label: {
              menuRow("日志", "clock.arrow.circlepath", small: true)
            }
            NavigationLink {
              USDTCommandsView()
            } label: {
              menuRow("交易命令", "clock", small: true)
            }
          }
          separator
          Button {
            floatingPositions.toggle()
          } label: {
            menuRow("持仓浮窗", "rectangle.on.rectangle", value: floatingPositions ? "已开启" : "未开启")
          }.accessibilityIdentifier("profile.floatingPositions")
            .accessibilityValue(floatingPositions ? "已开启" : "未开启")
          separator
          NavigationLink {
            USDTSettingsView()
          } label: {
            menuRow("设置", "gearshape")
          }
        }.background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 16)).overlay {
          RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1)
        }.clipShape(RoundedRectangle(cornerRadius: 16)).shadow(
          color: scheme == .dark ? .clear : .black.opacity(0.1), radius: 3, y: 3)
        USDTNotice(text: store.notice)
        Text("版本号：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "--")")
          .font(.system(size: 12)).foregroundStyle(WebTheme.muted).frame(maxWidth: .infinity)
        Button {
          logout = true
        } label: {
          Text("退出登录").font(.system(size: 16, weight: .medium))
            .foregroundStyle(WebTheme.danger)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(WebTheme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityIdentifier("profile.logout")
      }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 32).frame(maxWidth: 448).frame(
        maxWidth: .infinity)
    }.scrollIndicators(.hidden).usdtPage("我的")
      .task(id: store.scope) {
        await store.refresh()
        collectAccount = (try? await store.get("/v1/account/capital-collect-account")) ?? .null
      }.refreshable { await store.refresh() }
      .webModal(isPresented: $binding, motion: .fade) { USDTBindingView() }
      .sheet(isPresented: $stopLoss) { USDTStopLossView() }
      .sheet(isPresented: $normalize) { USDTCapitalView(initialTab: capitalTab) }
      .webModal(isPresented: $logout) {
        WebModal(title: "确认退出登录") {
          Text("确认要退出登录吗？").foregroundStyle(WebTheme.secondary)
          HStack(spacing: 12) {
            Button("取消") { logout = false }.buttonStyle(
              WebButtonStyle(kind: .secondary, radius: 14))
            Button("确认") {
              logout = false
              store.invalidate()
              auth.logout()
            }.buttonStyle(WebButtonStyle(radius: 14))
          }
        }
      }
      .webModal(isPresented: $modeConfirm) {
        WebModal(title: lead ? "切换合约模式" : "切换带单模式") {
          Text("切换后显示该账户的余额和订单，当前持仓及保护继续运行。").foregroundStyle(WebTheme.secondary)
          HStack(spacing: 12) {
            Button("取消") { modeConfirm = false }.buttonStyle(WebButtonStyle(kind: .secondary))
            Button("确认切换") {
              modeConfirm = false
              store.switchMode(lead ? "ordinary" : "lead")
            }.buttonStyle(WebButtonStyle())
          }
        }
      }
  }
  private var separator: some View {
    Rectangle().fill(WebTheme.border).frame(height: 1).padding(.horizontal, 16)
  }
  private var accountBorder: Color {
    if scheme == .dark { return WebTheme.brand.opacity(0.2) }
    // Tailwind 4 yellow-200 / sky-200 from the original USDT profile card.
    return lead
      ? Color(red: 184 / 255, green: 230 / 255, blue: 254 / 255)
      : Color(red: 255 / 255, green: 240 / 255, blue: 133 / 255)
  }
  private var accountBackground: LinearGradient {
    LinearGradient(
      colors: scheme == .dark
        ? [WebTheme.brand.opacity(0.05), WebTheme.brand.opacity(0.1)]
        : lead
          ? [
            Color(red: 240 / 255, green: 249 / 255, blue: 255 / 255),
            Color(red: 239 / 255, green: 246 / 255, blue: 255 / 255),
          ]
          : [
            Color(red: 254 / 255, green: 252 / 255, blue: 232 / 255),
            Color(red: 255 / 255, green: 251 / 255, blue: 235 / 255),
          ], startPoint: .topLeading, endPoint: .bottomTrailing)
  }
  private func balance(_ key: String) -> String {
    guard let amount = store.account[key]?.decimal else { return "--" }
    return String(format: "%.2f", NSDecimalNumber(decimal: amount).doubleValue)
  }
  private func wallet(_ title: String, _ key: String) -> some View {
    HStack(spacing: 8) {
      Text(title).foregroundStyle(WebTheme.secondary).frame(width: 28, alignment: .leading)
      Text("\(balance(key)) USDT").fontWeight(.semibold)
    }.font(.system(size: 12))
  }
  private var total: Decimal {
    ["balance", "spot_balance", "funding_balance"].reduce(Decimal.zero) {
      $0 + (store.account[$1]?.decimal ?? 0)
    }
  }
  private func menuRow(
    _ title: String, _ icon: String, value: String = "", amount: Bool = false, small: Bool = false,
    arrow: String = "chevron.right"
  ) -> some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: small ? 10 : 14).fill(
        small
          ? WebTheme.secondary.opacity(0.1) : WebTheme.brand.opacity(scheme == .dark ? 0.1 : 0.15)
      ).frame(width: small ? 32 : 40, height: small ? 32 : 40).overlay {
        WebIcon(icon, size: small ? 16 : 20).foregroundStyle(
          small ? WebTheme.secondary : WebTheme.brand)
      }
      Text(title).font(.system(size: small ? 14 : 16, weight: small ? .regular : .medium))
        .foregroundStyle(small ? WebTheme.secondary : WebTheme.text)
      Spacer(minLength: 0)
      if !value.isEmpty {
        Text(value).font(.system(size: amount ? 14 : 12, weight: amount ? .bold : .medium))
          .foregroundStyle(
            amount ? (scheme == .dark ? WebTheme.brand : WebTheme.text) : WebTheme.muted
          ).lineLimit(1)
      }
      WebIcon(arrow, size: small ? 16 : 18).foregroundStyle(WebTheme.muted)
    }.padding(.vertical, small ? 12 : 16).padding(.leading, small ? 28 : 16).padding(.trailing, 16)
      .contentShape(Rectangle())
  }
}

struct USDTBindingView: View {
  @EnvironmentObject private var store: USDTStore
  @State private var apiKey = ""
  @State private var secret = ""
  @State private var alias = ""
  @State private var notice = ""
  @State private var busy = false
  @State private var unbind = false
  var body: some View {
    WebModal(title: store.isBound ? "API管理" : "绑定API") {
      if store.mode == "lead" {
        USDTNotice(text: "请在币安「合约跟单 → 我的带单 → 对应组合 → API」创建专用 Key，开启合约交易并设置 IP 白名单。")
      }
      if store.isBound {
        VStack(spacing: 6) {
          USDTMetric(title: "API别名", value: store.binding.value("alias"))
          USDTMetric(title: "连接状态", value: store.binding.value("status") == "1" ? "已连接" : "连接异常")
        }.padding(16).background(WebTheme.input, in: RoundedRectangle(cornerRadius: 14))
        Button("解除 API 绑定") { unbind = true }.buttonStyle(WebButtonStyle(kind: .danger, radius: 14))
          .disabled(busy)
      } else {
        USDTField(
          title: "API Key", text: $apiKey, secure: true, placeholder: "请输入API Key", radius: 14)
        USDTField(
          title: "Secret Key", text: $secret, secure: true, placeholder: "请输入Secret Key", radius: 14
        )
        USDTField(title: "API别名", text: $alias, placeholder: "请输入API别名，便于区分和记忆", radius: 14)
        Button(busy ? "绑定中..." : "确认绑定") { bind() }.buttonStyle(WebButtonStyle(radius: 14))
          .disabled(busy || apiKey.isEmpty || secret.isEmpty || alias.isEmpty)
      }
      USDTNotice(text: notice)
    }.task { await store.refresh() }.onDisappear {
      apiKey = ""
      secret = ""
    }
    .webModal(isPresented: $unbind) {
      WebModal(title: "确认解除绑定") {
        Text("确认解绑当前模式的 API？").foregroundStyle(WebTheme.secondary)
        HStack(spacing: 12) {
          Button("取消") { unbind = false }.buttonStyle(WebButtonStyle(kind: .secondary))
          Button("解除绑定") {
            unbind = false
            busy = true
            Task {
              defer { busy = false }
              do {
                _ = try await store.send("/v1/api/unbind")
                store.invalidate()
                await store.refresh()
                notice = "已解绑"
              } catch { notice = error.localizedDescription }
            }
          }.buttonStyle(WebButtonStyle(kind: .danger))
        }
      }
    }
  }
  private func bind() {
    busy = true
    Task {
      defer {
        busy = false
        apiKey = ""
        secret = ""
      }
      do {
        _ = try await store.send(
          "/v1/api/bind",
          ["api_key": .string(apiKey), "secret_key": .string(secret), "alias": .string(alias)])
        store.invalidate()
        await store.refresh()
        notice = "绑定成功"
      } catch { notice = error.localizedDescription }
    }
  }
}

private struct StopLossPresentationDetent: CustomPresentationDetent {
  static func height(in context: Context) -> CGFloat? {
    context.dynamicTypeSize.isAccessibilitySize ? context.maxDetentValue : min(650, context.maxDetentValue)
  }
}

struct USDTStopLossView: View {
  @EnvironmentObject private var store: USDTStore
  @Environment(\.dismiss) private var dismiss
  @State private var value: JSONValue = .null
  @State private var percentage = 2
  @State private var loading = true
  @State private var saving = false
  @State private var notice = ""
  @State private var confirm = false
  @State private var cancelPending = false
  @State private var completed: (from: Decimal, to: Decimal)?
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("止损设置").font(.system(size: 20, weight: .bold))
        Spacer()
        Button { dismiss() } label: {
          WebIcon("xmark", size: 20).foregroundStyle(WebTheme.muted).frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("关闭").disabled(saving)
      }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          VStack(alignment: .leading, spacing: 8) {
            Text("账户总资产（USDT）").font(.system(size: 14)).foregroundStyle(WebTheme.secondary)
            Text("\(money(balance)) USDT").font(.system(size: 24, weight: .bold))
          }
          VStack(spacing: 12) {
            HStack {
              Text("单笔止损占账户总资产百分比").font(.system(size: 14)).foregroundStyle(WebTheme.secondary)
              Spacer()
              Text("\(percentage)%").font(.system(size: 24, weight: .bold)).foregroundStyle(
                WebTheme.brand)
              Text(percentage <= 4 ? "低风险" : percentage <= 10 ? "中风险" : "高风险").font(.system(size: 14))
                .foregroundStyle(
                  percentage <= 4
                    ? WebTheme.success : percentage <= 10 ? WebTheme.brand : WebTheme.danger)
            }
            VStack(alignment: .leading, spacing: 4) {
              (Text("单笔止损额：").font(.system(size: 14))
                + Text(
                  " (\(money(balance))*\(percentage)%=\(money(balance * Decimal(percentage) / 100)) USDT 向上取整)"
                ).font(.system(size: 12))).foregroundStyle(WebTheme.secondary)
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(money(target)) USDT").font(.system(size: 24, weight: .bold))
                if !loading && target == value["current_amount"]?.decimal {
                  Text("当前").font(.system(size: 11))
                }
              }.foregroundStyle(WebTheme.brand)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(
              WebTheme.input, in: RoundedRectangle(cornerRadius: 14))
            Slider(value: Binding(get: { Double(percentage) }, set: { percentage = Int($0) }),
              in: 1...25, step: 1)
              .tint(WebTheme.brand).disabled(loading)
              .accessibilityLabel("止损比例").accessibilityValue("\(percentage)%")
              .accessibilityIdentifier("stop-loss.percentage")
            HStack {
              Text("1%")
              Spacer()
              Text("25%")
            }.font(.system(size: 12)).foregroundStyle(WebTheme.muted)
          }
          VStack(alignment: .leading, spacing: 8) {
            Text("1. 止损金额按合约、资金、现货三类账户的 USDT 总资产计算")
            Text("2. 止损金额设定后，不再随账户余额变动而变动")
            Text("3. 确认后止损额立即生效（测试阶段暂不启用调高冷却）")
          }.font(.system(size: 12)).foregroundStyle(WebTheme.muted).lineSpacing(4)
          if let pending = value["pending_amount"], pending != .null {
            HStack {
              TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text("您已调整止损金额\(value.value("pending_from_amount")) → \(pending.text)，\(countdownText(at: timeline.date))后生效")
                  .font(.system(size: 14))
              }
              Spacer()
              Button("取消") {
                cancelPending = true
                confirm = true
              }.underline()
            }.foregroundStyle(WebTheme.brand).padding(12).background(
              WebTheme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
          }
          if let completed {
            HStack {
              Text("您已调整止损金额\(money(completed.from)) → \(money(completed.to))。")
              Spacer()
              Button("知道了") { self.completed = nil }.underline()
            }.font(.system(size: 14)).foregroundStyle(WebTheme.success).padding(12)
              .background(WebTheme.success.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
          }
          USDTNotice(text: notice)
        }.padding(.horizontal, 24).padding(.vertical, 8)
      }.scrollIndicators(.hidden)
    }.frame(maxWidth: 448).frame(maxWidth: .infinity)
    .font(.system(size: 14)).foregroundStyle(WebTheme.text)
    .background(WebTheme.surface)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      Button(saving ? "提交中..." : "确定") {
        cancelPending = false
        confirm = true
      }.buttonStyle(WebButtonStyle(height: 56, radius: 14, weight: .bold, mutedDisabled: true))
        .disabled(loading || saving || target == (value["current_amount"]?.decimal ?? 0) || balance <= 0)
        .accessibilityIdentifier("stop-loss.submit")
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: 448).frame(maxWidth: .infinity).background(WebTheme.surface)
    }
    .presentationDetents([.custom(StopLossPresentationDetent.self)])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(24)
    .presentationBackground(WebTheme.surface)
    .interactiveDismissDisabled(saving)
    .task {
      do {
        let response = try await store.get("/v1/account/stop-loss")
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          value = response
          let current = value["current_amount"]?.decimal ?? 0
          if balance > 0 {
            percentage = min(25, max(1,
              Int(NSDecimalNumber(decimal: current / balance * 100).doubleValue.rounded())))
          }
          loading = false
        }
      } catch { notice = error.localizedDescription; loading = false }
    }
    .webModal(isPresented: $confirm) {
      WebModal(title: "", overlayOpacity: 0.45, contentSpacing: 24) {
        Text(
          cancelPending
            ? "确认取消调整止损金额？"
            : "您将调整止损金额由\(value.value("current_amount"))调整到\(NSDecimalNumber(decimal: target).stringValue)，确认后立即生效，是否确认？"
        ).font(.system(size: 16)).lineSpacing(4)
        HStack(spacing: 12) {
          Button("取消") { confirm = false }.buttonStyle(WebButtonStyle(kind: .secondary))
          Button("确定") {
            confirm = false
            update(cancel: cancelPending)
          }.buttonStyle(WebButtonStyle())
        }
      }
    }
  }
  private var balance: Decimal {
    value["total_balance"]?.decimal
      ?? ["balance", "spot_balance", "funding_balance"].reduce(Decimal.zero) {
        $0 + (store.account[$1]?.decimal ?? 0)
      }
  }
  private func countdownText(at now: Date) -> String {
    let deadline = WebFormat.date(value.value("pending_effective_at"))
    let seconds = max(0, Int(deadline?.timeIntervalSince(now) ?? 0))
    return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
  }
  private var target: Decimal { WebStopLossAmount.roundUp(balance * Decimal(percentage) / 100) }
  private func money(_ value: Decimal) -> String {
    String(format: "%.2f", NSDecimalNumber(decimal: value).doubleValue)
  }
  private func update(cancel: Bool) {
    guard !saving else { return }
    saving = true
    Task {
      defer { saving = false }
      do {
        let previous = value["current_amount"]?.decimal ?? 0
        value = try await store.send(
          cancel ? "/v1/account/stop-loss/cancel" : "/v1/account/stop-loss",
          cancel ? [:] : ["percentage": .number(Double(percentage))])
        await store.refresh()
        if let current = value["current_amount"]?.decimal, previous != current {
          completed = (previous, current)
        }
        notice = ""
      } catch { notice = error.localizedDescription }
    }
  }
}

/// Explicit wallet operations use the same native presentation as the pair picker.
struct USDTCapitalView: View {
  enum Tab: String, CaseIterable {
    case move = "划转", transfer = "转账", records = "记录"
    var identifier: String {
      switch self {
      case .move: "capital.tab.move"
      case .transfer: "capital.tab.transfer"
      case .records: "capital.tab.records"
      }
    }
  }
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: USDTStore
  @State private var tab: Tab
  @State private var direction = "to_spot"
  @State private var preview: JSONValue = .null
  @State private var busy = false
  @State private var notice = ""
  @State private var requestID = UUID().uuidString
  @State private var legacy = false
  @State private var editor = false
  @State private var submitted = false
  init(initialTab: Tab = .move) { _tab = State(initialValue: initialTab) }
  private var action: String { tab == .transfer ? "transfer" : direction }
  private var pending: Bool { preview.value("status") == "collection_pending" }
  private var completed: Bool { preview.value("reason") == "normalization_completed" }
  private var legacyPending: Bool { pending && preview.value("operation", fallback: "").isEmpty }
  private var canSubmit: Bool {
    tab != .records && !busy && (pending || preview.value("status") == "normalization_required")
      && preview.value("operation") == action
  }
  private var requestStorageKey: String { "capital.request.\(store.scope).\(action)" }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("归集资金").font(.system(size: 20, weight: .bold))
        Spacer()
        Button { dismiss() } label: {
          Image(systemName: "xmark").font(.system(size: 18, weight: .medium))
            .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(busy).accessibilityLabel("关闭")
          .accessibilityIdentifier("capital.close")
      }.padding(.horizontal, 20).padding(.top, 12)
      tabs
      if tab == .records {
        USDTRecordsView(kind: .transfers, embedded: true)
      } else {
        walletContent
      }
    }.foregroundStyle(WebTheme.text).background(WebTheme.page)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if tab != .records { walletFooter }
      }
      .largeTradingSheet().interactiveDismissDisabled(busy)
      .task(id: tab == .records ? "records" : action) {
        if tab != .records { await load() }
      }
      .onChange(of: store.scope) { _, _ in dismiss() }
      .webModal(isPresented: $editor) { USDTCollectAccountView() }
      .onChange(of: editor) { _, shown in if !shown { Task { await load() } } }
      .webModal(isPresented: $legacy) { USDTLegacyCapitalView() }
      .onChange(of: legacy) { _, shown in if !shown { Task { await load() } } }
  }
  private var tabs: some View {
    HStack(spacing: 4) {
      ForEach(Tab.allCases, id: \.self) { item in
        Button { tab = item } label: {
          Text(item.rawValue).font(.system(size: 15, weight: tab == item ? .semibold : .medium))
            .foregroundStyle(tab == item ? Color.black : WebTheme.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(tab == item ? WebTheme.brand : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityIdentifier(item.identifier)
          .accessibilityAddTraits(tab == item ? .isSelected : [])
      }
    }.padding(4).background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 12))
      .overlay { RoundedRectangle(cornerRadius: 12).stroke(WebTheme.border, lineWidth: 1) }
      .padding(.horizontal, 20).padding(.vertical, 12)
      .disabled(busy || pending || submitted).accessibilityIdentifier("capital.tabs")
  }
  private var walletContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if tab == .move {
          VStack(alignment: .leading, spacing: 8) {
            Text("划转方向").font(.system(size: 13, weight: .medium)).foregroundStyle(WebTheme.secondary)
            Picker("划转方向", selection: $direction) {
              Text("合约、资金 → 现货").tag("to_spot")
              Text("资金 → 合约").tag("funding_to_futures")
              Text("现货 → 合约").tag("spot_to_futures")
            }.pickerStyle(.menu).tint(WebTheme.text).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
              .padding(.horizontal, 12).background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 12))
              .overlay { RoundedRectangle(cornerRadius: 12).stroke(WebTheme.border, lineWidth: 1) }
              .disabled(busy || pending || submitted).accessibilityIdentifier("capital.direction")
          }
          walletCard
          VStack(alignment: .leading, spacing: 10) {
            Text(direction == "to_spot" ? "本次划转明细" : "补入合约")
              .font(.system(size: 15, weight: .semibold))
            VStack(spacing: 16) {
              if direction == "to_spot" {
                moneyRow("合约超出保留额", key: "futures_collect")
                moneyRow("资金账户可划转", key: "funding_collect")
              } else {
                moneyRow(direction == "funding_to_futures" ? "资金账户可用" : "现货账户可用",
                  key: direction == "funding_to_futures" ? "funding_available" : "spot_available")
                moneyRow("距合约保留上限", value: gap)
              }
            }.padding(20).background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 16))
          }
          Text(direction == "to_spot"
            ? "合约余额超过止损额的 5 倍时无法开启新一轮交易。确认后，超额部分与资金账户可划转金额一起转入现货。"
            : "按合约距 5 倍止损额的差额补入，最多使用所选账户的可用余额。")
            .font(.system(size: 13)).foregroundStyle(WebTheme.secondary).lineSpacing(5)
        } else {
          VStack(alignment: .leading, spacing: 12) {
            Text("转出账户").font(.system(size: 13, weight: .medium)).foregroundStyle(WebTheme.secondary)
            VStack(spacing: 18) {
              HStack { Label("现货账户", systemImage: "wallet.bifold").font(.system(size: 16, weight: .semibold)); Spacer(); Text("USDT").font(.system(size: 13)).foregroundStyle(WebTheme.muted) }
              moneyRow("现货可用余额", key: "spot_available")
              Divider().overlay(WebTheme.border)
              moneyRow("本次转出金额", key: "operation_amount", emphasis: true)
            }.padding(20).background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 16))
          }
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("收款账号").font(.system(size: 15, weight: .semibold))
              Spacer()
              if preview.value("account_type") == "master" && !preview.value("destination_address", fallback: "").isEmpty {
                Button("管理") { editor = true }.font(.system(size: 14, weight: .medium))
                  .frame(minWidth: 44, minHeight: 44).disabled(busy || pending || submitted)
                  .accessibilityIdentifier("collection.manageAccount")
              }
            }
            if preview.value("account_type") == "master" && preview.value("destination_address", fallback: "").isEmpty {
              Button { editor = true } label: {
                VStack(spacing: 12) {
                  Image(systemName: "plus").font(.system(size: 22, weight: .medium))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(Color.black)
                    .background(WebTheme.brand, in: RoundedRectangle(cornerRadius: 12))
                  Text("添加收款账号").font(.system(size: 15, weight: .medium))
                  Text("设置收款网络与地址").font(.system(size: 13)).foregroundStyle(WebTheme.secondary)
                }.foregroundStyle(WebTheme.text).frame(maxWidth: .infinity).padding(.vertical, 24)
                  .background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                  .overlay { RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, style: StrokeStyle(lineWidth: 1, dash: [6, 4])) }
                  .contentShape(RoundedRectangle(cornerRadius: 16))
              }.buttonStyle(.plain).disabled(busy || pending || submitted)
                .accessibilityIdentifier("collection.addAccount")
            } else {
              USDTCollectionAccountCard(data: preview == .null ? .null : .object([
                "account_type": preview["account_type"] ?? .null,
                "capital_collect_address": preview["destination_address"] ?? .null,
                "capital_collect_network": preview["destination_network"] ?? .null,
              ]))
            }
          }
          Text("转出金额按现货可用余额计算。子账户转至所属主账户；主账户按已设置的链和地址转出，以交易所最终回执为准。")
            .font(.system(size: 13)).foregroundStyle(WebTheme.secondary).lineSpacing(5)
        }
        if busy { HStack(spacing: 8) { ProgressView(); Text(submitted ? "正在提交，请稍候…" : "正在读取资金状态…") }.font(.system(size: 13)).foregroundStyle(WebTheme.secondary) }
        if completed { Label("本次操作已完成", systemImage: "checkmark.circle.fill").foregroundStyle(WebTheme.success).font(.system(size: 15, weight: .semibold)).accessibilityIdentifier("capital.completed") }
        if !notice.isEmpty { Text(notice).font(.system(size: 13)).foregroundStyle(WebTheme.secondary).lineSpacing(5).accessibilityIdentifier("capital.notice") }
        if !busy && preview.value("status") == "ready" && !completed {
          Text(tab == .transfer ? "暂无可转出的现货资金" : "当前方向暂无可划转金额")
            .font(.system(size: 14)).foregroundStyle(WebTheme.muted)
        }
      }.padding(20)
    }.scrollIndicators(.hidden)
  }
  private var walletFooter: some View {
    VStack(spacing: 12) {
      moneyRow(legacyPending ? "原归集转出金额" : tab == .transfer ? "本次转出金额" : direction == "to_spot" ? "合计划转到现货" : "本次转入合约",
        key: legacyPending ? "transfer_amount" : "operation_amount", emphasis: true).accessibilityIdentifier("capital.total")
      Button(busy ? "处理中…" : completed ? "完成" : legacyPending ? "核对之前的归集" : pending ? "核对 / 继续原操作" : tab == .transfer ? "转账" : "确定划转") {
        if completed { dismiss() } else if legacyPending { legacy = true } else { Task { await execute() } }
      }.buttonStyle(WebButtonStyle(height: 48, radius: 12)).disabled(busy || (!completed && !legacyPending && !canSubmit))
        .accessibilityIdentifier("capital.submit")
      if !busy && !pending && !completed {
        Button("刷新金额") { Task { await load() } }.font(.system(size: 13)).foregroundStyle(WebTheme.secondary).frame(minHeight: 44)
          .accessibilityIdentifier("capital.refresh")
      }
    }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8).background(WebTheme.page)
  }
  private var gap: String {
    guard let maximum = preview["maximum_futures_balance"]?.decimal,
      let futures = preview["futures_balance"]?.decimal else { return "--" }
    return NSDecimalNumber(decimal: max(0, maximum - futures)).stringValue
  }
  private var walletCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack { Label("合约账户", systemImage: "chart.line.uptrend.xyaxis").font(.system(size: 16, weight: .semibold)); Spacer(); Text("USDT").font(.system(size: 13)).foregroundStyle(WebTheme.muted) }
      Text(formatted(preview.value("futures_balance"))).font(.system(size: 32, weight: .bold)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.6)
      Divider().overlay(WebTheme.border)
      moneyRow("保留上限 · 止损额 × 5", key: "maximum_futures_balance")
    }.padding(20).background(WebTheme.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
      .overlay { RoundedRectangle(cornerRadius: 16).stroke(WebTheme.brand.opacity(0.2), lineWidth: 1) }
  }
  private func moneyRow(_ label: String, key: String, emphasis: Bool = false) -> some View {
    moneyRow(label, value: preview.value(key), emphasis: emphasis)
  }
  private func moneyRow(_ label: String, value: String, emphasis: Bool = false) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label).font(.system(size: 13)).foregroundStyle(WebTheme.secondary).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Text(formatted(value) + " USDT").font(.system(size: emphasis ? 20 : 14, weight: emphasis ? .bold : .medium))
        .monospacedDigit().multilineTextAlignment(.trailing).foregroundStyle(emphasis ? WebTheme.text : WebTheme.secondary)
    }.accessibilityElement(children: .combine)
  }
  private func formatted(_ value: String) -> String {
    guard let amount = Decimal(string: value) else { return "--" }
    return amount.formatted(.number.precision(.fractionLength(2)))
  }
  private func apply(_ result: JSONValue) {
    preview = .object(preview.fields.merging(result.fields) { _, new in new })
    if result.value("status") == "collection_pending" {
      let operation = result.value("operation", fallback: "")
      if operation == "transfer" { tab = .transfer }
      else if ["to_spot", "funding_to_futures", "spot_to_futures"].contains(operation) {
        direction = operation
        tab = .move
      }
    }
    notice = result.value("message", fallback: result.value("collection_error", fallback: ""))
    if result["plan_changed"]?.flag == true { notice = "余额或收款设置已变化，请核对最新金额后再次确认。" }
  }
  private func load() async {
    guard !busy else { return }
    let scope = store.scope
    let requestedAction = action
    busy = true
    preview = .null
    notice = ""
    defer { if scope == store.scope { busy = false } }
    do {
      let result = try await store.send("/v1/trade/capital/wallet/precheck", ["action": .string(requestedAction)])
      guard !Task.isCancelled, scope == store.scope, requestedAction == action else { return }
      apply(result)
      requestID = UserDefaults.standard.string(forKey: requestStorageKey) ?? UUID().uuidString
    } catch is CancellationError { } catch {
      if scope == store.scope { notice = error.localizedDescription }
    }
  }
  private func execute() async {
    guard canSubmit else { return }
    let scope = store.scope
    let storageKey = requestStorageKey
    busy = true
    submitted = true
    UserDefaults.standard.set(requestID, forKey: storageKey)
    defer { if scope == store.scope { busy = false } }
    var payload: [String: JSONValue] = ["action": .string(action), "request_id": .string(requestID),
      "expected_plan": preview["plan_token"] ?? .string("")]
    if pending { payload["collection_id"] = preview["collection_id"] }
    do {
      let result = try await store.send("/v1/trade/capital/wallet/execute", payload)
      guard scope == store.scope else { return }
      apply(result)
      if result.value("status") != "collection_pending" {
        submitted = false
        UserDefaults.standard.removeObject(forKey: storageKey)
        requestID = UUID().uuidString
      }
      await store.refresh()
    } catch {
      if scope == store.scope { notice = error.localizedDescription + "。请核对原操作结果后重试。" }
    }
  }
}

struct USDTCollectionAccountCard: View {
  let data: JSONValue
  private var address: String { data.value("capital_collect_address", fallback: "") }
  static func masked(_ address: String) -> String {
    guard address.count > 12 else { return address.isEmpty ? "未设置收款账号" : String(address.prefix(2)) + "••••" + String(address.suffix(2)) }
    return String(address.prefix(6)) + "••••••" + String(address.suffix(4))
  }
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "building.columns").font(.system(size: 20)).foregroundStyle(WebTheme.brand)
        .frame(width: 40, height: 40).background(WebTheme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
      VStack(alignment: .leading, spacing: 8) {
        if data == .null || data.fields.isEmpty {
          Text("正在读取收款账号…").font(.system(size: 14)).foregroundStyle(WebTheme.secondary)
        } else if data.value("account_type") == "sub" {
          Text("所属主账户").font(.system(size: 15, weight: .semibold))
          Text("币安站内 · 自动识别所属账号").font(.system(size: 13)).foregroundStyle(WebTheme.secondary)
        } else if data.value("account_type") != "master" {
          Text("暂无法读取收款账号").font(.system(size: 14)).foregroundStyle(WebTheme.secondary)
          Text("请刷新资金状态后重试").font(.system(size: 13)).foregroundStyle(WebTheme.muted)
        } else {
          Text(address.isEmpty ? "收款账号" : data.value("capital_collect_network", fallback: "--") + " · USDT")
            .font(.system(size: 15, weight: .semibold))
          Text(Self.masked(address)).font(.system(size: 14, design: .monospaced)).foregroundStyle(WebTheme.secondary)
            .textSelection(.disabled).lineLimit(1).minimumScaleFactor(0.7)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.padding(16).background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 16))
      .overlay { RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1) }
      .accessibilityElement(children: .combine).accessibilityIdentifier("collection.account")
  }
}

struct USDTLegacyCapitalView: View {
  @Environment(\.webDismiss) private var dismiss
  @EnvironmentObject private var store: USDTStore
  @State private var notice = ""
  @State private var preview: JSONValue = .null
  @State private var confirm = false
  @State private var busy = false
  @State private var followup: Task<Void, Never>?
  var body: some View {
    WebFinanceModal(title: capitalTitle) {
      if !capitalExplanation.isEmpty {
        Text(capitalExplanation).font(.system(size: 14)).foregroundStyle(WebTheme.secondary)
          .lineSpacing(6)
      }
      if ["normalization_required", "collection_pending", "shortfall", "ready"].contains(
        preview.value("status"))
      {
        VStack(spacing: 0) {
          WebFinanceRow(
            label: "开仓最低线",
            value: amount(
              preview.value("minimum_open_balance", fallback: preview.value("refill_trigger"))))
          WebFinanceRow(
            label: "合约最高保留",
            value: amount(
              preview.value(
                "maximum_futures_balance",
                fallback: preview.value("upper_limit", fallback: preview.value("target")))))
          if preview["futures_balance"] != nil {
            WebFinanceRow(label: "合约余额", value: amount(preview.value("futures_balance")))
          }
          ForEach(
            [
              ("资金 → 合约", "funding_to_futures"), ("现货 → 合约", "spot_to_futures"),
              ("合约 → 现货", "futures_collect"), ("资金 → 现货", "funding_collect"),
              ("现货 → 主账户", "transfer_amount"),
            ], id: \.0
          ) { label, key in
            if (collection[key]?.decimal ?? 0) > 0 {
              WebFinanceRow(
                label: label, value: amount(collection.value(key)),
                color: key == "transfer_amount" ? WebTheme.brand : .white)
            }
          }
          if !collection.value("destination_address", fallback: "").isEmpty {
            WebFinanceRow(
              label: "目标 Spot 地址",
              value: collection.value("destination_address") + " ("
                + collection.value("destination_network") + ")")
          }
          if preview.value("status") == "shortfall" {
            WebFinanceRow(label: "账户总余额", value: amount(preview.value("account_total")))
            WebFinanceRow(
              label: "至少补充", value: amount(preview.value("minimum_topup")), color: WebTheme.danger)
            WebFinanceRow(
              label: "最多补充", value: amount(preview.value("maximum_topup")), color: WebTheme.brand)
          }
        }.overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) }
      }
      if preview.value("status") == "normalization_required" {
        Text("确认后按上方计划保留合约资金，将超额部分转出；合约不足保留上限时，先从其他钱包补足。结果未确认前不会重复转账。").font(.system(size: 12))
          .foregroundStyle(WebTheme.secondary).lineSpacing(5)
      }
      if pendingID != nil {
        Text(collection.value("collection_error", fallback: "交易所划转结果正在确认，可重新确认结果。归集确认不影响开仓判定。"))
          .font(.system(size: 12)).foregroundStyle(WebTheme.brand).lineSpacing(5)
      }
      USDTNotice(text: notice)
      HStack(spacing: 12) {
        Button(canNormalize ? "取消" : "知道了") { dismiss() }.buttonStyle(
          WebButtonStyle(kind: .secondary))
        if canNormalize {
          Button(busy ? "处理中..." : pendingID != nil ? "重新确认结果" : "确认调整") { confirm = true }
            .buttonStyle(WebButtonStyle()).disabled(busy)
        }
      }.padding(.top, 4)
    }.task { loadPreview() }.onDisappear {
      followup?.cancel()
      followup = nil
    }
    .onChange(of: store.scope) { _, _ in
      followup?.cancel()
      followup = nil
      preview = .null
      busy = false
    }
    .webModal(isPresented: $confirm) {
      WebModal(title: "确认资金整理") {
        Text("请确认金额、网络与目标地址。").foregroundStyle(WebTheme.secondary)
        USDTMetric(
          title: "金额（USDT）",
          value: collection.value("transfer_amount", fallback: collection.value("collection_total"))
        )
        USDTMetric(title: "网络", value: collection.value("destination_network"))
        USDTMetric(title: "地址", value: collection.value("destination_address"))
        HStack(spacing: 12) {
          Button("取消") { confirm = false }.buttonStyle(WebButtonStyle(kind: .secondary))
          Button(pendingID == nil ? "确认整理" : "继续核对") {
            confirm = false
            normalize()
          }.buttonStyle(WebButtonStyle())
        }
      }
    }
  }
  private var capitalTitle: String {
    pendingID != nil
      ? "确认归集结果"
      : preview.value("reason") == "normalization_completed"
        ? "资金调整完成"
        : preview.value("status") == "ready" || preview.value("status") == "not_required"
          ? "无需归集" : preview.value("status") == "normalization_required" ? "调整账户资金" : "暂时无法归集"
  }
  private var capitalExplanation: String {
    if preview.value("status") == "blocked" {
      return preview.value("reason") == "active_position"
        ? "交易所当前存在真实持仓。持仓期间资金作为保证金使用，不能执行余额归集。"
        : preview.value("message", fallback: "交易所仍有未成交的普通挂单或条件单。请先处理挂单，再执行余额归集。")
    }
    if ["ready", "not_required"].contains(preview.value("status")) {
      return preview.value("reason") == "normalization_completed"
        ? preview.value("message", fallback: "本次资金调整已完成。") : "当前没有超过保留上限的可归集资金。"
    }
    return ""
  }
  private func amount(_ value: String) -> String {
    guard let decimal = Decimal(string: value) else { return "--" }
    return String(format: "%.2f U", NSDecimalNumber(decimal: decimal).doubleValue)
  }
  private var collection: JSONValue {
    preview.value("status") == "collection_pending"
      ? preview : preview["pending_collection"] ?? preview
  }
  private var pendingID: JSONValue? {
    guard preview.value("status") == "collection_pending" || preview["pending_collection"] != nil
    else { return nil }
    let value = collection["collection_id"]
    return value == .null ? nil : value
  }
  private var canNormalize: Bool {
    pendingID != nil
      || (preview.value("status") == "normalization_required"
        && !preview.value("plan_token", fallback: "").isEmpty)
  }
  private func normalize() {
    let scope = store.scope
    let original = preview
    let originalID = pendingID
    busy = true
    followup?.cancel()
    followup = Task {
      defer { if scope == store.scope { busy = false } }
      var id = originalID
      for delay in [0, 2, 5, 10, 20, 30, 30, 30] {
        do {
          if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
          guard !Task.isCancelled, scope == store.scope else { return }
          var payload: [String: JSONValue] = [
            "expected_status": .string(id == nil ? "normalization_required" : "collection_pending"),
            "purpose": .string("manual_sweep"),
          ]
          if let id {
            payload["collection_id"] = id
          } else {
            payload["expected_plan"] = original["plan_token"]
            preview = .null
          }
          let result = try await store.send("/v1/trade/capital/normalize", payload)
          guard !Task.isCancelled, scope == store.scope else { return }
          preview = result
          notice = result.value("message", fallback: result.value("status"))
          guard result.value("status") == "collection_pending",
            let nextID = result["collection_id"], nextID != .null
          else {
            await store.refresh()
            return
          }
          guard id == nil || id == nextID else {
            notice = "流水已变化，请重新检查资金状态"
            return
          }
          id = nextID
        } catch is CancellationError { return } catch {
          guard scope == store.scope else { return }
          notice = error.localizedDescription
          if id == nil {
            notice += "。请求结果未确认，请重新预览核对。"
            return
          }
        }
      }
      notice = "归集仍在确认，请稍后继续核对同一流水。"
    }
  }
  private func loadPreview() {
    busy = true
    Task {
      defer { busy = false }
      do {
        preview = try await store.send(
          "/v1/trade/capital/precheck", ["purpose": .string("manual_sweep")])
        notice = preview.value("message", fallback: "请核对资金状态")
      } catch { notice = error.localizedDescription }
    }
  }
}

struct USDTSettingsView: View {
  @EnvironmentObject private var store: USDTStore
  @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .defaultValue
  @State private var enabled = false
  @State private var isAdmin = false
  @State private var saving = false
  @State private var notice = ""
  var body: some View {
    WebForm {
      HStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 14).fill(
          WebTheme.color(0xFEF9C3, 0xF0B90B).opacity(appearance == .dark ? 0.1 : 1)
        ).frame(width: 40, height: 40).overlay {
          WebIcon(appearance == .dark ? "moon" : "sun", size: 20).foregroundStyle(WebTheme.brand)
        }
        Text("颜色模式").font(.system(size: 16, weight: .medium))
        Spacer()
        Text(appearance == .dark ? "深色" : "浅色").font(.system(size: 14, weight: .medium))
          .foregroundStyle(WebTheme.secondary)
        Button {
          appearance = appearance == .dark ? .light : .dark
        } label: {
          Capsule().fill(WebTheme.color(0xE5E7EB, 0x2B2F36)).frame(width: 48, height: 28)
            .overlay(alignment: appearance == .dark ? .trailing : .leading) {
              Circle().fill(
                appearance == .dark ? AnyShapeStyle(WebTheme.gradient) : AnyShapeStyle(.white)
              ).frame(width: 20, height: 20).padding(4).shadow(
                color: .black.opacity(0.15), radius: 2, y: 2)
            }
        }.accessibilityLabel("切换颜色模式").accessibilityValue(appearance == .dark ? "深色" : "浅色")
      }.padding(16).background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 16)).overlay {
        RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1)
      }
      if isAdmin {
        WebSection {
          WebLabel("管理员", "gearshape").font(.system(size: 14)).foregroundStyle(WebTheme.secondary)
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("开放注册").font(.system(size: 16, weight: .medium))
              Text("开启后其他用户可以注册新账号；关闭后注册将被拒绝").font(.system(size: 12)).foregroundStyle(
                WebTheme.muted)
            }
            Toggle("开放注册", isOn: Binding(get: { enabled }, set: { value in save(value) }))
              .labelsHidden().toggleStyle(WebSwitchStyle()).frame(width: 48).disabled(saving)
          }
        }
      }
      USDTNotice(text: notice)
    }.usdtPage("设置").task {
      if let result = try? await store.get("/v1/auth/admin-settings") {
        isAdmin = result["is_admin"]?.flag ?? false
        enabled = result["open_registration"]?.flag ?? false
      }
    }
  }
  private func save(_ value: Bool) {
    saving = true
    Task {
      defer { saving = false }
      do {
        _ = try await store.send("/v1/auth/admin-settings", ["open_registration": .bool(value)])
        enabled = value
      } catch { notice = error.localizedDescription }
    }
  }
}

struct USDTCollectAccountView: View {
  @EnvironmentObject private var store: USDTStore
  @Environment(\.webDismiss) private var dismiss
  @State private var address = ""
  @State private var network = ""
  @State private var accountType = ""
  @State private var configured = false
  @State private var busy = false
  @State private var notice = ""
  var body: some View {
    WebModal(title: "资金归集账号") {
      if accountType == "sub" {
        Text("当前是子账户，资金将归集到该账户从属的主账户，无需配置归集账户。").font(.system(size: 14)).foregroundStyle(
          WebTheme.success
        ).padding(16).background(WebTheme.input, in: RoundedRectangle(cornerRadius: 14))
        Button("知道了") { dismiss() }.buttonStyle(WebButtonStyle(radius: 14))
      } else if accountType == "master" {
        Text(
          "当绑定的是币安主账户时，系统会使用 Spot 提现接口向目标主账户的充值地址发起申请。如果地址属于 Binance 且 Fast Withdraw 条件满足，通常会内部到账、无需上链；请以目标主账户 Spot 充值页面显示的网络和地址为准。子账户归集到所属主账户时无需配置。"
        ).font(.system(size: 12)).foregroundStyle(WebTheme.muted).lineSpacing(4)
        WebSelect(
          selection: $network,
          options: [
            ("", "请选择网络"), ("BSC", "BSC（BEP20）"), ("TRX", "TRX（TRC20）"), ("ETH", "ETH（ERC20）"),
          ])
        USDTField(title: "", text: $address, placeholder: "目标主账户 Spot 充值地址（与网络匹配）", radius: 14)
        VStack(alignment: .leading, spacing: 4) {
          Text("支持网络：BSC（BEP20）、TRX（TRC20）、ETH（ERC20）").foregroundStyle(WebTheme.success)
          Text("当前资金归集仅支持以上三种网络，请确保充值地址与所选网络一致。").font(.system(size: 12)).foregroundStyle(
            WebTheme.muted)
        }.padding(16).background(WebTheme.input, in: RoundedRectangle(cornerRadius: 14))
        HStack(spacing: 12) {
          Button("取消") { dismiss() }.buttonStyle(WebButtonStyle(kind: .secondary, radius: 14))
          if configured {
            Button("清除") {
              address = ""
              network = ""
              save()
            }.buttonStyle(WebButtonStyle(kind: .secondary, radius: 14)).foregroundStyle(
              WebTheme.danger
            ).disabled(busy)
          }
          Button(busy ? "保存中…" : "保存") { save() }.buttonStyle(WebButtonStyle(radius: 14)).disabled(
            busy || address.isEmpty || network.isEmpty)
        }
      } else {
        Text(store.isBound ? "暂时无法确认当前 Binance 账户类型，请刷新页面后重试。" : "请先绑定 Binance API。").font(
          .system(size: 14)
        ).foregroundStyle(WebTheme.muted)
        Button("知道了") { dismiss() }.buttonStyle(WebButtonStyle(radius: 14))
      }
      USDTNotice(text: notice)
    }.task {
      do {
        let data = try await store.get("/v1/account/capital-collect-account")
        address = data.value("capital_collect_address", fallback: "")
        network = data.value("capital_collect_network", fallback: "")
        configured = !address.isEmpty
        accountType = data.value("account_type", fallback: "")
      } catch { notice = error.localizedDescription }
    }
  }
  private func save() {
    busy = true
    Task {
      defer { busy = false }
      do {
        _ = try await store.send(
          "/v1/account/capital-collect-account",
          [
            "capital_collect_address": .string(address),
            "capital_collect_network": .string(network),
          ])
        dismiss()
      } catch { notice = error.localizedDescription }
    }
  }
}

struct USDTCapitalReminderView: View {
  @EnvironmentObject private var store: USDTStore
  @Environment(\.webDismiss) private var dismiss
  @State private var preview: JSONValue = .null
  @State private var busy = false
  @State private var notice = ""
  var body: some View {
    WebFinanceModal(title: "补资提醒预览", icon: "mail") {
      VStack(spacing: 0) {
        WebFinanceRow(label: "账户总余额", value: amount(preview.value("account_total")))
        WebFinanceRow(
          label: "开仓最低线",
          value: amount(
            preview.value("minimum_open_balance", fallback: preview.value("refill_trigger"))))
        WebFinanceRow(
          label: "补资上限",
          value: amount(preview.value("maximum_futures_balance", fallback: preview.value("target")))
        )
        WebFinanceRow(
          label: "至少补充",
          value: amount(
            preview.value("minimum_topup", fallback: preview.value("remaining_after_transfer"))),
          color: WebTheme.danger)
        WebFinanceRow(
          label: "最多补充", value: amount(preview.value("maximum_topup")), color: WebTheme.brand)
        WebFinanceRow(
          label: "建议转入", value: amount(preview.value("recommended_topup")), color: WebTheme.brand)
      }.overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) }
      VStack(alignment: .leading, spacing: 8) {
        Text("邮件标题").font(.system(size: 12)).foregroundStyle(WebTheme.muted)
        Text(preview.value("email_subject", fallback: "")).font(.system(size: 14)).padding(
          .horizontal, 12
        ).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).background(
          .black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("邮件正文").font(.system(size: 12)).foregroundStyle(WebTheme.muted)
        Text(preview.value("email_body", fallback: "")).font(.system(size: 14)).lineSpacing(6)
          .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
            .black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
      }
      USDTNotice(text: notice)
      HStack(spacing: 12) {
        Button("取消") { dismiss() }.buttonStyle(WebButtonStyle(kind: .secondary))
        Button(busy ? "发送中..." : "发送通知") {
          busy = true
          Task {
            defer { busy = false }
            do {
              _ = try await store.send("/v1/trade/capital/remind")
              dismiss()
            } catch { notice = error.localizedDescription }
          }
        }.buttonStyle(WebButtonStyle()).disabled(busy || preview.value("status") != "shortfall")
      }
    }.task {
      do { preview = try await store.get("/v1/trade/capital/remind") } catch {
        notice = error.localizedDescription
      }
    }
  }
  private func amount(_ value: String) -> String {
    guard let decimal = Decimal(string: value) else { return "--" }
    return String(format: "%.2f U", NSDecimalNumber(decimal: decimal).doubleValue)
  }

}

/// Same 1 / 5 / 10 USDT steps as the Web stop-loss preview; all arithmetic stays decimal.
enum WebStopLossAmount {
  static func roundUp(_ value: Decimal) -> Decimal {
    let step: Decimal = value < 20 ? 1 : value < 100 ? 5 : 10
    var units = value / step
    var rounded = Decimal()
    NSDecimalRound(&rounded, &units, 0, .up)
    return max(step, rounded * step)
  }
}
