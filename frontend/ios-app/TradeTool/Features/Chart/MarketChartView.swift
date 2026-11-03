import SwiftUI
import UIKit

private enum ChartPalette {
    static let positive = BinanceTheme.positive
    static let negative = BinanceTheme.negative
    static let actionPositive = BinanceTheme.positive
    static let actionNegative = BinanceTheme.negative
    static let detailPrimaryText = BinanceTheme.primaryText
    static let detailSecondaryText = BinanceTheme.secondaryText
    static let detailDivider = BinanceTheme.border
}

private enum MarketChartIndicatorCatalog {
    static let overlays = [
        "MA", "EMA", "BOLL", "SAR", "AVL", "SUPER",
    ]
    static let panels = [
        "VOL", "MACD", "RSI", "KDJ", "OBV", "WR", "StochRSI",
        "ATR", "O.I.", "L.S Acco.", "L.S Posit.", "L.S Ratio",
        "B.S Vol.", "Basis",
    ]
    static let all = overlays + panels
}

struct MarketChartView: View {
    @EnvironmentObject private var dashboard: DashboardViewModel
    @State private var selectedMarket: MarketSnapshot
    @State private var selectedInterval: MarketKlineInterval
    @State private var showsSymbols = false
    @State private var pendingSymbol: String?

    private let availableMarkets: [MarketSnapshot]
    private let apiClient: any APIClient
    private let realtimeClient: RealtimeClient
    private let onClose: (() -> Void)?
    private let onStop: (() -> Void)?
    private let onShowPositions: (() -> Void)?

    init(
        market: MarketSnapshot,
        availableMarkets: [MarketSnapshot] = [],
        apiClient: any APIClient,
        realtimeClient: RealtimeClient,
        initialInterval: MarketKlineInterval = .oneHour,
        onClose: (() -> Void)? = nil,
        onStop: (() -> Void)? = nil,
        onShowPositions: (() -> Void)? = nil
    ) {
        _selectedMarket = State(initialValue: market)
        _selectedInterval = State(initialValue: initialInterval)
        self.availableMarkets = availableMarkets
        self.apiClient = apiClient
        self.realtimeClient = realtimeClient
        self.onClose = onClose
        self.onStop = onStop
        self.onShowPositions = onShowPositions
    }

    var body: some View {
        MarketChartDetailView(
            market: selectedMarket,
            availableMarkets: switcherMarkets,
            apiClient: apiClient,
            realtimeClient: realtimeClient,
            initialInterval: selectedInterval,
            onSelectMarket: selectMarket,
            onIntervalChange: { selectedInterval = $0 },
            onShowSymbols: { showsSymbols = true },
            onClose: onClose,
            onStop: onStop,
            onShowPositions: onShowPositions
        )
        .id(selectedMarket.symbol)
        .largeTradingSheet(isPresented: $showsSymbols, onDismiss: {
            guard let symbol = pendingSymbol else { return }
            pendingSymbol = nil
            selectMarket(dashboard.marketSnapshot(forSymbol: symbol), interval: selectedInterval)
        }) {
            MarketSearchView(dashboardViewModel: dashboard, selectedSymbol: selectedMarket.symbol) { symbol in
                pendingSymbol = symbol
            }
        }
    }

    private var switcherMarkets: [MarketSnapshot] {
        var seen = Set<String>()
        var markets: [MarketSnapshot] = []
        for market in availableMarkets
        where market.isVisible && seen.insert(market.symbol).inserted {
            markets.append(
                market.symbol == selectedMarket.symbol
                    ? selectedMarket
                    : market
            )
        }
        if seen.insert(selectedMarket.symbol).inserted {
            markets.insert(selectedMarket, at: 0)
        }
        return markets
    }

    private func selectMarket(
        _ market: MarketSnapshot,
        interval: MarketKlineInterval
    ) {
        guard market.symbol != selectedMarket.symbol else {
            return
        }
        selectedInterval = interval
        selectedMarket = market
    }
}

private struct MarketChartDetailView: View {
    @EnvironmentObject private var toastCenter: AppToastCenter
    @EnvironmentObject private var usdt: USDTStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var nativeOrderType = "market"
    @StateObject private var positions = USDTChartPositionsModel()
    @State private var showsLeverage = false
    @State private var selectedStopPrice: Double?
    @State private var showsIntervalSettings = false
    @AppStorage(ChartIntervalPreferences.storageKey) private var favoriteIntervals = ChartIntervalPreferences.defaultValue
    @AppStorage("integrated.chart.autoFitPrice") private var automaticallyFitsPrice = true
    @StateObject private var viewModel: MarketChartViewModel
    let availableMarkets: [MarketSnapshot]
    let onSelectMarket: (MarketSnapshot, MarketKlineInterval) -> Void
    let onIntervalChange: (MarketKlineInterval) -> Void
    let onShowSymbols: () -> Void
    let onClose: (() -> Void)?
    let onStop: (() -> Void)?
    let onShowPositions: (() -> Void)?
    @EnvironmentObject private var dashboard: DashboardViewModel
    private var isFavorite: Bool { dashboard.containsInWatchlist(viewModel.market.symbol) }
    @State private var isIndicatorSettingsPresented = false
    @State private var isOrderSettingsPresented = false
    @State private var orderDrawing: ChartOrderDrawingState?
    @State private var chartPriceProjection: ChartPriceProjection?
    @State private var wheelPreview: ChartWheelPreviewState?

