import Charts
import SwiftUI

struct USDTResearchView: View {
  @EnvironmentObject private var store: USDTStore
  @StateObject private var samples = USDTPageModel()
  @StateObject private var strategies = USDTPageModel()
  @State private var page = "entry"
  @State private var notice = ""
  @State private var busy = false
  @State private var models: [JSONValue] = []
  @State private var modelID = ""
  @State private var modelPicker = false
  @State private var preview = false
  @State private var packet: JSONValue = .null
  @State private var fetchTarget: JSONValue? = nil
  @State private var confirmingFetch = false
  @State private var selectedSample: JSONValue? = nil
  @State private var selectedStrategy: JSONValue? = nil
  private let tabs = [
    ("entry", "数据录入"), ("analysis", "数据分析"), ("rules", "规则与代码"), ("backtest", "策略回测"),
  ]
  init(initialPage: String = "entry") { _page = State(initialValue: initialPage) }
  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        HStack {
          Menu {
            ForEach(tabs, id: \.0) { key, title in Button(title) { page = key } }
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(tabs.first { $0.0 == page }?.1 ?? "数据录入").font(.system(size: 18, weight: .bold))
              Text("EMA 21 / 55 / 144 · SuperTrend (ATR 10, ×6)").font(.system(size: 12))
                .foregroundStyle(WebTheme.muted)
            }
          }.accessibilityIdentifier("research.navigation").accessibilityLabel("研究页面")
          Spacer()
          Button {
            Task { await load() }
          } label: {
            WebIcon("refresh-cw", size: 17).foregroundStyle(WebTheme.muted).frame(
              width: 34, height: 34
            ).overlay { RoundedRectangle(cornerRadius: 10).stroke(WebTheme.border, lineWidth: 1) }
          }.accessibilityLabel("刷新研究")
        }.padding(.horizontal, 20).padding(.vertical, 16).background(WebTheme.page).overlay(
          alignment: .bottom
        ) { Rectangle().fill(WebTheme.border).frame(height: 1) }
        VStack(spacing: 24) {
          if page == "entry" {
            USDTResearchSampleEditor(embedded: true, onSaved: { Task { await load() } })
            sampleList(analysis: false)
          } else if page == "analysis" {
            sampleList(analysis: true)
            if let selectedSample {
              USDTResearchSampleView(
                sample: selectedSample, embedded: true,
                onDeleted: {
                  self.selectedSample = nil
                  Task { await load() }
                }
              ).id(selectedSample.value("id"))
            } else {
              Text("选择一个已获取数据的样本。").font(.system(size: 16)).foregroundStyle(WebTheme.muted).frame(
                maxWidth: .infinity
              ).padding(48).overlay {
                RoundedRectangle(cornerRadius: 16).stroke(
                  WebTheme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
              }
            }
          } else if page == "rules" {
            rulesPanel
          } else {
            USDTResearchBacktestView(embedded: true)
          }
          USDTNotice(text: notice)
        }.padding(20)
      }.frame(maxWidth: 1152).frame(maxWidth: .infinity)
    }.scrollIndicators(.hidden).usdtPage("信号研究").task(id: store.scope) { await load() }.refreshable
    { await load() }
    .webModal(isPresented: $modelPicker) {
      ZStack {
        Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { modelPicker = false }
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            Text("选择大模型").font(.system(size: 18, weight: .bold))
            Spacer()
            Button {
              modelPicker = false
            } label: {
              WebIcon("x", size: 20)
            }.accessibilityLabel("关闭")
          }
          Text("选择用于生成本账户策略草案的大模型。")
            .font(.system(size: 12)).foregroundStyle(WebTheme.muted).padding(.top, 8)
          VStack(spacing: 8) {
            ForEach(Array(models.enumerated()), id: \.offset) { _, row in
              Button {
                modelID = row.value("id")
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  HStack {
                    Text(row.value("name")).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(modelID == row.value("id") ? "已选择" : row.value("model"))
                      .font(.system(size: 12)).foregroundStyle(WebTheme.muted)
                  }
                  Text(row.value("provider") + " · " + row.value("model"))
                    .font(.system(size: 12)).foregroundStyle(WebTheme.muted)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                  .background(
                    modelID == row.value("id")
                      ? Color(red: 1, green: 250 / 255, blue: 240 / 255) : .white,
                    in: RoundedRectangle(cornerRadius: 14)
                  )
                  .overlay {
                    RoundedRectangle(cornerRadius: 14).stroke(
                      modelID == row.value("id")
                        ? Color(red: 228 / 255, green: 191 / 255, blue: 86 / 255) : WebTheme.border,
                      lineWidth: 1)
                  }
              }
            }
          }.padding(.top, 20)
          HStack {
            Spacer()
            Button("确定使用") {
              Task {
                do {
                  _ = try await store.send("/v1/signal-research/ai-models/\(modelID)/activate")
                  modelPicker = false
                } catch { notice = error.localizedDescription }
              }
            }.buttonStyle(
              WebButtonStyle(height: 40, radius: 14, fontSize: 14, fullWidth: false, weight: .bold)
            ).disabled(modelID.isEmpty)
          }.padding(.top, 20)
        }.padding(20).frame(maxWidth: 672).foregroundStyle(WebTheme.text)
          .background(.white, in: RoundedRectangle(cornerRadius: 16)).padding(16)
      }.preferredColorScheme(.light).presentationBackground(.clear)
    }
    .webModal(isPresented: $preview) {
      ResearchModal(title: "AI 研究包预览", subtitle: "以下内容将原样发送；不含 API Key、账户或未来数据。") {
        VStack(alignment: .leading, spacing: 16) {
          Button {
            UIPasteboard.general.string = prettyPacket
          } label: {
            WebLabel("复制完整请求", "copy")
          }.buttonStyle(
            WebButtonStyle(kind: .secondary, height: 38, fontSize: 14, fullWidth: false)
          ).frame(maxWidth: .infinity, alignment: .trailing)
          Text("完整请求体").font(.system(size: 14, weight: .bold))
          ScrollView([.horizontal, .vertical]) {
            Text(prettyPacket).font(.system(size: 12, design: .monospaced)).lineSpacing(10)
              .textSelection(.enabled).foregroundStyle(
                Color(red: 214 / 255, green: 228 / 255, blue: 207 / 255)
              ).padding(16)
          }.frame(maxHeight: 420).frame(maxWidth: .infinity, alignment: .leading).background(
            Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255),
            in: RoundedRectangle(cornerRadius: 14))
          Button("确认发送给 AI") {
            preview = false
            generate()
          }.buttonStyle(WebButtonStyle(radius: 14, fontSize: 14, weight: .bold)).disabled(busy)
        }.padding(20)
      }
    }
    .webModal(isPresented: $confirmingFetch) {
      WebModal(title: "获取历史数据") {
        Text("确认向币安获取样本所需的历史 K 线并计算特征？").foregroundStyle(WebTheme.secondary)
        HStack(spacing: 12) {
          Button("取消") { confirmingFetch = false }.buttonStyle(
            WebButtonStyle(kind: .secondary, radius: 14))
          Button("确认获取") {
            confirmingFetch = false
            fetchPending()
          }.buttonStyle(WebButtonStyle(radius: 14))
        }
      }
    }
  }
  private var prettyPacket: String {
    guard let data = try? JSONEncoder().encode(packet["request"] ?? packet),
      let object = try? JSONSerialization.jsonObject(with: data),
      let pretty = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
      let string = String(data: pretty, encoding: .utf8)
    else { return "" }
    return string
  }
  private func sampleList(analysis: Bool) -> some View {
    VStack(spacing: 0) {
      HStack {
        Text(analysis ? "数据样本" : "已录入样本").font(.system(size: 16, weight: .bold))
        if !analysis {
          Text("\(samples.items.count)").font(.system(size: 14)).foregroundStyle(WebTheme.muted)
        }
        Spacer()
        if !analysis
          && samples.items.contains(where: { $0["fetched_at"] == nil || $0["fetched_at"] == .null })
        {
          Button(busy ? "正在批量采集..." : "一键采集待采集数据") {
            fetchTarget = nil
            confirmingFetch = true
          }.buttonStyle(
            WebButtonStyle(kind: .secondary, height: 34, radius: 10, fontSize: 12, fullWidth: false)
          ).disabled(busy)
        }
      }.padding(.horizontal, 20).padding(.vertical, 16)
      Rectangle().fill(WebTheme.border).frame(height: 1)
      if samples.items.isEmpty {
        Text(analysis ? "请先在“数据录入”获取一个样本。" : "还没有样本。先录入你认为可信的信号。").font(.system(size: 14))
          .foregroundStyle(WebTheme.muted).frame(maxWidth: .infinity).padding(40)
      }
      ForEach(
        Array(
          samples.items.filter {
            !analysis || ($0["fetched_at"] != nil && $0["fetched_at"] != .null)
          }.enumerated()), id: \.offset
      ) { _, row in
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 12) {
            WebBadge(
              text: row.value("expected_direction") == "long"
                ? "做多" : row.value("expected_direction") == "short" ? "做空" : "观察",
              color: row.value("expected_direction") == "short" ? WebTheme.danger : WebTheme.success
            )
            Button {
              selectedSample = row
              page = "analysis"
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(row.value("symbol") + " · " + row.value("timeframe")).font(
                  .system(size: 16, weight: .semibold))
                Text(WebFormat.time(row.value("signal_time"), format: "yyyy/MM/dd HH:mm:ss")).font(
                  .system(size: 12)
                ).foregroundStyle(WebTheme.muted)
              }
            }
            Spacer(minLength: 0)
          }
          HStack {
            if row["fetched_at"] == nil || row["fetched_at"] == .null {
              Button("获取数据") {
                fetchTarget = row
                confirmingFetch = true
              }.buttonStyle(
                WebButtonStyle(
                  kind: .secondary, height: 34, radius: 10, fontSize: 12, fullWidth: false))
            }
            Button {
              selectedSample = row
              page = "analysis"
            } label: {
              Text("查看 / 标注")
            }.buttonStyle(
              WebButtonStyle(
                kind: .secondary, height: 34, radius: 10, fontSize: 12, fullWidth: false))
            Text(row.value("note", fallback: "")).font(.system(size: 12)).foregroundStyle(
              WebTheme.muted
            ).lineLimit(2)
          }
        }.padding(16)
        Rectangle().fill(WebTheme.border).frame(height: 1)
      }
    }.background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 16)).overlay {
      RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1)
    }
  }
  private var rulesPanel: some View {
    VStack(spacing: 20) {
      VStack(spacing: 12) {
        Button("选择大模型") {
          Task {
            do {
              models = try await store.get("/v1/signal-research/ai-models").rows
              modelID =
                models.first { $0["is_active"]?.flag == true }?.value("id") ?? models.first?.value(
                  "id") ?? ""
              modelPicker = true
            } catch { notice = error.localizedDescription }
          }
        }.buttonStyle(WebButtonStyle(kind: .secondary, height: 42, radius: 14, fontSize: 14))
        Button {
          Task {
            do {
              packet = try await store.get("/v1/signal-research/strategies/preview")
              preview = true
            } catch { notice = error.localizedDescription }
          }
        } label: {
          WebLabel("预览本次研究包", "eye")
        }.buttonStyle(WebButtonStyle(kind: .secondary, height: 42, radius: 14, fontSize: 14))
        Button(busy ? "AI 正在生成..." : "AI 生成策略草案") { generate() }.buttonStyle(
          WebButtonStyle(radius: 14, fontSize: 14)
        ).disabled(busy)
        Text("仅在你点击后发送已标注样本的压缩特征、备注与正反例；不会后台自动调用。").font(.system(size: 12)).foregroundStyle(
          WebTheme.muted
        ).lineSpacing(5)
        ForEach(Array(strategies.items.enumerated()), id: \.offset) { _, row in
          Button {
            selectedStrategy = row
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(row.value("name") + " v" + row.value("version")).font(
                .system(size: 14, weight: .semibold))
              Text(row.value("status") == "published" ? "已发布" : "待审核草案").font(.system(size: 12))
                .foregroundStyle(WebTheme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).overlay {
              RoundedRectangle(cornerRadius: 10).stroke(WebTheme.border, lineWidth: 1)
            }
          }
        }
      }.padding(16).overlay {
        RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1)
      }
      if let selectedStrategy {
        USDTResearchStrategyView(initial: selectedStrategy, embedded: true).id(
          selectedStrategy.value("id"))
      } else {
        Text("先标注可信样本，再点击“AI 生成策略草案”。").font(.system(size: 16)).foregroundStyle(WebTheme.muted)
          .frame(maxWidth: .infinity).padding(48).overlay {
            RoundedRectangle(cornerRadius: 16).stroke(
              WebTheme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
          }
      }
    }
  }
  private func load() async {
    await samples.load(store, path: "/v1/signal-research/samples")
    await strategies.load(store, path: "/v1/signal-research/strategies")
    if selectedSample == nil {
      selectedSample = samples.items.first { $0["fetched_at"] != nil && $0["fetched_at"] != .null }
    }
    if selectedStrategy == nil { selectedStrategy = strategies.items.first }
  }
  private func fetchPending() {
    busy = true
    let rows =
      fetchTarget.map { [$0] }
      ?? samples.items.filter { $0["fetched_at"] == nil || $0["fetched_at"] == .null }
    Task {
      defer { busy = false }
      do {
        for row in rows {
          _ = try await store.send("/v1/signal-research/samples/\(row.value("id"))/fetch")
        }
        await load()
      } catch { notice = error.localizedDescription }
    }
  }
  private func generate() {
    busy = true
    Task {
      defer { busy = false }
      do {
        _ = try await store.send("/v1/signal-research/strategies/generate")
        await load()
      } catch { notice = error.localizedDescription }
    }
  }
}

