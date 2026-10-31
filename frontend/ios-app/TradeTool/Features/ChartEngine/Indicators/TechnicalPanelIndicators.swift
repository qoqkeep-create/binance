import Foundation

enum TechnicalPanelIndicatorKind: Equatable, Sendable {
  case kdj
  case obv
  case williamsR
  case stochasticRSI
  case atr

  var descriptor: ChartIndicatorDescriptor {
    switch self {
    case .kdj:
      return ChartIndicatorDescriptor(
        id: "kdj",
        displayName: "KDJ",
        definitionVersion: 1,
        placement: .panel(ChartPanelID.kdj),
        parameters: [
          Self.integerParameter("period", "周期", 9),
          Self.integerParameter("kSmoothing", "K 平滑", 3),
          Self.integerParameter("dSmoothing", "D 平滑", 3),
        ],
        outputs: [
          Self.lineOutput("k", "K", .ema21),
          Self.lineOutput("d", "D", .ema55),
          Self.lineOutput("j", "J", .ema144),
        ],
        warmupCount: 9,
        yAxisPolicy: .fixed(lower: 0, upper: 100),
        allowsMultipleInstances: false
      )
    case .obv:
      return ChartIndicatorDescriptor(
        id: "obv",
        displayName: "OBV",
        definitionVersion: 1,
        placement: .panel(ChartPanelID.obv),
        parameters: [],
        outputs: [Self.lineOutput("value", "OBV", .ema21)],
        warmupCount: 0,
        yAxisPolicy: .automatic,
        allowsMultipleInstances: false
      )
    case .williamsR:
      return ChartIndicatorDescriptor(
        id: "williams-r",
        displayName: "WR",
        definitionVersion: 1,
        placement: .panel(ChartPanelID.williamsR),
        parameters: [Self.integerParameter("period", "周期", 14)],
        outputs: [Self.lineOutput("value", "WR", .ema21)],
        warmupCount: 14,
        yAxisPolicy: .fixed(lower: -100, upper: 0),
        allowsMultipleInstances: false
      )
    case .stochasticRSI:
      return ChartIndicatorDescriptor(
        id: "stochastic-rsi",
        displayName: "StochRSI",
        definitionVersion: 1,
        placement: .panel(ChartPanelID.stochasticRSI),
        parameters: [
          Self.integerParameter("rsiPeriod", "RSI 周期", 14),
          Self.integerParameter("window", "随机周期", 14),
          Self.integerParameter("kSmoothing", "K 平滑", 3),
          Self.integerParameter("dSmoothing", "D 平滑", 3),
        ],
        outputs: [
          Self.lineOutput("k", "K%", .ema21),
          Self.lineOutput("d", "D%", .ema144),
        ],
        warmupCount: 31,
        yAxisPolicy: .fixed(lower: 0, upper: 100),
        allowsMultipleInstances: false
      )
    case .atr:
      return ChartIndicatorDescriptor(
        id: "atr",
        displayName: "ATR",
        definitionVersion: 1,
        placement: .panel(ChartPanelID.atr),
        parameters: [Self.integerParameter("period", "周期", 14)],
        outputs: [Self.lineOutput("value", "ATR", .ema21)],
        warmupCount: 14,
        yAxisPolicy: .automatic,
        allowsMultipleInstances: false
      )
    }
  }

  private static func integerParameter(
    _ id: String,
    _ displayName: String,
    _ value: Double
  ) -> ChartIndicatorParameterDescriptor {
    ChartIndicatorParameterDescriptor(
      id: id,
      displayName: displayName,
      defaultValue: value,
      range: 1...500,
      step: 1
    )
  }

  private static func lineOutput(
    _ id: String,
    _ displayName: String,
    _ color: ChartIndicatorColorToken
  ) -> ChartIndicatorOutputDescriptor {
    ChartIndicatorOutputDescriptor(
      id: id,
      displayName: displayName,
      colorToken: color,
      lineWidthPoints: 0.8,
      autoscale: .included
    )
  }
}

struct TechnicalPanelChartIndicatorPlugin: ChartIndicatorPlugin {
  let kind: TechnicalPanelIndicatorKind

  var descriptor: ChartIndicatorDescriptor {
    kind.descriptor
  }

  func makeCalculator(
    configuration: ChartIndicatorInstanceConfiguration,
    intervalMilliseconds: Int64
  ) -> (any ChartIndicatorCalculator)? {
    TechnicalPanelChartIndicatorCalculator(
      kind: kind,
      configuration: configuration,
      intervalMilliseconds: intervalMilliseconds
    )
  }
}

