import SwiftUI

struct USDTSignalsView: View {
    @EnvironmentObject private var store: USDTStore
    @StateObject private var model = USDTPageModel()
    @State private var source = "external"
    let openChart: (String, String) -> Void
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack { Text("信号").font(.title2.bold()); Spacer(); NavigationLink("观察计划", destination: USDTWatchPlansView()) }
                Picker("信号来源", selection: $source) { Text("外部信号").tag("external"); Text("自有扫描").tag("internal"); Text("TradingView").tag("tradingview") }.pickerStyle(.segmented)
                ForEach(Array(model.items.enumerated()), id: \.offset) { _, row in
                    USDTCard {
                        HStack { Text(row.value("symbol")).font(.headline); Spacer(); Text(row.value("direction")).foregroundStyle(row.value("direction") == "LONG" ? BinanceTheme.positive : BinanceTheme.negative) }
                        Text(row.value("title", fallback: row.value("strategy"))).font(.subheadline.bold())
                        USDTMetric(title: "周期 / 价格", value: "\(row.value("interval")) / \(row.value("price_display"))")
                        Text(row.value("comment", fallback: "")).font(.footnote)
                        if source == "internal" {
                            USDTMetric(title: "评分 / 决策", value: "\(row.value("score")) / \(row.value("final_action"))")
                            Text(row.value("entry_condition", fallback: "")).font(.footnote)
                            ForEach(Array((row["risk_points"]?.rows ?? []).enumerated()), id: \.offset) { _, risk in Text(risk.text).font(.caption).foregroundStyle(BinanceTheme.secondaryText) }
                        }
                        Text(row.value("signal_time", fallback: row.value("received_at"))).font(.caption).foregroundStyle(BinanceTheme.secondaryText)
                        Button("查看 K 线") { openChart(row.value("symbol"), row.value("interval")) }.buttonStyle(.bordered)
                    }
                }
                if model.items.isEmpty { USDTEmptyState(title: "暂无信号", error: model.error) { Task { await load() } } }
            }.padding(16)
        }.usdtPage("信号").task(id: "\(store.scope):\(source)") { await load() }.refreshable { await load() }
    }
    private func load() async { await model.load(store, path: "/v1/trade/tradingview/signals", query: [.init(name: "source", value: source)]) }
}

struct USDTRecordsView: View {
    enum Kind {
        case transfers, operations, strategyLog(String)
        var title: String { switch self { case .transfers: "转账历史"; case .operations: "操作日志"; case .strategyLog: "策略执行记录" } }
        var path: String { switch self { case .transfers: "/v1/account/transfer-history"; case .operations: "/v1/account/operation-logs"; case .strategyLog: "/v1/strategy/log" } }
    }
    @EnvironmentObject private var store: USDTStore
    @StateObject private var model = USDTPageModel()
    let kind: Kind
    @State private var cursor = ""
    @State private var filter = ""
    @State private var notice = ""
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                TextField("筛选币种、类型或内容", text: $filter).textFieldStyle(.roundedBorder)
                if case .transfers = kind {
                    Button("从交易所同步历史") {
                        Task { do { _ = try await store.send("/v1/account/transfer-history/sync"); await load(reset: true); notice = "同步完成" } catch { notice = error.localizedDescription } }
                    }.buttonStyle(.bordered).disabled(model.loading)
                }
                USDTNotice(text: notice)
                ForEach(Array(model.items.enumerated()).filter { filter.isEmpty || $0.element.fields.values.contains(where: { $0.text.localizedCaseInsensitiveContains(filter) }) }, id: \.offset) { _, row in
                    USDTCard {
                        if case .transfers = kind {
                            USDTMetric(title: row.value("direction") == "incoming" ? "转入" : "转出", value: "\(row.value("amount")) \(row.value("asset"))")
                            USDTMetric(title: "路径", value: row.value("route"))
                            USDTMetric(title: "渠道", value: row.value("channel"))
                        } else {
                            HStack { Text(row.value("symbol", fallback: row.value("action"))).font(.headline); Spacer(); Text(row.value("status", fallback: "")) }
                            Text(row.value("message", fallback: row.value("content", fallback: row.value("behavior_desc", fallback: "")))).font(.subheadline)
                            USDTMetric(title: "操作", value: row.value("action", fallback: row.value("event_type", fallback: row.value("result"))))
                            if let error = row["error"]?.text, !error.isEmpty { Text(error).foregroundStyle(BinanceTheme.negative) }
                        }
                        Text(row.value("occurred_at", fallback: row.value("created_at"))).font(.caption).foregroundStyle(BinanceTheme.secondaryText)
                    }
                }
                if model.items.isEmpty { USDTEmptyState(title: "暂无记录", error: model.error) { Task { await load(reset: true) } } }
                if model.hasNext || model.value["has_more"]?.flag == true {
                    Button("加载更多") { model.page += 1; cursor = model.value.value("next_cursor", fallback: ""); Task { await load(reset: false) } }.disabled(model.loading)
                }
            }.padding(16)
        }.usdtPage(kind.title).task(id: store.scope) { await load(reset: true) }.refreshable { await load(reset: true) }
    }
    private func load(reset: Bool) async {
        if reset { model.page = 1; cursor = "" }
        var query: [URLQueryItem] = [.init(name: "page", value: String(model.page)), .init(name: "page_size", value: "20"), .init(name: "limit", value: "20"), .init(name: "cursor", value: cursor)]
        if case let .strategyLog(id) = kind { query.append(.init(name: "position_id", value: id)) }
        await model.load(store, path: kind.path, query: query, append: !reset)
    }
}

struct USDTPasswordResetView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var email = ""
    @State private var token = ""
    @State private var uid = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var notice = ""
    var body: some View {
        Form {
            Section("申请重置") {
                USDTField(title: "邮箱", text: $email)
                Button("发送重置邮件") { submit("request", ["email": .string(email)]) }
            }
            Section("重置密码") {
                USDTField(title: "邮件中的用户标识 uid", text: $uid)
                USDTField(title: "邮件中的重置令牌", text: $token)
                USDTField(title: "新密码", text: $password, secure: true)
                USDTField(title: "确认新密码", text: $confirmPassword, secure: true)
                Button("确认重置") { submit("confirm", ["uid": .string(uid), "token": .string(token), "new_password": .string(password), "confirm_password": .string(confirmPassword)]) }.disabled(password != confirmPassword || password.count < 8 || token.isEmpty)
            }
            USDTNotice(text: notice)
        }.usdtPage("重置密码")
    }
    private func submit(_ action: String, _ body: [String: JSONValue]) {
        Task {
            do { _ = try await container.apiClient.send(APIRequest<JSONValue>.json(path: "/v1/auth/password-reset/\(action)", method: .post, body: body, showsErrorToast: false)); notice = action == "request" ? "如该邮箱已注册，将收到重置邮件" : "密码已重置，请重新登录" }
            catch { notice = error.localizedDescription }
        }
    }
}
