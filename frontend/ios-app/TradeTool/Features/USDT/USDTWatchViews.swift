import SwiftUI

struct USDTWatchPlansView: View {
  @EnvironmentObject private var store: USDTStore
  @StateObject private var model = USDTPageModel()
  @State private var type = "all"
  @State private var direction = "all"
  @State private var timeframe = "all"
  @State private var status = "all"
  @State private var review = "all"
  @State private var selected: JSONValue? = nil
  @State private var editor = false
  @State private var preflight = false
  @State private var preflightCompletedAt: Date?
  @Environment(\.scenePhase) private var scenePhase
  @State private var deleting = false
  @State private var pane = "plan"
  @State private var notice = ""
  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(WebTheme.muted)
            Text("记录").fontWeight(.semibold).padding(.trailing, 16)
            WebSelect(
              selection: $type, options: [("all", "左右侧单"), ("0", "计划左侧单"), ("1", "确认右侧单")],
              compact: true
            ).frame(width: 130)
            WebSelect(
              selection: $direction, options: [("all", "多空筛选"), ("0", "只看做多"), ("1", "只看做空")],
              compact: true
            ).frame(width: 120)
            WebSelect(
              selection: $timeframe, options: [("all", "周期筛选")] + watchTimeframes, compact: true
            ).frame(width: 120)
            WebSelect(
              selection: $status, options: [("all", "状态筛选"), ("1", "已做"), ("2", "未做")],
              compact: true
            ).frame(width: 120)
            WebSelect(
              selection: $review, options: [("all", "是否复盘"), ("yes", "已复盘"), ("no", "未复盘")],
              compact: true
            ).frame(width: 120)
            Text("\(filtered.count) 条").font(.system(size: 14)).foregroundStyle(WebTheme.muted)
              .padding(.horizontal, 12)
            Button("写计划") {
              selected = nil
              pane = "plan"
              editor = true
            }.buttonStyle(WebButtonStyle(height: 38, radius: 10, fontSize: 14, fullWidth: false))
          }.padding(.horizontal, 20).padding(.vertical, 16)
        }.scrollIndicators(.hidden)
        Rectangle().fill(WebTheme.border).frame(height: 1)
        ScrollView(.horizontal) {
          VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
              tableText("交易对", width: 120)
              tableText("周期/方向", width: 120)
              tableText("内容", width: 280)
              tableText("复盘", width: 220)
              tableText("类型/状态/结果", width: 220)
              tableText("操作/时间", width: 150)
            }.font(.system(size: 12, weight: .semibold)).foregroundStyle(WebTheme.muted).padding(
              .horizontal, 12
            ).padding(.vertical, 8)
            Rectangle().fill(WebTheme.border).frame(height: 1)
            if filtered.isEmpty {
              Text(model.loading ? "加载中…" : "暂无记录").font(.system(size: 14)).foregroundStyle(
                WebTheme.muted
              ).frame(maxWidth: .infinity).padding(.vertical, 40)
            }
            ForEach(Array(filtered.enumerated()), id: \.offset) { _, row in
              tableRow(row)
              Rectangle().fill(WebTheme.border).frame(height: 1)
            }
          }.frame(width: 1274)
        }.padding(20)
        USDTNotice(text: model.error.isEmpty ? notice : model.error).padding(.horizontal, 20)
      }.background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 16)).overlay {
        RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1)
      }.padding(16)
    }.scrollIndicators(.hidden).usdtPage("看盘计划", refresh: { Task { await load() } }).task(
      id: store.scope
    ) {
      await load()
      await checkPreflight()
    }.refreshable { await load() }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { Task { await checkPreflight() } }
      }
      .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
        if let completedAt = preflightCompletedAt, now.timeIntervalSince(completedAt) >= 3 * 3600 {
          preflight = true
        }
      }
      .webModal(isPresented: $preflight) {
        USDTPreflightView {
          preflightCompletedAt = .now
          preflight = false
        }.environmentObject(store).interactiveDismissDisabled()
      }
      .webModal(isPresented: $editor) {
        USDTWatchEditor(plan: selected, pane: pane).environmentObject(store)
      }.onChange(of: editor) { _, shown in if !shown { Task { await load() } } }
      .webModal(isPresented: $deleting) {
        WebModal(title: "确认删除") {
          Text("确定删除这条记录？").foregroundStyle(WebTheme.secondary)
          HStack(spacing: 12) {
            Button("取消") { deleting = false }.buttonStyle(
              WebButtonStyle(kind: .secondary, radius: 14))
            Button("删除") {
              deleting = false
              Task {
                do {
                  _ = try await store.send(
                    "/v1/watch-plan/delete", ["id": selected?["id"] ?? .null])
                  await load()
                } catch { notice = error.localizedDescription }
              }
            }.buttonStyle(WebButtonStyle(kind: .danger, radius: 14))
          }
        }
      }
  }
  private func checkPreflight() async {
    do {
      let value = try await store.get("/v1/auth/preflight-status")
      let date = WebFormat.date(value.value("preflight_completed_at"))
      preflightCompletedAt = date
      preflight = date == nil || Date().timeIntervalSince(date!) >= 3 * 3600
    } catch { notice = error.localizedDescription }
  }
  private var filtered: [JSONValue] {
    model.items.filter { row in
      (type == "all" || row.value("plan_type") == type)
        && (direction == "all" || row.value("direction") == direction)
        && (timeframe == "all" || row.value("timeframe") == timeframe)
        && (status == "all"
          || (status == "2" ? row.value("status") != "1" : row.value("status") == "1"))
        && (review == "all"
          || (review == "yes"
            ? !row.value("review_content", fallback: "").isEmpty
            : row.value("review_content", fallback: "").isEmpty))
    }
  }
  private func tableText(_ text: String, width: CGFloat) -> some View {
    Text(text).frame(width: width, alignment: .leading)
  }
  private func tableRow(_ row: JSONValue) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Button(row.value("symbol")) {
        selected = row
        pane = "plan"
        editor = true
      }.font(.system(size: 16, weight: .semibold)).underline().frame(
        width: 120, alignment: .leading)
      WebBadge(
        text: "\(row.value("timeframe"))/\(row.value("direction") == "0" ? "多" : "空")",
        color: row.value("direction") == "0" ? WebTheme.success : WebTheme.danger
      ).frame(width: 120, alignment: .leading)
      VStack(alignment: .leading, spacing: 8) {
        noteBox("指标和入场理由 " + row.value("content", fallback: "未填写"), color: WebTheme.success)
        noteBox(
          "止盈预期 " + row.value("take_profit_expectation", fallback: "未填写"), color: WebTheme.success)
      }.frame(width: 280)
      Button {
        selected = row
        pane = "review"
        editor = true
      } label: {
        noteBox(row.value("review_content", fallback: "未填写") + "  ✎", color: .blue)
      }.frame(width: 220)
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          WebBadge(text: row.value("plan_type") == "1" ? "确认右侧单" : "计划左侧单", color: .purple)
          WebBadge(text: row.value("status") == "1" ? "已做" : "未做", color: WebTheme.muted)
        }
        Button {
          selected = row
          pane = "result"
          editor = true
        } label: {
          Text(
            row.value("result") == "0"
              ? "止盈止损"
              : (row.value("result") == "1" ? "止损：-" : "止盈：+") + row.value("result_amount") + "U"
          ).font(.system(size: 14, weight: .semibold)).foregroundStyle(
            row.value("result") == "1"
              ? WebTheme.danger : row.value("result") == "2" ? WebTheme.success : WebTheme.muted)
        }
      }.frame(width: 220, alignment: .leading)
      VStack(alignment: .trailing, spacing: 8) {
        HStack(spacing: 8) {
          Button {
            Task {
              do {
                _ = try await store.send(
                  "/v1/watch-plan/update",
                  ["id": row["id"] ?? .null, "status": .number(row.value("status") == "1" ? 2 : 1)])
                await load()
              } catch { notice = error.localizedDescription }
            }
          } label: {
            Image(systemName: "checkmark")
          }
          Button {
            selected = row
            pane = "plan"
            editor = true
          } label: {
            Image(systemName: "pencil")
          }
          Button {
            selected = row
            deleting = true
          } label: {
            Image(systemName: "trash").foregroundStyle(WebTheme.danger)
          }
        }.buttonStyle(
          WebButtonStyle(kind: .secondary, height: 36, radius: 10, fontSize: 14, fullWidth: false))
        Button {
          selected = row
          pane = "score"
          editor = true
        } label: {
          Text(row["score"] == nil || row["score"] == .null ? "未评分" : row.value("score") + "分")
            .font(.system(size: 14, weight: .bold)).frame(maxWidth: .infinity).padding(10)
            .background(WebTheme.input, in: RoundedRectangle(cornerRadius: 14))
        }
        Text(WebFormat.time(row.value("created_at"))).font(.system(size: 12)).foregroundStyle(
          WebTheme.muted)
      }.frame(width: 150)
    }.font(.system(size: 14)).padding(12)
  }
  private func noteBox(_ text: String, color: Color) -> some View {
    Text(text).font(.system(size: 14)).foregroundStyle(color).frame(
      maxWidth: .infinity, alignment: .leading
    ).padding(.horizontal, 12).padding(.vertical, 8).background(
      color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
  }
  private func load() async { await model.load(store, path: "/v1/watch-plan/list") }
}

