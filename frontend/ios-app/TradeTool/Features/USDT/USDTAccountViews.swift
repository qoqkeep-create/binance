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
  @State private var collect = false
  @State private var normalize = false
  @State private var modeConfirm = false
  @State private var version: JSONValue = .null
  @State private var collectAccount: JSONValue = .null
  @Environment(\.colorScheme) private var scheme
  private var lead: Bool { store.mode == "lead" }
  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 0) {
          if !store.isBound {
            Button {
              binding = true
            } label: {
              WebLabel("请先绑定 API", "link")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(WebTheme.color(0x16734B, 0x7FE0AE))
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(WebTheme.color(0xE3F5EA, 0x203E34), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).accessibilityIdentifier("profile.bind")
              .padding(.bottom, 20)
          }
          if store.isBound || lead || version["lead_trading_enabled"]?.flag == true
            || version["lead_trading_bound"]?.flag == true {
          HStack(alignment: .top, spacing: 12) {
            if store.isBound {
              AsyncImage(url: URL(string: store.profile.value("avatar_url", fallback: ""))) {
                phase in
                if let image = phase.image {
                  image.resizable().scaledToFill()
                } else {
                  RoundedRectangle(cornerRadius: 14).fill(WebTheme.gradient).overlay {
                    Text("B").font(.system(size: 20, weight: .bold)).foregroundStyle(.black)
                  }
                }
              }.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 14))
              VStack(alignment: .leading, spacing: 0) {
                Text(store.binding.value("alias", fallback: store.profile.value("display_name")))
                  .font(.system(size: 16, weight: .bold)).lineLimit(1).frame(height: 24).padding(
                    .bottom, 4)
                Text(
                  collectAccount.value("account_type") == "master"
                    ? "主账户" : collectAccount.value("account_type") == "sub" ? "子账户" : "账户类型同步中"
                ).font(.system(size: 12, weight: .semibold)).foregroundStyle(WebTheme.brand)
                  .padding(.horizontal, 6).frame(height: 18).background(
                    WebTheme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 8)
                  ).overlay {
                    RoundedRectangle(cornerRadius: 8).stroke(
                      WebTheme.brand.opacity(0.25), lineWidth: 1)
                  }
                Button("解除 API 绑定") { binding = true }.font(.system(size: 12)).underline()
                  .foregroundStyle(WebTheme.danger).frame(height: 32)
              }
            }
            Spacer(minLength: 0)
            if lead || version["lead_trading_enabled"]?.flag == true
              || version["lead_trading_bound"]?.flag == true
            {
              Button(lead ? "切换合约模式" : "切换带单模式") { modeConfirm = true }.font(
                .system(size: 12, weight: .medium)
              ).padding(.horizontal, 10).padding(.vertical, 10).background(
                WebTheme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 10)
              ).overlay {
                RoundedRectangle(cornerRadius: 10).stroke(WebTheme.brand.opacity(0.3), lineWidth: 1)
              }
            }
          }.padding(.bottom, 20)
          }
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
                  normalize = true
                } label: {
                  WebLabel("归集余额", "wallet.bifold")
                }.buttonStyle(WebButtonStyle(height: 36, fontSize: 12, fullWidth: false)).disabled(
                  !canCollect)
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
              collect = true
            } label: {
              menuRow(
                "资金归集账号", "paperplane",
                value: collectAccount.value("account_type") == "sub"
                  ? "所属主账户"
                  : collectAccount.value("capital_collect_address", fallback: "").isEmpty
                    ? "未配置" : "已配置")
            }
            separator
            NavigationLink {
              USDTRecordsView(kind: .transfers)
            } label: {
              menuRow("转账历史", "clock.arrow.circlepath")
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
        version = (try? await store.get("/v1/account/version")) ?? .null
        collectAccount = (try? await store.get("/v1/account/capital-collect-account")) ?? .null
      }.refreshable { await store.refresh() }
      .webModal(isPresented: $binding, motion: .fade) { USDTBindingView() }
      .webModal(isPresented: $stopLoss) { USDTStopLossView() }
      .webModal(isPresented: $collect) {
        USDTCollectAccountView().onDisappear {
          Task {
            collectAccount = (try? await store.get("/v1/account/capital-collect-account")) ?? .null
          }
        }
      }
      .webModal(isPresented: $normalize) { USDTCapitalView() }
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
  private var usableTotal: Decimal {
    (store.account["balance"]?.decimal ?? 0)
      + ["spot_balance", "funding_balance"].reduce(Decimal.zero) { sum, key in
        let amount = store.account[key]?.decimal ?? 0
        return sum + (amount >= 1 ? amount : 0)
      }
  }
  private var balancesKnown: Bool {
    store.isBound
      && ["balance", "spot_balance", "funding_balance"].allSatisfy {
        store.account[$0]?.decimal != nil
      } && (Decimal(string: store.riskAmount) ?? 0) > 0
  }
  private var canCollect: Bool {
    balancesKnown
      && usableTotal - (Decimal(string: store.riskAmount) ?? 0) * 5 >= Decimal(string: "0.01")!
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

struct USDTStopLossView: View {
  @EnvironmentObject private var store: USDTStore
  @State private var value: JSONValue = .null
  @State private var percentage = 2
  @State private var loading = true
  @State private var saving = false
  @State private var now = Date()
  @State private var notice = ""
  @State private var confirm = false
  @State private var cancelPending = false
  @State private var completed: (from: Decimal, to: Decimal)?
  var body: some View {
    WebModal(
      title: "止损设置", alignment: .bottom, maximumWidth: 448, titleSize: 20, overlayOpacity: 0.45,
      contentSpacing: 16, closeIconSize: 20, closeButtonSize: 36
    ) {
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
          WebRangeSlider(value: $percentage).disabled(loading)
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
            Text(
              "您已调整止损金额\(value.value("pending_from_amount")) → \(pending.text)，\(countdownText)后生效"
            ).font(
              .system(size: 14))
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
        Button(saving ? "提交中..." : "确定") {
          cancelPending = false
          confirm = true
        }.buttonStyle(
          WebButtonStyle(height: 56, radius: 14, weight: .bold, mutedDisabled: true)
        ).disabled(
          loading || saving || target == (value["current_amount"]?.decimal ?? 0) || balance <= 0)
      }
    }.onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }.task {
      defer { loading = false }
      do {
        value = try await store.get("/v1/account/stop-loss")
        let current = value["current_amount"]?.decimal ?? 0
        if balance > 0 {
          percentage = min(
            25, max(1, Int(NSDecimalNumber(decimal: current / balance * 100).doubleValue.rounded()))
          )
        }
      } catch { notice = error.localizedDescription }
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
  private var countdownText: String {
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

struct USDTCapitalView: View {
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