    init(
        market: MarketSnapshot,
        availableMarkets: [MarketSnapshot],
        apiClient: any APIClient,
        realtimeClient: RealtimeClient,
        initialInterval: MarketKlineInterval,
        onSelectMarket: @escaping (
            MarketSnapshot,
            MarketKlineInterval
        ) -> Void,
        onIntervalChange: @escaping (MarketKlineInterval) -> Void,
        onShowSymbols: @escaping () -> Void,
        onClose: (() -> Void)?,
        onStop: (() -> Void)?,
        onShowPositions: (() -> Void)?
    ) {
        self.availableMarkets = availableMarkets
        self.onSelectMarket = onSelectMarket
        self.onIntervalChange = onIntervalChange
        self.onShowSymbols = onShowSymbols
        self.onClose = onClose
        self.onStop = onStop
        self.onShowPositions = onShowPositions
        _viewModel = StateObject(wrappedValue: MarketChartViewModel(
            market: market,
            apiClient: apiClient,
            realtimeClient: realtimeClient,
            initialInterval: initialInterval,
            diagnosticUpload: apiClient is URLSessionAPIClient ? { data in
                ChartLoadDiagnostics.upload(data, using: apiClient)
            } : nil
        ))
    }

    var body: some View {
        ZStack {
            BinanceTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                fixedHeader
                indicatorStrip
                intervalStrip
                GeometryReader { geometry in
                    ScrollView(showsIndicators: false) {
                        chart.frame(width: geometry.size.width,
                            height: CGFloat(ChartPanelLayout.squareViewportHeightPoints(
                                widthPoints: Double(geometry.size.width),
                                indicatorPanelCount: viewModel.chartIndicatorPanelCount)))
                    }.accessibilityIdentifier("market-chart-detail-scroll")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                USDTTradeView(chartInput: ChartTradeInput(symbol: viewModel.market.symbol,
                    orderType: nativeOrderType,
                    stopLossPrice: priceString(nativeOrderType == "limit" ? orderDrawing?.stopLossPrice : selectedStopPrice),
                    limitPrice: priceString(orderDrawing?.entryPrice),
                    currentPrice: priceString(viewModel.currentPrice)),
                    onChartOrderTypeChange: { type in
                        nativeOrderType = type
                        initializeLimitDrawing()
                    }, chartHasPosition: !heldPositions.isEmpty,
                    chartPositionsReady: positions.isReady(scope: usdt.scope),
                    chartPositionsError: positions.error,
                    chartPositionRows: heldPositions,
                    onShowPositions: onShowPositions)
                    .id(usdt.scope)
            }

            if let wheelPreview {
                ChartWheelScrollPreview(state: wheelPreview)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .interactivePopGestureEnabled()
        .task {
            viewModel.start()
        }
        .task(id: "\(usdt.scope):\(viewModel.market.symbol)") {
            await usdt.loadDefaultLeverage(for: viewModel.market.symbol)
        }
        .task(id: "\(usdt.scope):\(usdt.isBound):\(scenePhase)") {
            guard scenePhase == .active else { positions.reset(); return }
            await positions.monitor(usdt)
        }
        .onChange(of: usdt.liveRevision) { _, _ in
            guard scenePhase == .active else { return }
            Task { await positions.refresh(usdt) }
        }
        .onDisappear {
            selectedStopPrice = nil
            viewModel.stop()
            onStop?()
        }
        .onChange(of: viewModel.interval) { _, interval in
            onIntervalChange(interval)
        }
        .navigationDestination(isPresented: $isIndicatorSettingsPresented) {
            ChartIndicatorSettingsView(
                parameters: viewModel.chartIndicatorParameters
            ) { parameters in
                viewModel.updateChartIndicatorParameters(parameters)
            }
        }
        .navigationDestination(isPresented: $isOrderSettingsPresented) {
            USDTChartOrderSettingsView()
        }
        .largeTradingSheet(isPresented: $showsIntervalSettings) {
            ChartIntervalSettingsView(selection: viewModel.interval,
                favorites: $favoriteIntervals, onSelect: viewModel.selectInterval)
        }
        .largeTradingSheet(isPresented: $showsLeverage, background: WebTheme.page) {
            USDTLeverageBracketsView(symbol: viewModel.market.symbol)
        }
        .onChange(of: viewModel.currentPrice, initial: true) { _, _ in initializeLimitDrawing() }
        .onChange(of: nativeOrderType) { _, _ in initializeLimitDrawing() }
    }

    private var fixedHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                BinanceBackButton(action: onClose)
                    .accessibilityIdentifier("market-chart-back")

                Button(action: onShowSymbols) {
                    VStack(alignment: .leading, spacing: 1) {
                      HStack(spacing: 5) {
                        Text(viewModel.market.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .foregroundStyle(BinanceTheme.primaryText)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(BinanceTheme.secondaryText)
                      }

                    HStack(spacing: 4) {
                        Text(formatPrice(viewModel.currentPrice))
                            .foregroundStyle(latestPriceColor)
                        Text(viewModel.formattedChange24h)
                            .foregroundStyle(change24hColor)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换交易对 \(viewModel.market.symbol)")
                .accessibilityIdentifier("market-chart-symbols")

                Spacer(minLength: 2)
                HStack(spacing: 0) {
                    tradeTool(title: "指标", action: { isIndicatorSettingsPresented = true }) {
                        indicatorSettingsIcon
                    }.accessibilityIdentifier("market-chart-indicator-settings-shortcut")
                    tradeTool("gauge.with.dots.needle.67percent", title: usdt.displayedLeverage(for: viewModel.market.symbol).map { "杠杆 × \($0)" } ?? "杠杆 · 读取中", width: 62, action: { showsLeverage = true })
                        .accessibilityIdentifier("market-chart-leverage")
                    tradeTool("gearshape", title: "设置", action: { isOrderSettingsPresented = true })
                        .accessibilityIdentifier("market-chart-settings")
                }

                Button {
                    if isFavorite { dashboard.hideMarkets([viewModel.market.symbol]) }
                    else { dashboard.addToWatchlist(viewModel.market.symbol) }
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(
                            isFavorite
                                ? BinanceTheme.accent
                                : BinanceTheme.secondaryText
                        )
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("market-chart-favorite")
                .accessibilityLabel("收藏")
                .accessibilityValue(isFavorite ? "已收藏" : "未收藏")
            }
            .padding(.leading, 4)
            .padding(.trailing, 11)
            .frame(height: 53)

            Rectangle()
                .fill(BinanceTheme.navigationBorder.opacity(0.7))
                .frame(height: 0.5)
        }
        .background(BinanceTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("market-chart-header")
    }

    private var chart: some View {
        ZStack {
            KlineChartSceneView(
                frame: viewModel.chartDataFrame,
                automaticallyFitsPrice: automaticallyFitsPrice,
                candleMarkers: ChartPositionEntryMarkers.markers(in: heldPositions, symbol: viewModel.market.symbol),
                candleMarkerExclusions: positionMarkerExclusions,
                diagnostics: viewModel.loadDiagnostics,
                onFirstFramePresented: { epoch, time in
                    viewModel.chartFirstFramePresented(epoch: epoch, at: time)
                },
                onNeedsOlderHistory: {
                    viewModel.requestOlderHistory()
                },
                onPriceProjectionChange: { projection in
                    chartPriceProjection = projection
                },
                onCrosshairSelection: { selection in
                    guard nativeOrderType == "market" else { return }
                    guard selection.panelID == ChartPanelID.price,
                        selection.panelValue.isFinite, selection.panelValue > 0 else {
                        selectedStopPrice = nil
                        return
                    }
                    selectedStopPrice = selection.panelValue
                },
                onCrosshairDismiss: { selectedStopPrice = nil }
            )

            if let projection = chartPriceProjection, !heldPositions.isEmpty {
                ChartPositionLinesOverlay(lines: ChartPositionLine.lines(in: heldPositions,
                    symbol: viewModel.market.symbol, currentPrice: Decimal(string: priceString(viewModel.currentPrice))), projection: projection)
            }

            if let projection = chartPriceProjection, heldPositions.isEmpty,
               nativeOrderType == "limit", let drawing = orderDrawing {
                ChartOrderDrawingOverlay(
                    drawing: Binding(
                        get: { orderDrawing ?? drawing },
                        set: { orderDrawing = $0 }
                    ),
                    projection: projection,
                    formatPrice: formatPrice,
                    showsSummary: false,
                    allowsOffscreenStopLoss: !automaticallyFitsPrice
                )
                .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("market-chart-plot")
    }

    private var positionMarkerExclusions: [CGRect] {
        guard let projection = chartPriceProjection else { return [] }
        return ChartPositionLinesOverlay.labelFrames(lines: ChartPositionLine.lines(in: heldPositions,
            symbol: viewModel.market.symbol), projection: projection)
    }

    private var indicatorSettingsIcon: some View {
        IndicatorSettingsControlIcon()
            .stroke(
                ChartPalette.detailPrimaryText,
                style: StrokeStyle(
                    lineWidth: 1.2,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: 18, height: 18)
    }

    private var indicatorStrip: some View {
        MarketChartQuickIndicatorStrip(activeIndicators: Set(
            MarketChartIndicatorCatalog.all.filter(viewModel.isChartIndicatorActive)),
            onToggle: viewModel.toggleChartIndicator)
            .frame(height: 42)
    }

    private var intervalStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(ChartIntervalPreferences.visible(favoriteIntervals, selected: viewModel.interval)) { interval in
                        Button { viewModel.selectInterval(interval) } label: {
                            Text(interval.title).font(.system(size: 12,
                                weight: interval == viewModel.interval ? .semibold : .medium))
                                .foregroundStyle(interval == viewModel.interval ? BinanceTheme.accentText : BinanceTheme.secondaryText)
                                .overlay(alignment: .bottom) {
                                    if interval == viewModel.interval {
                                        Rectangle().fill(BinanceTheme.accent).frame(height: 2).offset(y: 5)
                                    }
                                }
                                .padding(.horizontal, 6).frame(height: 38).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("chart-interval." + interval.rawValue)
                    }
                    Button { showsIntervalSettings = true } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 13)).frame(width: 30, height: 38)
                    }.buttonStyle(.plain).accessibilityLabel("编辑时间周期").accessibilityIdentifier("chart-interval.edit")
                }
            }
            Toggle(isOn: $automaticallyFitsPrice) {
                Text("auto").font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(ChartAutoFitToggleStyle())
            .accessibilityLabel("auto 自动适配")
            .accessibilityIdentifier("chart-interval.auto")
            .padding(.leading, 4).padding(.trailing, 8)
        }.padding(.leading, 4).background(BinanceTheme.background)
    }

    private func priceString(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "" }
        return NSDecimalNumber(string: String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)).stringValue
    }

    private func initializeLimitDrawing() {
        guard nativeOrderType == "limit", orderDrawing == nil, viewModel.currentPrice > 0 else { return }
        guard var drawing = ChartOrderDrawingState.make(side: .long, entryOrderType: .limit,
            referencePrice: viewModel.currentPrice) else { return }
        if let stop = selectedStopPrice, stop != viewModel.currentPrice {
            drawing.entryPrice = viewModel.currentPrice
            drawing.stopLossPrice = stop
        }
        drawing.allowsSideChange = true
        orderDrawing = drawing
    }

    private func updateWheelPreview(
        sourceID: String,
        preview: ChartWheelPreviewState?
    ) {
        if let preview {
            if wheelPreview == nil {
                withAnimation(.easeOut(duration: 0.12)) {
                    wheelPreview = preview
                }
            } else {
                wheelPreview = preview
            }
        } else if wheelPreview?.sourceID == sourceID {
            withAnimation(.easeOut(duration: 0.2)) {
                wheelPreview = nil
            }
        }
    }

    private func tradeTool(
        _ icon: String,
        title: String,
        width: CGFloat = 44,
        action: @escaping () -> Void
    ) -> some View {
        tradeTool(title: title, width: width, action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
        }
    }

    private func tradeTool<Icon: View>(
        title: String,
        width: CGFloat = 44,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                icon()
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(BinanceTheme.primaryText)
            .frame(width: width, height: 44)
        }
        .buttonStyle(.plain)
    }

