import SwiftUI

struct OrderSettingsView: View {
    @EnvironmentObject private var toastCenter: AppToastCenter
    @ObservedObject var viewModel: SettingsAccountViewModel

    @State private var draft: TradingOrderSettings
    @State private var fallbackMarketStopText: String
    @State private var isSaving = false

    init(viewModel: SettingsAccountViewModel) {
        self.viewModel = viewModel
        let settings = viewModel.orderSettings ?? .defaultValue
        _draft = State(initialValue: settings)
        _fallbackMarketStopText = State(
            initialValue: settings.fallbackMarketStopR.map(compactNumber) ?? ""
        )
    }

    var body: some View {
        SettingsDetailPage(title: "下单设置") {
            VStack(alignment: .leading, spacing: 16) {
                defaultStrategySection
                orderTypeSection(
                    title: "建仓方式",
                    detail: "设置开仓委托的默认类型",
                    selection: $draft.entryOrderType
                )
                orderTypeSection(
                    title: "止盈方式",
                    detail: "设置止盈减仓委托的默认类型",
                    selection: $draft.takeProfitOrderType
                )
                stopLossSection
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            saveBar
        }
        .onReceive(viewModel.$orderSettings.compactMap { $0 }) { settings in
            guard !isSaving else { return }
            draft = settings
            fallbackMarketStopText = settings.fallbackMarketStopR
                .map(compactNumber) ?? ""
        }
    }

    private var saveBar: some View {
        Button(action: save) {
            HStack(spacing: 8) {
                if isSaving {
                    ProgressView()
                        .tint(BinanceTheme.onAccent)
                }
                Text(isSaving ? "保存中" : "保存设置")
            }
        }
        .buttonStyle(BinancePrimaryButtonStyle())
        .disabled(isSaving)
        .opacity(isSaving ? 0.7 : 1)
        .padding(.horizontal, BinanceTheme.Layout.pageHorizontalPadding)
        .padding(.vertical, 12)
        .background(BinanceTheme.marketBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BinanceTheme.border)
                .frame(height: 0.5)
        }
    }

    private var defaultStrategySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                title: "默认止盈止损",
                detail: "从已有止盈止损策略中选择，也可不设置"
            )
            .padding(.bottom, 12)

            Menu {
                Button {
                    clearDefaultStrategy()
                } label: {
                    Label("不设置", systemImage: "nosign")
                }

                if !viewModel.exitStrategies.isEmpty {
                    Divider()
                    ForEach(viewModel.exitStrategies) { strategy in
                        Button {
                            draft.defaultExitStrategyId = strategy.id
                            draft.defaultExitStrategyName = strategy.name
                        } label: {
                            if draft.defaultExitStrategyId == strategy.id {
                                Label(strategy.name, systemImage: "checkmark")
                            } else {
                                Text(strategy.name)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("默认策略")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(BinanceTheme.secondaryText)

                        Text(selectedStrategyName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(BinanceTheme.primaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BinanceTheme.secondaryText)
                }
                .padding(.horizontal, 13)
                .frame(height: 58)
                .background(
                    BinanceTheme.elevated,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(BinanceTheme.border, lineWidth: 0.8)
                }
            }

            if draft.defaultExitStrategyId != nil {
                Button(action: clearDefaultStrategy) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle")
                        Text("清除默认策略")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BinanceTheme.negative)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
        }
        .padding(15)
        .settingsPanel()
    }

    private func orderTypeSection(
        title: String,
        detail: String,
        selection: Binding<TradingOrderType>
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: title, detail: detail)
                .padding(.bottom, 5)

            ForEach(TradingOrderType.allCases) { type in
                choiceRow(
                    title: type.title,
                    isSelected: selection.wrappedValue == type
                ) {
                    selection.wrappedValue = type
                }
            }
        }
        .padding(15)
        .settingsPanel()
    }

    private var stopLossSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                title: "止损方式",
                detail: "选择限价止损时，必须同时配置保底市价止损"
            )
            .padding(.bottom, 5)

            ForEach(TradingStopLossOrderType.allCases) { type in
                choiceRow(
                    title: type.title,
                    isSelected: draft.stopLossOrderType == type
                ) {
                    draft.stopLossOrderType = type
                    if type != .limit {
                        draft.fallbackMarketStopR = nil
                        fallbackMarketStopText = ""
                    }
                }
            }

            if draft.stopLossOrderType == .limit {
                Rectangle()
                    .fill(BinanceTheme.border)
                    .frame(height: 0.5)
                    .padding(.vertical, 12)

                VStack(alignment: .leading, spacing: 8) {
                    Text("保底市价止损")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(BinanceTheme.primaryText)

                    HStack(spacing: 10) {
                        TextField("必须大于 1", text: $fallbackMarketStopText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(BinanceTheme.primaryText)
                            .multilineTextAlignment(.trailing)

                        Text("R")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(BinanceTheme.secondaryText)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 50)
                    .background(
                        BinanceTheme.elevated,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(BinanceTheme.border, lineWidth: 0.8)
                    }

                    Text("当限价止损未成交并到达该 R 位置时，后续执行器将改用市价止损。")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(BinanceTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(15)
        .settingsPanel()
    }

    private func sectionHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(BinanceTheme.primaryText)
            Text(detail)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(BinanceTheme.secondaryText)
        }
    }

    private func choiceRow(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(
                            isSelected
                                ? BinanceTheme.accent
                                : BinanceTheme.secondaryText,
                            lineWidth: 2
                        )
                    if isSelected {
                        Circle()
                            .fill(BinanceTheme.accent)
                            .padding(4)
                    }
                }
                .frame(width: 21, height: 21)

                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BinanceTheme.primaryText)

                Spacer()
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectedStrategyName: String {
        guard let strategyID = draft.defaultExitStrategyId else {
            return viewModel.exitStrategies.isEmpty ? "暂无可选策略" : "不设置"
        }
        return viewModel.exitStrategies.first { $0.id == strategyID }?.name
            ?? draft.defaultExitStrategyName
            ?? "不设置"
    }

    private func clearDefaultStrategy() {
        draft.defaultExitStrategyId = nil
        draft.defaultExitStrategyName = nil
    }

    private func save() {
        guard !isSaving else { return }

        if draft.stopLossOrderType == .limit {
            draft.fallbackMarketStopR = parsedFallbackMarketStop
        } else {
            draft.fallbackMarketStopR = nil
        }

        do {
            _ = try draft.validated()
        } catch {
            toastCenter.error(error.localizedDescription)
            return
        }

        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                draft = try await viewModel.saveOrderSettings(draft)
                fallbackMarketStopText = draft.fallbackMarketStopR
                    .map(compactNumber) ?? ""
                toastCenter.success("下单设置已保存")
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }

    private var parsedFallbackMarketStop: Double? {
        Double(
            fallbackMarketStopText
                .replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
