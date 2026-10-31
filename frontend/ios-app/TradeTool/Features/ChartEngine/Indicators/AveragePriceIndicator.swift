import Foundation

struct AveragePriceIndicatorCalculator: Sendable {
  let intervalMilliseconds: Int64
  private(set) var lastCommittedOpenTime: Int64?

  init?(intervalMilliseconds: Int64) {
    guard intervalMilliseconds > 0 else {
      return nil
    }
    self.intervalMilliseconds = intervalMilliseconds
  }

  @discardableResult
  mutating func commit(_ candle: ChartCandle) -> IndicatorPoint {
    guard candle.closure == .closed, candle.isValid else {
      return invalidPoint(for: candle.openTime)
    }
    if let lastCommittedOpenTime {
      guard candle.openTime > lastCommittedOpenTime else {
        return invalidPoint(for: candle.openTime)
      }
      let expected = lastCommittedOpenTime.addingReportingOverflow(
        intervalMilliseconds
      )
      guard !expected.overflow,
        candle.openTime == expected.partialValue
      else {
        self.lastCommittedOpenTime = candle.openTime
        return IndicatorPoint(
          openTime: candle.openTime,
          value: nil,
          validity: .dataGap
        )
      }
    }
    let point = calculatedPoint(for: candle)
    if point.validity != .invalid {
      lastCommittedOpenTime = candle.openTime
    }
    return point
  }

  func provisional(_ candle: ChartCandle?) -> IndicatorPoint? {
    guard let candle else {
      return nil
    }
    guard candle.closure != .closed, candle.isValid else {
      return invalidPoint(for: candle.openTime)
    }
    if let lastCommittedOpenTime {
      let expected = lastCommittedOpenTime.addingReportingOverflow(
        intervalMilliseconds
      )
      guard !expected.overflow,
        candle.openTime == expected.partialValue
      else {
        return IndicatorPoint(
          openTime: candle.openTime,
          value: nil,
          validity: candle.openTime > lastCommittedOpenTime
            ? .dataGap
            : .invalid
        )
      }
    }
    return calculatedPoint(for: candle)
  }

  private func calculatedPoint(for candle: ChartCandle) -> IndicatorPoint {
    guard candle.volume > 0 else {
      return IndicatorPoint(
        openTime: candle.openTime,
        value: nil,
        validity: .hidden
      )
    }
    let value = candle.quoteVolume / candle.volume
    guard value.isFinite, value >= 0 else {
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

struct AveragePriceChartIndicatorPlugin: ChartIndicatorPlugin {
  let descriptor = ChartIndicatorDescriptor(
    id: "average-price",
    displayName: "AVL",
    definitionVersion: 1,
    placement: .priceOverlay,
    parameters: [],
    outputs: [
      ChartIndicatorOutputDescriptor(
        id: "value",
        displayName: "AVL",
        colorToken: .ema21,
        lineWidthPoints: 0.85,
        autoscale: .included
      )
    ],
    warmupCount: 0,
    yAxisPolicy: .sharedPrice,
    allowsMultipleInstances: false
  )

  func makeCalculator(
    configuration: ChartIndicatorInstanceConfiguration,
    intervalMilliseconds: Int64
  ) -> (any ChartIndicatorCalculator)? {
    guard let calculator = AveragePriceIndicatorCalculator(
      intervalMilliseconds: intervalMilliseconds
    ) else {
      return nil
    }
    return AveragePriceChartIndicatorCalculator(
      calculator: calculator
    )
  }
}

private struct AveragePriceChartIndicatorCalculator:
  ChartIndicatorCalculator
{
  private var calculator: AveragePriceIndicatorCalculator

  init(calculator: AveragePriceIndicatorCalculator) {
    self.calculator = calculator
  }

  var lastCommittedOpenTime: Int64? {
    calculator.lastCommittedOpenTime
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
      legendColorToken: .ema21
    )
  }
}
