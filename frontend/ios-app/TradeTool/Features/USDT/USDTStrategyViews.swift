import SwiftUI

struct USDTStrategiesView: View {
    @EnvironmentObject private var store: USDTStore
    @State private var notice = ""
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                NavigationLink { USDTStrategyEditor(strategy: nil) } label: { Label("新增止盈策略", systemImage: "plus") }.buttonStyle(.bordered)
                ForEach(Array(store.strategies.enumerated()), id: \.offset) { _, strategy in
                    USDTCard {
                        HStack { Text(strategy.value("name")).font(.headline); Spacer(); if strategy["is_active"]?.flag == true { Text("使用中").foregroundStyle(BinanceTheme.accentText) } }
                        ForEach(Array((strategy["levels"]?.rows ?? []).enumerated()), id: \.offset) { i, level in
                            USDTMetric(title: "L\(i + 1) · \(level.value("profitRR"))R", value: "减仓 \(level.value("reducePosition"))%")
                        }
                        HStack {
                            NavigationLink("编辑") { USDTStrategyEditor(strategy: strategy) }
                            Spacer()
                            Button("设为当前") { Task { do { _ = try await store.send("/v1/strategy/set-active", ["strategy_id": strategy["id"] ?? .null]); await store.refresh() } catch { notice = error.localizedDescription } } }
                        }
                    }
                }
                USDTNotice(text: notice)
                if store.strategies.isEmpty { USDTEmptyState(title: "暂无策略", error: store.notice) { Task { await store.refresh() } } }
            }.padding(16)
        }.usdtPage("止盈策略").task { await store.refresh() }
    }
}

private struct USDTStrategyLevel: Identifiable {
    let id = UUID()
    var profit = "1"
    var reduce = "20"
    var stopType = "none"
    var stopValue = "0"
    var payload: JSONValue {
        var result: [String: JSONValue] = ["profitRR": .string(profit), "reducePosition": .string(reduce), "stopLossType": .string(stopType)]
        if stopType == "fixedRR" { result["stopLossRR"] = .string(stopValue) }
        if stopType == "absoluteRR" { result["stopLossAbsoluteRR"] = .string(stopValue) }
        return .object(result)
    }
}

struct USDTStrategyEditor: View {
    @EnvironmentObject private var store: USDTStore
    @Environment(\.dismiss) private var dismiss
    let strategy: JSONValue?
    @State private var name = ""
    @State private var levels = [USDTStrategyLevel()]
    @State private var notice = ""
    @State private var busy = false
    @State private var delete = false
    var body: some View {
        Form {
            Section("策略名称") { TextField("名称", text: $name) }
            ForEach($levels) { $level in
                Section("层级 \((levels.firstIndex(where: { $0.id == level.id }) ?? 0) + 1)") {
                    USDTField(title: "盈利达到 R", text: $level.profit, numeric: true)
                    USDTField(title: "减仓比例 %", text: $level.reduce, numeric: true)
                    Picker("止损移动", selection: $level.stopType) {
                        Text("保持原止损").tag("none"); Text("当前浮盈减 xR").tag("fixedRR"); Text("移动到 xR").tag("absoluteRR")
                    }
                    if level.stopType != "none" { USDTField(title: "xR", text: $level.stopValue, numeric: true) }
                    if levels.count > 1 { Button("删除此层", role: .destructive) { levels.removeAll { $0.id == level.id } } }
                }
            }
            if levels.count < 5 { Button("添加层级") { levels.append(USDTStrategyLevel(profit: String(levels.count + 1))) } }
            Section {
                Button(busy ? "保存中…" : "保存策略") { save() }.disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                if strategy != nil { Button("删除策略", role: .destructive) { delete = true } }
                USDTNotice(text: notice)
            }
        }.usdtPage(strategy == nil ? "新增策略" : "编辑策略").onAppear {
            guard let strategy else { return }
            name = strategy.value("name")
            levels = (strategy["levels"]?.rows ?? []).map { row in
                USDTStrategyLevel(profit: row.value("profitRR"), reduce: row.value("reducePosition"), stopType: row.value("stopLossType"), stopValue: row.value(row.value("stopLossType") == "fixedRR" ? "stopLossRR" : "stopLossAbsoluteRR", fallback: "0"))
            }
        }.confirmationDialog("删除此策略？", isPresented: $delete) {
            Button("删除", role: .destructive) { Task { do { _ = try await store.send("/v1/strategy/delete", ["strategy_id": strategy?["id"] ?? .null]); await store.refresh(); dismiss() } catch { notice = error.localizedDescription } } }
        }
    }
    private func save() {
        var previous = Decimal.zero, total = Decimal.zero
        for level in levels {
            guard let profit = Decimal(string: level.profit), profit > previous,
                  let reduce = Decimal(string: level.reduce), reduce >= 0 else { notice = "层级盈利 R 必须递增，减仓比例不能为负数"; return }
            previous = profit; total += reduce
        }
        guard total <= 100 else { notice = "累计减仓不能超过 100%"; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                var body: [String: JSONValue] = ["name": .string(name), "levels": .array(levels.map(\.payload))]
                body["strategy_id"] = strategy?["id"]
                _ = try await store.send("/v1/strategy/save", body); await store.refresh(); dismiss()
            } catch { notice = error.localizedDescription }
        }
    }
}

struct USDTChartOrderSettingsView: View {
    @AppStorage("integrated.chart.orderType") private var orderType = "limit"
    var body: some View {
        Form {
            Picker("图表开仓类型", selection: $orderType) { Text("限价").tag("limit"); Text("市价").tag("market") }
            NavigationLink("止损金额", destination: USDTStopLossView())
            NavigationLink("止盈策略", destination: USDTStrategiesView())
        }.usdtPage("下单设置")
    }
}
