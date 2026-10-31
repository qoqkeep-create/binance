import SwiftUI

struct USDTTradeView: View {
    @EnvironmentObject private var store: USDTStore
    @State private var orderType = "market"
    @State private var stop = ""
    @State private var limit = ""
    @State private var risk = ""
    @State private var includeFee = true
    @State private var strategyID = ""
    @State private var ema: JSONValue = .null
    @State private var notice = ""
    @State private var busy = false
    @State private var confirm = false
    @State private var requestIdentity = UUID().uuidString
    @State private var submitted = false
    var initialStop: String = ""
    var initialLimit: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                USDTCard {
                    HStack {
                        Text("开仓").font(.title2.bold())
                        Spacer()
                        Text(store.mode == "lead" ? "带单" : "普通").font(.caption).foregroundStyle(BinanceTheme.accentText)
                    }
                    USDTField(title: "交易对", text: $store.selectedSymbol)
                    Picker("委托类型", selection: $orderType) {
                        Text("市价开仓").tag("market"); Text("限价委托").tag("limit")
                    }.pickerStyle(.segmented)
                    if orderType == "limit" { USDTField(title: "委托价格", text: $limit, numeric: true) }
                    USDTField(title: "止损价格", text: $stop, numeric: true)
                    USDTField(title: "单次止损金额（USDT）", text: $risk, numeric: true)
                    if orderType == "market" { Toggle("止损金额包含手续费", isOn: $includeFee) }
                    Picker("止盈策略", selection: $strategyID) {
                        Text("不使用策略").tag("")
                        ForEach(Array(store.strategies.enumerated()), id: \.offset) { _, row in
                            Text(row.value("name")).tag(row.value("id"))
                        }
                    }
                    if orderType == "market" {
                        Button("EMA 方向初筛") { checkEMA() }.buttonStyle(.bordered).disabled(busy || submitted)
                        if !ema.fields.isEmpty {
                            Text(ema["has_any_matching_interval"]?.flag == true ? "方向初筛通过" : "方向初筛未通过")
                                .foregroundStyle(ema["has_any_matching_interval"]?.flag == true ? BinanceTheme.positive : BinanceTheme.negative)
                            ForEach(Array((ema["intervals"]?.rows ?? []).enumerated()), id: \.offset) { _, row in
                                USDTMetric(title: row.value("interval"), value: row.value("message"))
                            }
                        }
                    }
                    Button(busy ? "处理中…" : submitted ? "请求已提交，请查看命令记录" : "确认开仓") {
                        Task {
                            busy = true; defer { busy = false }
                            do { try await store.preflight(); confirm = true }
                            catch { notice = error.localizedDescription }
                        }
                    }.buttonStyle(BinancePrimaryButtonStyle()).disabled(busy || submitted || !validDraft)
                    NavigationLink("查看交易命令", destination: USDTCommandsView())
                }
                USDTNotice(text: notice)
                USDTNotice(text: store.isBound ? "方向由止损价相对开仓价确定，数量和保护单由服务端按原交易规则计算。" : "请先在“我的”中绑定当前模式的 Binance API。")
            }.padding(16)
        }.usdtPage("开仓")
        .task(id: store.scope) { await store.refresh(); risk = store.riskAmount }
        .onAppear { if !initialStop.isEmpty { stop = initialStop }; if !initialLimit.isEmpty { limit = initialLimit; orderType = "limit" } }
        .onChange(of: store.selectedSymbol) { _, _ in resetDraft() }
        .onChange(of: stop) { _, _ in resetDraft() }
        .onChange(of: limit) { _, _ in resetDraft() }
        .onChange(of: orderType) { _, _ in resetDraft() }
        .onChange(of: strategyID) { _, _ in requestIdentity = UUID().uuidString }
        .confirmationDialog("确认提交 \(store.selectedSymbol) 的\(orderType == "market" ? "市价" : "限价")开仓？止损 \(stop)，风险金额 \(risk) USDT", isPresented: $confirm, titleVisibility: .visible) {
            Button("提交交易") { submit() }
        }
    }
    private var validDraft: Bool {
        guard store.isBound, let riskValue = Decimal(string: risk), riskValue > 0,
              let stopValue = Decimal(string: stop), stopValue > 0 else { return false }
        if orderType == "limit" { return (Decimal(string: limit) ?? 0) > 0 }
        return ema["has_any_matching_interval"]?.flag == true
    }
    private func resetDraft() { ema = .null; if !submitted { requestIdentity = UUID().uuidString } }
    private func checkEMA() {
        busy = true
        Task {
            defer { busy = false }
            do { ema = try await store.send("/v1/trade/ema-check", ["symbol": .string(store.selectedSymbol.uppercased()), "stop_loss_price": .string(stop)]) }
            catch { notice = error.localizedDescription }
        }
    }
    private func submit() {
        busy = true; submitted = true
        Task {
            defer { busy = false }
            var payload: [String: JSONValue] = ["symbol": .string(store.selectedSymbol.uppercased()), "stop_loss_price": .string(stop), "stop_loss_amount": .string(risk)]
            if orderType == "limit" { payload["limit_price"] = .string(limit) }
            else { payload["include_fee"] = .bool(includeFee); payload["ema_check_id"] = ema["check_id"] }
            if let strategy = store.strategies.first(where: { $0.value("id") == strategyID }) {
                payload["strategy_id"] = strategy["id"]; payload["strategy_name"] = strategy["name"]; payload["strategy_config"] = strategy["levels"]
            }
            do {
                let result = try await store.command(orderType == "limit" ? "limit-create" : "open", payload: payload, key: requestIdentity)
                notice = store.commandMessage(result)
                // A new intent requires leaving the submitted ticket; retries retain the same key.
            } catch { notice = error.localizedDescription + "。请先核对命令记录。" }
        }
    }
}

