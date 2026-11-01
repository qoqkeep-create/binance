import SwiftUI

private enum MarketSortField: Equatable {
    case symbol
    case quoteVolume
    case price
    case changePercent

    var title: String {
        switch self {
        case .symbol:
            return "名称"
        case .quoteVolume:
            return "成交额"
        case .price:
            return "最新价"
        case .changePercent:
            return "24小时涨跌幅"
        }
    }

    var initialDirection: MarketSortDirection {
        self == .symbol ? .ascending : .descending
    }
}

private enum MarketSortDirection: Equatable {
    case ascending
    case descending

    var reversed: MarketSortDirection {
        self == .ascending ? .descending : .ascending
    }
}

private struct MarketSortSelection: Equatable {
    let field: MarketSortField
    let direction: MarketSortDirection
}

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let apiClient: any APIClient
    @ObservedObject var realtimeClient: RealtimeClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @Binding var isShowingMarketSearch: Bool
    @Binding var isShowingMarketSettings: Bool
    @Binding var selectedMarket: MarketSnapshot?

    @State private var sortSelection: MarketSortSelection?

    private var markets: [MarketSnapshot] {
        let visibleMarkets = viewModel.markets(onlyVisible: true)
        guard let sortSelection else {
            return visibleMarkets
        }

        return visibleMarkets.sorted { left, right in
            let comparison = compare(
                left,
                right,
                by: sortSelection.field
            )
            if comparison == .orderedSame {
                return left.symbol < right.symbol
            }

            switch sortSelection.direction {
            case .ascending:
                return comparison == .orderedAscending
            case .descending:
                return comparison == .orderedDescending
            }
        }
    }

    var body: some View {
        ZStack {
            BinanceTheme.marketBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                searchHeader
                    .padding(
                        .horizontal,
                        BinanceTheme.Layout.pageHorizontalPadding
                    )
                    .padding(.top, 7)
                    .padding(.bottom, 13)

                marketHeader
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)

                marketTableHeader
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if markets.isEmpty {
                            emptyState
                                .padding(.top, 56)
                        }

                        ForEach(markets) { market in
                            Button {
                                selectedMarket = market
                            } label: {
                                MarketTickerRow(market: market)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .refreshable {
                    realtimeClient.requestLatencyTest()
                    await viewModel.refresh()
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            isVisible = true
            realtimeClient.setLatencyMonitoring(scenePhase == .active)
        }
        .onDisappear {
            isVisible = false
            realtimeClient.setLatencyMonitoring(false)
        }
        .onChange(of: scenePhase) { _, phase in
            realtimeClient.setLatencyMonitoring(isVisible && phase == .active)
        }
        .navigationDestination(isPresented: $isShowingMarketSearch) {
            MarketSearchView(
                apiClient: apiClient,
                dashboardViewModel: viewModel
            )
        }
        .navigationDestination(isPresented: $isShowingMarketSettings) {
            MarketListSettingsView(viewModel: viewModel)
        }
    }

    private var searchHeader: some View {
        Button {
            isShowingMarketSearch = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(BinanceTheme.Typography.text(.footnote, weight: .medium))

                Text("搜索币种/币对/合约")
                    .font(BinanceTheme.Typography.text(.footnote))

                Spacer(minLength: 0)
            }
            .foregroundStyle(BinanceTheme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: BinanceTheme.Layout.compactSearchFieldHeight)
            .background(
                BinanceTheme.elevated,
                in: RoundedRectangle(
                    cornerRadius:
                        BinanceTheme.Layout.compactSearchCornerRadius,
                    style: .continuous
                )
            )
            .padding(
                .vertical,
                (
                    BinanceTheme.Layout.compactSearchTapHeight
                    - BinanceTheme.Layout.compactSearchFieldHeight
                ) / 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索币种、币对或合约")
    }

    private var marketHeader: some View {
        HStack {
            Text("合约")
                .font(BinanceTheme.Typography.selectedTab)
                .foregroundStyle(BinanceTheme.primaryText)

            Spacer()

            MarketLatencyBadge(latency: realtimeClient.latency,
                isRefreshing: realtimeClient.isTestingLatency) {
                realtimeClient.requestLatencyTest()
            }
                .padding(.trailing, 6)
            Button {
                isShowingMarketSettings = true
            } label: {
                Image(systemName: "pencil.line")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(BinanceTheme.secondaryText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑行情列表")
        }
    }

    private var marketTableHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                sortHeaderButton("名称", field: .symbol)
                Text("/")
                sortHeaderButton("成交额", field: .quoteVolume)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            sortHeaderButton("最新价", field: .price)
                .frame(width: 78, alignment: .trailing)

            sortHeaderButton(
                "24h\n涨跌幅",
                field: .changePercent
            )
            .frame(width: 76, alignment: .trailing)
        }
        .font(BinanceTheme.Typography.tableHeader)
        .foregroundStyle(BinanceTheme.secondaryText)
    }

    private func sortHeaderButton(
        _ title: String,
        field: MarketSortField
    ) -> some View {
        Button {
            toggleSort(field)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .multilineTextAlignment(.center)
                MarketSortIndicator(
                    direction:
                        sortSelection?.field == field
                        ? sortSelection?.direction
                        : nil
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sortAccessibilityLabel(for: field))
    }

    private func toggleSort(_ field: MarketSortField) {
        if let sortSelection, sortSelection.field == field {
            if sortSelection.direction == field.initialDirection {
                self.sortSelection = MarketSortSelection(
                    field: field,
                    direction: sortSelection.direction.reversed
                )
            } else {
                self.sortSelection = nil
            }
        } else {
            sortSelection = MarketSortSelection(
                field: field,
                direction: field.initialDirection
            )
        }
    }

    private func sortAccessibilityLabel(
        for field: MarketSortField
    ) -> String {
        if let sortSelection, sortSelection.field == field {
            if sortSelection.direction != field.initialDirection {
                return "取消\(field.title)排序"
            }

            let nextDirection = sortSelection.direction.reversed
            let directionText =
                nextDirection == .ascending ? "升序" : "降序"
            return "按\(field.title)\(directionText)排列"
        }

        let nextDirection = field.initialDirection
        let directionText =
            nextDirection == .ascending ? "升序" : "降序"
        return "按\(field.title)\(directionText)排列"
    }

    private func compare(
        _ left: MarketSnapshot,
        _ right: MarketSnapshot,
        by field: MarketSortField
    ) -> ComparisonResult {
        switch field {
        case .symbol:
            return left.symbol.localizedStandardCompare(right.symbol)
        case .quoteVolume:
            return compare(left.quoteVolume24h, right.quoteVolume24h)
        case .price:
            return compare(left.price, right.price)
        case .changePercent:
            return compare(
                left.changePercent24h,
                right.changePercent24h
            )
        }
    }

    private func compare(
        _ left: Double,
        _ right: Double
    ) -> ComparisonResult {
        if left < right {
            return .orderedAscending
        }
        if left > right {
            return .orderedDescending
        }
        return .orderedSame
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(BinanceTheme.secondaryText)

            Text("暂无行情")
                .font(BinanceTheme.Typography.text(.headline))
                .foregroundStyle(BinanceTheme.primaryText)

            Text("可在编辑列表中打开显示")
                .font(BinanceTheme.Typography.text(.subheadline))
                .foregroundStyle(BinanceTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MarketLatencyBadge: View {
    let latency: RealtimeLatency
    let isRefreshing: Bool
    let retry: () -> Void
    private var showsProgress: Bool { isRefreshing || latency == .measuring }
    private var color: Color {
        switch latency.quality {
        case .good: BinanceTheme.positive
        case .fair: BinanceTheme.accentText
        case .poor: BinanceTheme.negative
        }
    }
    private var bars: Int {
        switch latency.quality { case .good: 4; case .fair: 3; case .poor: 1 }
    }
    var body: some View {
        Button(action: retry) {
          HStack(spacing: 5) {
            ZStack {
                if showsProgress {
                    ProgressView().progressViewStyle(.circular).controlSize(.mini).tint(color)
                        .scaleEffect(0.65)
                }
            }.frame(width: 10, height: 10).accessibilityHidden(true)
            Text(latency == .measuring ? "-- ms" : latency.text)
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .contentTransition(.identity)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < bars ? color : BinanceTheme.secondaryText.opacity(0.2))
                        .frame(width: 3, height: CGFloat(4 + index * 3))
                }
            }.accessibilityHidden(true)
          }.foregroundStyle(color).frame(minWidth: 66, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("网络延迟")
            .accessibilityValue(latency.text + ", " + latency.quality.rawValue
                + (showsProgress ? ", 正在刷新" : ""))
            .accessibilityHint("点击立即重新测量")
            .accessibilityIdentifier("market.latency")
    }
}

private struct MarketSortIndicator: View {
    let direction: MarketSortDirection?

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: "triangle.fill")
                .foregroundStyle(color(for: .ascending))

            Image(systemName: "triangle.fill")
                .rotationEffect(.degrees(180))
                .foregroundStyle(color(for: .descending))
        }
        .font(.system(size: 4, weight: .black))
        .frame(width: 7, height: 11)
        .accessibilityHidden(true)
    }

    private func color(
        for candidate: MarketSortDirection
    ) -> Color {
        if direction == candidate {
            return BinanceTheme.primaryText
        }
        return BinanceTheme.secondaryText.opacity(
            direction == nil ? 0.7 : 0.35
        )
    }
}

struct MarketTickerRow: View {
    let market: MarketSnapshot

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(market.symbol)
                        .font(BinanceTheme.Typography.listSymbol)
                        .foregroundStyle(BinanceTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text("永续")
                        .font(BinanceTheme.Typography.smallLabel)
                        .foregroundStyle(BinanceTheme.secondaryText)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            BinanceTheme.elevated,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                        .padding(.leading, 6)
                }

                Text(market.detailText)
                    .font(BinanceTheme.Typography.marketDetail)
                    .foregroundStyle(BinanceTheme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text(market.formattedPrice)
                    .font(BinanceTheme.Typography.marketPrice)
                    .foregroundStyle(BinanceTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text("$\(market.formattedPrice)")
                    .font(BinanceTheme.Typography.marketPriceSecondary)
                    .foregroundStyle(BinanceTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 78, alignment: .trailing)

            Text(market.formattedChange)
                .font(BinanceTheme.Typography.marketChange)
                .foregroundStyle(.white)
                .frame(width: 76, height: BinanceTheme.Layout.marketChangeHeight)
                .background(
                    market.isPositive
                        ? BinanceTheme.positiveFill
                        : BinanceTheme.negativeFill,
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
        }
        .frame(minHeight: BinanceTheme.Layout.marketRowHeight)
        .contentShape(Rectangle())
    }
}
