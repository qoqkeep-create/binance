import Foundation

struct SignalNotificationPreferences: Codable, Equatable, Sendable {
    var fifteenMinuteEnabled: Bool
    var oneHourEnabled: Bool
    var fourHourEnabled: Bool

    static let allEnabled = SignalNotificationPreferences(
        fifteenMinuteEnabled: true,
        oneHourEnabled: true,
        fourHourEnabled: true
    )

    func allows(interval: String) -> Bool {
        switch interval {
        case "15m": fifteenMinuteEnabled
        case "1h": oneHourEnabled
        case "4h": fourHourEnabled
        default: false
        }
    }
}

struct StrategySignal: Identifiable, Codable, Hashable, Sendable {
    enum Direction: String, Codable, Sendable {
        case long = "LONG"
        case short = "SHORT"

        var title: String {
            switch self {
            case .long:
                return "做多"
            case .short:
                return "做空"
            }
        }
    }

    enum ReversalAlertState: String, Codable, Sendable {
        case none = "NONE"
        case active = "ACTIVE"
        case triggered = "TRIGGERED"
    }

    let id: UUID
    let symbol: String
    let interval: String
    let strategyName: String
    let direction: Direction
    let triggerPrice: Double
    let triggeredAt: Date
    var isRead: Bool = false
    var reversalAlertState: ReversalAlertState? = nil
    var reversalPatternName: String? = nil

    init(
        id: UUID,
        symbol: String,
        interval: String = MarketKlineInterval.oneHour.rawValue,
        strategyName: String,
        direction: Direction,
        triggerPrice: Double,
        triggeredAt: Date,
        isRead: Bool = false,
        reversalAlertState: ReversalAlertState? = nil,
        reversalPatternName: String? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.interval = interval
        self.strategyName = strategyName
        self.direction = direction
        self.triggerPrice = triggerPrice
        self.triggeredAt = triggeredAt
        self.isRead = isRead
        self.reversalAlertState = reversalAlertState
        self.reversalPatternName = reversalPatternName
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case symbol
        case interval
        case strategyName
        case direction
        case triggerPrice
        case triggeredAt
        case isRead
        case reversalAlertState
        case reversalPatternName
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        symbol = try values.decode(String.self, forKey: .symbol)
        interval = try values.decodeIfPresent(
            String.self,
            forKey: .interval
        ) ?? MarketKlineInterval.oneHour.rawValue
        strategyName = try values.decode(String.self, forKey: .strategyName)
        direction = try values.decode(Direction.self, forKey: .direction)
        triggerPrice = try values.decode(Double.self, forKey: .triggerPrice)
        triggeredAt = try values.decode(Date.self, forKey: .triggeredAt)
        isRead = try values.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        reversalAlertState = try values.decodeIfPresent(
            ReversalAlertState.self,
            forKey: .reversalAlertState
        )
        reversalPatternName = try values.decodeIfPresent(
            String.self,
            forKey: .reversalPatternName
        )
    }
}