struct USDTPositionsView: View {
    @EnvironmentObject private var store: USDTStore
    @StateObject private var model = USDTPageModel()
    @State private var segment = "positions"
    @State private var filter = "all"
    @State private var notice = ""
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack { Text("持仓").font(.title2.bold()); Spacer(); NavigationLink("命令记录", destination: USDTCommandsView()) }
                Picker("类别", selection: $segment) {
                    Text("当前持仓").tag("positions"); Text("限价委托").tag("limits"); Text("历史记录").tag("history")
                }.pickerStyle(.segmented)
                if segment == "history" {
                    Picker("来源", selection: $filter) { Text("全部").tag("all"); Text("系统").tag("system"); Text("手动").tag("manual") }.pickerStyle(.segmented)
                }
                USDTNotice(text: notice)
                if model.loading && model.items.isEmpty { ProgressView().padding(30) }
                if !model.loading && model.items.isEmpty { USDTEmptyState(title: "暂无记录", error: model.error) { Task { await reload() } } }
                ForEach(Array(model.items.enumerated()), id: \.offset) { _, row in
                    if segment == "positions" {
                        NavigationLink { USDTPositionDetailView(position: row) } label: { positionCard(row) }.buttonStyle(.plain)
                    } else if segment == "limits" { limitCard(row) }
                    else { historyCard(row) }
                }
                if model.hasNext { Button("加载更多") { model.page += 1; Task { await reload(append: true) } } }
            }.padding(16)
        }.usdtPage("持仓")
        .task(id: "\(store.scope):\(segment):\(filter)") { model.page = 1; await reload() }
        .refreshable { model.page = 1; await reload() }
        .onChange(of: store.liveRevision) { _, _ in
            if segment != "history" { model.page = 1; Task { await reload() } }
        }
    }
    private func reload(append: Bool = false) async {
        let path = segment == "positions" ? "/v1/position/list" : segment == "limits" ? "/v1/trade/limit-order/list" : "/v1/position/history"
        await model.load(store, path: path, query: [.init(name: "filter", value: filter), .init(name: "page", value: String(model.page)), .init(name: "page_size", value: "20")], append: append)
    }
    private func positionCard(_ row: JSONValue) -> some View {
        USDTCard {
            HStack { Text(row.value("symbol")).font(.headline); Spacer(); Text(row.value("side") == "0" ? "多" : "空").foregroundStyle(row.value("side") == "0" ? BinanceTheme.positive : BinanceTheme.negative) }
            USDTMetric(title: "浮动盈亏（USDT）", value: row.value("pnl"))
            HStack { Text("开仓 \(row.value("open_price"))"); Spacer(); Text("现价 \(row.value("current_price"))") }.font(.caption)
            USDTMetric(title: "止损 / 止盈", value: "\(row.value("stop_loss_price")) / \(row.value("manual_take_profit_price"))")
            Text(row.value("stop_protection_error", fallback: row.value("stop_protection_status"))).font(.caption).foregroundStyle(BinanceTheme.secondaryText)
        }
    }
    private func historyCard(_ row: JSONValue) -> some View {
        USDTCard {
            Text(row.value("symbol")).font(.headline)
            USDTMetric(title: "收益", value: row.value("pnl"))
            USDTMetric(title: "开仓时间", value: row.value("opened_at"))
            USDTMetric(title: "平仓时间", value: row.value("closed_at"))
            USDTMetric(title: "手续费 / 资金费", value: "\(row.value("fee")) / \(row.value("funding_fee"))")
            USDTMetric(title: "结算状态", value: row.value("settlement_status"))
            if !row.value("settlement_note", fallback: "").isEmpty { Text(row.value("settlement_note")).font(.footnote).foregroundStyle(BinanceTheme.secondaryText) }
            if row["has_strategy_logs"]?.flag == true { NavigationLink("策略记录", destination: USDTRecordsView(kind: .strategyLog(row.value("id")))) }
        }
    }
    private func limitCard(_ row: JSONValue) -> some View {
        USDTCard {
            HStack { Text(row.value("symbol")).font(.headline); Spacer(); Text(row.value("status_text")) }
            USDTMetric(title: "委托价 / 止损价", value: "\(row.value("limit_price")) / \(row.value("stop_loss_price"))")
            USDTMetric(title: "成交 / 数量", value: "\(row.value("filled_size")) / \(row.value("size"))")
            HStack {
                USDTCommandButton(title: "取消委托", action: "limit-cancel", payload: ["limit_order_id": row["id"] ?? .null]) { notice = $0; Task { await reload() } }
                if row["can_chase"]?.flag == true {
                    USDTCommandButton(title: "追单", action: "limit-chase", payload: ["limit_order_id": row["id"] ?? .null], preflight: "chase") { notice = $0; Task { await reload() } }
                }
            }
        }
    }
}

