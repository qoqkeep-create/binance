import Foundation

struct MACDIndicatorPoint: Equatable, Sendable {
  let openTime: Int64
  let dif: Double?
  let dea: Double?
  let histogram: Double?
  let difValidity: IndicatorPointValidity
  let deaValidity: IndicatorPointValidity
  let histogramValidity: IndicatorPointValidity
}

private enum MACDScalarEMAAppendResult: Equatable, Sendable {
  case warmup
  case value(Double)
  case invalid
}

private struct MACDScalarEMA: Equatable, Sendable {
  let period: Int
  private(set) var sampleCount = 0
  private(set) var seedSum = 0.0
  private(set) var value: Double?

  mutating func append(
    _ sample: Double
  ) -> MACDScalarEMAAppendResult {
    guard sample.isFinite else {
      return .invalid
    }
    if let value {
      let alpha = 2 / Double(period + 1)
      let next = value + alpha * (sample - value)
      let nextCount = sampleCount.addingReportingOverflow(1)
      guard next.isFinite,
        !nextCount.overflow
      else {
        return .invalid
      }
      sampleCount = nextCount.partialValue
      self.value = next
      return .value(next)
    }

    let nextCount = sampleCount.addingReportingOverflow(1)
    let nextSum = seedSum + sample
    guard !nextCount.overflow,
      nextSum.isFinite
    else {
      return .invalid
    }
    sampleCount = nextCount.partialValue
    seedSum = nextSum
    guard sampleCount >= period else {
      return .warmup
    }
    let seeded = seedSum / Double(period)
    guard seeded.isFinite else {
      return .invalid
    }
    value = seeded
    return .value(seeded)
  }
}

struct MACDIndicatorCalculator: Sendable {
  let fastPeriod: Int
  let slowPeriod: Int
  let signalPeriod: Int
  let intervalMilliseconds: Int64

  private var fastEMA: EMAIndicatorCalculator
  private var slowEMA: EMAIndicatorCalculator
  private var signalEMA: MACDScalarEMA
  private(set) var lastCommittedOpenTime: Int64?

  init?(
    fastPeriod: Int,
    slowPeriod: Int,
    signalPeriod: Int,
    intervalMilliseconds: Int64
  ) {
    guard fastPeriod > 0,
      slowPeriod > fastPeriod,
      signalPeriod > 0,
      intervalMilliseconds > 0,
      let fastEMA = EMAIndicatorCalculator(
        period: fastPeriod,
        intervalMilliseconds: intervalMilliseconds
      ),
      let slowEMA = EMAIndicatorCalculator(
        period: slowPeriod,
        intervalMilliseconds: intervalMilliseconds
      )
    else {
      return nil
    }
    self.fastPeriod = fastPeriod
    self.slowPeriod = slowPeriod
    self.signalPeriod = signalPeriod
    self.intervalMilliseconds = intervalMilliseconds
    self.fastEMA = fastEMA
    self.slowEMA = slowEMA
    signalEMA = MACDScalarEMA(period: signalPeriod)
  }

