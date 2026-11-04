import Foundation
import SwiftUI

private enum IndicatorSettingsPalette {
    static let background = BinanceTheme.background
    static let surface = BinanceTheme.elevated
    static let primaryText = BinanceTheme.primaryText
    static let secondaryText = BinanceTheme.secondaryText
    static let divider = BinanceTheme.border
    static let accent = BinanceTheme.accent
    static let error = BinanceTheme.negative
}

struct ChartIndicatorSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("integrated.chart.indicatorSettings.lastViewed")
    private var lastViewedIndicator = "MA"
    @State private var superTrendFillAlpha: Double
    @State private var movingAverageFast: String
    @State private var movingAverageMiddle: String
    @State private var movingAverageSlow: String
    @State private var emaFast: String
    @State private var emaMiddle: String
    @State private var emaSlow: String
    @State private var bollingerPeriod: String
    @State private var bollingerMultiplier: String
    @State private var parabolicSARStart: String
    @State private var parabolicSARMaximum: String
    @State private var superTrendATRPeriod: String
    @State private var superTrendMultiplier: String
    @State private var volumeFastPeriod: String
    @State private var volumeSlowPeriod: String
    @State private var macdFastPeriod: String
    @State private var macdSlowPeriod: String
    @State private var macdSignalPeriod: String
    @State private var rsiPeriod: String
    @State private var kdjPeriod: String
    @State private var kdjKSmoothing: String
    @State private var kdjDSmoothing: String
    @State private var williamsRPeriod: String
    @State private var stochasticRSIPeriod: String
    @State private var stochasticRSIWindow: String
    @State private var stochasticRSIKSmoothing: String
    @State private var stochasticRSIDSmoothing: String
    @State private var atrPeriod: String

    private let onApply: (ChartIndicatorParameters) -> Void

    private static let indicatorTitles = [
        "MA", "EMA", "BOLL", "SAR", "AVL", "Super", "VOL", "MACD",
        "RSI", "KDJ", "OBV", "WR", "StochRSI", "ATR", "合约数据"
    ]

    private var selectedIndicator: String {
        Self.indicatorTitles.contains(lastViewedIndicator) ? lastViewedIndicator : "MA"
    }

    init(
        parameters: ChartIndicatorParameters,
        onApply: @escaping (ChartIndicatorParameters) -> Void
    ) {
        _superTrendFillAlpha = State(initialValue: min(
            SuperTrendFillTransparency.maximumAlpha, parameters.superTrendFillAlpha))
        _movingAverageFast = State(
            initialValue: String(parameters.movingAveragePeriods[0])
        )
        _movingAverageMiddle = State(
            initialValue: String(parameters.movingAveragePeriods[1])
        )
        _movingAverageSlow = State(
            initialValue: String(parameters.movingAveragePeriods[2])
        )
        _emaFast = State(initialValue: String(parameters.emaPeriods[0]))
        _emaMiddle = State(initialValue: String(parameters.emaPeriods[1]))
        _emaSlow = State(initialValue: String(parameters.emaPeriods[2]))
        _bollingerPeriod = State(
            initialValue: String(parameters.bollingerPeriod)
        )
        _bollingerMultiplier = State(
            initialValue: parameters.bollingerMultiplierText
        )
        _parabolicSARStart = State(
            initialValue: parameters.parabolicSARStartText
        )
        _parabolicSARMaximum = State(
            initialValue: parameters.parabolicSARMaximumText
        )
        _superTrendATRPeriod = State(
            initialValue: String(parameters.superTrendATRPeriod)
        )
        _superTrendMultiplier = State(
            initialValue: parameters.superTrendMultiplierText
        )
        _volumeFastPeriod = State(
            initialValue: String(parameters.volumeFastPeriod)
        )
        _volumeSlowPeriod = State(
            initialValue: String(parameters.volumeSlowPeriod)
        )
        _macdFastPeriod = State(
            initialValue: String(parameters.macdFastPeriod)
        )
        _macdSlowPeriod = State(
            initialValue: String(parameters.macdSlowPeriod)
        )
        _macdSignalPeriod = State(
            initialValue: String(parameters.macdSignalPeriod)
        )
        _rsiPeriod = State(
            initialValue: String(parameters.rsiPeriod)
        )
        _kdjPeriod = State(initialValue: String(parameters.kdjPeriod))
        _kdjKSmoothing = State(
            initialValue: String(parameters.kdjKSmoothing)
        )
        _kdjDSmoothing = State(
            initialValue: String(parameters.kdjDSmoothing)
        )
        _williamsRPeriod = State(
            initialValue: String(parameters.williamsRPeriod)
        )
        _stochasticRSIPeriod = State(
            initialValue: String(parameters.stochasticRSIPeriod)
        )
        _stochasticRSIWindow = State(
            initialValue: String(parameters.stochasticRSIWindow)
        )
        _stochasticRSIKSmoothing = State(
            initialValue: String(parameters.stochasticRSIKSmoothing)
        )
        _stochasticRSIDSmoothing = State(
            initialValue: String(parameters.stochasticRSIDSmoothing)
        )
        _atrPeriod = State(initialValue: String(parameters.atrPeriod))
        self.onApply = onApply
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            indicatorSelector

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if selectedIndicator == "MA" {
                        settingsSection(
                            title: "MA",
                            subtitle: "移动平均线（币安默认 7 / 25 / 99）"
                        ) {
                            integerRow("周期 1", value: $movingAverageFast)
                            integerRow("周期 2", value: $movingAverageMiddle)
                            integerRow("周期 3", value: $movingAverageSlow)
                        }
                    }

                    if selectedIndicator == "EMA" {
                        settingsSection(
                            title: "EMA",
                            subtitle: "主图指数移动平均线"
                        ) {
                            integerRow("周期 1", value: $emaFast)
                            integerRow("周期 2", value: $emaMiddle)
                            integerRow("周期 3", value: $emaSlow)
                        }
                    }

                    if selectedIndicator == "BOLL" {
                        settingsSection(
                            title: "BOLL",
                            subtitle: "布林线计算周期与带宽"
                        ) {
                            integerRow("计算周期", value: $bollingerPeriod)
                            decimalRow("带宽", value: $bollingerMultiplier)
                        }
                    }

                    if selectedIndicator == "SAR" {
                        settingsSection(
                            title: "SAR",
                            subtitle: "抛物线转向加速因子"
                        ) {
                            decimalRow("开始", value: $parabolicSARStart)
                            decimalRow("最大", value: $parabolicSARMaximum)
                        }
                    }

                    if selectedIndicator == "AVL" {
                        settingsSection(
                            title: "AVL",
                            subtitle: "每根 K 线的成交额 ÷ 成交量均价线"
                        ) {
                            Text("无周期参数")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(
                                    IndicatorSettingsPalette.secondaryText
                                )
                                .frame(minHeight: BinanceTheme.Layout.minimumTapSize)
                        }
                    }

                    if selectedIndicator == "Super" {
                        settingsSection(
                            title: "Super",
                            subtitle: "ATR 周期与趋势带倍数"
                        ) {
                            integerRow(
                                "ATR 周期",
                                value: $superTrendATRPeriod
                            )
                            decimalRow(
                                "倍数",
                                value: $superTrendMultiplier
                            )
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("填充透明度").font(.system(size: 14))
                                    Spacer()
                                    Text("\(Int((SuperTrendFillTransparency.sliderValue(alpha: superTrendFillAlpha) * 100).rounded()))%")
                                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                                }
                                Slider(value: Binding(
                                    get: { SuperTrendFillTransparency.sliderValue(alpha: superTrendFillAlpha) },
                                    set: { superTrendFillAlpha = SuperTrendFillTransparency.alpha(sliderValue: $0) }
                                ), in: 0...1, step: 0.01)
                                    .tint(IndicatorSettingsPalette.accent)
                                    .accessibilityLabel("Super 填充透明度")
                                    .accessibilityIdentifier("indicator-settings.super-opacity")
                            }.foregroundStyle(IndicatorSettingsPalette.primaryText).padding(.top, 12)
                        }
                    }

                    if selectedIndicator == "VOL" {
                        settingsSection(
                            title: "VOL",
                            subtitle: "成交量均线周期"
                        ) {
                            integerRow(
                                "快速均量",
                                value: $volumeFastPeriod
                            )
                            integerRow(
                                "慢速均量",
                                value: $volumeSlowPeriod
                            )
                        }
                    }

                    if selectedIndicator == "MACD" {
                        settingsSection(
                            title: "MACD",
                            subtitle: "快线、慢线与信号线周期"
                        ) {
                            integerRow(
                                "快线周期",
                                value: $macdFastPeriod
                            )
                            integerRow(
                                "慢线周期",
                                value: $macdSlowPeriod
                            )
                            integerRow(
                                "信号周期",
                                value: $macdSignalPeriod
                            )
                        }
                    }

                    if selectedIndicator == "RSI" {
                        settingsSection(
                            title: "RSI",
                            subtitle: "Wilder 相对强弱周期"
                        ) {
                            integerRow(
                                "周期",
                                value: $rsiPeriod
                            )
                        }
                    }

                    if selectedIndicator == "KDJ" {
                        settingsSection(
                            title: "KDJ",
                            subtitle: "币安默认 9 / 3 / 3"
                        ) {
                            integerRow("计算周期", value: $kdjPeriod)
                            integerRow("K 平滑", value: $kdjKSmoothing)
                            integerRow("D 平滑", value: $kdjDSmoothing)
                        }
                    }

                    if selectedIndicator == "OBV" {
                        settingsSection(
                            title: "OBV",
                            subtitle: "能量潮主线"
                        ) {
                            Text("无周期参数")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(
                                    IndicatorSettingsPalette.secondaryText
                                )
                                .frame(minHeight: BinanceTheme.Layout.minimumTapSize)
                        }
                    }

                    if selectedIndicator == "WR" {
                        settingsSection(
                            title: "WR",
                            subtitle: "Williams %R"
                        ) {
                            integerRow("周期", value: $williamsRPeriod)
                        }
                    }

                    if selectedIndicator == "StochRSI" {
                        settingsSection(
                            title: "StochRSI",
                            subtitle: "RSI / 随机窗口 / K / D"
                        ) {
                            integerRow("RSI 周期", value: $stochasticRSIPeriod)
                            integerRow("随机窗口", value: $stochasticRSIWindow)
                            integerRow("K 平滑", value: $stochasticRSIKSmoothing)
                            integerRow("D 平滑", value: $stochasticRSIDSmoothing)
                        }
                    }

                    if selectedIndicator == "ATR" {
                        settingsSection(
                            title: "ATR",
                            subtitle: "Wilder 平均真实波幅"
                        ) {
                            integerRow("周期", value: $atrPeriod)
                        }
                    }

                    if selectedIndicator == "合约数据" {
                        settingsSection(
                            title: "合约数据",
                            subtitle: "O.I.、多空比、主动买卖量与 Basis"
                        ) {
                            Text("按当前 K 线周期读取币安近 30 天统计数据")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(
                                    IndicatorSettingsPalette.secondaryText
                                )
                                .frame(minHeight: BinanceTheme.Layout.minimumTapSize)
                        }
                    }

                    if let validationMessage {
                        Text(validationMessage)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(
                                IndicatorSettingsPalette.error
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 18)
            }

            applyButton
        }
        .background(
            IndicatorSettingsPalette.background
                .ignoresSafeArea()
        )
        .toolbar(.hidden, for: .navigationBar)
        .interactivePopGestureEnabled()
    }

    private var indicatorSelector: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(Self.indicatorTitles, id: \.self) { title in
                Button { lastViewedIndicator = title } label: {
                    Text(title).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(selectedIndicator == title ? BinanceTheme.onAccent : IndicatorSettingsPalette.primaryText)
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .background(selectedIndicator == title ? IndicatorSettingsPalette.accent : IndicatorSettingsPalette.surface,
                            in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityIdentifier("indicator-settings.tab." + title)
                  .accessibilityAddTraits(selectedIndicator == title ? .isSelected : [])
            }
        }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
    }

    private var header: some View {
        HStack {
            BinanceBackButton()

            Spacer()

            Text("指标设置")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(IndicatorSettingsPalette.primaryText)

            Spacer()

            Button("重置") {
                resetToDefaults()
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(BinanceTheme.accentText)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IndicatorSettingsPalette.divider)
                .frame(height: 0.5)
        }
    }

    private var applyButton: some View {
        Button {
            guard let resolvedParameters else {
                return
            }
            onApply(resolvedParameters)
            dismiss()
        } label: {
            Text("应用")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BinanceTheme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    IndicatorSettingsPalette.accent
                        .opacity(resolvedParameters == nil ? 0.45 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(resolvedParameters == nil)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(IndicatorSettingsPalette.background)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IndicatorSettingsPalette.divider)
                .frame(height: 0.5)
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(IndicatorSettingsPalette.primaryText)
            Text(subtitle)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(IndicatorSettingsPalette.secondaryText)
                .padding(.top, 3)
                .padding(.bottom, 8)

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IndicatorSettingsPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func integerRow(
        _ title: String,
        value: Binding<String>
    ) -> some View {
        parameterRow(title) {
            TextField("", text: value)
                .keyboardType(.numberPad)
        }
    }

    private func decimalRow(
        _ title: String,
        value: Binding<String>
    ) -> some View {
        parameterRow(title) {
            TextField("", text: value)
                .keyboardType(.decimalPad)
        }
    }

    private func parameterRow<Field: View>(
        _ title: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(IndicatorSettingsPalette.primaryText)

            Spacer(minLength: 12)

            field()
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(IndicatorSettingsPalette.primaryText)
                .multilineTextAlignment(.trailing)
                .frame(width: 96)
                .frame(minHeight: BinanceTheme.Layout.controlHeight)
                .padding(.horizontal, 10)
                .background(BinanceTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            IndicatorSettingsPalette.divider,
                            lineWidth: 0.5
                        )
                }
        }
        .frame(minHeight: BinanceTheme.Layout.settingsRowHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IndicatorSettingsPalette.divider.opacity(0.7))
                .frame(height: 0.5)
        }
    }

    private var resolvedParameters: ChartIndicatorParameters? {
        guard let movingAverageFast = parsedInteger(
                  movingAverageFast
              ),
              let movingAverageMiddle = parsedInteger(
                  movingAverageMiddle
              ),
              let movingAverageSlow = parsedInteger(
                  movingAverageSlow
              ),
              let emaFast = parsedInteger(emaFast),
              let emaMiddle = parsedInteger(emaMiddle),
              let emaSlow = parsedInteger(emaSlow),
              let bollingerPeriod = parsedInteger(bollingerPeriod),
              let bollingerMultiplier = parsedDouble(
                  bollingerMultiplier
              ),
              let parabolicSARStart = parsedDouble(
                  parabolicSARStart
              ),
              let parabolicSARMaximum = parsedDouble(
                  parabolicSARMaximum
              ),
              let superTrendATRPeriod = parsedInteger(
                superTrendATRPeriod
              ),
              let superTrendMultiplier = parsedDouble(
                superTrendMultiplier
              ),
              let volumeFastPeriod = parsedInteger(volumeFastPeriod),
              let volumeSlowPeriod = parsedInteger(volumeSlowPeriod),
              let macdFastPeriod = parsedInteger(macdFastPeriod),
              let macdSlowPeriod = parsedInteger(macdSlowPeriod),
              let macdSignalPeriod = parsedInteger(macdSignalPeriod),
              let rsiPeriod = parsedInteger(rsiPeriod),
              let kdjPeriod = parsedInteger(kdjPeriod),
              let kdjKSmoothing = parsedInteger(kdjKSmoothing),
              let kdjDSmoothing = parsedInteger(kdjDSmoothing),
              let williamsRPeriod = parsedInteger(williamsRPeriod),
              let stochasticRSIPeriod = parsedInteger(
                  stochasticRSIPeriod
              ),
              let stochasticRSIWindow = parsedInteger(
                  stochasticRSIWindow
              ),
              let stochasticRSIKSmoothing = parsedInteger(
                  stochasticRSIKSmoothing
              ),
              let stochasticRSIDSmoothing = parsedInteger(
                  stochasticRSIDSmoothing
              ),
              let atrPeriod = parsedInteger(atrPeriod) else {
            return nil
        }
        return ChartIndicatorParameters(
            emaPeriods: [emaFast, emaMiddle, emaSlow],
            superTrendATRPeriod: superTrendATRPeriod,
            superTrendMultiplier: superTrendMultiplier,
            volumeFastPeriod: volumeFastPeriod,
            volumeSlowPeriod: volumeSlowPeriod,
            macdFastPeriod: macdFastPeriod,
            macdSlowPeriod: macdSlowPeriod,
            macdSignalPeriod: macdSignalPeriod,
            rsiPeriod: rsiPeriod,
            movingAveragePeriods: [
                movingAverageFast,
                movingAverageMiddle,
                movingAverageSlow,
            ],
            bollingerPeriod: bollingerPeriod,
            bollingerMultiplier: bollingerMultiplier,
            parabolicSARStart: parabolicSARStart,
            parabolicSARMaximum: parabolicSARMaximum,
            kdjPeriod: kdjPeriod,
            kdjKSmoothing: kdjKSmoothing,
            kdjDSmoothing: kdjDSmoothing,
            williamsRPeriod: williamsRPeriod,
            stochasticRSIPeriod: stochasticRSIPeriod,
            stochasticRSIWindow: stochasticRSIWindow,
            stochasticRSIKSmoothing: stochasticRSIKSmoothing,
            stochasticRSIDSmoothing: stochasticRSIDSmoothing,
            atrPeriod: atrPeriod,
            superTrendFillAlpha: superTrendFillAlpha
        )
    }

    private var validationMessage: String? {
        guard resolvedParameters == nil else {
            return nil
        }
        guard let movingAverageFast = parsedInteger(
                  movingAverageFast
              ),
              let movingAverageMiddle = parsedInteger(
                  movingAverageMiddle
              ),
              let movingAverageSlow = parsedInteger(
                  movingAverageSlow
              ),
              let emaFast = parsedInteger(emaFast),
              let emaMiddle = parsedInteger(emaMiddle),
              let emaSlow = parsedInteger(emaSlow),
              parsedInteger(bollingerPeriod) != nil,
              parsedDouble(bollingerMultiplier) != nil,
              let parabolicSARStart = parsedDouble(
                  parabolicSARStart
              ),
              let parabolicSARMaximum = parsedDouble(
                  parabolicSARMaximum
              ),
              let volumeFastPeriod = parsedInteger(volumeFastPeriod),
              let volumeSlowPeriod = parsedInteger(volumeSlowPeriod),
              let macdFastPeriod = parsedInteger(macdFastPeriod),
              let macdSlowPeriod = parsedInteger(macdSlowPeriod),
              parsedInteger(superTrendATRPeriod) != nil,
              parsedDouble(superTrendMultiplier) != nil,
              parsedInteger(macdSignalPeriod) != nil,
              parsedInteger(rsiPeriod) != nil,
              parsedInteger(kdjPeriod) != nil,
              parsedInteger(kdjKSmoothing) != nil,
              parsedInteger(kdjDSmoothing) != nil,
              parsedInteger(williamsRPeriod) != nil,
              parsedInteger(stochasticRSIPeriod) != nil,
              parsedInteger(stochasticRSIWindow) != nil,
              parsedInteger(stochasticRSIKSmoothing) != nil,
              parsedInteger(stochasticRSIDSmoothing) != nil,
              parsedInteger(atrPeriod) != nil else {
            return "请完整填写有效数字。"
        }
        if !(movingAverageFast < movingAverageMiddle
              && movingAverageMiddle < movingAverageSlow) {
            return "MA 三个周期必须按从小到大填写。"
        }
        if !(emaFast < emaMiddle && emaMiddle < emaSlow) {
            return "EMA 三个周期必须按从小到大填写。"
        }
        if volumeFastPeriod > volumeSlowPeriod {
            return "VOL 快速均量周期不能大于慢速均量周期。"
        }
        if macdFastPeriod >= macdSlowPeriod {
            return "MACD 快线周期必须小于慢线周期。"
        }
        if parabolicSARStart > parabolicSARMaximum {
            return "SAR 开始值不能大于最大值。"
        }
        return "参数超出允许范围，或倍数不符合步进要求。"
    }

    private func resetToDefaults() {
        let defaults = ChartIndicatorParameters.standard
        movingAverageFast = String(defaults.movingAveragePeriods[0])
        movingAverageMiddle = String(defaults.movingAveragePeriods[1])
        movingAverageSlow = String(defaults.movingAveragePeriods[2])
        emaFast = String(defaults.emaPeriods[0])
        emaMiddle = String(defaults.emaPeriods[1])
        emaSlow = String(defaults.emaPeriods[2])
        bollingerPeriod = String(defaults.bollingerPeriod)
        bollingerMultiplier = defaults.bollingerMultiplierText
        parabolicSARStart = defaults.parabolicSARStartText
        parabolicSARMaximum = defaults.parabolicSARMaximumText
        superTrendATRPeriod = String(defaults.superTrendATRPeriod)
        superTrendMultiplier = defaults.superTrendMultiplierText
        superTrendFillAlpha = defaults.superTrendFillAlpha
        volumeFastPeriod = String(defaults.volumeFastPeriod)
        volumeSlowPeriod = String(defaults.volumeSlowPeriod)
        macdFastPeriod = String(defaults.macdFastPeriod)
        macdSlowPeriod = String(defaults.macdSlowPeriod)
        macdSignalPeriod = String(defaults.macdSignalPeriod)
        rsiPeriod = String(defaults.rsiPeriod)
        kdjPeriod = String(defaults.kdjPeriod)
        kdjKSmoothing = String(defaults.kdjKSmoothing)
        kdjDSmoothing = String(defaults.kdjDSmoothing)
        williamsRPeriod = String(defaults.williamsRPeriod)
        stochasticRSIPeriod = String(defaults.stochasticRSIPeriod)
        stochasticRSIWindow = String(defaults.stochasticRSIWindow)
        stochasticRSIKSmoothing = String(
            defaults.stochasticRSIKSmoothing
        )
        stochasticRSIDSmoothing = String(
            defaults.stochasticRSIDSmoothing
        )
        atrPeriod = String(defaults.atrPeriod)
    }

    private func parsedInteger(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parsedDouble(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