private let researchTimeframes = [
  ("1m", "1分钟"), ("3m", "3分钟"), ("5m", "5分钟"), ("15m", "15分钟"), ("1h", "1小时"), ("4h", "4小时"),
  ("1d", "1天"),
]

struct USDTResearchSampleEditor: View {
  @EnvironmentObject private var store: USDTStore
  @Environment(\.dismiss) private var dismiss
  var embedded = false
  var onSaved: (() -> Void)? = nil
  @State private var symbol = "BTCUSDT"
  @State private var timeframe = "1h"
  @State private var time = Date()
  @State private var direction = "neutral"
  @State private var note = ""
  @State private var notice = ""
  @State private var busy = false
  var body: some View {
    Group { if embedded { form } else { WebForm { form }.usdtPage("数据录入") } }
  }
  private var form: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Image(systemName: "plus").font(.system(size: 18)).foregroundStyle(
          Color(red: 183 / 255, green: 134 / 255, blue: 0)
        ).frame(width: 32, height: 32).background(
          WebTheme.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 0) {
          Text("录入一个已收盘信号样本").font(.system(size: 16, weight: .bold))
          Text("保存后，再由你主动确认是否向币安获取历史数据。").font(.system(size: 12)).foregroundStyle(WebTheme.muted)
        }
      }.padding(.bottom, 4)
      WebSelect(title: "合约币种", selection: $symbol, options: researchSymbols.map { ($0, $0) })
      WebSelect(title: "K线周期", selection: $timeframe, options: researchTimeframes)
      WebSelect(
        title: "预期方向", selection: $direction,
        options: [("long", "做多"), ("short", "做空"), ("neutral", "仅观察")])
      WebDateField(title: "K线收盘时间", selection: $time, latestDate: .now)
      WebTextArea(title: "观察备注（可选）", text: $note, placeholder: "例如：此处由空转多，回踩 EMA21 后收回...")
      Button(busy ? "保存中..." : "保存样本") { save() }.buttonStyle(
        WebButtonStyle(radius: 14, fontSize: 14, fullWidth: false)
      ).frame(maxWidth: .infinity, alignment: .trailing).disabled(busy).padding(.top, 4)
      USDTNotice(text: notice)
    }.padding(20).background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 16)).overlay {
      RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1)
    }
  }
  private func save() {
    busy = true
    Task {
      defer { busy = false }
      do {
        _ = try await store.send(
          "/v1/signal-research/samples",
          [
            "symbol": .string(symbol.uppercased()), "timeframe": .string(timeframe),
            "signal_time": .string(ISO8601DateFormatter().string(from: time)),
            "expected_direction": .string(direction), "note": .string(note), "trusted": .null,
          ])
        notice = "样本已保存"
        onSaved?()
        if !embedded { dismiss() }
      } catch { notice = error.localizedDescription }
    }
  }
}

