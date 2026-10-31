import SwiftUI

struct USDTProfileView: View {
    @EnvironmentObject private var store: USDTStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var runtime: AppRuntime
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .defaultValue
    @State private var logout = false
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                USDTCard {
                    HStack {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 42)).foregroundStyle(BinanceTheme.accentText)
                        VStack(alignment: .leading) {
                            Text(store.profile.value("display_name", fallback: auth.session?.user.displayName ?? "账户")).font(.headline)
                            Text(auth.session?.user.email ?? "").font(.caption).foregroundStyle(BinanceTheme.secondaryText)
                        }
                        Spacer()
                    }
                    Picker("交易模式", selection: Binding(get: { store.mode }, set: { store.switchMode($0) })) {
                        Text("普通账户").tag("ordinary"); Text("带单账户").tag("lead")
                    }.pickerStyle(.segmented)
                }
                USDTCard {
                    Text("账户资产（USDT）").font(.headline)
                    ForEach([("总资产", "total_balance"), ("合约可用", "balance"), ("现货", "spot_balance"), ("资金账户", "funding_balance"), ("今日收益", "today_pnl"), ("单次止损", "stop_loss_amount")], id: \.0) { title, key in USDTMetric(title: title, value: store.account.value(key)) }
                    if store.mode == "ordinary" { NavigationLink("资金管理", destination: USDTCapitalView()) }
                }
                USDTCard {
                    link("API 管理", "key", USDTBindingView())
                    link("止损设置", "shield", USDTStopLossView())
                    link("止盈策略", "slider.horizontal.3", USDTStrategiesView())
                    if store.mode == "ordinary" {
                        link("观察计划", "eye", USDTWatchPlansView())
                        link("信号研究", "waveform.path.ecg", USDTResearchView())
                    }
                    if store.mode == "ordinary" { link("转账历史", "arrow.left.arrow.right", USDTRecordsView(kind: .transfers)) }
                    link("操作日志", "list.bullet.rectangle", USDTRecordsView(kind: .operations))
                    link("交易命令", "clock.arrow.circlepath", USDTCommandsView())
                }
                USDTCard {
                    Picker("外观", selection: $appearance) { Text("浅色").tag(AppAppearance.light); Text("深色").tag(AppAppearance.dark) }
                    link("服务器", "server.rack", ServerSettingsView())
                    link("用户协议与风险提示", "doc.text", USDTLegalView())
                    if auth.session?.user.isAdmin == true { link("管理设置", "person.badge.key", USDTAdminView()) }
                    Button("退出登录", role: .destructive) { logout = true }.frame(maxWidth: .infinity, minHeight: 44)
                }
                USDTNotice(text: store.notice)
                Text("TradeTools · USDT 整合版").font(.caption).foregroundStyle(BinanceTheme.secondaryText)
            }.padding(16)
        }.usdtPage("我的").task(id: store.scope) { await store.refresh() }.refreshable { await store.refresh() }
            .confirmationDialog("退出当前账户？", isPresented: $logout) { Button("退出登录", role: .destructive) { store.invalidate(); auth.logout() } }
    }
    private func link<V: View>(_ title: String, _ icon: String, _ destination: V) -> some View {
        NavigationLink(destination: destination) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(BinanceTheme.secondaryText)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
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
        ScrollView {
            VStack(spacing: 16) {
                USDTCard {
                    Text(store.mode == "lead" ? "带单 API" : "普通 API").font(.headline)
                    if store.isBound {
                        USDTMetric(title: "别名", value: store.binding.value("alias"))
                        USDTMetric(title: "绑定状态", value: store.binding.value("status"))
                        Button("解绑 API", role: .destructive) { unbind = true }.disabled(busy)
                    } else {
                        USDTField(title: "账户别名", text: $alias)
                        USDTField(title: "API Key", text: $apiKey, secure: true)
                        USDTField(title: "Secret Key", text: $secret, secure: true)
                        Button(busy ? "验证中…" : "验证并绑定") { bind() }.buttonStyle(BinancePrimaryButtonStyle()).disabled(busy || apiKey.isEmpty || secret.isEmpty)
                    }
                }
                USDTNotice(text: notice)
                USDTNotice(text: "密钥仅提交服务端验证并加密保存，客户端不保存。每种交易模式独立绑定。")
            }.padding(16)
        }.usdtPage("API 管理").task { await store.refresh() }
            .onDisappear { apiKey = ""; secret = "" }
            .confirmationDialog("确认解绑当前模式的 API？", isPresented: $unbind, titleVisibility: .visible) {
                Button("解绑", role: .destructive) {
                    busy = true
                    Task { defer { busy = false }; do { _ = try await store.send("/v1/api/unbind"); store.invalidate(); await store.refresh(); notice = "已解绑" } catch { notice = error.localizedDescription } }
                }
            }
    }
    private func bind() {
        busy = true
        Task {
            defer { busy = false; apiKey = ""; secret = "" }
            do {
                _ = try await store.send("/v1/api/bind", ["api_key": .string(apiKey), "secret_key": .string(secret), "alias": .string(alias)])
                store.invalidate(); await store.refresh(); notice = "绑定成功"
            } catch { notice = error.localizedDescription }
        }
    }
}

