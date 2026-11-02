import SwiftUI
import UIKit

enum TradingOrderType: String, Codable, CaseIterable, Identifiable {
    case makerOnly = "MAKER_ONLY"
    case limit = "LIMIT"
    case market = "MARKET"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .makerOnly: "只做Maker"
        case .limit: "限价单"
        case .market: "市价单"
        }
    }
}

enum ChartOrderSide: Equatable {
    case long
    case short

    var title: String {
        switch self {
        case .long: "做多"
        case .short: "做空"
        }
    }

}

enum ChartOrderLineKind: Equatable {
    case entry
    case stopLoss
}

struct ChartOrderDrawingState: Equatable {
    let side: ChartOrderSide
    let entryOrderType: TradingOrderType
    let referencePrice: Double
    let riskAmount: Double
    var entryPrice: Double?
    var stopLossPrice: Double
    var allowsSideChange = false

    var inferredSide: ChartOrderSide {
        allowsSideChange ? (stopLossPrice < effectiveEntryPrice ? .long : .short) : side
    }

    static func make(
        side: ChartOrderSide,
        entryOrderType: TradingOrderType,
        referencePrice: Double,
        riskAmount: Double = 0
    ) -> ChartOrderDrawingState? {
        guard referencePrice.isFinite, referencePrice > 0 else {
            return nil
        }
        let direction = side == .long ? -1.0 : 1.0
        let entryPrice = entryOrderType == .market
            ? nil
            : referencePrice * (1 + direction * 0.004)
        let stopLossPrice = referencePrice * (1 + direction * 0.014)
        return ChartOrderDrawingState(
            side: side,
            entryOrderType: entryOrderType,
            referencePrice: referencePrice,
            riskAmount: riskAmount,
            entryPrice: entryPrice,
            stopLossPrice: stopLossPrice
        )
    }

    var entryLineTitle: String {
        switch entryOrderType {
        case .makerOnly: "Maker建仓"
        case .limit: "限价建仓"
        case .market: "市价建仓"
        }
    }

    var modeSummary: String {
        entryOrderType == .market
            ? "市价建仓 · 拖动止损线"
            : "\(entryLineTitle) · 拖动价格线"
    }

    var effectiveEntryPrice: Double {
        entryPrice ?? referencePrice
    }

    var stopDrawdownPercent: Double {
        guard effectiveEntryPrice.isFinite,
              effectiveEntryPrice > 0 else {
            return 0
        }
        return abs(effectiveEntryPrice - stopLossPrice)
            / effectiveEntryPrice * 100
    }

    var plannedPositionNotional: Double? {
        let distance = abs(effectiveEntryPrice - stopLossPrice)
        guard riskAmount.isFinite,
              riskAmount > 0,
              effectiveEntryPrice.isFinite,
              effectiveEntryPrice > 0,
              distance.isFinite,
              distance > 0 else {
            return nil
        }
        let value = riskAmount / distance * effectiveEntryPrice
        return value.isFinite && value > 0 ? value : nil
    }

    mutating func move(
        _ line: ChartOrderLineKind,
        to proposedPrice: Double,
        within range: ClosedRange<Double>
    ) {
        guard proposedPrice.isFinite,
              range.lowerBound.isFinite,
              range.upperBound.isFinite,
              range.upperBound > range.lowerBound else {
            return
        }
        let minimumGap = max(
            referencePrice * 0.0001,
            (range.upperBound - range.lowerBound) * 0.001
        )
        if allowsSideChange {
            let price = clamp(proposedPrice, range)
            if line == .entry, entryPrice != nil { entryPrice = price }
            if line == .stopLoss { stopLossPrice = price }
            return
        }

        switch line {
        case .entry:
            guard entryPrice != nil else { return }
            switch side {
            case .long:
                let lower = min(
                    range.upperBound,
                    max(range.lowerBound, stopLossPrice + minimumGap)
                )
                entryPrice = clamp(
                    proposedPrice,
                    lower...range.upperBound
                )
            case .short:
                let upper = max(
                    range.lowerBound,
                    min(range.upperBound, stopLossPrice - minimumGap)
                )
                entryPrice = clamp(
                    proposedPrice,
                    range.lowerBound...upper
                )
            }
        case .stopLoss:
            let entry = entryPrice ?? referencePrice
            switch side {
            case .long:
                let upper = max(
                    range.lowerBound,
                    min(range.upperBound, entry - minimumGap)
                )
                stopLossPrice = clamp(
                    proposedPrice,
                    range.lowerBound...upper
                )
            case .short:
                let lower = min(
                    range.upperBound,
                    max(range.lowerBound, entry + minimumGap)
                )
                stopLossPrice = clamp(
                    proposedPrice,
                    lower...range.upperBound
                )
            }
        }
    }