struct USDTCommandButton: View {
    @EnvironmentObject private var store: USDTStore
    let title: String
    let action: String
    let payload: [String: JSONValue]
    var preflight: String? = nil
    let completed: (String) -> Void
    @State private var key = UUID().uuidString
    @State private var busy = false
    @State private var confirm = false
    @State private var pending = false
    var body: some View {
        Button(busy ? "处理中…" : pending ? "查询\(title)结果" : title) { confirm = true }
            .buttonStyle(.bordered).disabled(busy)
            .confirmationDialog("确认\(title)？", isPresented: $confirm, titleVisibility: .visible) {
                Button(title, role: action == "position-close" ? .destructive : nil) {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            if let preflight, !pending { try await store.preflight(preflight) }
                            pending = true
                            let result = try await store.command(action, payload: payload, key: key)
                            completed(store.commandMessage(result))
                            if ["SUCCEEDED", "FAILED"].contains(result.value("status")) { key = UUID().uuidString; pending = false }
                        } catch { completed(error.localizedDescription) }
                    }
                }
            }
    }
}

struct USDTPositionDetailView: View {
    @EnvironmentObject private var store: USDTStore
    let position: JSONValue
    @State private var livePosition: JSONValue = .null
    @State private var closed = false
    private var current: JSONValue { livePosition == .null ? position : livePosition }
    @State private var takeProfit = ""
    @State private var orderType = "limit"
    @State private var strategy = ""
    @State private var notice = ""
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                USDTCard {
                    ForEach([("持仓金额", "position_amount"), ("盈亏", "pnl"), ("开仓价格", "open_price"), ("当前价格", "current_price"), ("止损价", "stop_loss_price"), ("止盈价", "manual_take_profit_price"), ("数量", "exchange_size"), ("策略", "strategy_name"), ("保护状态", "stop_protection_status"), ("保护错误", "stop_protection_error")], id: \.0) { title, key in USDTMetric(title: title, value: current.value(key)) }
                }
                USDTCard {
                    USDTField(title: "止盈价格", text: $takeProfit, numeric: true)
                    Picker("止盈委托", selection: $orderType) { Text("限价").tag("limit"); Text("市价").tag("market") }.pickerStyle(.segmented)
                    USDTCommandButton(title: "设置止盈", action: "take-profit", payload: ["position_id": current["id"] ?? .null, "take_profit_price": .string(takeProfit), "order_type": .string(orderType)]) { notice = $0; Task { await reload() } }
                    USDTCommandButton(title: "保本止损", action: "break-even", payload: ["position_id": current["id"] ?? .null]) { notice = $0; Task { await reload() } }
                }
                USDTCard {
                    Picker("更换策略", selection: $strategy) {
                        Text("选择策略").tag("")
                        ForEach(Array(store.strategies.enumerated()), id: \.offset) { _, row in Text(row.value("name")).tag(row.value("id")) }
                    }
                    USDTCommandButton(title: "绑定策略", action: "strategy-rebind", payload: ["position_id": current["id"] ?? .null, "strategy_id": .string(strategy)]) { notice = $0; Task { await reload() } }
                    USDTCommandButton(title: "取消策略", action: "strategy-cancel", payload: ["position_id": current["id"] ?? .null]) { notice = $0; Task { await reload() } }
                    NavigationLink("策略执行记录") { USDTRecordsView(kind: .strategyLog(current.value("id"))) }
                }
                USDTCommandButton(title: "平仓", action: "position-close", payload: ["position_id": current["id"] ?? .null]) { notice = $0; Task { await reload() } }
                if closed { Text("此持仓已结束").foregroundStyle(BinanceTheme.secondaryText) }
                USDTNotice(text: notice)
            }.padding(16)
        }.disabled(closed).usdtPage(current.value("symbol"))
        .task(id: store.scope) { await reload() }
        .onChange(of: store.liveRevision) { _, _ in Task { await reload() } }
    }
    private func reload() async {
        do {
            let rows = try await store.get("/v1/position/list").rows
            if let latest = rows.first(where: { $0.value("id") == position.value("id") }) { livePosition = latest; closed = false }
            else { closed = true }
        } catch is CancellationError { } catch { notice = error.localizedDescription }
    }
}

struct USDTCommandsView: View {
    @EnvironmentObject private var store: USDTStore
    @StateObject private var model = USDTPageModel()
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(Array(model.items.enumerated()), id: \.offset) { _, row in
                    USDTCard {
                        USDTMetric(title: row.value("action"), value: row.value("status"))
                        Text(row.value("id")).font(.caption.monospaced())
                        Text(row["result"]?.value("message", fallback: "等待执行结果") ?? "等待执行结果").font(.footnote)
                        Text(row.value("createdAt")).font(.caption).foregroundStyle(BinanceTheme.secondaryText)
                    }
                }
                if model.items.isEmpty { USDTEmptyState(title: "暂无交易命令", error: model.error) { Task { await load() } } }
            }.padding(16)
        }.usdtPage("交易命令").task(id: store.scope) { await load() }.refreshable { await load() }
        .onChange(of: store.liveRevision) { _, _ in Task { await load() } }
    }
    private func load() async { await model.load(store, path: "/api/commands") }
}