private struct TechnicalPanelChartIndicatorCalculator:
  ChartIndicatorCalculator
{
  let kind: TechnicalPanelIndicatorKind
  let intervalMilliseconds: Int64
  let period: Int
  let secondaryPeriod: Int
  let kSmoothing: Int
  let dSmoothing: Int

  private(set) var lastCommittedOpenTime: Int64?
  private var rollingCandles: [ChartCandle] = []
  private var previousClose: Double?
  private var obv: Double?
  private var kValue = 50.0
  private var dValue = 50.0
  private var atrSeed: [Double] = []
  private var atrValue: Double?
  private var rsiChangeCount = 0
  private var rsiGainSum = 0.0
  private var rsiLossSum = 0.0
  private var rsiAverageGain: Double?
  private var rsiAverageLoss: Double?
  private var rsiValues: [Double] = []
  private var stochasticValues: [Double] = []
  private var stochasticKValues: [Double] = []

  init?(
    kind: TechnicalPanelIndicatorKind,
    configuration: ChartIndicatorInstanceConfiguration,
    intervalMilliseconds: Int64
  ) {
    guard intervalMilliseconds > 0 else {
      return nil
    }
    func integer(_ id: String, fallback: Int) -> Int? {
      let raw = configuration.parameters[id] ?? Double(fallback)
      guard raw.isFinite,
        raw.rounded() == raw,
        raw >= 1,
        raw <= 500
      else {
        return nil
      }
      return Int(raw)
    }
    switch kind {
    case .kdj:
      guard let period = integer("period", fallback: 9),
        let k = integer("kSmoothing", fallback: 3),
        let d = integer("dSmoothing", fallback: 3)
      else {
        return nil
      }
      self.period = period
      secondaryPeriod = period
      kSmoothing = k
      dSmoothing = d
    case .obv:
      period = 1
      secondaryPeriod = 1
      kSmoothing = 1
      dSmoothing = 1
    case .williamsR, .atr:
      guard let period = integer("period", fallback: 14) else {
        return nil
      }
      self.period = period
      secondaryPeriod = period
      kSmoothing = 1
      dSmoothing = 1
    case .stochasticRSI:
      guard let rsiPeriod = integer("rsiPeriod", fallback: 14),
        let window = integer("window", fallback: 14),
        let k = integer("kSmoothing", fallback: 3),
        let d = integer("dSmoothing", fallback: 3)
      else {
        return nil
      }
      period = rsiPeriod
      secondaryPeriod = window
      kSmoothing = k
      dSmoothing = d
    }
    self.kind = kind
    self.intervalMilliseconds = intervalMilliseconds
  }

  mutating func commit(
    _ candle: ChartCandle
  ) -> ChartIndicatorPluginComputation {
    guard candle.closure == .closed,
      candle.isValid
    else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    if let lastCommittedOpenTime {
      guard candle.openTime > lastCommittedOpenTime else {
        return emptyComputation(
          openTime: candle.openTime,
          validity: .invalid
        )
      }
      let expected = lastCommittedOpenTime.addingReportingOverflow(
        intervalMilliseconds
      )
      guard !expected.overflow,
        candle.openTime == expected.partialValue
      else {
        reset()
        _ = advance(candle)
        return emptyComputation(
          openTime: candle.openTime,
          validity: .dataGap
        )
      }
    }
    var candidate = self
    let result = candidate.advance(candle)
    if !result.points.values.contains(where: {
      $0.validity == .invalid
    }) {
      self = candidate
    }
    return result
  }

  func provisional(
    _ candle: ChartCandle?
  ) -> ChartIndicatorPluginComputation {
    guard let candle else {
      return ChartIndicatorPluginComputation(
        points: [:],
        legendValue: nil,
        legendColorToken: nil
      )
    }
    guard candle.closure != .closed,
      candle.isValid
    else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    if let lastCommittedOpenTime {
      let expected = lastCommittedOpenTime.addingReportingOverflow(
        intervalMilliseconds
      )
      guard !expected.overflow,
        candle.openTime == expected.partialValue
      else {
        return emptyComputation(
          openTime: candle.openTime,
          validity: candle.openTime > lastCommittedOpenTime
            ? .dataGap
            : .invalid
        )
      }
    }
    var temporary = self
    return temporary.advance(candle.withClosure(.closed))
  }

  private mutating func advance(
    _ candle: ChartCandle
  ) -> ChartIndicatorPluginComputation {
    defer {
      previousClose = candle.closePrice
      lastCommittedOpenTime = candle.openTime
    }
    switch kind {
    case .kdj:
      return advanceKDJ(candle)
    case .obv:
      return advanceOBV(candle)
    case .williamsR:
      return advanceWilliamsR(candle)
    case .stochasticRSI:
      return advanceStochasticRSI(candle)
    case .atr:
      return advanceATR(candle)
    }
  }

  private mutating func advanceKDJ(
    _ candle: ChartCandle
  ) -> ChartIndicatorPluginComputation {
    appendRollingCandle(candle, limit: period)
    guard rollingCandles.count == period else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .warmup
      )
    }
    guard let highest = rollingCandles.map(\.highPrice).max(),
      let lowest = rollingCandles.map(\.lowPrice).min()
    else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    let range = highest - lowest
    let rsv = range > 0
      ? 100 * (candle.closePrice - lowest) / range
      : 0
    let nextK = (
      kValue * Double(kSmoothing - 1) + rsv
    ) / Double(kSmoothing)
    let nextD = (
      dValue * Double(dSmoothing - 1) + nextK
    ) / Double(dSmoothing)
    let nextJ = 3 * nextK - 2 * nextD
    guard [nextK, nextD, nextJ].allSatisfy(\.isFinite) else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    kValue = nextK
    dValue = nextD
    return computation(
      openTime: candle.openTime,
      values: ["k": nextK, "d": nextD, "j": nextJ],
      components: [
        component("k", "K:", nextK, .ema21, 0),
        component("d", "D:", nextD, .ema55, 1),
        component("j", "J:", nextJ, .ema144, 2),
      ]
    )
  }

  private mutating func advanceOBV(
    _ candle: ChartCandle
  ) -> ChartIndicatorPluginComputation {
    let next: Double
    if let previousClose, let obv {
      if candle.closePrice > previousClose {
        next = obv + candle.volume
      } else if candle.closePrice < previousClose {
        next = obv - candle.volume
      } else {
        next = obv
      }
    } else {
      next = candle.volume
    }
    guard next.isFinite else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    obv = next
    return computation(
      openTime: candle.openTime,
      values: ["value": next]
    )
  }

  private mutating func advanceWilliamsR(
    _ candle: ChartCandle
  ) -> ChartIndicatorPluginComputation {
    appendRollingCandle(candle, limit: period)
    guard rollingCandles.count == period else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .warmup
      )
    }
    guard let highest = rollingCandles.map(\.highPrice).max(),
      let lowest = rollingCandles.map(\.lowPrice).min()
    else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    let range = highest - lowest
    let value = range > 0
      ? -100 * (highest - candle.closePrice) / range
      : 0
    guard value.isFinite else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    return computation(
      openTime: candle.openTime,
      values: ["value": value]
    )
  }

  private mutating func advanceATR(
    _ candle: ChartCandle
  ) -> ChartIndicatorPluginComputation {
    let trueRange: Double
    if let previousClose {
      trueRange = max(
        candle.highPrice - candle.lowPrice,
        abs(candle.highPrice - previousClose),
        abs(candle.lowPrice - previousClose)
      )
    } else {
      trueRange = candle.highPrice - candle.lowPrice
    }
    guard trueRange.isFinite, trueRange >= 0 else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    let value: Double
    if let current = atrValue {
      value = (
        current * Double(period - 1) + trueRange
      ) / Double(period)
      atrValue = value
    } else {
      atrSeed.append(trueRange)
      guard atrSeed.count >= period else {
        return emptyComputation(
          openTime: candle.openTime,
          validity: .warmup
        )
      }
      value = atrSeed.reduce(0, +) / Double(period)
      atrValue = value
      atrSeed.removeAll(keepingCapacity: true)
    }
    guard value.isFinite else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    return computation(
      openTime: candle.openTime,
      values: ["value": value]
    )
  }

  private mutating func advanceStochasticRSI(
    _ candle: ChartCandle
  ) -> ChartIndicatorPluginComputation {
    guard let rsi = nextRSI(close: candle.closePrice) else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .warmup
      )
    }
    append(&rsiValues, rsi, limit: secondaryPeriod)
    guard rsiValues.count == secondaryPeriod,
      let highest = rsiValues.max(),
      let lowest = rsiValues.min()
    else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .warmup
      )
    }
    let range = highest - lowest
    let stochastic = range > 0
      ? 100 * (rsi - lowest) / range
      : 0
    append(&stochasticValues, stochastic, limit: kSmoothing)
    guard stochasticValues.count == kSmoothing else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .warmup
      )
    }
    let k = stochasticValues.reduce(0, +) / Double(kSmoothing)
    append(&stochasticKValues, k, limit: dSmoothing)
    let d: Double? = stochasticKValues.count == dSmoothing
      ? stochasticKValues.reduce(0, +) / Double(dSmoothing)
      : nil
    guard k.isFinite, d?.isFinite != false else {
      return emptyComputation(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    let kPoint = IndicatorPoint(
      openTime: candle.openTime,
      value: k,
      validity: .valid
    )
    let dPoint = IndicatorPoint(
      openTime: candle.openTime,
      value: d,
      validity: d == nil ? .warmup : .valid
    )
    return ChartIndicatorPluginComputation(
      points: ["k": kPoint, "d": dPoint],
      legendValue: k,
      legendColorToken: .ema21,
      legendComponents: [
        component("k", "K%:", k, .ema21, 0),
        component("d", "D%:", d, .ema144, 1),
      ]
    )
  }

  private mutating func nextRSI(close: Double) -> Double? {
    guard let previousClose else {
      return nil
    }
    let change = close - previousClose
    let gain = max(change, 0)
    let loss = max(-change, 0)
    if let averageGain = rsiAverageGain,
      let averageLoss = rsiAverageLoss
    {
      let divisor = Double(period)
      let nextGain = (
        averageGain * Double(period - 1) + gain
      ) / divisor
      let nextLoss = (
        averageLoss * Double(period - 1) + loss
      ) / divisor
      rsiAverageGain = nextGain
      rsiAverageLoss = nextLoss
      return Self.rsi(averageGain: nextGain, averageLoss: nextLoss)
    }
    rsiChangeCount += 1
    rsiGainSum += gain
    rsiLossSum += loss
    guard rsiChangeCount >= period else {
      return nil
    }
    let averageGain = rsiGainSum / Double(period)
    let averageLoss = rsiLossSum / Double(period)
    rsiAverageGain = averageGain
    rsiAverageLoss = averageLoss
    return Self.rsi(
      averageGain: averageGain,
      averageLoss: averageLoss
    )
  }

  private static func rsi(
    averageGain: Double,
    averageLoss: Double
  ) -> Double? {
    guard averageGain.isFinite,
      averageLoss.isFinite,
      averageGain >= 0,
      averageLoss >= 0
    else {
      return nil
    }
    if averageLoss == 0 {
      return averageGain == 0 ? 50 : 100
    }
    let value = 100 - 100 / (1 + averageGain / averageLoss)
    return value.isFinite ? value : nil
  }

  private mutating func appendRollingCandle(
    _ candle: ChartCandle,
    limit: Int
  ) {
    rollingCandles.append(candle)
    if rollingCandles.count > limit {
      rollingCandles.removeFirst(rollingCandles.count - limit)
    }
  }

  private func computation(
    openTime: Int64,
    values: [String: Double],
    components: [ChartIndicatorLegendComponent] = []
  ) -> ChartIndicatorPluginComputation {
    let points = values.mapValues {
      IndicatorPoint(
        openTime: openTime,
        value: $0,
        validity: .valid
      )
    }
    return ChartIndicatorPluginComputation(
      points: points,
      legendValue: values.values.first,
      legendColorToken: kind == .obv || kind == .atr
        || kind == .williamsR ? .ema21 : nil,
      legendComponents: components
    )
  }

  private func emptyComputation(
    openTime: Int64,
    validity: IndicatorPointValidity
  ) -> ChartIndicatorPluginComputation {
    ChartIndicatorPluginComputation(
      points: Dictionary(
        uniqueKeysWithValues: kind.descriptor.outputs.map {
          ($0.id, IndicatorPoint(
            openTime: openTime,
            value: nil,
            validity: validity
          ))
        }
      ),
      legendValue: nil,
      legendColorToken: nil
    )
  }

  private func component(
    _ id: String,
    _ label: String,
    _ value: Double?,
    _ color: ChartIndicatorColorToken,
    _ order: Int
  ) -> ChartIndicatorLegendComponent {
    ChartIndicatorLegendComponent(
      id: id,
      label: label,
      value: value,
      labelColorToken: color,
      colorToken: color,
      order: order
    )
  }

  private mutating func reset() {
    lastCommittedOpenTime = nil
    rollingCandles.removeAll(keepingCapacity: true)
    previousClose = nil
    obv = nil
    kValue = 50
    dValue = 50
    atrSeed.removeAll(keepingCapacity: true)
    atrValue = nil
    rsiChangeCount = 0
    rsiGainSum = 0
    rsiLossSum = 0
    rsiAverageGain = nil
    rsiAverageLoss = nil
    rsiValues.removeAll(keepingCapacity: true)
    stochasticValues.removeAll(keepingCapacity: true)
    stochasticKValues.removeAll(keepingCapacity: true)
  }

  private func append(
    _ values: inout [Double],
    _ value: Double,
    limit: Int
  ) {
    values.append(value)
    if values.count > limit {
      values.removeFirst(values.count - limit)
    }
  }
}