struct USDTResearchSampleView: View {
  @EnvironmentObject private var store: USDTStore
  @Environment(\.dismiss) private var dismiss
  let sample: JSONValue
  var embedded = false
  var onDeleted: (() -> Void)? = nil
  @State private var value: JSONValue = .null
  @State private var note = ""
  @State private var notice = ""
  @State private var deleting = false
  @State private var busy = false
  @State private var chart = false
  var body: some View {
    Group {
      if embedded {
        content
      } else {
        ScrollView { content.padding(20) }.usdtPage(sample.value("symbol"))
      }
    }
    .task { await load() }
    .webModal(isPresented: $chart) { ResearchCandleModal(sample: sample) }
    .webModal(isPresented: $deleting) {
      WebModal(title: "删除样本") {
        Text("确定删除该采集样本？").foregroundStyle(WebTheme.secondary)
        HStack(spacing: 12) {
          Button("取消") { deleting = false }.buttonStyle(
            WebButtonStyle(kind: .secondary, radius: 14))
          Button("删除") {
            deleting = false
            Task {
              do {
                _ = try await store.send(path, method: .delete)
                if embedded { onDeleted?() } else { dismiss() }
              } catch { notice = error.localizedDescription }
            }
          }.buttonStyle(WebButtonStyle(kind: .danger, radius: 14))
        }
      }
    }
  }
  private var content: some View {
    VStack(spacing: 20) {
      VStack(alignment: .leading, spacing: 16) {
        Text(sample.value("symbol") + " · " + sample.value("timeframe")).font(
          .system(size: 20, weight: .bold))
        Text("收盘时间：" + WebFormat.time(sample.value("signal_time"), format: "yyyy/MM/dd HH:mm:ss"))
          .font(.system(size: 14)).foregroundStyle(WebTheme.muted)
        Button {
          chart = true
        } label: {
          WebLabel("查看蜡烛图", "chart-candlestick")
        }.buttonStyle(
          WebButtonStyle(kind: .secondary, height: 38, radius: 14, fontSize: 14, fullWidth: false))
        if value["fetched_at"] == nil || value["fetched_at"] == .null {
          Button(busy ? "获取中…" : "获取样本行情并分析") { fetch() }.buttonStyle(
            WebButtonStyle(kind: .secondary, height: 40, radius: 14, fontSize: 14)
          ).disabled(busy)
        }
      }.padding(20).frame(maxWidth: .infinity, alignment: .leading).overlay {
        RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1)
      }
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          Text("量化特征快照").font(.system(size: 16, weight: .bold))
          Text("以下值均只使用该根 K 线收盘前的数据计算。").font(.system(size: 12)).foregroundStyle(WebTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(
          .vertical, 16)
        Rectangle().fill(WebTheme.border).frame(height: 1)
        USDTResearchFeatures(features: value["features"] ?? sample["features"] ?? .null)
      }.overlay { RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1) }
      HStack(spacing: 8) {
        Button("可信") { mark(.bool(true)) }
        Button("不可信") { mark(.bool(false)) }
        Button("未标注") { mark(.null) }
        Button {
          deleting = true
        } label: {
          WebIcon("trash-2", size: 16).foregroundStyle(WebTheme.danger)
        }
      }.buttonStyle(WebButtonStyle(kind: .secondary, height: 34, radius: 4, fontSize: 12))
      WebTextArea(title: "观察备注", text: $note)
      Button("保存备注") {
        Task {
          do {
            value = try await store.send(path, ["note": .string(note)], method: .patch)
            notice = "已保存"
          } catch { notice = error.localizedDescription }
        }
      }.buttonStyle(WebButtonStyle(height: 40, radius: 14, fontSize: 14))
      USDTNotice(text: notice)
    }
  }
  private var path: String { "/v1/signal-research/samples/\(sample.value("id"))" }
  private func load() async {
    do {
      value = try await store.get(path)
      note = value.value("note", fallback: sample.value("note", fallback: ""))
    } catch { notice = error.localizedDescription }
  }
  private func mark(_ trusted: JSONValue) {
    Task {
      do { value = try await store.send(path, ["trusted": trusted], method: .patch) } catch {
        notice = error.localizedDescription
      }
    }
  }
  private func fetch() {
    busy = true
    Task {
      defer { busy = false }
      do { value = try await store.send(path + "/fetch") } catch {
        notice = error.localizedDescription
      }
    }
  }
}