private let watchTimeframes = [("15m", "15分钟"), ("1h", "1小时"), ("4h", "4小时"), ("1d", "1天")]

struct USDTWatchEditor: View {
  @EnvironmentObject private var store: USDTStore
  @Environment(\.dismiss) private var dismiss
  let plan: JSONValue?
  var pane = "plan"
  @State private var symbol = ""
  @State private var symbols: [String] = []
  @State private var symbolSearch = ""
  @State private var showSymbols = false
  @State private var saving = false
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
  @State private var scoreChecks: Set<String> = []
  @State private var scoreVetoes: Set<String> = []
  @State private var notice = ""
  @State private var deleting = false
  var body: some View {
    WatchPanelModal(
      title: pane == "score"
        ? "评分" : pane == "review" ? "复盘" : pane == "result" ? "止盈止损" : plan == nil ? "写计划" : "编辑计划",
      subtitle: pane == "plan" ? plan.map { "#" + $0.value("id") } ?? "" : symbol,
      maximumWidth: pane == "plan" ? 1024 : pane == "score" ? 896 : pane == "review" ? 672 : 448,
      pinnedHeader: pane == "score"
        ? AnyView(scoreSummary.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16))
        : nil,
      pinnedFooter: pane == "score"
        ? AnyView(editorFooter.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20))
        : nil
    ) {
      VStack(alignment: .leading, spacing: 16) {
        if pane == "plan" {
          WebWatchHeaderGrid {
            VStack(alignment: .leading, spacing: 8) {
              watchCaption("交易对")
              Button {
                showSymbols = true
              } label: {
                HStack(spacing: 4) {
                  Text(symbol.isEmpty ? "点击选择/搜索" : symbol).font(
                    .system(size: 16, weight: symbol.isEmpty ? .regular : .semibold)
                  ).fixedSize(horizontal: false, vertical: true)
                  if !symbol.isEmpty { WebIcon("chevron-down", size: 16) }
                }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity)
                  .background(WebTheme.page, in: RoundedRectangle(cornerRadius: 14)).overlay {
                    RoundedRectangle(cornerRadius: 14).stroke(WebTheme.border, lineWidth: 1)
                  }
              }
            }
            VStack(alignment: .leading, spacing: 8) {
              watchCaption("类型")
              watchSegment(
                [
                  (0, "计划左侧单", Color(red: 109 / 255, green: 60 / 255, blue: 229 / 255)),
                  (1, "确认右侧单", Color(red: 199 / 255, green: 101 / 255, blue: 0)),
                ], selection: $planType
              ).fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
              watchCaption("周期")
              WebSelect(selection: $timeframe, options: watchTimeframes, compact: true)
            }
            VStack(alignment: .leading, spacing: 8) {
              watchCaption("方向")
              watchSegment(
                [(0, "多", WebTheme.success), (1, "空", WebTheme.danger)], selection: $direction
              ).fixedSize()
            }
            WebDateField(title: "日期", selection: $date, includesTime: false)
          }
          VStack(alignment: .leading, spacing: 12) {
            watchCaption("内容")
            WebTextArea(
              title: "指标和入场理由", text: $content, placeholder: "写下你看到的结构、指标、关键位置和入场逻辑…", height: 90,
              labelSize: 12, labelWeight: .semibold, fill: WebTheme.page, horizontalPadding: 12,
              verticalPadding: 8)
            WebTextArea(
              title: "止盈预期", text: $expectation, placeholder: "写下止盈路径、目标区间或离场预期…", height: 66,
              labelSize: 12, labelWeight: .semibold, fill: WebTheme.page, horizontalPadding: 12,
              verticalPadding: 8)
          }
        } else if pane == "review" {
          WebTextArea(
            text: $review, placeholder: "填写复盘内容…", height: 186, fill: WebTheme.page,
            horizontalPadding: 12, verticalPadding: 8)
        } else if pane == "result" {
          watchSegment(
            [(2, "止盈", WebTheme.success), (1, "止损", WebTheme.danger)], selection: $result)
          USDTField(title: "止盈止损金额", text: $amount, numeric: true, placeholder: "输入金额", radius: 14)
        } else {
          ForEach(scoreSections, id: \.title) { section in
            VStack(alignment: .leading, spacing: 8) {
              Text(section.title).font(.system(size: 14, weight: .bold)).padding(.bottom, 4)
              ForEach(section.items, id: \.key) { item in scoreChoice(item, veto: false) }
            }.padding(16).background(WebTheme.page, in: RoundedRectangle(cornerRadius: 16)).overlay
            { RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1) }
          }
          VStack(alignment: .leading, spacing: 8) {
            Text("否决项").font(.system(size: 14, weight: .bold)).foregroundStyle(WebTheme.danger)
              .padding(.bottom, 4)
            ForEach(WatchScoreSection.vetoes, id: \.key) { scoreChoice($0, veto: true) }
          }.padding(16).background(
            WebTheme.danger.opacity(0.06), in: RoundedRectangle(cornerRadius: 16)
          ).overlay {
            RoundedRectangle(cornerRadius: 16).stroke(WebTheme.danger.opacity(0.2), lineWidth: 1)
          }
        }
        USDTNotice(text: notice)
        if pane != "score" { editorFooter }
      }.padding(20)
    }.onAppear {
      configurePlan()
    }
    .task { symbols = (try? await store.get("/v1/trade/symbols").rows.map(\.text)) ?? [] }
    .webModal(isPresented: $showSymbols) {
      symbolPicker
    }
  }
  private var editorFooter: some View {
    HStack(spacing: 8) {
      if ["review", "result"].contains(pane) {
        Spacer()
        Button("取消") { dismiss() }.buttonStyle(
          WebButtonStyle(
            kind: .secondary, height: 40, radius: 14, fullWidth: false, weight: .bold))
      }
      Button(
        saving ? "保存中..." : pane == "review" || (pane == "plan" && plan != nil) ? "保存" : "确定"
      ) { save() }.buttonStyle(
        WebButtonStyle(
          height: pane == "plan" || pane == "score" ? 48 : 40, radius: 14,
          fullWidth: pane == "plan" || pane == "score", weight: .bold)
      ).disabled(saving)
    }
  }
  private func configurePlan() {
    guard let plan else { return }
    symbol = plan.value("symbol")
    timeframe = plan.value("timeframe")
    planType = Int(plan.value("plan_type")) ?? 0
    direction = Int(plan.value("direction")) ?? 0
    content = plan.value("content", fallback: "")
    expectation = plan.value("take_profit_expectation", fallback: "")
    review = plan.value("review_content", fallback: "")
    status = Int(plan.value("status")) ?? 0
    result = Int(plan.value("result")) ?? 0
    amount = plan.value("result_amount", fallback: "")
    scoreChecks = Set((plan["score_payload"]?["checks"]?.rows ?? []).map(\.text))
    scoreVetoes = Set((plan["score_payload"]?["vetoes"]?.rows ?? []).map(\.text))
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    date = formatter.date(from: plan.value("plan_date")) ?? .now
  }
  private var symbolPicker: some View {
    WatchPanelModal(title: "选择交易对", maximumWidth: 672) {
      VStack(spacing: 12) {
        USDTField(title: "", text: $symbolSearch, placeholder: "搜索交易对…")
        ForEach(
          symbols.filter {
            symbolSearch.isEmpty || $0.localizedCaseInsensitiveContains(symbolSearch)
          }, id: \.self
        ) { pair in
          Button(pair) {
            symbol = pair
            showSymbols = false
          }.font(.system(size: 14, weight: .semibold)).frame(
            maxWidth: .infinity, alignment: .leading
          ).padding(12)
        }
      }.padding(20)
    }
  }
  private func watchCaption(_ title: String) -> some View {
    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(WebTheme.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
  private func watchSegment(_ items: [(Int, String, Color)], selection: Binding<Int>) -> some View {
    HStack(spacing: 0) {
      ForEach(items, id: \.0) { key, title, color in
        Button(title) { selection.wrappedValue = key }.font(.system(size: 14, weight: .semibold))
          .fixedSize().padding(.horizontal, 16).padding(.vertical, 8).foregroundStyle(
            selection.wrappedValue == key ? color : WebTheme.text
          ).background(selection.wrappedValue == key ? color.opacity(0.15) : .clear)
      }
    }.background(WebTheme.page, in: RoundedRectangle(cornerRadius: 14)).clipShape(
      RoundedRectangle(cornerRadius: 14)
    ).overlay { RoundedRectangle(cornerRadius: 14).stroke(WebTheme.border, lineWidth: 1) }
  }
  private var scoreSummary: some View {
    let total = calculatedScore
    let color =
      !scoreVetoes.isEmpty || total < 80
      ? WebTheme.danger : total >= 90 ? WebTheme.success : WebTheme.brand
    return VStack(alignment: .leading, spacing: 8) {
      Text(planType == 1 ? "确认右侧单评分" : "计划左侧单评分").font(.system(size: 14, weight: .semibold))
      Text("\(total)分").font(.system(size: 36, weight: .black))
      Text(!scoreVetoes.isEmpty ? "已触发否决项" : total >= 90 ? "S级" : total >= 80 ? "A级" : "观察").font(
        .system(size: 14, weight: .bold))
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        ForEach(scoreSections, id: \.title) { section in
          VStack(spacing: 8) {
            Text(
              "\(section.items.reduce(0) { $0 + (scoreChecks.contains($1.key) ? $1.points : 0) })分"
            ).font(.system(size: 24, weight: .black))
            Text(section.title.components(separatedBy: "（")[0]).font(
              .system(size: 12, weight: .semibold))
          }.frame(maxWidth: .infinity).padding(12).background(
            .white.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(color).padding(
      .horizontal, 20
    ).padding(.vertical, 16).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
      .overlay { RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.25), lineWidth: 1) }
  }
  private func scoreChoice(_ item: WatchScoreSection.Item, veto: Bool) -> some View {
    let binding = scoreBinding(item.key, veto: veto)
    let color = veto ? WebTheme.danger : WebTheme.brand
    return Button {
      binding.wrappedValue.toggle()
    } label: {
      (Text(item.label).font(.system(size: 14, weight: .medium))
        + Text(veto ? "" : "  \(item.points)分").font(.system(size: 12, weight: .bold))
        .foregroundColor(color)).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(
          binding.wrappedValue ? color.opacity(0.12) : .white,
          in: RoundedRectangle(cornerRadius: 14)
        ).overlay {
          RoundedRectangle(cornerRadius: 14).stroke(
            binding.wrappedValue ? color.opacity(0.3) : WebTheme.border, lineWidth: 1)
        }
    }.foregroundStyle(veto && binding.wrappedValue ? WebTheme.danger : WebTheme.text)
  }
  private var scoreSections: [WatchScoreSection] {
    WatchScoreSection.sections(right: planType == 1)
  }
  private var calculatedScore: Int {
    scoreSections.flatMap(\.items).reduce(0) { $0 + (scoreChecks.contains($1.key) ? $1.points : 0) }
  }
  private func scoreBinding(_ key: String, veto: Bool) -> Binding<Bool> {
    Binding(
      get: { veto ? scoreVetoes.contains(key) : scoreChecks.contains(key) },
      set: { enabled in
        if veto {
          if enabled { scoreVetoes.insert(key) } else { scoreVetoes.remove(key) }
        } else {
          if enabled { scoreChecks.insert(key) } else { scoreChecks.remove(key) }
        }
      })
  }
  private func save() {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    var payload: [String: JSONValue] = [
      "symbol": .string(symbol.uppercased()), "plan_date": .string(formatter.string(from: date)),
      "plan_type": .number(Double(planType)), "timeframe": .string(timeframe),
      "direction": .number(Double(direction)), "content": .string(content),
      "take_profit_expectation": .string(expectation),
    ]
    guard !saving else { return }
    if pane == "plan" && symbol.trimmingCharacters(in: .whitespaces).isEmpty {
      notice = "交易对不能为空"
      return
    }
    if pane == "result" && ((Decimal(string: amount) ?? -1) < 0 || result == 0) {
      notice = "请选择止盈或止损，并输入有效金额"
      return
    }
    if let plan { payload["id"] = plan["id"] }
    if pane == "review" {
      payload = ["id": plan?["id"] ?? .null, "review_content": .string(review)]
    }
    if pane == "result" {
      payload = [
        "id": plan?["id"] ?? .null, "result": .number(Double(result)),
        "result_amount": .string(amount),
      ]
    }
    if pane == "score" {
      payload = [
        "id": plan?["id"] ?? .null, "score": .number(Double(calculatedScore)),
        "score_payload": .object([
          "checks": .array(scoreChecks.sorted().map { .string($0) }),
          "vetoes": .array(scoreVetoes.sorted().map { .string($0) }),
        ]),
      ]
    }
    saving = true
    Task {
      defer { saving = false }
      do {
        _ = try await store.send(
          plan == nil ? "/v1/watch-plan/create" : "/v1/watch-plan/update", payload)
        dismiss()
      } catch { notice = error.localizedDescription }
    }
  }
}

private struct WatchScoreSection {
  struct Item {
    let key: String
    let label: String
    let points: Int
  }
  let title: String
  let items: [Item]
  static let section0 = WatchScoreSection(
    title: "趋势背景（20分）",
    items: [
      Item(key: "trend-direction", label: "大周期方向明确，1D / 4H 与交易方向一致", points: 10),
      Item(key: "trend-ema-order", label: "EMA21 / 55 / 144 顺向排列", points: 5),
      Item(key: "trend-not-chasing", label: "均线发散不极端，价格不是远离均线后追入", points: 5),
    ])
  static let section1 = WatchScoreSection(
    title: "位置质量（25分）",
    items: [
      Item(key: "position-structure", label: "价格处在关键支撑/压力/前高前低/结构位", points: 10),
      Item(key: "position-ema144", label: "回踩到 EMA144 或核心均线区域", points: 7),
      Item(key: "position-fib", label: "Fib 0.618 / 0.786 与 EMA144 / 结构位重合", points: 5),
      Item(key: "position-not-middle", label: "不是震荡区中间，不是无意义位置", points: 3),
    ])
  static let section2 = WatchScoreSection(
    title: "入场触发（20分）",
    items: [
      Item(key: "entry-right-reversal", label: "已出现明确反转 K 线", points: 8),
      Item(key: "entry-right-zone", label: "反转 K 线位置正好在关键区域", points: 5),
      Item(key: "entry-right-stop-clear", label: "反转 K 线止损点清晰", points: 4),
      Item(key: "entry-right-r-space", label: "入场后仍有足够 R 值空间", points: 3),
    ])
  static let section3 = WatchScoreSection(
    title: "入场触发（20分）",
    items: [
      Item(key: "entry-left-planned", label: "是提前计划好的左侧关键位，不是临场接刀", points: 7),
      Item(key: "entry-left-confluence", label: "EMA144 + Fib / 结构位强共振", points: 6),
      Item(key: "entry-left-stop-clear", label: "止损放在明确失效位，比如 Fib 1 / 结构破位", points: 4),
      Item(key: "entry-left-risk-limited", label: "左侧只占部分风险，或总风险被程序严格限制", points: 3),
    ])
  static let section4 = WatchScoreSection(
    title: "风险收益结构（20分）",
    items: [
      Item(key: "risk-stop-clear", label: "止损位置明确，不需要临场调整", points: 5),
      Item(key: "risk-two-r", label: "到前高/前低至少 ≥ 2R", points: 6),
      Item(key: "risk-three-five-r", label: "有可能走到 3R - 5R，适合趋势仓", points: 4),
      Item(key: "risk-fixed-amount", label: "单笔风险金额固定，不因信心提高", points: 3),
      Item(key: "risk-auto-tp", label: "交易后能自动执行 30-20-50 止盈", points: 2),
    ])
  static let section5 = WatchScoreSection(
    title: "清晰度 / 心理状态（15分）",
    items: [
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
  static func sections(right: Bool) -> [WatchScoreSection] {
    [section0, section1, right ? section2 : section3, section4, section5]
  }
}

struct USDTPreflightView: View {
  @EnvironmentObject private var store: USDTStore
  let completed: () -> Void
  @State private var questions = PreflightQuestion.build()
  @State private var index = 0
  @State private var answer = ""
  @State private var busy = false
  @State private var notice = ""
  private var current: PreflightQuestion { questions[index] }
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.65).ignoresSafeArea()
        VStack(spacing: 0) {
          HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
              Text("交易前校准").font(.system(size: 24, weight: .bold))
              Text("在进入系统前，先把注意力拉回到交易原则。当前题答对后，才能继续下一题。").font(.system(size: 14)).lineSpacing(6)
                .foregroundStyle(WebTheme.secondary)
            }
            Text("第\(index + 1)/\(questions.count)题").font(.system(size: 14, weight: .bold))
              .foregroundStyle(WebTheme.brand).fixedSize().padding(.horizontal, 16).padding(
                .vertical, 8
              ).background(WebTheme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
          }.padding(.horizontal, 24).padding(.vertical, 20)
          Rectangle().fill(WebTheme.border).frame(height: 1)
          ScrollView {
            VStack(alignment: .leading, spacing: 20) {
              Text(
                current.prompt.replacingOccurrences(
                  of: #"^\d+、"#, with: "", options: .regularExpression)
              ).font(.system(size: 18, weight: .semibold)).lineSpacing(8)
              VStack(spacing: 12) {
                ForEach(current.options, id: \.self) { option in
                  Button {
                    answer = option
                  } label: {
                    Text(option).font(.system(size: 14)).lineSpacing(6).frame(
                      maxWidth: .infinity, alignment: .leading
                    ).padding(.horizontal, 16).padding(.vertical, 12).background(
                      answer == option
                        ? (option == current.correct ? WebTheme.success : WebTheme.danger).opacity(
                          0.1) : WebTheme.surface, in: RoundedRectangle(cornerRadius: 16)
                    ).overlay {
                      RoundedRectangle(cornerRadius: 16).stroke(
                        answer == option
                          ? (option == current.correct ? WebTheme.success : WebTheme.danger)
                          : WebTheme.border, lineWidth: 1)
                    }
                  }.buttonStyle(.plain)
                }
              }
              if !answer.isEmpty && answer != current.correct {
                Text("这不是系统答案，请重新选择。").font(.system(size: 14, weight: .medium)).foregroundStyle(
                  WebTheme.danger)
              }
              USDTNotice(text: notice)
            }.padding(20).background(WebTheme.page, in: RoundedRectangle(cornerRadius: 16)).overlay
            { RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1) }.padding(24)
          }.frame(maxHeight: max(180, geometry.size.height - 270)).scrollIndicators(.hidden)
          Rectangle().fill(WebTheme.border).frame(height: 1)
          HStack(spacing: 16) {
            Button("重新出题") {
              questions = PreflightQuestion.build()
              index = 0
              answer = ""
            }.buttonStyle(
              WebButtonStyle(kind: .secondary, height: 40, radius: 14, fullWidth: false))
            Spacer(minLength: 0)
            Button(busy ? "提交中..." : index == questions.count - 1 ? "完成" : "下一题") { next() }
              .buttonStyle(WebButtonStyle(height: 44, radius: 14, fullWidth: false)).disabled(
                answer != current.correct || busy)
          }.padding(.horizontal, 24).padding(.vertical, 20)
        }.foregroundStyle(WebTheme.text).frame(maxWidth: 768).background(
          WebTheme.surface, in: RoundedRectangle(cornerRadius: 24)
        ).overlay { RoundedRectangle(cornerRadius: 24).stroke(WebTheme.border, lineWidth: 1) }
          .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.presentationBackground(.clear)
  }
  private func next() {
    guard answer == current.correct else { return }
    if index < questions.count - 1 {
      index += 1
      answer = ""
      return
    }
    busy = true
    Task {
      defer { busy = false }
      do {
        _ = try await store.send("/v1/auth/preflight-complete")
        completed()
      } catch { notice = error.localizedDescription }
    }
  }
}

private struct PreflightQuestion {
  let prompt: String
  let correct: String
  let options: [String]
  static func build() -> [PreflightQuestion] {
    bank.shuffled().map { prompt, correct, distractors in
      PreflightQuestion(
        prompt: prompt, correct: correct,
        options: ([correct] + Array(distractors.shuffled().prefix(4))).shuffled())
    }
  }
  private static let bank: [(String, String, [String])] = [
    (
      "1、进入一笔交易时，最优先考虑的应该是什么？", "价格所处的位置是最优先考虑的点，优先找关键位置，而不是反转 K 线或者其他指标",
      [
        "只要出现 Pin Bar / 吞没形态，就可以优先考虑进场", "RSI 超卖超买比价格位置更重要", "MACD 背离出现时，可以忽略位置直接尝试",
        "指标共振越多，位置的重要性越低",
      ]
    ),
    (
      "2、系统内理想的入场点，应该尽量靠近哪里？", "入场点尽可能靠近 EMA144",
      ["只要方向正确，距离 EMA 多远都可以追", "行情启动后第一时间追进去最重要", "怕错过行情时可以放宽 EMA 距离", "趋势行情不需要等回踩"]
    ),
    (
      "3、关于入场确认，哪一项更符合你的交易原则？", "等待形成反转 K 线以后入场，按照反转 K 线定点止损，其盈亏比比盲入更稳，盈亏比更优",
      ["预判永远比确认更赚钱", "提前进场可以拿到最低点", "不需要等 K 线确认，感觉到了就可以先进", "真正的高手都是提前埋伏"]
    ),
    (
      "4、周期之间的观察顺序，正确的是哪一项？", "优先看大周期，根据大周期再依次缩小周期去找入场点",
      ["小周期信号最灵敏，优先级最高", "1 分钟周期能最快发现机会", "只做超短线时，大周期可以忽略", "先找进场点，再看大周期方向"]
    ),
    (
      "5、连续亏损后的正确处理方式是什么？", "连续亏损后应降低频率，而不是急于翻本",
      ["连亏后下一单应该加仓翻回来", "状态不好时更应该频繁交易找感觉", "亏损后立即重仓是恢复信心最快的方法", "连亏说明快轮到自己赚钱了"]
    ),
    (
      "6、没有符合系统的机会时，正确选择是什么？", "没有机会时候，应该空仓等待，去复盘过往记录，去完善过程控制系统",
      [
        "没机会时可以轻仓试错找感觉", "长时间空仓容易错过突然启动的行情", "没有标准机会时，可以降低条件做单", "盘感好的时候不一定非要等系统信号",
        "做交易最重要的是保持市场参与感", "行情少的时候应该增加观察周期去寻找机会", "只要控制仓位，随便做一点问题不大", "没机会时可以做自己“感觉最强”的品种",
        "等机会太被动，主动试单更容易抓节奏", "市场每天都有机会，只是有没有发现", "复盘不如实战，真正的经验来自做单", "空仓太久会导致执行力下降", "横盘行情更适合高频试单",
        "小止损多尝试，总能抓到一次趋势", "交易员应该持续保持出手状态", "看得越久，机会自然会出现", "没有明显机会时，可以通过加杠杆提高收益效率",
        "与其空仓，不如小仓位保持市场温度", "没有机会时应该多开图、多找形态", "真正的高手会在别人看不懂的时候提前布局",
      ]
    ),
    (
      "7、关于错过与追单，哪一项更符合你的系统？", "错过行情比做错行情更容易接受",
      ["错过比亏损更难受，所以应该追", "行情已经启动更说明方向正确", "强势行情不能等回踩", "不敢追说明执行力差"]
    ),
    (
      "8、面对不够确定的入场机会时，正确态度是什么？", "宁可不做，等待确定时机，而不是着急入场亏掉本金，等待并不会让你损失，越急越亏",
      [
        "先上车再观察，机会往往稍纵即逝", "犹豫太久会错过最佳利润", "提前试仓比完全错过更重要", "行情启动后确认就已经太晚了", "做交易最怕没有参与感",
        "等待会降低交易节奏和盘感", "越早入场，利润空间越大", "真正的大行情往往不给确认机会", "小仓位提前埋伏风险并不大", "慢一步就意味着盈亏比变差",
        "市场不会等人，必须主动出击", "先试错，再根据走势调整", "机会是抢出来的，不是等出来的", "趋势初期应该大胆预判", "害怕入场本质上是不够自信",
        "确认太多会错过最肥的一段行情",
      ]
    ),
    (
      "9、机会质量和仓位之间，哪种理解更符合你的系统？", "确定的机会搭配合理的仓位，比模糊的机会试图用小仓位赚取利润更重要",
      [
        "只要仓位小，任何位置都可以尝试", "小仓位试错没有成本", "高频小仓位更容易抓住行情", "模糊机会也可能变成大行情", "做得多总会遇到正确行情",
        "小仓位可以忽略系统要求", "机会不明确时更应该提前布局", "用轻仓不断试单才容易抓启动点", "仓位比机会质量更重要", "盈利主要靠次数堆积",
        "小亏多次无所谓，抓一次就够", "看不懂的时候轻仓试最合理", "不敢试错会错过很多行情", "模糊机会可以通过加仓弥补", "轻仓交易不需要太严格",
        "高手都是不断试单试出来的", "小止损高频试错是最高效的方法", "仓位小的时候可以适当放宽标准",
      ]
    ),
    (
      "10、对于需要你反复分析、越看越纠结的机会，哪种判断更符合你的系统？", "如果不是一眼就能看出来的机会，需要反复分析的，不是机会而是陷阱",
      [
        "深度分析越久，胜率越高", "真正的大机会往往隐藏很深", "复杂行情更适合高手发挥", "需要推演的机会利润空间更大", "越难看懂的走势越值得研究",
        "只要逻辑能自洽，就可以做", "多找几个理由支持就能提高胜率", "看不懂的时候应该继续盯盘等待感觉", "复杂结构往往意味着大行情", "反复分析说明自己足够认真",
        "好机会通常需要耐心挖掘", "越多人看不懂，越可能是机会", "交易需要不断推演各种可能性", "机会本来就需要花时间确认", "一眼看懂的行情通常已经晚了",
        "越复杂的走势越容易产生超额利润", "怀疑自己时更应该加强分析", "只要盈亏比合适，模糊机会也值得做",
      ]
    ),
  ]
}

/// Preserve the source's twelve-column plan header, including its narrow-screen column widths.
private struct WebWatchHeaderGrid: Layout {
  private let weights: [CGFloat] = [2, 3, 2, 2, 3]
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 984
    let unit = max(0, (width - 176) / 12)
    let height =
      subviews.enumerated().map { index, view in
        view.sizeThatFits(
          ProposedViewSize(width: unit * weights[index] + 16 * (weights[index] - 1), height: nil)
        ).height
      }.max() ?? 0
    return CGSize(width: width, height: height)
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let unit = max(0, (bounds.width - 176) / 12)
    var x = bounds.minX
    for (index, view) in subviews.enumerated() {
      let width = unit * weights[index] + 16 * (weights[index] - 1)
      view.place(
        at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
        proposal: ProposedViewSize(width: width, height: nil))
      x += width + 16
    }
  }
}