    private func clamp(
        _ value: Double,
        _ range: ClosedRange<Double>
    ) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

struct ChartPositionLine: Identifiable, Equatable {
    enum Kind: String { case entry, stopLoss, takeProfit }
    let id: String
    let kind: Kind
    let price: Decimal
    let title: String
    var detail: String = ""

    static func positions(in rows: [JSONValue], symbol: String) -> [JSONValue] {
        rows.filter { row in
            guard row.value("symbol", fallback: "").uppercased() == symbol.uppercased() else { return false }
            if let status = row["status"], status.text != "0" { return false }
            if let size = row["exchange_size"] ?? row["size"] {
                guard let amount = size.decimal, !amount.isNaN, amount != 0 else { return false }
            }
            return true
        }
    }

    static func lines(in rows: [JSONValue], symbol: String, currentPrice: Decimal? = nil) -> [Self] {
        let matching = positions(in: rows, symbol: symbol)
        return matching.enumerated().flatMap { index, row -> [Self] in
            let prefix = row.value("id", fallback: String(index)) + "." + row.value("side")
            let side = matching.count > 1 ? (row.value("side") == "0" ? "多 · " : "空 · ") : ""
            func valid(_ key: String) -> Decimal? {
                guard let value = row[key]?.decimal, !value.isNaN, value > 0 else { return nil }
                return value
            }
            func detail(_ kind: Kind) -> String {
                if kind == .entry {
                    guard let currentPrice,
                      let valuation = PositionLiveValuation(row: row, quote: PositionMarketQuote(price: currentPrice, eventTime: 0)) else { return "-" }
                    return (valuation.profit > 0 ? "+" : "") + DisplayNumber.text(valuation.profit) + " U"
                }
                if kind == .stopLoss {
                    return row["stop_loss_amount"]?.decimal.map { "-" + DisplayNumber.text(abs($0)) + " U" } ?? "-"
                }
                return row["manual_take_profit_price"]?.decimal.map { DisplayNumber.text($0) } ?? "-"
            }
            var result: [Self] = []
            func append(_ kind: Kind, _ price: Decimal?, _ title: String) {
                if let price { result.append(Self(id: prefix + "." + kind.rawValue,
                    kind: kind, price: price, title: side + title, detail: detail(kind))) }
            }
            append(.entry, valid("open_price"), "开仓")
            append(.stopLoss, row["market_stop_set"]?.flag == true
                ? valid("market_stop_price") ?? valid("stop_loss_price") : valid("stop_loss_price"), "止损")
            if row["manual_take_profit_set"]?.flag == true {
                append(.takeProfit, valid("manual_take_profit_price"), "止盈")
            }
            return result
        }
    }
}

struct ChartPositionLinesOverlay: View {
    let lines: [ChartPositionLine]
    let projection: ChartPriceProjection

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                ForEach(lines) { line in
                    let price = NSDecimalNumber(decimal: line.price).doubleValue
                    if let y = projection.screenY(for: price),
                       y >= projection.plotTop, y <= projection.plotBottom {
                        Path { path in
                            path.move(to: CGPoint(x: projection.plotLeft, y: y))
                            path.addLine(to: CGPoint(x: projection.plotRight, y: y))
                        }.stroke(color(line.kind), style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                        let label = ChartPriceLineLabelLayout(projection: projection, texts: lines.map { $0.title + " " + $0.detail })
                        ChartPriceLineLabel(title: line.title, price: line.detail,
                            color: color(line.kind), width: label.width)
                            .position(x: label.centerX, y: y)
                            .accessibilityIdentifier("position-line." + line.id)
                            .accessibilityLabel(line.title).accessibilityValue(DisplayNumber.text(line.price))
                    }
                }
            }
        }.clipped().allowsHitTesting(false)
    }

    private func color(_ kind: ChartPositionLine.Kind) -> Color {
        switch kind {
        case .entry: WebTheme.brand
        case .stopLoss: WebTheme.danger
        case .takeProfit: WebTheme.success
        }
    }
}

struct ChartPriceLineLabelLayout {
    let width: Double
    let centerX: Double

    init(projection: ChartPriceProjection, texts: [String], draggable: Bool = false) {
        let plotWidth = max(1, projection.plotRight - projection.plotLeft)
        let longest = texts.map { ($0 as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 10, weight: .medium)]).width }.max() ?? 0
        width = min(ceil(longest) + 14 + (draggable ? 16 : 0), max(1, plotWidth - 12))
        centerX = projection.plotLeft + 6 + width / 2
    }
}

private struct ChartPriceLineLabel: View {
    let title: String
    let price: String
    let color: Color
    let width: Double
    var draggable = false

