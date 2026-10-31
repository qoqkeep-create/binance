import Foundation

struct SimpleMovingAverageCommittedState: Equatable, Sendable {
  let period: Int
  fileprivate(set) var values: [Double] = []
  fileprivate(set) var sum: Double = 0
  fileprivate(set) var lastOpenTime: Int64?
}

struct SimpleMovingAverageIndicatorCalculator: Sendable {
  let intervalMilliseconds: Int64
  private(set) var committed: SimpleMovingAverageCommittedState

  init?(period: Int, intervalMilliseconds: Int64) {
    guard period > 0, intervalMilliseconds > 0 else {
      return nil
    }
    self.intervalMilliseconds = intervalMilliseconds
    committed = SimpleMovingAverageCommittedState(period: period)
  }

  @discardableResult
  mutating func commit(_ candle: ChartCandle) -> IndicatorPoint {
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
        return IndicatorPoint(
          openTime: candle.openTime,
          value: nil,
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

  func provisional(_ candle: ChartCandle?) -> IndicatorPoint? {
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
        return IndicatorPoint(
          openTime: candle.openTime,
          value: nil,
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
    committed.sum = candle.closePrice
    committed.lastOpenTime = candle.openTime
  }

  private mutating func advanceCommitted(
    with candle: ChartCandle
  ) -> IndicatorPoint {
    committed.values.append(candle.closePrice)
    committed.sum += candle.closePrice
    if committed.values.count > committed.period {
      committed.sum -= committed.values.removeFirst()
    }
    guard committed.sum.isFinite else {
      return invalidPoint(for: candle.openTime)
    }
    committed.lastOpenTime = candle.openTime
    guard committed.values.count == committed.period else {
      return IndicatorPoint(
        openTime: candle.openTime,
        value: nil,
        validity: .warmup
      )
    }
    let value = committed.sum / Double(committed.period)
    guard value.isFinite else {
      return invalidPoint(for: candle.openTime)
    }
    return IndicatorPoint(
      openTime: candle.openTime,
      value: value,
      validity: .valid
    )
  }

  private func invalidPoint(for openTime: Int64) -> IndicatorPoint {
    IndicatorPoint(
      openTime: openTime,
      value: nil,
      validity: .invalid
    )
  }
}

struct SimpleMovingAverageChartIndicatorPlugin: ChartIndicatorPlugin {
  let descriptor = ChartIndicatorDescriptor(
    id: "sma",
    displayName: "MA",
    definitionVersion: 1,
    placement: .priceOverlay,
    parameters: [
      ChartIndicatorParameterDescriptor(
        id: "period",
        displayName: "周期",
        defaultValue: 7,
        range: 1...500,
        step: 1
      )
    ],
    outputs: [
      ChartIndicatorOutputDescriptor(
        id: "value",
        displayName: "MA",
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
    let rawPeriod = configuration.parameters["period"] ?? 7
    guard rawPeriod.rounded() == rawPeriod,
      rawPeriod >= 1,
      rawPeriod <= 500,
      let calculator = SimpleMovingAverageIndicatorCalculator(
        period: Int(rawPeriod),
        intervalMilliseconds: intervalMilliseconds
      )
    else {
      return nil
    }
    return SimpleMovingAverageChartIndicatorCalculator(
      calculator: calculator
    )
  }
}

private struct SimpleMovingAverageChartIndicatorCalculator:
  ChartIndicatorCalculator
{
  private var calculator: SimpleMovingAverageIndicatorCalculator

  init(calculator: SimpleMovingAverageIndicatorCalculator) {
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
      legendValue: point.validity == .valid ? point.value : nil,
      legendColorToken: nil
    )
  }
}
