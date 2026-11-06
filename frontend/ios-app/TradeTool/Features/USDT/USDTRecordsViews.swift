import SwiftUI

struct USDTSignalsView: View {
  var isVisible = true
  @EnvironmentObject private var store: USDTStore
  @StateObject private var model = USDTPageModel()
  @State private var rules = false
  @State private var modelScope = ""
  @State private var nextRefreshAt = Date.distantPast
  @Environment(\.scenePhase) private var scenePhase
  let openChart: (String, String) -> Void
  var body: some View {
    VStack(spacing: 0) {
      WebPageHeader("信号", back: false, centered: true, height: WebTheme.rootHeaderHeight, trailing: {
        Button {
          rules = true
        } label: {
          Color.clear.frame(width: 44, height: 44).overlay {
            WebIcon("info.circle", size: 18).foregroundStyle(WebTheme.muted)
          }.contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.trailing, 8).zIndex(1).accessibilityLabel("内部信号规则")
      }).accessibilityElement(children: .contain).accessibilityIdentifier("signals.header")
      WebRefreshScrollView(isActive: isVisible && scenePhase == .active) {
        VStack(spacing: 10) {
          ForEach(model.items, id: \.signalIdentity) { row in
            Button {
              openChart(row.value("symbol"), row.value("interval"))
            } label: {
              signalCard(row)
            }.buttonStyle(.plain).accessibilityIdentifier("signals.card.\(row.signalIdentity)")
          }
          if model.items.isEmpty {
            Text(
              model.loading
                ? "加载中..."
                : store.mode != "ordinary" ? "带单模式暂不支持信号"
                : model.error.isEmpty ? "暂无内部信号" : model.error
            ).font(.system(size: 14)).foregroundStyle(WebTheme.muted).frame(maxWidth: .infinity)
              .padding(.top, 64)
          }
        }.padding(16).frame(maxWidth: 448).frame(maxWidth: .infinity)
      }.scrollIndicators(.hidden).accessibilityIdentifier("signals.list")
        .webRefreshable { await load() }
    }.usdtPage("信号").task(id: "\(store.scope):\(scenePhase):\(isVisible)") {
      if modelScope != store.scope {
        model.reset(); modelScope = store.scope; nextRefreshAt = .distantPast
      }
      guard store.mode == "ordinary" else { model.reset(); return }
      guard isVisible, scenePhase == .active else { return }
      while !Task.isCancelled {
        let delay = nextRefreshAt.timeIntervalSinceNow
        if delay > 0 {
          do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        await load()
      }
    }
      .webModal(isPresented: $rules) {
        WebModal(title: "信号规则") {
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              ForEach(Array(signalRuleGroups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 6) {
                  Text(group.0).font(.system(size: 14, weight: .medium)).foregroundStyle(
                    WebTheme.brand)
                  ForEach(group.1, id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                      Circle().fill(WebTheme.muted).frame(width: 4, height: 4).padding(.top, 8)
                      Text(line).font(.system(size: 14)).lineSpacing(5).foregroundStyle(
                        WebTheme.secondary)
                    }
                  }
                }
              }
            }
          }.frame(maxHeight: 440).scrollIndicators(.hidden)
          Button("我知道了") { rules = false }.buttonStyle(WebButtonStyle(radius: 14))
        }
      }
  }
  private func signalCard(_ row: JSONValue) -> some View {
    USDTCard(radius: 10, padding: 14, spacing: 8) {
      HStack(spacing: 8) {
        WebDirection(long: ["LONG", "long", "0"].contains(row.value("direction")))
        Text(row.value("symbol").replacingOccurrences(of: "USDT", with: "")).font(
          .system(size: 16, weight: .semibold))
        WebBadge(text: "自有", color: WebTheme.muted)
        Spacer(minLength: 0)
        Text(WebFormat.time(row.value("signal_time", fallback: row.value("received_at")))).font(
          .system(size: 12)
        ).monospacedDigit().foregroundStyle(WebTheme.muted)
      }
      HStack(spacing: 6) {
        if !row.value("interval", fallback: "").isEmpty {
          WebBadge(text: row.value("interval"), color: WebTheme.muted)
        }
        if row.value("strategy") != "Unknown" {
          Text(row.value("strategy", fallback: "")).font(.system(size: 14)).foregroundStyle(
            WebTheme.secondary)
        }
        if !row.value("final_action", fallback: "").isEmpty {
          WebBadge(text: row.value("final_action"))
        }
        Spacer(minLength: 0)
      }
      if !row.value("comment", fallback: "").isEmpty {
        Text(row.value("comment")).font(.system(size: 14)).foregroundStyle(WebTheme.secondary)
      }
      if !row.value("entry_condition", fallback: "").isEmpty {
        Text("触发条件：" + row.value("entry_condition")).font(.system(size: 12)).foregroundStyle(
          WebTheme.muted
        ).lineSpacing(4)
      }
      if let risks = row["risk_points"]?.rows, !risks.isEmpty {
        Text("风险：" + risks.map(\.text).joined(separator: "；")).font(.system(size: 12))
          .foregroundStyle(WebTheme.muted).lineSpacing(4)
      }
    }.overlay { RoundedRectangle(cornerRadius: 10).stroke(WebTheme.border, lineWidth: 1) }
      .contentShape(Rectangle())
  }
  private func load() async {
    guard store.mode == "ordinary" else { model.reset(); return }
    let scope = store.scope
    await model.load(
      store, path: "/v1/trade/tradingview/signals", query: [.init(name: "source", value: "internal")])
    guard !Task.isCancelled, scope == store.scope else { return }
    if model.error.isEmpty {
      store.recordSignalSnapshot(model.items, markRead: isVisible && scenePhase == .active)
    }
    nextRefreshAt = .now.addingTimeInterval(30)
  }
}

