import SwiftUI

/// Confirmed fees retain their source value; unconfirmed entry fees stay explicitly estimated.
enum PositionEntryFeePresentation {
  static let singleSideRate = Decimal(5) / Decimal(10_000)

  static func text(_ row: JSONValue, abbreviatedUnit: Bool = false) -> String {
    if let actual = confirmedFee(row) {
      let unit = abbreviatedUnit && actual.asset == "USDT" ? "U" : actual.asset
      return DisplayNumber.amount(actual.value, maximumFractionDigits: 2) + " " + unit
    }
    guard let estimate = estimatedEntryFee(row) else { return "待核对" }
    return "估 " + DisplayNumber.amount(-estimate, maximumFractionDigits: 2)
      + (abbreviatedUnit ? " U" : " USDT")
  }

  static func confirmedFee(_ row: JSONValue) -> (value: Decimal, asset: String)? {
    guard row.value("entry_fee_status") == "confirmed",
      let fee = finiteDecimal(row["entry_realized_fee"]) else { return nil }
    let rawAsset = row.value("entry_fee_asset", fallback: "USDT")
      .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let asset = rawAsset.isEmpty ? (fee == 0 ? "USDT" : "费用币种待核对") : rawAsset
    return (fee, asset)
  }

  static func estimatedEntryFee(_ row: JSONValue) -> Decimal? {
    if let total = finiteDecimal(row["estimated_total_fee"]), total != 0 {
      return abs(total) / 2
    }
    guard let price = finiteDecimal(row["open_price"]), price > 0,
      let quantity = finiteDecimal(row["size"]), quantity > 0 else { return nil }
    return price * quantity * singleSideRate
  }

  static func finiteDecimal(_ value: JSONValue?) -> Decimal? {
    guard let value else { return nil }
    let source = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard source.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
      options: .regularExpression) != nil,
      let number = Decimal(string: source, locale: Locale(identifier: "en_US_POSIX")),
      !number.isNaN else { return nil }
    return number
  }
}

enum PositionCardPresentation {
  static func leverageText(_ row: JSONValue) -> String? {
    guard let leverage = PositionEntryFeePresentation.finiteDecimal(row["leverage"]), leverage > 1 else {
      return nil
    }
    var value = DisplayNumber.text(leverage)
    if let separator = value.firstIndex(of: ".") {
      let fractionStart = value.index(after: separator)
      let integer = String(value[..<separator])
      var fraction = String(value[fractionStart...])
      while fraction.last == "0" { fraction.removeLast() }
      value = fraction.isEmpty ? integer : integer + "." + fraction
    }
    return "x" + value
  }

  static func strategyErrorText(_ row: JSONValue) -> String {
    let message = row.value("latest_strategy_error", fallback: "").trimmingCharacters(in: .whitespacesAndNewlines)
    // Older responses can put a successful binding audit entry in this field.
    // Keep it in the execution log, without repeating it as a card warning.
    let prefixes = ["开仓绑定策略", "限价成交绑定策略"]
    if prefixes.contains(where: { message.hasPrefix($0 + "：") || message.hasPrefix($0 + ":") }) { return "" }
    return message
  }

  static func feeText(_ row: JSONValue, currentPrice: Decimal? = nil) -> String {
    let entry = PositionEntryFeePresentation.text(row, abbreviatedUnit: true)
    guard let total = estimatedTotalFee(row, currentPrice: currentPrice) else {
      return entry + "（估总待核对）"
    }
    return entry + "（估总 " + DisplayNumber.amount(-total, maximumFractionDigits: 2) + " U）"
  }

  static func profitText(_ profit: Decimal?) -> String {
    guard let profit, !profit.isNaN else { return "--" }
    return DisplayNumber.amount(profit, maximumFractionDigits: 2) + " U"
  }

  static func takeProfitText(_ row: JSONValue) -> String {
    let price = DisplayNumber.text(row.value("manual_take_profit_price"))
    guard row["manual_take_profit_set"]?.flag == true, price != "--" else { return "未设置" }
    // A limit take-profit already communicates its exit price; the projected amount is
    // requested for the market-triggered path, whose price is only an activation price.
    guard row.value("manual_take_profit_order_type") != "limit",
      let profit = takeProfitProfit(row) else { return price }
    return price + "（" + DisplayNumber.amount(profit, maximumFractionDigits: 2, signed: true) + " U）"
  }

  private static func takeProfitProfit(_ row: JSONValue) -> Decimal? {
    if let reported = PositionEntryFeePresentation.finiteDecimal(row["manual_take_profit_pnl"]) {
      return reported
    }
    guard let target = PositionEntryFeePresentation.finiteDecimal(row["manual_take_profit_price"]), target > 0,
      let entry = PositionEntryFeePresentation.finiteDecimal(row["open_price"]), entry > 0,
      let quantity = PositionEntryFeePresentation.finiteDecimal(row["exchange_size"] ?? row["size"]),
      quantity > 0 else { return nil }
    return (row.value("side") == "0" ? target - entry : entry - target) * quantity
  }