struct USDTResearchFeatures: View {
  let features: JSONValue
  private static let labels: [(String, String)] = [
    ("trend", "趋势 · Trend"),
    ("supertrend_flip", "超级趋势翻转 · SuperTrend Flip"),
    ("ema_alignment", "均线排列 · EMA Alignment"),
    ("close_to_ema21_atr", "距 EMA21（ATR）· Close to EMA21 ATR"),
    ("close_to_ema55_atr", "距 EMA55（ATR）· Close to EMA55 ATR"),
    ("close_to_ema144_atr", "距 EMA144（ATR）· Close to EMA144 ATR"),
    ("ema21_slope_5", "EMA21 斜率（5根）· EMA21 Slope 5"),
    ("ema21_slope_10_atr", "EMA21 斜率（10根）· EMA21 Slope 10 ATR"),
    ("ema21_slope_20_atr", "EMA21 斜率（20根）· EMA21 Slope 20 ATR"),
    ("ema21_55_gap_atr", "EMA21/55 间距 · EMA21/55 Gap ATR"),
    ("ema55_144_gap_atr", "EMA55/144 间距 · EMA55/144 Gap ATR"),
    ("supertrend_age_bars", "趋势持续K数 · SuperTrend Age"),
    ("atr_percent", "ATR 波动率 · ATR Percent"),
    ("range_atr", "K线振幅（ATR）· Range ATR"),
    ("volume_ratio_20", "20根量比 · Volume Ratio 20"),
    ("volume_zscore_20", "成交量 Z 分数 · Volume Z-Score 20"),
    ("return_1_pct", "1根收益率 · Return 1"),
    ("return_5_pct", "5根收益率 · Return 5"),
    ("return_20_pct", "20根收益率 · Return 20"),
    ("realized_volatility_20_pct", "20根实现波动率 · Realized Volatility 20"),
    ("close_position_20", "20根区间位置 · Close Position 20"),
    ("close_position_55", "55根区间位置 · Close Position 55"),
    ("drawdown_from_20_high_pct", "距20根高点回撤 · Drawdown from 20 High"),
    ("upside_from_20_low_pct", "距20根低点涨幅 · Upside from 20 Low"),
    ("bollinger_width_pct", "布林带宽度 · Bollinger Width"),
    ("bollinger_percent_b", "布林带位置 · Bollinger %B"),
    ("body_atr", "实体大小（ATR）· Body ATR"),
    ("upper_wick_atr", "上影线（ATR）· Upper Wick ATR"),
    ("lower_wick_atr", "下影线（ATR）· Lower Wick ATR"),
    ("close_location_value", "收盘位置 · Close Location"),
    ("pullback_to_ema21", "是否回踩 EMA21 · Pullback to EMA21"),
    ("close", "收盘价 · Close"),
  ]
  private var entries: [(String, JSONValue)] {
    let known = Self.labels.map(\.0).filter { features[$0] != nil }
    let extra = features.fields.keys.filter { $0 != "ready" && !known.contains($0) }.sorted()
    return (known + extra).map { ($0, features[$0] ?? .null) }
  }
  var body: some View {
    VStack(spacing: 0) {
      ForEach(entries, id: \.0) { key, value in
        VStack(alignment: .leading, spacing: 4) {
          Text(Self.labels.first { $0.0 == key }?.1 ?? key.replacingOccurrences(of: "_", with: " "))
            .font(.system(size: 12)).foregroundStyle(WebTheme.muted)
          Text(formatted(value)).font(.system(size: 16, weight: .semibold))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        Rectangle().fill(WebTheme.border).frame(height: 1)
      }
    }
  }
  private func formatted(_ value: JSONValue) -> String {
    if case .bool(let flag) = value { return flag ? "是" : "否" }
    if case .number(let number) = value {
      return number.formatted(
        .number.locale(Locale(identifier: "zh_CN")).precision(.fractionLength(0...4)))
    }
    return value == .null ? "-" : value.text
  }
}

/// The research chart is a separate audit modal; the first market tab keeps its Metal engine.
struct USDTResearchChart: View {
  let candles: [JSONValue]
  var signalTime: Date? = nil
  private let indicators: [(String, String, Color)] = [
    ("ema21", "EMA 21", Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255)),
    ("ema55", "EMA 55", Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)),
    ("ema144", "EMA 144", Color(red: 124 / 255, green: 58 / 255, blue: 237 / 255)),
    ("supertrend", "SuperTrend (10, 6)", Color(red: 17 / 255, green: 24 / 255, blue: 39 / 255)),
  ]
  var body: some View {
    if candles.isEmpty {
      Text("获取行情后显示样本 K 线").font(.system(size: 14)).frame(height: 520).frame(maxWidth: .infinity)
    } else {
      ScrollView(.horizontal) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 12) {
            ForEach(indicators, id: \.0) { _, title, color in
              Text("● " + title).font(.system(size: 12)).foregroundStyle(color)
            }
          }
          Chart {
            ForEach(Array(candles.enumerated()), id: \.offset) { index, candle in
              let open = Double(candle.value("open")) ?? 0
              let close = Double(candle.value("close")) ?? 0
              let color =
                close >= open
                ? Color(red: 22 / 255, green: 163 / 255, blue: 74 / 255)
                : Color(red: 220 / 255, green: 38 / 255, blue: 38 / 255)
              RuleMark(
                x: .value("时间", index), yStart: .value("低", Double(candle.value("low")) ?? 0),
                yEnd: .value("高", Double(candle.value("high")) ?? 0)
              ).foregroundStyle(color)
              RectangleMark(
                x: .value("时间", index), yStart: .value("开", min(open, close)),
                yEnd: .value("收", max(open, close)),
                width: .fixed(max(1, 650 / CGFloat(max(1, candles.count)) * 0.7))
              ).foregroundStyle(color)
              ForEach(indicators, id: \.0) { key, title, color in
                if let amount = candle[key]?.decimal {
                  LineMark(
                    x: .value("时间", index),
                    y: .value("价格", NSDecimalNumber(decimal: amount).doubleValue),
                    series: .value("指标", title)
                  ).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
                }
              }
            }
            if let index = signalIndex, let low = candles[index]["low"]?.decimal {
              PointMark(
                x: .value("信号", index), y: .value("信号价", NSDecimalNumber(decimal: low).doubleValue)
              ).foregroundStyle(WebTheme.brand).symbol(.triangle).annotation(position: .bottom) {
                Text("信号").font(.system(size: 12)).foregroundStyle(WebTheme.brand)
              }
            }
          }.chartYScale(domain: .automatic(includesZero: false)).chartLegend(.hidden).chartYAxis {
            AxisMarks(position: .trailing) {
              AxisGridLine().foregroundStyle(
                Color(red: 243 / 255, green: 244 / 255, blue: 246 / 255))
              AxisValueLabel().font(.system(size: 12)).foregroundStyle(WebTheme.muted)
            }
          }.chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
              AxisGridLine().foregroundStyle(
                Color(red: 243 / 255, green: 244 / 255, blue: 246 / 255))
              AxisValueLabel {
                if let index = value.as(Int.self), candles.indices.contains(index) {
                  Text(timeLabel(candles[index])).font(.system(size: 12)).foregroundStyle(
                    WebTheme.muted)
                }
              }
            }
          }.frame(height: 520).accessibilityLabel("样本蜡烛图与 EMA21、EMA55、EMA144、SuperTrend")
            .accessibilityIdentifier("research.candles")
        }.frame(minWidth: 700).padding(16)
      }
    }
  }
  private func timeLabel(_ candle: JSONValue) -> String {
    guard let date = WebFormat.date(candle.value("time", fallback: candle.value("open_time")))
    else { return "" }
    let format = DateFormatter()
    format.timeZone = TimeZone(secondsFromGMT: 0)
    format.dateFormat = "MM/dd HH:mm"
    return format.string(from: date)
  }
  private var signalIndex: Int? {
    guard let signalTime else { return nil }
    return candles.firstIndex {
      ($0["close_time"]?.decimal.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0)
        >= signalTime.timeIntervalSince1970 * 1000
    }
  }
}

