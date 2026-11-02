import Foundation

enum ChartIndicatorPlacement: Equatable, Sendable {
  case priceOverlay
  case panel(String)
}

enum ChartIndicatorYAxisPolicy: Equatable, Sendable {
  case sharedPrice
  case automatic
  case fixed(lower: Double, upper: Double)
}

enum ChartIndicatorAutoscalePolicy: Equatable, Sendable {
  case excluded
  case included
}

enum ChartIndicatorHistogramColorStrategy: Equatable, Sendable {
  case fixed
  case valueSign
  case candleDirection
}

enum ChartIndicatorHistogramPosition: Equatable, Sendable {
  case leading
  case trailing
}

enum ChartIndicatorFigureStyle: Equatable, Sendable {
  case line
  case lineWithCandleCloseBand(fillAlpha: Float)
  case hollowSquareMarker(sizePoints: Float)
  case histogramFromZero(
    colorStrategy: ChartIndicatorHistogramColorStrategy
  )
  case pairedHistogramFromZero(
    colorStrategy: ChartIndicatorHistogramColorStrategy,
    position: ChartIndicatorHistogramPosition
  )
  case areaFromZero(fillAlpha: Float)
}

enum ChartIndicatorColorToken: String, Equatable, Sendable {
  case neutral
  case positive
  case negative
  case ema21
  case ema55
  case ema144
  case emaShort
  case emaMedium
  case emaLong
  case macdHistogram
  case orange

  var color: ChartColor {
    switch self {
    case .neutral:
      return .neutral
    case .positive:
      return .positive
    case .negative:
      return .negative
    case .ema21:
      return .ema21
    case .ema55:
      return .ema55
    case .ema144:
      return .ema144
    case .emaShort:
      return .emaShort
    case .emaMedium:
      return .emaMedium
    case .emaLong:
      return .emaLong
    case .macdHistogram:
      return .neutral
    case .orange:
      return .orange
    }
  }
}

struct ChartIndicatorParameterDescriptor: Equatable, Sendable {
  let id: String
  let displayName: String
  let defaultValue: Double
  let range: ClosedRange<Double>
  let step: Double

  var isValid: Bool {
    !id.isEmpty
      && !displayName.isEmpty
      && defaultValue.isFinite
      && range.lowerBound.isFinite
      && range.upperBound.isFinite
      && range.contains(defaultValue)
      && step.isFinite
      && step > 0
  }
}

struct ChartIndicatorOutputDescriptor: Equatable, Sendable {
  let id: String
  let displayName: String
  let colorToken: ChartIndicatorColorToken
  let lineWidthPoints: Float
  let autoscale: ChartIndicatorAutoscalePolicy
  let figureStyle: ChartIndicatorFigureStyle

  init(
    id: String,
    displayName: String,
    colorToken: ChartIndicatorColorToken,
    lineWidthPoints: Float,
    autoscale: ChartIndicatorAutoscalePolicy,
    figureStyle: ChartIndicatorFigureStyle = .line
  ) {
    self.id = id
    self.displayName = displayName
    self.colorToken = colorToken
    self.lineWidthPoints = lineWidthPoints
    self.autoscale = autoscale
    self.figureStyle = figureStyle
  }

  var isValid: Bool {
    let validFigureStyle: Bool
    switch figureStyle {
    case .line, .histogramFromZero,
      .pairedHistogramFromZero:
      validFigureStyle = true
    case .lineWithCandleCloseBand(let fillAlpha):
      validFigureStyle = fillAlpha.isFinite
        && fillAlpha > 0
        && fillAlpha <= 1
    case .hollowSquareMarker(let sizePoints):
      validFigureStyle = sizePoints.isFinite
        && sizePoints > 0
    case .areaFromZero(let fillAlpha):
      validFigureStyle = fillAlpha.isFinite
        && fillAlpha > 0
        && fillAlpha <= 1
    }
    return !id.isEmpty
      && !displayName.isEmpty
      && lineWidthPoints.isFinite
      && lineWidthPoints > 0
      && validFigureStyle
  }
}

struct ChartIndicatorDescriptor: Equatable, Sendable {
  let id: String
  let displayName: String
  let definitionVersion: Int
  let placement: ChartIndicatorPlacement
  let parameters: [ChartIndicatorParameterDescriptor]
  let outputs: [ChartIndicatorOutputDescriptor]
  let warmupCount: Int
  let yAxisPolicy: ChartIndicatorYAxisPolicy
  let allowsMultipleInstances: Bool

