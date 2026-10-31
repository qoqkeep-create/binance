import Combine
import SwiftUI

struct MarketSearchView: View {
    @ObservedObject private var dashboardViewModel: DashboardViewModel
    @StateObject private var viewModel: MarketSearchViewModel
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    init(
        apiClient: any APIClient,
        dashboardViewModel: DashboardViewModel
    ) {
        self.dashboardViewModel = dashboardViewModel
        _viewModel = StateObject(
            wrappedValue: MarketSearchViewModel(
                service: APIMarketTickerSearchService(
                    apiClient: apiClient
                )
            )
        )
    }

    var body: some View {
        ZStack {
            BinanceTheme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                searchHeader
                    .padding(
                        .horizontal,
                        BinanceTheme.Layout.pageHorizontalPadding
                    )
                    .padding(.top, 3)
                    .padding(.bottom, 12)

                resultsContent
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .interactivePopGestureEnabled()
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            isSearchFocused = true
        }
        .task(id: query) {
            let requestedQuery = query
            if !normalizedQuery(requestedQuery).isEmpty {
                try? await Task.sleep(for: .milliseconds(280))
            }
            guard !Task.isCancelled else { return }
            await viewModel.loadFirstPage(query: requestedQuery)
        }
        .onChange(
            of: viewModel.items.map(\.symbol),
            initial: true
        ) { _, symbols in
            dashboardViewModel.trackSearchTickerSymbols(symbols)
        }
        .onDisappear {
            dashboardViewModel.stopTrackingSearchTickers()
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 4) {
            BinanceBackButton()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(BinanceTheme.Typography.text(.footnote, weight: .medium))
                    .foregroundStyle(BinanceTheme.secondaryText)

                TextField(
                    "",
                    text: $query,
                    prompt: Text("搜索币种/币对/合约")
                        .foregroundStyle(BinanceTheme.secondaryText)
                )
                .font(BinanceTheme.Typography.text(.footnote))
                .foregroundStyle(BinanceTheme.primaryText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.search)
                .focused($isSearchFocused)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(BinanceTheme.Typography.text(.footnote, weight: .medium))
                            .foregroundStyle(BinanceTheme.secondaryText)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索")
                }
            }
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
        }
        .frame(height: BinanceTheme.Layout.compactSearchTapHeight)
    }

    @ViewBuilder
    private var resultsContent: some View {
        if viewModel.isLoadingInitial, viewModel.items.isEmpty {
            Spacer()
            ProgressView()
                .tint(BinanceTheme.accent)
            Spacer()
        } else if viewModel.loadFailed, viewModel.items.isEmpty {
            retryState
        } else if !isPopularMode, viewModel.items.isEmpty {
            emptySearchState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if isPopularMode {
                        popularResults
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var popularResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("热门交易")
                .font(
                    BinanceTheme.Typography.text(
                        .headline,
                        weight: .semibold
                    )
                )
                .foregroundStyle(BinanceTheme.primaryText)
                .padding(.bottom, 10)

            ForEach(Array(viewModel.items.enumerated()), id: \.element.id) {
                offset,
                market in
                MarketSearchTickerRow(
                    market: liveMarket(market),
                    rank: offset + 1
                )
            }

            if viewModel.hasNext {
                Button {
                    Task {
                        await viewModel.loadNextPage(query: "")
                    }
                } label: {
                    Group {
                        if viewModel.isLoadingMore {
                            ProgressView()
                                .tint(BinanceTheme.accent)
                        } else {
                            Text("查看更多")
                        }
                    }
                    .font(
                        BinanceTheme.Typography.text(
                            .caption,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(BinanceTheme.accentText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoadingMore)
            }
        }
    }

    private var searchResults: some View {
        ForEach(viewModel.items) { market in
            MarketSearchTickerRow(
                market: liveMarket(market),
                rank: nil
            )
            .onAppear {
                guard market.id == viewModel.items.last?.id,
                      viewModel.hasNext else {
                    return
                }
                Task {
                    await viewModel.loadNextPage(query: query)
                }
            }
        }
    }

    private var emptySearchState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(BinanceTheme.secondaryText)

            Text("未找到相关合约")
                .font(
                    BinanceTheme.Typography.text(
                        .headline,
                        weight: .semibold
                    )
                )
                .foregroundStyle(BinanceTheme.primaryText)

            Text("请尝试输入其他币种或交易对")
                .font(BinanceTheme.Typography.text(.subheadline))
                .foregroundStyle(BinanceTheme.secondaryText)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var retryState: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(BinanceTheme.secondaryText)

            Text("行情加载失败")
                .font(
                    BinanceTheme.Typography.text(
                        .headline,
                        weight: .semibold
                    )
                )
                .foregroundStyle(BinanceTheme.primaryText)

            Button("重新加载") {
                Task {
                    await viewModel.loadFirstPage(query: query)
                }
            }
            .font(
                BinanceTheme.Typography.text(
                    .subheadline,
                    weight: .semibold
                )
            )
            .foregroundStyle(BinanceTheme.accentText)
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var isPopularMode: Bool {
        normalizedQuery(query).isEmpty
    }

    private func normalizedQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func liveMarket(
        _ market: MarketSnapshot
    ) -> MarketSnapshot {
        _ = dashboardViewModel.realtimeTickerRevision
        return dashboardViewModel.realtimeSnapshot(for: market)
    }
}

private struct MarketSearchTickerRow: View {
    let market: MarketSnapshot
    let rank: Int?

    var body: some View {
        HStack(spacing: 12) {
            if let rank {
                Text(String(rank))
                    .font(
                        BinanceTheme.Typography.number(
                            .footnote,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(
                        rank <= 3
                            ? BinanceTheme.accent
                            : BinanceTheme.secondaryText
                    )
                    .frame(width: 24, alignment: .leading)
            }

            symbolText

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 4) {
                Text(market.formattedPrice)
                    .font(BinanceTheme.Typography.marketPrice)
                    .foregroundStyle(BinanceTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(market.formattedChange)
                    .font(BinanceTheme.Typography.marketSearchChange)
                    .foregroundStyle(
                        market.isPositive
                            ? BinanceTheme.positive
                            : BinanceTheme.negative
                    )
            }
            .frame(width: 112, alignment: .trailing)
        }
        .frame(minHeight: BinanceTheme.Layout.marketSearchRowHeight)
        .contentShape(Rectangle())
    }

    private var symbolText: some View {
        Text(market.symbol)
            .font(BinanceTheme.Typography.marketSymbol)
            .foregroundStyle(BinanceTheme.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
    }
}

@MainActor
private final class MarketSearchViewModel: ObservableObject {
    @Published private(set) var items: [MarketSnapshot] = []
    @Published private(set) var isLoadingInitial = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasNext = false
    @Published private(set) var loadFailed = false

    private let service: any MarketTickerSearching
    private var activeQuery = ""
    private var nextPage = 0
    private var requestRevision = 0

    init(service: any MarketTickerSearching) {
        self.service = service
    }

    func loadFirstPage(query: String) async {
        requestRevision += 1
        let revision = requestRevision
        let normalized = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        activeQuery = normalized
        nextPage = 0
        items = []
        hasNext = false
        loadFailed = false
        isLoadingInitial = true
        isLoadingMore = false
        defer {
            if requestRevision == revision {
                isLoadingInitial = false
            }
        }

        do {
            let response = try await service.loadPage(
                query: normalized,
                page: 0,
                size: normalized.isEmpty ? 10 : 20
            )
            guard requestRevision == revision,
                  !Task.isCancelled else {
                return
            }
            apply(response, appending: false)
        } catch {
            guard requestRevision == revision,
                  !Task.isCancelled else {
                return
            }
            loadFailed = true
        }
    }

    func loadNextPage(query: String) async {
        let normalized = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalized == activeQuery,
              hasNext,
              !isLoadingInitial,
              !isLoadingMore else {
            return
        }

        let revision = requestRevision
        let requestedPage = nextPage
        isLoadingMore = true
        defer {
            if requestRevision == revision {
                isLoadingMore = false
            }
        }

        do {
            let response = try await service.loadPage(
                query: normalized,
                page: requestedPage,
                size: normalized.isEmpty ? 10 : 20
            )
            guard requestRevision == revision,
                  normalized == activeQuery,
                  !Task.isCancelled else {
                return
            }
            apply(response, appending: true)
        } catch {
            guard requestRevision == revision,
                  !Task.isCancelled else {
                return
            }
            loadFailed = true
        }
    }

    private func apply(
        _ response: MarketTickerPageResponse,
        appending: Bool
    ) {
        let mapped = response.items.map {
            MarketSnapshot(
                symbol: $0.symbol,
                quoteAsset: response.quoteAsset,
                price: $0.lastPrice,
                quoteVolume24h: $0.quoteVolume24h,
                changePercent24h: $0.priceChangePercent24h,
                updatedAt: Date(
                    timeIntervalSince1970:
                        Double($0.eventTime) / 1_000
                )
            )
        }

        if appending {
            let existingSymbols = Set(items.map(\.symbol))
            items.append(
                contentsOf: mapped.filter {
                    !existingSymbols.contains($0.symbol)
                }
            )
        } else {
            items = mapped
        }

        nextPage = response.page + 1
        hasNext = response.hasNext
        loadFailed = false
    }
}

private protocol MarketTickerSearching {
    func loadPage(
        query: String,
        page: Int,
        size: Int
    ) async throws -> MarketTickerPageResponse
}

private struct APIMarketTickerSearchService: MarketTickerSearching {
    let apiClient: any APIClient

    func loadPage(
        query: String,
        page: Int,
        size: Int
    ) async throws -> MarketTickerPageResponse {
        let isPopular = query.isEmpty
        var queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "size", value: String(size)),
        ]
        if !isPopular {
            queryItems.insert(
                URLQueryItem(name: "query", value: query),
                at: 0
            )
        }

        return try await apiClient.send(
            APIRequest<MarketTickerPageResponse>(
                path: isPopular
                    ? "/api/market/tickers/popular"
                    : "/api/market/tickers/search",
                queryItems: queryItems
            )
        )
    }
}

private struct MarketTickerPageResponse: Decodable {
    let quoteAsset: String
    let query: String
    let page: Int
    let size: Int
    let totalElements: Int
    let totalPages: Int
    let hasNext: Bool
    let items: [MarketTickerPayload]
}
