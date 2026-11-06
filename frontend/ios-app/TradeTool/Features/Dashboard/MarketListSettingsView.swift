import SwiftUI

struct MarketListSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let onSelectMarket: (String) -> Void
    @State private var pendingDeletion: String?
    @State private var showingPairs = false
    @State private var pendingChartSymbol: String?

    private var markets: [MarketSnapshot] { viewModel.markets(onlyVisible: true) }

    var body: some View {
        VStack(spacing: 0) {
            BinanceNavigationHeader(title: "编辑自选")
            Divider().overlay(BinanceTheme.border)
            HStack(spacing: 0) {
                Text("交易对").frame(maxWidth: .infinity, alignment: .leading)
                Text("删除").frame(width: 44)
                Text("移到顶部").frame(width: 68)
                Text("拖动").fixedSize().frame(width: 24)
            }.font(BinanceTheme.Typography.sectionHeader)
                .foregroundStyle(BinanceTheme.secondaryText)
                .padding(.horizontal, 16).padding(.top, WebTheme.pageContentSpacing).padding(.bottom, 10)
            List {
                ForEach(markets) { market in
                    HStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(market.symbol).font(BinanceTheme.Typography.listSymbol)
                                .fontWeight(.bold).lineLimit(1).minimumScaleFactor(0.65)
                            Text("永续").font(BinanceTheme.Typography.marketDetail)
                                .foregroundStyle(BinanceTheme.secondaryText)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button { pendingDeletion = market.symbol } label: {
                            Image(systemName: "trash").frame(width: 44, height: 56)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("删除 \(market.symbol)")
                            .accessibilityIdentifier("watchlist.delete.\(market.symbol)")
                        Button { viewModel.moveMarketToTop(market.symbol) } label: {
                            Image(systemName: "arrow.up.to.line").frame(width: 68, height: 56)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("移到顶部 \(market.symbol)")
                            .accessibilityIdentifier("watchlist.top.\(market.symbol)")
                    }.foregroundStyle(BinanceTheme.primaryText)
                        .listRowBackground(BinanceTheme.background)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
                }.onMove(perform: viewModel.moveVisibleMarkets)
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
                .accessibilityIdentifier("watchlist.list")
                .overlay {
                    if markets.isEmpty {
                        Text("暂无自选交易对").foregroundStyle(BinanceTheme.secondaryText)
                    }
                }
        }.background(BinanceTheme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button("添加自选") { showingPairs = true }
                    .buttonStyle(WebButtonStyle(height: 48))
                    .accessibilityIdentifier("watchlist.add")
                    .padding(16).background(BinanceTheme.background)
            }
            .toolbar(.hidden, for: .navigationBar)
            .interactivePopGestureEnabled()
            .largeTradingSheet(isPresented: $showingPairs, onDismiss: {
                guard let symbol = pendingChartSymbol else { return }
                pendingChartSymbol = nil
                onSelectMarket(symbol)
            }) {
                MarketSearchView(dashboardViewModel: viewModel) { symbol in
                    pendingChartSymbol = symbol
                }
            }
            .alert("删除自选", isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
            ), presenting: pendingDeletion) { symbol in
                Button("删除自选", role: .destructive) {
                    viewModel.hideMarkets([symbol])
                    pendingDeletion = nil
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: { symbol in
                Text("确定从自选中删除 \(symbol)？")
            }
    }
}
