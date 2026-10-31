import Foundation

enum ChartBuiltInIndicator: String, CaseIterable, Hashable, Sendable {
  case movingAverage = "MA"
  case ema = "EMA"
  case bollingerBands = "BOLL"
  case parabolicSAR = "SAR"
  case averagePrice = "AVL"
  case superTrend = "SUPER"
  case volume = "VOL"
  case macd = "MACD"
  case rsi = "RSI"
  case kdj = "KDJ"
  case obv = "OBV"
  case williamsR = "WR"
  case stochasticRSI = "StochRSI"
  case atr = "ATR"
  case openInterest = "O.I."
  case topAccountRatio = "L.S Acco."
  case topPositionRatio = "L.S Posit."
  case globalAccountRatio = "L.S Ratio"
  case buySellVolume = "B.S Vol."
  case basis = "Basis"

  var isPanelIndicator: Bool {
    switch self {
    case .movingAverage, .ema, .bollingerBands,
      .parabolicSAR, .averagePrice, .superTrend:
      return false
    case .volume, .macd, .rsi, .kdj, .obv,
      .williamsR, .stochasticRSI, .atr,
      .openInterest, .topAccountRatio,
      .topPositionRatio, .globalAccountRatio,
      .buySellVolume, .basis:
      return true
    }
  }
}

enum ChartTradingDataSeries: String, Hashable, Sendable {
  case openInterest
  case topAccountRatio
  case topPositionRatio
  case globalAccountRatio
  case buySellVolume
  case basis
}

struct ChartIndicatorSelection: Equatable, Sendable {
  private(set) var activeIndicators: Set<ChartBuiltInIndicator>
  private(set) var activeIndicatorsInOrder: [ChartBuiltInIndicator]

  static let standard = ChartIndicatorSelection(
    validatedIndicatorsInOrder: [
      .ema,
      .superTrend,
      .macd,
      .volume,
    ]
  )

  static let priceOverlays = ChartIndicatorSelection(
    validatedIndicatorsInOrder: [.ema, .superTrend]
  )

  static let allBuiltIn = ChartIndicatorSelection(
    validatedIndicatorsInOrder: ChartBuiltInIndicator.allCases
  )

  init?(activeIndicatorsInOrder: [ChartBuiltInIndicator]) {
    guard Set(activeIndicatorsInOrder).count == activeIndicatorsInOrder.count else {
      return nil
    }
    self.init(validatedIndicatorsInOrder: activeIndicatorsInOrder)
  }

  init?(persistedRawValues: [String]) {
    let indicators = persistedRawValues.compactMap(
      ChartBuiltInIndicator.init(rawValue:)
    )
    guard indicators.count == persistedRawValues.count else {
      return nil
    }
    self.init(activeIndicatorsInOrder: indicators)
  }

  func contains(_ indicator: ChartBuiltInIndicator) -> Bool {
    activeIndicators.contains(indicator)
  }

  func toggling(
    _ indicator: ChartBuiltInIndicator
  ) -> ChartIndicatorSelection {
    var next = activeIndicatorsInOrder
    if let index = next.firstIndex(of: indicator) {
      next.remove(at: index)
      return ChartIndicatorSelection(
        validatedIndicatorsInOrder: next
      )
    }
    next.append(indicator)
    return ChartIndicatorSelection(
      validatedIndicatorsInOrder: next
    )
  }

  var activePanelIndicatorsInOrder: [ChartBuiltInIndicator] {
    activeIndicatorsInOrder.filter(\.isPanelIndicator)
  }

  var persistedRawValues: [String] {
    activeIndicatorsInOrder.map(\.rawValue)
  }

  var requestedTradingDataSeries: [ChartTradingDataSeries] {
    activeIndicatorsInOrder.compactMap { indicator in
      switch indicator {
      case .openInterest:
        return .openInterest
      case .topAccountRatio:
        return .topAccountRatio
      case .topPositionRatio:
        return .topPositionRatio
      case .globalAccountRatio:
        return .globalAccountRatio
      case .buySellVolume:
        return .buySellVolume
      case .basis:
        return .basis
      default:
        return nil
      }
    }
  }

  private init(
    validatedIndicatorsInOrder: [ChartBuiltInIndicator]
  ) {
    activeIndicators = Set(validatedIndicatorsInOrder)
    activeIndicatorsInOrder = validatedIndicatorsInOrder
  }
}

struct ChartIndicatorSelectionStore {
  private let defaults: UserDefaults
  private let key: String

  init(
    defaults: UserDefaults = .standard,
    key: String = "chart.indicator-selection.v2"
  ) {
    self.defaults = defaults
    self.key = key
  }

  func load() -> ChartIndicatorSelection {
    guard let rawValues = defaults.stringArray(forKey: key),
      let selection = ChartIndicatorSelection(
        persistedRawValues: rawValues
      )
    else {
      return .standard
    }
    return selection
  }

  func applyLaunchOverrides(arguments: [String]) {
    if let flagIndex = arguments.firstIndex(
      of: "--chart-calibration-panel"
    ), arguments.indices.contains(flagIndex + 1),
      let indicator = ChartBuiltInIndicator(
        rawValue: arguments[flagIndex + 1]
      ), indicator.isPanelIndicator
    {
      let initial = ChartIndicatorSelection.standard
      save(initial.contains(indicator) ? initial : initial.toggling(indicator))
      return
    }
#if DEBUG
    if arguments.contains(
      "--chart-indicators-all"
    ) {
      save(.allBuiltIn)
    }
#endif
  }

  func save(_ selection: ChartIndicatorSelection) {
    defaults.set(
      selection.persistedRawValues,
      forKey: key
    )
  }
}
