import Foundation

struct MarketSnapshot: Identifiable, Codable, Hashable, Sendable {
    let symbol: String
    let quoteAsset: String
    let name: String
    var price: Double
    var turnoverText: String
    var quoteVolume24h: Double
    var changePercent24h: Double
    var updatedAt: Date
    var isPinned: Bool
    var isVisible: Bool

    var id: String { symbol }
    var isPositive: Bool { changePercent24h >= 0 }

    var baseAsset: String {
        guard !quoteAsset.isEmpty,
              symbol.uppercased().hasSuffix(quoteAsset.uppercased()) else {
            return symbol
        }
        return String(symbol.dropLast(quoteAsset.count))
    }

    var detailText: String {
        turnoverText.isEmpty ? name : "\(name) | \(turnoverText)"
    }

    var formattedPrice: String {
        if price >= 100 {
            return String(format: "%.2f", price)
        }

        if price >= 1 {
            return String(format: "%.3f", price)
        }

        if price >= 0.1 {
            return String(format: "%.4f", price)
        }

        return String(format: "%.5f", price)
    }

    var formattedChange: String {
        String(format: "%+.2f%%", changePercent24h)
    }

    init(
        symbol: String,
        quoteAsset: String,
        name: String = "USD-M",
        price: Double,
        turnoverText: String = "",
        quoteVolume24h: Double = 0,
        changePercent24h: Double,
        updatedAt: Date,
        isPinned: Bool = false,
        isVisible: Bool = true
    ) {
        self.symbol = symbol
        self.quoteAsset = quoteAsset
        self.name = name
        self.price = price
        self.turnoverText = turnoverText
        self.quoteVolume24h = quoteVolume24h
        self.changePercent24h = changePercent24h
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isVisible = isVisible
    }
}
