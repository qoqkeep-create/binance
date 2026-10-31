import SwiftUI

struct ReferenceNotificationsView: View {
    @ObservedObject var viewModel: ReferenceNotificationsViewModel
    @ObservedObject var marketViewModel: DashboardViewModel
    let isVisible: Bool
    let onSelectMarket: (MarketSnapshot) -> Void

    var body: some View {
        VStack(spacing: 0) {
            BinanceNavigationHeader(
                title: "参考",
                showsBackButton: false
            )

            Divider()
                .overlay(BinanceTheme.border)

            List {
                if viewModel.notifications.isEmpty, viewModel.isLoading {
                    loadingState
                        .referenceListRow()
                } else if viewModel.notifications.isEmpty,
                          viewModel.loadFailed {
                    failureState
                        .referenceListRow()
                } else if viewModel.notifications.isEmpty {
                    emptyState
                        .referenceListRow()
                } else {
                    ForEach(viewModel.notifications) { notification in
                        let market = marketViewModel.usdcMarket(
                            for: notification
                        )

                        Group {
                            if let market {
                                Button {
                                    onSelectMarket(market)
                                } label: {
                                    ReferenceNotificationRow(
                                        notification: notification,
                                        linkedSymbol: market.symbol
                                    )
                                    .padding(16)
                                    .binancePanel()
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("打开对应USDC交易对K线详情")
                            } else {
                                ReferenceNotificationRow(
                                    notification: notification,
                                    linkedSymbol: nil
                                )
                                .padding(16)
                                .binancePanel()
                            }
                        }
                        .referenceListRow()
                    }

                    paginationFooter
                        .referenceListRow()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 12, for: .scrollContent)
            .refreshable {
                await viewModel.refresh()
            }
        }
        .background(BinanceTheme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: isVisible) {
            guard isVisible else { return }
            await viewModel.loadIfNeeded()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bookmark.slash")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(BinanceTheme.secondaryText)

            Text("暂无参考通知")
                .font(.headline)
                .foregroundStyle(BinanceTheme.primaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .binancePanel()
    }

    private var loadingState: some View {
        ProgressView("正在加载…")
            .tint(BinanceTheme.accent)
            .foregroundStyle(BinanceTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 56)
            .binancePanel()
    }

    private var failureState: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(BinanceTheme.secondaryText)

            Text("参考通知加载失败")
                .font(.headline)
                .foregroundStyle(BinanceTheme.primaryText)

            Button("重试") {
                Task {
                    await viewModel.refresh()
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(BinanceTheme.accentText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
        .binancePanel()
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if viewModel.hasMore {
            if viewModel.loadFailed {
                Button("加载失败，点击重试") {
                    Task {
                        await viewModel.loadMore()
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(BinanceTheme.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else {
                ProgressView()
                    .tint(BinanceTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .id(viewModel.notifications.last?.id)
                    .onAppear {
                        Task {
                            await viewModel.loadMore()
                        }
                    }
            }
        }
    }
}

private struct ReferenceNotificationRow: View {
    let notification: ReferenceTradeNotification
    let linkedSymbol: String?

    var body: some View {
        let summary = notification.summary

        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(typeColor.opacity(0.12))

                Image(systemName: iconName(for: summary.direction))
                    .font(BinanceTheme.Typography.text(.subheadline, weight: .bold))
                    .foregroundStyle(typeColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(
                        linkedSymbol
                            ?? summary.sourceSymbol
                            ?? notification.type.title
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BinanceTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)

                    if let direction = summary.direction {
                        badge(direction.title, color: directionColor(direction))
                    }

                    Spacer(minLength: 8)

                    Text(shortDate(notification.occurredAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(BinanceTheme.secondaryText)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Text(notification.type.title)
                    .font(.subheadline)
                    .foregroundStyle(BinanceTheme.secondaryText)

                ForEach(
                    Array(summary.details.enumerated()),
                    id: \.offset
                ) { _, detail in
                    HStack {
                        Text(detail.label)
                            .font(.caption)
                            .foregroundStyle(BinanceTheme.secondaryText)

                        Spacer()

                        Text(detail.value)
                            .font(.subheadline.monospacedDigit().weight(.medium))
                            .foregroundStyle(BinanceTheme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
        .padding(.vertical, 9)
    }

    private var typeColor: Color {
        switch notification.type {
        case .open:
            return BinanceTheme.accent
        case .stopLoss:
            return BinanceTheme.negative
        case .strategyTakeProfit, .manualTakeProfit:
            return BinanceTheme.positive
        case .reduction:
            return BinanceTheme.secondaryText
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(
                color.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 4)
            )
    }

    private func directionColor(
        _ direction: ReferenceTradeNotification.Direction
    ) -> Color {
        switch direction {
        case .long:
            return BinanceTheme.positive
        case .short:
            return BinanceTheme.negative
        }
    }

    private func iconName(
        for direction: ReferenceTradeNotification.Direction?
    ) -> String {
        switch direction {
        case .long:
            return "arrow.up.right"
        case .short:
            return "arrow.down.right"
        case nil:
            return "bookmark.fill"
        }
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .month(.twoDigits)
                .day(.twoDigits)
                .hour()
                .minute()
        )
    }
}

private extension View {
    func referenceListRow() -> some View {
        self
            .listRowInsets(
                EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
