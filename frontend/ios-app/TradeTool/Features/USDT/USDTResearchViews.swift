import SwiftUI
import Charts

struct USDTResearchView: View {
    @EnvironmentObject private var store: USDTStore
    @StateObject private var model = USDTPageModel()
    @State private var page = "samples"
    @State private var notice = ""
    @State private var busy = false
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("研究", selection: $page) { Text("样本").tag("samples"); Text("规则").tag("rules"); Text("策略").tag("strategies"); Text("模型").tag("ai-models") }.pickerStyle(.segmented)
                if page == "samples" {
                    NavigationLink("添加研究样本", destination: USDTResearchSampleEditor()).buttonStyle(.bordered)
                    ForEach(Array(model.items.enumerated()), id: \.offset) { _, row in
                        NavigationLink { USDTResearchSampleView(sample: row) } label: {
                            USDTCard {
                                HStack { Text(row.value("symbol")).font(.headline); Spacer(); Text(row.value("timeframe")); Text(row.value("expected_direction")) }
                                Text(row.value("signal_time")).font(.caption)
                                USDTMetric(title: "可信样本", value: row["trusted"]?.text ?? "待标记")
                                Text(row.value("note", fallback: "")).font(.footnote)
                            }
                        }.buttonStyle(.plain)
                    }
                } else if page == "rules" {
                    USDTCard {
                        Text(model.value.value("name")).font(.headline)
                        USDTMetric(title: "可信样本数", value: model.value.value("trusted_sample_count"))
                        ForEach(Array((model.value["rules"]?.rows ?? []).enumerated()), id: \.offset) { _, row in Text(row.text).font(.subheadline) }
                        if model.value["rules"]?.rows.isEmpty != false { Text(model.value.value("rules", fallback: "")).font(.subheadline) }
                        ForEach(Array((model.value["evidence"]?.rows ?? []).enumerated()), id: \.offset) { _, row in Text(row.text).font(.footnote).foregroundStyle(BinanceTheme.secondaryText) }
                    }
                } else if page == "strategies" {
                    HStack {
                        Button(busy ? "生成中…" : "AI 生成策略草案") { generate() }.buttonStyle(.bordered).disabled(busy)
                        NavigationLink("回测", destination: USDTResearchBacktestView())
                    }
                    ForEach(Array(model.items.enumerated()), id: \.offset) { _, row in
                        NavigationLink { USDTResearchStrategyView(initial: row) } label: {
                            USDTCard {
                                Text(row.value("name")).font(.headline)
                                USDTMetric(title: "版本 / 状态", value: "\(row.value("version")) / \(row.value("status"))")
                                Text(row.value("rationale", fallback: "")).font(.footnote).lineLimit(4)
                            }
                        }.buttonStyle(.plain)
                    }
                } else {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { _, row in
                        USDTCard {
                            Text(row.value("name")).font(.headline)
                            USDTMetric(title: "提供商", value: row.value("provider"))
                            USDTMetric(title: "模型", value: row.value("model"))
                            Button("选用此模型") { Task { do { _ = try await store.send("/v1/signal-research/ai-models/\(row.value("id"))/activate"); notice = "模型已选用" } catch { notice = error.localizedDescription } } }.buttonStyle(.bordered)
                        }
                    }
                }
                USDTNotice(text: notice)
                if model.items.isEmpty && page != "rules" { USDTEmptyState(title: "暂无研究记录", error: model.error) { Task { await load() } } }
            }.padding(16)
        }.usdtPage("信号研究").task(id: "\(store.scope):\(page)") { await load() }.onAppear { Task { await load() } }.refreshable { await load() }
    }
    private func load() async { await model.load(store, path: "/v1/signal-research/\(page)") }
    private func generate() {
        busy = true
        Task { defer { busy = false }; do { _ = try await store.send("/v1/signal-research/strategies/generate"); notice = "草案已生成，审核后可发布"; await load() } catch { notice = error.localizedDescription } }
    }
}

struct USDTResearchSampleEditor: View {
    @EnvironmentObject private var store: USDTStore
    @Environment(\.dismiss) private var dismiss
    @State private var symbol = "BTCUSDT"
    @State private var timeframe = "1h"
    @State private var time = Date().addingTimeInterval(-3600)
    @State private var direction = "neutral"
    @State private var note = ""
    @State private var notice = ""
    var body: some View {
        Form {
            USDTField(title: "交易对", text: $symbol)
            Picker("周期", selection: $timeframe) { ForEach(["15m", "1h", "4h", "1d"], id: \.self) { Text($0) } }
            DatePicker("收盘时间", selection: $time, in: ...Date())
            Picker("预期方向", selection: $direction) { Text("观察").tag("neutral"); Text("做多").tag("long"); Text("做空").tag("short") }
            TextEditor(text: $note).frame(minHeight: 100)
            Button("保存样本") {
                Task { do { _ = try await store.send("/v1/signal-research/samples", ["symbol": .string(symbol.uppercased()), "timeframe": .string(timeframe), "signal_time": .string(ISO8601DateFormatter().string(from: time)), "expected_direction": .string(direction), "note": .string(note), "trusted": .null]); dismiss() } catch { notice = error.localizedDescription } }
            }
            USDTNotice(text: notice)
        }.usdtPage("新增研究样本")
    }
}