private struct ResearchCandleModal: View {
  @EnvironmentObject private var store: USDTStore
  let sample: JSONValue
  @State private var candles: [JSONValue] = []
  @State private var loading = true
  @State private var notice = ""
  var body: some View {
    ResearchModal(
      title: sample.value("symbol") + " · " + researchTimeframe(sample.value("timeframe"))
        + " · K线复核",
      subtitle: "信号收盘："
        + WebFormat.time(sample.value("signal_time"), format: "yyyy/MM/dd HH:mm:ss"),
      maximumWidth: 1152
    ) {
      if loading {
        ProgressView().frame(height: 520).frame(maxWidth: .infinity)
      } else {
        USDTResearchChart(candles: candles, signalTime: WebFormat.date(sample.value("signal_time")))
      }
      USDTNotice(text: notice).padding(.horizontal, 16)
    }.task {
      do {
        let result = try await store.get(
          "/v1/signal-research/chart",
          query: [
            .init(name: "symbol", value: sample.value("symbol")),
            .init(name: "timeframe", value: sample.value("timeframe")),
            .init(
              name: "signal_time",
              value: WebFormat.date(sample.value("signal_time")).map {
                ISO8601DateFormatter().string(from: $0)
              } ?? sample.value("signal_time")),
          ])
        candles = result["candles"]?.rows ?? []
      } catch { notice = error.localizedDescription }
      loading = false
    }
  }
}