struct USDTStopLossView: View {
    @EnvironmentObject private var store: USDTStore
    @State private var value: JSONValue = .null
    @State private var percentage = 2
    @State private var notice = ""
    @State private var confirm = false
    var body: some View {
        Form {
            Section("单次止损金额") {
                USDTMetric(title: "当前金额", value: value.value("current_amount", fallback: store.riskAmount))
                USDTMetric(title: "待生效金额", value: value.value("pending_amount"))
                Stepper("账户资金的 \(percentage)%", value: $percentage, in: 1...25)
                Button("保存调整") { confirm = true }
                Button("取消待生效调整") { update(cancel: true) }
            }
            Section { Text("生效时间与资金口径按原 USDT 规则执行。").font(.footnote); USDTNotice(text: notice) }
        }.usdtPage("止损设置").task { do { value = try await store.get("/v1/account/stop-loss") } catch { notice = error.localizedDescription } }
            .confirmationDialog("确认调整止损比例为 \(percentage)%？", isPresented: $confirm, titleVisibility: .visible) { Button("保存") { update(cancel: false) } }
    }
    private func update(cancel: Bool) {
        Task { do { value = try await store.send(cancel ? "/v1/account/stop-loss/cancel" : "/v1/account/stop-loss", cancel ? [:] : ["percentage": .number(Double(percentage))]); await store.refresh(); notice = "已更新" } catch { notice = error.localizedDescription } }
    }
}

