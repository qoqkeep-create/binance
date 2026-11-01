import SwiftUI

/// Shared by market search, watchlist editing and trade symbol selection.
struct MarketSearchView: View {
    @ObservedObject var dashboardViewModel: DashboardViewModel
    var selectedSymbol: String? = nil
    var onSelect: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var pendingDeletion: String?

    private var symbols: [String] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "").uppercased()
        return dashboardViewModel.catalogSymbols.filter {
            normalized.isEmpty || $0.contains(normalized)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("交易对").font(.system(size: 20, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("关闭")
                    .accessibilityIdentifier("pairs.close")
            }.padding(.horizontal, 20).padding(.top, 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(BinanceTheme.secondaryText)
                TextField("搜索交易对", text: $query)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .keyboardType(.asciiCapable).accessibilityIdentifier("pairs.search")
            }.padding(12).background(BinanceTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20).padding(.bottom, 12)
            if dashboardViewModel.catalogSymbols.isEmpty {
                Spacer()
                if dashboardViewModel.isLoadingCatalog {
                    ProgressView().tint(BinanceTheme.accent)
                } else {
                    Text("交易对加载失败").foregroundStyle(BinanceTheme.secondaryText)
                    Button("重新加载") {
                        Task { await dashboardViewModel.loadSymbolCatalog(force: true) }
                    }.padding(.top, 12)
                }
                Spacer()
            } else {
                List {
                    ForEach(symbols, id: \.self) { symbol in
                        pairRow(symbol)
                            .listRowBackground(BinanceTheme.background)
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .overlay {
                        if symbols.isEmpty {
                            Text("未找到相关交易对").foregroundStyle(BinanceTheme.secondaryText)
                        }
                    }
            }
        }.foregroundStyle(BinanceTheme.primaryText)
            .background(BinanceTheme.background)
            .largeTradingSheet()
            .task { await dashboardViewModel.loadSymbolCatalog() }
            .alert("删除自选", isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
            ), presenting: pendingDeletion) { symbol in
                Button("删除自选", role: .destructive) {
                    dashboardViewModel.hideMarkets([symbol])
                    pendingDeletion = nil
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: { symbol in
                Text("确定从自选中删除 \(symbol)？")
            }
    }

    private func pairRow(_ symbol: String) -> some View {
        let isFavorite = dashboardViewModel.containsInWatchlist(symbol)
        return HStack(spacing: 12) {
            Button {
                if let onSelect {
                    onSelect(symbol)
                    dismiss()
                } else {
                    toggleFavorite(symbol)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(symbol).font(.system(size: 16, weight: isFavorite ? .bold : .regular))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text("永续").font(.system(size: 11)).foregroundStyle(BinanceTheme.secondaryText)
                    if symbol == selectedSymbol {
                        Image(systemName: "checkmark").foregroundStyle(BinanceTheme.accentText)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 56).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("pairs.select.\(symbol)")
            Button { toggleFavorite(symbol) } label: {
                Image(systemName: isFavorite ? "trash" : "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isFavorite ? BinanceTheme.secondaryText : BinanceTheme.accentText)
                    .frame(width: 44, height: 48).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(isFavorite ? "删除自选 \(symbol)" : "添加自选 \(symbol)")
                .accessibilityIdentifier("pairs.favorite.\(symbol)")
                .accessibilityValue(isFavorite ? "已自选" : "未自选")
        }
    }

    private func toggleFavorite(_ symbol: String) {
        if dashboardViewModel.containsInWatchlist(symbol) {
            pendingDeletion = symbol
        } else {
            dashboardViewModel.addToWatchlist(symbol)
        }
    }
}

/// A system sheet, shared with the legal documents for the same presentation height.
extension View {
    func largeTradingSheet() -> some View {
        presentationDetents([.fraction(0.85)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(24)
            .presentationBackground(BinanceTheme.background)
    }
}
