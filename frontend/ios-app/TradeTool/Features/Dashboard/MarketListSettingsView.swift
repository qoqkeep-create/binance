import SwiftUI

struct MarketListSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel

    @State private var selectedSymbols: Set<String> = []

    private var markets: [MarketSnapshot] {
        viewModel.markets(onlyVisible: false)
    }

    private var isAllSelected: Bool {
        !markets.isEmpty && selectedSymbols.count == markets.count
    }

    var body: some View {
        ZStack {
            BinanceTheme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                navigationHeader

                Divider()
                    .overlay(BinanceTheme.border)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        tableHeader
                            .padding(.top, 24)
                            .padding(.bottom, 10)

                        ForEach(markets) { market in
                            MarketListSettingsRow(
                                market: market,
                                isSelected: selectedSymbols.contains(
                                    market.symbol
                                ),
                                toggleSelected: {
                                    toggleSelection(for: market.symbol)
                                },
                                toggleVisible: {
                                    viewModel.toggleMarketVisibility(
                                        market.symbol
                                    )
                                },
                                togglePinned: {
                                    viewModel.togglePinned(market.symbol)
                                },
                                moveToTop: {
                                    viewModel.moveMarketToTop(market.symbol)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 148)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .toolbar(.hidden, for: .navigationBar)
        .interactivePopGestureEnabled()
    }

    private var navigationHeader: some View {
        BinanceNavigationHeader(title: "编辑自选")
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("市场")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("固顶")
                .frame(width: 44)

            Text("移到顶部")
                .frame(width: 68)

            Text("拖动")
                .frame(width: 44)
        }
        .font(BinanceTheme.Typography.sectionHeader)
        .foregroundStyle(BinanceTheme.secondaryText)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            Divider()
                .overlay(BinanceTheme.border)

            Button {
                toggleAllSelection()
            } label: {
                HStack(spacing: 10) {
                    CheckboxView(isSelected: isAllSelected)
                    Text("全选")
                        .font(BinanceTheme.Typography.tab)
                    Spacer()
                }
                .foregroundStyle(BinanceTheme.primaryText)
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                disabledActionButton("添加到群组")

                Button {
                    viewModel.hideMarkets(selectedSymbols)
                    selectedSymbols.removeAll()
                } label: {
                    Text("移除")
                        .font(BinanceTheme.Typography.tab)
                        .foregroundStyle(
                            selectedSymbols.isEmpty
                                ? BinanceTheme.secondaryText
                                : BinanceTheme.onAccent
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            selectedSymbols.isEmpty
                                ? BinanceTheme.elevated
                                : BinanceTheme.accent,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
                .disabled(selectedSymbols.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(BinanceTheme.marketBackground)
    }

    private func disabledActionButton(_ title: String) -> some View {
        Text(title)
            .font(BinanceTheme.Typography.tab)
            .foregroundStyle(BinanceTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                BinanceTheme.elevated,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .opacity(0.65)
    }

    private func toggleSelection(for symbol: String) {
        if selectedSymbols.contains(symbol) {
            selectedSymbols.remove(symbol)
        } else {
            selectedSymbols.insert(symbol)
        }
    }

    private func toggleAllSelection() {
        if isAllSelected {
            selectedSymbols.removeAll()
        } else {
            selectedSymbols = Set(markets.map(\.symbol))
        }
    }
}

private struct MarketListSettingsRow: View {
    let market: MarketSnapshot
    let isSelected: Bool
    let toggleSelected: () -> Void
    let toggleVisible: () -> Void
    let togglePinned: () -> Void
    let moveToTop: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: toggleSelected) {
                    CheckboxView(isSelected: isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "取消选择" : "选择")

                Button(action: toggleVisible) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(market.symbol)
                            .font(BinanceTheme.Typography.listSymbol)
                            .foregroundStyle(BinanceTheme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)

                        Text("永续")
                            .font(BinanceTheme.Typography.marketDetail)
                            .foregroundStyle(BinanceTheme.secondaryText)
                    }
                    .opacity(market.isVisible ? 1 : 0.42)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: togglePinned) {
                Image(systemName: market.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(
                        market.isPinned
                            ? BinanceTheme.accent
                            : BinanceTheme.secondaryText
                    )
                    .frame(width: 44, height: 52)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(market.isPinned ? "取消固顶" : "固顶")

            Button(action: moveToTop) {
                Image(systemName: "arrow.up.to.line")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(BinanceTheme.secondaryText)
                    .frame(width: 68, height: 52)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移到顶部")

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(BinanceTheme.secondaryText)
                .frame(width: 44, height: 52)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 5)
    }
}

private struct CheckboxView: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isSelected ? BinanceTheme.accent : .clear)
            .frame(width: 20, height: 20)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(
                        isSelected
                            ? BinanceTheme.accent
                            : BinanceTheme.border,
                        lineWidth: 1.5
                    )
            }
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(BinanceTheme.onAccent)
                }
            }
    }
}