  var isValid: Bool {
    guard !id.isEmpty,
      !displayName.isEmpty,
      definitionVersion > 0,
      warmupCount >= 0,
      !outputs.isEmpty,
      parameters.allSatisfy(\.isValid),
      outputs.allSatisfy(\.isValid)
    else {
      return false
    }
    return Set(parameters.map(\.id)).count == parameters.count
      && Set(outputs.map(\.id)).count == outputs.count
  }
}

struct ChartIndicatorInstanceConfiguration: Sendable {
  let instanceID: String
  let pluginID: String
  let parameters: [String: Double]
  let outputColorOverrides: [String: ChartIndicatorColorToken]
  let legendLabel: String
  let legendLabelColorToken: ChartIndicatorColorToken?
  let legendRow: Int
  let legendOrder: Int

  init?(
    instanceID: String,
    pluginID: String,
    parameters: [String: Double],
    outputColorOverrides: [String: ChartIndicatorColorToken] = [:],
    legendLabel: String,
    legendLabelColorToken: ChartIndicatorColorToken? = nil,
    legendRow: Int,
    legendOrder: Int
  ) {
    guard !instanceID.isEmpty,
      !pluginID.isEmpty,
      !legendLabel.isEmpty,
      legendRow >= 0,
      parameters.values.allSatisfy(\.isFinite)
    else {
      return nil
    }
    self.instanceID = instanceID
    self.pluginID = pluginID
    self.parameters = parameters
    self.outputColorOverrides = outputColorOverrides
    self.legendLabel = legendLabel
    self.legendLabelColorToken = legendLabelColorToken
    self.legendRow = legendRow
    self.legendOrder = legendOrder
  }
}

struct ChartIndicatorSeriesKey: Hashable, Sendable {
  let instanceID: String
  let outputID: String
}

struct ChartIndicatorSeriesHistory: Sendable {
  let key: ChartIndicatorSeriesKey
  let points: [IndicatorPoint]
  let placement: ChartIndicatorPlacement
  let yAxisPolicy: ChartIndicatorYAxisPolicy
  let colorToken: ChartIndicatorColorToken
  let lineWidthPoints: Float
  let autoscale: ChartIndicatorAutoscalePolicy
  let figureStyle: ChartIndicatorFigureStyle
}

final class ChartIndicatorHistorySnapshot: @unchecked Sendable {
  let series: [ChartIndicatorSeriesHistory]

  init(series: [ChartIndicatorSeriesHistory]) {
    self.series = series
  }
}

struct ChartIndicatorLivePoint: Sendable {
  let key: ChartIndicatorSeriesKey
  let point: IndicatorPoint
}

struct ChartIndicatorLegendEntry: Sendable {
  let instanceID: String
  let label: String
  let value: Double?
  let labelColorToken: ChartIndicatorColorToken
  let colorToken: ChartIndicatorColorToken
  let placement: ChartIndicatorPlacement
  let row: Int
  let order: Int
}

struct ChartIndicatorLegendComponent: Sendable {
  let id: String
  let label: String
  let value: Double?
  let labelColorToken: ChartIndicatorColorToken
  let colorToken: ChartIndicatorColorToken
  let order: Int
}

struct ChartIndicatorSnapshot: Sendable {
  let history: ChartIndicatorHistorySnapshot
  let livePoints: [ChartIndicatorLivePoint]
  let legends: [ChartIndicatorLegendEntry]
}

struct ChartIndicatorPluginComputation: Sendable {
  let points: [String: IndicatorPoint]
  let legendValue: Double?
  let legendColorToken: ChartIndicatorColorToken?
  let legendComponents: [ChartIndicatorLegendComponent]

  init(
    points: [String: IndicatorPoint],
    legendValue: Double?,
    legendColorToken: ChartIndicatorColorToken?,
    legendComponents: [ChartIndicatorLegendComponent] = []
  ) {
    self.points = points
    self.legendValue = legendValue
    self.legendColorToken = legendColorToken
    self.legendComponents = legendComponents
  }
}

protocol ChartIndicatorCalculator: Sendable {
  var lastCommittedOpenTime: Int64? { get }

  mutating func commit(
    _ candle: ChartCandle
  ) -> ChartIndicatorPluginComputation

  func provisional(
    _ candle: ChartCandle?
  ) -> ChartIndicatorPluginComputation
}

protocol ChartIndicatorPlugin: Sendable {
  var descriptor: ChartIndicatorDescriptor { get }

  func makeCalculator(
    configuration: ChartIndicatorInstanceConfiguration,
    intervalMilliseconds: Int64
  ) -> (any ChartIndicatorCalculator)?
}

struct ChartIndicatorRegistry: Sendable {
  private let plugins: [String: any ChartIndicatorPlugin]

