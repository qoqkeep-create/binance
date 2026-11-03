import SwiftUI

struct USDTTradeView: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var store: USDTStore
  @State private var orderType = "market"
  @State private var stop = ""
  @State private var limit = ""
  private var risk: String { store.riskAmount }
  @State private var includeFee = false
  @State private var strategyID = ""
  @State private var busy = false
  @State private var confirm = false
  @State private var requestIdentity = UUID().uuidString
  @State private var submitted = false
  var initialStop: String = ""
  var initialLimit: String = ""
  var chartInput: ChartTradeInput? = nil
  var onChartOrderTypeChange: ((String) -> Void)? = nil
  var chartHasPosition = false
  var chartPositionsReady = true
  var chartPositionsError = ""
  var chartPositionRows: [JSONValue] = []
  @State private var heldPositionID = ""
  var onShowPositions: (() -> Void)? = nil
  @StateObject private var positions = USDTChartPositionsModel()
  @State private var showsPositions = false
  @State private var confirmationDraft: USDTEntryDraft?
  @State private var confirmationScope = ""
  private var symbol: String { chartInput?.symbol ?? store.selectedSymbol }
  private var hasPosition: Bool {
    chartInput != nil ? chartHasPosition : !positions.positions(for: symbol, scope: store.scope).isEmpty
  }
  private var positionsReady: Bool {
    chartInput != nil ? chartPositionsReady : positions.isReady(scope: store.scope)
  }
  private var entryDisabled: Bool {
    !hasPosition && (busy || submitted || !store.isBound || !inputValid || !strategyValid || !positionsReady)
  }

  @EnvironmentObject private var container: AppContainer
  @EnvironmentObject private var dashboard: DashboardViewModel
  private var currentQuote: String { chartInput?.currentPrice ?? dashboard.tradeQuote(for: symbol) }
  @State private var showSymbols = false
  @State private var showStopLoss = false
  @State private var showChart = false
  private var strategyEnabled: Bool { !strategyID.isEmpty }

  private var standardForm: some View {
    VStack(spacing: 0) {
      Text("开仓").font(.system(size: 18, weight: .semibold))
        .frame(maxWidth: .infinity).frame(height: 48)
        .background(WebTheme.surface.ignoresSafeArea(edges: .top))
      ScrollView {
        VStack(spacing: 16) {
          USDTCard {
            HStack {
              Button { showSymbols = true } label: {
                HStack(spacing: 4) {
                  Text(symbol).font(.system(size: 17, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                  WebIcon("chevron.down", size: 12).foregroundStyle(WebTheme.muted)
                }.frame(minHeight: 44).contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityIdentifier("trade.symbol")
              Spacer(minLength: 4)
              ForEach([("market", "市价开仓"), ("limit", "限价委托")], id: \.0) { key, title in
                Button(title) { orderType = key }.font(.system(size: 14))
                  .foregroundStyle(orderType == key ? Color.black : WebTheme.secondary)
                  .padding(.horizontal, 8).frame(height: 28)
                  .background(
                    orderType == key ? WebTheme.brand : WebTheme.secondaryButton,
                    in: RoundedRectangle(cornerRadius: 4))
              }
            }
            HStack(spacing: 8) {
              Button {
                showChart = true
              } label: {
                Text(DisplayNumber.text(currentQuote)).font(
                  .system(size: 24, weight: .medium)
                ).underline()
              }.buttonStyle(.plain)
              Button {
                showChart = true
              } label: {
                WebLabel("K线", "chart.bar.xaxis")
              }.buttonStyle(
                WebButtonStyle(kind: .secondary, height: 38, fontSize: 14, fullWidth: false))
              Spacer()
            }
            if orderType == "limit" {
              USDTField(title: "限价", text: $limit, numeric: true, placeholder: "请输入限价")
            }
            USDTField(title: "止损价", text: $stop, numeric: true, placeholder: "请输入止损价")
            VStack(alignment: .leading, spacing: 8) {
              Text("止盈方式").font(.system(size: 14)).foregroundStyle(WebTheme.muted)
              NavigationLink {
                USDTStrategiesView(returnAfterSelection: true, onSelection: selectStrategy)
              } label: {
                takeProfitSelectionLabel
              }.buttonStyle(.plain).accessibilityIdentifier("trade.strategy")
            }.padding(.bottom, 12)
          }
          USDTCard(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
              estimate("止损金额", DisplayNumber.text(risk.isEmpty ? "0" : risk))
              estimate("预估仓位", estimatedPosition)
              estimate("预估手续费", estimatedFee)
            }.padding(.bottom, 0)
            Rectangle().fill(WebTheme.border).frame(height: 1)
            HStack(spacing: 8) {
              Button {
                showStopLoss = true
              } label: {
                Text("调整止损金额").padding(.horizontal, 12)
              }.buttonStyle(WebButtonStyle(height: 36, fontSize: 14, fullWidth: false))
              Spacer(minLength: 0)
              Toggle("止损含手续费", isOn: $includeFee).toggleStyle(WebSwitchStyle()).fixedSize()
            }
          }
          Button(action: advanceEntry) {
            Text(entryButtonText).font(.system(size: 16, weight: .semibold))
              .frame(maxWidth: .infinity, minHeight: 48)
              .foregroundStyle(hasPosition ? BinanceTheme.onAccent : Color.white)
              .background(hasPosition ? BinanceTheme.accent : chartActionColor,
                in: RoundedRectangle(cornerRadius: 10))
          }.buttonStyle(ChartTicketActionStyle()).disabled(entryDisabled)
        }.padding(16).frame(maxWidth: 448).frame(maxWidth: .infinity)
      }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
    }.usdtPage("开仓")
  }

  var body: some View {
    Group {
      if chartInput != nil { chartTicket } else { standardForm }
    }
      .onChange(of: chartInput, initial: true) { _, input in
        guard let input else { return }
        orderType = input.orderType
        stop = input.stopLossPrice
        limit = input.limitPrice
      }
      .task(id: "\(store.scope):\(store.isBound):\(scenePhase)") {
        guard chartInput == nil, scenePhase == .active else { return }
        await positions.monitor(store)
      }
      .onChange(of: store.liveRevision) { _, _ in
        guard chartInput == nil, scenePhase == .active else { return }
        Task { await positions.refresh(store) }
      }
      .onChange(of: hasPosition) { _, holding in
        if holding { confirm = false; confirmationDraft = nil }
      }
      .onChange(of: store.scope) { _, _ in
        confirmationDraft = nil; confirm = false; submitted = false
        requestIdentity = UUID().uuidString
        strategyID = store.activeStrategy?.value("id") ?? ""
      }
      .onChange(of: includeFee) { _, _ in resetDraft() }
      .onChange(of: risk) { _, _ in resetDraft() }
      .task(id: store.scope) {
        let scope = store.scope
        strategyID = store.activeStrategy?.value("id") ?? ""
        await store.refresh()
        guard scope == store.scope, !Task.isCancelled else { return }
        strategyID = store.activeStrategy?.value("id") ?? ""
      }
      .onChange(of: chartPositionsError, initial: true) { _, message in presentPositionError(message) }
      .onChange(of: positions.error) { _, message in presentPositionError(message) }
      .onAppear {
        if chartInput == nil { dashboard.restoreRealtimeSubscriptions() }
        if !initialStop.isEmpty { stop = initialStop }
        if !initialLimit.isEmpty {
          limit = initialLimit
          orderType = "limit"
        }
      }
      .onChange(of: symbol) { _, _ in resetDraft() }
      .onChange(of: stop) { _, _ in resetDraft() }
      .onChange(of: limit) { _, _ in resetDraft() }
      .onChange(of: orderType) { _, _ in resetDraft() }
      .onChange(of: strategyID) { _, _ in resetDraft() }
      .onChange(of: store.activeStrategy?.value("id")) { _, id in
        strategyID = id ?? ""
      }
      .navigationDestination(isPresented: $showChart) {
          MarketChartView(
            market: container.dashboardViewModel.markets(onlyVisible: false).first {
              $0.symbol == symbol
            }
              ?? MarketSnapshot(
                symbol: symbol, quoteAsset: "USDT", price: 0, changePercent24h: 0,
                updatedAt: .now),
            availableMarkets: container.dashboardViewModel.markets(onlyVisible: false),
            apiClient: container.apiClient, realtimeClient: container.realtimeClient,
            initialInterval: .oneHour,
            onStop: { dashboard.restoreRealtimeSubscriptions() })
      }
      .navigationDestination(isPresented: $showsPositions) { USDTPositionsView() }
      .largeTradingSheet(isPresented: $showSymbols) {
        MarketSearchView(dashboardViewModel: dashboard, selectedSymbol: symbol) { symbol in
          store.selectedSymbol = symbol
        }
      }
      .largeTradingSheet(isPresented: $showStopLoss, background: WebTheme.surface, showsDragIndicator: false) {
        USDTStopLossView()
      }
      .webModal(isPresented: $confirm) {
        let draft = confirmationDraft ?? currentDraft
        WebModal(title: draft.orderType == "limit" ? "委托确认" : "开仓确认") {
          Text(
            "即将开\(draft.symbol.replacingOccurrences(of: "USDT", with: "")) \(draft.isLong ? "多" : "空")单"
          ).font(.system(size: 18, weight: .bold)).foregroundStyle(
            draft.isLong ? WebTheme.success : WebTheme.danger
          ).frame(maxWidth: .infinity)
          VStack(spacing: 12) {
            USDTMetric(title: "币种", value: draft.symbol)
            USDTMetric(title: "模式", value: draft.orderType == "limit" ? "限价委托" : "市价开仓")
            USDTMetric(title: "止损价", value: DisplayNumber.text(draft.stopLossPrice))
            if draft.orderType == "limit" { USDTMetric(title: "限价值", value: DisplayNumber.text(draft.limitPrice)) }
            USDTMetric(title: "仓位", value: draft.positionText + " U")
            HStack {
              Text("手续费").foregroundStyle(WebTheme.secondary)
              Spacer()
              Text(draft.includeFee ? "(含)" : "(不含)").font(.system(size: 12)).foregroundStyle(
                draft.includeFee ? WebTheme.success : WebTheme.danger)
              Text(draft.feeText + " U").fontWeight(.medium)
            }
            USDTMetric(
              title: "止损额",
              value: draft.includeFee
                ? DisplayNumber.text(draft.riskAmount) + " U"
                : DisplayNumber.text(draft.riskAmount) + "+" + draft.feeText + "="
                  + USDTEntryDraft.amount((Decimal(string: draft.riskAmount) ?? 0)
                    + draft.positionEstimate * USDTEntryDraft.feeRate) + " U")
            USDTMetric(
              title: "止损回撤",
              value: draft.referencePrice > 0
                ? DisplayNumber.text(abs(draft.referencePrice - draft.stop) / draft.referencePrice * 100) + "%" : "--")
          }.font(.system(size: 14)).padding(16).background(
            WebTheme.input, in: RoundedRectangle(cornerRadius: 14))
          HStack(spacing: 12) {
            Button("取消") { confirm = false }.buttonStyle(
              WebButtonStyle(kind: .secondary, radius: 14))
            Button("确定") {
              confirm = false
              guard confirmationScope == store.scope, draft.matchesIntent(currentDraft) else {
                container.toastCenter.warning("开仓参数已变化，请重新确认"); return
              }
              submit(draft)
            }.buttonStyle(WebButtonStyle(radius: 14, weight: .bold))
          }
        }
      }
  }
  private var currentDraft: USDTEntryDraft {
    USDTEntryDraft(symbol: symbol, orderType: orderType, stopLossPrice: stop,
      limitPrice: limit, currentPrice: currentQuote, riskAmount: risk, includeFee: includeFee,
      strategy: strategyEnabled ? store.strategies.first { $0.value("id") == strategyID } : nil,
      leverage: store.selectedLeverage(for: symbol))
  }
  private var referencePrice: Decimal { currentDraft.referencePrice }
  private var isLong: Bool { currentDraft.isLong }
  private var positionEstimate: Decimal { currentDraft.positionEstimate }
  private var estimatedPosition: String { currentDraft.positionText }
  private var estimatedFee: String { currentDraft.feeText }
  private func estimate(_ title: String, _ value: String) -> some View {
    VStack(spacing: 8) {
      Text(title).font(.system(size: 14)).foregroundStyle(WebTheme.muted).frame(height: 20)
      Text(value).font(.system(size: 24)).frame(height: 32).lineLimit(1).minimumScaleFactor(0.6)
    }.frame(maxWidth: .infinity)
  }
  private var inputValid: Bool {
    currentDraft.isValid
  }
  private var strategyValid: Bool {
    !strategyEnabled || store.strategies.contains { $0.value("id") == strategyID }
  }
  private var entryButtonText: String {
    if hasPosition { return "正在持仓中" }
    if store.isBound && !positionsReady { return "正在确认持仓…" }
    if submitted { return "已提交" }
    if busy { return "处理中…" }
    if !strategyValid { return "请选择止盈方式" }
    if !inputValid { return chartInput != nil ? "在 K 线图上选择止损价开仓"
      : orderType == "market" ? "输入止损价开仓" : "输入止损价/限价开仓" }
    return chartInput != nil ? (isLong ? "开多" : "开空")
      : (orderType == "market" ? "市价开" : "限价开") + (isLong ? "多" : "空")
  }

  private var takeProfitSelectionText: String {
    if hasPosition { return heldTakeProfit }
    if !strategyEnabled { return "手动止盈" }
    return store.strategies.first { $0.value("id") == strategyID }?.value("name", fallback: "选择止盈方式") ?? "选择止盈方式"
  }
  private var takeProfitIsAutomatic: Bool {
    if hasPosition { return heldRow?.value("strategy_status") == "1" }
    return strategyEnabled
  }
  private var takeProfitSelectionLabel: some View {
    HStack(spacing: 4) {
      Text(takeProfitSelectionText).font(.system(size: 16, weight: .semibold))
        .lineLimit(1).truncationMode(.tail).underline(!hasPosition)
      if !hasPosition {
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
      }
    }.foregroundStyle(takeProfitIsAutomatic ? BinanceTheme.accent : ChartTradingPalette.color(.positive, for: colorScheme))
      .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
  }

  private func presentPositionError(_ message: String) {
    guard !message.isEmpty else { return }
    container.toastCenter.error(message)
  }
  private func presentEntryError(_ error: Error, suffix: String = "") {
    let mapped = APIError.map(error)
    guard mapped.shouldPresent else { return }
    container.toastCenter.error(mapped.userMessage + suffix)
  }
  private func resetDraft() {
    if !submitted { requestIdentity = UUID().uuidString }
  }
  private func advanceEntry() {
    if hasPosition {
      if let onShowPositions { onShowPositions() } else { showsPositions = true }
      return
    }
    guard !busy, !submitted, store.isBound, inputValid, strategyValid, positionsReady else { return }
    let draft = currentDraft
    let scope = store.scope
    busy = true
    Task {
      defer { busy = false }
      do {
        try await store.preflight()
        guard scope == store.scope, draft.matchesIntent(currentDraft), !hasPosition, positionsReady else { return }
        confirmationDraft = draft
        confirmationScope = scope
        confirm = true
      } catch { if scope == store.scope { presentEntryError(error) } }
    }
  }
  private func submit(_ draft: USDTEntryDraft) {
    guard !hasPosition, positionsReady else { confirm = false; return }
    let scope = store.scope
    let key = requestIdentity
    let payload = draft.payload()
    busy = true
    submitted = true
    Task {
      defer { busy = false }
      do {
        let result = try await store.command(
          draft.orderType == "limit" ? "limit-create" : "open", payload: payload, key: key)
        guard scope == store.scope else { return }
        let status = result.value("status")
        container.toastCenter.present(store.commandMessage(result),
          style: status == "SUCCEEDED" ? .success : status == "FAILED" ? .error : .warning,
          duration: status == "SUCCEEDED" ? 1.5 : 4)
      } catch { if scope == store.scope { presentEntryError(error, suffix: "。请先核对命令记录。") } }
    }
  }

  private var heldRow: JSONValue? {
    chartPositionRows.first { $0.value("id") == heldPositionID } ?? chartPositionRows.first
  }
  private func heldAmount(_ key: String, unit: String = "") -> String {
    guard let amount = heldRow?[key]?.decimal, !amount.isNaN else { return "-" }
    return DisplayNumber.text(amount) + unit
  }
  private var heldStopPrice: String {
    guard let row = heldRow else { return "-" }
    let price = row["market_stop_set"]?.flag == true ? row["market_stop_price"] ?? row["stop_loss_price"] : row["stop_loss_price"]
    return price?.decimal.map { DisplayNumber.text($0) } ?? "-"
  }
  private var heldTakeProfit: String {
    guard let row = heldRow else { return "-" }
    if row["manual_take_profit_set"]?.flag == true { return heldAmount("manual_take_profit_price") }
    if row.value("strategy_status") == "1" { return row.value("strategy_name", fallback: "策略止盈") }
    return "手动止盈"
  }
  private var heldFee: String {
    guard let row = heldRow else { return "-" }
    if row.value("entry_fee_status") == "confirmed" {
      return heldAmount("entry_realized_fee", unit: " " + row.value("entry_fee_asset", fallback: "USDT"))
    }
    return row["estimated_total_fee"]?.decimal.map { "≈" + DisplayNumber.text(abs($0) / 2) + " U" } ?? "-"
  }
  private var chartTicket: some View {
    VStack(spacing: 14) {
      if chartPositionRows.count > 1 {
        Picker("持仓方向", selection: $heldPositionID) {
          ForEach(Array(chartPositionRows.enumerated()), id: \.offset) { _, row in
            Text(row.value("side") == "0" ? "多单" : "空单").tag(row.value("id"))
          }
        }.pickerStyle(.segmented)
      }
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        GridRow(alignment: .top) {
          chartMetric("开仓价", hasPosition ? heldAmount("open_price") : inputValid ? (orderType == "market" ? "市价" : DisplayNumber.text(limit)) : "-")
          chartMetric("止损价", hasPosition ? heldStopPrice : inputValid ? DisplayNumber.text(stop) : "-")
          chartMetric(hasPosition ? "仓位" : "预估仓位", hasPosition ? heldAmount("position_amount", unit: " U") : inputValid ? estimatedPosition + " U" : "-")
        }
        GridRow {
          Rectangle().fill(BinanceTheme.border).frame(height: 0.5)
            .gridCellColumns(3).gridCellUnsizedAxes(.horizontal)
        }
        GridRow(alignment: .top) {
          VStack(alignment: .leading, spacing: 5) {
            chartMetricLabel("止损金额").frame(height: 24, alignment: .leading)
            if hasPosition {
              chartMetricValue("止损金额", heldAmount("stop_loss_amount", unit: " U"))
                .foregroundStyle(WebTheme.text).frame(minHeight: 28, alignment: .leading)
            } else {
              Button { showStopLoss = true } label: {
                HStack(spacing: 4) {
                  chartMetricValue("止损金额", showsChartRiskAmount ? DisplayNumber.text(risk) + " U" : "-")
                    .underline(showsChartRiskAmount)
                  if showsChartRiskAmount {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                  }
                }.frame(minHeight: 28, alignment: .leading).contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityLabel("调整止损金额")
                .accessibilityIdentifier("chart-ticket.risk-settings")
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
              chartMetricLabel(hasPosition ? "手续费" : "含手续费")
              if !hasPosition { Toggle("含手续费", isOn: $includeFee).labelsHidden()
                .toggleStyle(ChartFeeSwitchStyle()).fixedSize()
                .disabled(busy || submitted || confirm).accessibilityIdentifier("chart-ticket.include-fee") }
            }.frame(height: 24, alignment: .leading)
            chartMetricValue("手续费", hasPosition ? heldFee : inputValid ? estimatedFee + " U" : "-").frame(minHeight: 28, alignment: .leading)
          }.frame(maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .leading, spacing: 5) {
            chartMetricLabel("止盈").frame(height: 24, alignment: .leading)
            NavigationLink {
              USDTStrategiesView(returnAfterSelection: true, onSelection: selectStrategy)
            } label: {
              takeProfitSelectionLabel
            }.buttonStyle(.plain).disabled(hasPosition || busy || submitted || confirm)
              .accessibilityIdentifier("chart-ticket.strategy")
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }.monospacedDigit().padding(.horizontal, 10).padding(.vertical, 12)
        .background(WebTheme.color(0xF3F5F7, 0x202731), in: RoundedRectangle(cornerRadius: 10))
      HStack(spacing: 12) {
        Picker("委托类型", selection: Binding(get: { orderType }, set: { value in
          orderType = value; onChartOrderTypeChange?(value)
        })) {
          Text("市价").tag("market")
          Text("限价").tag("limit")
        }.pickerStyle(.segmented).frame(width: 112).accessibilityIdentifier("chart-ticket.order-type")
          .disabled(hasPosition || busy || submitted || confirm)
        Button(action: advanceEntry) {
          HStack(spacing: 6) {
          Text(entryButtonText)
            .font(.system(size: inputValid || hasPosition ? 16 : 12, weight: .semibold))
            .lineLimit(1).minimumScaleFactor(0.75)
          if hasPosition { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)) }
          }.frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(hasPosition ? BinanceTheme.onAccent : inputValid ? BinanceTheme.onTradeAction : Color.white)
            .background(hasPosition ? BinanceTheme.accent : inputValid ? chartActionColor : ChartTradingPalette.color(.positive, for: colorScheme),
              in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(ChartTicketActionStyle()).disabled(entryDisabled)
          .accessibilityIdentifier("chart-ticket.submit")
      }
    }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
      .frame(maxWidth: .infinity)
      .background(BinanceTheme.surface.ignoresSafeArea(edges: [.horizontal, .bottom]))
      .overlay(alignment: .top) {
        Rectangle().fill(WebTheme.color(0xCAB56C, 0x887A4F)).frame(height: 1)
          .ignoresSafeArea(edges: .horizontal)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("chart-ticket")
  }
  private var showsChartRiskAmount: Bool {
    inputValid && (Decimal(string: risk) ?? 0) > 0
  }
  private func chartMetric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      chartMetricLabel(title)
      chartMetricValue(title, value)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func chartMetricLabel(_ title: String) -> some View {
    Text(title).font(.system(size: 12)).foregroundStyle(WebTheme.muted).lineLimit(1)
  }
  private func chartMetricValue(_ title: String, _ value: String) -> some View {
    Text(value).font(.system(size: 16, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
      .accessibilityIdentifier("chart-ticket." + title)
  }
  private var chartActionColor: Color {
    ChartTradingPalette.color(isLong ? .positive : .negative, for: colorScheme)
  }
  private func selectStrategy(_ strategy: JSONValue?) {
    strategyID = strategy?.value("id") ?? ""
    resetDraft()
  }
}

private struct ChartTicketActionStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
  }
}

private struct ChartFeeSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      Capsule().fill(configuration.isOn ? WebTheme.brand : WebTheme.muted.opacity(0.3))
        .frame(width: 30, height: 18)
        .overlay(alignment: .leading) {
          Circle().fill(.white).frame(width: 14, height: 14)
            .offset(x: configuration.isOn ? 14 : 2)
        }
    }.buttonStyle(.plain).frame(width: 30, height: 24)
      .animation(.easeOut(duration: 0.15), value: configuration.isOn)
      .accessibilityLabel("含手续费").accessibilityValue(configuration.isOn ? "开启" : "关闭")
      .accessibilityAddTraits(.isToggle)
  }
}

struct ChartTradeInput: Equatable {
  let symbol: String
  let orderType: String
  let stopLossPrice: String
  let limitPrice: String
  let currentPrice: String
}

/// Shared by the normal entry form and the embedded chart ticket. Monetary calculations stay Decimal.
struct USDTEntryDraft: Equatable {
  let symbol: String
  let orderType: String
  let stopLossPrice: String
  let limitPrice: String
  let currentPrice: String
  let riskAmount: String
  let includeFee: Bool
  let strategy: JSONValue?
  var leverage: Int? = nil
  static let feeRate = Decimal(string: "0.001")!
  var referencePrice: Decimal { Decimal(string: orderType == "limit" ? limitPrice : currentPrice) ?? 0 }
  var stop: Decimal { Decimal(string: stopLossPrice) ?? 0 }
  var isLong: Bool { stop < referencePrice }
  var isValid: Bool {
    let risk = Decimal(string: riskAmount) ?? 0
    return referencePrice > 0 && stop > 0 && referencePrice != stop && risk > 0
      && !referencePrice.isNaN && !stop.isNaN && !risk.isNaN
  }
  var positionEstimate: Decimal {
    guard isValid else { return 0 }
    let ratio = abs(referencePrice - stop) / referencePrice
    return (Decimal(string: riskAmount) ?? 0) / (ratio + (includeFee ? Self.feeRate : 0))
  }
  var positionText: String { Self.amount(positionEstimate) }
  var feeText: String { Self.amount(positionEstimate * Self.feeRate) }
  static func amount(_ value: Decimal) -> String { DisplayNumber.text(value) }
  func matchesIntent(_ other: Self) -> Bool {
    symbol == other.symbol && orderType == other.orderType && stopLossPrice == other.stopLossPrice
      && limitPrice == other.limitPrice && riskAmount == other.riskAmount && includeFee == other.includeFee
      && strategy == other.strategy && leverage == other.leverage && isLong == other.isLong
  }
  func payload() -> [String: JSONValue] {
    var result: [String: JSONValue] = ["symbol": .string(symbol.uppercased()),
      "stop_loss_price": .string(stopLossPrice), "stop_loss_amount": .string(riskAmount)]
    if let leverage { result["leverage"] = .number(Double(leverage)) }
    if orderType == "limit" { result["limit_price"] = .string(limitPrice) }
    else { result["include_fee"] = .bool(includeFee) }
    if let strategy {
      result["strategy_id"] = strategy["id"]; result["strategy_name"] = strategy["name"]
      result["strategy_config"] = strategy["levels"]
    }
    return result
  }
}

struct USDTPositionsView: View {
  var isVisible = true
  var onOpenChart: ((String, String) -> Void)? = nil
  @EnvironmentObject private var store: USDTStore
  @EnvironmentObject private var dashboard: DashboardViewModel
  @EnvironmentObject private var liveActivity: PositionLiveActivityController
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage(FloatingPositionsPreferences.enabledKey, store: FloatingPositionsPreferences.defaults)
  private var floatingPositions = false
  @StateObject private var model = USDTPageModel()
  @StateObject private var trendAdvice = PositionTrendAdviceModel()
  private var liveQuotes: PositionLiveQuotes { store.positionQuotes }
  private var snapshots: FloatingPositionsModel { store.positionSnapshots }
  private var rows: [JSONValue] {
    segment == "positions" ? (snapshots.scope == store.scope ? snapshots.rows : []) : model.items
  }
  private var loading: Bool { segment == "positions" ? snapshots.loading : model.loading }
  private var refreshing: Bool { segment != "positions" && model.refreshing }
  private var loadError: String {
    segment == "positions" ? (snapshots.failed ? "持仓更新失败，请稍后重试" : "") : model.error
  }
  @State private var segment = "positions"
  @State private var filter = "all"
  @State private var modelScope = ""
  @State private var notice = ""
  @EnvironmentObject private var container: AppContainer
  @State private var selected: JSONValue = .null
  @State private var operation: WebPositionOperation? = nil
  @State private var chart = false
  @State private var binding = false
  @State private var skipCloseAllConfirm = false
  @State private var closeAllConfirm = false
  @State private var closingAll = false
  @State private var closeQueue: [WebCloseTarget] = []
  private var closeQueueKey: String { "integrated.close-queue.\(store.scope)" }
  private var totalPnl: Decimal? {
    let profits = rows.compactMap { liveValuation($0)?.profit }
    return profits.count == rows.count ? profits.reduce(Decimal.zero, +) : nil
  }
  private var totalPnlText: String { totalPnl.map { DisplayNumber.text($0, signed: true) } ?? "--" }
  private var totalPnlColor: Color { totalPnl.map { $0 >= 0 ? WebTheme.success : WebTheme.danger } ?? WebTheme.muted }
  private var trendSymbols: [String] {
    guard isVisible, store.isBound, segment == "positions", scenePhase == .active, !chart else { return [] }
    return Array(Set(rows.map { $0.value("symbol", fallback: "").uppercased() }
      .filter { !$0.isEmpty })).sorted()
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 4) {
        WebTabs(
          tabs: [("positions", "持仓"), ("limits", "限价委托"), ("history", "历史仓位")], selection: $segment)
          .frame(maxWidth: 248).frame(height: 44)
        Spacer(minLength: 0)
        Button { liveActivity.toggle(store: store, container: container) } label: {
          VStack(spacing: 1) {
            if liveActivity.isStarting || liveActivity.isRegistering {
              ProgressView().controlSize(.mini).frame(height: 17)
            } else {
              Image(systemName: "waveform.path.ecg").font(.system(size: 17, weight: .medium))
            }
            Text("live").font(.system(size: 9, weight: .semibold))
          }.foregroundStyle(liveActivity.isActive ? WebTheme.brand : WebTheme.secondary)
            .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("positions.liveActivity")
          .accessibilityLabel("live 持仓实时活动")
          .accessibilityValue(liveActivity.isActive ? "已开启" : "未开启")
        Button { floatingPositions.toggle() } label: {
          Image(systemName: floatingPositions ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(floatingPositions ? WebTheme.brand : WebTheme.secondary)
            .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("positions.floatingPositions")
          .accessibilityLabel("持仓浮窗").accessibilityValue(floatingPositions ? "已开启" : "未开启")
      }.padding(.horizontal, 8).frame(height: WebTheme.rootHeaderHeight)
        .background(WebTheme.surface).overlay(alignment: .bottom) {
          Rectangle().fill(WebTheme.border).frame(height: 1)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("positions.header")
      GeometryReader { geometry in
      ScrollView {
        VStack(spacing: 10) {
          if segment == "history" && store.isBound {
            HStack(spacing: 8) {
              ForEach(
                [("all", "全部"), ("day", "一天内"), ("three-days", "三天"), ("week", "一周")], id: \.0
              ) { key, label in
                Button(label) { filter = key }
                  .font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).frame(height: 32)
                  .foregroundStyle(filter == key ? WebTheme.color(0x735500, 0xFFE58A) : WebTheme.secondary)
                  .background(filter == key ? WebTheme.color(0xFFF5CC, 0x51451F) : WebTheme.secondaryButton,
                    in: RoundedRectangle(cornerRadius: 8))
                  .overlay { RoundedRectangle(cornerRadius: 8).stroke(filter == key ? BinanceTheme.accent : WebTheme.border, lineWidth: 1) }
                  .frame(minHeight: 44).contentShape(Rectangle())
                  .accessibilityAddTraits(filter == key ? .isSelected : [])
              }
              Spacer()
            }
          }
          if !store.isBound {
            Button { binding = true } label: {
              HStack(spacing: 6) {
                Text("请先绑定 Binance API").underline()
                WebIcon("chevron-right", size: 16)
              }.font(.system(size: 16)).foregroundStyle(WebTheme.muted)
                .frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("positions.bind")
          } else {
            USDTNotice(text: notice)
            if refreshing {
              Text("正在更新历史记录…").font(.system(size: 13)).foregroundStyle(WebTheme.muted)
            }
            if !rows.isEmpty { USDTNotice(text: loadError) }
            if loading && rows.isEmpty {
              Text("加载中...").font(.system(size: 16)).foregroundStyle(WebTheme.muted).frame(
                maxWidth: .infinity
              ).padding(.vertical, 48)
            }
            if !loading && !refreshing && rows.isEmpty {
              USDTEmptyState(
                title: segment == "positions" ? "暂无持仓" : segment == "limits" ? "暂无限价委托" : "暂无历史仓位记录",
                error: loadError
              ) { Task { await reload() } }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
              if segment == "positions" {
                positionCard(row)
              } else if segment == "limits" {
                limitCard(row)
              } else {
                historyCard(row)
              }
            }
            if segment == "positions", rows.count > 1 || !closeQueue.isEmpty { closeAllBar }
            if segment != "positions", model.hasNext {
              Button("加载更多") {
                model.page += 1
                Task { await reload(append: true) }
              }.buttonStyle(WebButtonStyle(kind: .secondary, fontSize: 14))
                .disabled(loading || refreshing)
            }
          }
        }.frame(minHeight: !store.isBound ? max(0, geometry.size.height - 32) : nil)
          .padding(16).frame(maxWidth: 448).frame(maxWidth: .infinity)
      }.scrollIndicators(.hidden).scrollBounceBehavior(.always)
        .accessibilityIdentifier("positions.list")
        .refreshable {
          let scope = store.scope
          let refreshSegment = segment
          let refreshFilter = filter
          // Account publication can cancel SwiftUI's refresh action. Keep this
          // read independent, then recheck the selected account and page.
          await Task { @MainActor in
            await store.refresh()
            guard scope == store.scope, refreshSegment == segment, refreshFilter == filter else { return }
            model.page = 1
            await reload()
          }.value
        }
      }
    }.usdtPage("持仓")
      .task(id: "quotes:\(store.scope):\(store.isBound):\(trendSymbols.joined(separator: ","))") {
        guard store.isBound else {
          dashboard.trackPositionTickerSymbols([], owner: "positions")
          return
        }
        let symbols = trendSymbols
        let session = liveQuotes.begin(scope: store.scope, symbols: symbols, owner: "positions")
        dashboard.trackPositionTickerSymbols(symbols, owner: "positions")
        defer {
          if liveQuotes.end(session) { dashboard.trackPositionTickerSymbols([], owner: "positions") }
        }
        guard !symbols.isEmpty else { return }
        for await event in container.realtimeClient.events(bufferingPolicy: .bufferingNewest(256)) {
          guard !Task.isCancelled else { break }
          if container.realtimeClient.state == .connected { liveQuotes.receive(event, session: session) }
        }
      }
      .task(id: "\(store.scope):\(segment):\(trendSymbols.joined(separator: ","))") {
        await trendAdvice.monitor(symbols: trendSymbols, api: container.apiClient)
      }
      .webModal(isPresented: $binding, motion: .fade) { USDTBindingView() }
      .task(id: store.scope) {
        if let data = UserDefaults.standard.data(forKey: closeQueueKey),
          let saved = try? JSONDecoder().decode([WebCloseTarget].self, from: data)
        {
          closeQueue = saved
        } else {
          closeQueue = []
        }
      }
      .task(id: "\(store.scope):\(segment):\(filter):\(store.isBound):\(isVisible):\(scenePhase)") {
        if modelScope != store.scope { model.reset(); modelScope = store.scope; notice = "" }
        guard store.isBound else { model.reset(); return }
        guard isVisible, scenePhase == .active, !chart else { return }
        model.page = 1
        let scope = store.scope
        let requestedSegment = segment
        let requestedFilter = filter
        // Keep an initial read alive across tab visibility changes.
        await Task { @MainActor in
          guard scope == store.scope, requestedSegment == segment, requestedFilter == filter else { return }
          await reload(reuseIfLoaded: true)
        }.value
      }
      .onChange(of: store.liveRevision) { _, _ in
        if isVisible, scenePhase == .active, !chart, segment != "history" {
          model.page = 1
          Task { await reload() }
        }
      }
      .onChange(of: scenePhase) { old, phase in
        guard old != .active, phase == .active, isVisible, store.isBound else { return }
        model.page = 1
        Task { await reload() }
      }
      .webModal(isPresented: $closeAllConfirm) {
        WebModal(title: "全部平仓") {
          (Text("当前共 \(rows.count) 笔持仓，预估总盈亏 ")
            + Text(totalPnlText + " USDT").foregroundColor(
              totalPnlColor) + Text("，确认全部平仓？"))
            .foregroundStyle(WebTheme.secondary).font(.system(size: 16))
          HStack(spacing: 12) {
            Button("取消") { closeAllConfirm = false }.buttonStyle(
              WebButtonStyle(kind: .secondary, radius: 14))
            Button("确认") {
              closeAllConfirm = false
              closeAll()
            }.buttonStyle(WebButtonStyle(kind: .danger, radius: 14)).disabled(closingAll)
          }
        }
      }
      .webModal(item: $operation,
        motion: operation?.action == "strategy" && operation?.position.value("strategy_status") != "1" ? .slide : .fade
      ) { operation in
        USDTPositionControls(position: operation.position, action: operation.action) {
          completePositionOperation($0)
        }.presentationBackground(.clear)
      }
      .onChange(of: store.scope) { _, _ in operation = nil }
      .navigationDestination(isPresented: $chart) {
          MarketChartView(
            market: MarketSnapshot(
              symbol: selected.value("symbol"), quoteAsset: "USDT",
              price: Double(selected.value("current_price")) ?? 0, changePercent24h: 0,
              updatedAt: .now), apiClient: container.apiClient,
            realtimeClient: container.realtimeClient,
            onStop: { dashboard.restoreRealtimeSubscriptions() })
      }
  }
  private var closeAllBar: some View {
    HStack(spacing: 8) {
      Button {
        skipCloseAllConfirm.toggle()
      } label: {
        HStack(spacing: 6) {
          RoundedRectangle(cornerRadius: 4).fill(skipCloseAllConfirm ? WebTheme.brand : .clear)
            .overlay {
              RoundedRectangle(cornerRadius: 4).stroke(
                skipCloseAllConfirm ? WebTheme.brand : WebTheme.muted, lineWidth: 1)
              if skipCloseAllConfirm { WebIcon("check", size: 11).foregroundStyle(.black) }
            }.frame(width: 16, height: 16)
          Text("无需确认").font(.system(size: 14, weight: .medium))
        }.frame(width: 106, height: 44).foregroundStyle(
          skipCloseAllConfirm ? WebTheme.brand : WebTheme.muted
        ).background(
          skipCloseAllConfirm ? WebTheme.brand.opacity(0.12) : WebTheme.secondaryButton,
          in: RoundedRectangle(cornerRadius: 10)
        ).overlay {
          RoundedRectangle(cornerRadius: 10).stroke(
            skipCloseAllConfirm ? WebTheme.brand : WebTheme.border, lineWidth: 1)
        }
      }.disabled(closingAll || !closeQueue.isEmpty)
      Button(
        closingAll ? "平仓中..." : !closeQueue.isEmpty ? "继续核对平仓结果" : "全部平仓(" + totalPnlText + ")"
      ) {
        if skipCloseAllConfirm || !closeQueue.isEmpty { closeAll() } else { closeAllConfirm = true }
      }.buttonStyle(WebButtonStyle(kind: totalPnl.map { $0 >= 0 ? .success : .danger } ?? .secondary, height: 44)).disabled(
        closingAll)
    }.padding(.top, 6)
  }
  private func closeAll() {
    guard !closingAll else { return }
    let scope = store.scope
    let storageKey = closeQueueKey
    if closeQueue.isEmpty {
      closeQueue = rows.compactMap { row in
        guard let id = row["id"], id != .null else { return nil }
        return WebCloseTarget(positionID: id, key: UUID().uuidString)
      }
    }
    persistCloseQueue(storageKey)
    closingAll = true
    Task {
      defer { closingAll = false }
      var succeeded = 0
      var failed = 0
      while let target = closeQueue.first {
        guard scope == store.scope else { return }
        do {
          let result = try await store.command(
            "position-close", payload: ["position_id": target.positionID], key: target.key)
          guard scope == store.scope else { return }
          switch result.value("status") {
          case "SUCCEEDED": succeeded += 1
          case "FAILED": failed += 1
          default:
            notice = store.commandMessage(result)
            await reload()
            return
          }
          closeQueue.removeFirst()
          persistCloseQueue(storageKey)
        } catch {
          // Preserve the same command identity and remaining targets on an unknown result.
          if scope == store.scope { notice = error.localizedDescription + "。请继续核对同一批平仓结果。" }
          return
        }
      }
      notice = "平仓结果：成功 \(succeeded) 笔，失败 \(failed) 笔；实际盈亏请以历史仓位结算为准。"
      await reload()
    }
  }
  private func persistCloseQueue(_ key: String) {
    if closeQueue.isEmpty {
      UserDefaults.standard.removeObject(forKey: key)
    } else if let data = try? JSONEncoder().encode(closeQueue) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }
  private func reload(append: Bool = false, reuseIfLoaded: Bool = false) async {
    guard store.isBound else {
      model.reset()
      return
    }
    if segment == "positions" {
      await store.refreshPositions()
      return
    }
    let path = segment == "limits" ? "/v1/trade/limit-order/list" : "/v1/position/history"
    await model.load(
      store, path: path,
      query: [
        .init(name: "filter", value: filter), .init(name: "page", value: String(model.page)),
        .init(name: "page_size", value: "20"),
      ], append: append, snapshotFirst: segment == "history" && !append, reuseIfLoaded: reuseIfLoaded)
  }
  private func positionCard(_ row: JSONValue) -> some View {
    let valuation = liveValuation(row)
    return USDTCard(radius: 14, padding: 14, spacing: 14) {
      HStack(spacing: 8) {
        Text(row.value("side") == "0" ? "多" : "空").font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white).frame(width: 20, height: 20)
          .background(
            row.value("side") == "0" ? WebTheme.success : WebTheme.danger,
            in: RoundedRectangle(cornerRadius: 4))
        Button { openChart(row, valuation: valuation) } label: {
          Text(row.value("symbol")).font(.system(size: 16, weight: .medium))
            .foregroundStyle(WebTheme.text).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(row.value("symbol") + " K线图")
          .accessibilityIdentifier("position.symbol." + row.value("id"))
        if row.value("position_origin") == "exchange_external" { WebBadge(text: "手动仓") }
        Text("x\(row.value("leverage"))").font(.system(size: 14)).foregroundStyle(WebTheme.muted)
        Text("止损\(DisplayNumber.text(row.value("stop_loss_amount")))U").font(.system(size: 12)).foregroundStyle(
          WebTheme.brand
        ).padding(.horizontal, 6).padding(.vertical, 2).background(
          WebTheme.brand.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        Spacer(minLength: 0)
        Button {
          openChart(row, valuation: valuation)
        } label: {
          WebIcon("candlesticks", size: 20).foregroundStyle(WebTheme.text)
            .frame(width: 32, height: 32)
            .background(WebTheme.secondaryButton, in: RoundedRectangle(cornerRadius: 8))
            .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("K线图")
          .accessibilityIdentifier("position.chart.\(row.value("id"))")
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 16) {
          inline("开仓额度：", DisplayNumber.text(row.value("position_amount")))
          inline(
            "持仓盈亏：", valuation.map { DisplayNumber.text($0.profit) } ?? "--",
            color: valuation.map { $0.profit >= 0 ? WebTheme.success : WebTheme.danger } ?? WebTheme.muted)
        }
        HStack(spacing: 16) {
          inline("开仓价格：", DisplayNumber.text(row.value("open_price")))
          inline("当前价格：", valuation.map { DisplayNumber.text($0.price) } ?? "--")
        }
        inline(
          "市价止损：", row["market_stop_set"]?.flag == true ? DisplayNumber.text(row.value("market_stop_price")) : "未设置")
        HStack(spacing: 6) {
          inline(
            "市价止盈：",
            row["manual_take_profit_set"]?.flag == true
              ? DisplayNumber.text(row.value("manual_take_profit_price")) : "未设置",
            expands: false)
          Button("设置") { show("takeProfit", row) }.font(.system(size: 12)).foregroundStyle(
            WebTheme.brand
          ).padding(.horizontal, 8).padding(.vertical, 2).background(
            WebTheme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
          Spacer(minLength: 0)
        }
        HStack(spacing: 4) {
          Text("手续费：").foregroundStyle(WebTheme.muted)
          Text(
            row.value("entry_fee_status") == "confirmed"
              ? DisplayNumber.text(row.value("entry_realized_fee")) + " "
                + row.value("entry_fee_asset", fallback: "USDT")
              : "估-"
                + DisplayNumber.text(abs(row["estimated_total_fee"]?.decimal ?? 0) / 2) + "U"
          ).foregroundStyle(WebTheme.danger)
          Text(
            "（估-"
              + DisplayNumber.text(abs(row["estimated_total_fee"]?.decimal ?? 0))
              + "U）"
          ).foregroundStyle(WebTheme.muted)
        }.font(.system(size: 14))
        Text(
          (row.value("position_origin") == "exchange_external" ? "接管时间：" : "开仓时间：")
            + WebFormat.time(
              row.value("created_at", fallback: row.value("opened_at")),
              format: "yyyy-MM-dd HH:mm:ss")
        ).font(.system(size: 14)).foregroundStyle(WebTheme.muted)
        if !row.value("latest_strategy_error", fallback: "").isEmpty {
          Text(row.value("latest_strategy_error")).font(.system(size: 14)).foregroundStyle(
            WebTheme.brand
          ).padding(12).background(
            WebTheme.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        }
        if !row.value("stop_protection_error", fallback: "").isEmpty {
          Text(row.value("stop_protection_error")).font(.system(size: 12)).foregroundStyle(
            WebTheme.danger)
        }
      }
      Rectangle().fill(WebTheme.border).frame(height: 1)
      HStack(spacing: 8) {
        if row.value("position_origin") != "exchange_external" {
          Button(
            row.value("strategy_status") == "1"
              ? "自动止盈中" : row["can_bind_strategy"]?.flag == true ? "添加自动止盈" : "手动止盈"
          ) { show("strategy", row) }.lineLimit(1).minimumScaleFactor(0.8).buttonStyle(
            WebPositionStrategyStyle(running: row.value("strategy_status") == "1")
          ).disabled(row.value("strategy_status") != "1" && row["can_bind_strategy"]?.flag != true)
          Button("设置保本损") { show("breakEven", row) }.lineLimit(1).minimumScaleFactor(0.8)
            .buttonStyle(WebPositiveActionStyle())
        }
        Button("立即平仓") { show("close", row) }.lineLimit(1).minimumScaleFactor(0.8)
          .buttonStyle(WebButtonStyle(height: 38, fontSize: 14))
      }
      if trendAdvice.isCountertrend(symbol: row.value("symbol"), side: row.value("side")) {
        Text(PositionTrendAdviceModel.message)
          .font(.system(size: 12)).foregroundStyle(WebTheme.brand)
          .lineLimit(1).minimumScaleFactor(0.8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("position.countertrendAdvice")
      }
    }
  }
  private func inline(_ title: String, _ value: String, color: Color? = nil, expands: Bool = true) -> some View {
    (Text(title).foregroundColor(WebTheme.muted)
      + Text(value).fontWeight(.medium).foregroundColor(color ?? WebTheme.text)).font(
        .system(size: 14)
      ).frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
  }
  private func liveValuation(_ row: JSONValue) -> PositionLiveValuation? {
    PositionLiveValuation(row: row, quote: liveQuotes.quotes[row.value("symbol").uppercased()])
  }
  private func openChart(_ row: JSONValue, valuation: PositionLiveValuation?) {
    if let onOpenChart { onOpenChart(row.value("symbol"), "1h"); return }
    var snapshot = row.fields
    if let valuation {
      snapshot["current_price"] = .string(NSDecimalNumber(decimal: valuation.price).stringValue)
    }
    selected = .object(snapshot)
    chart = true
  }
  private func show(_ name: String, _ row: JSONValue) {
    operation = WebPositionOperation(position: row, action: name)
  }
  private func completePositionOperation(_ message: String) {
    notice = message
    operation = nil
    Task { await reload() }
  }
  private func historyCard(_ row: JSONValue) -> some View {
    let external = row.value("position_origin") == "exchange_external"
    let pnl = row["pnl"]?.decimal
    let risk = row["stop_loss_amount"]?.decimal ?? 0
    let ratio =
      risk > 0 && pnl != nil
      ? DisplayNumber.text(pnl! / risk) + ":1" : "--"
    let fee: Decimal? =
      external && (row["fee"]?.decimal == nil || row["funding_fee"]?.decimal == nil)
      ? nil : (row["fee"]?.decimal ?? 0) + (row["funding_fee"]?.decimal ?? 0)
    return USDTCard(radius: 14, padding: 14, spacing: 12) {
      HStack(spacing: 8) {
        WebDirection(long: row.value("side") == "0")
        Text(row.value("symbol")).font(.system(size: 16, weight: .medium))
        WebBadge(text: "止损" + DisplayNumber.text(row.value("stop_loss_amount")) + "U")
        if row.value("settlement_status") == "estimated" { WebBadge(text: "估算") }
        if row.value("settlement_status") == "pending" { WebBadge(text: "待结算") }
        if row.value("settlement_status") == "failed" { WebBadge(text: "结算待重试") }
        Spacer()
      }
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
        alignment: .leading, spacing: 12
      ) {
        detail(
          "平仓盈亏", pnl.map { DisplayNumber.text($0) + "U" } ?? "--",
          color: pnl.map { $0 >= 0 ? WebTheme.success : WebTheme.danger })
        detail("盈亏比", ratio, color: pnl.map { $0 >= 0 ? WebTheme.success : WebTheme.danger })
        detail("开仓价格", DisplayNumber.text(row.value("open_price")))
        detail("平仓价格", DisplayNumber.text(row.value("close_price")))
        detail("持仓额", DisplayNumber.text(row.value("position_amount")) + "U")
        detail(
          "手续费", fee.map { DisplayNumber.text($0) + "U" } ?? "--",
          color: fee.map { $0 <= 0 ? WebTheme.danger : WebTheme.success })
      }
      Rectangle().fill(WebTheme.border).frame(height: 1)
      HStack(alignment: .bottom) {
        VStack(alignment: .leading, spacing: 4) {
          Text(
            "开仓时间  "
              + WebFormat.time(
                row.value("created_at", fallback: row.value("opened_at")),
                format: "yyyy-MM-dd HH:mm:ss"))
          Text("平仓时间  " + WebFormat.time(row.value("closed_at"), format: "yyyy-MM-dd HH:mm:ss"))
        }.font(.system(size: 14)).foregroundStyle(WebTheme.muted)
        Spacer(minLength: 0)
        if row["has_strategy_logs"]?.flag == true {
          Button {
            show("strategyLog", row)
          } label: {
            WebIcon("file-text", size: 20)
          }.accessibilityLabel("查看止盈止损记录")
        }
      }
      let settlementNote = row.value("settlement_note", fallback: "")
        .components(separatedBy: "；").filter { !$0.contains("资金费来自持仓时间窗口") }.joined(separator: "；")
      if !settlementNote.isEmpty { USDTNotice(text: settlementNote) }
    }
  }
  private func detail(_ title: String, _ value: String, color: Color? = nil) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 14)).foregroundStyle(WebTheme.muted)
      Text(value).font(.system(size: 16, weight: .medium)).foregroundStyle(color ?? WebTheme.text)
    }
  }
  private func limitCard(_ row: JSONValue) -> some View {
    USDTCard(radius: 14, padding: 14, spacing: 14) {
      HStack(spacing: 8) {
        WebDirection(long: row.value("side") == "0")
        Text(row.value("symbol")).font(.system(size: 16, weight: .medium))
        WebBadge(text: "止损" + DisplayNumber.text(row.value("stop_loss_amount")) + "U")
        Spacer()
        WebBadge(text: row.value("status_text"))
      }
      LazyVGrid(
        columns: [
          GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading),
        ], alignment: .leading, spacing: 12
      ) {
        detail("限价", DisplayNumber.text(row.value("limit_price")))
        detail("止损价", DisplayNumber.text(row.value("stop_loss_price")))
        detail("委托仓位", DisplayNumber.text(row.value("position_amount")) + "U")
        detail(
          "已成交",
          DisplayNumber.text(row.value("filled_amount", fallback: row.value("filled_size"))) + "/"
            + DisplayNumber.text(row.value("position_amount")) + "U")
      }
      Rectangle().fill(WebTheme.border).frame(height: 1)
      HStack(spacing: 8) {
        USDTCommandButton(
          title: row["can_chase"]?.flag == true ? "追单" : "已部分成交", action: "limit-chase",
          payload: ["limit_order_id": row["id"] ?? .null], preflight: "chase"
        ) {
          notice = $0
          Task { await reload() }
        }.disabled(row["can_chase"]?.flag != true)
        USDTCommandButton(
          title: "撤单", action: "limit-cancel", payload: ["limit_order_id": row["id"] ?? .null],
          buttonKind: .primary
        ) {
          notice = $0
          Task { await reload() }
        }
      }
    }
  }
}

private struct WebCloseTarget: Codable {
  let positionID: JSONValue
  let key: String
}

private struct WebPositionOperation: Identifiable {
  let id = UUID()
  let position: JSONValue
  let action: String
}

struct USDTCommandButton: View {
  @EnvironmentObject private var store: USDTStore
  let title: String
  let action: String
  let payload: [String: JSONValue]
  var preflight: String? = nil
  var buttonKind: WebButtonStyle.Kind? = nil
  var requiresConfirmation = true
  let completed: (String) -> Void
  @State private var key = UUID().uuidString
  @State private var busy = false
  @State private var confirm = false
  @State private var pending = false
  var body: some View {
    Button(busy ? "处理中…" : pending ? "查询\(title)结果" : title) {
      if requiresConfirmation { confirm = true } else { execute() }
    }
    .buttonStyle(
      WebButtonStyle(
        kind: buttonKind ?? (action == "position-close" ? .danger : .secondary), height: 38,
        fontSize: 14)
    ).disabled(busy)
    .webModal(isPresented: $confirm) {
      WebModal(
        title: action == "limit-chase" ? "市价追单" : action == "limit-cancel" ? "撤销委托" : "确认" + title
      ) {
        Text(
          action == "limit-chase"
            ? "将按当前市价追单，确认继续？" : action == "limit-cancel" ? "确认撤销此限价委托？" : "确认\(title)？"
        ).font(.system(size: 16)).foregroundStyle(WebTheme.secondary)
        HStack(spacing: 12) {
          Button("取消") { confirm = false }.buttonStyle(WebButtonStyle(kind: .secondary, radius: 14))
          Button(title) {
            confirm = false
            execute()
          }.buttonStyle(
            WebButtonStyle(kind: action == "position-close" ? .danger : .primary, radius: 14))
        }
      }
    }
  }
  private func execute() {
    busy = true
    Task {
      defer { busy = false }
      do {
        if let preflight, !pending { try await store.preflight(preflight) }
        pending = true
        let result = try await store.command(action, payload: payload, key: key)
        completed(store.commandMessage(result))
        if ["SUCCEEDED", "FAILED"].contains(result.value("status")) {
          key = UUID().uuidString
          pending = false
        }
      } catch { completed(error.localizedDescription) }
    }
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
        if model.items.isEmpty {
          USDTEmptyState(title: "暂无交易命令", error: model.error) { Task { await load() } }
        }
      }.padding(16)
    }.usdtPage("交易命令").task(id: store.scope) { await load() }.refreshable { await load() }
      .onChange(of: store.liveRevision) { _, _ in Task { await load() } }
  }
  private func load() async { await model.load(store, path: "/api/commands") }
}

