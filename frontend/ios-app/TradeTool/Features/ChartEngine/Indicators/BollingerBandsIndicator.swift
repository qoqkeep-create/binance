import Foundation

struct BollingerBandsPoint: Equatable, Sendable {
  let openTime: Int64
  let upper: Double?
  let middle: Double?
  let lower: Double?
  let validity: IndicatorPointValidity
}

struct BollingerBandsCommittedState: Equatable, Sendable {
  let period: Int
  let multiplier: Double
  fileprivate(set) var values: [Double] = []
  fileprivate(set) var lastOpenTime: Int64?
}

struct BollingerBandsIndicatorCalculator: Sendable {
  let intervalMilliseconds: Int64
  private(set) var committed: BollingerBandsCommittedState

  init?(
    period: Int,
    multiplier: Double,
    intervalMilliseconds: Int64
  ) {
    guard period > 0,
      multiplier.isFinite,
      multiplier > 0,
      intervalMilliseconds > 0
    else {
      return nil
    }
    self.intervalMilliseconds = intervalMilliseconds
    committed = BollingerBandsCommittedState(
      period: period,
      multiplier: multiplier
    )
  }

  @discardableResult
  mutating func commit(_ candle: ChartCandle) -> BollingerBandsPoint {
    guard candle.closure == .closed,
      candle.isValid,
      candle.closePrice.isFinite
    else {
      return invalidPoint(for: candle.openTime)
    }
    if let lastOpenTime = committed.lastOpenTime {
      guard candle.openTime > lastOpenTime else {
        return invalidPoint(for: candle.openTime)
      }
      let expected = lastOpenTime.addingReportingOverflow(
        intervalMilliseconds
      )
      guard !expected.overflow,
        candle.openTime == expected.partialValue
      else {
        restartSeed(with: candle)
        return emptyPoint(for: candle.openTime, validity: .dataGap)
      }
    }
    var candidate = self
    let point = candidate.advanceCommitted(with: candle)
    if point.validity != .invalid {
      self = candidate
    }
    return point
  }

  func provisional(_ candle: ChartCandle?) -> BollingerBandsPoint? {
    guard let candle else {
      return nil
    }
    guard candle.closure != .closed,
      candle.isValid,
      candle.closePrice.isFinite
    else {
      return invalidPoint(for: candle.openTime)
    }
    if let lastOpenTime = committed.lastOpenTime {
      let expected = lastOpenTime.addingReportingOverflow(
        intervalMilliseconds
      )
      guard !expected.overflow,
        candle.openTime == expected.partialValue
      else {
        return emptyPoint(
          for: candle.openTime,
          validity: candle.openTime > lastOpenTime
            ? .dataGap
            : .invalid
        )
      }
    }
    var temporary = self
    return temporary.advanceCommitted(
      with: candle.withClosure(.closed)
    )
  }

  private mutating func restartSeed(with candle: ChartCandle) {
    committed.values = [candle.closePrice]
    committed.lastOpenTime = candle.openTime
  }

  private mutating func advanceCommitted(
    with candle: ChartCandle
  ) -> BollingerBandsPoint {
    let close = candle.closePrice
    committed.values.append(close)
    if committed.values.count > committed.period {
      committed.values.removeFirst()
    }
    committed.lastOpenTime = candle.openTime
    guard committed.values.count == committed.period else {
      return emptyPoint(for: candle.openTime, validity: .warmup)
    }

    let count = Double(committed.period)
    // Center on an observed price before summing. E[x²] - E[x]² loses
    // low-volatility differences at large prices and can produce false spikes.
    let reference = committed.values[0]
    let meanOffset = committed.values.reduce(0) {
      $0 + ($1 - reference)
    } / count
    let middle = reference + meanOffset
    let variance = committed.values.reduce(0) { sum, value in
      let deviation = (value - reference) - meanOffset
      return sum + deviation * deviation
    } / count
    let standardDeviation = sqrt(variance)
    let offset = standardDeviation * committed.multiplier
    let upper = middle + offset
    let lower = middle - offset
    guard middle.isFinite,
      standardDeviation.isFinite,
      upper.isFinite,
      lower.isFinite
    else {
      return invalidPoint(for: candle.openTime)
    }
    return BollingerBandsPoint(
      openTime: candle.openTime,
      upper: upper,
      middle: middle,
      lower: lower,
      validity: .valid
    )
  }