    private var heldPositions: [JSONValue] {
        positions.positions(for: viewModel.market.symbol, scope: usdt.scope)
    }

    private var latestPriceColor: Color {
        switch viewModel.latestPriceMovement {
        case .unchanged:
            ChartPalette.detailPrimaryText
        case .rising:
            ChartPalette.positive
        case .falling:
            ChartPalette.negative
        }
    }

    private var change24hColor: Color {
        viewModel.changePercent24h >= 0
            ? ChartPalette.positive
            : ChartPalette.negative
    }

    private func formatPrice(_ value: Double) -> String {
        MarketDisplayFormatter.price(value)
    }

}

struct ChartQuickSwitcherSequence<Item: Identifiable>
where Item.ID: Hashable {
    let items: [Item]
    let selectedID: Item.ID

    init(items: [Item], selectedID: Item.ID) {
        var seen = Set<Item.ID>()
        self.items = items.filter { seen.insert($0.id).inserted }
        self.selectedID = selectedID
    }

    func item(offsetFromSelection offset: Int) -> Item? {
        guard !items.isEmpty,
              let selectedIndex = items.firstIndex(where: {
                  $0.id == selectedID
              }) else {
            return nil
        }
        if items.count == 1, offset != 0 {
            return nil
        }
        let count = items.count
        let wrappedIndex = ((selectedIndex + offset) % count + count) % count
        return items[wrappedIndex]
    }
}

