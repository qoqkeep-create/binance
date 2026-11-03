import Foundation

enum SuperTrendDirection: Equatable, Sendable {
  case up
  case down
}

struct SuperTrendPoint: Equatable, Sendable {
  let openTime: Int64
  let value: Double?
  let direction: SuperTrendDirection?
  let validity: IndicatorPointValidity
}

struct SuperTrendCommittedState: Equatable, Sendable {
  let atrPeriod: Int
  let multiplier: Double
  fileprivate(set) var sampleCount: Int = 0
  fileprivate(set) var previousClose: Double?
  fileprivate(set) var atr: Double?
  fileprivate(set) var upperBand: Double?
  fileprivate(set) var lowerBand: Double?
  fileprivate(set) var value: Double?
  fileprivate(set) var direction: SuperTrendDirection?
  fileprivate(set) var lastOpenTime: Int64?
}

struct SuperTrendIndicatorCalculator: Sendable {
  let intervalMilliseconds: Int64
  private(set) var committed: SuperTrendCommittedState

  init?(
    atrPeriod: Int,
    multiplier: Double,
    intervalMilliseconds: Int64
  ) {
    guard atrPeriod > 0,
      multiplier.isFinite,
      multiplier > 0,
      intervalMilliseconds > 0
    else {
      return nil
    }
    self.intervalMilliseconds = intervalMilliseconds
    committed = SuperTrendCommittedState(
      atrPeriod: atrPeriod,
      multiplier: multiplier
    )
  }

  @discardableResult
  mutating func commit(
    _ candle: ChartCandle
  ) -> SuperTrendPoint {
    guard candle.closure == .closed,
      candle.isValid
    else {
      return SuperTrendPoint(
        openTime: candle.openTime,
        value: nil,
        direction: nil,
        validity: .invalid
      )
    }

    if let lastOpenTime = committed.lastOpenTime {
      guard candle.openTime > lastOpenTime else {
        return SuperTrendPoint(
          openTime: candle.openTime,
          value: nil,
          direction: nil,
          validity: .invalid
        )
      }
      let expected = lastOpenTime.addingReportingOverflow(
        intervalMilliseconds
      )
      guard !expected.overflow,
        candle.openTime == expected.partialValue
      else {
        restartSeed(with: candle)
        return SuperTrendPoint(
          openTime: candle.openTime,
          value: nil,
          direction: nil,
          validity: .dataGap
        )
      }
    }

    var candidate = self
    let point = candidate.advanceCommitted(with: candle)
    if point.validity != .invalid {
      self = candidate
    }
    return point
  }