private extension JSONValue {
  var signalIdentity: String {
    value("id", fallback: value("symbol") + ":" + value("interval") + ":" + value("signal_time"))
  }
}

struct USDTRecordsView: View {
  enum Kind {
    case transfers, operations
    case strategyLog(String)
    var title: String {
      switch self {
      case .transfers: "资金归集"
      case .operations: "日志"
      case .strategyLog: "策略执行记录"
      }
    }
    var path: String {
      switch self {
      case .transfers: "/v1/account/transfer-history"
      case .operations: "/v1/account/operation-logs"
      case .strategyLog: "/v1/strategy/log"
      }
    }
    var transfers: Bool {
      if case .transfers = self { return true }
      return false
    }
  }
  @EnvironmentObject private var store: USDTStore
  @StateObject private var model = USDTPageModel()
  let kind: Kind
  var embedded = false
  @State private var cursor = ""
  @State private var notice = ""
  var body: some View {
    Group {
      if embedded { records }
      else { records.usdtPage(kind.title, refresh: { Task { await refresh() } }) }
    }.task(id: store.scope) { await load(reset: true) }
      .webRefreshable { await refresh() }
  }
  private var records: some View {
    WebRefreshScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if kind.transfers {
          transferSummary
          HStack {
            Text("历史记录").font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("共 \(model.value["pagination"]?.value("total", fallback: "0") ?? "0") 笔").font(
              .system(size: 12)
            ).foregroundStyle(WebTheme.muted)
            if embedded {
              Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium))
                  .frame(width: 44, height: 44).contentShape(Rectangle())
              }.buttonStyle(.plain).disabled(model.loading).accessibilityLabel("刷新记录")
                .accessibilityIdentifier("collection.refresh")
            }
          }.padding(.top, 8).padding(.horizontal, 4)
        } else {
          Text("北京时间 · 最新记录在前").font(.system(size: 12)).foregroundStyle(WebTheme.muted)
        }
        USDTNotice(text: notice)
        ForEach(Array(model.items.enumerated()), id: \.offset) { _, row in
          if kind.transfers { transferCard(row) } else { operationCard(row) }
        }
        if model.items.isEmpty {
          VStack(spacing: 12) {
            Image(systemName: kind.transfers ? "clock.arrow.circlepath" : "list.clipboard").font(
              .system(size: 28, weight: .light))
            Text(
              model.error.isEmpty
                ? (model.loading ? "正在加载..." : kind.transfers ? "暂无转账记录" : "暂无日志") : model.error
            ).font(.system(size: 14))
          }.foregroundStyle(WebTheme.muted).frame(maxWidth: .infinity).frame(
            minHeight: kind.transfers ? 240 : 168
          ).background(
            kind.transfers ? WebTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 16))
        }
        if model.hasNext || model.value["has_more"]?.flag == true {
          Button(model.loading ? "加载中..." : "加载更多") {
            model.page += 1
            cursor = model.value.value("next_cursor", fallback: "")
            Task { await load(reset: false) }
          }.buttonStyle(WebButtonStyle(kind: .secondary, height: 44, radius: 14, fontSize: 14))
            .disabled(model.loading)
        } else if !model.items.isEmpty && !kind.transfers {
          Text("已显示全部日志").font(.system(size: 12)).foregroundStyle(WebTheme.muted).frame(
            maxWidth: .infinity
          ).padding(.top, 8)
        }
      }.padding(16).frame(maxWidth: 448).frame(maxWidth: .infinity)
    }.scrollIndicators(.hidden).accessibilityIdentifier("collection.history")
  }
  private var transferSummary: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("\(WebFormat.time(model.value.value("start_at"), format: "yyyy.MM.dd")) 起").font(
            .system(size: 12, weight: .medium)
          ).foregroundStyle(WebTheme.muted)
          Spacer()
          WebBadge(
            text: model.value.value("account_type") == "sub"
              ? "子账户" : model.value.value("account_type") == "master" ? "主账户" : "待同步",
            color: WebTheme.muted)
        }
        Text((model.value["net_amount"]?.decimal ?? 0) < 0 ? "累计净收到" : "累计净转出").font(
          .system(size: 14, weight: .medium)
        ).foregroundStyle(WebTheme.secondary).padding(.top, 20)
        Text(WebFormat.amount(model.value.value("net_amount", fallback: "0"), signed: true)).font(
          .system(size: 30, weight: .bold)
        ).foregroundStyle(WebTheme.success).padding(.top, 4)
      }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20).frame(
        maxWidth: .infinity, alignment: .leading)
      Rectangle().fill(WebTheme.border).frame(height: 1)
      HStack(spacing: 0) {
        transferTotal(
          "累计转出", model.value.value("outgoing_total", fallback: "0.00"), WebTheme.success)
        Rectangle().fill(WebTheme.border).frame(width: 1)
        transferTotal("累计收到", model.value.value("incoming_total", fallback: "0.00"), WebTheme.brand)
      }.fixedSize(horizontal: false, vertical: true)
    }.background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 16)).overlay {
      RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1)
    }.accessibilityIdentifier("collection.summary")
  }
  private func transferTotal(_ label: String, _ value: String, _ color: Color) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.system(size: 12)).foregroundStyle(WebTheme.muted)
      Text(WebFormat.amount(value)).font(.system(size: 16, weight: .semibold)).foregroundStyle(
        color)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(
      .vertical, 16)
  }
  private func transferCard(_ row: JSONValue) -> some View {
    let outgoing = row.value("direction") == "outgoing"
    let color = outgoing ? WebTheme.success : WebTheme.brand
    return HStack(spacing: 12) {
      WebIcon(outgoing ? "arrow.up.right" : "arrow.down.left", size: 20).foregroundStyle(color)
        .frame(width: 40, height: 40).background(
          color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
      VStack(alignment: .leading, spacing: 4) {
        Text(row.value("route")).font(.system(size: 14, weight: .medium)).lineLimit(1)
        Text("\(WebFormat.time(row.value("occurred_at"))) · \(row.value("channel"))").font(
          .system(size: 12)
        ).foregroundStyle(WebTheme.muted).lineLimit(1)
      }.frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .trailing, spacing: 4) {
        Text((outgoing ? "+" : "-") + WebFormat.amount(row.value("amount"))).font(
          .system(size: 14, weight: .semibold)
        ).foregroundStyle(color)
        Text(outgoing ? "转出" : "收到").font(.system(size: 11)).foregroundStyle(WebTheme.muted)
      }
    }.padding(16).frame(minHeight: 96).background(
      WebTheme.surface, in: RoundedRectangle(cornerRadius: 16)
    ).overlay { RoundedRectangle(cornerRadius: 16).stroke(WebTheme.border, lineWidth: 1) }
  }
  private func operationCard(_ row: JSONValue) -> some View {
    let status = row.value("status")
    let label =
      ["success": "已执行", "pending": "待确认", "failed": "失败", "info": "记录"][status] ?? status
    return USDTCard(radius: 14, spacing: 8) {
      HStack(spacing: 8) {
        Text(row.value("symbol", fallback: row.value("action"))).font(
          .system(size: 16, weight: .semibold))
        Text(row.value("side") == "long" ? "多" : "空").font(.system(size: 12)).foregroundStyle(
          row.value("side") == "long" ? WebTheme.success : WebTheme.danger)
        if row.value("position_origin") == "exchange_external" { WebBadge(text: "手动仓") }
        Spacer()
        WebBadge(
          text: label,
          color: status == "success"
            ? WebTheme.success
            : status == "failed"
              ? WebTheme.danger : status == "pending" ? WebTheme.brand : WebTheme.secondary)
      }
      HStack(spacing: 12) {
        Text(
          ["system": "系统", "user": "手动", "strategy": "策略", "trade": "成交"][row.value("source")]
            ?? "系统")
        Text("仓位 #" + row.value("order_id"))
        Text(
          WebFormat.time(
            row.value("occurred_at", fallback: row.value("created_at")),
            format: "yyyy/MM/dd HH:mm:ss"))
      }.font(.system(size: 12)).foregroundStyle(WebTheme.muted)
      Text(
        row.value(
          "message",
          fallback: row.value("content", fallback: row.value("behavior_desc", fallback: "")))
      ).font(.system(size: 14)).foregroundStyle(WebTheme.secondary).lineSpacing(6).padding(.top, 4)
    }.overlay { RoundedRectangle(cornerRadius: 14).stroke(WebTheme.border, lineWidth: 1) }
  }
  private func refresh() async {
    if kind.transfers {
      do { _ = try await store.send("/v1/account/transfer-history/sync") } catch {
        notice = error.localizedDescription
      }
    }
    await load(reset: true)
  }
  private func load(reset: Bool) async {
    if reset {
      model.page = 1
      cursor = ""
    }
    var query: [URLQueryItem] = [
      .init(name: "page", value: String(model.page)), .init(name: "page_size", value: "20"),
      .init(name: "limit", value: "20"), .init(name: "cursor", value: cursor),
    ]
    if case .strategyLog(let id) = kind { query.append(.init(name: "position_id", value: id)) }
    await model.load(store, path: kind.path, query: query, append: !reset)
  }
}