struct USDTCapitalView: View {
    @EnvironmentObject private var store: USDTStore
    @State private var address = ""
    @State private var network = "BSC"
    @State private var notice = ""
    @State private var preview: JSONValue = .null
    @State private var confirm = false
    @State private var busy = false
    @State private var followup: Task<Void, Never>?
    var body: some View {
        Form {
            Section("账户资金（USDT）") {
                USDTMetric(title: "合约可用", value: store.account.value("balance"))
                USDTMetric(title: "现货", value: store.account.value("spot_balance"))
                USDTMetric(title: "资金账户", value: store.account.value("funding_balance"))
                Button("刷新余额") { Task { await store.refresh() } }
            }
            Section("资金归集目标") {
                USDTField(title: "主账户 Spot 充值地址", text: $address)
                Picker("网络", selection: $network) { Text("BSC / BEP20").tag("BSC"); Text("TRX / TRC20").tag("TRX"); Text("ETH / ERC20").tag("ETH") }
                Button("保存归集目标") {
                    Task { do { _ = try await store.send("/v1/account/capital-collect-account", ["capital_collect_address": .string(address), "capital_collect_network": .string(address.isEmpty ? "" : network)]); notice = "已保存" } catch { notice = error.localizedDescription } }
                }
            }
            Section("资金状态") {
                Button("检查开仓资金") { Task { do { preview = try await store.send("/v1/trade/capital/precheck", ["purpose": .string("entry")]); notice = preview.value("message", fallback: preview.value("status")) } catch { notice = error.localizedDescription } } }
                Button("预览资金整理") { loadPreview() }.disabled(busy)
                if !preview.fields.isEmpty {
                    USDTMetric(title: "状态", value: preview.value("status"))
                    USDTMetric(title: "最低补充", value: preview.value("minimum_topup"))
                    USDTMetric(title: "最高补充", value: preview.value("maximum_topup"))
                    ForEach([("合约保留上限", "maximum_futures_balance"), ("合约转出", "futures_collect"), ("资金账户转出", "funding_collect"), ("现货转出", "spot_collect"), ("归集合计", "collection_total"), ("本次金额", "transfer_amount"), ("转账路径", "transfer_path"), ("结算方式", "settlement_method"), ("目标地址", "destination_address"), ("目标网络", "destination_network"), ("归集流水", "collection_id"), ("处理中原因", "collection_error")], id: \.0) { title, key in
                        if let field = collection[key] ?? preview[key], field != .null, !field.text.isEmpty {
                            USDTMetric(title: title, value: field.text)
                        }
                    }
                }
                Button(pendingID == nil ? "确认执行资金整理" : "继续核对归集结果") { confirm = true }.disabled(busy || !canNormalize)
                Button("发送资金提醒") { Task { do { let value = try await store.send("/v1/trade/capital/remind"); notice = value.value("message", fallback: "提醒已提交") } catch { notice = error.localizedDescription } } }
            }
            USDTNotice(text: notice)
        }.usdtPage("资金管理").task {
            do { let result = try await store.get("/v1/account/capital-collect-account"); address = result.value("capital_collect_address", fallback: ""); network = result.value("capital_collect_network", fallback: "BSC") } catch { notice = error.localizedDescription }
        }.onDisappear { followup?.cancel(); followup = nil }
        .onChange(of: store.scope) { _, _ in followup?.cancel(); followup = nil; preview = .null; busy = false }
        .confirmationDialog("确认资金整理？金额 \(collection.value("transfer_amount", fallback: collection.value("collection_total"))) USDT，网络 \(collection.value("destination_network"))，地址 \(collection.value("destination_address"))。", isPresented: $confirm, titleVisibility: .visible) {
            Button(pendingID == nil ? "确认整理" : "继续核对") { normalize() }
        }
    }
    private var collection: JSONValue { preview.value("status") == "collection_pending" ? preview : preview["pending_collection"] ?? preview }
    private var pendingID: JSONValue? {
        guard preview.value("status") == "collection_pending" || preview["pending_collection"] != nil else { return nil }
        let value = collection["collection_id"]
        return value == .null ? nil : value
    }
    private var canNormalize: Bool {
        pendingID != nil || (preview.value("status") == "normalization_required" && (preview["transfer_amount"]?.decimal ?? preview["collection_total"]?.decimal ?? 0) >= Decimal(string: "0.01")!)
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
                    var payload: [String: JSONValue] = ["expected_status": .string(id == nil ? "normalization_required" : "collection_pending"), "purpose": .string("manual_sweep")]
                    if let id { payload["collection_id"] = id }
                    else { payload["expected_plan"] = original["plan_token"]; preview = .null }
                    let result = try await store.send("/v1/trade/capital/normalize", payload)
                    guard !Task.isCancelled, scope == store.scope else { return }
                    preview = result
                    notice = result.value("message", fallback: result.value("status"))
                    guard result.value("status") == "collection_pending", let nextID = result["collection_id"], nextID != .null else {
                        await store.refresh(); return
                    }
                    guard id == nil || id == nextID else { notice = "流水已变化，请重新检查资金状态"; return }
                    id = nextID
                } catch is CancellationError { return }
                catch {
                    guard scope == store.scope else { return }
                    notice = error.localizedDescription
                    if id == nil { notice += "。请求结果未确认，请重新预览核对。"; return }
                }
            }
            notice = "归集仍在确认，请稍后继续核对同一流水。"
        }
    }
    private func loadPreview() {
        busy = true
        Task { defer { busy = false }; do { preview = try await store.send("/v1/trade/capital/precheck", ["purpose": .string("manual_sweep")]); notice = preview.value("message", fallback: "请核对资金状态") } catch { notice = error.localizedDescription } }
    }
}

struct USDTAdminView: View {
    @EnvironmentObject private var store: USDTStore
    @State private var enabled = false
    @State private var notice = ""
    var body: some View {
        Form {
            Toggle("开放用户注册", isOn: $enabled)
            Button("保存") { Task { do { _ = try await store.send("/v1/auth/admin-settings", ["open_registration": .bool(enabled)]); notice = "已保存" } catch { notice = error.localizedDescription } } }
            USDTNotice(text: notice)
        }.usdtPage("管理设置").task {
            do { let result = try await store.get("/v1/auth/admin-settings"); enabled = result["open_registration"]?.flag ?? false } catch { notice = error.localizedDescription }
        }
    }
}
