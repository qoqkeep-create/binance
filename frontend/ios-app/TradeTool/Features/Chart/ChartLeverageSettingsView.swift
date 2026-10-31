import SwiftUI

struct ChartLeverageSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toastCenter: AppToastCenter
    @ObservedObject var viewModel: SettingsAccountViewModel
    let symbol: String

    @State private var draftLeverage = 1
    @State private var isSaving = false

    private var settings: TradingLeverageSettings? {
        viewModel.leverageSettings
    }

    private var maximumLeverage: Int {
        max(1, settings?.maxLeverage ?? 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 22) {
                leverageStepper
                leverageSlider
                positionLimit
                riskNotice

                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView()
                            .tint(BinanceTheme.onAccent)
                    } else {
                        Text("确认")
                    }
                }
                .buttonStyle(BinancePrimaryButtonStyle())
                .disabled(isSaving || settings == nil)
                .opacity(settings == nil ? 0.55 : 1)
                .accessibilityIdentifier("chart-leverage-confirm")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 18)
        }
        .background(BinanceTheme.marketBackground.ignoresSafeArea())
        .presentationDetents([.height(485)])
        .presentationDragIndicator(.visible)
        .presentationBackground(BinanceTheme.marketBackground)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            synchronizeDraft()
        }
        .onChange(of: viewModel.leverageSettings) { _, _ in
            synchronizeDraft()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("调整杠杆")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(BinanceTheme.primaryText)

                Text(symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BinanceTheme.secondaryText)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BinanceTheme.primaryText)
                    .frame(width: 34, height: 34)
                    .background(
                        BinanceTheme.elevated,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .accessibilityLabel("关闭杠杆设置")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BinanceTheme.border)
                .frame(height: 0.5)
        }
    }

    private var leverageStepper: some View {
        HStack(spacing: 20) {
            leverageButton(systemName: "minus") {
                draftLeverage = max(1, draftLeverage - 1)
            }
            .disabled(draftLeverage <= 1)

            Text("\(draftLeverage)x")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(BinanceTheme.primaryText)
                .monospacedDigit()
                .frame(minWidth: 112)

            leverageButton(systemName: "plus") {
                draftLeverage = min(
                    maximumLeverage,
                    draftLeverage + 1
                )
            }
            .disabled(draftLeverage >= maximumLeverage)
        }
    }

    private func leverageButton(
        systemName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(BinanceTheme.primaryText)
                .frame(width: 48, height: 42)
                .background(
                    BinanceTheme.elevated,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(BinanceTheme.border, lineWidth: 0.8)
                }
        }
        .buttonStyle(.plain)
    }

    private var leverageSlider: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { Double(draftLeverage) },
                    set: { draftLeverage = Int($0.rounded()) }
                ),
                in: 1...Double(maximumLeverage),
                step: 1
            )
            .tint(BinanceTheme.accent)
            .disabled(settings == nil)
            .accessibilityIdentifier("chart-leverage-slider")

            HStack {
                ForEach(sliderMarks, id: \.self) { value in
                    Text("\(value)x")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(BinanceTheme.secondaryText)
                    if value != sliderMarks.last {
                        Spacer()
                    }
                }
            }
        }
    }

    private var positionLimit: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("当前倍数最大持仓")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(BinanceTheme.secondaryText)

                Text("\(formatNotional(maximumPosition)) U")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BinanceTheme.primaryText)
                    .monospacedDigit()
            }

            Spacer()

            Text("调整后将应用于该交易对")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(BinanceTheme.secondaryText)
        }
        .padding(.horizontal, 14)
        .frame(height: 64)
        .background(
            BinanceTheme.elevated,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private var riskNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(
                    draftLeverage >= 10
                        ? BinanceTheme.negative
                        : BinanceTheme.accentText
                )

            Text(
                draftLeverage >= 10
                    ? "高杠杆会显著提高强平风险。调整会同时影响该交易对已有持仓和未成交订单。"
                    : "调整杠杆会同时影响该交易对已有持仓和未成交订单。"
            )
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(BinanceTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private var maximumPosition: Double {
        settings?.maximumNotional(for: draftLeverage) ?? 0
    }

    private var sliderMarks: [Int] {
        guard maximumLeverage > 1 else { return [1] }
        let values = [
            1,
            max(1, maximumLeverage / 4),
            max(1, maximumLeverage / 2),
            max(1, maximumLeverage * 3 / 4),
            maximumLeverage,
        ]
        return values.reduce(into: [Int]()) { result, value in
            if result.last != value {
                result.append(value)
            }
        }
    }

    private func synchronizeDraft() {
        guard let settings else { return }
        draftLeverage = min(
            settings.maxLeverage,
            max(1, settings.leverage)
        )
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let saved = try await viewModel.saveLeverage(
                    symbol: symbol,
                    leverage: draftLeverage
                )
                draftLeverage = saved.leverage
                toastCenter.success("杠杆已调整为 \(saved.leverage)x")
                dismiss()
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }

    private func formatNotional(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "--" }
        return value.formatted(
            .number
                .grouping(.automatic)
                .precision(.fractionLength(0...2))
        )
    }
}