private let signalRuleGroups: [(String, [String])] = [
  (
    "监控范围",
    [
      "币种池：DOGE / BTC / ETH / XAU / SOL / XRP / ADA / BCH / SUI / XLM / HBAR / ALGO / TAO / ZEC（USDT 永续合约，共 14 个）",
      "周期：15 分钟、1 小时、4 小时、1 天", "仅在「已收盘确认」的K线上判定，每分钟轮询一次，同一信号只提醒一次",
    ]
  ),
  (
    "趋势判定（SuperTrend）",
    [
      "使用 SuperTrend 指标：ATR 系数 6、ATR 长度 10（Wilder 平滑），源价取 (最高+最低)/2",
      "趋势切换做多：SuperTrend 方向由空翻多 → 静默进入等待做多状态，不发送提醒", "趋势切换做空：SuperTrend 方向由多翻空 → 静默进入等待做空状态，不发送提醒",
      "每次趋势切换会清空反向的等待状态",
    ]
  ),
  (
    "入场信号（EMA55 / EMA144）",
    [
      "多头过滤：EMA21 在 EMA55 之上；15 分钟周期放宽为 EMA55 在 EMA144 之上亦可",
      "空头过滤：EMA55 在 EMA144 之下；15 分钟周期放宽为 EMA21 在 EMA55 之下亦可",
      "做多入场：等待做多期间，出现阳线且整根K线（含影线）触碰/穿过 EMA55 或 EMA144 → 触发「做多入场EMA55/144」，对应等待随即消耗",
      "做空入场：等待做空期间，出现阴线且整根K线（含影线）触碰/穿过 EMA55 或 EMA144 → 触发「做空入场EMA55/144」，对应等待随即消耗",
      "趋势切换当根K线不允许触发入场；等待消耗后需等待下一次趋势切换才会重新等待",
    ]
  ),
  ("提醒出口", ["触发后同步推送到企业微信群，并展示在本页信号列表", "信号由自有服务器基于币安公开行情计算，不依赖任何第三方平台"]),
]
