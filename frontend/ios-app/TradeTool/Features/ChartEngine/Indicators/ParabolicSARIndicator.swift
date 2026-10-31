import Foundation

struct ParabolicSARCommittedState: Equatable, Sendable {
  let start: Double
  let maximum: Double
  fileprivate(set) var sampleCount: Int = 0
  fileprivate(set) var isRising: Bool?
  fileprivate(set) var value: Double?
  fileprivate(set) var extreme: Double?
  fileprivate(set) var acceleration: Double?
  fileprivate(set) var previousHigh: Double?
  fileprivate(set) var previousLow: Double?
  fileprivate(set) var secondPreviousHigh: Double?
  fileprivate(set) var secondPreviousLow: Double?
  fileprivate(set) var lastOpenTime: Int64?
}

struct ParabolicSARIndicatorCalculator: Sendable {
  let intervalMilliseconds: Int64
  private(set) var committed: ParabolicSARCommittedState

  init?(
    start: Double,
    maximum: Double,
    intervalMilliseconds: Int64
  ) {
    guard start.isFinite,
      maximum.isFinite,
      start > 0,
      maximum >= start,
      intervalMilliseconds > 0
    else {
      return nil
    }
    self.intervalMilliseconds = intervalMilliseconds
    committed = ParabolicSARCommittedState(
      start: start,
      maximum: maximum
    )
  }

  @discardableResult
  mutating func commit(_ candle: ChartCandle) -> IndicatorPoint {
    guard candle.closure == .closed, candle.isValid else {
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
    guard candle.closure != .closed, candle.isValid else {
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
    let start = committed.start
    let maximum = committed.maximum
    committed = ParabolicSARCommittedState(
      start: start,
      maximum: maximum,
      sampleCount: 1,
      previousHigh: candle.highPrice,
      previousLow: candle.lowPrice,
      lastOpenTime: candle.openTime
    )
  }

  private mutating func advanceCommitted(
    with candle: ChartCandle
  ) -> IndicatorPoint {
    guard let previousHigh = committed.previousHigh,
      let previousLow = committed.previousLow
    else {
      committed.sampleCount = 1
      committed.previousHigh = candle.highPrice
      committed.previousLow = candle.lowPrice
      committed.lastOpenTime = candle.openTime
      return IndicatorPoint(
        openTime: candle.openTime,
        value: nil,
        validity: .warmup
      )
    }

    if committed.sampleCount == 1 {
      let plusMovement = candle.highPrice - previousHigh
      let minusMovement = previousLow - candle.lowPrice
      let isRising = plusMovement >= minusMovement
      let value = isRising
        ? min(previousLow, candle.lowPrice)
        : max(previousHigh, candle.highPrice)
      let extreme = isRising
        ? max(previousHigh, candle.highPrice)
        : min(previousLow, candle.lowPrice)
      guard value.isFinite, extreme.isFinite else {
        return invalidPoint(for: candle.openTime)
      }
      committed.sampleCount = 2
      committed.isRising = isRising
      committed.value = value
      committed.extreme = extreme
      committed.acceleration = committed.start
      shiftPreviousCandle(with: candle)
      return IndicatorPoint(
        openTime: candle.openTime,
        value: value,
        validity: .valid
      )
    }

    guard let wasRising = committed.isRising,
      let previousValue = committed.value,
      var extreme = committed.extreme,
      var acceleration = committed.acceleration
    else {
      return invalidPoint(for: candle.openTime)
    }
    var value = previousValue
      + acceleration * (extreme - previousValue)
    var isRising = wasRising

    if wasRising {
      value = min(value, previousLow)
      if let secondPreviousLow = committed.secondPreviousLow {
        value = min(value, secondPreviousLow)
      }
      if candle.lowPrice < value {
        isRising = false
        value = extreme
        extreme = candle.lowPrice
        acceleration = committed.start
      } else if candle.highPrice > extreme {
        extreme = candle.highPrice
        acceleration = min(
          committed.maximum,
          acceleration + committed.start
        )
      }
    } else {
      value = max(value, previousHigh)
      if let secondPreviousHigh = committed.secondPreviousHigh {
        value = max(value, secondPreviousHigh)
      }
      if candle.highPrice > value {
        isRising = true
        value = extreme
        extreme = candle.highPrice
        acceleration = committed.start
      } else if candle.lowPrice < extreme {
        extreme = candle.lowPrice
        acceleration = min(
          committed.maximum,
          acceleration + committed.start
        )
      }
    }

    guard value.isFinite,
      extreme.isFinite,
      acceleration.isFinite
    else {
      return invalidPoint(for: candle.openTime)
    }
    committed.sampleCount &+= 1
    committed.isRising = isRising
    committed.value = value
    committed.extreme = extreme
    committed.acceleration = acceleration
    shiftPreviousCandle(with: candle)
    return IndicatorPoint(
      openTime: candle.openTime,
      value: value,
      validity: .valid
    )
  }

  private mutating func shiftPreviousCandle(with candle: ChartCandle) {
    committed.secondPreviousHigh = committed.previousHigh
    committed.secondPreviousLow = committed.previousLow
    committed.previousHigh = candle.highPrice
    committed.previousLow = candle.lowPrice
    committed.lastOpenTime = candle.openTime
  }

  private func invalidPoint(for openTime: Int64) -> IndicatorPoint {
    IndicatorPoint(
      openTime: openTime,
      value: nil,
      validity: .invalid
    )
  }
}

struct ParabolicSARChartIndicatorPlugin: ChartIndicatorPlugin {
  let descriptor = ChartIndicatorDescriptor(
    id: "parabolic-sar",
    displayName: "SAR",
    definitionVersion: 1,
    placement: .priceOverlay,
    parameters: [
      ChartIndicatorParameterDescriptor(
        id: "start",
        displayName: "开始",
        defaultValue: 0.02,
        range: 0.001...1,
        step: 0.001
      ),
      ChartIndicatorParameterDescriptor(
        id: "maximum",
        displayName: "最大",
        defaultValue: 0.2,
        range: 0.001...5,
        step: 0.001
      ),
    ],
    outputs: [
      ChartIndicatorOutputDescriptor(
        id: "value",
        displayName: "SAR",
        colorToken: .ema21,
        lineWidthPoints: 0.65,
        autoscale: .included,
        figureStyle: .hollowSquareMarker(sizePoints: 2.7)
      )
    ],
    warmupCount: 2,
    yAxisPolicy: .sharedPrice,
    allowsMultipleInstances: false
  )

  func makeCalculator(
    configuration: ChartIndicatorInstanceConfiguration,
    intervalMilliseconds: Int64
  ) -> (any ChartIndicatorCalculator)? {
    let start = configuration.parameters["start"] ?? 0.02
    let maximum = configuration.parameters["maximum"] ?? 0.2
    guard let calculator = ParabolicSARIndicatorCalculator(
      start: start,
      maximum: maximum,
      intervalMilliseconds: intervalMilliseconds
    ) else {
      return nil
    }
    return ParabolicSARChartIndicatorCalculator(
      calculator: calculator
    )
  }
}

private struct ParabolicSARChartIndicatorCalculator:
  ChartIndicatorCalculator
{
  private var calculator: ParabolicSARIndicatorCalculator

  init(calculator: ParabolicSARIndicatorCalculator) {
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
      legendColorToken: .ema21
    )
  }
}
