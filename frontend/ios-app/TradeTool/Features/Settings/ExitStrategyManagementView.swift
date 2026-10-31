import SwiftUI

struct ExitStrategyManagementView: View {
    @EnvironmentObject private var toastCenter: AppToastCenter
    @ObservedObject var viewModel: SettingsAccountViewModel

    @State private var strategyToDelete: TradingExitStrategy?

    var body: some View {
        SettingsDetailPage(title: "止盈止损策略") {
            VStack(alignment: .leading, spacing: 16) {
                Text("我的策略")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(BinanceTheme.primaryText)

                if viewModel.exitStrategies.isEmpty {
                    emptyState
                } else {
                    ForEach(viewModel.exitStrategies) { strategy in
                        strategyCard(strategy)
                    }
                }

                NavigationLink {
                    ExitStrategyEditorView(
                        strategy: nil,
                        viewModel: viewModel
                    )
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                        Text("新建策略")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BinanceTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        BinanceTheme.accent,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                .buttonStyle(.plain)

                Text("策略会用于后续新建仓；已打开仓位继续使用建仓时冻结的策略快照。")
                    .font(.system(size: 12))
                    .foregroundStyle(BinanceTheme.secondaryText)
                    .lineSpacing(3)
                    .padding(14)
                    .background(
                        BinanceTheme.accent.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
            }
        }
        .confirmationDialog(
            "确认删除",
            isPresented: Binding(
                get: { strategyToDelete != nil },
                set: { if !$0 { strategyToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let strategyToDelete {
                    delete(strategyToDelete)
                }
            }
            Button("取消", role: .cancel) {
                strategyToDelete = nil
            }
        } message: {
            Text("删除后无法恢复，但不会撤销交易所中已经存在的订单。")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "scope")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(BinanceTheme.accentText)

            Text("还没有止盈止损策略")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BinanceTheme.primaryText)

            Text("可创建最多 5 级的减仓与移动止损动作")
                .font(.system(size: 12))
                .foregroundStyle(BinanceTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .settingsPanel()
    }

    private func strategyCard(_ strategy: TradingExitStrategy) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Text(strategy.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(BinanceTheme.primaryText)

                Spacer()

                NavigationLink {
                    ExitStrategyEditorView(
                        strategy: strategy,
                        viewModel: viewModel
                    )
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(BinanceTheme.secondaryText)
                        .frame(width: 34, height: 34)
                        .background(
                            BinanceTheme.elevated,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    strategyToDelete = strategy
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(BinanceTheme.negative)
                        .frame(width: 34, height: 34)
                        .background(
                            BinanceTheme.negative.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
            }

            Rectangle()
                .fill(BinanceTheme.border)
                .frame(height: 0.5)

            ForEach(strategy.levels, id: \.stableID) { level in
                HStack(alignment: .top, spacing: 10) {
                    Text("L\(level.level)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(BinanceTheme.onAccent)
                        .frame(width: 30, height: 22)
                        .background(BinanceTheme.accent, in: Capsule())

                    Text(levelSummary(level))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(BinanceTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(15)
        .settingsPanel()
    }

    private func levelSummary(_ level: TradingExitStrategyLevel) -> String {
        var actions: [String] = []
        if level.reducePercent > 0 {
            actions.append("减仓 \(compactNumber(level.reducePercent))%")
        }
        switch level.moveStopMode {
        case .none:
            break
        case .fixedR:
            actions.append("止损移到 \(compactNumber(level.moveStopR ?? 0))R")
        case .trailingProfitR:
            actions.append(
                "止损保持浮盈 − \(compactNumber(level.moveStopR ?? 0))R"
            )
        }
        return "盈利 ≥ \(compactNumber(level.triggerR))R · "
            + actions.joined(separator: " · ")
    }

    private func delete(_ strategy: TradingExitStrategy) {
        strategyToDelete = nil
        Task {
            do {
                try await viewModel.deleteExitStrategy(id: strategy.id)
                toastCenter.success("策略已删除")
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }
}

private struct ExitStrategyLevelDraft: Identifiable {
    let id = UUID()
    var triggerR = ""
    var reducesPosition = false
    var reducePercent = ""
    var movesStop = false
    var moveMode: ExitStrategyStopMoveMode = .fixedR
    var fixedMoveStopR = ""
    var trailingMoveStopR = ""

    init() {}

    init(level: TradingExitStrategyLevel) {
        triggerR = compactNumber(level.triggerR)
        reducesPosition = level.reducePercent > 0
        reducePercent = reducesPosition
            ? compactNumber(level.reducePercent)
            : ""
        movesStop = level.moveStopMode != .none
        moveMode = level.moveStopMode == .none ? .fixedR : level.moveStopMode
        if level.moveStopMode == .fixedR {
            fixedMoveStopR = level.moveStopR.map(compactNumber) ?? ""
        } else if level.moveStopMode == .trailingProfitR {
            trailingMoveStopR = level.moveStopR.map(compactNumber) ?? ""
        }
    }
}

private struct ExitStrategyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toastCenter: AppToastCenter
    @ObservedObject var viewModel: SettingsAccountViewModel

    let strategyID: String?
    @State private var name: String
    @State private var editsName = false
    @State private var levels: [ExitStrategyLevelDraft]
    @State private var isSaving = false

    init(
        strategy: TradingExitStrategy?,
        viewModel: SettingsAccountViewModel
    ) {
        self.viewModel = viewModel
        strategyID = strategy?.id
        _name = State(initialValue: strategy?.name ?? "策略1")
        _levels = State(initialValue: strategy?.levels.map {
            ExitStrategyLevelDraft(level: $0)
        } ?? [ExitStrategyLevelDraft()])
    }

    var body: some View {
        VStack(spacing: 0) {
            BinanceNavigationHeader(
                title: strategyID == nil ? "新建策略" : "编辑策略"
            )

            Rectangle()
                .fill(BinanceTheme.border)
                .frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    nameHeader
                    riskExplanation

                    ForEach(Array(levels.indices), id: \.self) { index in
                        levelEditor(index: index)
                    }

                    if levels.count < 5 {
                        Button {
                            levels.append(ExitStrategyLevelDraft())
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "plus")
                                Text("添加 L\(levels.count + 1)")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(BinanceTheme.accentText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(
                                        BinanceTheme.accent.opacity(0.65),
                                        style: StrokeStyle(
                                            lineWidth: 1,
                                            dash: [5, 4]
                                        )
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Text("每一级首次进入触发条件后只执行一次；持续移动模式会随浮盈扩大而收紧止损。")
                        .font(.system(size: 12))
                        .foregroundStyle(BinanceTheme.secondaryText)
                        .lineSpacing(3)
                        .padding(14)
                        .background(
                            BinanceTheme.accent.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
                .padding(.horizontal, BinanceTheme.Layout.pageHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 92)
            }
        }
        .background(BinanceTheme.marketBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .interactivePopGestureEnabled()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                save()
            } label: {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                            .tint(BinanceTheme.onAccent)
                    }
                    Text("确定")
                }
            }
            .buttonStyle(BinancePrimaryButtonStyle())
            .disabled(!canSave || isSaving)
            .opacity(canSave && !isSaving ? 1 : 0.42)
            .padding(.horizontal, BinanceTheme.Layout.pageHorizontalPadding)
            .padding(.vertical, 12)
            .background(BinanceTheme.marketBackground)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(BinanceTheme.border)
                    .frame(height: 0.5)
            }
        }
    }

    private var nameHeader: some View {
        HStack(spacing: 8) {
            if editsName {
                TextField("策略名称", text: $name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(BinanceTheme.primaryText)
                    .submitLabel(.done)
                    .onSubmit { editsName = false }
            } else {
                Text(name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(BinanceTheme.primaryText)
                    .lineLimit(1)
            }

            Button {
                editsName.toggle()
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BinanceTheme.secondaryText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    private var riskExplanation: some View {
        let amount = viewModel.lossLimit?.currentAmount ?? 0
        let asset = viewModel.lossLimit?.settlementAsset
            ?? viewModel.snapshot?.quoteAsset
            ?? "USDC"
        return Text(
            "R 是指基准止损金额，您当前的基准止损金额为 "
                + "\(compactNumber(amount)) \(asset)"
        )
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(BinanceTheme.secondaryText)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            BinanceTheme.accent.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func levelEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("L\(index + 1)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(BinanceTheme.onAccent)
                    .frame(width: 36, height: 25)
                    .background(BinanceTheme.accent, in: Capsule())

                Text("剩余仓位 \(compactNumber(remainingPosition(before: index)))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BinanceTheme.secondaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(BinanceTheme.elevated, in: Capsule())

                Spacer()

                if levels.count > 1 {
                    Button {
                        levels.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(BinanceTheme.negative)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 9) {
                Text("当盈利达到")
                strategyNumberField(
                    text: $levels[index].triggerR,
                    placeholder: index == 0 ? "2" : ""
                )
                Text("R 时")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(BinanceTheme.primaryText)

            Rectangle()
                .fill(BinanceTheme.border)
                .frame(height: 0.5)

            VStack(alignment: .leading, spacing: 4) {
                Text("仓位动作")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BinanceTheme.secondaryText)
                    .padding(.bottom, 2)

                StrategyChoiceRow(
                    title: "不减仓",
                    isSelected: !levels[index].reducesPosition
                ) {
                    levels[index].reducesPosition = false
                    levels[index].reducePercent = ""
                }

                StrategyChoiceRow(
                    title: "减仓",
                    isSelected: levels[index].reducesPosition
                ) {
                    levels[index].reducesPosition = true
                } trailing: {
                    if levels[index].reducesPosition {
                        HStack(spacing: 4) {
                            strategyNumberField(
                                text: $levels[index].reducePercent,
                                placeholder: "50"
                            )
                            Text("%")
                                .foregroundStyle(BinanceTheme.secondaryText)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("同时执行")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BinanceTheme.secondaryText)
                    .padding(.bottom, 2)

                StrategyChoiceRow(
                    title: "不移动止损位",
                    isSelected: !levels[index].movesStop
                ) {
                    levels[index].movesStop = false
                    levels[index].fixedMoveStopR = ""
                    levels[index].trailingMoveStopR = ""
                }

                StrategyChoiceRow(
                    title: "移动止损位",
                    isSelected: levels[index].movesStop
                ) {
                    levels[index].movesStop = true
                }

                if levels[index].movesStop {
                    moveStopChoices(index: index)
                        .padding(.leading, 20)
                }
            }
        }
        .padding(15)
        .settingsPanel()
    }

    private func moveStopChoices(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            StrategyChoiceRow(
                title: "移动到",
                isSelected: levels[index].moveMode == .fixedR
            ) {
                levels[index].moveMode = .fixedR
                levels[index].trailingMoveStopR = ""
            } trailing: {
                HStack(spacing: 4) {
                    strategyNumberField(
                        text: $levels[index].fixedMoveStopR,
                        placeholder: levels[index].moveMode == .fixedR ? "0" : "",
                        width: 54,
                        isEnabled: levels[index].moveMode == .fixedR
                    )
                    Text("R 位置")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("一次")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(BinanceTheme.accentText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(BinanceTheme.accent.opacity(0.1), in: Capsule())
                }
                .foregroundStyle(BinanceTheme.secondaryText)
            }

            StrategyChoiceRow(
                title: "移动到 当前浮盈 −",
                isSelected: levels[index].moveMode == .trailingProfitR
            ) {
                levels[index].moveMode = .trailingProfitR
                levels[index].fixedMoveStopR = ""
            } trailing: {
                HStack(spacing: 4) {
                    strategyNumberField(
                        text: $levels[index].trailingMoveStopR,
                        placeholder: levels[index].moveMode == .trailingProfitR ? "1" : "",
                        width: 54,
                        isEnabled: levels[index].moveMode == .trailingProfitR
                    )
                    Text("R 位置")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("持续")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(BinanceTheme.positive)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(BinanceTheme.positive.opacity(0.1), in: Capsule())
                }
                .foregroundStyle(BinanceTheme.secondaryText)
            }
        }
    }

    private func strategyNumberField(
        text: Binding<String>,
        placeholder: String,
        width: CGFloat = 58,
        isEnabled: Bool = true
    ) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundStyle(
                isEnabled
                    ? BinanceTheme.primaryText
                    : BinanceTheme.secondaryText
            )
            .frame(width: width, height: 36)
            .background(
                BinanceTheme.elevated.opacity(isEnabled ? 1 : 0.45),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        BinanceTheme.border.opacity(isEnabled ? 1 : 0.55),
                        lineWidth: 0.8
                    )
            }
            .disabled(!isEnabled)
    }

    private var parsedLevels: [TradingExitStrategyLevel]? {
        var result: [TradingExitStrategyLevel] = []
        var remaining = 100.0
        var previousTrigger = 0.0

        for (index, level) in levels.enumerated() {
            guard let trigger = parseStrategyNumber(level.triggerR),
                  trigger >= 0.1,
                  trigger <= 1_000,
                  trigger > previousTrigger else {
                return nil
            }

            let reduction: Double
            if level.reducesPosition {
                guard let value = parseStrategyNumber(level.reducePercent),
                      value > 0,
                      value <= remaining else {
                    return nil
                }
                reduction = value
            } else {
                reduction = 0
            }

            let moveMode: ExitStrategyStopMoveMode
            let moveR: Double?
            if level.movesStop {
                let selectedValue = level.moveMode == .fixedR
                    ? level.fixedMoveStopR
                    : level.trailingMoveStopR
                guard let value = parseStrategyNumber(selectedValue) else {
                    return nil
                }
                moveMode = level.moveMode
                if moveMode == .fixedR {
                    guard (-100...1_000).contains(value) else { return nil }
                } else {
                    guard (0.1...1_000).contains(value) else { return nil }
                }
                moveR = value
            } else {
                moveMode = .none
                moveR = nil
            }

            guard reduction > 0 || moveMode != .none else { return nil }
            result.append(TradingExitStrategyLevel(
                id: nil,
                level: index + 1,
                triggerR: trigger,
                reducePercent: reduction,
                moveStopMode: moveMode,
                moveStopR: moveR
            ))
            remaining -= reduction
            previousTrigger = trigger
        }
        return result
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.count <= 32
            && parsedLevels != nil
    }

    private func remainingPosition(before index: Int) -> Double {
        guard index > 0 else { return 100 }
        return max(0, 100 - levels[..<index].reduce(0) { partial, level in
            partial + (level.reducesPosition
                ? (parseStrategyNumber(level.reducePercent) ?? 0)
                : 0)
        })
    }

    private func save() {
        guard let parsedLevels else {
            toastCenter.warning("请完整填写级别，并保证后一级 R 高于前一级")
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await viewModel.saveExitStrategy(
                    id: strategyID,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    levels: parsedLevels
                )
                toastCenter.success("策略已保存")
                dismiss()
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }
}

private struct StrategyChoiceRow<Trailing: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 9) {
                    ZStack {
                        Circle()
                            .stroke(
                                isSelected
                                    ? BinanceTheme.accent
                                    : BinanceTheme.secondaryText,
                                lineWidth: 1.4
                            )
                        if isSelected {
                            Circle()
                                .fill(BinanceTheme.accent)
                                .padding(4)
                        }
                    }
                    .frame(width: 17, height: 17)

                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BinanceTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)
            trailing()
        }
        .frame(height: 38)
    }
}

private extension StrategyChoiceRow where Trailing == EmptyView {
    init(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            isSelected: isSelected,
            action: action
        ) {
            EmptyView()
        }
    }
}

struct StopLossLimitSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toastCenter: AppToastCenter
    @ObservedObject var viewModel: SettingsAccountViewModel

    @State private var percentage: Double
    @State private var isSaving = false

    init(viewModel: SettingsAccountViewModel) {
        self.viewModel = viewModel
        _percentage = State(
            initialValue: Double(viewModel.lossLimit?.currentPercentage ?? 3)
        )
    }

    var body: some View {
        ZStack {
            BinanceTheme.marketBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        accountBalance
                        percentageCard
                        explanation
                    }
                    .padding(.horizontal, BinanceTheme.Layout.pageHorizontalPadding)
                    .padding(.bottom, 18)
                }

                Button {
                    save()
                } label: {
                    HStack(spacing: 8) {
                        if isSaving {
                            ProgressView()
                                .tint(BinanceTheme.onAccent)
                        }
                        Text("确定")
                    }
                }
                .buttonStyle(BinancePrimaryButtonStyle())
                .disabled(!hasChanges || isSaving)
                .opacity(hasChanges && !isSaving ? 1 : 0.42)
                .padding(.horizontal, BinanceTheme.Layout.pageHorizontalPadding)
                .padding(.vertical, 12)
                .background(BinanceTheme.marketBackground)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(BinanceTheme.border)
                        .frame(height: 0.5)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("止损设置")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(BinanceTheme.primaryText)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BinanceTheme.secondaryText)
                    .frame(width: 36, height: 36)
                    .background(BinanceTheme.elevated, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, BinanceTheme.Layout.pageHorizontalPadding)
        .padding(.vertical, 13)
    }

    private var accountBalance: some View {
        HStack {
            Text("账户余额")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BinanceTheme.secondaryText)

            Spacer()

            Text(
                "\(money(balance)) \(asset)"
            )
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundStyle(BinanceTheme.primaryText)
        }
        .padding(14)
        .background(BinanceTheme.elevated, in: RoundedRectangle(cornerRadius: 11))
    }

    private var percentageCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("止损比例")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BinanceTheme.secondaryText)

                    Text("\(selectedPercentage)%")
                        .font(.system(size: 31, weight: .bold).monospacedDigit())
                        .foregroundStyle(BinanceTheme.primaryText)
                }

                Spacer()

                Text(riskLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(riskColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(riskColor.opacity(0.1), in: Capsule())
            }

            LossPercentageSlider(
                percentage: $percentage,
                currentPercentage: viewModel.lossLimit?.currentPercentage ?? 3
            )

            HStack {
                Text("1%")
                Spacer()
                Text("25%")
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(BinanceTheme.secondaryText)

            Rectangle()
                .fill(BinanceTheme.border)
                .frame(height: 0.5)

            VStack(alignment: .leading, spacing: 7) {
                Text("本次计算")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BinanceTheme.secondaryText)

                Text(
                    "\(money(balance)) × \(selectedPercentage)% = "
                        + "\(money(rawAmount)) \(asset)  向上取整"
                )
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(BinanceTheme.secondaryText)

                Text("\(money(previewAmount)) \(asset)")
                    .font(.system(size: 27, weight: .bold).monospacedDigit())
                    .foregroundStyle(BinanceTheme.accentText)
            }

            if let pending = viewModel.lossLimit?.pendingPercentage,
               let amount = viewModel.lossLimit?.pendingAmount,
               let date = viewModel.lossLimit?.pendingEffectiveAt {
                Text(
                    "待生效：\(pending)%（\(money(amount)) \(asset)），"
                        + date.formatted(.dateTime.month().day().hour().minute())
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BinanceTheme.accentText)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    BinanceTheme.accent.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 9)
                )
            }
        }
        .padding(16)
        .background(BinanceTheme.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(BinanceTheme.border, lineWidth: 0.8)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            LossRuleRow(number: 1, text: "止损金额按照百分比计算会自动调整")
            LossRuleRow(number: 2, text: "止损金额设定后，不再随账户余额变动而变动")
            LossRuleRow(number: 3, text: "调低止损额会立即生效，调高止损额 2 小时后生效")
        }
    }

    private var selectedPercentage: Int { Int(percentage.rounded()) }
    private var balance: Double {
        viewModel.lossLimit?.accountBalance
            ?? viewModel.snapshot.map { decimalDouble($0.totalMarginBalance) }
            ?? 0
    }
    private var asset: String {
        viewModel.lossLimit?.settlementAsset
            ?? viewModel.snapshot?.quoteAsset
            ?? "USDC"
    }
    private var rawAmount: Double {
        balance * Double(selectedPercentage) / 100
    }
    private var previewAmount: Double {
        TradingLossLimitSettings.previewAmount(
            balance: balance,
            percentage: selectedPercentage
        )
    }
    private var hasChanges: Bool {
        selectedPercentage != viewModel.lossLimit?.currentPercentage
    }
    private var riskLabel: String {
        switch selectedPercentage {
        case 1...4: "低风险"
        case 5...10: "中风险"
        default: "高风险"
        }
    }
    private var riskColor: Color {
        switch selectedPercentage {
        case 1...4: BinanceTheme.positive
        case 5...10: BinanceTheme.accentText
        default: BinanceTheme.negative
        }
    }

    private func money(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let saved = try await viewModel.saveLossLimit(
                    percentage: selectedPercentage
                )
                if let effectiveAt = saved.pendingEffectiveAt,
                   saved.pendingPercentage == selectedPercentage {
                    toastCenter.success(
                        "调高止损额已提交，将于 "
                            + effectiveAt.formatted(
                                .dateTime.hour().minute()
                            ) + " 生效"
                    )
                } else {
                    toastCenter.success("止损额已立即生效")
                }
                dismiss()
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }
}

private struct LossPercentageSlider: View {
    @Binding var percentage: Double
    let currentPercentage: Int

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - 28, 1)
            let selectedX = position(
                for: Int(percentage.rounded()),
                width: width
            ) + 14
            let currentX = position(for: currentPercentage, width: width) + 14

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(BinanceTheme.border)
                    .frame(height: 4)
                    .padding(.horizontal, 14)

                Capsule()
                    .fill(BinanceTheme.accent)
                    .frame(width: max(selectedX - 14, 2), height: 4)
                    .offset(x: 14)

                VStack(spacing: 2) {
                    Text("当前")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(BinanceTheme.secondaryText)
                    Circle()
                        .fill(BinanceTheme.secondaryText)
                        .frame(width: 5, height: 5)
                }
                .position(x: currentX, y: 5)

                Circle()
                    .fill(BinanceTheme.accent)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Circle()
                            .stroke(BinanceTheme.background, lineWidth: 4)
                    }
                    .position(x: selectedX, y: proxy.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let normalized = min(
                            max((value.location.x - 14) / width, 0),
                            1
                        )
                        percentage = Double(
                            Int((normalized * 24).rounded()) + 1
                        )
                    }
            )
        }
        .frame(height: 46)
        .accessibilityLabel("止损比例")
        .accessibilityValue("\(Int(percentage))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                percentage = min(25, percentage + 1)
            case .decrement:
                percentage = max(1, percentage - 1)
            @unknown default:
                break
            }
        }
    }

    private func position(for value: Int, width: CGFloat) -> CGFloat {
        CGFloat(min(max(value, 1), 25) - 1) / 24 * width
    }
}

private struct LossRuleRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(BinanceTheme.onAccent)
                .frame(width: 20, height: 20)
                .background(BinanceTheme.accent, in: Circle())

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(BinanceTheme.secondaryText)
                .lineSpacing(2)
        }
    }
}

private func parseStrategyNumber(_ value: String) -> Double? {
    Double(
        value
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    )
}
