import Foundation

struct VolumeIndicatorPoint: Equatable, Sendable {
  let openTime: Int64
  let volume: Double?
  let fastAverage: Double?
  let slowAverage: Double?
  let volumeValidity: IndicatorPointValidity
  let fastAverageValidity: IndicatorPointValidity
  let slowAverageValidity: IndicatorPointValidity
  let isRising: Bool?
}

struct VolumeIndicatorCommittedState: Equatable, Sendable {
  let fastPeriod: Int
  let slowPeriod: Int
  fileprivate(set) var samples: [Double] = []
  fileprivate(set) var lastOpenTime: Int64?
}

struct VolumeIndicatorCalculator: Sendable {
  let intervalMilliseconds: Int64
  private(set) var committed: VolumeIndicatorCommittedState

  init?(
    fastPeriod: Int,
    slowPeriod: Int,
    intervalMilliseconds: Int64
  ) {
    guard fastPeriod > 0,
      slowPeriod >= fastPeriod,
      intervalMilliseconds > 0
    else {
      return nil
    }
    self.intervalMilliseconds = intervalMilliseconds
    committed = VolumeIndicatorCommittedState(
      fastPeriod: fastPeriod,
      slowPeriod: slowPeriod
    )
  }

  @discardableResult
  mutating func commit(
    _ candle: ChartCandle
  ) -> VolumeIndicatorPoint {
    guard candle.closure == .closed,
      candle.isValid,
      candle.volume.isFinite,
      candle.volume >= 0
    else {
      return invalidPoint(
        openTime: candle.openTime,
        validity: .invalid
      )
    }

    if let lastOpenTime = committed.lastOpenTime {
      guard candle.openTime > lastOpenTime else {
        return invalidPoint(
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
        return invalidPoint(
          openTime: candle.openTime,
          validity: .dataGap
        )
      }
    }

    var candidate = self
    let point = candidate.advance(with: candle)
    if point.volumeValidity != .invalid {
      self = candidate
    }
    return point
  }

  func provisional(
    _ candle: ChartCandle?
  ) -> VolumeIndicatorPoint? {
    guard let candle else {
      return nil
    }
    guard candle.closure != .closed,
      candle.isValid,
      candle.volume.isFinite,
      candle.volume >= 0
    else {
      return invalidPoint(
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
        return invalidPoint(
          openTime: candle.openTime,
          validity: candle.openTime > lastOpenTime
            ? .dataGap
            : .invalid
        )
      }
    }

    var temporary = self
    return temporary.advance(
      with: candle.withClosure(.closed)
    )
  }

  private mutating func restart(
    with candle: ChartCandle
  ) {
    committed.samples = [candle.volume]
    committed.lastOpenTime = candle.openTime
  }

  private mutating func advance(
    with candle: ChartCandle
  ) -> VolumeIndicatorPoint {
    committed.samples.append(candle.volume)
    if committed.samples.count > committed.slowPeriod {
      committed.samples.removeFirst(
        committed.samples.count - committed.slowPeriod
      )
    }
    committed.lastOpenTime = candle.openTime

    let fastAverage = average(
      suffix: committed.fastPeriod
    )
    let slowAverage = average(
      suffix: committed.slowPeriod
    )
    guard fastAverage?.isFinite != false,
      slowAverage?.isFinite != false
    else {
      return invalidPoint(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    return VolumeIndicatorPoint(
      openTime: candle.openTime,
      volume: candle.volume,
      fastAverage: fastAverage,
      slowAverage: slowAverage,
      volumeValidity: .valid,
      fastAverageValidity: fastAverage == nil
        ? .warmup
        : .valid,
      slowAverageValidity: slowAverage == nil
        ? .warmup
        : .valid,
      isRising: candle.closePrice >= candle.openPrice
    )
  }

  private func average(
    suffix count: Int
  ) -> Double? {
    guard committed.samples.count >= count else {
      return nil
    }
    let sum = committed.samples.suffix(count).reduce(0, +)
    let result = sum / Double(count)
    return result.isFinite ? result : nil
  }

  private func invalidPoint(
    openTime: Int64,
    validity: IndicatorPointValidity
  ) -> VolumeIndicatorPoint {
    VolumeIndicatorPoint(
      openTime: openTime,
      volume: nil,
      fastAverage: nil,
      slowAverage: nil,
      volumeValidity: validity,
      fastAverageValidity: validity,
      slowAverageValidity: validity,
      isRising: nil
    )
  }
}

struct VolumeChartIndicatorPlugin: ChartIndicatorPlugin {
  let descriptor = ChartIndicatorDescriptor(
    id: "volume",
    displayName: "VOL",
    definitionVersion: 1,
    placement: .panel("volume"),
    parameters: [
      ChartIndicatorParameterDescriptor(
        id: "fastPeriod",
        displayName: "快速均量周期",
        defaultValue: 5,
        range: 1...200,
        step: 1
      ),
      ChartIndicatorParameterDescriptor(
        id: "slowPeriod",
        displayName: "慢速均量周期",
        defaultValue: 10,
        range: 1...500,
        step: 1
      ),
    ],
    outputs: [
      ChartIndicatorOutputDescriptor(
        id: "volume",
        displayName: "VOL",
        colorToken: .neutral,
        lineWidthPoints: 1,
        autoscale: .included,
        figureStyle: .histogramFromZero(
          colorStrategy: .candleDirection
        )
      ),
      ChartIndicatorOutputDescriptor(
        id: "fastAverage",
        displayName: "MA5",
        colorToken: .ema21,
        lineWidthPoints: 0.8,
        autoscale: .included
      ),
      ChartIndicatorOutputDescriptor(
        id: "slowAverage",
        displayName: "MA10",
        colorToken: .ema144,
        lineWidthPoints: 0.8,
        autoscale: .included
      ),
    ],
    warmupCount: 10,
    yAxisPolicy: .automatic,
    allowsMultipleInstances: false
  )

  func makeCalculator(
    configuration: ChartIndicatorInstanceConfiguration,
    intervalMilliseconds: Int64
  ) -> (any ChartIndicatorCalculator)? {
    let rawFast = configuration.parameters["fastPeriod"] ?? 5
    let rawSlow = configuration.parameters["slowPeriod"] ?? 10
    guard rawFast.rounded() == rawFast,
      rawSlow.rounded() == rawSlow,
      rawFast >= 1,
      rawSlow >= rawFast,
      rawSlow <= 500,
      let calculator = VolumeIndicatorCalculator(
        fastPeriod: Int(rawFast),
        slowPeriod: Int(rawSlow),
        intervalMilliseconds: intervalMilliseconds
      )
    else {
      return nil
    }
    return VolumeChartIndicatorCalculator(
      calculator: calculator,
      fastPeriod: Int(rawFast),
      slowPeriod: Int(rawSlow)
    )
  }
}

private struct VolumeChartIndicatorCalculator:
  ChartIndicatorCalculator
{
  private var calculator: VolumeIndicatorCalculator
  private let fastPeriod: Int
  private let slowPeriod: Int

  init(
    calculator: VolumeIndicatorCalculator,
    fastPeriod: Int,
    slowPeriod: Int
  ) {
    self.calculator = calculator
    self.fastPeriod = fastPeriod
    self.slowPeriod = slowPeriod
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
    _ point: VolumeIndicatorPoint
  ) -> ChartIndicatorPluginComputation {
    let directionColor: ChartIndicatorColorToken
    if let isRising = point.isRising {
      directionColor = isRising ? .positive : .negative
    } else {
      directionColor = .neutral
    }
    return ChartIndicatorPluginComputation(
      points: [
        "volume": IndicatorPoint(
          openTime: point.openTime,
          value: point.volume,
          validity: point.volumeValidity
        ),
        "fastAverage": IndicatorPoint(
          openTime: point.openTime,
          value: point.fastAverage,
          validity: point.fastAverageValidity
        ),
        "slowAverage": IndicatorPoint(
          openTime: point.openTime,
          value: point.slowAverage,
          validity: point.slowAverageValidity
        ),
      ],
      legendValue: point.volume,
      legendColorToken: directionColor,
      legendComponents: [
        ChartIndicatorLegendComponent(
          id: "volume",
          label: "VOL:",
          value: point.volume,
          labelColorToken: .neutral,
          colorToken: directionColor,
          order: 0
        ),
        ChartIndicatorLegendComponent(
          id: "fastAverage",
          label: "MA(\(fastPeriod)):",
          value: point.fastAverage,
          labelColorToken: .ema21,
          colorToken: .ema21,
          order: 1
        ),
        ChartIndicatorLegendComponent(
          id: "slowAverage",
          label: "MA(\(slowPeriod)):",
          value: point.slowAverage,
          labelColorToken: .ema144,
          colorToken: .ema144,
          order: 2
        ),
      ]
    )
  }
}