  init?(_ plugins: [any ChartIndicatorPlugin]) {
    var registered: [String: any ChartIndicatorPlugin] = [:]
    for plugin in plugins {
      let descriptor = plugin.descriptor
      guard descriptor.isValid,
        registered[descriptor.id] == nil
      else {
        return nil
      }
      registered[descriptor.id] = plugin
    }
    self.plugins = registered
  }

  var descriptors: [ChartIndicatorDescriptor] {
    plugins.values
      .map(\.descriptor)
      .sorted { $0.id < $1.id }
  }

  func plugin(
    id: String
  ) -> (any ChartIndicatorPlugin)? {
    plugins[id]
  }

  static var standard: ChartIndicatorRegistry? {
    ChartIndicatorRegistry([
      SimpleMovingAverageChartIndicatorPlugin(),
      EMAChartIndicatorPlugin(),
      BollingerBandsChartIndicatorPlugin(),
      ParabolicSARChartIndicatorPlugin(),
      AveragePriceChartIndicatorPlugin(),
      SuperTrendChartIndicatorPlugin(),
      VolumeChartIndicatorPlugin(),
      MACDChartIndicatorPlugin(),
      RSIChartIndicatorPlugin(),
      TechnicalPanelChartIndicatorPlugin(kind: .kdj),
      TechnicalPanelChartIndicatorPlugin(kind: .obv),
      TechnicalPanelChartIndicatorPlugin(kind: .williamsR),
      TechnicalPanelChartIndicatorPlugin(kind: .stochasticRSI),
      TechnicalPanelChartIndicatorPlugin(kind: .atr),
      TradingDataPanelChartIndicatorPlugin(kind: .openInterest),
      TradingDataPanelChartIndicatorPlugin(kind: .topAccountRatio),
      TradingDataPanelChartIndicatorPlugin(kind: .topPositionRatio),
      TradingDataPanelChartIndicatorPlugin(kind: .globalAccountRatio),
      TradingDataPanelChartIndicatorPlugin(kind: .buySellVolume),
      TradingDataPanelChartIndicatorPlugin(kind: .basis),
    ])
  }
}

struct ChartIndicatorProductDefinition: Sendable {
  let indicator: ChartBuiltInIndicator
  let configurations:
    @Sendable (ChartIndicatorParameters)
      -> [ChartIndicatorInstanceConfiguration]?
}