private struct MarketChartQuickIndicatorStrip: View {
    let activeIndicators: Set<String>
    let onToggle: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                indicatorGroup(
                    title: "指标",
                    identifier: "overlay",
                    indicators: MarketChartIndicatorCatalog.overlays
                )

                Rectangle()
                    .fill(ChartPalette.detailDivider)
                    .frame(width: 0.5, height: 22)

                indicatorGroup(
                    title: "副图",
                    identifier: "panel",
                    indicators: MarketChartIndicatorCatalog.panels
                )
            }
            .padding(.horizontal, 2)
            .frame(height: 42)
        }
        .accessibilityIdentifier("market-chart-quick-indicator-strip")
    }

    private func indicatorGroup(
        title: String,
        identifier: String,
        indicators: [String]
    ) -> some View {
        HStack(spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ChartPalette.detailSecondaryText)
                .padding(.trailing, 2)
                .accessibilityIdentifier(
                    "market-chart-quick-\(identifier)-group"
                )

            ForEach(indicators, id: \.self) { indicator in
                indicatorButton(indicator)
            }
        }
    }

    private func indicatorButton(_ indicator: String) -> some View {
        let active = activeIndicators.contains(indicator)
        return Button {
            onToggle(indicator)
        } label: {
            Text(indicator)
                .font(.system(
                    size: 13,
                    weight: active ? .semibold : .regular
                ))
                .foregroundStyle(
                    active
                        ? ChartPalette.detailPrimaryText
                        : ChartPalette.detailSecondaryText
                )
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .frame(height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            "market-chart-quick-indicator-\(indicator)"
        )
        .accessibilityValue(active ? "已开启" : "已关闭")
        .accessibilityHint("切换图表指标")
    }
}

struct ChartWheelPreviewState: Equatable {
    let sourceID: String
    let accessibilityLabel: String
    let labels: [String]
    let centerPosition: CGFloat

    func label(at row: Int) -> String? {
        guard !labels.isEmpty else {
            return nil
        }
        let index = ((row % labels.count) + labels.count) % labels.count
        return labels[index]
    }
}

private struct ChartWheelScrollPreview: View {
    let state: ChartWheelPreviewState