  private static func estimatedTotalFee(_ row: JSONValue, currentPrice: Decimal?) -> Decimal? {
    guard row["has_manual_addition"]?.flag != true,
      let original = PositionEntryFeePresentation.finiteDecimal(row["size"]), original > 0,
      let remaining = PositionEntryFeePresentation.finiteDecimal(row["exchange_size"] ?? row["size"]),
      remaining >= 0, remaining <= original,
      let entryPrice = PositionEntryFeePresentation.finiteDecimal(row["open_price"]), entryPrice > 0 else { return nil }
    let entry: Decimal
    if let actual = PositionEntryFeePresentation.confirmedFee(row) {
      // An unconverted BNB/mixed-asset commission cannot be added to a U estimate.
      guard actual.asset == "USDT" || actual.value == 0 else { return nil }
      entry = abs(actual.value)
    } else {
      guard let estimate = PositionEntryFeePresentation.estimatedEntryFee(row) else { return nil }
      entry = estimate
    }
    let remainingExit: Decimal
    if remaining == 0 {
      remainingExit = 0
    } else {
      guard let price = currentPrice ?? PositionEntryFeePresentation.finiteDecimal(row["current_price"]),
        !price.isNaN, price > 0 else { return nil }
      remainingExit = remaining * price * PositionEntryFeePresentation.singleSideRate
    }
    // The API exposes no realized partial-close commission. Keep this component
    // estimated at the entry notional instead of inventing an actual zero.
    let closedExit = (original - remaining) * entryPrice * PositionEntryFeePresentation.singleSideRate
    let total = entry + closedExit + remainingExit
    return total.isNaN ? nil : total
  }
}

/// List reads never reconcile or mutate an order. Actions retain the source identity.
struct OrderCardPresentation {
  let row: JSONValue

  var recordKey: String { row.value("record_key", fallback: row.value("id")) }
  var kindText: String {
    switch row.value("order_kind") {
    case "maker": return "Maker"
    case "limit": return "限价"
    default: return "委托"
    }
  }
  var canCancel: Bool { row["can_cancel"]?.flag == true && operationIdentity != nil }
  var canChase: Bool {
    row.value("order_kind") == "limit" && row["can_chase"]?.flag == true && operationIdentity != nil
  }
  var cancelAction: String { row.value("order_kind") == "maker" ? "maker-fallback" : "limit-cancel" }
  var cancelPayload: [String: JSONValue]? { canCancel ? operationIdentity : nil }
  var chasePayload: [String: JSONValue]? { canChase ? operationIdentity : nil }
  var orderAmountText: String { money(row["position_amount"]) }
  var filledAmountText: String { money(row["filled_amount"]) }
  var filledQuantityText: String {
    let filled = quantity(row["filled_size"])
    let total = quantity(row["size"])
    let explicit = row.value("base_asset", fallback: "").trimmingCharacters(in: .whitespacesAndNewlines)
    let symbol = row.value("symbol", fallback: "")
    let suffix = ["USDT", "USDC"].first(where: { symbol.hasSuffix($0) })
    let asset = explicit.isEmpty ? suffix.map { String(symbol.dropLast($0.count)) } ?? "" : explicit
    return filled + " / " + total + (asset.isEmpty ? "" : " " + asset)
  }
  var averagePriceText: String {
    guard let filled = nonnegative(row["filled_size"]), filled > 0,
      let price = nonnegative(row["average_price"]), price > 0 else { return "--" }
    return DisplayNumber.text(price)
  }

  private var operationIdentity: [String: JSONValue]? {
    // Unknown, terminal, and incomplete states remain visible without mutation controls.
    guard nonnegative(row["status"]) == 0 else { return nil }
    switch row.value("order_kind") {
    case "maker":
      guard case let .string(requestID) = row["client_request_id"],
        !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      return ["client_request_id": .string(requestID), "cancel_only": .bool(true)]
    case "limit":
      guard case let .number(sourceID) = row["source_id"], sourceID.isFinite,
        sourceID > 0, sourceID.rounded() == sourceID, sourceID <= 9_007_199_254_740_991 else { return nil }
      return ["limit_order_id": .number(sourceID)]
    default: return nil
    }
  }
  private func nonnegative(_ value: JSONValue?) -> Decimal? {
    guard let number = PositionEntryFeePresentation.finiteDecimal(value), number >= 0 else { return nil }
    return number
  }
  private func quantity(_ value: JSONValue?) -> String {
    nonnegative(value).map { NSDecimalNumber(decimal: $0).stringValue } ?? "--"
  }
  private func money(_ value: JSONValue?) -> String {
    nonnegative(value).map { DisplayNumber.amount($0, maximumFractionDigits: 2) + "U" } ?? "--"
  }
}

