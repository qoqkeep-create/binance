import Foundation

struct ReferenceTradeNotification:
    Identifiable,
    Decodable,
    Hashable,
    Sendable {

    enum NotificationType: String, Decodable, Sendable {
        case open = "OPEN"
        case stopLoss = "STOP_LOSS"
        case strategyTakeProfit = "STRATEGY_TAKE_PROFIT"
        case manualTakeProfit = "MANUAL_TAKE_PROFIT"
        case reduction = "REDUCTION"

        var title: String {
            switch self {
            case .open:
                return "开仓"
            case .stopLoss:
                return "止损"
            case .strategyTakeProfit:
                return "策略止盈"
            case .manualTakeProfit:
                return "手动止盈"
            case .reduction:
                return "减仓"
            }
        }
    }

    let id: UUID
    let eventId: String
    let schemaVersion: Int
    let type: NotificationType
    let title: String
    let content: String
    let occurredAt: Date
    let receivedAt: Date
}

struct ReferenceTradeNotificationPageResponse: Decodable {
    let size: Int
    let hasNext: Bool
    let nextCursor: String?
    let items: [ReferenceTradeNotification]
}

extension ReferenceTradeNotification {
    enum Direction: Equatable, Sendable {
        case long
        case short

        var title: String {
            switch self {
            case .long:
                return "多"
            case .short:
                return "空"
            }
        }
    }

    struct SummaryDetail: Equatable, Sendable {
        let label: String
        let value: String
    }

    struct Summary: Equatable, Sendable {
        let sourceSymbol: String?
        let usdcSymbol: String?
        let direction: Direction?
        let details: [SummaryDetail]
    }

    var summary: Summary {
        let text = title + "\n" + content
        let sourceSymbol = Self.firstContractSymbol(in: text)
        let fields = Self.contentFields(content)

        return Summary(
            sourceSymbol: sourceSymbol,
            usdcSymbol: sourceSymbol.map(Self.usdcSymbol(from:)),
            direction: Self.direction(in: text),
            details: Self.summaryDetails(for: type, fields: fields)
        )
    }

    private static func firstContractSymbol(in text: String) -> String? {
        let normalized = text.uppercased()
        let pattern = #"(?<![A-Z0-9])([A-Z0-9]{2,})(USDC|USDT)(?![A-Z0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: normalized,
                range: NSRange(normalized.startIndex..., in: normalized)
              ),
              let range = Range(match.range, in: normalized) else {
            return nil
        }
        return String(normalized[range])
    }

    private static func usdcSymbol(from sourceSymbol: String) -> String {
        if sourceSymbol.hasSuffix("USDC") {
            return sourceSymbol
        }
        return String(sourceSymbol.dropLast(4)) + "USDC"
    }

    private static func direction(in text: String) -> Direction? {
        let normalized = text.uppercased()
        if normalized.contains("多单")
            || normalized.contains("做多")
            || normalized.contains("LONG") {
            return .long
        }
        if normalized.contains("空单")
            || normalized.contains("做空")
            || normalized.contains("SHORT") {
            return .short
        }
        return nil
    }

    private static func contentFields(_ content: String) -> [String: String] {
        var fields: [String: String] = [:]

        for rawLine in content.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if line.hasPrefix(">") {
                line.removeFirst()
            }
            line = line
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let separator = [line.firstIndex(of: "："), line.firstIndex(of: ":")]
                .compactMap { $0 }
                .min()
            guard let separator else { continue }

            let key = String(line[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty, fields[key] == nil else {
                continue
            }
            fields[key] = value
        }

        return fields
    }

    private static func summaryDetails(
        for type: NotificationType,
        fields: [String: String]
    ) -> [SummaryDetail] {
        let candidates: [(String, [String])]
        switch type {
        case .open:
            candidates = [
                ("成交价格", ["成交价", "成交价格", "开仓价", "开仓价格"]),
                ("止损价格", ["止损价", "止损价格"]),
            ]
        case .stopLoss:
            candidates = [
                ("止损价格", ["止损价", "止损价格", "成交价", "平仓价"]),
                ("盈亏", ["盈亏", "收益", "收益率"]),
            ]
        case .strategyTakeProfit, .manualTakeProfit:
            candidates = [
                ("止盈价格", ["止盈价", "止盈价格", "成交价", "平仓价"]),
                ("收益", ["收益", "收益率", "盈亏"]),
            ]
        case .reduction:
            candidates = [
                ("减仓比例", ["减仓百分比", "减仓比例"]),
                ("减仓价格", ["减仓价", "减仓价格"]),
            ]
        }

        return candidates.compactMap { label, keys in
            guard let value = keys.lazy.compactMap({ fields[$0] }).first else {
                return nil
            }
            return SummaryDetail(label: label, value: value)
        }
    }
}