struct USDTResearchSampleView: View {
    @EnvironmentObject private var store: USDTStore
    @Environment(\.dismiss) private var dismiss
    let sample: JSONValue
    @State private var value: JSONValue = .null
    @State private var note = ""
    @State private var notice = ""
    @State private var deleting = false
    @State private var busy = false
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                USDTCard {
                    USDTMetric(title: "周期 / 信号时间", value: "\(sample.value("timeframe")) · \(sample.value("signal_time"))")
                    USDTResearchChart(candles: value["candles"]?.rows ?? [])
                    Button(busy ? "获取中…" : "获取样本行情并分析") { fetch() }.disabled(busy).buttonStyle(.bordered)
                }
                USDTCard {
                    USDTResearchFeatures(features: value["features"] ?? .null)
                    USDTMetric(title: "可信", value: value["trusted"]?.text ?? "待标记")
                    HStack {
                        Button("可信") { mark(.bool(true)) }; Spacer(); Button("不可信") { mark(.bool(false)) }; Spacer(); Button("待判断") { mark(.null) }
                    }.buttonStyle(.bordered)
                    TextEditor(text: $note).frame(minHeight: 90)
                    Button("保存备注") { Task { do { value = try await store.send(path, ["note": .string(note)], method: .patch); notice = "已保存" } catch { notice = error.localizedDescription } } }
                    Button("删除样本", role: .destructive) { deleting = true }
                }
                USDTNotice(text: notice)
            }.padding(16)
        }.usdtPage(sample.value("symbol")).task { await load() }
            .confirmationDialog("删除此研究样本？", isPresented: $deleting) { Button("删除", role: .destructive) { Task { do { _ = try await store.send(path, method: .delete); dismiss() } catch { notice = error.localizedDescription } } } }
    }
    private var path: String { "/v1/signal-research/samples/\(sample.value("id"))" }
    private func load() async { do { value = try await store.get(path); note = value.value("note", fallback: "") } catch { notice = error.localizedDescription } }
    private func mark(_ trusted: JSONValue) { Task { do { value = try await store.send(path, ["trusted": trusted], method: .patch) } catch { notice = error.localizedDescription } } }
    private func fetch() { busy = true; Task { defer { busy = false }; do { value = try await store.send(path + "/fetch") } catch { notice = error.localizedDescription } } }
}

struct USDTResearchFeatures: View {
    let features: JSONValue
    var body: some View {
        ForEach([("趋势", "trend"), ("SuperTrend 翻转", "supertrend_flip"), ("EMA 排列", "ema_alignment"), ("距 EMA21（ATR）", "close_to_ema21_atr"), ("距 EMA55（ATR）", "close_to_ema55_atr"), ("距 EMA144（ATR）", "close_to_ema144_atr"), ("ATR %", "atr_percent"), ("成交量比", "volume_ratio_20"), ("20根涨幅 %", "return_20_pct"), ("趋势持续根数", "supertrend_age_bars")], id: \.0) { title, key in
            USDTMetric(title: title, value: features.value(key))
        }
    }
}

struct USDTResearchChart: View {
    let candles: [JSONValue]
    var body: some View {
        if candles.isEmpty { Text("获取行情后显示样本 K 线").font(.caption).frame(height: 180).frame(maxWidth: .infinity) }
        else {
            Chart(Array(candles.suffix(150).enumerated()), id: \.offset) { i, candle in
                let open = Double(candle.value("open")) ?? 0
                let close = Double(candle.value("close")) ?? 0
                RuleMark(x: .value("时间", i), yStart: .value("低", Double(candle.value("low")) ?? 0), yEnd: .value("高", Double(candle.value("high")) ?? 0))
                    .foregroundStyle(close >= open ? BinanceTheme.positive : BinanceTheme.negative)
                RectangleMark(x: .value("时间", i), yStart: .value("开", min(open, close)), yEnd: .value("收", max(open, close)), width: 3)
                    .foregroundStyle(close >= open ? BinanceTheme.positive : BinanceTheme.negative)
                LineMark(x: .value("时间", i), y: .value("EMA55", Double(candle.value("ema55")) ?? close), series: .value("指标", "EMA55")).foregroundStyle(BinanceTheme.accent)
            }.chartYScale(domain: .automatic(includesZero: false)).frame(height: 220).accessibilityLabel("样本蜡烛图与 EMA55")
        }
    }
}