enum PositionPage: String, Hashable { case positions, limits, history }

/// A fresh identity also routes repeated requests to a retained page correctly.
struct PositionPageRequest: Identifiable, Hashable {
  let id = UUID()
  let page: PositionPage
}

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
  @State private var entryNeedsReconcile = false
  @State private var entryCommandID = ""
  @State private var confirmedLimitDraft: USDTEntryDraft?
  var initialStop: String = ""
  var initialLimit: String = ""
  var chartInput: ChartTradeInput? = nil
  var onChartOrderTypeChange: ((String) -> Void)? = nil
  var onChartLimitSubmission: ((USDTEntryDraft?) -> Void)? = nil
  var chartHasPosition = false
  var chartPositionsReady = true
  var chartPositionsError = ""
  var chartPositionRows: [JSONValue] = []
  @State private var heldPositionID = ""
  var onShowPositions: ((PositionPage) -> Void)? = nil
  @StateObject private var positions = USDTChartPositionsModel()
  @State private var positionDestination: PositionPageRequest?
  @State private var confirmationDraft: USDTEntryDraft?
  @State private var confirmationScope = ""
  @AppStorage(ChartOrderExecutionPreferences.marketEntryMaker) private var marketEntryMaker = false
  @State private var openSuccess = false
  @State private var successDraft: USDTEntryDraft?
  private var symbol: String { chartInput?.symbol ?? store.selectedSymbol }
  private var hasPosition: Bool {
    chartInput != nil ? chartHasPosition : !positions.positions(for: symbol, scope: store.scope).isEmpty
  }
  private var positionsReady: Bool {
    chartInput != nil ? chartPositionsReady : positions.isReady(scope: store.scope)
  }
  private var entryDisabled: Bool {
    if entryNeedsReconcile {
      return busy || !store.isBound || entryCommandID.isEmpty
    }
    return !hasPosition && confirmedLimitDraft == nil
      && (busy || submitted || !store.isBound || !inputValid || !strategyValid || !positionsReady)
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
        if holding {
          confirm = false; confirmationDraft = nil
          confirmedLimitDraft = nil
          onChartLimitSubmission?(nil)
        }
      }
      .onChange(of: store.scope) { _, _ in
        confirmationDraft = nil; confirm = false; openSuccess = false; submitted = false
        entryNeedsReconcile = false; entryCommandID = ""
        confirmedLimitDraft = nil
        onChartLimitSubmission?(nil)
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
      .navigationDestination(item: $positionDestination) { destination in
        USDTPositionsView(navigationRequest: destination)
      }
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
              if draft.orderType == "market" && marketEntryMaker {
                submitMaker(draft)
              } else {
                submit(draft)
              }
            }.buttonStyle(WebButtonStyle(radius: 14, weight: .bold))
          }
        }
      }
      .webModal(isPresented: $openSuccess, motion: .fade) {
        WebModal(title: "开仓成功") {
          VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 42)).foregroundStyle(WebTheme.success)
            Text(successDraft?.symbol ?? symbol).font(.system(size: 18, weight: .bold))
            Text("交易所已确认成交，持仓保护已进入系统管理。")
              .font(.system(size: 13)).foregroundStyle(WebTheme.secondary)
              .multilineTextAlignment(.center)
          }
          HStack(spacing: 12) {
            Button("关闭") { openSuccess = false }
              .buttonStyle(WebButtonStyle(kind: .secondary, radius: 14))
            Button("查看持仓") {
              openSuccess = false
              showPositionPage(.positions)
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
    if confirmedLimitDraft != nil { return "已挂单" }
    if store.isBound && !positionsReady { return "正在确认持仓…" }
    if entryNeedsReconcile { return "核对开仓结果" }
    if submitted { return "已提交" }
    if busy { return "处理中…" }
    if !strategyValid { return "请选择止盈方式" }
    if !inputValid { return chartInput != nil ? "在 K 线图上选择止损价开仓"
      : orderType == "market" ? "输入止损价开仓" : "输入止损价/限价开仓" }
    let action = chartInput != nil
      ? (isLong ? "开多" : "开空")
      : (orderType == "market" ? "市价开" : "限价开") + (isLong ? "多" : "空")
    return orderType == "market" && marketEntryMaker ? action + "（只做 Maker）" : action
  }

  private var takeProfitSelectionText: String {
    if hasPosition { return heldTakeProfit }
    if !strategyEnabled { return "手动止盈" }
    return store.strategies.first { $0.value("id") == strategyID }?.value("name", fallback: "选择止盈方式") ?? "选择止盈方式"
  }
  private var takeProfitSelectionLabel: some View {
    HStack(spacing: 4) {
      Text(takeProfitSelectionText).font(.system(size: 16, weight: .semibold))
        .lineLimit(1).truncationMode(.tail).underline(!hasPosition)
      if !hasPosition {
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
      }
    }.foregroundStyle(strategyValid || hasPosition ? WebTheme.text : WebTheme.danger)
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
  private func showPositionPage(_ page: PositionPage) {
    if let onShowPositions { onShowPositions(page) }
    else { positionDestination = PositionPageRequest(page: page) }
  }
  private func advanceEntry() {
    if hasPosition {
      showPositionPage(.positions)
      return
    }
    if confirmedLimitDraft != nil {
      showPositionPage(.limits)
      return
    }
    if entryNeedsReconcile {
      reconcileEntry()
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
    // Freeze the confirmed price intent before dispatch, including unknown
    // outcomes. Chart dragging must never appear to amend a submitted order.
    if draft.orderType == "limit" { onChartLimitSubmission?(draft) }
    Task {
      defer { busy = false }
      do {
        let result = try await store.command(
          draft.orderType == "limit" ? "limit-create" : "open", payload: payload, key: key)
        guard scope == store.scope else { return }
        entryCommandID = result.value("id")
        let status = result.value("status")
        if status == "SUCCEEDED" && draft.orderType == "limit" && !hasPosition {
          // Only an acknowledged limit-create becomes a clickable pending order.
          confirmedLimitDraft = draft
        } else if status == "FAILED" {
          submitted = false
          entryNeedsReconcile = false
          requestIdentity = UUID().uuidString
          if draft.orderType == "limit" { onChartLimitSubmission?(nil) }
        }
        if status == "UNKNOWN" {
          entryNeedsReconcile = true
          container.toastCenter.error(store.commandMessage(result))
          return
        }
        if status == "SUCCEEDED" && draft.orderType == "market" {
          // This dialog is shown only after the backend has confirmed the
          // exchange fill and adopted the position locally.
          successDraft = draft
          openSuccess = true
        } else {
          container.toastCenter.present(store.commandMessage(result),
            style: status == "SUCCEEDED" ? .success : status == "FAILED" ? .error : .warning,
            duration: status == "SUCCEEDED" ? 1.5 : 4)
        }
      } catch { if scope == store.scope { presentEntryError(error, suffix: "。请先核对命令记录。") } }
    }
  }

  private func makerData(_ result: JSONValue) -> JSONValue? {
    result["result"]?["data"]
  }

  private func submitMaker(_ draft: USDTEntryDraft) {
    // Maker uses durable backend commands; this view never calls Binance directly.
    guard !hasPosition, positionsReady else { return }
    let scope = store.scope
    let key = requestIdentity
    var payload = draft.payload()
    payload["execution_mode"] = .string("maker")
    busy = true
    submitted = true
    Task {
      defer { busy = false }
      do {
        let result = try await store.command("open", payload: payload, key: key)
        guard scope == store.scope else { return }
        entryCommandID = result.value("id")
        if result.value("status") == "UNKNOWN" {
          entryNeedsReconcile = true
          container.toastCenter.error(store.commandMessage(result))
          return
        }
        if result.value("status") == "SUCCEEDED", let data = makerData(result) {
          let state = data.value("state")
          if state == "PENDING_MAKER" {
            entryNeedsReconcile = false
            showPositionPage(.limits)
          } else if state == "SUCCEEDED" {
            entryNeedsReconcile = false
            successDraft = draft
            openSuccess = true
          } else {
            entryNeedsReconcile = true
            container.toastCenter.error(store.commandMessage(result))
          }
        } else {
          container.toastCenter.error(store.commandMessage(result))
          submitted = false
          entryNeedsReconcile = false
          requestIdentity = UUID().uuidString
        }
      } catch {
        if scope == store.scope { submitted = false; presentEntryError(error, suffix: "。请先核对命令记录。") }
      }
    }
  }

  private func reconcileEntry() {
    guard !busy, !entryCommandID.isEmpty, store.isBound else { return }
    let scope = store.scope
    let originalCommandID = entryCommandID
    busy = true
    Task {
      defer { busy = false }
      do {
        let result = try await store.command(
          "entry-status",
          payload: ["client_request_id": .string(originalCommandID)],
          key: "entry-status-" + originalCommandID + "-" + UUID().uuidString
        )
        guard scope == store.scope else { return }
        let data = result["result"]?["data"]
        let state = data?.value("state") ?? "UNKNOWN"
        if state == "SUCCEEDED" {
          entryNeedsReconcile = false
          submitted = true
          if data?.value("position_id") != "" {
            openSuccess = true
          } else {
            showPositionPage(.limits)
          }
        } else if ["PENDING_MAKER", "PENDING_LIMIT"].contains(state) {
          entryNeedsReconcile = false
          submitted = true
          showPositionPage(.limits)
        } else if ["FAILED", "CANCELLED", "EXPIRED", "REJECTED"].contains(state) {
          entryNeedsReconcile = false
          submitted = false
          requestIdentity = UUID().uuidString
          container.toastCenter.error(store.commandMessage(result))
        } else {
          entryNeedsReconcile = true
          container.toastCenter.error(store.commandMessage(result))
        }
      } catch {
        if scope == store.scope { container.toastCenter.error(APIError.map(error).userMessage) }
      }
    }
  }

  private var heldRow: JSONValue? {
    chartPositionRows.first { $0.value("id") == heldPositionID } ?? chartPositionRows.first
  }
  private func heldAmount(_ key: String, unit: String = "", maximumFractionDigits: Int? = nil) -> String {
    guard let amount = heldRow?[key]?.decimal, !amount.isNaN else { return "-" }
    if let maximumFractionDigits {
      return DisplayNumber.amount(amount, maximumFractionDigits: maximumFractionDigits) + unit
    }
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
    return PositionEntryFeePresentation.text(row, abbreviatedUnit: true)
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
              chartMetricValue("止损金额", heldAmount("stop_loss_amount", unit: " U", maximumFractionDigits: 1))
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
            if hasPosition {
              takeProfitSelectionLabel
                .accessibilityIdentifier("chart-ticket.strategy")
            } else {
              NavigationLink {
                USDTStrategiesView(returnAfterSelection: true, onSelection: selectStrategy)
              } label: {
                takeProfitSelectionLabel
              }.buttonStyle(.plain).disabled(busy || submitted || confirm)
                .accessibilityIdentifier("chart-ticket.strategy")
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }.monospacedDigit().padding(.horizontal, 10).padding(.vertical, 12)
        .background(WebTheme.color(0xF3F5F7, 0x202731), in: RoundedRectangle(cornerRadius: 10))
      HStack(spacing: 12) {
        WebOrderTypeSelector(selection: Binding(get: { orderType }, set: { value in
          orderType = value; onChartOrderTypeChange?(value)
        })).frame(width: 112).accessibilityIdentifier("chart-ticket.order-type")
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
  var feeText: String { DisplayNumber.amount(positionEstimate * Self.feeRate, maximumFractionDigits: 2) }
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

struct PositionLiveButtonLabel: View {
  let isActive: Bool

  var body: some View {
    VStack(spacing: 1) {
      Image(systemName: "waveform.path.ecg").font(.system(size: 17, weight: .medium))
      Text("live").font(.system(size: 9, weight: .semibold))
    }
    .foregroundStyle(isActive ? BinanceTheme.accent : WebTheme.secondary)
  }
}

struct USDTPositionsView: View {
  var isVisible = true
  var onOpenChart: ((String, String) -> Void)? = nil
  var navigationRequest: PositionPageRequest? = nil
  @EnvironmentObject private var store: USDTStore
  @EnvironmentObject private var dashboard: DashboardViewModel
  @EnvironmentObject private var liveActivity: PositionLiveActivityController
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage(FloatingPositionsPreferences.enabledKey, store: FloatingPositionsPreferences.defaults)
  private var floatingPositions = false
  @StateObject private var limitsModel = USDTPageModel()
  @StateObject private var historyModel = USDTPageModel()
  @StateObject private var margin = PositionMarginModel()
  @State private var marginDetails = false
  private func pageModel(_ page: String) -> USDTPageModel { page == "limits" ? limitsModel : historyModel }
  private var model: USDTPageModel { pageModel(segment) }
  private var liveQuotes: PositionLiveQuotes { store.positionQuotes }
  private var snapshots: FloatingPositionsModel { store.positionSnapshots }
  private var rows: [JSONValue] {
    snapshots.scope == store.scope ? snapshots.rows : []
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
  private var positionSymbols: [String] {
    guard isVisible, store.isBound, segment == "positions", scenePhase == .active, !chart else { return [] }
    return Array(Set(rows.map { $0.value("symbol", fallback: "").uppercased() }
      .filter { !$0.isEmpty })).sorted()
  }
  private var pagingEnabled: Bool {
    isVisible && scenePhase == .active && !chart && !binding && !marginDetails
      && !closeAllConfirm && operation == nil
  }
  var body: some View {
    PositionNativePager(selection: $segment, enabled: pagingEnabled, headerHeight: WebTheme.rootHeaderHeight,
      header: { pageHeader }, page: { pageContent($0) })
      .id(store.scope + ":" + String(store.isBound))
      .background(alignment: .top) {
        // The pager's UIKit header host deliberately ignores safe areas. Paint
        // this strip in the outer SwiftUI context so it reaches the status bar.
        WebTheme.surface.frame(height: WebTheme.rootHeaderHeight)
          .background(WebTheme.surface.ignoresSafeArea(edges: .top))
      }
      .usdtPage("持仓")
      .onChange(of: navigationRequest, initial: true) { _, request in
        if let request { segment = request.page.rawValue }
      }
      .task(id: "margin:\(store.scope):\(store.isBound):\(isVisible):\(scenePhase):\(chart)") {
        guard isVisible, scenePhase == .active, !chart, store.isBound else {
          margin.suspend()
          return
        }
        await margin.monitor(store)
      }
      .webModal(isPresented: $marginDetails, motion: .fade) { PositionMarginDetails(model: margin) }
      .task(id: "quotes:\(store.scope):\(store.isBound):\(positionSymbols.joined(separator: ","))") {
        guard store.isBound else {
          dashboard.trackPositionTickerSymbols([], owner: "positions")
          return
        }
        let symbols = positionSymbols
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
        if modelScope != store.scope {
          limitsModel.reset(); historyModel.reset(); modelScope = store.scope; notice = ""
        }
        guard store.isBound else { limitsModel.reset(); historyModel.reset(); return }
        guard isVisible, scenePhase == .active, !chart else { return }
        if segment != "positions" { model.page = 1 }
        let scope = store.scope
        let requestedSegment = segment
        let requestedFilter = filter
        // Keep an initial read alive across tab visibility changes.
        await Task { @MainActor in
          guard scope == store.scope, requestedSegment == segment, requestedFilter == filter else { return }
          await reload(page: requestedSegment, reuseIfLoaded: true)
        }.value
      }
      .onChange(of: store.positionDataRevision) { _, _ in
        if isVisible, scenePhase == .active, !chart {
          Task {
            async let marginRefresh: Void = margin.refresh(store, afterChange: true)
            await store.refreshPositions()
            await marginRefresh
          }
        }
      }
      .onChange(of: store.liveRevision) { _, _ in
        if isVisible, scenePhase == .active, !chart, segment == "limits" {
          model.page = 1
          Task { await reload() }
        }
      }
      .onChange(of: scenePhase) { old, phase in
        guard old != .active, phase == .active, isVisible, store.isBound else { return }
        if segment != "positions" { model.page = 1 }
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
      .webModal(item: $operation, motion: .fade) { operation in
        USDTPositionControls(position: operation.position, action: operation.action) {
          completePositionOperation($0)
        }
      }
      .onChange(of: store.scope) { _, _ in
        operation = nil; marginDetails = false
      }
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
  private var pageHeader: some View {
      HStack(spacing: 4) {
        WebTabs(
          tabs: [("positions", "持仓"), ("limits", "委托"), ("history", "历史仓位")], selection: $segment, compact: true)
          .frame(maxWidth: 248).frame(height: 44)
          .padding(.leading, 12)
        Spacer(minLength: 0)
        PositionMarginBadge(model: margin, scope: store.scope, exposure: margin.exposure(in: store)) {
          marginDetails = true
          Task { await margin.refresh(store, afterChange: true) }
        }
        Button { liveActivity.toggle(store: store, container: container) } label: {
          PositionLiveButtonLabel(isActive: liveActivity.isActive)
            .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("positions.liveActivity")
          .accessibilityLabel("live 持仓实时活动")
          .accessibilityValue(liveActivity.isStarting || liveActivity.isRegistering
            ? "正在启动" : liveActivity.isActive ? "已开启" : "未开启")
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
  }
  private func pageContent(_ page: String) -> some View {
    let model = pageModel(page)
    let pageRows = page == "positions" ? rows : (modelScope == store.scope ? model.items : [])
    let loading = page == "positions" ? snapshots.loading : model.loading
    let refreshing = page != "positions" && model.refreshing
    let loadError = page == "positions" ? (snapshots.failed ? "持仓更新失败，请稍后重试" : "") : model.error
    let awaitingFirstRead = page != "positions" && model.value == .null && loadError.isEmpty
    return
      GeometryReader { geometry in
      WebRefreshScrollView(isActive: isVisible && scenePhase == .active && segment == page) {
        LazyVStack(spacing: 10) {
          if page == "history" && store.isBound {
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
            if !pageRows.isEmpty { USDTNotice(text: loadError) }
            if (loading || awaitingFirstRead) && pageRows.isEmpty {
              Text("加载中...").font(.system(size: 16)).foregroundStyle(WebTheme.muted).frame(
                maxWidth: .infinity
              ).padding(.vertical, 48)
            }
            if !loading && !awaitingFirstRead && !refreshing && pageRows.isEmpty {
              USDTEmptyState(
                title: page == "positions" ? "暂无持仓" : page == "limits" ? "暂无委托" : "暂无历史仓位记录",
                error: loadError
              ) { Task { await reload(page: page) } }
            }
            ForEach(Array(pageRows.enumerated()), id: \.offset) { _, row in
              if page == "positions" {
                positionCard(row)
              } else if page == "limits" {
                orderCard(row)
              } else {
                historyCard(row)
              }
            }
            if page == "positions", pageRows.count > 1 || !closeQueue.isEmpty { closeAllBar }
            if page != "positions", model.hasNext {
              Button("加载更多") {
                model.page += 1
                Task { await reload(page: page, append: true) }
              }.buttonStyle(WebButtonStyle(kind: .secondary, fontSize: 14))
                .disabled(loading || refreshing)
            }
          }
        }.frame(minHeight: !store.isBound ? max(0, geometry.size.height - 32) : nil)
          .padding(16).frame(maxWidth: 448).frame(maxWidth: .infinity)
      }.scrollIndicators(.hidden).scrollBounceBehavior(.always)
        .accessibilityIdentifier(segment == page ? "positions.list" : "positions.list." + page)
        .webRefreshable {
          let scope = store.scope
          let refreshSegment = page
          let refreshFilter = filter
          // Account publication can cancel SwiftUI's refresh action. Keep this
          // read independent, then recheck the selected account and page.
          if page == "positions" {
            // Pull-to-refresh on the positions page only needs the position and
            // margin snapshots. Refreshing profile, strategies, and account
            // here causes the whole card tree to re-evaluate while the finger
            // is returning, which produces the visible flash and hitch.
            async let positionsRefresh: Void = reload(page: page)
            async let marginRefresh: Void = margin.refresh(store, afterChange: true)
            await positionsRefresh
            await marginRefresh
            return
          }
          await Task { @MainActor in
            await store.refresh()
            guard scope == store.scope, refreshSegment == segment, refreshFilter == filter else { return }
            if page != "positions" { model.page = 1 }
            async let marginRefresh: Void = margin.refresh(store, afterChange: true)
            await reload(page: page)
            await marginRefresh
          }.value
        }
      }
      .accessibilityHidden(segment != page)
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
  private func reload(page: String? = nil, append: Bool = false, reuseIfLoaded: Bool = false) async {
    let page = page ?? segment
    let model = pageModel(page)
    guard store.isBound else {
      model.reset()
      return
    }
    if page == "positions" {
      if reuseIfLoaded, snapshots.scope == store.scope, snapshots.hasLoaded, !snapshots.failed,
        let date = snapshots.updatedAt, Date().timeIntervalSince(date) < 3 { return }
      await store.refreshPositions()
      return
    }
    let path = page == "limits" ? "/v1/trade/order/list" : "/v1/position/history"
    await model.load(
      store, path: path,
      query: [
        .init(name: "filter", value: page == "history" ? filter : "all"), .init(name: "page", value: String(model.page)),
        .init(name: "page_size", value: "20"),
      ], append: append, snapshotFirst: page == "history" && !append, reuseIfLoaded: reuseIfLoaded)
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
        if let leverage = PositionCardPresentation.leverageText(row) {
          Text(leverage).font(.system(size: 14)).foregroundStyle(WebTheme.muted)
        }
        Text("止损\(row["stop_loss_amount"]?.decimal.map { DisplayNumber.amount($0, maximumFractionDigits: 1) } ?? "--")U").font(.system(size: 12)).foregroundStyle(
          WebTheme.brand
        ).padding(.horizontal, 6).padding(.vertical, 2).background(
          WebTheme.brand.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        Spacer(minLength: 0)
        Button {
          openChart(row, valuation: valuation)
        } label: {
          PositionCandlestickIcon()
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
            "持仓盈亏：", PositionCardPresentation.profitText(valuation?.profit),
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
            PositionCardPresentation.takeProfitText(row),
            expands: false)
          Button("设置") { show("takeProfit", row) }.font(.system(size: 12)).foregroundStyle(
            WebTheme.brand
          ).padding(.horizontal, 8).padding(.vertical, 2).background(
            WebTheme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
          Spacer(minLength: 0)
        }
        HStack(spacing: 4) {
          Text("手续费：").foregroundStyle(WebTheme.muted)
          Text(PositionCardPresentation.feeText(row, currentPrice: valuation?.price)).foregroundStyle(WebTheme.danger)
        }.font(.system(size: 14))
        Text(
          (row.value("position_origin") == "exchange_external" ? "接管时间：" : "开仓时间：")
            + WebFormat.time(
              row.value("created_at", fallback: row.value("opened_at")),
              format: "yyyy-MM-dd HH:mm:ss")
        ).font(.system(size: 14)).foregroundStyle(WebTheme.muted)
        if !PositionCardPresentation.strategyErrorText(row).isEmpty {
          Text(PositionCardPresentation.strategyErrorText(row)).font(.system(size: 14)).foregroundStyle(
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
    }.accessibilityElement(children: .contain)
      .accessibilityIdentifier("position.card." + row.value("id"))
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
    Task {
      async let marginRefresh: Void = margin.refresh(store, afterChange: true)
      await reload()
      await marginRefresh
    }
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
  private func orderCard(_ row: JSONValue) -> some View {
    let order = OrderCardPresentation(row: row)
    return USDTCard(radius: 14, padding: 14, spacing: 14) {
      HStack(spacing: 8) {
        WebDirection(long: row.value("side") == "0")
        Text(row.value("symbol")).font(.system(size: 16, weight: .medium))
        Spacer(minLength: 0)
        WebBadge(text: row.value("status_text", fallback: "待核对"))
      }
      HStack(spacing: 8) {
        WebBadge(text: order.kindText)
        Text("x" + row.value("leverage")).font(.system(size: 13)).foregroundStyle(WebTheme.muted)
        WebBadge(text: "止损" + DisplayNumber.text(row.value("stop_loss_amount")) + "U")
        Spacer(minLength: 0)
      }
      LazyVGrid(
        columns: [
          GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading),
        ], alignment: .leading, spacing: 12
      ) {
        detail("委托价", DisplayNumber.text(row.value("limit_price")))
        detail("止损价", DisplayNumber.text(row.value("stop_loss_price")))
        detail("委托金额", order.orderAmountText)
        detail("成交金额", order.filledAmountText)
        detail("成交数量", order.filledQuantityText)
        detail("成交均价", order.averagePriceText)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("委托时间  " + WebFormat.time(row.value("created_at"), format: "yyyy-MM-dd HH:mm:ss"))
        if let filledAt = row["filled_at"], filledAt != .null, !filledAt.text.isEmpty {
          Text("成交时间  " + WebFormat.time(filledAt.text, format: "yyyy-MM-dd HH:mm:ss"))
        }
      }.font(.system(size: 12)).foregroundStyle(WebTheme.muted)
      if order.canChase || order.canCancel {
        Rectangle().fill(WebTheme.border).frame(height: 1)
        HStack(spacing: 8) {
          if let payload = order.chasePayload {
            USDTCommandButton(title: "追单", action: "limit-chase", payload: payload, preflight: "chase") {
              notice = $0
              Task { await reload() }
            }
          }
          if let payload = order.cancelPayload {
            USDTCommandButton(title: "撤单", action: order.cancelAction, payload: payload, buttonKind: .primary) {
              notice = $0
              Task { await reload() }
            }
          }
        }
      }
    }.accessibilityElement(children: .contain).accessibilityIdentifier("orders.card." + order.recordKey)
      .id(store.scope + ":" + order.recordKey)
  }
}

private struct WebCloseTarget: Codable {
  let positionID: JSONValue
  let key: String
}

private struct PositionCandlestickIcon: View {
  var body: some View {
    HStack(spacing: 4) {
      candle(color: WebTheme.success, bodyOffset: 2)
      candle(color: WebTheme.danger, bodyOffset: -3)
    }
    .frame(width: 20, height: 20)
    .accessibilityHidden(true)
  }

  private func candle(color: Color, bodyOffset: CGFloat) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 0.5).fill(color).frame(width: 1.4, height: 18)
      RoundedRectangle(cornerRadius: 0.6).fill(color).frame(width: 6, height: 9)
        .offset(y: bodyOffset)
    }
    .frame(width: 6, height: 20)
  }
}

struct WebPositionOperation: Identifiable {
  let id = UUID()
  let position: JSONValue
  let action: String
  var usesNativeSheet: Bool { false }
}

struct USDTCommandButton: View {
  @EnvironmentObject private var store: USDTStore
  @EnvironmentObject private var container: AppContainer
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
  private var makerCancel: Bool { action == "maker-fallback" && payload["cancel_only"]?.flag == true }
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
        title: action == "limit-chase" ? "市价追单" : action == "limit-cancel" || makerCancel ? "撤销委托" : "确认" + title
      ) {
        Text(
          action == "limit-chase"
            ? "将按当前市价追单，确认继续？" : makerCancel ? "确认撤销此 Maker 委托？"
              : action == "limit-cancel" ? "确认撤销此限价委托？" : "确认\(title)？"
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
        let status = result.value("status")
        let message = store.commandMessage(result)
        if status != "SUCCEEDED" {
          container.toastCenter.error(message)
        }
        completed(status == "SUCCEEDED" ? message : "")
        if ["SUCCEEDED", "FAILED"].contains(status) {
          key = UUID().uuidString
          pending = false
        }
      } catch { container.toastCenter.error(error.localizedDescription) }
    }
  }

}

struct USDTCommandsView: View {
  @EnvironmentObject private var store: USDTStore
  @StateObject private var model = USDTPageModel()
  var body: some View {
    WebRefreshScrollView {
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
    }.usdtPage("交易命令").task(id: store.scope) { await load() }.webRefreshable { await load() }
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
                WebOrderTypeSelector(selection: $orderType).frame(width: 116)
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