  func provisional(
    _ candle: ChartCandle?
  ) -> SuperTrendPoint? {
    guard let candle else {
      return nil
    }
    guard candle.closure != .closed,
      candle.isValid
    else {
      return SuperTrendPoint(
        openTime: candle.openTime,
        value: nil,
        direction: nil,
        validity: .invalid
      )
    }

    if let lastOpenTime = committed.lastOpenTime {
      let expected = lastOpenTime.addingReportingOverflow(
        intervalMilliseconds
      )
      guard !expected.overflow,
        candle.openTime == expected.partialValue
      else {
        return SuperTrendPoint(
          openTime: candle.openTime,
          value: nil,
          direction: nil,
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

  private mutating func restartSeed(
    with candle: ChartCandle
  ) {
    committed.sampleCount = 1
    committed.previousClose = candle.closePrice
    committed.atr = nil
    committed.upperBand = nil
    committed.lowerBand = nil
    committed.value = nil
    committed.direction = nil
    committed.lastOpenTime = candle.openTime
  }

  private mutating func advanceCommitted(
    with candle: ChartCandle
  ) -> SuperTrendPoint {
    let previousClose = committed.previousClose
    guard
      let trueRange = trueRange(
        candle: candle,
        previousClose: previousClose
      )
    else {
      return SuperTrendPoint(
        openTime: candle.openTime,
        value: nil,
        direction: nil,
        validity: .invalid
      )
    }

    let index = committed.sampleCount
    committed.sampleCount &+= 1
    committed.previousClose = candle.closePrice
    committed.lastOpenTime = candle.openTime

    guard index >= committed.atrPeriod else {
      return SuperTrendPoint(
        openTime: candle.openTime,
        value: nil,
        direction: nil,
        validity: .warmup
      )
    }

    let atr: Double
    if index == committed.atrPeriod {
      atr = trueRange
    } else if let previousATR = committed.atr {
      atr =
        previousATR
        + (trueRange - previousATR)
        / Double(committed.atrPeriod)
    } else {
      return SuperTrendPoint(
        openTime: candle.openTime,
        value: nil,
        direction: nil,
        validity: .invalid
      )
    }

    let median =
      candle.lowPrice
      + (candle.highPrice - candle.lowPrice) / 2
    let offset = committed.multiplier * atr
    let basicUpper = median + offset
    let basicLower = median - offset
    guard atr.isFinite,
      median.isFinite,
      offset.isFinite,
      basicUpper.isFinite,
      basicLower.isFinite
    else {
      return SuperTrendPoint(
        openTime: candle.openTime,
        value: nil,
        direction: nil,
        validity: .invalid
      )
    }

    let upperBand: Double
    if let previousUpper = committed.upperBand,
      let previousClose
    {
      upperBand =
        basicUpper < previousUpper
          || previousClose > previousUpper
        ? basicUpper
        : previousUpper
    } else {
      upperBand = basicUpper
    }

    let lowerBand: Double
    if let previousLower = committed.lowerBand,
      let previousClose
    {
      lowerBand =
        basicLower > previousLower
          || previousClose < previousLower
        ? basicLower
        : previousLower
    } else {
      lowerBand = basicLower
    }

    let direction: SuperTrendDirection
    switch committed.direction {
    case .down:
      direction =
        candle.closePrice <= upperBand
        ? .down
        : .up
    case .up:
      direction =
        candle.closePrice >= lowerBand
        ? .up
        : .down
    case nil:
      direction = .up
    }
    let value =
      direction == .up
      ? lowerBand
      : upperBand
    guard upperBand.isFinite,
      lowerBand.isFinite,
      value.isFinite
    else {
      return SuperTrendPoint(
        openTime: candle.openTime,
        value: nil,
        direction: nil,
        validity: .invalid
      )
    }

    committed.atr = atr
    committed.upperBand = upperBand
    committed.lowerBand = lowerBand
    committed.value = value
    committed.direction = direction
    return SuperTrendPoint(
      openTime: candle.openTime,
      value: value,
      direction: direction,
      validity: .valid
    )
  }

  private func trueRange(
    candle: ChartCandle,
    previousClose: Double?
  ) -> Double? {
    let highLow = abs(candle.highPrice - candle.lowPrice)
    guard highLow.isFinite else {
      return nil
    }
    guard let previousClose else {
      return highLow
    }
    let highClose = abs(candle.highPrice - previousClose)
    let closeLow = abs(previousClose - candle.lowPrice)
    let result = max(highLow, max(highClose, closeLow))
    return result.isFinite ? result : nil
  }
}

struct SuperTrendChartIndicatorPlugin: ChartIndicatorPlugin {
  let descriptor = ChartIndicatorDescriptor(
    id: "supertrend",
    displayName: "SuperTrend",
    definitionVersion: 1,
    placement: .priceOverlay,
    parameters: [
      ChartIndicatorParameterDescriptor(
        id: "atrPeriod",
        displayName: "ATR 周期",
        defaultValue: 10,
        range: 1...200,
        step: 1
      ),
      ChartIndicatorParameterDescriptor(
        id: "multiplier",
        displayName: "倍数",
        defaultValue: 6,
        range: 0.1...20,
        step: 0.1
      ),
    ],
    outputs: [
      ChartIndicatorOutputDescriptor(
        id: "up",
        displayName: "Up",
        colorToken: .positive,
        lineWidthPoints: 1.3,
        autoscale: .included,
        figureStyle: .lineWithCandleCloseBand(fillAlpha: 0.28)
      ),
      ChartIndicatorOutputDescriptor(
        id: "down",
        displayName: "Down",
        colorToken: .negative,
        lineWidthPoints: 1.3,
        autoscale: .included,
        figureStyle: .lineWithCandleCloseBand(fillAlpha: 0.28)
      ),
    ],
    warmupCount: 10,
    yAxisPolicy: .sharedPrice,
    allowsMultipleInstances: false
  )

  func makeCalculator(
    configuration: ChartIndicatorInstanceConfiguration,
    intervalMilliseconds: Int64
  ) -> (any ChartIndicatorCalculator)? {
    let rawPeriod = configuration.parameters["atrPeriod"] ?? 10
    let multiplier = configuration.parameters["multiplier"] ?? 6
    guard rawPeriod.rounded() == rawPeriod,
      rawPeriod >= 1,
      rawPeriod <= 200,
      let calculator = SuperTrendIndicatorCalculator(
        atrPeriod: Int(rawPeriod),
        multiplier: multiplier,
        intervalMilliseconds: intervalMilliseconds
      )
    else {
      return nil
    }
    return SuperTrendChartIndicatorCalculator(
      calculator: calculator
    )
  }
}

private struct SuperTrendChartIndicatorCalculator:
  ChartIndicatorCalculator
{
  private var calculator: SuperTrendIndicatorCalculator

  init(calculator: SuperTrendIndicatorCalculator) {
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
    _ point: SuperTrendPoint
  ) -> ChartIndicatorPluginComputation {
    let up: IndicatorPoint
    let down: IndicatorPoint
    if point.validity == .valid {
      up = IndicatorPoint(
        openTime: point.openTime,
        value: point.direction == .up ? point.value : nil,
        validity: point.direction == .up ? .valid : .hidden
      )
      down = IndicatorPoint(
        openTime: point.openTime,
        value: point.direction == .down ? point.value : nil,
        validity: point.direction == .down ? .valid : .hidden
      )
    } else {
      up = IndicatorPoint(
        openTime: point.openTime,
        value: nil,
        validity: point.validity
      )
      down = IndicatorPoint(
        openTime: point.openTime,
        value: nil,
        validity: point.validity
      )
    }
    let color: ChartIndicatorColorToken?
    switch point.direction {
    case .up:
      color = .positive
    case .down:
      color = .negative
    case nil:
      color = nil
    }
    return ChartIndicatorPluginComputation(
      points: [
        "up": up,
        "down": down,
      ],
      legendValue: point.validity == .valid
        ? point.value
        : nil,
      legendColorToken: color
    )
  }
}