private struct WatchPanelModal<Content: View>: View {
  let title: String
  var subtitle = ""
  var maximumWidth: CGFloat = 1024
  var pinnedHeader: AnyView? = nil
  var pinnedFooter: AnyView? = nil
  @ViewBuilder var content: Content
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { dismiss() }
        ViewThatFits(in: .vertical) {
          if pinnedHeader == nil && pinnedFooter == nil {
            panel(scrollable: false).fixedSize(horizontal: false, vertical: true)
          }
          panel(scrollable: true)
        }.frame(maxWidth: maximumWidth).background(
          WebTheme.surface, in: RoundedRectangle(cornerRadius: 16)
        ).clipShape(RoundedRectangle(cornerRadius: 16)).overlay {
          RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1)
        }.frame(maxHeight: geometry.size.height * 0.85).padding(16)
      }
    }.font(.system(size: 16)).foregroundStyle(WebTheme.text).buttonStyle(.plain)
      .presentationBackground(.clear)
  }
  private func panel(scrollable: Bool) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(title).font(.system(size: 16, weight: .bold))
        if !subtitle.isEmpty {
          Text(subtitle).font(.system(size: 14)).foregroundStyle(WebTheme.muted)
        }
        Spacer()
        Button {
          dismiss()
        } label: {
          WebIcon("x", size: 18).padding(8).contentShape(Rectangle())
        }.accessibilityLabel("关闭")
      }.padding(.horizontal, 20).padding(.vertical, 16).fixedSize(horizontal: false, vertical: true)
      Rectangle().fill(WebTheme.border).frame(height: 1)
      if let pinnedHeader {
        pinnedHeader.fixedSize(horizontal: false, vertical: true)
        Rectangle().fill(WebTheme.border).frame(height: 1)
      }
      if scrollable {
        ScrollView { content }.scrollIndicators(.hidden)
      } else {
        content
      }
      if let pinnedFooter {
        Rectangle().fill(WebTheme.border).frame(height: 1)
        pinnedFooter.fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