    private let rowSpacing: CGFloat = 27

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BinanceTheme.surface.opacity(0.98))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(BinanceTheme.border, lineWidth: 0.5)
                }

            ForEach(-4...4, id: \.self) { offset in
                previewRow(offset: offset)
            }
        }
        .frame(width: 160, height: 184)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("market-chart-wheel-preview")
        .accessibilityLabel(
            "\(state.accessibilityLabel)滚动预览，\(centerLabel)"
        )
    }

    private var centerRow: Int {
        Int(state.centerPosition.rounded())
    }

    private var centerLabel: String {
        state.label(at: centerRow) ?? ""
    }

    @ViewBuilder
    private func previewRow(offset: Int) -> some View {
        let row = centerRow + offset
        let distance = CGFloat(row) - state.centerPosition
        if let label = state.label(at: row) {
            Text(label)
                .font(.system(
                    size: fontSize(for: abs(distance)),
                    weight: abs(distance) < 0.55 ? .semibold : .regular
                ))
                .foregroundStyle(BinanceTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 142, height: 34)
                .opacity(opacity(for: abs(distance)))
                .offset(y: distance * rowSpacing)
        }
    }

    private func fontSize(for distance: CGFloat) -> CGFloat {
        interpolate(
            distance: distance,
            values: [29, 23, 17, 12, 11]
        )
    }

    private func opacity(for distance: CGFloat) -> Double {
        Double(interpolate(
            distance: distance,
            values: [1, 0.5, 0.2, 0.07, 0]
        ))
    }

    private func interpolate(
        distance: CGFloat,
        values: [CGFloat]
    ) -> CGFloat {
        let boundedDistance = min(max(distance, 0), CGFloat(values.count - 1))
        let lowerIndex = Int(boundedDistance.rounded(.down))
        let upperIndex = min(lowerIndex + 1, values.count - 1)
        let progress = boundedDistance - CGFloat(lowerIndex)
        return values[lowerIndex]
            + (values[upperIndex] - values[lowerIndex]) * progress
    }
}

