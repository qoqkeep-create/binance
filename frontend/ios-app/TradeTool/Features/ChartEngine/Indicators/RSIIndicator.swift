import Foundation

struct RSIIndicatorCommittedState: Equatable, Sendable {
  let period: Int
  fileprivate(set) var previousClose: Double?
  fileprivate(set) var changeCount = 0
  fileprivate(set) var seedGainSum = 0.0
  fileprivate(set) var seedLossSum = 0.0
  fileprivate(set) var averageGain: Double?
  fileprivate(set) var averageLoss: Double?
  fileprivate(set) var lastOpenTime: Int64?
}

struct RSIIndicatorCalculator: Sendable {
  let intervalMilliseconds: Int64
  private(set) var committed: RSIIndicatorCommittedState

  init?(period: Int, intervalMilliseconds: Int64) {
    guard period > 0, intervalMilliseconds > 0 else {
      return nil
    }
    self.intervalMilliseconds = intervalMilliseconds
    committed = RSIIndicatorCommittedState(period: period)
  }

  @discardableResult
  mutating func commit(_ candle: ChartCandle) -> IndicatorPoint {
    guard candle.closure == .closed,
      candle.isValid,
      candle.closePrice.isFinite
    else {
      return point(
        openTime: candle.openTime,
        validity: .invalid
      )
    }

    if let lastOpenTime = committed.lastOpenTime {
      guard candle.openTime > lastOpenTime else {
        return point(
          openTime: candle.openTime,
          validity: .invalid
        )
      }
      let expected = lastOpenTime.addingReportingOverflow(
        intervalMilliseconds
      )
      guard !expected.overflow,
        candle.openTime == expected.partialValue
      else {
        restart(with: candle)
        return point(
          openTime: candle.openTime,
          validity: .dataGap
        )
      }
    }

    var candidate = self
    let result = candidate.advance(with: candle)
    if result.validity != .invalid {
      self = candidate
    }
    return result
  }

  func provisional(_ candle: ChartCandle?) -> IndicatorPoint? {
    guard let candle else {
      return nil
    }
    guard candle.closure != .closed,
      candle.isValid,
      candle.closePrice.isFinite
    else {
      return point(
        openTime: candle.openTime,
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
        return point(
          openTime: candle.openTime,
          validity: candle.openTime > lastOpenTime
            ? .dataGap
            : .invalid
        )
      }
    }
    var temporary = self
    return temporary.advance(with: candle.withClosure(.closed))
  }

  private mutating func restart(with candle: ChartCandle) {
    committed = RSIIndicatorCommittedState(
      period: committed.period,
      previousClose: candle.closePrice,
      lastOpenTime: candle.openTime
    )
  }

  private mutating func advance(
    with candle: ChartCandle
  ) -> IndicatorPoint {
    defer {
      committed.previousClose = candle.closePrice
      committed.lastOpenTime = candle.openTime
    }
    guard let previousClose = committed.previousClose else {
      return point(
        openTime: candle.openTime,
        validity: .warmup
      )
    }

    let change = candle.closePrice - previousClose
    let gain = max(change, 0)
    let loss = max(-change, 0)
    guard gain.isFinite, loss.isFinite else {
      return point(
        openTime: candle.openTime,
        validity: .invalid
      )
    }

    if let averageGain = committed.averageGain,
      let averageLoss = committed.averageLoss
    {
      let divisor = Double(committed.period)
      let nextGain = (
        averageGain * Double(committed.period - 1) + gain
      ) / divisor
      let nextLoss = (
        averageLoss * Double(committed.period - 1) + loss
      ) / divisor
      guard let value = Self.value(
        averageGain: nextGain,
        averageLoss: nextLoss
      ) else {
        return point(
          openTime: candle.openTime,
          validity: .invalid
        )
      }
      committed.averageGain = nextGain
      committed.averageLoss = nextLoss
      committed.changeCount &+= 1
      return IndicatorPoint(
        openTime: candle.openTime,
        value: value,
        validity: .valid
      )
    }

    let nextCount = committed.changeCount.addingReportingOverflow(1)
    let nextGainSum = committed.seedGainSum + gain
    let nextLossSum = committed.seedLossSum + loss
    guard !nextCount.overflow,
      nextGainSum.isFinite,
      nextLossSum.isFinite
    else {
      return point(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    committed.changeCount = nextCount.partialValue
    committed.seedGainSum = nextGainSum
    committed.seedLossSum = nextLossSum
    guard committed.changeCount >= committed.period else {
      return point(
        openTime: candle.openTime,
        validity: .warmup
      )
    }

    let divisor = Double(committed.period)
    let averageGain = nextGainSum / divisor
    let averageLoss = nextLossSum / divisor
    guard let value = Self.value(
      averageGain: averageGain,
      averageLoss: averageLoss
    ) else {
      return point(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    committed.averageGain = averageGain
    committed.averageLoss = averageLoss
    return IndicatorPoint(
      openTime: candle.openTime,
      value: value,
      validity: .valid
    )
  }

  private static func value(
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
    if averageGain == 0, averageLoss == 0 {
      return 50
    }
    if averageLoss == 0 {
      return 100
    }
    if averageGain == 0 {
      return 0
    }
    let relativeStrength = averageGain / averageLoss
    let value = 100 - 100 / (1 + relativeStrength)
    return value.isFinite ? value : nil
  }

  private func point(
    openTime: Int64,
    validity: IndicatorPointValidity
  ) -> IndicatorPoint {
    IndicatorPoint(
      openTime: openTime,
      value: nil,
      validity: validity
    )
  }
}

struct RSIChartIndicatorPlugin: ChartIndicatorPlugin {
  let descriptor = ChartIndicatorDescriptor(
    id: "rsi",
    displayName: "RSI",
    definitionVersion: 1,
    placement: .panel("rsi"),
    parameters: [
      ChartIndicatorParameterDescriptor(
        id: "period",
        displayName: "周期",
        defaultValue: 14,
        range: 1...200,
        step: 1
      )
    ],
    outputs: [
      ChartIndicatorOutputDescriptor(
        id: "value",
        displayName: "RSI",
        colorToken: .ema144,
        lineWidthPoints: 0.8,
        autoscale: .included
      )
    ],
    warmupCount: 14,
    yAxisPolicy: .fixed(lower: 0, upper: 100),
    allowsMultipleInstances: false
  )

  func makeCalculator(
    configuration: ChartIndicatorInstanceConfiguration,
    intervalMilliseconds: Int64
  ) -> (any ChartIndicatorCalculator)? {
    let rawPeriod = configuration.parameters["period"] ?? 14
    guard rawPeriod.rounded() == rawPeriod,
      rawPeriod >= 1,
      rawPeriod <= 200,
      let calculator = RSIIndicatorCalculator(
        period: Int(rawPeriod),
        intervalMilliseconds: intervalMilliseconds
      )
    else {
      return nil
    }
    return RSIChartIndicatorCalculator(calculator: calculator)
  }
}

private struct RSIChartIndicatorCalculator:
  ChartIndicatorCalculator
{
  private var calculator: RSIIndicatorCalculator

  init(calculator: RSIIndicatorCalculator) {
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
      legendColorToken: .ema144
    )
  }
}