private struct ResearchModal<Content: View>: View {
  let title: String
  var subtitle = ""
  var maximumWidth: CGFloat = 1024
  @ViewBuilder var content: Content
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { dismiss() }
        VStack(spacing: 0) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(title).font(.system(size: 16, weight: .bold))
              if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(WebTheme.muted)
              }
            }
            Spacer()
            Button {
              dismiss()
            } label: {
              WebIcon("x", size: 20).padding(8)
            }.accessibilityLabel("关闭")
          }.padding(.horizontal, 20).padding(.vertical, 16)
          Rectangle().fill(WebTheme.border).frame(height: 1)
          ScrollView { content }.scrollIndicators(.hidden)
        }.fixedSize(horizontal: false, vertical: true).frame(
          maxWidth: maximumWidth, maxHeight: geometry.size.height * 0.92
        ).background(.white, in: RoundedRectangle(cornerRadius: 16)).clipShape(
          RoundedRectangle(cornerRadius: 16)
        ).overlay { RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1) }
          .padding(16)
      }
    }.environment(\.colorScheme, .light).foregroundStyle(WebTheme.text).presentationBackground(
      .clear
    ).buttonStyle(.plain)
  }
}

struct USDTResearchStrategyView: View {
  @EnvironmentObject private var store: USDTStore
  let initial: JSONValue
  var embedded = false
  @State private var published = false
  @State private var confirm = false
  @State private var notice = ""
  var body: some View {
    Group { if embedded { content } else { ScrollView { content.padding(20) }.usdtPage("规则与代码") } }
      .onAppear { published = initial.value("status") == "published" }
      .webModal(isPresented: $confirm) {
        WebModal(title: "确认发布") {
          Text("发布后此版本不可修改。确认发布？").foregroundStyle(WebTheme.secondary)
          HStack(spacing: 12) {
            Button("取消") { confirm = false }.buttonStyle(
              WebButtonStyle(kind: .secondary, radius: 14))
            Button("发布") {
              confirm = false
              Task {
                do {
                  _ = try await store.send(
                    "/v1/signal-research/strategies/\(initial.value("id"))/publish")
                  published = true
                } catch { notice = error.localizedDescription }
              }
            }.buttonStyle(WebButtonStyle(radius: 14))
          }
        }
      }
  }
  private var content: some View {
    VStack(spacing: 20) {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .top, spacing: 8) {
          WebIcon("book-open", size: 24).foregroundStyle(WebTheme.brand)
          Text(initial.value("name") + " v" + initial.value("version")).font(
            .system(size: 20, weight: .bold))
          Spacer(minLength: 0)
        }
        Text(
          "依据 \(initial["research_packet"]?.value("trusted_count",fallback:"0") ?? "0") 个可信样本生成 · \(published ? "已发布且不可修改" : "请审核后发布")"
        ).font(.system(size: 14)).foregroundStyle(WebTheme.muted)
        if !published {
          Button("确认发布") { confirm = true }.buttonStyle(
            WebButtonStyle(height: 36, radius: 14, fontSize: 14, fullWidth: false))
        }
        ForEach(Array((initial["natural_rules"]?.rows ?? []).enumerated()), id: \.offset) {
          index, rule in
          HStack(alignment: .top, spacing: 12) {
            Text("\(index+1)").font(.system(size: 12, weight: .bold)).foregroundStyle(
              WebTheme.brand
            ).frame(width: 24, height: 24).background(WebTheme.brand.opacity(0.12), in: Circle())
            Text(rule.text).font(.system(size: 14)).lineSpacing(6)
          }
        }
        if !initial.value("rationale", fallback: "").isEmpty {
          Text(initial.value("rationale")).font(.system(size: 14)).foregroundStyle(WebTheme.brand)
            .lineSpacing(6).padding(16).background(
              WebTheme.brand.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        }
      }.padding(24).frame(maxWidth: .infinity, alignment: .leading).overlay {
        RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1)
      }
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          WebIcon("code-2", size: 18)
          Text("受限策略代码").font(.system(size: 16, weight: .bold))
          Spacer()
        }.padding(.horizontal, 20).padding(.vertical, 16)
        ScrollView(.horizontal) {
          Text(initial.value("code", fallback: "")).font(.system(size: 14, design: .monospaced))
            .lineSpacing(7).textSelection(.enabled).foregroundStyle(
              Color(red: 214 / 255, green: 228 / 255, blue: 207 / 255)
            ).padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 120).background(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255))
      }.clipShape(RoundedRectangle(cornerRadius: 16)).overlay {
        RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1)
      }
      USDTNotice(text: notice)
    }
  }
}

