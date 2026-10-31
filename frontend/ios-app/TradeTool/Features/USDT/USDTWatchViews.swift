import SwiftUI

struct USDTWatchPlansView: View {
    @EnvironmentObject private var store: USDTStore
    @StateObject private var model = USDTPageModel()
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                NavigationLink("新增观察计划", destination: USDTWatchEditor(plan: nil)).buttonStyle(.bordered)
                ForEach(Array(model.items.enumerated()), id: \.offset) { _, plan in
                    NavigationLink { USDTWatchEditor(plan: plan) } label: {
                        USDTCard {
                            HStack { Text(plan.value("symbol")).font(.headline); Spacer(); Text(plan.value("timeframe")); Text(plan.value("direction") == "0" ? "多" : "空") }
                            Text(plan.value("content", fallback: "")).font(.subheadline)
                            USDTMetric(title: "日期 / 评分", value: "\(plan.value("plan_date")) / \(plan.value("score"))")
                            if !plan.value("review_content", fallback: "").isEmpty { Text(plan.value("review_content")).font(.footnote).foregroundStyle(BinanceTheme.secondaryText) }
                        }
                    }.buttonStyle(.plain)
                }
                if model.items.isEmpty { USDTEmptyState(title: "暂无观察计划", error: model.error) { Task { await load() } } }
            }.padding(16)
        }.usdtPage("观察计划").task(id: store.scope) { await load() }.onAppear { Task { await load() } }.refreshable { await load() }
    }
    private func load() async { await model.load(store, path: "/v1/watch-plan/list") }
}

struct USDTWatchEditor: View {
    @EnvironmentObject private var store: USDTStore
    @Environment(\.dismiss) private var dismiss
    let plan: JSONValue?
    @State private var symbol = "BTCUSDT"
    @State private var date = Date()
    @State private var planType = 0
    @State private var timeframe = "1h"
    @State private var direction = 0
    @State private var content = ""
    @State private var expectation = ""
    @State private var review = ""
    @State private var status = 0
    @State private var result = 0
    @State private var amount = ""
    @State private var score = 0
    @State private var scoreChecks: Set<String> = []
    @State private var scoreVetoes: Set<String> = []
    @State private var scoreEdited = false
    @State private var notice = ""
    @State private var deleting = false
    var body: some View {
        Form {
            Section("计划") {
                USDTField(title: "交易对", text: $symbol)
                DatePicker("计划日期", selection: $date, displayedComponents: .date)
                Picker("类型", selection: $planType) { Text("计划左侧单").tag(0); Text("确认右侧单").tag(1) }
                Picker("周期", selection: $timeframe) { ForEach(["15m", "1h", "4h", "1d"], id: \.self) { Text($0) } }
                Picker("方向", selection: $direction) { Text("做多").tag(0); Text("做空").tag(1) }.pickerStyle(.segmented)
                Text("计划内容").font(.caption); TextEditor(text: $content).frame(minHeight: 100)
                Text("止盈预期").font(.caption); TextEditor(text: $expectation).frame(minHeight: 80)
            }
            if plan != nil {
                Section("执行与复盘") {
                    Picker("状态", selection: $status) { Text("未标记").tag(0); Text("已做单").tag(1); Text("未做单").tag(2) }
                    Picker("结果", selection: $result) { Text("无").tag(0); Text("止损").tag(1); Text("止盈").tag(2) }
                    if result != 0 { USDTField(title: "盈亏金额", text: $amount, numeric: true) }
                    Text("评分 \(scoreEdited ? calculatedScore : score) / 100").font(.headline)
                    ForEach(scoreSections, id: \.title) { section in
                        DisclosureGroup(section.title) {
                            ForEach(section.items, id: \.key) { item in
                                Toggle("\(item.label)（\(item.points)分）", isOn: scoreBinding(item.key, veto: false))
                            }
                        }
                    }
                    DisclosureGroup("一票否决") {
                        ForEach(WatchScoreSection.vetoes, id: \.key) { item in
                            Toggle(item.label, isOn: scoreBinding(item.key, veto: true))
                        }
                    }
                    if !scoreVetoes.isEmpty { Text("存在否决项，不建议执行此计划").foregroundStyle(BinanceTheme.negative) }
                    TextEditor(text: $review).frame(minHeight: 100)
                }
            }
            Section {
                Button("保存计划") { save() }
                if plan != nil { Button("删除计划", role: .destructive) { deleting = true } }
                USDTNotice(text: notice)
            }
        }.usdtPage(plan == nil ? "新增观察" : "计划与复盘").onAppear {
            guard let plan else { return }
            symbol = plan.value("symbol"); timeframe = plan.value("timeframe")
            planType = Int(plan.value("plan_type")) ?? 0; direction = Int(plan.value("direction")) ?? 0
            content = plan.value("content", fallback: ""); expectation = plan.value("take_profit_expectation", fallback: "")
            review = plan.value("review_content", fallback: ""); status = Int(plan.value("status")) ?? 0
            result = Int(plan.value("result")) ?? 0; amount = plan.value("result_amount", fallback: "")
            score = Int(plan.value("score")) ?? 0
            scoreChecks = Set((plan["score_payload"]?["checks"]?.rows ?? []).map(\.text))
            scoreVetoes = Set((plan["score_payload"]?["vetoes"]?.rows ?? []).map(\.text))
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; date = formatter.date(from: plan.value("plan_date")) ?? .now
        }.confirmationDialog("删除此观察计划？", isPresented: $deleting) {
            Button("删除", role: .destructive) { Task { do { _ = try await store.send("/v1/watch-plan/delete", ["id": plan?["id"] ?? .null]); dismiss() } catch { notice = error.localizedDescription } } }
        }
    }
    private var scoreSections: [WatchScoreSection] { WatchScoreSection.sections(right: planType == 1) }
    private var calculatedScore: Int { scoreSections.flatMap(\.items).reduce(0) { $0 + (scoreChecks.contains($1.key) ? $1.points : 0) } }
    private func scoreBinding(_ key: String, veto: Bool) -> Binding<Bool> {
        Binding(get: { veto ? scoreVetoes.contains(key) : scoreChecks.contains(key) }, set: { enabled in
            scoreEdited = true
            if veto { if enabled { scoreVetoes.insert(key) } else { scoreVetoes.remove(key) } }
            else { if enabled { scoreChecks.insert(key) } else { scoreChecks.remove(key) } }
        })
    }
    private func save() {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        var payload: [String: JSONValue] = ["symbol": .string(symbol.uppercased()), "plan_date": .string(formatter.string(from: date)), "plan_type": .number(Double(planType)), "timeframe": .string(timeframe), "direction": .number(Double(direction)), "content": .string(content), "take_profit_expectation": .string(expectation)]
        if let plan {
            payload.merge(["id": plan["id"] ?? .null, "review_content": .string(review), "status": .number(Double(status)), "result": .number(Double(result)), "result_amount": .string(result == 0 ? "" : amount), "score": .number(Double(scoreEdited ? calculatedScore : score)), "score_payload": .object(["checks": .array(scoreChecks.sorted().map { .string($0) }), "vetoes": .array(scoreVetoes.sorted().map { .string($0) })])]) { _, new in new }
        }
        Task { do { _ = try await store.send(plan == nil ? "/v1/watch-plan/create" : "/v1/watch-plan/update", payload); dismiss() } catch { notice = error.localizedDescription } }
    }
}