private struct ChartWheelSwitcher<Item: Identifiable>: UIViewRepresentable
where Item.ID: Hashable {
    let items: [Item]
    let selectedID: Item.ID
    let width: CGFloat
    let accessibilityLabel: String
    let identifierPrefix: String
    let label: KeyPath<Item, String>
    let onSelect: (Item) -> Void
    let onPreviewChange: (String, ChartWheelPreviewState?) -> Void

    private var normalizedItems: [Item] {
        ChartQuickSwitcherSequence(
            items: items,
            selectedID: selectedID
        ).items
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = ChartWheelSnapFlowLayout()
        layout.scrollDirection = .vertical
        layout.itemSize = CGSize(width: width, height: 22)
        layout.minimumLineSpacing = -0.5
        layout.minimumInteritemSpacing = 0

        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: width, height: 52),
            collectionViewLayout: layout
        )
        collectionView.backgroundColor = UIColor(BinanceTheme.background)
        collectionView.contentInset = UIEdgeInsets(
            top: 15,
            left: 0,
            bottom: 15,
            right: 0
        )
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.decelerationRate = .fast
        collectionView.alwaysBounceVertical = true
        collectionView.clipsToBounds = true
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(
            ChartWheelCollectionCell.self,
            forCellWithReuseIdentifier: ChartWheelCollectionCell.reuseID
        )
        collectionView.accessibilityIdentifier =
            "\(identifierPrefix)-wheel"
        collectionView.accessibilityLabel = accessibilityLabel

        context.coordinator.bind(
            collectionView: collectionView,
            items: normalizedItems,
            selectedID: selectedID,
            accessibilityLabel: accessibilityLabel,
            identifierPrefix: identifierPrefix,
            labelText: { $0[keyPath: label] },
            onSelect: onSelect,
            onPreviewChange: onPreviewChange
        )
        return collectionView
    }

    func updateUIView(
        _ collectionView: UICollectionView,
        context: Context
    ) {
        if let layout = collectionView.collectionViewLayout
            as? UICollectionViewFlowLayout {
            layout.itemSize = CGSize(width: width, height: 22)
        }
        context.coordinator.bind(
            collectionView: collectionView,
            items: normalizedItems,
            selectedID: selectedID,
            accessibilityLabel: accessibilityLabel,
            identifierPrefix: identifierPrefix,
            labelText: { $0[keyPath: label] },
            onSelect: onSelect,
            onPreviewChange: onPreviewChange
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UICollectionView,
        context: Context
    ) -> CGSize? {
        CGSize(width: width, height: 52)
    }

    final class Coordinator: NSObject,
        UICollectionViewDataSource,
        UICollectionViewDelegate {
        private let repetitionCount = 201
        private let rowStride: CGFloat = 21.5
        private var items: [Item] = []
        private var itemIDs: [Item.ID] = []
        private var selectedID: Item.ID?
        private var selectedRow = 0
        private var wheelAccessibilityLabel = ""
        private var identifierPrefix = ""
        private var labelText: (Item) -> String = { _ in "" }
        private var previewLabels: [String] = []
        private var onSelect: (Item) -> Void = { _ in }
        private var onPreviewChange:
            (String, ChartWheelPreviewState?) -> Void = { _, _ in }
        private weak var collectionView: UICollectionView?
        private var isPreviewVisible = false
        private var previewDismissWorkItem: DispatchWorkItem?

        func bind(
            collectionView: UICollectionView,
            items: [Item],
            selectedID: Item.ID,
            accessibilityLabel: String,
            identifierPrefix: String,
            labelText: @escaping (Item) -> String,
            onSelect: @escaping (Item) -> Void,
            onPreviewChange: @escaping (
                String,
                ChartWheelPreviewState?
            ) -> Void
        ) {
            self.collectionView = collectionView
            wheelAccessibilityLabel = accessibilityLabel
            self.identifierPrefix = identifierPrefix
            self.labelText = labelText
            previewLabels = items.map(labelText)
            self.onSelect = onSelect
            self.onPreviewChange = onPreviewChange
            let newIDs = items.map(\.id)
            let itemsChanged = newIDs != itemIDs
            self.items = items
            itemIDs = newIDs
            collectionView.alwaysBounceVertical = items.count > 1

            guard let logicalIndex = items.firstIndex(where: {
                $0.id == selectedID
            }) else {
                self.selectedID = nil
                selectedRow = 0
                collectionView.reloadData()
                return
            }

            let selectionChanged = self.selectedID != selectedID
            self.selectedID = selectedID
            if itemsChanged {
                collectionView.reloadData()
                selectedRow = middleRow(for: logicalIndex)
                synchronizeSelection(animated: false)
            } else if selectionChanged {
                selectedRow = nearestRow(
                    for: logicalIndex,
                    around: selectedRow
                )
                synchronizeSelection(animated: false)
            } else {
                styleVisibleCells()
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            guard items.count > 1 else {
                return items.count
            }
            return items.count * repetitionCount
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChartWheelCollectionCell.reuseID,
                for: indexPath
            ) as? ChartWheelCollectionCell,
                  let item = item(at: indexPath.item) else {
                return UICollectionViewCell()
            }
            cell.setText(labelText(item))
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didSelectItemAt indexPath: IndexPath
        ) {
            let selectedCurrentRow = indexPath.item == selectedRow
            beginPreview()
            selectedRow = indexPath.item
            synchronizeSelection(animated: true)
            if selectedCurrentRow {
                schedulePreviewDismissal()
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            beginPreview()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            styleVisibleCells()
            publishPreviewIfNeeded()
        }

        func scrollViewDidEndDragging(
            _ scrollView: UIScrollView,
            willDecelerate decelerate: Bool
        ) {
            if !decelerate {
                if settleSelection() {
                    schedulePreviewDismissal()
                }
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if settleSelection() {
                schedulePreviewDismissal()
            }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            if settleSelection() {
                schedulePreviewDismissal()
            }
        }

        private func synchronizeSelection(animated: Bool) {
            guard let collectionView,
                  collectionView.numberOfItems(inSection: 0) > selectedRow else {
                return
            }
            collectionView.layoutIfNeeded()
            collectionView.scrollToItem(
                at: IndexPath(item: selectedRow, section: 0),
                at: .centeredVertically,
                animated: animated
            )
            if !animated {
                styleVisibleCells()
            }
        }

        private func settleSelection() -> Bool {
            guard let collectionView,
                  let centeredRow = centeredVisibleRow() else {
                return true
            }
            selectedRow = centeredRow
            if let attributes = collectionView.layoutAttributesForItem(
                at: IndexPath(item: centeredRow, section: 0)
            ) {
                let targetY = attributes.center.y
                    - collectionView.bounds.height / 2
                if abs(collectionView.contentOffset.y - targetY) > 0.5 {
                    collectionView.setContentOffset(
                        CGPoint(x: 0, y: targetY),
                        animated: true
                    )
                    return false
                }
            }

            styleVisibleCells()
            guard let item = item(at: centeredRow) else {
                return true
            }
            if item.id != selectedID {
                selectedID = item.id
                onSelect(item)
            }
            recenterIfNeeded()
            return true
        }

        private func beginPreview() {
            guard items.count > 1 else {
                return
            }
            previewDismissWorkItem?.cancel()
            previewDismissWorkItem = nil
            isPreviewVisible = true
            publishPreviewIfNeeded()
        }

        private func publishPreviewIfNeeded() {
            guard isPreviewVisible,
                  let collectionView,
                  let centeredRow = centeredVisibleRow(),
                  let attributes = collectionView.layoutAttributesForItem(
                    at: IndexPath(item: centeredRow, section: 0)
                  ) else {
                return
            }
            let visibleCenterY = collectionView.contentOffset.y
                + collectionView.bounds.height / 2
            let centerPosition = CGFloat(centeredRow)
                - (attributes.center.y - visibleCenterY) / rowStride
            onPreviewChange(
                identifierPrefix,
                ChartWheelPreviewState(
                    sourceID: identifierPrefix,
                    accessibilityLabel: wheelAccessibilityLabel,
                    labels: previewLabels,
                    centerPosition: centerPosition
                )
            )
        }

        private func schedulePreviewDismissal() {
            previewDismissWorkItem?.cancel()
            let sourceID = identifierPrefix
            let dismissWorkItem = DispatchWorkItem { [weak self] in
                guard let self else {
                    return
                }
                isPreviewVisible = false
                onPreviewChange(sourceID, nil)
            }
            previewDismissWorkItem = dismissWorkItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.45,
                execute: dismissWorkItem
            )
        }

        private func styleVisibleCells() {
            guard let collectionView else {
                return
            }
            let visibleCenterY = collectionView.contentOffset.y
                + collectionView.bounds.height / 2
            let centeredRow = centeredVisibleRow() ?? selectedRow

            for case let cell as ChartWheelCollectionCell
                in collectionView.visibleCells {
                guard let indexPath = collectionView.indexPath(for: cell) else {
                    continue
                }
                let distance = cell.center.y - visibleCenterY
                let progress = min(abs(distance) / rowStride, 1)
                let angle = min(max(distance / rowStride, -1), 1) * 0.76
                var transform = CATransform3DIdentity
                transform = CATransform3DRotate(
                    transform,
                    angle,
                    1,
                    0,
                    0
                )
                transform = CATransform3DScale(
                    transform,
                    1 - progress * 0.008,
                    1,
                    1
                )
                cell.layer.transform = transform
                cell.alpha = 1 - progress * 0.86

                let isCurrent = indexPath.item == centeredRow
                cell.setCurrent(isCurrent)
                if isCurrent {
                    cell.accessibilityIdentifier =
                        "\(identifierPrefix)-current"
                } else if indexPath.item == centeredRow - 1 {
                    cell.accessibilityIdentifier =
                        "\(identifierPrefix)-previous"
                } else if indexPath.item == centeredRow + 1 {
                    cell.accessibilityIdentifier =
                        "\(identifierPrefix)-next"
                } else {
                    cell.accessibilityIdentifier = nil
                }
                cell.accessibilityLabel = labelText(
                    items[logicalIndex(for: indexPath.item)]
                )
                cell.accessibilityHint = isCurrent
                    ? "当前\(wheelAccessibilityLabel)"
                    : "轻点切换\(wheelAccessibilityLabel)"
            }
        }

        private func centeredVisibleRow() -> Int? {
            guard let collectionView else {
                return nil
            }
            let centerY = collectionView.contentOffset.y
                + collectionView.bounds.height / 2
            return collectionView.indexPathsForVisibleItems.min { lhs, rhs in
                let lhsY = collectionView.layoutAttributesForItem(at: lhs)?
                    .center.y ?? .greatestFiniteMagnitude
                let rhsY = collectionView.layoutAttributesForItem(at: rhs)?
                    .center.y ?? .greatestFiniteMagnitude
                return abs(lhsY - centerY) < abs(rhsY - centerY)
            }?.item
        }

        private func item(at row: Int) -> Item? {
            guard !items.isEmpty else {
                return nil
            }
            return items[logicalIndex(for: row)]
        }

        private func logicalIndex(for row: Int) -> Int {
            guard !items.isEmpty else {
                return 0
            }
            return ((row % items.count) + items.count) % items.count
        }

        private func middleRow(for logicalIndex: Int) -> Int {
            guard items.count > 1 else {
                return 0
            }
            return (repetitionCount / 2) * items.count + logicalIndex
        }

        private func nearestRow(
            for logicalIndex: Int,
            around row: Int
        ) -> Int {
            guard items.count > 1 else {
                return 0
            }
            let cycle = row / items.count
            return [cycle - 1, cycle, cycle + 1]
                .map { $0 * items.count + logicalIndex }
                .filter {
                    $0 >= 0 && $0 < items.count * repetitionCount
                }
                .min(by: { abs($0 - row) < abs($1 - row) })
                ?? middleRow(for: logicalIndex)
        }

        private func recenterIfNeeded() {
            guard items.count > 1,
                  selectedRow < items.count * 10
                    || selectedRow > items.count * (repetitionCount - 10)
            else {
                return
            }
            selectedRow = middleRow(
                for: logicalIndex(for: selectedRow)
            )
            synchronizeSelection(animated: false)
        }
    }
}

private final class ChartWheelSnapFlowLayout: UICollectionViewFlowLayout {
    override func targetContentOffset(
        forProposedContentOffset proposedContentOffset: CGPoint,
        withScrollingVelocity velocity: CGPoint
    ) -> CGPoint {
        guard let collectionView else {
            return proposedContentOffset
        }
        let visibleCenterY = proposedContentOffset.y
            + collectionView.bounds.height / 2
        let targetRect = CGRect(
            x: 0,
            y: proposedContentOffset.y,
            width: collectionView.bounds.width,
            height: collectionView.bounds.height
        )
        guard let attributes = layoutAttributesForElements(in: targetRect),
              let nearest = attributes
                .filter({ $0.representedElementCategory == .cell })
                .min(by: {
                    abs($0.center.y - visibleCenterY)
                        < abs($1.center.y - visibleCenterY)
                }) else {
            return proposedContentOffset
        }
        let proposedY = nearest.center.y
            - collectionView.bounds.height / 2
        let minimumY = -collectionView.adjustedContentInset.top
        let maximumY = collectionViewContentSize.height
            - collectionView.bounds.height
            + collectionView.adjustedContentInset.bottom
        return CGPoint(
            x: proposedContentOffset.x,
            y: min(max(proposedY, minimumY), maximumY)
        )
    }
}

private final class ChartWheelCollectionCell: UICollectionViewCell {
    static let reuseID = "ChartWheelCollectionCell"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.68
        label.textColor = UIColor(BinanceTheme.primaryText)
        label.isAccessibilityElement = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            label.topAnchor.constraint(equalTo: contentView.topAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        layer.transform = CATransform3DIdentity
        alpha = 1
        accessibilityIdentifier = nil
    }

    func setText(_ text: String) {
        label.text = text
    }

    func setCurrent(_ isCurrent: Bool) {
        label.font = .systemFont(
            ofSize: 15,
            weight: isCurrent ? .semibold : .regular
        )
        label.textColor = isCurrent
            ? UIColor(BinanceTheme.primaryText)
            : UIColor(BinanceTheme.secondaryText)
        accessibilityTraits = isCurrent
            ? [.button, .selected]
            : .button
    }
}

private struct IndicatorSettingsControlIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / 18
        let scaleY = rect.height / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * scaleX, y: y * scaleY)
        }

        var path = Path()
        path.move(to: point(2, 1.5))
        path.addLine(to: point(2, 16))
        path.addLine(to: point(16.5, 16))

        path.move(to: point(4, 12.5))
        path.addLine(to: point(7.5, 9))
        path.addLine(to: point(10.5, 11.5))
        path.addLine(to: point(16, 6))

        path.move(to: point(10, 3))
        path.addLine(to: point(12, 5))
        path.addLine(to: point(14, 3))

        return path
    }
}