struct USDTResearchBacktestView: View {
  var embedded = false
  @EnvironmentObject private var store: USDTStore
  @State private var strategies: [JSONValue] = []
  @State private var chartSample: JSONValue = .null
  @State private var showChart = false
  @State private var strategy = ""
  @State private var symbol = "BTCUSDT"
  @State private var timeframe = "1h"
  @State private var start = Date().addingTimeInterval(-7 * 86400)
  @State private var end = Date()
  @State private var result: JSONValue = .null
  @State private var notice = ""
  @State private var busy = false
  var body: some View {
    Group { if embedded { content } else { ScrollView { content.padding(20) }.usdtPage("策略回测") } }
      .task {
        do {
          strategies = try await store.get("/v1/signal-research/strategies").rows.filter {
            $0.value("status") == "published"
          }
          strategy = strategies.first?.value("id") ?? ""
        } catch { notice = error.localizedDescription }
      }
      .webModal(isPresented: $showChart) { ResearchCandleModal(sample: chartSample) }
  }
  private var content: some View {
    VStack(spacing: 24) {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          WebIcon("play", size: 18).foregroundStyle(WebTheme.brand).frame(width: 32, height: 32)
            .background(WebTheme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
          VStack(alignment: .leading, spacing: 0) {
            Text("运行策略回测").font(.system(size: 16, weight: .bold))
            Text("扫描已收盘 K 线；结果可逐条打开蜡烛图核验。").font(.system(size: 12)).foregroundStyle(WebTheme.muted)
          }
        }.padding(.bottom, 4)
        WebSelect(
          title: "策略版本", selection: $strategy,
          options: [("", "请选择")]
            + strategies.map { ($0.value("id"), $0.value("name") + " v" + $0.value("version")) })
        WebSelect(title: "币种", selection: $symbol, options: researchSymbols.map { ($0, $0) })
        WebSelect(title: "周期", selection: $timeframe, options: researchTimeframes)
        dateField("开始时间", $start)
        dateField("结束时间", $end)
        Button(busy ? "回测中..." : "开始回测") { run() }.buttonStyle(
          WebButtonStyle(radius: 14, fontSize: 14, fullWidth: false)
        ).disabled(busy || strategy.isEmpty || start >= end).frame(
          maxWidth: .infinity, alignment: .trailing
        ).padding(.top, 4)
        USDTNotice(text: notice)
      }.padding(20).overlay {
        RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1)
      }
      VStack(spacing: 0) {
        HStack {
          Text("命中信号").font(.system(size: 16, weight: .bold))
          Spacer()
          Text("\(result["results"]?.rows.count ?? 0) 条").font(.system(size: 14)).foregroundStyle(
            WebTheme.muted)
        }.padding(.horizontal, 20).padding(.vertical, 16)
        Rectangle().fill(WebTheme.border).frame(height: 1)
        if result["results"]?.rows.isEmpty != false {
          Text("选择区间并运行回测后，结果会出现在这里。").font(.system(size: 14)).foregroundStyle(WebTheme.muted)
            .frame(maxWidth: .infinity).padding(40)
        }
        ForEach(Array((result["results"]?.rows ?? []).enumerated()), id: \.offset) { _, row in
          VStack(alignment: .leading, spacing: 12) {
            Text(
              WebFormat.time(row.value("signal_time")) + " · " + row.value("symbol") + " · "
                + row.value("timeframe")
            ).font(.system(size: 14, weight: .semibold))
            WebBadge(
              text: row.value("direction") == "long" ? "做多" : "做空",
              color: row.value("direction") == "long" ? WebTheme.success : WebTheme.danger)
            Text(
              "SuperTrend 翻转 " + (row["features"]?.value("supertrend_flip") ?? "-") + " · EMA21 距离 "
                + (row["features"]?.value("close_to_ema21_atr") ?? "-") + " ATR"
            ).font(.system(size: 12)).foregroundStyle(WebTheme.muted)
            Button {
              chartSample = row
              showChart = true
            } label: {
              WebLabel("查看蜡烛图", "chart-candlestick")
            }.buttonStyle(
              WebButtonStyle(
                kind: .secondary, height: 34, radius: 10, fontSize: 12, fullWidth: false))
          }.padding(16)
          Rectangle().fill(WebTheme.border).frame(height: 1)
        }
      }.overlay { RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1) }
    }
  }
  private func dateField(_ title: String, _ selection: Binding<Date>) -> some View {
    WebDateField(title: title, selection: selection)
  }
  private func run() {
    busy = true
    Task {
      defer { busy = false }
      do {
        result = try await store.send(
          "/v1/signal-research/backtest",
          [
            "symbol": .string(symbol.uppercased()), "timeframe": .string(timeframe),
            "strategy_id": .string(strategy),
            "start_time": .string(ISO8601DateFormatter().string(from: start)),
            "end_time": .string(ISO8601DateFormatter().string(from: end)),
          ])
        notice = "回测完成"
      } catch { notice = error.localizedDescription }
    }
  }
}

private func researchTimeframe(_ value: String) -> String {
  researchTimeframes.first { $0.0 == value }?.1 ?? value
}