private struct USDTPositionControls: View {
  @EnvironmentObject private var store: USDTStore
  @Environment(\.webDismiss) private var dismiss
  let position: JSONValue
  let action: String
  let completed: (String) -> Void
  @State private var price = ""
  @State private var orderType = "market"
  @State private var strategyID = ""
  @State private var key = UUID().uuidString
  @State private var busy = false
  @State private var pending = false
  @State private var notice = ""
  @State private var pendingAction = ""
  @State private var pendingPayload: [String: JSONValue] = [:]
  @State private var strategyScope = ""
  @State private var cancellingStrategy = false
  @State private var logs: JSONValue = .null
  private var running: Bool { position.value("strategy_status") == "1" }
  private var fee: Decimal { abs(position["estimated_total_fee"]?.decimal ?? 0) }
  private var pnl: Decimal { position["pnl"]?.decimal ?? 0 }
  private var subtitle: String {
    position.value("symbol") + " · " + (position.value("side") == "0" ? "多单" : "空单")
  }
  var body: some View {
    Group {
      if action == "strategy" && !running {
        WebStrategyPicker(
          selection: $strategyID, busy: busy, pending: pending, notice: notice
        ) {
          execute("strategy-rebind", extra: ["strategy_id": .string(strategyID)])
        }
      } else {
        WebModal(title: title) {
          if action != "strategyLog" && !(action == "strategy" && running) {
            Text(subtitle).font(.system(size: 14)).foregroundStyle(WebTheme.secondary)
          }
          if action == "takeProfit" {
            VStack(alignment: .leading, spacing: 8) {
              Text("止盈价格").font(.system(size: 14, weight: .medium)).foregroundStyle(
                WebTheme.secondary)
              HStack(spacing: 8) {
                USDTField(
                  title: "", text: $price, numeric: true, placeholder: "请输入止盈价格", radius: 14)
                HStack(spacing: 0) {
                  ForEach([("market", "市价"), ("limit", "限价")], id: \.0) { item, label in
                    Button(label) { orderType = item }.font(.system(size: 12, weight: .semibold))
                      .padding(.horizontal, 12).frame(height: 34).foregroundStyle(
                        orderType == item ? Color.black : WebTheme.muted
                      ).background(orderType == item ? WebTheme.brand : Color.clear, in: Capsule())
                  }
                }.padding(2).background(WebTheme.secondaryButton, in: Capsule()).overlay {
                  Capsule().stroke(WebTheme.border, lineWidth: 1)
                }.fixedSize()
              }
            }
            if position["manual_take_profit_set"]?.flag == true {
              HStack {
                Text("止盈：" + DisplayNumber.text(position.value("manual_take_profit_price"))).font(.system(size: 14))
                  .foregroundStyle(WebTheme.success)
                Spacer()
                Button("取消") { cancelTakeProfit() }.font(.system(size: 12)).foregroundStyle(
                  WebTheme.danger)
              }.padding(16).background(
                WebTheme.success.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
            Button(busy ? "处理中..." : pending ? "查询设置结果" : "确认设置") {
              execute(
                "take-profit",
                extra: ["take_profit_price": .string(price), "order_type": .string(orderType)])
            }.buttonStyle(WebButtonStyle(radius: 14, weight: .semibold)).disabled(
              busy || (Decimal(string: price) ?? 0) <= 0)
          } else if action == "breakEven" {
            VStack(spacing: 8) {
              USDTMetric(title: "当前浮盈", value: DisplayNumber.text(position.value("pnl")) + " USDT")
              USDTMetric(
                title: "预估总手续费", value: "-" + DisplayNumber.text(fee) + " USDT")
            }.padding(.horizontal, 16).padding(.vertical, 12).overlay {
              RoundedRectangle(cornerRadius: 14).stroke(WebTheme.border, lineWidth: 1)
            }
            Button {
              execute("break-even", extra: ["mode": .string("with_fee")])
            } label: {
              VStack(spacing: 2) {
                Text("含手续费保本（净盈亏 0）").font(.system(size: 14, weight: .semibold))
                Text(pnl > 0 ? "止损移至开仓价 ± 手续费对应价位" : "挂止盈单至开仓价 ± 手续费价位，回价自动平仓").font(
                  .system(size: 12)
                ).opacity(0.8)
              }
            }.buttonStyle(WebButtonStyle(height: 64, radius: 14)).disabled(
              busy || (pnl > 0 && pnl <= fee))
            Button {
              execute("break-even", extra: ["mode": .string("without_fee")])
            } label: {
              VStack(spacing: 2) {
                Text("不含手续费保本（净盈亏 -" + DisplayNumber.text(fee) + "）").font(
                  .system(size: 14, weight: .semibold))
                Text(pnl > 0 ? "止损移至开仓价，亏损约等于手续费" : "挂止盈单至开仓价，回到开仓价自动平仓，亏损约等于手续费").font(
                  .system(size: 12)
                ).opacity(0.8)
              }
            }.buttonStyle(WebPositiveActionStyle(height: 64, radius: 14)).disabled(busy)
          } else if action == "strategyLog" || (action == "strategy" && running) {
            ScrollView {
              VStack(alignment: .leading, spacing: 8) {
                Text(
                  "策略名称：" + logs.value("strategy_name", fallback: position.value("strategy_name"))
                ).font(.system(size: 14, weight: .medium))
                ForEach(
                  Array(
                    (logs["strategy_config"]?.rows ?? position["strategy_config"]?.rows ?? [])
                      .enumerated()), id: \.offset
                ) { index, level in
                  Text(WebStrategyText.level(level, index: index)).font(.system(size: 14))
                    .foregroundStyle(WebTheme.secondary)
                }
                Rectangle().fill(WebTheme.border).frame(height: 1).padding(.vertical, 4)
                Text("执行日志：").font(.system(size: 14, weight: .medium))
                if logs == .null {
                  Text("加载中...")
                } else if (logs["logs"]?.rows ?? []).isEmpty {
                  Text("暂未执行任何止损止盈操作")
                }
                ForEach(Array((logs["logs"]?.rows ?? []).enumerated()), id: \.offset) { _, log in
                  Text(
                    (log.value("result", fallback: "").isEmpty
                      ? "" : "[" + log.value("result") + "] ")
                      + log.value("behavior_desc", fallback: "")
                      + (log.value("error", fallback: "").isEmpty
                        ? "" : "（" + log.value("error") + "）")
                  ).font(.system(size: 14)).foregroundStyle(WebTheme.secondary)
                }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.frame(maxHeight: 400).background(
              WebTheme.input, in: RoundedRectangle(cornerRadius: 14))
          } else {
            (Text("预估收益 ")
              + Text(DisplayNumber.text(position.value("pnl")) + " USDT").foregroundColor(
                pnl >= 0 ? WebTheme.success : WebTheme.danger) + Text("，确认平仓？")).font(
                .system(size: 16)
              ).foregroundStyle(WebTheme.secondary)
            HStack(spacing: 12) {
              Button("取消") { dismiss() }.buttonStyle(WebButtonStyle(kind: .secondary, radius: 14))
              Button(busy ? "处理中..." : pending ? "查询结果" : "确认") { execute("position-close") }
                .buttonStyle(WebButtonStyle(radius: 14)).disabled(busy)
            }
          }
          USDTNotice(text: notice)
        }
      }
    }.task {
      strategyScope = store.scope
      price =
        position["manual_take_profit_set"]?.flag == true
        ? position.value("manual_take_profit_price") : ""
      orderType = position.value("manual_take_profit_order_type") == "limit" ? "limit" : "market"
      if action == "strategyLog" || (action == "strategy" && running) {
        do {
          logs = try await store.get(
            "/v1/strategy/log", query: [.init(name: "position_id", value: position.value("id"))])
        } catch {
          notice = error.localizedDescription
          logs = .object([:])
        }
      }
    }
  }
  private var title: String {
    action == "strategyLog" || (action == "strategy" && running)
      ? "策略和执行日志"
      : ["takeProfit": "设置止盈", "breakEven": "设置保本损", "strategy": "止盈止损策略", "close": "立即平仓"][action]
        ?? "持仓"
  }
  private func execute(_ action: String, extra: [String: JSONValue] = [:]) {
    guard !busy else { return }
    let scope = store.scope
    if action == "strategy-rebind" {
      guard scope == strategyScope,
        pending || store.strategies.contains(where: { $0.value("id", fallback: "") == strategyID && !strategyID.isEmpty })
      else { return }
    }
    var payload = extra
    payload["position_id"] = position["id"] ?? .null
    if !pending {
      pendingAction = action
      pendingPayload = payload
    }
    busy = true
    Task {
      defer { busy = false }
      do {
        guard scope == store.scope, !Task.isCancelled else { return }
        pending = true
        let result = try await store.command(pendingAction, payload: pendingPayload, key: key)
        guard scope == store.scope else { return }
        let message = store.commandMessage(result)
        if result.value("status") == "SUCCEEDED" {
          completed(message)
        } else {
          notice = message
          if result.value("status") == "FAILED" {
            key = UUID().uuidString
            pending = false
          }
        }
      } catch {
        guard scope == store.scope, !Task.isCancelled else { return }
        let error = APIError.map(error)
        if error.shouldPresent { notice = error.userMessage }
      }
    }
  }
  private func cancelTakeProfit() {
    // This endpoint cancels only the manual take-profit order; protective stops remain managed by the backend.
    busy = true
    Task {
      defer { busy = false }
      do {
        _ = try await store.send(
          "/v1/position/take-profit", ["position_id": position["id"] ?? .null], method: .delete)
        completed("已取消手动止盈")
      } catch { notice = error.localizedDescription }
    }
  }
}

private struct WebPositiveActionStyle: ButtonStyle {
  var height: CGFloat = 38
  var radius: CGFloat = 10
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 14, weight: .medium)).foregroundStyle(WebTheme.success)
      .frame(maxWidth: .infinity).frame(height: height).background(
        WebTheme.success.opacity(0.1), in: RoundedRectangle(cornerRadius: radius)
      ).overlay {
        RoundedRectangle(cornerRadius: radius).stroke(WebTheme.success.opacity(0.3), lineWidth: 1)
      }.contentShape(Rectangle()).opacity(enabled ? configuration.isPressed ? 0.8 : 1 : 0.5)
  }
}
private struct WebPositionStrategyStyle: ButtonStyle {
  let running: Bool
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 14, weight: .medium)).foregroundStyle(
      running ? WebTheme.success : WebTheme.text
    ).frame(maxWidth: .infinity).frame(height: 38)
      .background(
        running ? WebTheme.success.opacity(0.1) : WebTheme.secondaryButton,
        in: RoundedRectangle(cornerRadius: 10)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 10).stroke(
          running ? WebTheme.success.opacity(0.3) : WebTheme.border, lineWidth: 1)
      }.contentShape(Rectangle()).opacity(enabled ? configuration.isPressed ? 0.8 : 1 : 0.5)
  }
}