private enum MarketDisplayFormatter {
    static func price(_ value: Double) -> String { DisplayNumber.text(value, grouped: true) }
}

/// Favorite intervals are chronological shortcuts; selecting another supported interval never changes the favorites.
enum ChartIntervalPreferences {
    static let storageKey = "integrated.chart.favoriteIntervals"
    static let defaultValue = "3m,5m,15m,1h,4h,1d"
    static let maximumCount = 6
    static func favorites(_ value: String) -> [MarketKlineInterval] {
        let enabled = Set(value.split(separator: ",").compactMap { MarketKlineInterval(rawValue: String($0)) })
        if enabled.isEmpty, value != defaultValue { return favorites(defaultValue) }
        return Array(MarketKlineInterval.allCases.filter { enabled.contains($0) }.prefix(maximumCount))
    }
    static func visible(_ value: String, selected: MarketKlineInterval) -> [MarketKlineInterval] {
        var shortcuts = favorites(value)
        if !shortcuts.contains(selected) {
            if shortcuts.count == maximumCount { shortcuts.removeLast() }
            shortcuts.append(selected)
        }
        let enabled = Set(shortcuts)
        return MarketKlineInterval.allCases.filter { enabled.contains($0) }
    }
    static func toggling(_ interval: MarketKlineInterval, in value: String) -> String {
        var enabled = Set(favorites(value))
        if enabled.contains(interval) {
            guard enabled.count > 1 else { return value }
            enabled.remove(interval)
        } else {
            guard enabled.count < maximumCount else { return value }
            enabled.insert(interval)
        }
        return MarketKlineInterval.allCases.filter { enabled.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

private struct ChartAutoFitToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 4) {
                configuration.label
                    .foregroundStyle(BinanceTheme.secondaryText)
                Capsule()
                    .fill(configuration.isOn ? BinanceTheme.positive : BinanceTheme.border)
                    .frame(width: 28, height: 17)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 13, height: 13).padding(2)
                    }
            }.frame(height: 38).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(configuration.isOn ? "1" : "0")
            .accessibilityAddTraits(.isButton)
    }
}