  private func emptyPoint(
    for openTime: Int64,
    validity: IndicatorPointValidity
  ) -> BollingerBandsPoint {
    BollingerBandsPoint(
      openTime: openTime,
      upper: nil,
      middle: nil,
      lower: nil,
      validity: validity
    )
  }

  private func invalidPoint(for openTime: Int64) -> BollingerBandsPoint {
    emptyPoint(for: openTime, validity: .invalid)
  }
}

struct BollingerBandsChartIndicatorPlugin: ChartIndicatorPlugin {
  let descriptor = ChartIndicatorDescriptor(
    id: "bollinger",
    displayName: "BOLL",
    definitionVersion: 1,
    placement: .priceOverlay,
    parameters: [
      ChartIndicatorParameterDescriptor(
        id: "period",
        displayName: "计算周期",
        defaultValue: 20,
        range: 1...500,
        step: 1
      ),
      ChartIndicatorParameterDescriptor(
        id: "multiplier",
        displayName: "带宽",
        defaultValue: 2,
        range: 0.1...20,
        step: 0.1
      ),
    ],
    outputs: [
      ChartIndicatorOutputDescriptor(
        id: "upper",
        displayName: "UP",
        colorToken: .ema21,
        lineWidthPoints: 0.85,
        autoscale: .included
      ),
      ChartIndicatorOutputDescriptor(
        id: "middle",
        displayName: "MB",
        colorToken: .ema55,
        lineWidthPoints: 0.85,
        autoscale: .included
      ),
      ChartIndicatorOutputDescriptor(
        id: "lower",
        displayName: "DN",
        colorToken: .ema144,
        lineWidthPoints: 0.85,
        autoscale: .included
      ),
    ],
    warmupCount: 20,
    yAxisPolicy: .sharedPrice,
    allowsMultipleInstances: false
  )

  func makeCalculator(
    configuration: ChartIndicatorInstanceConfiguration,
    intervalMilliseconds: Int64
  ) -> (any ChartIndicatorCalculator)? {
    let rawPeriod = configuration.parameters["period"] ?? 20
    let multiplier = configuration.parameters["multiplier"] ?? 2
    guard rawPeriod.rounded() == rawPeriod,
      rawPeriod >= 1,
      rawPeriod <= 500,
      let calculator = BollingerBandsIndicatorCalculator(
        period: Int(rawPeriod),
        multiplier: multiplier,
        intervalMilliseconds: intervalMilliseconds
      )
    else {
      return nil
    }
    return BollingerBandsChartIndicatorCalculator(
      calculator: calculator,
      period: Int(rawPeriod),
      multiplier: multiplier
    )
  }
}

private struct BollingerBandsChartIndicatorCalculator:
  ChartIndicatorCalculator
{
  private var calculator: BollingerBandsIndicatorCalculator
  private let legendPrefix: String

  init(
    calculator: BollingerBandsIndicatorCalculator,
    period: Int,
    multiplier: Double
  ) {
    self.calculator = calculator
    legendPrefix = "BOLL:(\(period), \(Self.text(multiplier)))"
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
    _ point: BollingerBandsPoint
  ) -> ChartIndicatorPluginComputation {
    let values: [(String, Double?)] = [
      ("upper", point.upper),
      ("middle", point.middle),
      ("lower", point.lower),
    ]
    let indicatorPoints = Dictionary(uniqueKeysWithValues: values.map {
      (
        $0.0,
        IndicatorPoint(
          openTime: point.openTime,
          value: point.validity == .valid ? $0.1 : nil,
          validity: point.validity
        )
      )
    })
    return ChartIndicatorPluginComputation(
      points: indicatorPoints,
      legendValue: point.middle,
      legendColorToken: nil,
      legendComponents: [
        ChartIndicatorLegendComponent(
          id: "upper",
          label: "\(legendPrefix) UP:",
          value: point.validity == .valid ? point.upper : nil,
          labelColorToken: .ema21,
          colorToken: .ema21,
          order: 0
        ),
        ChartIndicatorLegendComponent(
          id: "middle",
          label: "MB:",
          value: point.validity == .valid ? point.middle : nil,
          labelColorToken: .ema55,
          colorToken: .ema55,
          order: 1
        ),
        ChartIndicatorLegendComponent(
          id: "lower",
          label: "DN:",
          value: point.validity == .valid ? point.lower : nil,
          labelColorToken: .ema144,
          colorToken: .ema144,
          order: 2
        ),
      ]
    )
  }

  private static func text(_ value: Double) -> String {
    value.rounded() == value
      ? String(Int(value))
      : String(format: "%.2f", value)
        .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
  }
}
