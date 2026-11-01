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
    @State private var selectedMarket: MarketSnapshot
    @State private var selectedInterval: MarketKlineInterval

    private let availableMarkets: [MarketSnapshot]
    private let apiClient: any APIClient
    private let realtimeClient: RealtimeClient
    private let onClose: (() -> Void)?

    init(
        market: MarketSnapshot,
        availableMarkets: [MarketSnapshot] = [],
        apiClient: any APIClient,
        realtimeClient: RealtimeClient,
        initialInterval: MarketKlineInterval = .oneHour,
        onClose: (() -> Void)? = nil
    ) {
        _selectedMarket = State(initialValue: market)
        _selectedInterval = State(initialValue: initialInterval)
        self.availableMarkets = availableMarkets
        self.apiClient = apiClient
        self.realtimeClient = realtimeClient
        self.onClose = onClose
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
            onClose: onClose
        )
        .id(selectedMarket.symbol)
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
    @AppStorage("integrated.chart.orderType") private var nativeOrderType = "limit"
    @State private var showsNativeTicket = false
    @StateObject private var viewModel: MarketChartViewModel
    let availableMarkets: [MarketSnapshot]
    let onSelectMarket: (MarketSnapshot, MarketKlineInterval) -> Void
    let onIntervalChange: (MarketKlineInterval) -> Void
    let onClose: (() -> Void)?
    @State private var isFavorite = true
    @State private var isIndicatorSettingsPresented = false
    @State private var isOrderSettingsPresented = false
    @State private var isLoadingOrderSettings = false
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
        onClose: (() -> Void)?
    ) {
        self.availableMarkets = availableMarkets
        self.onSelectMarket = onSelectMarket
        self.onIntervalChange = onIntervalChange
        self.onClose = onClose
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

                GeometryReader { geometry in
                    ScrollView(showsIndicators: false) {
                        chart
                            .frame(
                                width: geometry.size.width,
                                height: chartContentHeight(
                                    availableHeight: geometry.size.height
                                )
                            )
                    }
                    .accessibilityIdentifier("market-chart-detail-scroll")
                }

                quickSwitcherBar
                    .allowsHitTesting(
                        orderDrawing == nil
                    )
                    .opacity(orderDrawing == nil ? 1 : 0.42)

                tradeBar
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
        .onDisappear {
            viewModel.stop()
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
        .webSheet(isPresented: $showsNativeTicket) {
            NavigationStack {
                USDTTradeView(initialStop: orderDrawing.map { String(format: "%.12g", $0.stopLossPrice) } ?? "",
                              initialLimit: orderDrawing?.entryPrice.map { String(format: "%.12g", $0) } ?? "")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showsNativeTicket = false } } }
            }.environmentObject(usdt)
        }
    }

    private var fixedHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                BinanceBackButton(action: onClose)
                    .accessibilityIdentifier("market-chart-back")

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(viewModel.market.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(BinanceTheme.primaryText)

                        Text("永续")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(BinanceTheme.secondaryText)
                            .padding(.horizontal, 4)
                            .frame(height: 16)
                            .background(
                                BinanceTheme.elevated,
                                in: RoundedRectangle(cornerRadius: 3)
                            )

                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
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
                }

                Spacer()

                Button {
                    isFavorite.toggle()
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(
                            isFavorite
                                ? BinanceTheme.accentText
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
                diagnostics: viewModel.loadDiagnostics,
                onFirstFramePresented: { epoch, time in
                    viewModel.chartFirstFramePresented(epoch: epoch, at: time)
                },
                onNeedsOlderHistory: {
                    viewModel.requestOlderHistory()
                },
                onPriceProjectionChange: { projection in
                    chartPriceProjection = projection
                }
            )

            if let projection = chartPriceProjection,
               let drawing = orderDrawing {
                ChartOrderDrawingOverlay(
                    drawing: Binding(
                        get: { orderDrawing ?? drawing },
                        set: { orderDrawing = $0 }
                    ),
                    projection: projection,
                    formatPrice: formatPrice
                )
                .transition(.opacity)
            }
        }
        .accessibilityIdentifier("market-chart-plot")
    }

    private func chartContentHeight(availableHeight: CGFloat) -> CGFloat {
        CGFloat(ChartPanelLayout.scrollContentHeightPoints(
            availableHeightPoints: Double(availableHeight),
            indicatorPanelCount:
                viewModel.chartIndicatorPanelCount
        ))
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

    private var tradeBar: some View {
        Group {
            if let drawing = orderDrawing {
                HStack(spacing: 9) {
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            orderDrawing = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(BinanceTheme.primaryText)
                            .frame(width: 44, height: 44)
                            .background(
                                BinanceTheme.elevated,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(
                                        BinanceTheme.border,
                                        lineWidth: 0.8
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("取消划线下单")
                    .accessibilityIdentifier(
                        "market-chart-order-cancel"
                    )

                    Button {
                        submitOrder(drawing)
                    } label: {
                        HStack(spacing: 7) {
                            Text(drawing.side.title)
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 7)
                                .frame(height: 22)
                                .background(
                                    Color.black.opacity(0.16),
                                    in: Capsule()
                                )

                            Text("下单")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(BinanceTheme.onTradeAction)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: BinanceTheme.Layout.minimumTapSize)
                        .background(
                            drawing.side == .long
                                ? ChartPalette.actionPositive
                                : ChartPalette.actionNegative,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开开仓表单并确认订单")
                    .accessibilityIdentifier(
                        "market-chart-order-submit"
                    )
                }
            } else {
                HStack(spacing: 8) {
                    tradeTool(
                        title: "指标",
                        action: { isIndicatorSettingsPresented = true }
                    ) {
                        indicatorSettingsIcon
                    }
                    .accessibilityIdentifier(
                        "market-chart-indicator-settings-shortcut"
                    )
                    .accessibilityHint("打开指标参数设置")
                    tradeTool(
                        "gauge.with.dots.needle.67percent",
                        title: leverageToolTitle,
                        action: presentLeverageSettings
                    )
                    tradeTool(
                        "gearshape",
                        title: "设置"
                    ) {
                        isOrderSettingsPresented = true
                    }

                    Button {
                        beginOrderDrawing(side: .long)
                    } label: {
                        Text("做多")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(BinanceTheme.onTradeAction)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: BinanceTheme.Layout.minimumTapSize)
                            .background(
                                ChartPalette.actionPositive,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("market-chart-order-long")

                    Button {
                        beginOrderDrawing(side: .short)
                    } label: {
                        Text("做空")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(BinanceTheme.onTradeAction)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: BinanceTheme.Layout.minimumTapSize)
                            .background(
                                ChartPalette.actionNegative,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("market-chart-order-short")
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(BinanceTheme.background)
    }

    private var quickSwitcherBar: some View {
        MarketChartQuickSwitcher(
            markets: availableMarkets,
            selectedMarket: viewModel.market,
            selectedInterval: viewModel.interval,
            onSelectMarket: {
                onSelectMarket($0, viewModel.interval)
            },
            onSelectInterval: viewModel.selectInterval,
            activeIndicators: Set(
                MarketChartIndicatorCatalog.all.filter(
                    viewModel.isChartIndicatorActive
                )
            ),
            onToggleIndicator: viewModel.toggleChartIndicator,
            onPreviewChange: updateWheelPreview
        )
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
        action: @escaping () -> Void
    ) -> some View {
        tradeTool(title: title, action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
        }
    }

    private func tradeTool<Icon: View>(
        title: String,
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
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }

    private func beginOrderDrawing(side: ChartOrderSide) {
        guard !isLoadingOrderSettings else { return }
        isLoadingOrderSettings = true
        Task {
            defer { isLoadingOrderSettings = false }
            await usdt.refresh()
            guard usdt.isBound else { toastCenter.warning("请先在我的页面绑定 API"); return }
            guard let risk = Decimal(string: usdt.riskAmount), risk > 0,
                  let drawing = ChartOrderDrawingState.make(side: side,
                    entryOrderType: nativeOrderType == "market" ? .market : .limit,
                    referencePrice: viewModel.currentPrice,
                    riskAmount: NSDecimalNumber(decimal: risk).doubleValue) else {
                toastCenter.warning("价格或止损金额暂不可用"); return
            }
            orderDrawing = drawing
        }
    }

    private func submitOrder(_ drawing: ChartOrderDrawingState) {
        usdt.selectedSymbol = viewModel.market.symbol
        showsNativeTicket = true
    }

    private var leverageToolTitle: String { "自动杠杆" }

    private func presentLeverageSettings() {
        toastCenter.warning("杠杆由服务端按原 USDT 风控规则自动设置")
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

private struct MarketChartQuickSwitcher: View {
    let markets: [MarketSnapshot]
    let selectedMarket: MarketSnapshot
    let selectedInterval: MarketKlineInterval
    let onSelectMarket: (MarketSnapshot) -> Void
    let onSelectInterval: (MarketKlineInterval) -> Void
    let activeIndicators: Set<String>
    let onToggleIndicator: (String) -> Void
    let onPreviewChange: (String, ChartWheelPreviewState?) -> Void

    var body: some View {
        HStack(spacing: 16) {
            MarketChartQuickIndicatorStrip(
                activeIndicators: activeIndicators,
                onToggle: onToggleIndicator
            )
            .frame(maxWidth: .infinity)
            .frame(height: 52)

            ChartWheelSwitcher(
                items: markets,
                selectedID: selectedMarket.id,
                width: 68,
                accessibilityLabel: "币种",
                identifierPrefix: "market-chart-quick-symbol",
                label: \MarketSnapshot.symbol,
                onSelect: onSelectMarket,
                onPreviewChange: onPreviewChange
            )
            .frame(width: 68, height: 52)

            ChartWheelSwitcher(
                items: MarketKlineInterval.allCases,
                selectedID: selectedInterval.id,
                width: 52,
                accessibilityLabel: "时间间隔",
                identifierPrefix: "market-chart-quick-interval",
                label: \MarketKlineInterval.title,
                onSelect: onSelectInterval,
                onPreviewChange: onPreviewChange
            )
            .frame(width: 52, height: 52)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(BinanceTheme.background)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BinanceTheme.navigationBorder.opacity(0.75))
                .frame(height: 0.5)
        }
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
            .frame(height: 52)
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
                .frame(height: 44)
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
    static func price(_ value: Double) -> String {
        let basis = abs(value)
        let fractionDigits: Int
        if basis >= 1_000 {
            fractionDigits = 1
        } else if basis >= 1 {
            fractionDigits = 3
        } else {
            fractionDigits = 5
        }
        return decimal(
            value,
            minimumFractionDigits: fractionDigits,
            maximumFractionDigits: fractionDigits
        )
    }

    private static func decimal(
        _ value: Double,
        minimumFractionDigits: Int,
        maximumFractionDigits: Int
    ) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "%.\(maximumFractionDigits)f", value)
    }
}