enum ChartIndicatorProductCatalog {
  static let standard: [ChartIndicatorProductDefinition] = [
    ChartIndicatorProductDefinition(
      indicator: .movingAverage,
      configurations: { movingAverageConfigurations($0) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .ema,
      configurations: { emaConfigurations($0) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .bollingerBands,
      configurations: { bollingerBandsConfigurations($0) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .parabolicSAR,
      configurations: { parabolicSARConfigurations($0) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .averagePrice,
      configurations: { averagePriceConfigurations($0) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .superTrend,
      configurations: { superTrendConfigurations($0) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .volume,
      configurations: { volumeConfigurations($0) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .macd,
      configurations: { macdConfigurations($0) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .rsi,
      configurations: { rsiConfigurations($0) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .kdj,
      configurations: { kdjConfigurations($0) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .obv,
      configurations: { _ in fixedConfiguration(
        instanceID: "obv",
        pluginID: "obv",
        legendLabel: "OBV:"
      ) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .williamsR,
      configurations: { williamsRConfigurations($0) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .stochasticRSI,
      configurations: { stochasticRSIConfigurations($0) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .atr,
      configurations: { atrConfigurations($0) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .openInterest,
      configurations: { _ in fixedConfiguration(
        instanceID: "open-interest",
        pluginID: "open-interest",
        legendLabel: "O.I.:"
      ) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .topAccountRatio,
      configurations: { _ in fixedConfiguration(
        instanceID: "top-account-ratio",
        pluginID: "top-account-ratio",
        legendLabel: "L.S Acco.:"
      ) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .topPositionRatio,
      configurations: { _ in fixedConfiguration(
        instanceID: "top-position-ratio",
        pluginID: "top-position-ratio",
        legendLabel: "L.S Posit.:"
      ) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .globalAccountRatio,
      configurations: { _ in fixedConfiguration(
        instanceID: "global-account-ratio",
        pluginID: "global-account-ratio",
        legendLabel: "L.S Ratio:"
      ) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .buySellVolume,
      configurations: { _ in fixedConfiguration(
        instanceID: "buy-sell-volume",
        pluginID: "buy-sell-volume",
        legendLabel: "B.S Vol.:"
      ) }
    ),
    ChartIndicatorProductDefinition(
      indicator: .basis,
      configurations: { _ in fixedConfiguration(
        instanceID: "basis",
        pluginID: "basis",
        legendLabel: "Basis:"
      ) }
    ),
  ]

  static func configurations(
    selection: ChartIndicatorSelection,
    parameters: ChartIndicatorParameters
  ) -> [ChartIndicatorInstanceConfiguration]? {
    var result: [ChartIndicatorInstanceConfiguration] = []
    let overlayDefinitions = standard.filter {
      !$0.indicator.isPanelIndicator
        && selection.contains($0.indicator)
    }
    let panelDefinitions = selection
      .activePanelIndicatorsInOrder
      .compactMap { indicator in
        standard.first { $0.indicator == indicator }
      }
    for (row, definition) in overlayDefinitions.enumerated() {
      guard let configurations = definition.configurations(
        parameters
      ) else {
        return nil
      }
      let rowConfigurations = configurations.compactMap {
        configuration in
        ChartIndicatorInstanceConfiguration(
          instanceID: configuration.instanceID,
          pluginID: configuration.pluginID,
          parameters: configuration.parameters,
          outputColorOverrides:
            configuration.outputColorOverrides,
          legendLabel: configuration.legendLabel,
          legendLabelColorToken:
            configuration.legendLabelColorToken,
          legendRow: row,
          legendOrder: configuration.legendOrder
        )
      }
      guard rowConfigurations.count == configurations.count else {
        return nil
      }
      result.append(contentsOf: rowConfigurations)
    }
    for definition in panelDefinitions {
      guard let configurations = definition.configurations(
        parameters
      ) else {
        return nil
      }
      result.append(contentsOf: configurations)
    }
    return result
  }

  private static func movingAverageConfigurations(
    _ parameters: ChartIndicatorParameters
  ) -> [ChartIndicatorInstanceConfiguration]? {
    let colors: [ChartIndicatorColorToken] = [
      .ema21,
      .ema55,
      .ema144,
    ]
    let configurations = zip(
      parameters.movingAveragePeriods,
      colors
    ).enumerated().compactMap { index, entry in
      let (period, color) = entry
      return ChartIndicatorInstanceConfiguration(
        instanceID: "sma.\(period)",
        pluginID: "sma",
        parameters: ["period": Double(period)],
        outputColorOverrides: ["value": color],
        legendLabel: "MA(\(period)):",
        legendRow: 0,
        legendOrder: index
      )
    }
    return configurations.count
      == parameters.movingAveragePeriods.count
      ? configurations
      : nil
  }

  private static func superTrendConfigurations(
    _ parameters: ChartIndicatorParameters
  ) -> [ChartIndicatorInstanceConfiguration]? {
    guard let configuration = ChartIndicatorInstanceConfiguration(
      instanceID:
        "supertrend.\(parameters.superTrendATRPeriod)."
        + parameters.superTrendMultiplierText,
      pluginID: "supertrend",
      parameters: [
        "atrPeriod": Double(parameters.superTrendATRPeriod),
        "multiplier": parameters.superTrendMultiplier,
      ],
      legendLabel:
        "SUPERTREND(\(parameters.superTrendATRPeriod),"
        + "\(DisplayNumber.text(parameters.superTrendMultiplier)))",
      legendLabelColorToken: .neutral,
      legendRow: 1,
      legendOrder: 0
    ) else {
      return nil
    }
    return [configuration]
  }

  private static func emaConfigurations(
    _ parameters: ChartIndicatorParameters
  ) -> [ChartIndicatorInstanceConfiguration]? {
    let colors: [ChartIndicatorColorToken] = [
      .emaShort,
      .emaMedium,
      .emaLong,
    ]
    let configurations = zip(
      parameters.emaPeriods,
      colors
    ).enumerated().compactMap { index, entry in
      let (period, color) = entry
      return ChartIndicatorInstanceConfiguration(
        instanceID: "ema.\(period)",
        pluginID: "ema",
        parameters: ["period": Double(period)],
        outputColorOverrides: ["value": color],
        legendLabel: "EMA(\(period)):",
        legendRow: 0,
        legendOrder: index
      )
    }
    return configurations.count == parameters.emaPeriods.count
      ? configurations
      : nil
  }

  private static func bollingerBandsConfigurations(
    _ parameters: ChartIndicatorParameters
  ) -> [ChartIndicatorInstanceConfiguration]? {
    guard let configuration = ChartIndicatorInstanceConfiguration(
      instanceID:
        "bollinger.\(parameters.bollingerPeriod)."
        + parameters.bollingerMultiplierText,
      pluginID: "bollinger",
      parameters: [
        "period": Double(parameters.bollingerPeriod),
        "multiplier": parameters.bollingerMultiplier,
      ],
      legendLabel:
        "BOLL:(\(parameters.bollingerPeriod), "
        + "\(DisplayNumber.text(parameters.bollingerMultiplier)))",
      legendRow: 0,
      legendOrder: 0
    ) else {
      return nil
    }
    return [configuration]
  }

  private static func parabolicSARConfigurations(
    _ parameters: ChartIndicatorParameters
  ) -> [ChartIndicatorInstanceConfiguration]? {
    guard let configuration = ChartIndicatorInstanceConfiguration(
      instanceID:
        "parabolic-sar.\(parameters.parabolicSARStartText)."
        + parameters.parabolicSARMaximumText,
      pluginID: "parabolic-sar",
      parameters: [
        "start": parameters.parabolicSARStart,
        "maximum": parameters.parabolicSARMaximum,
      ],
      legendLabel:
        "SAR(\(DisplayNumber.text(parameters.parabolicSARStart)), "
        + "\(DisplayNumber.text(parameters.parabolicSARMaximum))):",
      legendRow: 0,
      legendOrder: 0
    ) else {
      return nil
    }
    return [configuration]
  }

  private static func averagePriceConfigurations(
    _ parameters: ChartIndicatorParameters
  ) -> [ChartIndicatorInstanceConfiguration]? {
    guard let configuration = ChartIndicatorInstanceConfiguration(
      instanceID: "average-price",
      pluginID: "average-price",
      parameters: [:],
      legendLabel: "AVL",
      legendRow: 0,
      legendOrder: 0
    ) else {
      return nil
    }
    return [configuration]
  }

  private static func volumeConfigurations(
    _ parameters: ChartIndicatorParameters
  ) -> [ChartIndicatorInstanceConfiguration]? {
    guard let configuration = ChartIndicatorInstanceConfiguration(
      instanceID:
        "volume.\(parameters.volumeFastPeriod)."
        + "\(parameters.volumeSlowPeriod)",
      pluginID: "volume",
      parameters: [
        "fastPeriod": Double(parameters.volumeFastPeriod),
        "slowPeriod": Double(parameters.volumeSlowPeriod),
      ],
      legendLabel: "VOL:",
      legendLabelColorToken: .neutral,
      legendRow: 0,
      legendOrder: 0
    ) else {
      return nil
    }
    return [configuration]
  }

  private static func macdConfigurations(
    _ parameters: ChartIndicatorParameters
  ) -> [ChartIndicatorInstanceConfiguration]? {
    guard let configuration = ChartIndicatorInstanceConfiguration(
      instanceID:
        "macd.\(parameters.macdFastPeriod)."
        + "\(parameters.macdSlowPeriod)."
        + "\(parameters.macdSignalPeriod)",
      pluginID: "macd",
      parameters: [
        "fastPeriod": Double(parameters.macdFastPeriod),
        "slowPeriod": Double(parameters.macdSlowPeriod),
        "signalPeriod": Double(parameters.macdSignalPeriod),
      ],
      legendLabel:
        "MACD(\(parameters.macdFastPeriod),"
        + "\(parameters.macdSlowPeriod),"
        + "\(parameters.macdSignalPeriod)):",
      legendLabelColorToken: .neutral,
      legendRow: 0,
      legendOrder: 0
    ) else {
      return nil
    }
    return [configuration]
  }

  private static func rsiConfigurations(
    _ parameters: ChartIndicatorParameters
  ) -> [ChartIndicatorInstanceConfiguration]? {
    guard let configuration = ChartIndicatorInstanceConfiguration(
      instanceID: "rsi.\(parameters.rsiPeriod)",
      pluginID: "rsi",
      parameters: ["period": Double(parameters.rsiPeriod)],
      legendLabel: "RSI(\(parameters.rsiPeriod)):",
      legendLabelColorToken: .neutral,
      legendRow: 0,
      legendOrder: 0
    ) else {
      return nil
    }
    return [configuration]
  }

  private static func kdjConfigurations(
    _ parameters: ChartIndicatorParameters
  ) -> [ChartIndicatorInstanceConfiguration]? {
    guard let configuration = ChartIndicatorInstanceConfiguration(
      instanceID:
        "kdj.\(parameters.kdjPeriod)."
        + "\(parameters.kdjKSmoothing)."
        + "\(parameters.kdjDSmoothing)",
      pluginID: "kdj",
      parameters: [
        "period": Double(parameters.kdjPeriod),
        "kSmoothing": Double(parameters.kdjKSmoothing),
        "dSmoothing": Double(parameters.kdjDSmoothing),
      ],
      legendLabel: "KDJ:",
      legendRow: 0,
      legendOrder: 0
    ) else {
      return nil
    }
    return [configuration]
  }

  private static func williamsRConfigurations(
    _ parameters: ChartIndicatorParameters
  ) -> [ChartIndicatorInstanceConfiguration]? {
    guard let configuration = ChartIndicatorInstanceConfiguration(
      instanceID: "williams-r.\(parameters.williamsRPeriod)",
      pluginID: "williams-r",
      parameters: ["period": Double(parameters.williamsRPeriod)],
      legendLabel: "WR(\(parameters.williamsRPeriod)):",
      legendRow: 0,
      legendOrder: 0
    ) else {
      return nil
    }
    return [configuration]
  }

  private static func stochasticRSIConfigurations(
    _ parameters: ChartIndicatorParameters
  ) -> [ChartIndicatorInstanceConfiguration]? {
    guard let configuration = ChartIndicatorInstanceConfiguration(
      instanceID:
        "stochastic-rsi.\(parameters.stochasticRSIPeriod)."
        + "\(parameters.stochasticRSIWindow)."
        + "\(parameters.stochasticRSIKSmoothing)."
        + "\(parameters.stochasticRSIDSmoothing)",
      pluginID: "stochastic-rsi",
      parameters: [
        "rsiPeriod": Double(parameters.stochasticRSIPeriod),
        "window": Double(parameters.stochasticRSIWindow),
        "kSmoothing": Double(parameters.stochasticRSIKSmoothing),
        "dSmoothing": Double(parameters.stochasticRSIDSmoothing),
      ],
      legendLabel: "StochRSI:",
      legendRow: 0,
      legendOrder: 0
    ) else {
      return nil
    }
    return [configuration]
  }

  private static func atrConfigurations(
    _ parameters: ChartIndicatorParameters
  ) -> [ChartIndicatorInstanceConfiguration]? {
    guard let configuration = ChartIndicatorInstanceConfiguration(
      instanceID: "atr.\(parameters.atrPeriod)",
      pluginID: "atr",
      parameters: ["period": Double(parameters.atrPeriod)],
      legendLabel: "ATR(\(parameters.atrPeriod)):",
      legendRow: 0,
      legendOrder: 0
    ) else {
      return nil
    }
    return [configuration]
  }

  private static func fixedConfiguration(
    instanceID: String,
    pluginID: String,
    legendLabel: String
  ) -> [ChartIndicatorInstanceConfiguration]? {
    guard let configuration = ChartIndicatorInstanceConfiguration(
      instanceID: instanceID,
      pluginID: pluginID,
      parameters: [:],
      legendLabel: legendLabel,
      legendRow: 0,
      legendOrder: 0
    ) else {
      return nil
    }
    return [configuration]
  }
}

struct ChartIndicatorCommitHealth: Sendable {
  let requiresRecovery: Bool
}

struct ChartIndicatorEngine: Sendable {
  private struct Entry: Sendable {
    let configuration: ChartIndicatorInstanceConfiguration
    let descriptor: ChartIndicatorDescriptor
    var calculator: any ChartIndicatorCalculator
    var histories: [String: [IndicatorPoint]]
    var lastComputation: ChartIndicatorPluginComputation?
  }

  private let historyLimit: Int
  private var entries: [Entry]
  private(set) var history: ChartIndicatorHistorySnapshot

  init?(
    registry: ChartIndicatorRegistry,
    configurations: [ChartIndicatorInstanceConfiguration],
    intervalMilliseconds: Int64,
    historyLimit: Int
  ) {
    guard intervalMilliseconds > 0,
      historyLimit > 0,
      Set(configurations.map(\.instanceID)).count
        == configurations.count
    else {
      return nil
    }

    var entries: [Entry] = []
    entries.reserveCapacity(configurations.count)
    var pluginInstanceCounts: [String: Int] = [:]

    for configuration in configurations {
      guard
        let plugin = registry.plugin(
          id: configuration.pluginID
        )
      else {
        return nil
      }
      let descriptor = plugin.descriptor
      let count = pluginInstanceCounts[descriptor.id, default: 0]
      guard descriptor.allowsMultipleInstances || count == 0,
        Self.validate(configuration, against: descriptor),
        let calculator = plugin.makeCalculator(
          configuration: configuration,
          intervalMilliseconds: intervalMilliseconds
        )
      else {
        return nil
      }
      pluginInstanceCounts[descriptor.id] = count + 1
      entries.append(
        Entry(
          configuration: configuration,
          descriptor: descriptor,
          calculator: calculator,
          histories: Dictionary(
            uniqueKeysWithValues: descriptor.outputs.map {
              ($0.id, [])
            }
          ),
          lastComputation: nil
        ))
    }

    self.historyLimit = historyLimit
    self.entries = entries
    history = ChartIndicatorHistorySnapshot(series: [])
    history = makeHistorySnapshot()
  }

  var lastCommittedOpenTime: Int64? {
    entries.first?.calculator.lastCommittedOpenTime
  }

  mutating func installHistory(
    _ candles: [ChartCandle]
  ) -> ChartIndicatorCommitHealth {
    var requiresRecovery = false
    for candle in candles {
      requiresRecovery =
        apply(candle).requiresRecovery
        || requiresRecovery
    }
    publishHistory()
    return ChartIndicatorCommitHealth(
      requiresRecovery: requiresRecovery
    )
  }

  mutating func commit(
    _ candle: ChartCandle
  ) -> ChartIndicatorCommitHealth {
    let health = apply(candle)
    publishHistory()
    return health
  }

  func snapshot(
    provisional candle: ChartCandle?
  ) -> ChartIndicatorSnapshot {
    var livePoints: [ChartIndicatorLivePoint] = []
    var legends: [ChartIndicatorLegendEntry] = []

    for entry in entries {
      let computation: ChartIndicatorPluginComputation?
      if candle != nil {
        computation = entry.calculator.provisional(candle)
      } else {
        computation = entry.lastComputation
      }
      guard let computation else {
        continue
      }

      if candle != nil {
        for output in entry.descriptor.outputs {
          if let point = computation.points[output.id] {
            livePoints.append(
              ChartIndicatorLivePoint(
                key: ChartIndicatorSeriesKey(
                  instanceID: entry.configuration.instanceID,
                  outputID: output.id
                ),
                point: point
              ))
          }
        }
      }

      let defaultColor =
        entry.descriptor.outputs.first.map {
          Self.resolvedColor(
            for: $0,
            configuration: entry.configuration
          )
        } ?? .neutral
      if computation.legendComponents.isEmpty {
        legends.append(
          ChartIndicatorLegendEntry(
            instanceID: entry.configuration.instanceID,
            label: entry.configuration.legendLabel,
            value: computation.legendValue,
            labelColorToken:
              entry.configuration.legendLabelColorToken
              ?? computation.legendColorToken
              ?? defaultColor,
            colorToken: computation.legendColorToken
              ?? defaultColor,
            placement: entry.descriptor.placement,
            row: entry.configuration.legendRow,
            order: entry.configuration.legendOrder
          ))
      } else {
        for component in computation.legendComponents {
          legends.append(
            ChartIndicatorLegendEntry(
              instanceID:
                "\(entry.configuration.instanceID).\(component.id)",
              label: component.label,
              value: component.value,
              labelColorToken: component.labelColorToken,
              colorToken: component.colorToken,
              placement: entry.descriptor.placement,
              row: entry.configuration.legendRow,
              order:
                entry.configuration.legendOrder * 10
                + component.order
            ))
        }
      }
    }

    legends.sort {
      if $0.row != $1.row {
        return $0.row < $1.row
      }
      return $0.order < $1.order
    }
    return ChartIndicatorSnapshot(
      history: history,
      livePoints: livePoints,
      legends: legends
    )
  }

  static func productionConfigurations(
    selection: ChartIndicatorSelection = .standard,
    parameters: ChartIndicatorParameters = .standard
  )
    -> [ChartIndicatorInstanceConfiguration]?
  {
    ChartIndicatorProductCatalog.configurations(
      selection: selection,
      parameters: parameters
    )
  }

  static func productionPriceOverlayConfigurations()
    -> [ChartIndicatorInstanceConfiguration]?
  {
    productionConfigurations(
      selection: .priceOverlays,
      parameters: .standard
    )
  }

  private mutating func apply(
    _ candle: ChartCandle
  ) -> ChartIndicatorCommitHealth {
    var requiresRecovery = false

    for index in entries.indices {
      var entry = entries[index]
      let computation = entry.calculator.commit(candle)

      for output in entry.descriptor.outputs {
        let point =
          computation.points[output.id]
          ?? IndicatorPoint(
            openTime: candle.openTime,
            value: nil,
            validity: .invalid
          )
        var points = entry.histories[output.id] ?? []
        points.append(point)
        if points.count > historyLimit {
          points.removeFirst(points.count - historyLimit)
        }
        entry.histories[output.id] = points
        if point.validity == .dataGap
          || point.validity == .invalid
        {
          requiresRecovery = true
        }
      }

      entry.lastComputation = computation
      entries[index] = entry
    }

    return ChartIndicatorCommitHealth(
      requiresRecovery: requiresRecovery
    )
  }

  private mutating func publishHistory() {
    history = makeHistorySnapshot()
  }

  private func makeHistorySnapshot()
    -> ChartIndicatorHistorySnapshot
  {
    var series: [ChartIndicatorSeriesHistory] = []
    for entry in entries {
      for output in entry.descriptor.outputs {
        series.append(
          ChartIndicatorSeriesHistory(
            key: ChartIndicatorSeriesKey(
              instanceID: entry.configuration.instanceID,
              outputID: output.id
            ),
            points: entry.histories[output.id] ?? [],
            placement: entry.descriptor.placement,
            yAxisPolicy: entry.descriptor.yAxisPolicy,
            colorToken: Self.resolvedColor(
              for: output,
              configuration: entry.configuration
            ),
            lineWidthPoints: output.lineWidthPoints,
            autoscale: output.autoscale,
            figureStyle: output.figureStyle
          ))
      }
    }
    return ChartIndicatorHistorySnapshot(series: series)
  }

  private static func validate(
    _ configuration: ChartIndicatorInstanceConfiguration,
    against descriptor: ChartIndicatorDescriptor
  ) -> Bool {
    guard configuration.pluginID == descriptor.id else {
      return false
    }
    let allowedParameters = Set(descriptor.parameters.map(\.id))
    guard
      Set(configuration.parameters.keys)
        .isSubset(of: allowedParameters)
    else {
      return false
    }
    for parameter in descriptor.parameters {
      let value =
        configuration.parameters[parameter.id]
        ?? parameter.defaultValue
      guard value.isFinite,
        parameter.range.contains(value)
      else {
        return false
      }
    }
    let outputIDs = Set(descriptor.outputs.map(\.id))
    return Set(configuration.outputColorOverrides.keys)
      .isSubset(of: outputIDs)
  }

  private static func resolvedColor(
    for output: ChartIndicatorOutputDescriptor,
    configuration: ChartIndicatorInstanceConfiguration
  ) -> ChartIndicatorColorToken {
    configuration.outputColorOverrides[output.id]
      ?? output.colorToken
  }
}

struct EMAChartIndicatorPlugin: ChartIndicatorPlugin {
  let descriptor = ChartIndicatorDescriptor(
    id: "ema",
    displayName: "EMA",
    definitionVersion: 1,
    placement: .priceOverlay,
    parameters: [
      ChartIndicatorParameterDescriptor(
        id: "period",
        displayName: "周期",
        defaultValue: 21,
        range: 1...500,
        step: 1
      )
    ],
    outputs: [
      ChartIndicatorOutputDescriptor(
        id: "value",
        displayName: "EMA",
        colorToken: .neutral,
        lineWidthPoints: 0.85,
        autoscale: .included
      )
    ],
    warmupCount: 1,
    yAxisPolicy: .sharedPrice,
    allowsMultipleInstances: true
  )

  func makeCalculator(
    configuration: ChartIndicatorInstanceConfiguration,
    intervalMilliseconds: Int64
  ) -> (any ChartIndicatorCalculator)? {
    let rawPeriod = configuration.parameters["period"] ?? 21
    guard rawPeriod.rounded() == rawPeriod,
      rawPeriod >= 1,
      rawPeriod <= 500,
      let calculator = EMAIndicatorCalculator(
        period: Int(rawPeriod),
        intervalMilliseconds: intervalMilliseconds
      )
    else {
      return nil
    }
    return EMAChartIndicatorCalculator(calculator: calculator)
  }
}

private struct EMAChartIndicatorCalculator: ChartIndicatorCalculator {
  private var calculator: EMAIndicatorCalculator

  init(calculator: EMAIndicatorCalculator) {
    self.calculator = calculator
  }

  var lastCommittedOpenTime: Int64? {
    calculator.committed.lastOpenTime
  }

  mutating func commit(
    _ candle: ChartCandle
  ) -> ChartIndicatorPluginComputation {
    computation(calculator.commit(candle))
  }

  func provisional(
    _ candle: ChartCandle?
  ) -> ChartIndicatorPluginComputation {
    guard let point = calculator.provisional(candle) else {
      return ChartIndicatorPluginComputation(
        points: [:],
        legendValue: nil,
        legendColorToken: nil
      )
    }
    return computation(point)
  }

  private func computation(
    _ point: IndicatorPoint
  ) -> ChartIndicatorPluginComputation {
    ChartIndicatorPluginComputation(
      points: ["value": point],
      legendValue: point.validity == .valid
        ? point.value
        : nil,
      legendColorToken: nil
    )
  }
}
