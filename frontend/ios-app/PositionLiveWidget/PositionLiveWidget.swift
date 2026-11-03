import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PositionLiveWidgetBundle: WidgetBundle {
    var body: some Widget { PositionLiveWidget() }
}

struct PositionLiveWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PositionLiveActivityAttributes.self) { context in
            let stale = hasStaleContent(context)
            VStack(alignment: .leading, spacing: 7) {
                PositionLiveHeading(tradingMode: context.attributes.tradingMode)
                PositionLiveRows(state: context.state, isStale: stale, limit: 4)
                PositionLiveFooter(state: context.state, isStale: stale)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .privacySensitive()
            .activityBackgroundTint(PositionLiveColors.background)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let stale = hasStaleContent(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("持仓 live", systemImage: "waveform.path")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PositionLiveColors.yellow)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.tradingMode == "lead" ? "带单" : "合约")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        PositionLiveRows(state: context.state, isStale: stale, limit: 3)
                        PositionLiveFooter(state: context.state, isStale: stale)
                    }.privacySensitive()
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "waveform.path").foregroundStyle(PositionLiveColors.yellow)
                    Text(context.state.positions.first.map { compactSymbol($0.symbol) } ?? "live")
                        .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                }.font(.system(size: 11, weight: .semibold)).privacySensitive()
            } compactTrailing: {
                if let row = context.state.positions.first {
                    PositionLiveProfit(row: row, available: !stale && context.state.status.isEmpty)
                        .font(.system(size: 12, weight: .semibold)).privacySensitive()
                } else {
                    Text("--").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } minimal: {
                Image(systemName: "waveform.path").foregroundStyle(PositionLiveColors.yellow)
            }
            .keylineTint(PositionLiveColors.yellow)
        }
    }

    private func hasStaleContent(_ context: ActivityViewContext<PositionLiveActivityAttributes>) -> Bool {
        context.isStale || context.state.updatedAt <= 0
            || Date().timeIntervalSince1970 - TimeInterval(context.state.updatedAt)
                > TimeInterval(PositionLiveContentState.freshnessInterval)
    }

    private func compactSymbol(_ symbol: String) -> String {
        symbol.hasSuffix("USDT") ? String(symbol.dropLast(4)) : symbol
    }
}

private struct PositionLiveHeading: View {
    let tradingMode: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path").foregroundStyle(PositionLiveColors.yellow)
            Text("持仓 live").foregroundStyle(.white)
            Spacer(minLength: 4)
            Text(tradingMode == "lead" ? "带单" : "合约")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(PositionLiveColors.yellow)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(PositionLiveColors.yellow.opacity(0.13), in: Capsule())
        }.font(.system(size: 12, weight: .semibold))
    }
}

private struct PositionLiveRows: View {
    let state: PositionLiveContentState
    let isStale: Bool
    let limit: Int
    var body: some View {
        VStack(spacing: 3) {
            if state.positions.isEmpty {
                Text(state.status.isEmpty ? "暂无持仓" : state.status)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(state.positions.prefix(limit)), id: \.id) { row in
                    HStack(spacing: 6) {
                        Text(row.symbol).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                        Text(row.isShort ? "空" : "多").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(row.isShort ? PositionLiveColors.red : PositionLiveColors.green)
                        Spacer(minLength: 6)
                        PositionLiveProfit(row: row, available: !isStale && state.status.isEmpty)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                if state.totalCount > min(limit, state.positions.count) {
                    Text("另有 \(state.totalCount - min(limit, state.positions.count)) 笔持仓")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct PositionLiveProfit: View {
    let row: PositionLiveRow
    let available: Bool
    private var profitColor: Color {
        if !available || row.profit == "--" { return .white.opacity(0.6) }
        let value = row.profit.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("-") || value.hasPrefix("−") ? PositionLiveColors.red : PositionLiveColors.green
    }
    var body: some View {
        Text(available ? row.profit : "--").monospacedDigit().foregroundStyle(profitColor)
            .lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityLabel(available ? "浮盈浮亏 \(row.profit)" : "浮盈浮亏更新延迟")
    }
}

private struct PositionLiveFooter: View {
    let state: PositionLiveContentState
    let isStale: Bool
    var body: some View {
        HStack(spacing: 4) {
            if isStale {
                Text("更新延迟").foregroundStyle(PositionLiveColors.yellow)
            } else if !state.status.isEmpty && !state.positions.isEmpty {
                Text(state.status).lineLimit(1).foregroundStyle(.white.opacity(0.65))
            }
            Spacer(minLength: 4)
            if state.updatedAt > 0 {
                Text("更新")
                Text(Date(timeIntervalSince1970: TimeInterval(state.updatedAt)), style: .time)
            }
        }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
    }
}

private enum PositionLiveColors {
    static let background = Color(red: 0.129, green: 0.153, blue: 0.192)
    static let yellow = Color(red: 0.988, green: 0.835, blue: 0.208)
    static let green = Color(red: 0.180, green: 0.741, blue: 0.522)
    static let red = Color(red: 0.965, green: 0.275, blue: 0.365)
}
