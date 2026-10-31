import SwiftUI

struct PositionCenterView: View {
    let isVisible: Bool
    let onSelectPosition: (
        TradingPositionSnapshot,
        Decimal,
        String
    ) -> Void

    @EnvironmentObject private var toastCenter: AppToastCenter
    @StateObject private var viewModel: PositionCenterViewModel
    @StateObject private var bindingViewModel: SettingsAccountViewModel
    @State private var showsAPIBinding = false
    @State private var selectedSection: PositionCenterSection = .positions
    @State private var realizedPnlPosition: TradingPositionSnapshot?

    init(
        apiClient: any APIClient,
        realtimeClient: RealtimeClient,
        isVisible: Bool,
        restoreMarketSubscriptions: @escaping () -> Void,
        onSelectPosition: @escaping (
            TradingPositionSnapshot,
            Decimal,
            String
        ) -> Void
    ) {
        self.isVisible = isVisible
        self.onSelectPosition = onSelectPosition
        _bindingViewModel = StateObject(
            wrappedValue: SettingsAccountViewModel(apiClient: apiClient)
        )
        _viewModel = StateObject(
            wrappedValue: PositionCenterViewModel(
                apiClient: apiClient,
                realtimeClient: realtimeClient,
                restoreMarketSubscriptions: restoreMarketSubscriptions
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionTabs

            Rectangle()
                .fill(BinanceTheme.border.opacity(0.7))
                .frame(height: 0.5)

            ScrollView {
                LazyVStack(spacing: 12) {
                    if let errorMessage = viewModel.errorMessage {
                        errorBanner(errorMessage)
                    }

                    if let snapshot = viewModel.snapshot,
                       snapshot.syncStatus?.uppercased() != "SYNCED" {
                        syncNotice(snapshot.syncStatus)
                    }

                    content
                }
                .padding(.horizontal, 15)
                .padding(.bottom, 24)
            }
            .refreshable {
                await viewModel.refresh()
            }
        }
        .background(BinanceTheme.navigationBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: isVisible) {
            guard isVisible else { return }
            await viewModel.monitor()
        }
        .navigationDestination(isPresented: $showsAPIBinding) {
            BinanceAPIBindingView(viewModel: bindingViewModel)
                .task {
                    do { try await bindingViewModel.load() }
                    catch { toastCenter.error(error.localizedDescription) }
                }
        }
        .onChange(of: showsAPIBinding) { _, isPresented in
            if !isPresented { Task { await viewModel.refresh() } }
        }
        .sheet(item: $realizedPnlPosition) { position in
            PositionRealizedPnlDetailView(
                position: position,
                quoteAsset: viewModel.snapshot?.quoteAsset ?? "USDC"
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(BinanceTheme.navigationBackground)
        }
    }

    private var sectionTabs: some View {
        HStack(spacing: 0) {
            ForEach(PositionCenterSection.allCases) { section in
                let selected = selectedSection == section
                Button {
                    selectedSection = section
                } label: {
                    VStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Text(section.title)

                            if count(for: section) > 0 {
                                Text("\(count(for: section))")
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(
                                        selected
                                            ? BinanceTheme.primaryText
                                            : BinanceTheme.secondaryText
                                    )
                            }
                        }
                        .font(BinanceTheme.Typography.modalTitle)
                        .foregroundStyle(BinanceTheme.primaryText)
                        .frame(maxWidth: .infinity)

                        RoundedRectangle(cornerRadius: 1)
                            .fill(
                                selected
                                    ? BinanceTheme.accent
                                    : Color.clear
                            )
                            .frame(width: 28, height: 2)
                    }
                    .padding(.top, 5)
                    .frame(height: 51)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .accessibilityIdentifier("position-center-tabs")
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, viewModel.snapshot == nil {
            loadingState
        } else if viewModel.account == nil {
            emptyState(
                icon: "link.badge.plus",
                title: "尚未绑定 Binance 账户",
                message: "点击上方图标绑定 Binance API Key",
                action: { showsAPIBinding = true }
            )
        } else if let snapshot = viewModel.snapshot {
            switch selectedSection {
            case .positions:
                if snapshot.positions.isEmpty {
                    emptyState(
                        icon: "briefcase",
                        title: "暂无持仓",
                        message: "当前没有未平仓合约"
                    )
                } else {
                    ForEach(snapshot.positions) { position in
                        OpenPositionCard(
                            position: position,
                            quoteAsset: snapshot.quoteAsset,
                            latestPrice: viewModel.latestPrice(
                                for: position
                            ),
                            totalMarginBalance: viewModel.liveMarginBalance(),
                            isActing: viewModel.isActing(on: position.id),
                            onOpenChart: { currentPrice in
                                onSelectPosition(
                                    position,
                                    currentPrice,
                                    snapshot.quoteAsset
                                )
                            },
                            onShowRealizedPnl: {
                                realizedPnlPosition = position
                            },
                            onMarketClose: {
                                closePosition(position, orderType: "MARKET")
                            },
                            onMakerAction: {
                                makerAction(position)
                            }
                        )
                    }
                }

            case .limitOrders:
                if snapshot.limitOrders.isEmpty {
                    emptyState(
                        icon: "doc.text.magnifyingglass",
                        title: "暂无限价委托",
                        message: "当前没有等待成交的限价单"
                    )
                } else {
                    ForEach(snapshot.limitOrders) { order in
                        LimitOrderCard(
                            order: order,
                            quoteAsset: snapshot.quoteAsset,
                            isCancelling: viewModel.isCancelling(order.id),
                            onCancel: { cancelEntryOrder(order) }
                        )
                    }
                }

            case .history:
                if snapshot.historyTruncated {
                    historyTruncatedNotice
                }
                if snapshot.historyPositions.isEmpty {
                    emptyState(
                        icon: "clock.arrow.circlepath",
                        title: "暂无历史持仓",
                        message: "完整平仓后会汇总盈亏与手续费"
                    )
                } else {
                    ForEach(snapshot.historyPositions) { position in
                        PositionHistoryCard(
                            position: position,
                            quoteAsset: snapshot.quoteAsset
                        )
                    }
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(BinanceTheme.accent)
            Text("正在同步持仓数据")
                .font(BinanceTheme.Typography.text(.subheadline))
                .foregroundStyle(BinanceTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }

    private var historyTruncatedNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
            Text("成交记录较多，当前仅汇总最近 10,000 笔成交形成的历史持仓。")
                .font(BinanceTheme.Typography.text(.caption))
        }
        .foregroundStyle(BinanceTheme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BinanceTheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(BinanceTheme.negative)

            Text(message)
                .font(BinanceTheme.Typography.text(.caption))
                .foregroundStyle(BinanceTheme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("重试") {
                Task { await viewModel.refresh() }
            }
            .font(BinanceTheme.Typography.text(.caption, weight: .semibold))
            .foregroundStyle(BinanceTheme.accentText)
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            BinanceTheme.negative.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func syncNotice(_ status: String?) -> some View {
        let syncing = ["CONNECTING", "RECONCILING"].contains(
            status?.uppercased() ?? ""
        )
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(BinanceTheme.accentText)
            Text(
                syncing
                    ? "账户正在完成 WebSocket 监听与 REST 对账，数据可能短暂不完整。"
                    : "账户监听尚未同步，当前持仓仅代表最近快照，委托与历史可能不完整。"
            )
            .font(BinanceTheme.Typography.text(.caption))
            .foregroundStyle(BinanceTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            BinanceTheme.accent.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func emptyState(
        icon: String,
        title: String,
        message: String,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 12) {
            if let action {
                Button(action: action) {
                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(BinanceTheme.secondaryText)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("绑定 Binance API")
                .accessibilityIdentifier("position-bind-api")
            } else {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(BinanceTheme.secondaryText)
            }

            Text(title)
                .font(BinanceTheme.Typography.text(.headline, weight: .semibold))
                .foregroundStyle(BinanceTheme.primaryText)

            Text(message)
                .font(BinanceTheme.Typography.text(.subheadline))
                .foregroundStyle(BinanceTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private func count(for section: PositionCenterSection) -> Int {
        guard let snapshot = viewModel.snapshot else { return 0 }
        switch section {
        case .positions:
            return snapshot.positions.count
        case .limitOrders:
            return snapshot.limitOrders.count
        case .history:
            return snapshot.historyPositions.count
        }
    }

    private func cancelEntryOrder(_ order: TradingLimitOrderSnapshot) {
        Task {
            do {
                try await viewModel.cancelEntryOrder(order)
                toastCenter.success("撤单成功")
            } catch is CancellationError {
                return
            } catch {
                let apiError = APIError.map(error)
                guard apiError.shouldPresent else { return }
                toastCenter.error(apiError.localizedDescription)
            }
        }
    }

    private func closePosition(
        _ position: TradingPositionSnapshot,
        orderType: String
    ) {
        Task {
            do {
                try await viewModel.closePosition(
                    position,
                    orderType: orderType
                )
                toastCenter.success(
                    orderType == "MARKET"
                        ? "市价平仓单已提交"
                        : "Maker 平仓委托已提交"
                )
            } catch is CancellationError {
                return
            } catch {
                let apiError = APIError.map(error)
                guard apiError.shouldPresent else { return }
                toastCenter.error(apiError.localizedDescription)
            }
        }
    }

    private func makerAction(_ position: TradingPositionSnapshot) {
        if position.makerCloseOrderId == nil {
            closePosition(position, orderType: "MAKER")
            return
        }
        Task {
            do {
                try await viewModel.cancelMakerClose(position)
                toastCenter.success("Maker 平仓委托已撤销")
            } catch is CancellationError {
                return
            } catch {
                let apiError = APIError.map(error)
                guard apiError.shouldPresent else { return }
                toastCenter.error(apiError.localizedDescription)
            }
        }
    }
}

private enum PositionCenterSection: String, CaseIterable, Identifiable {
    case positions
    case limitOrders
    case history

    var id: Self { self }

    var title: String {
        switch self {
        case .positions: "持仓"
        case .limitOrders: "限价委托"
        case .history: "历史持仓"
        }
    }
}

private struct OpenPositionCard: View {
    let position: TradingPositionSnapshot
    let quoteAsset: String
    let latestPrice: Decimal?
    let totalMarginBalance: Decimal
    let isActing: Bool
    let onOpenChart: (Decimal) -> Void
    let onShowRealizedPnl: () -> Void
    let onMarketClose: () -> Void
    let onMakerAction: () -> Void

    private var direction: String {
        if position.positionSide.uppercased() == "SHORT" {
            return "SHORT"
        }
        if position.positionSide.uppercased() == "LONG" {
            return "LONG"
        }
        return position.quantity < 0 ? "SHORT" : "LONG"
    }

    private var directionColor: Color {
        direction == "LONG" ? BinanceTheme.positive : BinanceTheme.negative
    }

    private var metrics: TradingPositionLiveMetrics {
        TradingPositionLiveMetrics(
            position: position,
            latestPrice: latestPrice,
            totalMarginBalance: totalMarginBalance
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                onOpenChart(metrics.currentPrice)
            } label: {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text(direction == "LONG" ? "多" : "空")
                            .font(BinanceTheme.Typography.text(.caption, weight: .bold))
                            .foregroundStyle(BinanceTheme.onColor)
                            .frame(width: 22, height: 22)
                            .background(
                                directionColor,
                                in: RoundedRectangle(cornerRadius: 3)
                            )

                        Text(position.symbol.uppercased())
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(BinanceTheme.primaryText)

                        positionTag("永续")
                        positionTag("\(marginTitle) \(position.leverage)X")

                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 10)

                    HStack(alignment: .top) {
                        pnlMetric(
                            title: "未实现盈亏 (\(quoteAsset))",
                            value: PositionCenterFormat.signed(
                                metrics.unrealizedProfit,
                                maximumFractionDigits: 2
                            ),
                            colorValue: metrics.unrealizedProfit,
                            alignment: .leading
                        )

                        Spacer()

                        pnlMetric(
                            title: "投资回报率",
                            value: "\(PositionCenterFormat.signed(metrics.roe, maximumFractionDigits: 2))%",
                            colorValue: metrics.roe,
                            alignment: .trailing
                        )
                    }
                    .padding(.bottom, 8)

                    positionMetricRow(
                        (
                            "持仓数量 (\(quoteAsset))",
                            PositionCenterFormat.number(
                                metrics.notional,
                                maximumFractionDigits: 2
                            )
                        ),
                        (
                            "保证金 (\(quoteAsset))",
                            PositionCenterFormat.number(
                                metrics.margin,
                                maximumFractionDigits: 4
                            )
                        ),
                        (
                            "保证金比率",
                            "\(PositionCenterFormat.number(metrics.marginRatio, maximumFractionDigits: 2))%"
                        )
                    )
                    .padding(.bottom, 8)

                    positionMetricRow(
                        (
                            "开仓价格 (\(quoteAsset))",
                            PositionCenterFormat.price(position.entryPrice)
                        ),
                        (
                            "当前价格 (\(quoteAsset))",
                            PositionCenterFormat.price(metrics.currentPrice)
                        ),
                        (
                            "强平价格 (\(quoteAsset))",
                            PositionCenterFormat.priceOrDash(
                                position.liquidationPrice
                            )
                        )
                    )

                    HStack(spacing: 5) {
                        Text("仓位止盈止损")
                            .foregroundStyle(BinanceTheme.secondaryText)
                        Text(takeProfitText)
                            .foregroundStyle(BinanceTheme.positive)
                        Text("/")
                            .foregroundStyle(BinanceTheme.secondaryText)
                        Text(stopLossText)
                            .foregroundStyle(BinanceTheme.negative)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13, weight: .regular).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.top, 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开 \(position.symbol) K线详情")

            Button(action: onShowRealizedPnl) {
                HStack(spacing: 8) {
                    Text("已实现盈亏 (\(quoteAsset))")
                        .foregroundStyle(BinanceTheme.secondaryText)
                    Spacer(minLength: 8)
                    Text(
                        PositionCenterFormat.signed(
                            position.realizedPnl,
                            maximumFractionDigits: 4
                        )
                    )
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(
                        PositionCenterFormat.pnlColor(position.realizedPnl)
                    )
                    Image(systemName: "chevron.right")
                        .font(BinanceTheme.Typography.text(.caption, weight: .semibold))
                        .foregroundStyle(BinanceTheme.secondaryText)
                }
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .contentShape(Rectangle())
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(BinanceTheme.border, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            if let makerPrice = position.makerClosePrice,
               position.makerCloseOrderId != nil {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                    Text(
                        "Maker 平仓等待成交 · \(PositionCenterFormat.price(makerPrice)) \(quoteAsset)"
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BinanceTheme.accentText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }

            HStack(spacing: 8) {
                closeButton(
                    title: isActing ? "处理中" : "市价平仓",
                    action: onMarketClose
                )
                .disabled(isActing || position.makerCloseOrderId != nil)

                closeButton(
                    title: isActing
                        ? "处理中"
                        : position.makerCloseOrderId == nil
                            ? "Maker 平仓"
                            : "撤销 Maker",
                    action: onMakerAction
                )
                .disabled(
                    isActing
                        || (position.makerCloseOrderId != nil
                            && position.makerCloseCancelable != true)
                )
            }
            .padding(.top, 12)
            .opacity(isActing ? 0.58 : 1)

            Rectangle()
                .fill(BinanceTheme.border.opacity(0.7))
                .frame(height: 0.5)
                .padding(.top, 16)
        }
        .padding(.top, 14)
        .accessibilityIdentifier("position-card-\(position.id)")
    }

    private var takeProfitText: String {
        protectionText(position.takeProfitPrices)
    }

    private var stopLossText: String {
        protectionText(position.stopLossPrices)
    }

    private func protectionText(_ prices: [Decimal]) -> String {
        guard !prices.isEmpty else { return "--" }
        return prices.map(PositionCenterFormat.price).joined(separator: ", ")
    }

    private func pnlMetric(
        title: String,
        value: String,
        colorValue: Decimal,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(BinanceTheme.secondaryText)
            Text(value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(PositionCenterFormat.pnlColor(colorValue))
        }
    }

    private var marginTitle: String {
        position.marginType.lowercased() == "isolated" ? "逐仓" : "全仓"
    }

    private func closeButton(
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(BinanceTheme.Typography.text(.subheadline, weight: .semibold))
                .foregroundStyle(BinanceTheme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    Color.white.opacity(0.22),
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func positionTag(_ title: String) -> some View {
        Text(title)
            .font(BinanceTheme.Typography.text(.caption, weight: .medium))
            .foregroundStyle(BinanceTheme.primaryText)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(
                BinanceTheme.elevated,
                in: RoundedRectangle(cornerRadius: 3)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(BinanceTheme.border, lineWidth: 0.8)
            }
    }

    private func positionMetricRow(
        _ leading: (String, String),
        _ center: (String, String),
        _ trailing: (String, String)
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            positionMetric(
                leading,
                horizontalAlignment: .leading,
                frameAlignment: .leading,
                textAlignment: .leading
            )
            positionMetric(
                center,
                horizontalAlignment: .center,
                frameAlignment: .center,
                textAlignment: .center
            )
            positionMetric(
                trailing,
                horizontalAlignment: .trailing,
                frameAlignment: .trailing,
                textAlignment: .trailing
            )
        }
    }

    private func positionMetric(
        _ metric: (String, String),
        horizontalAlignment: HorizontalAlignment,
        frameAlignment: Alignment,
        textAlignment: TextAlignment
    ) -> some View {
        VStack(alignment: horizontalAlignment, spacing: 3) {
            Text(metric.0)
                .font(.system(size: 13))
                .foregroundStyle(BinanceTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(metric.1)
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(BinanceTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .multilineTextAlignment(textAlignment)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

private struct PositionRealizedPnlDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let position: TradingPositionSnapshot
    let quoteAsset: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(position.symbol.uppercased())
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(BinanceTheme.primaryText)
                        Text("当前仓位周期")
                            .font(.system(size: 12))
                            .foregroundStyle(BinanceTheme.secondaryText)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("已实现盈亏 (\(quoteAsset))")
                            .font(.system(size: 12))
                            .foregroundStyle(BinanceTheme.secondaryText)
                        Text(
                            PositionCenterFormat.signed(
                                position.realizedPnl,
                                maximumFractionDigits: 8
                            )
                        )
                        .font(.system(size: 18, weight: .semibold).monospacedDigit())
                        .foregroundStyle(
                            PositionCenterFormat.pnlColor(position.realizedPnl)
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Rectangle()
                    .fill(BinanceTheme.border)
                    .frame(height: 0.5)

                if position.realizedPnlDetails.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 28, weight: .medium))
                        Text("暂无成交明细")
                            .font(BinanceTheme.Typography.text(.subheadline, weight: .medium))
                    }
                    .foregroundStyle(BinanceTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(position.realizedPnlDetails) { fill in
                                realizedFillRow(fill)

                                Rectangle()
                                    .fill(BinanceTheme.border.opacity(0.7))
                                    .frame(height: 0.5)
                            }
                        }
                    }
                }
            }
            .background(BinanceTheme.navigationBackground)
            .navigationTitle("已实现盈亏详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(BinanceTheme.Typography.text(.subheadline, weight: .semibold))
                    }
                    .foregroundStyle(BinanceTheme.primaryText)
                    .accessibilityLabel("关闭")
                }
            }
        }
    }

    private func realizedFillRow(
        _ fill: TradingPositionRealizedFillSnapshot
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(fill.side.uppercased() == "BUY" ? "买入" : "卖出")
                        .foregroundStyle(
                            fill.side.uppercased() == "BUY"
                                ? BinanceTheme.positive
                                : BinanceTheme.negative
                        )
                    Text(fill.maker ? "Maker" : "Taker")
                        .foregroundStyle(BinanceTheme.secondaryText)
                }
                .font(.system(size: 13, weight: .medium))

                Text(PositionCenterFormat.dateTime(milliseconds: fill.tradeTimeMillis))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(BinanceTheme.secondaryText)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(
                    "\(PositionCenterFormat.price(fill.price)) × \(PositionCenterFormat.number(fill.quantity))"
                )
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(BinanceTheme.primaryText)

                HStack(spacing: 10) {
                    Text(
                        "手续费 -\(PositionCenterFormat.number(fill.commission)) \(fill.commissionAsset)"
                    )
                    .foregroundStyle(BinanceTheme.secondaryText)
                    Text(
                        PositionCenterFormat.signed(
                            fill.realizedPnl,
                            maximumFractionDigits: 8
                        )
                    )
                    .foregroundStyle(
                        PositionCenterFormat.pnlColor(fill.realizedPnl)
                    )
                }
                .font(.system(size: 11).monospacedDigit())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct LimitOrderCard: View {
    let order: TradingLimitOrderSnapshot
    let quoteAsset: String
    let isCancelling: Bool
    let onCancel: () -> Void

    private var sideColor: Color {
        order.side.uppercased() == "BUY"
            ? BinanceTheme.positive
            : BinanceTheme.negative
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Text(PositionCenterFormat.symbol(order.symbol, quoteAsset: quoteAsset))
                    .font(BinanceTheme.Typography.text(.headline, weight: .semibold))
                    .foregroundStyle(BinanceTheme.primaryText)

                Text(sideTitle)
                    .font(BinanceTheme.Typography.text(.caption2, weight: .bold))
                    .foregroundStyle(sideColor)

                Text("限价")
                    .font(BinanceTheme.Typography.text(.caption2, weight: .medium))
                    .foregroundStyle(BinanceTheme.secondaryText)

                if order.reduceOnly {
                    Text("只减仓")
                        .font(BinanceTheme.Typography.text(.caption2, weight: .medium))
                        .foregroundStyle(BinanceTheme.accentText)
                }

                Spacer()

                Text(PositionCenterFormat.orderStatus(order.status))
                    .font(BinanceTheme.Typography.text(.caption, weight: .medium))
                    .foregroundStyle(BinanceTheme.secondaryText)
            }

            metricGrid([
                ("委托价格 (\(quoteAsset))", PositionCenterFormat.price(order.price)),
                ("委托数量", PositionCenterFormat.number(order.quantity)),
                ("已成交", PositionCenterFormat.number(order.executedQuantity)),
                ("未成交", PositionCenterFormat.number(max(0, order.quantity - order.executedQuantity))),
            ])

            HStack(spacing: 12) {
                Text(
                    PositionCenterFormat.dateTime(
                        milliseconds: order.exchangeUpdateMillis
                    )
                )
                .font(BinanceTheme.Typography.number(.caption2))
                .foregroundStyle(BinanceTheme.secondaryText)

                Spacer()

                if order.entryCancelable {
                    Button(action: onCancel) {
                        Text(isCancelling ? "撤单中" : "撤单")
                            .font(
                                BinanceTheme.Typography.text(
                                    .caption,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(BinanceTheme.primaryText)
                            .padding(.horizontal, 16)
                            .frame(height: 30)
                            .background(
                                BinanceTheme.surface,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(BinanceTheme.border, lineWidth: 0.8)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(isCancelling)
                    .opacity(isCancelling ? 0.55 : 1)
                }
            }
        }
        .padding(14)
        .binancePanel(cornerRadius: 10)
    }

    private var sideTitle: String {
        let buy = order.side.uppercased() == "BUY"
        if order.reduceOnly {
            return buy ? "买入/平空" : "卖出/平多"
        }
        return buy ? "买入/做多" : "卖出/做空"
    }
}

private struct PositionHistoryCard: View {
    let position: TradingPositionHistorySnapshot
    let quoteAsset: String

    private var directionColor: Color {
        position.direction == "LONG"
            ? BinanceTheme.positive
            : BinanceTheme.negative
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Text(PositionCenterFormat.symbol(position.symbol, quoteAsset: quoteAsset))
                    .font(BinanceTheme.Typography.text(.headline, weight: .semibold))
                    .foregroundStyle(BinanceTheme.primaryText)

                Text(position.direction == "LONG" ? "多" : "空")
                    .font(BinanceTheme.Typography.text(.caption2, weight: .bold))
                    .foregroundStyle(directionColor)

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text("已实现盈亏 (\(quoteAsset))")
                        .font(BinanceTheme.Typography.text(.caption2))
                        .foregroundStyle(BinanceTheme.secondaryText)
                    Text(PositionCenterFormat.signed(position.realizedPnl, maximumFractionDigits: 4))
                        .font(BinanceTheme.Typography.number(.headline, weight: .semibold))
                        .foregroundStyle(PositionCenterFormat.pnlColor(position.realizedPnl))
                }
            }

            metricGrid([
                ("开仓均价", PositionCenterFormat.price(position.entryPrice)),
                ("平仓均价", PositionCenterFormat.price(position.closePrice)),
                ("最大持仓量", PositionCenterFormat.number(position.maximumQuantity)),
                ("成交笔数", "\(position.fillCount)"),
            ])

            HStack(alignment: .top) {
                Text("手续费")
                    .font(BinanceTheme.Typography.text(.caption))
                    .foregroundStyle(BinanceTheme.secondaryText)
                Spacer(minLength: 12)
                Text(feeText)
                    .font(BinanceTheme.Typography.number(.caption, weight: .medium))
                    .foregroundStyle(BinanceTheme.primaryText)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text(PositionCenterFormat.dateTime(milliseconds: position.openedAtMillis))
                Image(systemName: "arrow.right")
                    .font(.caption2)
                Text(PositionCenterFormat.dateTime(milliseconds: position.closedAtMillis))
            }
            .font(BinanceTheme.Typography.number(.caption2))
            .foregroundStyle(BinanceTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .binancePanel(cornerRadius: 10)
    }

    private var feeText: String {
        guard !position.fees.isEmpty else { return "--" }
        return position.fees.map {
            "-\(PositionCenterFormat.number($0.amount, maximumFractionDigits: 8)) \($0.asset)"
        }.joined(separator: "\n")
    }
}

private func metricGrid(
    _ metrics: [(String, String)]
) -> some View {
    LazyVGrid(
        columns: [
            GridItem(.flexible(), alignment: .leading),
            GridItem(.flexible(), alignment: .trailing),
        ],
        alignment: .leading,
        spacing: 13
    ) {
        ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
            VStack(
                alignment: index.isMultiple(of: 2) ? .leading : .trailing,
                spacing: 4
            ) {
                Text(metric.0)
                    .font(BinanceTheme.Typography.text(.caption2))
                    .foregroundStyle(BinanceTheme.secondaryText)
                    .frame(
                        maxWidth: .infinity,
                        alignment: index.isMultiple(of: 2) ? .leading : .trailing
                    )
                Text(metric.1)
                    .font(BinanceTheme.Typography.number(.subheadline, weight: .medium))
                    .foregroundStyle(BinanceTheme.primaryText)
                    .frame(
                        maxWidth: .infinity,
                        alignment: index.isMultiple(of: 2) ? .leading : .trailing
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
    }
}

private enum PositionCenterFormat {
    static func magnitude(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }

    static func number(
        _ value: Decimal,
        maximumFractionDigits: Int = 8
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "--"
    }

    static func signed(
        _ value: Decimal,
        maximumFractionDigits: Int
    ) -> String {
        let prefix = value > 0 ? "+" : ""
        return prefix + number(value, maximumFractionDigits: maximumFractionDigits)
    }

    static func price(_ value: Decimal) -> String {
        number(value, maximumFractionDigits: 8)
    }

    static func priceOrDash(_ value: Decimal) -> String {
        value > 0 ? price(value) : "--"
    }

    static func symbol(_ symbol: String, quoteAsset: String) -> String {
        guard symbol.hasSuffix(quoteAsset), symbol.count > quoteAsset.count else {
            return symbol
        }
        return "\(symbol.dropLast(quoteAsset.count))/\(quoteAsset)"
    }

    static func pnlColor(_ value: Decimal) -> Color {
        if value > 0 { return BinanceTheme.positive }
        if value < 0 { return BinanceTheme.negative }
        return BinanceTheme.primaryText
    }

    static func orderStatus(_ status: String) -> String {
        switch status.uppercased() {
        case "PARTIALLY_FILLED": "部分成交"
        case "CANCEL_PENDING": "撤单中"
        case "UNKNOWN", "UNRESOLVED": "确认中"
        default: "等待成交"
        }
    }

    static func dateTime(milliseconds: Int64) -> String {
        guard milliseconds > 0 else { return "--" }
        return dateTimeFormatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
        )
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

}