// The same curated symbol menu as the original Web research page.
private let researchSymbols = [
  "BTCUSDT",
  "ETHUSDT",
  "XAUUSDT",
  "BNBUSDT",
  "XRPUSDT",
  "SOLUSDT",
  "TRXUSDT",
  "DOGEUSDT",
  "HYPEUSDT",
  "ZECUSDT",
  "ADAUSDT",
  "BCHUSDT",
  "XMRUSDT",
  "LINKUSDT",
  "CCUSDT",
  "XLMUSDT",
  "TONUSDT",
  "SUIUSDT",
  "LTCUSDT",
  "AVAXUSDT",
  "HBARUSDT",
  "MUSDT",
  "1000SHIBUSDT",
  "NEARUSDT",
  "TAOUSDT",
  "UNIUSDT",
  "DOTUSDT",
  "ONDOUSDT",
  "WLFIUSDT",
  "ASTERUSDT",
  "SKYUSDT",
  "1000PEPEUSDT",
  "ICPUSDT",
  "ETCUSDT",
  "AAVEUSDT",
  "MORPHOUSDT",
  "QNTUSDT",
  "ATOMUSDT",
  "ALGOUSDT",
  "WLDUSDT",
  "RENDERUSDT",
  "POLUSDT",
  "KASUSDT",
  "ENAUSDT",
  "VVVUSDT",
  "JSTUSDT",
  "APTUSDT",
  "STABLEUSDT",
  "FILUSDT",
  "ARBUSDT",
  "JUPUSDT",
  "DEXEUSDT",
  "PUMPUSDT",
  "VETUSDT",
  "DASHUSDT",
  "PENGUUSDT",
  "NIGHTUSDT",
  "1000BONKUSDT",
  "INJUSDT",
  "TRUMPUSDT",
  "VIRTUALUSDT",
  "FETUSDT",
  "KITEUSDT",
  "CAKEUSDT",
  "EDGEUSDT",
  "1000LUNCUSDT",
  "STXUSDT",
  "SEIUSDT",
  "AEROUSDT",
  "TIAUSDT",
  "CHZUSDT",
  "SUNUSDT",
  "HUSDT",
  "2ZUSDT",
  "SIRENUSDT",
  "XTZUSDT",
  "BEATUSDT",
  "CRVUSDT",
  "UBUSDT",
  "LABUSDT",
  "SPXUSDT",
  "ZROUSDT",
  "PYTHUSDT",
  "SKYAIUSDT",
  "PENDLEUSDT",
  "KAIAUSDT",
  "LITUSDT",
  "MONUSDT",
  "BSVUSDT",
  "CFXUSDT",
  "LDOUSDT",
  "GRTUSDT",
  "1000FLOKIUSDT",
  "OPUSDT",
  "FRAXUSDT",
  "JASMYUSDT",
  "GRASSUSDT",
  "BSBUSDT",
  "BUSDT",
  "IOTAUSDT",
  "ENSUSDT",
  "STRKUSDT",
  "BILLUSDT",
  "GWEIUSDT",
  "JTOUSDT",
  "SYRUPUSDT",
  "AKTUSDT",
  "GENIUSUSDT",
  "XPLUSDT",
  "NEOUSDT",
  "FFUSDT",
  "AXSUSDT",
  "PIEVERSEUSDT",
  "THETAUSDT",
  "COMPUSDT",
  "WIFUSDT",
  "SANDUSDT",
  "TWTUSDT",
  "FARTCOINUSDT",
  "IPUSDT",
  "SUSDT",
  "MANAUSDT",
  "TAGUSDT",
  "CFGUSDT",
  "EIGENUSDT",
  "GALAUSDT",
  "RUNEUSDT",
  "CVXUSDT",
  "BATUSDT",
  "WALUSDT",
  "1000CHEEMSUSDT",
  "RAVEUSDT",
  "ZKUSDT",
  "1000XECUSDT",
  "IMXUSDT",
  "SFPUSDT",
  "GLMUSDT",
  "ARUSDT",
  "APEUSDT",
  "FLUIDUSDT",
  "AUSDT",
  "RIVERUSDT",
  "1INCHUSDT",
  "ATHUSDT",
  "DYDXUSDT",
  "EGLDUSDT",
  "KAITOUSDT",
  "SENTUSDT",
  "ESPORTSUSDT",
  "BANANAS31USDT",
  "SAFEUSDT",
  "SAHARAUSDT",
  "LPTUSDT",
  "ZENUSDT",
  "RSRUSDT",
  "SNXUSDT",
  "0GUSDT",
  "GASUSDT",
  "NXPCUSDT",
  "BERAUSDT",
  "QTUMUSDT",
  "CHIPUSDT",
  "BANUSDT",
  "LINEAUSDT",
  "KMNOUSDT",
  "AWEUSDT",
  "COWUSDT",
  "SKRUSDT",
  "MELANIAUSDT",
  "HOMEUSDT",
  "TRIAUSDT",
  "KSMUSDT",
  "MEGAUSDT",
  "ZRXUSDT",
  "ARKMUSDT",
  "RVNUSDT",
  "YFIUSDT",
  "ORCAUSDT",
  "FORMUSDT",
  "ORDIUSDT",
  "TACUSDT",
  "ENJUSDT",
  "DEEPUSDT",
  "ICNTUSDT",
  "DUSKUSDT",
  "TURBOUSDT",
  "ZILUSDT",
  "PLUMEUSDT",
  "SPKUSDT",
  "ROSEUSDT",
  "MINAUSDT",
  "ZETAUSDT",
  "CYSUSDT",
  "BIOUSDT",
  "WUSDT",
  "QUSDT",
  "BARDUSDT",
  "1MBABYDOGEUSDT",
  "GMXUSDT",
  "SUPERUSDT",
  "METUSDT",
]