private struct WatchScoreSection {
    struct Item { let key: String; let label: String; let points: Int }
    let title: String
    let items: [Item]
    static let section0 = WatchScoreSection(title: "趋势背景（20分）", items: [
        Item(key: "trend-direction", label: "大周期方向明确，1D / 4H 与交易方向一致", points: 10),
        Item(key: "trend-ema-order", label: "EMA21 / 55 / 144 顺向排列", points: 5),
        Item(key: "trend-not-chasing", label: "均线发散不极端，价格不是远离均线后追入", points: 5),
    ])
    static let section1 = WatchScoreSection(title: "位置质量（25分）", items: [
        Item(key: "position-structure", label: "价格处在关键支撑/压力/前高前低/结构位", points: 10),
        Item(key: "position-ema144", label: "回踩到 EMA144 或核心均线区域", points: 7),
        Item(key: "position-fib", label: "Fib 0.618 / 0.786 与 EMA144 / 结构位重合", points: 5),
        Item(key: "position-not-middle", label: "不是震荡区中间，不是无意义位置", points: 3),
    ])
    static let section2 = WatchScoreSection(title: "入场触发（20分）", items: [
        Item(key: "entry-right-reversal", label: "已出现明确反转 K 线", points: 8),
        Item(key: "entry-right-zone", label: "反转 K 线位置正好在关键区域", points: 5),
        Item(key: "entry-right-stop-clear", label: "反转 K 线止损点清晰", points: 4),
        Item(key: "entry-right-r-space", label: "入场后仍有足够 R 值空间", points: 3),
    ])
    static let section3 = WatchScoreSection(title: "入场触发（20分）", items: [
        Item(key: "entry-left-planned", label: "是提前计划好的左侧关键位，不是临场接刀", points: 7),
        Item(key: "entry-left-confluence", label: "EMA144 + Fib / 结构位强共振", points: 6),
        Item(key: "entry-left-stop-clear", label: "止损放在明确失效位，比如 Fib 1 / 结构破位", points: 4),
        Item(key: "entry-left-risk-limited", label: "左侧只占部分风险，或总风险被程序严格限制", points: 3),
    ])
    static let section4 = WatchScoreSection(title: "风险收益结构（20分）", items: [
        Item(key: "risk-stop-clear", label: "止损位置明确，不需要临场调整", points: 5),
        Item(key: "risk-two-r", label: "到前高/前低至少 ≥ 2R", points: 6),
        Item(key: "risk-three-five-r", label: "有可能走到 3R - 5R，适合趋势仓", points: 4),
        Item(key: "risk-fixed-amount", label: "单笔风险金额固定，不因信心提高", points: 3),
        Item(key: "risk-auto-tp", label: "交易后能自动执行 30-20-50 止盈", points: 2),
    ])
    static let section5 = WatchScoreSection(title: "清晰度 / 心理状态（15分）", items: [
        Item(key: "mind-clear", label: "一眼能看懂，不需要反复分析", points: 6),
        Item(key: "mind-not-revenge", label: "不是因为亏损后想补回来", points: 3),
        Item(key: "mind-not-greed", label: "不是因为盈利后没赢够", points: 3),
        Item(key: "mind-not-fomo", label: "不是因为错过后想重新参与", points: 3),
    ])
    static let vetoes: [Item] = [
        Item(key: "veto-trend-unclear", label: "大周期方向不明确", points: 0),
        Item(key: "veto-no-key-level", label: "不在关键位置，只有局部信号", points: 0),
        Item(key: "veto-less-than-2r", label: "预期空间不足 2R", points: 0),
        Item(key: "veto-emotional", label: "情绪驱动想做，不是按系统做", points: 0),
    ]
    static func sections(right: Bool) -> [WatchScoreSection] { [section0, section1, right ? section2 : section3, section4, section5] }
}