    var body: some View {
        HStack(spacing: 5) {
            if draggable {
                Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .medium))
            }
            Text(title).layoutPriority(1)
            if !price.isEmpty { Text(price).monospacedDigit() }
        }.font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
            .foregroundStyle(color).padding(.horizontal, 7).frame(width: width, height: 24)
            .background(BinanceTheme.background.opacity(0.98), in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.8), lineWidth: 0.5) }
            .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(price)
    }
}

struct ChartOrderDrawingOverlay: View {
    @Binding var drawing: ChartOrderDrawingState
    let projection: ChartPriceProjection
    let formatPrice: (Double) -> String
    var showsSummary = true

    private let coordinateSpaceName = "chart-order-drawing-overlay"

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                riskArea

                if let entryPrice = drawing.entryPrice {
                    orderLine(
                        kind: .entry,
                        title: drawing.entryLineTitle,
                        price: entryPrice,
                        color: BinanceTheme.accentText
                    )
                }

                orderLine(
                    kind: .stopLoss,
                    title: "止损价",
                    price: drawing.stopLossPrice,
                    color: BinanceTheme.negative
                )

                if showsSummary { modeBadge }
            }
            .coordinateSpace(name: coordinateSpaceName)
        }
        .clipped()
    }

    @ViewBuilder
    private var riskArea: some View {
        if let entryY = projectedY(drawing.effectiveEntryPrice),
           let stopY = projectedY(drawing.stopLossPrice) {
            let top = min(entryY, stopY)
            let height = max(1, abs(stopY - entryY))
            Rectangle()
                .fill(BinanceTheme.negative.opacity(0.075))
                .frame(
                    width: projection.plotRight - projection.plotLeft,
                    height: height
                )
                .position(
                    x: (projection.plotLeft + projection.plotRight) / 2,
                    y: top + height / 2
                )
                .allowsHitTesting(false)
        }
    }

    private var modeBadge: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(drawing.inferredSide.title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(BinanceTheme.onColor)
                    .padding(.horizontal, 7)
                    .frame(height: 21)
                    .background(sideColor, in: Capsule())

                Text(drawing.modeSummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(BinanceTheme.primaryText)
            }

            HStack(spacing: 7) {
                Text("仓位 \(positionText) U")
                Rectangle()
                    .fill(BinanceTheme.border)
                    .frame(width: 0.5, height: 10)
                Text(
                    "止损回撤 "
                        + DisplayNumber.text(drawing.stopDrawdownPercent)
                        + "%"
                )
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(BinanceTheme.secondaryText)
            .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            BinanceTheme.surface.opacity(0.96),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(BinanceTheme.border.opacity(0.9), lineWidth: 0.7)
        }
        .padding(.leading, projection.plotLeft + 6)
        .padding(.top, projection.plotTop + 5)
        .allowsHitTesting(false)
    }

    private var positionText: String {
        drawing.plannedPositionNotional.map { DisplayNumber.text($0, grouped: true) } ?? "--"
    }

    private func orderLine(
        kind: ChartOrderLineKind,
        title: String,
        price: Double,
        color: Color
    ) -> some View {
        let plotWidth = projection.plotRight - projection.plotLeft
        let label = ChartPriceLineLabelLayout(projection: projection, texts: [drawing.entryLineTitle, "止损价"], draggable: true)
        let y = projectedY(price) ?? projection.plotTop
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 18))
                path.addLine(to: CGPoint(x: plotWidth, y: 18))
            }
            .stroke(
                color.opacity(0.95),
                style: StrokeStyle(
                    lineWidth: 0.5,
                    dash: kind == .entry ? [5, 3] : [3, 3]
                )
            )

            ChartPriceLineLabel(title: title, price: "", color: color,
                width: label.width, draggable: true)
                .position(x: label.centerX - projection.plotLeft, y: 18)
        }
        .frame(width: plotWidth, height: 36).clipped()
        .contentShape(Rectangle())
        .position(
            x: projection.plotLeft + plotWidth / 2,
            y: y
        )
        .highPriorityGesture(
            DragGesture(
                minimumDistance: 0,
                coordinateSpace: .named(coordinateSpaceName)
            )
            .onChanged { value in
                guard let price = projection.price(
                    atScreenY: Double(value.location.y)
                ) else {
                    return
                }
                drawing.move(
                    kind,
                    to: price,
                    within: projection.priceRange
                )
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(kind == .entry ? "chart-order-line.entry" : "chart-order-line.stopLoss")
        .accessibilityLabel("\(title)价格线")
        .accessibilityValue(formatPrice(price))
        .accessibilityHint("上下拖动调整价格")
    }

    private var sideColor: Color {
        drawing.inferredSide == .long
            ? BinanceTheme.positive
            : BinanceTheme.negative
    }

    private func projectedY(_ price: Double) -> Double? {
        guard let y = projection.screenY(for: price) else {
            return nil
        }
        return min(projection.plotBottom, max(projection.plotTop, y))
    }
}