  @discardableResult
  mutating func commit(
    _ candle: ChartCandle
  ) -> MACDIndicatorPoint {
    guard candle.closure == .closed,
      candle.isValid,
      candle.closePrice.isFinite
    else {
      return invalidPoint(
        openTime: candle.openTime,
        validity: .invalid
      )
    }

    if let lastCommittedOpenTime {
      guard candle.openTime > lastCommittedOpenTime else {
        return invalidPoint(
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
        restart(with: candle)
        return invalidPoint(
          openTime: candle.openTime,
          validity: .dataGap
        )
      }
    }

    var candidate = self
    let point = candidate.advance(with: candle)
    if point.difValidity != .invalid {
      self = candidate
    }
    return point
  }

  func provisional(
    _ candle: ChartCandle?
  ) -> MACDIndicatorPoint? {
    guard let candle else {
      return nil
    }
    guard candle.closure != .closed,
      candle.isValid,
      candle.closePrice.isFinite
    else {
      return invalidPoint(
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
        return invalidPoint(
          openTime: candle.openTime,
          validity: candle.openTime > lastCommittedOpenTime
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
    guard
      let nextFast = EMAIndicatorCalculator(
        period: fastPeriod,
        intervalMilliseconds: intervalMilliseconds
      ),
      let nextSlow = EMAIndicatorCalculator(
        period: slowPeriod,
        intervalMilliseconds: intervalMilliseconds
      )
    else {
      return
    }
    fastEMA = nextFast
    slowEMA = nextSlow
    signalEMA = MACDScalarEMA(period: signalPeriod)
    _ = fastEMA.commit(candle)
    _ = slowEMA.commit(candle)
    lastCommittedOpenTime = candle.openTime
  }

  private mutating func advance(
    with candle: ChartCandle
  ) -> MACDIndicatorPoint {
    let fast = fastEMA.commit(candle)
    let slow = slowEMA.commit(candle)
    guard fast.validity != .invalid,
      slow.validity != .invalid
    else {
      return invalidPoint(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    lastCommittedOpenTime = candle.openTime

    guard fast.validity == .valid,
      slow.validity == .valid,
      let fastValue = fast.value,
      let slowValue = slow.value
    else {
      return MACDIndicatorPoint(
        openTime: candle.openTime,
        dif: nil,
        dea: nil,
        histogram: nil,
        difValidity: .warmup,
        deaValidity: .warmup,
        histogramValidity: .warmup
      )
    }

    let dif = fastValue - slowValue
    guard dif.isFinite else {
      return invalidPoint(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    let signalResult = signalEMA.append(dif)
    guard signalResult != .invalid else {
      return invalidPoint(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    guard case .value(let dea) = signalResult else {
      return MACDIndicatorPoint(
        openTime: candle.openTime,
        dif: dif,
        dea: nil,
        histogram: nil,
        difValidity: .valid,
        deaValidity: .warmup,
        histogramValidity: .warmup
      )
    }
    let histogram = 2 * (dif - dea)
    guard histogram.isFinite else {
      return invalidPoint(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    return MACDIndicatorPoint(
      openTime: candle.openTime,
      dif: dif,
      dea: dea,
      histogram: histogram,
      difValidity: .valid,
      deaValidity: .valid,
      histogramValidity: .valid
    )
  }

  private func invalidPoint(
    openTime: Int64,
    validity: IndicatorPointValidity
  ) -> MACDIndicatorPoint {
    MACDIndicatorPoint(
      openTime: openTime,
      dif: nil,
      dea: nil,
      histogram: nil,
      difValidity: validity,
      deaValidity: validity,
      histogramValidity: validity
    )
  }
}

struct MACDChartIndicatorPlugin: ChartIndicatorPlugin {
  let descriptor = ChartIndicatorDescriptor(
    id: "macd",
    displayName: "MACD",
    definitionVersion: 1,
    placement: .panel("macd"),
    parameters: [
      ChartIndicatorParameterDescriptor(
        id: "fastPeriod",
        displayName: "快线周期",
        defaultValue: 12,
        range: 1...200,
        step: 1
      ),
      ChartIndicatorParameterDescriptor(
        id: "slowPeriod",
        displayName: "慢线周期",
        defaultValue: 26,
        range: 2...500,
        step: 1
      ),
      ChartIndicatorParameterDescriptor(
        id: "signalPeriod",
        displayName: "信号周期",
        defaultValue: 9,
        range: 1...200,
        step: 1
      ),
    ],
    outputs: [
      ChartIndicatorOutputDescriptor(
        id: "dif",
        displayName: "DIF",
        colorToken: .positive,
        lineWidthPoints: 0.8,
        autoscale: .included
      ),
      ChartIndicatorOutputDescriptor(
        id: "dea",
        displayName: "DEA",
        colorToken: .ema144,
        lineWidthPoints: 0.8,
        autoscale: .included
      ),
      ChartIndicatorOutputDescriptor(
        id: "histogram",
        displayName: "MACD",
        colorToken: .macdHistogram,
        lineWidthPoints: 1,
        autoscale: .included,
        figureStyle: .histogramFromZero(
          colorStrategy: .valueSign
        )
      ),
    ],
    warmupCount: 34,
    yAxisPolicy: .automatic,
    allowsMultipleInstances: false
  )

  func makeCalculator(
    configuration: ChartIndicatorInstanceConfiguration,
    intervalMilliseconds: Int64
  ) -> (any ChartIndicatorCalculator)? {
    let rawFast = configuration.parameters["fastPeriod"] ?? 12
    let rawSlow = configuration.parameters["slowPeriod"] ?? 26
    let rawSignal = configuration.parameters["signalPeriod"] ?? 9
    guard rawFast.rounded() == rawFast,
      rawSlow.rounded() == rawSlow,
      rawSignal.rounded() == rawSignal,
      rawFast >= 1,
      rawSlow > rawFast,
      rawSlow <= 500,
      rawSignal >= 1,
      rawSignal <= 200,
      let calculator = MACDIndicatorCalculator(
        fastPeriod: Int(rawFast),
        slowPeriod: Int(rawSlow),
        signalPeriod: Int(rawSignal),
        intervalMilliseconds: intervalMilliseconds
      )
    else {
      return nil
    }
    return MACDChartIndicatorCalculator(
      calculator: calculator
    )
  }
}

private struct MACDChartIndicatorCalculator:
  ChartIndicatorCalculator
{
  private var calculator: MACDIndicatorCalculator

  init(calculator: MACDIndicatorCalculator) {
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
    _ point: MACDIndicatorPoint
  ) -> ChartIndicatorPluginComputation {
    let histogramColor: ChartIndicatorColorToken
    if let histogram = point.histogram {
      histogramColor = histogram >= 0 ? .positive : .negative
    } else {
      histogramColor = .neutral
    }
    return ChartIndicatorPluginComputation(
      points: [
        "dif": IndicatorPoint(
          openTime: point.openTime,
          value: point.dif,
          validity: point.difValidity
        ),
        "dea": IndicatorPoint(
          openTime: point.openTime,
          value: point.dea,
          validity: point.deaValidity
        ),
        "histogram": IndicatorPoint(
          openTime: point.openTime,
          value: point.histogram,
          validity: point.histogramValidity
        ),
      ],
      legendValue: point.histogram,
      legendColorToken: histogramColor,
      legendComponents: [
        ChartIndicatorLegendComponent(
          id: "dif",
          label: "DIF:",
          value: point.dif,
          labelColorToken: .positive,
          colorToken: .positive,
          order: 0
        ),
        ChartIndicatorLegendComponent(
          id: "dea",
          label: "DEA:",
          value: point.dea,
          labelColorToken: .ema144,
          colorToken: .ema144,
          order: 1
        ),
        ChartIndicatorLegendComponent(
          id: "histogram",
          label: "MACD:",
          value: point.histogram,
          labelColorToken: .neutral,
          colorToken: histogramColor,
          order: 2
        ),
      ]
    )
  }
}
