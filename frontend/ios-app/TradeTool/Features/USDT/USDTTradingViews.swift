import SwiftUI

struct USDTTradeView: View {
  @EnvironmentObject private var store: USDTStore
  @State private var orderType = "market"
  @State private var stop = ""
  @State private var limit = ""
  @State private var risk = ""
  @State private var includeFee = false
  @State private var strategyID = ""
  @State private var ema: JSONValue = .null
  @State private var notice = ""
  @State private var busy = false
  @State private var confirm = false
  @State private var requestIdentity = UUID().uuidString
  @State private var submitted = false
  var initialStop: String = ""
  var initialLimit: String = ""

  @EnvironmentObject private var container: AppContainer
  @State private var currentQuote = ""
  @State private var symbols: [String] = []
  @State private var symbolSearch = ""
  @State private var showSymbols = false
  @State private var showStopLoss = false
  @State private var showChart = false
  @State private var strategyEnabled = true
  @State private var emaExpanded = false
  @State private var now = Date()

  var body: some View {
    VStack(spacing: 0) {
      Button {
        showSymbols = true
      } label: {
        HStack(spacing: 4) {
          Text(store.selectedSymbol)
          WebIcon("chevron.down", size: 14).foregroundStyle(WebTheme.muted)
        }
        .font(.system(size: 16, weight: .medium)).frame(maxWidth: .infinity).frame(height: 48)
      }.buttonStyle(.plain).background(WebTheme.surface.ignoresSafeArea(edges: .top))
      ScrollView {
        VStack(spacing: 16) {
          USDTCard {
            HStack {
              Text("币价").font(.system(size: 14)).foregroundStyle(WebTheme.muted)
              Spacer()
              ForEach([("market", "市价开仓"), ("limit", "限价委托")], id: \.0) { key, title in
                Button(title) { orderType = key }.font(.system(size: 14))
                  .foregroundStyle(orderType == key ? Color.black : WebTheme.secondary)
                  .padding(.horizontal, 12).frame(height: 28)
                  .background(
                    orderType == key ? WebTheme.brand : WebTheme.secondaryButton,
                    in: RoundedRectangle(cornerRadius: 4))
              }
            }
            HStack(spacing: 8) {
              Button {
                showChart = true
              } label: {
                Text(currentQuote.isEmpty ? "--" : currentQuote).font(
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
            VStack(spacing: 8) {
              HStack {
                Text("止盈策略").font(.system(size: 14)).foregroundStyle(WebTheme.muted)
                Spacer()
                WebCheckbox(checked: $strategyEnabled)
              }
              NavigationLink {
                USDTStrategiesView(returnAfterSelection: true)
              } label: {
                Text(
                  strategyEnabled
                    ? store.strategies.first(where: { $0.value("id") == strategyID })?.value("name")
                      ?? "请选择策略" : "未启用自动止盈策略"
                )
                .font(.system(size: 16, weight: .medium)).foregroundStyle(
                  strategyEnabled ? WebTheme.brand : WebTheme.muted
                )
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(
                  (strategyEnabled ? WebTheme.brand : WebTheme.secondaryButton).opacity(0.12),
                  in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: 10).stroke(
                    style: StrokeStyle(lineWidth: 2, dash: [4])
                  ).foregroundStyle(
                    (strategyEnabled ? WebTheme.brand : WebTheme.border).opacity(0.35))
                }
              }.buttonStyle(.plain).accessibilityIdentifier("trade.strategy")
            }.padding(.bottom, 12)
          }
          USDTCard(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
              estimate("止损金额", risk.isEmpty ? "0" : risk)
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
          if orderType == "market", !ema.fields.isEmpty { emaCard }
          Button(entryButtonText) {
            if orderType == "market" && !emaValid {
              checkEMA()
            } else {
              Task {
                busy = true
                defer { busy = false }
                do {
                  try await store.preflight()
                  confirm = true
                } catch { notice = error.localizedDescription }
              }
            }
          }.buttonStyle(
            WebButtonStyle(
              kind: !inputValid || !strategyValid
                ? .inactive
                : orderType == "market" && !emaValid ? .primary : isLong ? .success : .danger)
          ).disabled(busy || submitted || !store.isBound || !inputValid || !strategyValid)
          if submitted {
            NavigationLink("查看交易命令", destination: USDTCommandsView()).font(.system(size: 14))
              .foregroundStyle(WebTheme.brand)
          }
          USDTNotice(text: notice)
        }.padding(16).frame(maxWidth: 448).frame(maxWidth: .infinity)
      }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
    }.usdtPage("开仓")
      .task(id: store.scope) {
        await store.refresh()
        risk = store.riskAmount
        if strategyID.isEmpty { strategyID = store.activeStrategy?.value("id") ?? "" }
        symbols = (try? await store.get("/v1/trade/symbols").rows.map(\.text)) ?? []
      }
      .task(id: "\(store.scope):\(store.selectedSymbol)") {
        while !Task.isCancelled {
          if let quote = try? await store.get(
            "/v1/trade/symbol/info", query: [.init(name: "symbol", value: store.selectedSymbol)])
          {
            currentQuote = quote.value("current_price", fallback: "")
          }
          do { try await Task.sleep(for: .seconds(3)) } catch { break }
        }
      }
      .onAppear {
        if !initialStop.isEmpty { stop = initialStop }
        if !initialLimit.isEmpty {
          limit = initialLimit
          orderType = "limit"
        }
      }
      .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
      .onChange(of: store.riskAmount) { _, value in risk = value }
      .onChange(of: store.selectedSymbol) { _, _ in resetDraft() }
      .onChange(of: stop) { _, _ in resetDraft() }
      .onChange(of: limit) { _, _ in resetDraft() }
      .onChange(of: orderType) { _, _ in resetDraft() }
      .onChange(of: strategyID) { _, _ in requestIdentity = UUID().uuidString }
      .onChange(of: store.activeStrategy?.value("id")) { _, id in strategyID = id ?? "" }
      .webSheet(isPresented: $showChart) {
        NavigationStack {
          MarketChartView(
            market: container.dashboardViewModel.markets(onlyVisible: false).first {
              $0.symbol == store.selectedSymbol
            }
              ?? MarketSnapshot(
                symbol: store.selectedSymbol, quoteAsset: "USDT", price: 0, changePercent24h: 0,
                updatedAt: .now),
            availableMarkets: container.dashboardViewModel.markets(onlyVisible: false),
            apiClient: container.apiClient, realtimeClient: container.realtimeClient,
            initialInterval: .oneHour, onClose: { showChart = false })
        }
      }
      .webModal(isPresented: $showSymbols) {
        WebModal(title: "选择交易对") {
          USDTField(title: "", text: $symbolSearch, placeholder: "搜索交易对")
          ScrollView {
            VStack(spacing: 0) {
              ForEach(
                symbols.filter {
                  symbolSearch.isEmpty || $0.localizedCaseInsensitiveContains(symbolSearch)
                }, id: \.self
              ) { symbol in
                Button {
                  store.selectedSymbol = symbol
                  showSymbols = false
                } label: {
                  HStack {
                    Text(symbol)
                    Spacer()
                    if symbol == store.selectedSymbol {
                      Image(systemName: "checkmark").foregroundStyle(WebTheme.brand)
                    }
                  }.padding(.vertical, 12)
                }.buttonStyle(.plain)
              }
            }
          }.frame(maxHeight: 400)
        }
      }
      .webModal(isPresented: $showStopLoss) {
        USDTStopLossView().onDisappear { risk = store.riskAmount }
      }
      .webModal(isPresented: $confirm) {
        WebModal(title: orderType == "limit" ? "委托确认" : "开仓确认") {
          Text(
            "即将开\(store.selectedSymbol.replacingOccurrences(of: "USDT", with: "")) \(isLong ? "多" : "空")单"
          ).font(.system(size: 18, weight: .bold)).foregroundStyle(
            isLong ? WebTheme.success : WebTheme.danger
          ).frame(maxWidth: .infinity)
          VStack(spacing: 12) {
            USDTMetric(title: "币种", value: store.selectedSymbol)
            USDTMetric(title: "模式", value: orderType == "limit" ? "限价委托" : "市价开仓")
            USDTMetric(title: "止损价", value: stop)
            if orderType == "limit" { USDTMetric(title: "限价值", value: limit) }
            USDTMetric(title: "仓位", value: estimatedPosition + " U")
            HStack {
              Text("手续费").foregroundStyle(WebTheme.secondary)
              Spacer()
              Text(includeFee ? "(含)" : "(不含)").font(.system(size: 12)).foregroundStyle(
                includeFee ? WebTheme.success : WebTheme.danger)
              Text(estimatedFee + " U").fontWeight(.medium)
            }
            USDTMetric(
              title: "止损额",
              value: includeFee
                ? risk + " U"
                : risk + "+" + estimatedFee + "="
                  + NSDecimalNumber(
                    decimal: (Decimal(string: risk) ?? 0) + positionEstimate * Decimal(
                      string: "0.001")!
                  ).stringValue + " U")
            USDTMetric(
              title: "止损回撤",
              value: referencePrice > 0
                ? String(
                  format: "%.2f%%",
                  NSDecimalNumber(
                    decimal: abs(referencePrice - (Decimal(string: stop) ?? 0)) / referencePrice
                      * 100
                  ).doubleValue) : "--")
          }.font(.system(size: 14)).padding(16).background(
            WebTheme.input, in: RoundedRectangle(cornerRadius: 14))
          HStack(spacing: 12) {
            Button("取消") { confirm = false }.buttonStyle(
              WebButtonStyle(kind: .secondary, radius: 14))
            Button("确定") {
              confirm = false
              submit()
            }.buttonStyle(WebButtonStyle(radius: 14, weight: .bold))
          }
        }
      }
  }
  private var referencePrice: Decimal {
    Decimal(string: orderType == "limit" ? limit : currentQuote) ?? 0
  }
  private var isLong: Bool { (Decimal(string: stop) ?? 0) < referencePrice }
  private var positionEstimate: Decimal {
    let stopValue = Decimal(string: stop) ?? 0
    guard referencePrice > 0, stopValue > 0, stopValue != referencePrice else { return 0 }
    let ratio = abs(referencePrice - stopValue) / referencePrice
    return (Decimal(string: risk) ?? 0) / (ratio + (includeFee ? Decimal(string: "0.001")! : 0))
  }
  private var estimatedPosition: String {
    NSDecimalNumber(decimal: positionEstimate).stringValue == "0"
      ? "0" : String(format: "%.2f", NSDecimalNumber(decimal: positionEstimate).doubleValue)
  }
  private var estimatedFee: String {
    positionEstimate == 0
      ? "0"
      : String(
        format: "%.2f",
        NSDecimalNumber(decimal: positionEstimate * Decimal(string: "0.001")!).doubleValue)
  }
  private func estimate(_ title: String, _ value: String) -> some View {
    VStack(spacing: 8) {
      Text(title).font(.system(size: 14)).foregroundStyle(WebTheme.muted).frame(height: 20)
      Text(value).font(.system(size: 24)).frame(height: 32).lineLimit(1).minimumScaleFactor(0.6)
    }.frame(maxWidth: .infinity)
  }
  private var inputValid: Bool {
    referencePrice > 0 && (Decimal(string: stop) ?? 0) > 0
      && Decimal(string: stop) != referencePrice
  }
  private var strategyValid: Bool {
    !strategyEnabled || store.strategies.contains { $0.value("id") == strategyID }
  }
  private var emaExpired: Bool {
    !ema.fields.isEmpty && (WebFormat.date(ema.value("expires_at")) ?? .distantPast) <= now
  }
  private var emaDirectionChanged: Bool {
    !ema.fields.isEmpty && ema.value("side") != (isLong ? "long" : "short")
  }
  private var emaValid: Bool {
    ema["has_any_matching_interval"]?.flag == true && !emaExpired && !emaDirectionChanged
      && ema.value("symbol") == store.selectedSymbol
  }
  private var entryButtonText: String {
    if submitted { return "请求已提交，请查看命令记录" }
    if busy { return orderType == "market" && !emaValid ? "检测中..." : "提交中..." }
    if !inputValid { return orderType == "market" ? "输入止损价开仓" : "输入止损价/限价开仓" }
    if !strategyValid { return "请选择止盈策略" }
    if orderType == "market" && !emaValid { return ema.fields.isEmpty ? "方向初筛" : "重新方向初筛" }
    return (orderType == "market" ? "市价开" : "限价开") + (isLong ? "多" : "空")
  }
  private var emaCard: some View {
    let items = ema["items"]?.rows ?? []
    let supported = items.filter { $0["supported"]?.flag == true }.count
    let matches = items.filter {
      $0["supported"]?.flag == true && $0["matches_direction"]?.flag == true
    }.count
    return VStack(spacing: 12) {
      Button {
        emaExpanded.toggle()
      } label: {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
              Text(
                emaExpired
                  ? "方向初筛已过期"
                  : emaDirectionChanged
                    ? "方向初筛方向已变化"
                    : ema["has_any_matching_interval"]?.flag == true ? "方向初筛通过" : "所有周期暂不支持当前方向"
              ).font(.system(size: 14, weight: .medium)).foregroundStyle(
                emaValid ? WebTheme.success : WebTheme.brand)
              Text((ema.value("side") == "long" ? "做多" : "做空") + " · 3分钟内有效").font(
                .system(size: 12)
              ).foregroundStyle(WebTheme.muted)
            }
            Spacer(minLength: 0)
            Text("\(matches)/\(supported > 0 ? supported : items.count)").font(
              .system(size: 14, weight: .semibold))
            WebIcon(emaExpanded ? "chevron-up" : "chevron-down", size: 18).foregroundStyle(
              WebTheme.muted)
          }
          if !emaExpanded {
            HStack(spacing: 12) {
              ForEach(Array(items.enumerated()), id: \.offset) { _, row in
                let pass = row["supported"]?.flag == true && row["matches_direction"]?.flag == true
                HStack(spacing: 6) {
                  WebIcon(pass ? "circle-check" : "circle-x", size: 16)
                  Text(row.value("label"))
                }.font(.system(size: 12)).foregroundStyle(pass ? WebTheme.success : WebTheme.danger)
              }
            }
          }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
      if emaExpanded {
        VStack(spacing: 8) {
          ForEach(Array(items.enumerated()), id: \.offset) { _, row in
            let supported = row["supported"]?.flag == true
            let pass = supported && row["matches_direction"]?.flag == true
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 8) {
                WebIcon(pass ? "circle-check" : "circle-x", size: 16).foregroundStyle(
                  pass ? WebTheme.success : WebTheme.danger)
                Text(row.value("label")).font(.system(size: 14))
                Spacer()
                Text(!supported ? "数据不足" : pass ? "支持" : "不支持").font(
                  .system(size: 12, weight: .medium)
                ).foregroundStyle(
                  !supported ? WebTheme.muted : pass ? WebTheme.success : WebTheme.danger)
              }
              Text(row.value("relation")).font(.system(size: 12)).foregroundStyle(WebTheme.muted)
            }.padding(.horizontal, 12).padding(.vertical, 8).background(
              WebTheme.surface, in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
    }.padding(12).background(
      (emaValid ? WebTheme.success : WebTheme.brand).opacity(emaValid ? 0.08 : 0.1),
      in: RoundedRectangle(cornerRadius: 10)
    ).overlay {
      RoundedRectangle(cornerRadius: 10).stroke(
        (emaValid ? WebTheme.success : WebTheme.brand).opacity(emaValid ? 0.25 : 0.3), lineWidth: 1)
    }
  }
  private func resetDraft() {
    ema = .null
    emaExpanded = false
    if !submitted { requestIdentity = UUID().uuidString }
  }
  private func checkEMA() {
    busy = true
    Task {
      defer { busy = false }
      do {
        ema = try await store.send(
          "/v1/trade/ema-check",
          ["symbol": .string(store.selectedSymbol.uppercased()), "stop_loss_price": .string(stop)])
      } catch { notice = error.localizedDescription }
    }
  }
  private func submit() {
    busy = true
    submitted = true
    Task {
      defer { busy = false }
      var payload: [String: JSONValue] = [
        "symbol": .string(store.selectedSymbol.uppercased()), "stop_loss_price": .string(stop),
        "stop_loss_amount": .string(risk),
      ]
      if orderType == "limit" {
        payload["limit_price"] = .string(limit)
      } else {
        payload["include_fee"] = .bool(includeFee)
        payload["ema_check_id"] = ema["check_id"]
      }
      if strategyEnabled,
        let strategy = store.strategies.first(where: { $0.value("id") == strategyID })
      {
        payload["strategy_id"] = strategy["id"]
        payload["strategy_name"] = strategy["name"]
        payload["strategy_config"] = strategy["levels"]
      }
      do {
        let result = try await store.command(
          orderType == "limit" ? "limit-create" : "open", payload: payload, key: requestIdentity)
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
  @EnvironmentObject private var container: AppContainer
  @State private var selected: JSONValue = .null
  @State private var operation: WebPositionOperation? = nil
  @State private var chart = false
  @State private var skipCloseAllConfirm = false
  @State private var closeAllConfirm = false
  @State private var closingAll = false
  @State private var closeQueue: [WebCloseTarget] = []
  private var closeQueueKey: String { "integrated.close-queue.\(store.scope)" }
  private var totalPnl: Decimal {
    model.items.reduce(Decimal.zero) { $0 + ($1["pnl"]?.decimal ?? 0) }
  }
  private var totalPnlText: String {
    (totalPnl >= 0 ? "+" : "") + NSDecimalNumber(decimal: totalPnl).stringValue
  }
  var body: some View {
    VStack(spacing: 0) {
      WebTabs(
        tabs: [("positions", "持仓"), ("limits", "限价委托"), ("history", "历史仓位")], selection: $segment)
      ScrollView {
        VStack(spacing: 10) {
          if segment == "history" {
            HStack(spacing: 8) {
              ForEach(
                [("all", "全部"), ("day", "一天内"), ("three-days", "三天"), ("week", "一周")], id: \.0
              ) { key, label in
                Button(label) { filter = key }.font(.system(size: 14, weight: .medium)).frame(
                  maxWidth: .infinity
                ).padding(.vertical, 6)
                  .foregroundStyle(filter == key ? Color.black : WebTheme.secondary)
                  .background(
                    filter == key ? WebTheme.brand : WebTheme.secondaryButton,
                    in: RoundedRectangle(cornerRadius: 8))
              }
              Spacer()
            }
          }
          if segment != "history" && !store.isBound {
            Text("请先绑定 Binance Api").font(.system(size: 16))
              .foregroundStyle(WebTheme.muted).frame(maxWidth: .infinity).padding(.vertical, 48)
          } else {
            USDTNotice(text: notice)
            if model.loading && model.items.isEmpty {
              Text("加载中...").font(.system(size: 16)).foregroundStyle(WebTheme.muted).frame(
                maxWidth: .infinity
              ).padding(.vertical, 48)
            }
            if !model.loading && model.items.isEmpty {
              USDTEmptyState(
                title: segment == "positions" ? "暂无持仓" : segment == "limits" ? "暂无限价委托" : "暂无历史仓位记录",
                error: model.error
              ) { Task { await reload() } }
            }
            ForEach(Array(model.items.enumerated()), id: \.offset) { _, row in
              if segment == "positions" {
                positionCard(row)
              } else if segment == "limits" {
                limitCard(row)
              } else {
                historyCard(row)
              }
            }
            if segment == "positions", model.items.count > 1 || !closeQueue.isEmpty { closeAllBar }
            if model.hasNext {
              Button("加载更多") {
                model.page += 1
                Task { await reload(append: true) }
              }.buttonStyle(WebButtonStyle(kind: .secondary, fontSize: 14))
            }
          }
        }.padding(16).frame(maxWidth: 448).frame(maxWidth: .infinity)
      }.scrollIndicators(.hidden).scrollBounceBehavior(.always)
        .accessibilityIdentifier("positions.list")
        .refreshable {
          let scope = store.scope
          await store.refresh()
          guard scope == store.scope else { return }
          model.page = 1
          await reload()
        }
    }.usdtPage("持仓")
      .task(id: store.scope) {
        if let data = UserDefaults.standard.data(forKey: closeQueueKey),
          let saved = try? JSONDecoder().decode([WebCloseTarget].self, from: data)
        {
          closeQueue = saved
        } else {
          closeQueue = []
        }
      }
      .task(id: "\(store.scope):\(segment):\(filter):\(store.isBound)") {
        model.page = 1
        await reload()
      }
      .onChange(of: store.liveRevision) { _, _ in
        if segment != "history" {
          model.page = 1
          Task { await reload() }
        }
      }
      .webModal(isPresented: $closeAllConfirm) {
        WebModal(title: "全部平仓") {
          (Text("当前共 \(model.items.count) 笔持仓，预估总盈亏 ")
            + Text(totalPnlText + " USDT").foregroundColor(
              totalPnl >= 0 ? WebTheme.success : WebTheme.danger) + Text("，确认全部平仓？"))
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
      .webModal(item: $operation) { operation in
        USDTPositionControls(position: operation.position, action: operation.action) {
          notice = $0
          Task { await reload() }
        }.presentationBackground(.clear)
      }
      .webSheet(isPresented: $chart) {
        NavigationStack {
          MarketChartView(
            market: MarketSnapshot(
              symbol: selected.value("symbol"), quoteAsset: "USDT",
              price: Double(selected.value("current_price")) ?? 0, changePercent24h: 0,
              updatedAt: .now), apiClient: container.apiClient,
            realtimeClient: container.realtimeClient, onClose: { chart = false })
        }
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
      }.buttonStyle(WebButtonStyle(kind: totalPnl >= 0 ? .success : .danger, height: 44)).disabled(
        closingAll)
    }.padding(.top, 6)
  }
  private func closeAll() {
    guard !closingAll else { return }
    let scope = store.scope
    let storageKey = closeQueueKey
    if closeQueue.isEmpty {
      closeQueue = model.items.compactMap { row in
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
  private func reload(append: Bool = false) async {
    guard segment == "history" || store.isBound else {
      model.value = .null
      model.error = ""
      model.hasNext = false
      return
    }
    let path =
      segment == "positions"
      ? "/v1/position/list"
      : segment == "limits" ? "/v1/trade/limit-order/list" : "/v1/position/history"
    await model.load(
      store, path: path,
      query: [
        .init(name: "filter", value: filter), .init(name: "page", value: String(model.page)),
        .init(name: "page_size", value: "20"),
      ], append: append)
  }
  private func positionCard(_ row: JSONValue) -> some View {
    USDTCard(radius: 14, padding: 14, spacing: 14) {
      HStack(spacing: 8) {
        Text(row.value("side") == "0" ? "多" : "空").font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white).frame(width: 20, height: 20)
          .background(
            row.value("side") == "0" ? WebTheme.success : WebTheme.danger,
            in: RoundedRectangle(cornerRadius: 4))
        Text(row.value("symbol")).font(.system(size: 16, weight: .medium))
        if row.value("position_origin") == "exchange_external" { WebBadge(text: "手动仓") }
        Text("x\(row.value("leverage"))").font(.system(size: 14)).foregroundStyle(WebTheme.muted)
        Text("止损\(row.value("stop_loss_amount"))U").font(.system(size: 12)).foregroundStyle(
          WebTheme.brand
        ).padding(.horizontal, 6).padding(.vertical, 2).background(
          WebTheme.brand.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        Spacer(minLength: 0)
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 16) {
          inline("开仓额度：", row.value("position_amount"))
          inline(
            "持仓盈亏：", row.value("pnl"),
            color: (row["pnl"]?.decimal ?? 0) >= 0 ? WebTheme.success : WebTheme.danger)
        }
        HStack(spacing: 16) {
          inline("开仓价格：", row.value("open_price"))
          inline("当前价格：", row.value("current_price"))
        }
        inline(
          "市价止损：", row["market_stop_set"]?.flag == true ? row.value("market_stop_price") : "未设置")
        HStack {
          inline(
            "市价止盈：",
            row["manual_take_profit_set"]?.flag == true
              ? row.value("manual_take_profit_price") : "未设置")
          Button("设置") { show("takeProfit", row) }.font(.system(size: 12)).foregroundStyle(
            WebTheme.brand
          ).padding(.horizontal, 8).padding(.vertical, 2).background(
            WebTheme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        HStack(spacing: 4) {
          Text("手续费：").foregroundStyle(WebTheme.muted)
          Text(
            row.value("entry_fee_status") == "confirmed"
              ? row.value("entry_realized_fee") + " "
                + row.value("entry_fee_asset", fallback: "USDT")
              : "估-"
                + NSDecimalNumber(decimal: abs(row["estimated_total_fee"]?.decimal ?? 0) / 2)
                .stringValue + "U"
          ).foregroundStyle(WebTheme.danger)
          Text(
            "（估-"
              + NSDecimalNumber(decimal: abs(row["estimated_total_fee"]?.decimal ?? 0)).stringValue
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
        Button {
          selected = row
          chart = true
        } label: {
          WebLabel("K线", "chart-candlestick")
        }.buttonStyle(WebButtonStyle(kind: .secondary, height: 38, fontSize: 14, fullWidth: false))
        if row.value("position_origin") != "exchange_external" {
          Button(
            row.value("strategy_status") == "1"
              ? "自动止盈中" : row["can_bind_strategy"]?.flag == true ? "添加自动止盈" : "手动止盈"
          ) { show("strategy", row) }.buttonStyle(
            WebPositionStrategyStyle(running: row.value("strategy_status") == "1")
          ).disabled(row.value("strategy_status") != "1" && row["can_bind_strategy"]?.flag != true)
          Button("设置保本损") { show("breakEven", row) }.buttonStyle(WebPositiveActionStyle())
        }
        Button("立即平仓") { show("close", row) }.buttonStyle(WebButtonStyle(height: 38, fontSize: 14))
      }
    }
  }
  private func inline(_ title: String, _ value: String, color: Color? = nil) -> some View {
    (Text(title).foregroundColor(WebTheme.muted)
      + Text(value).fontWeight(.medium).foregroundColor(color ?? WebTheme.text)).font(
        .system(size: 14)
      ).frame(maxWidth: .infinity, alignment: .leading)
  }
  private func show(_ name: String, _ row: JSONValue) {
    operation = WebPositionOperation(position: row, action: name)
  }
  private func historyCard(_ row: JSONValue) -> some View {
    let external = row.value("position_origin") == "exchange_external"
    let pnl = row["pnl"]?.decimal
    let risk = row["stop_loss_amount"]?.decimal ?? 0
    let ratio =
      risk > 0 && pnl != nil
      ? String(format: "%.1f:1", NSDecimalNumber(decimal: pnl! / risk).doubleValue) : "--"
    let fee: Decimal? =
      external && (row["fee"]?.decimal == nil || row["funding_fee"]?.decimal == nil)
      ? nil : (row["fee"]?.decimal ?? 0) + (row["funding_fee"]?.decimal ?? 0)
    return USDTCard(radius: 14, padding: 14, spacing: 12) {
      HStack(spacing: 8) {
        WebDirection(long: row.value("side") == "0")
        Text(row.value("symbol")).font(.system(size: 16, weight: .medium))
        WebBadge(text: "止损" + row.value("stop_loss_amount") + "U")
        if row.value("settlement_status") == "estimated" { WebBadge(text: "估算") }
        Spacer()
      }
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
        alignment: .leading, spacing: 12
      ) {
        detail(
          "平仓盈亏", pnl.map { NSDecimalNumber(decimal: $0).stringValue + "U" } ?? "--",
          color: pnl.map { $0 >= 0 ? WebTheme.success : WebTheme.danger })
        detail("盈亏比", ratio, color: pnl.map { $0 >= 0 ? WebTheme.success : WebTheme.danger })
        detail("开仓价格", row.value("open_price"))
        detail("平仓价格", row.value("close_price"))
        detail("持仓额", row.value("position_amount") + "U")
        detail(
          "手续费", fee.map { NSDecimalNumber(decimal: $0).stringValue + "U" } ?? "--",
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
      if !row.value("settlement_note", fallback: "").isEmpty {
        USDTNotice(text: row.value("settlement_note"))
      }
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
        WebBadge(text: "止损" + row.value("stop_loss_amount") + "U")
        Spacer()
        WebBadge(text: row.value("status_text"))
      }
      LazyVGrid(
        columns: [
          GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading),
        ], alignment: .leading, spacing: 12
      ) {
        detail("限价", row.value("limit_price"))
        detail("止损价", row.value("stop_loss_price"))
        detail("委托仓位", row.value("position_amount") + "U")
        detail(
          "已成交",
          row.value("filled_amount", fallback: row.value("filled_size")) + "/"
            + row.value("position_amount") + "U")
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
          selection: $strategyID, enabled: .constant(true), autoOnly: true, busy: busy,
          notice: notice
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
                Text("止盈：" + position.value("manual_take_profit_price")).font(.system(size: 14))
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
              USDTMetric(title: "当前浮盈", value: position.value("pnl") + " USDT")
              USDTMetric(
                title: "预估总手续费", value: "-" + NSDecimalNumber(decimal: fee).stringValue + " USDT")
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
                Text("不含手续费保本（净盈亏 -" + NSDecimalNumber(decimal: fee).stringValue + "）").font(
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
              + Text(position.value("pnl") + " USDT").foregroundColor(
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
        pending = true
        let result = try await store.command(pendingAction, payload: pendingPayload, key: key)
        let message = store.commandMessage(result)
        if result.value("status") == "SUCCEEDED" {
          completed(message)
          dismiss()
        } else {
          notice = message
          if result.value("status") == "FAILED" {
            key = UUID().uuidString
            pending = false
          }
        }
      } catch { notice = error.localizedDescription }
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
        dismiss()
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