private struct ChartIntervalSettingsView: View {
    let selection: MarketKlineInterval
    @Binding var favorites: String
    let onSelect: (MarketKlineInterval) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("时间周期").font(.system(size: 20, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("关闭")
            }.padding(.horizontal, 20).padding(.top, 12)
            Text("点击周期切换图表；星标管理快捷栏，保留 1–6 个。")
                .font(.system(size: 12)).foregroundStyle(BinanceTheme.secondaryText)
                .padding(.horizontal, 20).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    intervalSection("图表周期", intervals: visibleIntervals)
                    intervalSection("备选周期", intervals: MarketKlineInterval.allCases.filter { !visibleIntervals.contains($0) })
                    Button("恢复默认周期") { favorites = ChartIntervalPreferences.defaultValue }
                        .font(.system(size: 12))
                        .buttonStyle(.plain).foregroundStyle(BinanceTheme.accentText)
                        .frame(maxWidth: .infinity, minHeight: 32).padding(.top, 2)
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }.scrollIndicators(.hidden)
        }.foregroundStyle(BinanceTheme.primaryText).background(BinanceTheme.background)

    }
    private var visibleIntervals: [MarketKlineInterval] {
        ChartIntervalPreferences.visible(favorites, selected: selection)
    }
    private func intervalSection(_ title: String, intervals: [MarketKlineInterval]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(BinanceTheme.secondaryText)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 4) {
                ForEach(intervals) { intervalOption($0) }
            }
        }
    }
    private func intervalOption(_ interval: MarketKlineInterval) -> some View {
        let selected = interval == selection
        let enabled = ChartIntervalPreferences.favorites(favorites).contains(interval)
        return HStack(spacing: 0) {
            Button {
                onSelect(interval); dismiss()
            } label: {
                Text(interval.title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? WebTheme.color(0x735500, 0xFFE58A) : BinanceTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("interval-settings.select." + interval.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            Button { favorites = ChartIntervalPreferences.toggling(interval, in: favorites) } label: {
                Image(systemName: enabled ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(enabled ? Color(red: 0.86, green: 0.62, blue: 0) : BinanceTheme.secondaryText)
                    .frame(width: 28, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(interval.title + (enabled ? "停用快捷周期" : "启用快捷周期"))
                .accessibilityIdentifier("interval-settings.favorite." + interval.rawValue)
                .disabled(!enabled && ChartIntervalPreferences.favorites(favorites).count >= ChartIntervalPreferences.maximumCount)
        }.background {
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? WebTheme.color(0xFFF5CC, 0x51451F) : BinanceTheme.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? BinanceTheme.accent : BinanceTheme.border, lineWidth: 1)
                }.frame(height: 32)
        }
    }
}
