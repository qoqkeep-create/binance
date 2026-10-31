import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var runtime: AppRuntime
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @EnvironmentObject private var strategySignalNotifications:
        StrategySignalNotificationManager

    @StateObject private var accountViewModel: SettingsAccountViewModel
    @State private var riskSettings = TradingRiskSettings.defaultValue
    @State private var showsLossLimit = false
    @State private var showsServerSettings = false
    @ScaledMetric(relativeTo: .caption2)
    private var unboundAccountFontSize: CGFloat = 10

    init(apiClient: any APIClient) {
        _accountViewModel = StateObject(
            wrappedValue: SettingsAccountViewModel(apiClient: apiClient)
        )
    }

    @AppStorage("notificationsEnabled")
    private var notificationsEnabled = true
    @AppStorage(AppAppearance.storageKey)
    private var appearance: AppAppearance = .defaultValue

    private var userID: String {
        authStore.session?.user.id ?? ""
    }

    var body: some View {
        ZStack {
            BinanceTheme.marketBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                BinanceNavigationHeader(
                    title: "设置",
                    showsBackButton: false
                )

                Divider()
                    .overlay(BinanceTheme.border)

                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: 16
                    ) {
                        accountCard
                        tradingActionsPanel
                        preferencesPanel
                        serverPanel
                        logoutButton
                    }
                    .padding(
                        .horizontal,
                        BinanceTheme.Layout.pageHorizontalPadding
                    )
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .refreshable {
                    await refreshSettings()
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: userID) {
            guard !userID.isEmpty else { return }
            do {
                try await accountViewModel.load()
                riskSettings = accountViewModel.riskSettings
                LegacyTradingSettingsScrubber.delete(
                    bundleIdentifier: Bundle.main.bundleIdentifier
                        ?? "com.oovso.tradetool",
                    userID: userID
                )
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
        .onReceive(accountViewModel.$riskSettings) { value in
            riskSettings = value
        }
        .onChange(of: notificationsEnabled) { _, enabled in
            strategySignalNotifications.setEnabled(enabled)
        }
        .sheet(isPresented: $showsServerSettings) {
            ServerSettingsView()
                .environmentObject(runtime)
        }
        .sheet(isPresented: $showsLossLimit) {
            StopLossLimitSheet(viewModel: accountViewModel)
                .environmentObject(toastCenter)
                .presentationDetents([.fraction(0.82)])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(18)
        }
    }

    private var appearancePanel: some View {
        HStack(spacing: 13) {
            SettingsRowIcon(systemName: "moon")

            VStack(alignment: .leading, spacing: 3) {
                Text("暗色模式")
                    .font(BinanceTheme.Typography.settingsRowTitle)
                    .foregroundStyle(BinanceTheme.primaryText)
                Text("关闭使用亮色，开启使用暗色")
                    .font(BinanceTheme.Typography.text(.caption2))
                    .foregroundStyle(BinanceTheme.secondaryText)
            }

            Spacer()

            Toggle("暗色模式", isOn: Binding(
                get: { appearance == .dark },
                set: { appearance = $0 ? .dark : .light }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(BinanceTheme.accent)
            .accessibilityIdentifier("appearance-toggle")
            .accessibilityValue(appearance.title)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 60)
    }

    private var accountCard: some View {
        VStack(spacing: 0) {
            NavigationLink {
                BinanceAPIBindingView(
                    viewModel: accountViewModel
                )
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(
                            cornerRadius: 14,
                            style: .continuous
                        )
                        .fill(BinanceTheme.accent)

                        Text("实")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(BinanceTheme.onAccent)
                    }
                    .frame(width: 58, height: 58)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text("实盘")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(
                                    BinanceTheme.primaryText
                                )

                            Text(
                                accountViewModel.isBound
                                    ? "已连接"
                                    : "未绑定"
                            )
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(
                                accountViewModel.isBound
                                    ? BinanceTheme.positive
                                    : BinanceTheme.secondaryText
                            )
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                (
                                    accountViewModel.isBound
                                        ? BinanceTheme.positive
                                        : BinanceTheme.secondaryText
                                ).opacity(0.1),
                                in: Capsule()
                            )
                        }

                        Text(accountIdentifier)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(BinanceTheme.secondaryText)

                        Text("Binance USD-M 永续")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(BinanceTheme.secondaryText)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BinanceTheme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(userID.isEmpty)

            Rectangle()
                .fill(BinanceTheme.border)
                .frame(height: 0.5)
                .padding(.vertical, 15)

            HStack(spacing: 8) {
                Text("账户总资产（\(accountAsset)）")
                    .font(BinanceTheme.Typography.text(.caption, weight: .semibold))
                    .foregroundStyle(BinanceTheme.secondaryText)

                Button {
                    refreshAccount()
                } label: {
                    HStack(spacing: 4) {
                        if accountViewModel.isRefreshing {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(BinanceTheme.secondaryText)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                        }

                        Text("刷新")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(BinanceTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .disabled(accountViewModel.isRefreshing)

                Spacer()
            }

            HStack(alignment: .bottom, spacing: 12) {
                Text(accountBalanceText)
                    .font(accountViewModel.isBound
                        ? BinanceTheme.Typography.balance
                        : .system(size: unboundAccountFontSize, weight: .medium))
                    .foregroundStyle(BinanceTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                Spacer(minLength: 8)

                unrealizedProfitBadge
            }
            .padding(.top, 6)
        }
        .padding(16)
        .background(
            BinanceTheme.accent.opacity(0.16),
            in: RoundedRectangle(cornerRadius: BinanceTheme.Layout.cardCornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BinanceTheme.Layout.cardCornerRadius)
                .stroke(BinanceTheme.accent.opacity(0.24), lineWidth: 0.8)
        }
    }

    private var tradingActionsPanel: some View {
        VStack(spacing: 0) {
            NavigationLink {
                BinanceAPIBindingView(
                    viewModel: accountViewModel
                )
            } label: {
                SettingsNavigationRow(
                    icon: "link",
                    title: "绑定 API",
                    value: accountViewModel.isBound ? "实盘" : "未绑定"
                )
            }
            .buttonStyle(.plain)

            SettingsRowDivider()

            stopLossAmountPanel

            SettingsRowDivider()

            NavigationLink {
                ExitStrategyManagementView(viewModel: accountViewModel)
            } label: {
                SettingsNavigationRow(
                    icon: "scope",
                    title: "止盈止损策略",
                    value: strategySummary
                )
            }
            .buttonStyle(.plain)
            .disabled(!accountViewModel.isBound)

            SettingsRowDivider()

            NavigationLink {
                OrderSettingsView(viewModel: accountViewModel)
            } label: {
                SettingsNavigationRow(
                    icon: "arrow.up.arrow.down.square",
                    title: "下单设置",
                    value: orderSettingsSummary
                )
            }
            .buttonStyle(.plain)
            .disabled(!accountViewModel.isBound)
        }
        .settingsPanel()
    }

    private var stopLossAmountPanel: some View {
        Button {
            guard accountViewModel.isBound else {
                toastCenter.warning("请先绑定 Binance API")
                return
            }
            showsLossLimit = true
        } label: {
            SettingsNavigationRow(
                icon: "chart.line.uptrend.xyaxis",
                title: "止损额设置",
                value: lossLimitSummary,
                highlightsValue: true
            )
        }
        .buttonStyle(.plain)
    }

    private var preferencesPanel: some View {
        VStack(spacing: 0) {
            appearancePanel

            SettingsRowDivider()

            notificationPanel
        }
        .settingsPanel()
    }

    private var notificationPanel: some View {
        HStack(spacing: 13) {
            SettingsRowIcon(systemName: "bell")

            VStack(alignment: .leading, spacing: 3) {
                Text("策略通知")
                    .font(BinanceTheme.Typography.settingsRowTitle)
                    .foregroundStyle(BinanceTheme.primaryText)

                Text("以系统通知接收策略信号")
                    .font(BinanceTheme.Typography.text(.caption2))
                    .foregroundStyle(BinanceTheme.secondaryText)
            }

            Spacer()

            Toggle("", isOn: $notificationsEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(BinanceTheme.accent)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 60)
    }

    private var serverPanel: some View {
        Button {
            showsServerSettings = true
        } label: {
            SettingsNavigationRow(
                icon: "server.rack",
                title: "切换服务器",
                value: runtime.currentServer.name
            )
        }
        .buttonStyle(.plain)
        .settingsPanel()
        .accessibilityIdentifier("settings.server")
    }

    private var logoutButton: some View {
        Button {
            authStore.logout()
        } label: {
            Text("退出登录")
                .font(BinanceTheme.Typography.settingsRowTitle)
                .foregroundStyle(BinanceTheme.negative)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    BinanceTheme.negative.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            BinanceTheme.negative.opacity(0.22),
                            lineWidth: 0.8
                        )
                }
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var unrealizedProfitBadge: some View {
        if let snapshot = accountViewModel.snapshot {
            let pnl = decimalDouble(snapshot.unrealizedProfit)
            let color = pnl > 0
                ? BinanceTheme.positive
                : pnl < 0
                    ? BinanceTheme.negative
                    : BinanceTheme.secondaryText

            HStack(spacing: 5) {
                Text("未实现")
                    .foregroundStyle(BinanceTheme.secondaryText)

                Text(signedAmount(pnl))
                    .foregroundStyle(color)
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var accountIdentifier: String {
        guard let user = authStore.session?.user else {
            return "ID: --"
        }
        return "ID: \(user.displayName.isEmpty ? user.id : user.displayName)"
    }

    private var accountAsset: String {
        accountViewModel.snapshot?.asset
            ?? accountViewModel.lossLimit?.settlementAsset
            ?? riskSettings.settlementAsset
    }

    private var strategySummary: String {
        let count = accountViewModel.exitStrategies.count
        return count == 0 ? "未设置" : "\(count) 个策略"
    }

    private var lossLimitSummary: String {
        guard let limit = accountViewModel.lossLimit else {
            return "未设置"
        }
        return "\(compactNumber(limit.currentAmount)) "
            + limit.settlementAsset
    }

    private var orderSettingsSummary: String {
        guard let settings = accountViewModel.orderSettings else {
            return "未设置"
        }
        return "\(settings.entryOrderType.title) · "
            + settings.stopLossOrderType.title
    }

    private var accountBalanceText: String {
        guard accountViewModel.isBound else {
            return "API 未绑定"
        }
        guard let balance = accountViewModel.snapshot?.totalMarginBalance else {
            return "--"
        }
        return decimalDouble(balance).formatted(
            .number
                .grouping(.automatic)
                .precision(.fractionLength(2))
        )
    }

    private func refreshAccount() {
        guard accountViewModel.isBound else {
            toastCenter.warning("请先绑定 Binance API")
            return
        }

        Task {
            await refreshSettings()
        }
    }

    private func refreshSettings() async {
        guard accountViewModel.isBound else { return }

        do {
            try await accountViewModel.refresh()
        } catch {
            toastCenter.error(error.localizedDescription)
        }
    }

    private func saveRiskSettings(
        _ settings: TradingRiskSettings
    ) async throws {
        riskSettings = try await accountViewModel.saveRiskSettings(settings)
    }
}

struct SettingsNavigationRow: View {
    let icon: String
    let title: String
    let value: String
    var highlightsValue = false

    var body: some View {
        HStack(spacing: 13) {
            SettingsRowIcon(systemName: icon)

            Text(title)
                .font(BinanceTheme.Typography.settingsRowTitle)
                .foregroundStyle(BinanceTheme.primaryText)

            Spacer(minLength: 8)

            Text(value)
                .font(BinanceTheme.Typography.text(.caption, weight: .semibold))
                .foregroundStyle(
                    highlightsValue
                        ? BinanceTheme.accentText
                        : BinanceTheme.secondaryText
                )
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(BinanceTheme.Typography.text(.caption, weight: .semibold))
                .foregroundStyle(BinanceTheme.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: BinanceTheme.Layout.settingsRowHeight)
        .contentShape(Rectangle())
    }
}

struct SettingsRowIcon: View {
    let systemName: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(BinanceTheme.accent.opacity(0.11))

            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(BinanceTheme.accentText)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(BinanceTheme.border)
            .frame(height: 0.5)
            .padding(.leading, 63)
            .padding(.trailing, 16)
    }
}

struct BinanceAPIBindingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toastCenter: AppToastCenter
    @ObservedObject var viewModel: SettingsAccountViewModel

    @State private var apiKey = ""
    @State private var secretKey = ""
    @State private var confirmsUnbind = false

    var body: some View {
        SettingsDetailPage(title: "绑定 API") {
            VStack(alignment: .leading, spacing: 16) {
                if viewModel.isBound {
                    bindingStatusPanel
                }

                credentialPanel
                securityNotice

                Button {
                    bind()
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isRefreshing {
                            ProgressView()
                                .tint(BinanceTheme.onAccent)
                        }
                        Text(viewModel.isBound ? "重新验证并绑定" : "验证并绑定")
                    }
                }
                .buttonStyle(BinancePrimaryButtonStyle())
                .disabled(!canSubmit || viewModel.isRefreshing)
                .opacity(canSubmit ? 1 : 0.45)

                if viewModel.isBound {
                    Button(role: .destructive) {
                        confirmsUnbind = true
                    } label: {
                        Text("解除绑定")
                            .font(BinanceTheme.Typography.rowTitle)
                            .foregroundStyle(BinanceTheme.negative)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .confirmationDialog(
            "解除 Binance API 绑定？",
            isPresented: $confirmsUnbind,
            titleVisibility: .visible
        ) {
            Button("解除绑定", role: .destructive) {
                unbind()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("服务器将清除加密凭证并停止该账户的仓位同步")
        }
    }

    private var bindingStatusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前连接")
                    .font(BinanceTheme.Typography.text(.caption, weight: .semibold))
                    .foregroundStyle(BinanceTheme.secondaryText)

                Spacer()

                Text("已验证")
                    .font(BinanceTheme.Typography.text(.caption, weight: .semibold))
                    .foregroundStyle(BinanceTheme.positive)
            }

            Text(viewModel.maskedAPIKey ?? "••••••••")
                .font(.system(size: 15, weight: .medium).monospaced())
                .foregroundStyle(BinanceTheme.primaryText)
        }
        .padding(16)
        .settingsPanel()
    }

    private var credentialPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Binance USD-M HMAC API")
                .font(BinanceTheme.Typography.rowTitle)
                .foregroundStyle(BinanceTheme.primaryText)

            SettingsLabeledField(title: "API Key") {
                TextField("输入 API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            SettingsLabeledField(title: "Secret Key") {
                SecureField("输入 Secret Key", text: $secretKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .padding(16)
        .settingsPanel()
    }

    private var securityNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("安全说明")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BinanceTheme.accentText)

            Text(
                "凭证提交到 Java 服务器后使用 AES-256-GCM 加密保存，"
                    + "iPhone 不保存 API Secret，也不会直连 Binance。"
                    + "请先创建只读 API Key，并将服务器固定出口 IP 加入白名单；"
                    + "当前阶段不会提交任何订单。"
            )
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(BinanceTheme.secondaryText)
            .lineSpacing(3)
        }
        .padding(14)
        .background(
            BinanceTheme.accent.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var canSubmit: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKey.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
    }

    private func bind() {
        Task {
            do {
                try await viewModel.bind(
                    apiKey: apiKey,
                    secretKey: secretKey
                )
                secretKey = ""
                toastCenter.success("API 绑定成功")
                dismiss()
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }

    private func unbind() {
        Task {
            do {
                try await viewModel.unbind()
                apiKey = ""
                secretKey = ""
                toastCenter.success("已解除 API 绑定")
                dismiss()
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }
}

private struct TakeProfitStopLossSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toastCenter: AppToastCenter

    let onSave: (TradingRiskSettings) async throws -> Void

    @State private var draft: TradingRiskSettings
    @State private var takeProfitText: String
    @State private var stopLossText: String

    init(
        settings: TradingRiskSettings,
        onSave: @escaping (TradingRiskSettings) async throws -> Void
    ) {
        self.onSave = onSave
        _draft = State(initialValue: settings)
        _takeProfitText = State(
            initialValue: compactNumber(settings.takeProfitPercent)
        )
        _stopLossText = State(
            initialValue: compactNumber(settings.stopLossPercent)
        )
    }

    var body: some View {
        SettingsDetailPage(title: "止盈止损策略") {
            VStack(alignment: .leading, spacing: 16) {
                masterSwitch
                protectionPanel
                inactiveNotice

                Button("保存设置") {
                    save()
                }
                .buttonStyle(BinancePrimaryButtonStyle())
            }
        }
    }

    private var masterSwitch: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("启用风控参数")
                    .font(BinanceTheme.Typography.rowTitle)
                    .foregroundStyle(BinanceTheme.primaryText)

                Text("统一保存止盈和止损阈值")
                    .font(.system(size: 11))
                    .foregroundStyle(BinanceTheme.secondaryText)
            }

            Spacer()

            Toggle("", isOn: $draft.isEnabled)
                .labelsHidden()
                .tint(BinanceTheme.accent)
        }
        .padding(16)
        .settingsPanel()
    }

    private var protectionPanel: some View {
        VStack(spacing: 0) {
            SettingsRiskInputRow(
                title: "止盈保护",
                isEnabled: $draft.takeProfitEnabled,
                value: $takeProfitText,
                suffix: "%"
            )

            SettingsRowDivider()

            SettingsRiskInputRow(
                title: "止损保护",
                isEnabled: $draft.stopLossEnabled,
                value: $stopLossText,
                suffix: "%"
            )
        }
        .settingsPanel()
    }

    private var inactiveNotice: some View {
        Text(
            "本页先保存风控参数，不会自动为真实仓位提交订单。"
                + "自动挂单需要在后续交易执行模块完成后单独启用。"
        )
        .font(.system(size: 12))
        .foregroundStyle(BinanceTheme.secondaryText)
        .lineSpacing(3)
        .padding(14)
        .background(
            BinanceTheme.accent.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func save() {
        guard let takeProfit = parseNumber(takeProfitText),
              let stopLoss = parseNumber(stopLossText) else {
            toastCenter.warning("请输入有效的止盈止损比例")
            return
        }

        var candidate = draft
        candidate.takeProfitPercent = takeProfit
        candidate.stopLossPercent = stopLoss

        Task {
            do {
                let validated = try candidate.validated()
                try await onSave(validated)
                toastCenter.success("止盈止损设置已保存")
                dismiss()
            } catch {
                toastCenter.warning(error.localizedDescription)
            }
        }
    }
}

private struct StopLossAmountSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toastCenter: AppToastCenter

    let onSave: (TradingRiskSettings) async throws -> Void

    @State private var draft: TradingRiskSettings
    @State private var amountText: String

    init(
        settings: TradingRiskSettings,
        onSave: @escaping (TradingRiskSettings) async throws -> Void
    ) {
        self.onSave = onSave
        _draft = State(initialValue: settings)
        _amountText = State(
            initialValue: compactNumber(settings.stopLossAmount)
        )
    }

    var body: some View {
        SettingsDetailPage(title: "止损额设置") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("单笔最大止损额")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BinanceTheme.secondaryText)

                    HStack(spacing: 10) {
                        TextField("5", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(
                                .system(size: 24, weight: .semibold)
                                    .monospacedDigit()
                            )
                            .foregroundStyle(BinanceTheme.primaryText)

                        Text(draft.settlementAsset)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(BinanceTheme.accentText)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 58)
                    .background(
                        BinanceTheme.elevated,
                        in: RoundedRectangle(cornerRadius: 10)
                    )

                    HStack(spacing: 8) {
                        ForEach([5.0, 10, 20, 50], id: \.self) { amount in
                            Button {
                                amountText = compactNumber(amount)
                            } label: {
                                Text(compactNumber(amount))
                                    .font(BinanceTheme.Typography.text(.caption, weight: .semibold))
                                    .foregroundStyle(
                                        amountText == compactNumber(amount)
                                            ? BinanceTheme.onAccent
                                            : BinanceTheme.secondaryText
                                    )
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: BinanceTheme.Layout.minimumTapSize)
                                    .background(
                                        amountText == compactNumber(amount)
                                            ? BinanceTheme.accent
                                            : BinanceTheme.elevated,
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
                .settingsPanel()

                Text(
                    "该金额是单次交易允许承受的最大计划亏损，"
                        + "目前仅作为风险参数保存，不会自动减仓或平仓。"
                )
                .font(.system(size: 12))
                .foregroundStyle(BinanceTheme.secondaryText)
                .lineSpacing(3)
                .padding(14)
                .background(
                    BinanceTheme.accent.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 12)
                )

                Button("保存设置") {
                    save()
                }
                .buttonStyle(BinancePrimaryButtonStyle())
            }
        }
    }

    private func save() {
        guard let amount = parseNumber(amountText) else {
            toastCenter.warning("请输入有效的止损金额")
            return
        }

        var candidate = draft
        candidate.stopLossAmount = amount

        Task {
            do {
                let validated = try candidate.validated()
                try await onSave(validated)
                toastCenter.success("止损额设置已保存")
                dismiss()
            } catch {
                toastCenter.warning(error.localizedDescription)
            }
        }
    }
}

private struct SettingsRiskInputRow: View {
    let title: String
    @Binding var isEnabled: Bool
    @Binding var value: String
    let suffix: String

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .tint(BinanceTheme.accent)

            Text(title)
                .font(BinanceTheme.Typography.rowTitle)
                .foregroundStyle(BinanceTheme.primaryText)

            Spacer()

            HStack(spacing: 5) {
                TextField("0", text: $value)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(BinanceTheme.primaryText)
                    .frame(width: 58)

                Text(suffix)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BinanceTheme.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: BinanceTheme.Layout.minimumTapSize)
            .background(
                BinanceTheme.elevated,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .disabled(!isEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: BinanceTheme.Layout.settingsRowHeight)
    }
}

private struct SettingsLabeledField<Field: View>: View {
    let title: String
    @ViewBuilder let field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(BinanceTheme.Typography.text(.caption, weight: .semibold))
                .foregroundStyle(BinanceTheme.secondaryText)

            field()
                .font(.system(size: 14).monospaced())
                .foregroundStyle(BinanceTheme.primaryText)
                .padding(.horizontal, 12)
                .frame(height: 48)
                .background(
                    BinanceTheme.elevated,
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(BinanceTheme.border, lineWidth: 0.8)
                }
        }
    }
}

struct SettingsDetailPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            BinanceNavigationHeader(title: title)

            Rectangle()
                .fill(BinanceTheme.border)
                .frame(height: 0.5)

            ScrollView {
                content()
                    .padding(
                        .horizontal,
                        BinanceTheme.Layout.pageHorizontalPadding
                    )
                    .padding(.top, 12)
                    .padding(.bottom, 28)
            }
        }
        .background(BinanceTheme.marketBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .interactivePopGestureEnabled()
    }
}

struct SettingsPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                BinanceTheme.surface,
                in: RoundedRectangle(cornerRadius: BinanceTheme.Layout.cardCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BinanceTheme.Layout.cardCornerRadius, style: .continuous)
                    .stroke(
                        BinanceTheme.border.opacity(0.82),
                        lineWidth: 0.8
                    )
            }
    }
}

extension View {
    func settingsPanel() -> some View {
        modifier(SettingsPanelModifier())
    }
}

func decimalDouble(_ value: Decimal) -> Double {
    NSDecimalNumber(decimal: value).doubleValue
}

private func signedAmount(_ value: Double) -> String {
    let sign = value > 0 ? "+" : ""
    return sign + value.formatted(
        .number.precision(.fractionLength(2))
    )
}

func compactNumber(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int(value))
    }
    return value.formatted(
        .number.precision(.fractionLength(0...4))
    )
}

private func parseNumber(_ value: String) -> Double? {
    Double(
        value
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    )
}
