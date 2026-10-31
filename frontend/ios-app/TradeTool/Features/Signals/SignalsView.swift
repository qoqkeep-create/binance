import SwiftUI

struct SignalsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let apiClient: any APIClient
    let isVisible: Bool
    let onSelectSignal: (StrategySignal) -> Void

    @State private var isShowingNotificationSettings = false

    init(
        viewModel: DashboardViewModel,
        apiClient: any APIClient,
        isVisible: Bool,
        onSelectSignal: @escaping (StrategySignal) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.apiClient = apiClient
        self.isVisible = isVisible
        self.onSelectSignal = onSelectSignal
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationHeader

            Divider()
                .overlay(BinanceTheme.border)

            List {
                if viewModel.signals.isEmpty,
                   viewModel.isLoadingSignals {
                    loadingState
                        .signalListRow()
                } else if viewModel.signals.isEmpty,
                          viewModel.signalLoadFailed {
                    failureState
                        .signalListRow()
                } else if viewModel.signals.isEmpty {
                    emptyState
                        .signalListRow()
                } else {
                    ForEach(viewModel.signals) { signal in
                        Button {
                            onSelectSignal(signal)
                            Task {
                                await viewModel.markSignalRead(signal.id)
                            }
                        } label: {
                            SignalRow(signal: signal)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .binancePanel()
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("打开对应交易对K线详情")
                        .signalListRow()
                        .swipeActions(
                            edge: .trailing,
                            allowsFullSwipe: false
                        ) {
                            Button(role: .destructive) {
                                Task {
                                    await viewModel.deleteSignal(signal.id)
                                }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .tint(BinanceTheme.negative)

                            if signal.reversalAlertState != .active {
                                Button {
                                    Task {
                                        await viewModel.activateReversalAlert(
                                            signal.id
                                        )
                                    }
                                } label: {
                                    Label(
                                        signal.reversalAlertState == .triggered
                                            ? "再次提醒"
                                            : "二次提醒",
                                        systemImage: "bell.badge"
                                    )
                                }
                                .tint(BinanceTheme.accent)
                            }
                        }
                    }

                    paginationFooter
                        .signalListRow()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 12, for: .scrollContent)
            .refreshable {
                await viewModel.refreshSignals()
            }
        }
        .background(BinanceTheme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(
            isPresented: $isShowingNotificationSettings
        ) {
            SignalNotificationSettingsView(apiClient: apiClient) { settings in
                await viewModel.updateSignalNotificationPreferences(settings)
            }
        }
        .task(id: isVisible) {
            guard isVisible else { return }
            await viewModel.loadSignalsIfNeeded()
        }
    }

    private var navigationHeader: some View {
        ZStack {
            BinanceNavigationHeader(
                title: "信号",
                showsBackButton: false
            )

            HStack {
                Spacer()

                Button {
                    isShowingNotificationSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(BinanceTheme.primaryText)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("提醒设置")
            }
            .padding(.horizontal, 10)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bell.slash")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(BinanceTheme.secondaryText)

            Text("暂无策略信号")
                .font(.headline)
                .foregroundStyle(BinanceTheme.primaryText)

            Text("新信号出现后会显示在这里")
                .font(.subheadline)
                .foregroundStyle(BinanceTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .binancePanel()
    }

    private var loadingState: some View {
        ProgressView("正在加载历史信号…")
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

            Text("历史信号加载失败")
                .font(.headline)
                .foregroundStyle(BinanceTheme.primaryText)

            Button("重试") {
                Task {
                    await viewModel.refreshSignals()
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
        if viewModel.hasMoreSignals {
            if viewModel.signalLoadFailed {
                Button("加载失败，点击重试") {
                    Task {
                        await viewModel.loadMoreSignals()
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
                    .id(viewModel.signals.last?.id)
                    .onAppear {
                        Task {
                            await viewModel.loadMoreSignals()
                        }
                    }
            }
        }
    }
}

@MainActor
private final class SignalNotificationSettingsViewModel: ObservableObject {
    @Published private(set) var settings =
        SignalNotificationPreferences.allEnabled
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var loadFailed = false

    private let apiClient: any APIClient

    init(apiClient: any APIClient) {
        self.apiClient = apiClient
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }

        do {
            settings = try await apiClient.send(
                APIRequest<SignalNotificationPreferences>(
                    path: "/api/strategy/notification-preferences"
                )
            )
            hasLoaded = true
        } catch {
            loadFailed = true
        }
    }

    func save(_ updated: SignalNotificationPreferences) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }

        do {
            settings = try await apiClient.send(
                APIRequest<SignalNotificationPreferences>.json(
                    path: "/api/strategy/notification-preferences",
                    method: .put,
                    body: updated
                )
            )
            return true
        } catch {
            return false
        }
    }
}

private struct SignalNotificationSettingsView: View {
    @EnvironmentObject private var toastCenter: AppToastCenter
    @StateObject private var viewModel: SignalNotificationSettingsViewModel
    @State private var draft = SignalNotificationPreferences.allEnabled
    let onSave: (SignalNotificationPreferences) async -> Void

    init(
        apiClient: any APIClient,
        onSave: @escaping (SignalNotificationPreferences) async -> Void
    ) {
        self.onSave = onSave
        _viewModel = StateObject(
            wrappedValue: SignalNotificationSettingsViewModel(
                apiClient: apiClient
            )
        )
    }

    var body: some View {
        ZStack {
            BinanceTheme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                BinanceNavigationHeader(title: "提醒设置")

                Divider()
                    .overlay(BinanceTheme.border)

                content
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.hasLoaded {
                saveBar
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .interactivePopGestureEnabled()
        .task {
            await load()
        }
        .onChange(of: viewModel.settings) { _, settings in
            draft = settings
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.hasLoaded {
            ProgressView()
                .tint(BinanceTheme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.loadFailed && !viewModel.hasLoaded {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(BinanceTheme.secondaryText)

                Text("提醒设置加载失败")
                    .font(.headline)
                    .foregroundStyle(BinanceTheme.primaryText)

                Button("重试") {
                    Task { await load() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BinanceTheme.accentText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("提醒周期")
                        .font(BinanceTheme.Typography.sectionHeader)
                        .foregroundStyle(BinanceTheme.secondaryText)
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        intervalToggle(
                            "15分钟",
                            isOn: $draft.fifteenMinuteEnabled
                        )

                        Divider()
                            .overlay(BinanceTheme.border)
                            .padding(.leading, 16)

                        intervalToggle(
                            "1小时",
                            isOn: $draft.oneHourEnabled
                        )

                        Divider()
                            .overlay(BinanceTheme.border)
                            .padding(.leading, 16)

                        intervalToggle(
                            "4小时",
                            isOn: $draft.fourHourEnabled
                        )
                    }
                    .binancePanel(cornerRadius: 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
        }
    }

    private var saveBar: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(BinanceTheme.border)

            Button {
                Task {
                    if await viewModel.save(draft) {
                        await onSave(viewModel.settings)
                        toastCenter.success("提醒设置已保存")
                    }
                }
            } label: {
                Group {
                    if viewModel.isSaving {
                        ProgressView()
                            .tint(BinanceTheme.onAccent)
                    } else {
                        Text("保存设置")
                            .font(BinanceTheme.Typography.text(.subheadline, weight: .semibold))
                    }
                }
                .foregroundStyle(BinanceTheme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    BinanceTheme.accent,
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSaving || draft == viewModel.settings)
            .opacity(
                viewModel.isSaving || draft == viewModel.settings
                    ? 0.55
                    : 1
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(BinanceTheme.marketBackground)
    }

    private func intervalToggle(
        _ title: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(BinanceTheme.Typography.text(.subheadline, weight: .semibold))
                .foregroundStyle(BinanceTheme.primaryText)
        }
        .tint(BinanceTheme.accent)
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
    }

    private func load() async {
        await viewModel.load()
        if viewModel.hasLoaded {
            draft = viewModel.settings
        }
    }
}

struct SignalRow: View {
    let signal: StrategySignal

    private var directionColor: Color {
        signal.direction == .long
            ? BinanceTheme.positive
            : BinanceTheme.negative
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(signal.triggeredAt.formatted(
                .dateTime.month(.twoDigits).day(.twoDigits).hour().minute()
            ))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(BinanceTheme.secondaryText)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .trailing)

            HStack(alignment: .center, spacing: 10) {
                directionIcon
                signalDetails
                priceColumn
            }
        }
    }

    private var directionIcon: some View {
        ZStack {
            Circle()
                .fill(directionColor.opacity(0.12))
            Image(systemName: signal.direction == .long
                ? "arrow.up.right" : "arrow.down.right")
                .font(BinanceTheme.Typography.text(.caption, weight: .bold))
                .foregroundStyle(directionColor)
        }
        .frame(width: 28, height: 28)
    }

    private var signalDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(signal.symbol)
                    .font(BinanceTheme.Typography.listSymbol)
                    .foregroundStyle(BinanceTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(signal.direction.title)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .foregroundStyle(directionColor)
                    .background(directionColor.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 3))
                    .fixedSize()

                if !signal.isRead {
                    Circle()
                        .fill(BinanceTheme.accent)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("未读")
                }
            }

            Text("\(signal.strategyName) · \(intervalTitle)")
                .font(.caption)
                .foregroundStyle(BinanceTheme.secondaryText)
                .lineLimit(1)

            if signal.reversalAlertState == .active {
                Label(
                    signal.interval == MarketKlineInterval.fourHours.rawValue
                        ? "已设二次提醒 · 1小时反转K/MACD峰值"
                        : "已设二次提醒 · 反转K/MACD峰值",
                    systemImage: "bell.badge.fill"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(BinanceTheme.accentText)
            } else if signal.reversalAlertState == .triggered {
                Label(
                    signal.reversalPatternName.map {
                        "二次提醒已触发 · \($0) · 可再次设置"
                    } ?? "二次提醒已触发 · 可再次设置",
                    systemImage: "checkmark.circle"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(BinanceTheme.positive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var priceColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(signal.triggerPrice.formatted(
                .number.precision(.fractionLength(2...4))
            ))
            .font(.subheadline.monospacedDigit().weight(.medium))
            .foregroundStyle(BinanceTheme.primaryText)

            Text("价格")
                .font(.caption2)
                .foregroundStyle(BinanceTheme.secondaryText)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var intervalTitle: String {
        MarketKlineInterval(rawValue: signal.interval)?.title
            ?? signal.interval
    }
}

private extension View {
    func signalListRow() -> some View {
        self
            .listRowInsets(
                EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