struct USDTResearchStrategyView: View {
    @EnvironmentObject private var store: USDTStore
    let initial: JSONValue
    @State private var name = ""
    @State private var rationale = ""
    @State private var rules = ""
    @State private var notice = ""
    @State private var published = false
    @State private var flipWindow = 8
    @State private var minGap = "0"
    @State private var maxDistance = "0.35"
    @State private var align144 = false
    @State private var code = ""
    @State private var confirm = false
    var body: some View {
        Form {
            Section("研究策略") {
                TextField("策略名称", text: $name).disabled(published)
                Text("自然语言规则（每行一条）").font(.caption)
                TextEditor(text: $rules).frame(minHeight: 140).disabled(published)
                Text("依据").font(.caption); TextEditor(text: $rationale).frame(minHeight: 110).disabled(published)
                if !published {
                    Button("保存草案") { save() }
                    Button("审核并发布") { confirm = true }
                } else { Text("此版本已发布") }
            }
            Section("策略参数") {
                Stepper("翻转窗口 \(flipWindow) 根", value: $flipWindow, in: 1...20).disabled(published)
                USDTField(title: "最小均线间距（ATR，0–5）", text: $minGap, numeric: true).disabled(published)
                USDTField(title: "最大收盘距离（ATR，0.05–3）", text: $maxDistance, numeric: true).disabled(published)
                Toggle("要求 EMA144 同向", isOn: $align144).disabled(published)
            }
            Section("策略代码") { Text(code).font(.caption.monospaced()).textSelection(.enabled) }
            USDTNotice(text: notice)
        }.usdtPage("研究策略 v\(initial.value("version"))").onAppear {
            name = initial.value("name"); rationale = initial.value("rationale", fallback: "")
            rules = (initial["natural_rules"]?.rows ?? []).map(\.text).joined(separator: "\n")
            published = initial.value("status") == "published"
            let definition = initial["definition"] ?? .null
            flipWindow = Int(definition.value("flip_window")) ?? 8
            minGap = definition.value("min_ema_gap_atr", fallback: "0")
            maxDistance = definition.value("max_close_distance_atr", fallback: "0.35")
            align144 = definition["require_ema144_alignment"]?.flag ?? false
            code = initial.value("code", fallback: "")
        }.confirmationDialog("发布后此版本不可修改。确认发布？", isPresented: $confirm, titleVisibility: .visible) {
            Button("发布") { Task { do { try await saveDraft(); _ = try await store.send(path + "/publish"); published = true; notice = "已发布" } catch { notice = error.localizedDescription } } }
        }
    }
    private var path: String { "/v1/signal-research/strategies/\(initial.value("id"))" }
    private func saveDraft() async throws {
        guard let gap = Double(minGap), gap.isFinite, (0...5).contains(gap),
              let distance = Double(maxDistance), distance.isFinite, (0.05...3).contains(distance) else {
            throw APIError.business(code: "400", message: "请填写范围内的策略参数")
        }
        let result = try await store.send(path, ["name": .string(name), "rationale": .string(rationale), "natural_rules": .array(rules.split(separator: "\n").map { .string(String($0)) }), "definition": .object(["flip_window": .number(Double(flipWindow)), "min_ema_gap_atr": .number(gap), "max_close_distance_atr": .number(distance), "require_ema144_alignment": .bool(align144)])], method: .patch)
        code = result.value("code", fallback: code)
    }
    private func save() { Task { do { try await saveDraft(); notice = "已保存" } catch { notice = error.localizedDescription } } }
}

struct USDTResearchBacktestView: View {
    @EnvironmentObject private var store: USDTStore
    @State private var strategies: [JSONValue] = []
    @State private var strategy = ""
    @State private var symbol = "BTCUSDT"
    @State private var timeframe = "1h"
    @State private var start = Date().addingTimeInterval(-7 * 86400)
    @State private var end = Date()
    @State private var result: JSONValue = .null
    @State private var notice = ""
    @State private var busy = false
    var body: some View {
        Form {
            Section("回测参数") {
                USDTField(title: "交易对", text: $symbol)
                Picker("周期", selection: $timeframe) { ForEach(["15m", "1h", "4h", "1d"], id: \.self) { Text($0) } }
                Picker("已发布策略", selection: $strategy) { Text("请选择").tag(""); ForEach(Array(strategies.enumerated()), id: \.offset) { _, row in Text(row.value("name") + " v" + row.value("version")).tag(row.value("id")) } }
                DatePicker("开始", selection: $start); DatePicker("结束", selection: $end)
                Button(busy ? "回测中…" : "开始回测") { run() }.disabled(busy || strategy.isEmpty || start >= end)
            }
            Section("信号结果 \(result["results"]?.rows.count ?? 0)") {
                ForEach(Array((result["results"]?.rows ?? []).enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 8) {
                        USDTMetric(title: row.value("direction"), value: row.value("signal_time"))
                        USDTResearchFeatures(features: row["features"] ?? .null)
                    }.padding(.vertical, 8)
                }
                USDTNotice(text: notice)
            }
        }.usdtPage("策略回测").task {
            do { strategies = try await store.get("/v1/signal-research/strategies").rows.filter { $0.value("status") == "published" } } catch { notice = error.localizedDescription }
        }
    }
    private func run() {
        busy = true
        Task { defer { busy = false }; do {
            result = try await store.send("/v1/signal-research/backtest", ["symbol": .string(symbol.uppercased()), "timeframe": .string(timeframe), "strategy_id": .string(strategy), "start_time": .string(ISO8601DateFormatter().string(from: start)), "end_time": .string(ISO8601DateFormatter().string(from: end))]); notice = "回测完成"
        } catch { notice = error.localizedDescription } }
    }
}
