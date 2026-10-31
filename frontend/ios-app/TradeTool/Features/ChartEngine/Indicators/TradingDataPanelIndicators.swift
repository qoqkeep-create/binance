import Foundation

enum TradingDataPanelIndicatorKind: Sendable {
  case openInterest
  case topAccountRatio
  case topPositionRatio
  case globalAccountRatio
  case buySellVolume
  case basis

  var descriptor: ChartIndicatorDescriptor {
    switch self {
    case .openInterest:
      return ChartIndicatorDescriptor(
        id: "open-interest",
        displayName: "O.I.",
        definitionVersion: 1,
        placement: .panel(ChartPanelID.openInterest),
        parameters: [],
        outputs: [
          Self.output(
            "openInterest",
            "O.I.",
            .positive,
            .histogramFromZero(colorStrategy: .fixed)
          ),
          Self.output("notional", "O.I. NV", .ema21, .line),
        ],
        warmupCount: 0,
        yAxisPolicy: .automatic,
        allowsMultipleInstances: false
      )
    case .topAccountRatio:
      return Self.ratioDescriptor(
        id: "top-account-ratio",
        name: "L.S Acco.",
        panelID: ChartPanelID.topAccountRatio
      )
    case .topPositionRatio:
      return Self.ratioDescriptor(
        id: "top-position-ratio",
        name: "L.S Posit.",
        panelID: ChartPanelID.topPositionRatio
      )
    case .globalAccountRatio:
      return Self.ratioDescriptor(
        id: "global-account-ratio",
        name: "L.S Ratio",
        panelID: ChartPanelID.globalAccountRatio
      )
    case .buySellVolume:
      return ChartIndicatorDescriptor(
        id: "buy-sell-volume",
        displayName: "B.S Vol.",
        definitionVersion: 1,
        placement: .panel(ChartPanelID.buySellVolume),
        parameters: [],
        outputs: [
          Self.output(
            "buy",
            "B",
            .positive,
            .pairedHistogramFromZero(
              colorStrategy: .fixed,
              position: .leading
            )
          ),
          Self.output(
            "sell",
            "S",
            .negative,
            .pairedHistogramFromZero(
              colorStrategy: .fixed,
              position: .trailing
            )
          ),
        ],
        warmupCount: 0,
        yAxisPolicy: .automatic,
        allowsMultipleInstances: false
      )
    case .basis:
      return ChartIndicatorDescriptor(
        id: "basis",
        displayName: "Basis",
        definitionVersion: 1,
        placement: .panel(ChartPanelID.basis),
        parameters: [],
        outputs: [
          Self.output(
            "basis",
            "Basis",
            .ema21,
            .areaFromZero(fillAlpha: 0.72)
          ),
          Self.output("basisRate", "BR", .orange, .line),
          Self.output("futuresPremium", "FP", .ema55, .line),
          Self.output("indexPremium", "PI", .positive, .line),
        ],
        warmupCount: 0,
        yAxisPolicy: .automatic,
        allowsMultipleInstances: false
      )
    }
  }

  private static func ratioDescriptor(
    id: String,
    name: String,
    panelID: String
  ) -> ChartIndicatorDescriptor {
    ChartIndicatorDescriptor(
      id: id,
      displayName: name,
      definitionVersion: 1,
      placement: .panel(panelID),
      parameters: [],
      outputs: [
        output(
          "total",
          "S",
          .negative,
          .histogramFromZero(colorStrategy: .fixed)
        ),
        output(
          "long",
          "L",
          .positive,
          .histogramFromZero(colorStrategy: .fixed)
        ),
        output("ratio", name, .ema21, .line),
      ],
      warmupCount: 0,
      yAxisPolicy: .automatic,
      allowsMultipleInstances: false
    )
  }

  private static func output(
    _ id: String,
    _ name: String,
    _ color: ChartIndicatorColorToken,
    _ style: ChartIndicatorFigureStyle
  ) -> ChartIndicatorOutputDescriptor {
    ChartIndicatorOutputDescriptor(
      id: id,
      displayName: name,
      colorToken: color,
      lineWidthPoints: 0.8,
      autoscale: .included,
      figureStyle: style
    )
  }
}

struct TradingDataPanelChartIndicatorPlugin: ChartIndicatorPlugin {
  let kind: TradingDataPanelIndicatorKind

  var descriptor: ChartIndicatorDescriptor {
    kind.descriptor
  }

  func makeCalculator(
    configuration: ChartIndicatorInstanceConfiguration,
    intervalMilliseconds: Int64
  ) -> (any ChartIndicatorCalculator)? {
    guard configuration.parameters.isEmpty,
      intervalMilliseconds > 0
    else {
      return nil
    }
    return TradingDataPanelChartIndicatorCalculator(
      kind: kind,
      intervalMilliseconds: intervalMilliseconds
    )
  }
}

private struct TradingDataPanelChartIndicatorCalculator:
  ChartIndicatorCalculator
{
  let kind: TradingDataPanelIndicatorKind
  let intervalMilliseconds: Int64
  private(set) var lastCommittedOpenTime: Int64?

  mutating func commit(
    _ candle: ChartCandle
  ) -> ChartIndicatorPluginComputation {
    guard candle.closure == .closed,
      candle.isValid
    else {
      return empty(
        openTime: candle.openTime,
        validity: .invalid
      )
    }
    if let lastCommittedOpenTime {
      guard candle.openTime > lastCommittedOpenTime else {
        return empty(
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
        self.lastCommittedOpenTime = candle.openTime
        return empty(
          openTime: candle.openTime,
          validity: .dataGap
        )
      }
    }
    lastCommittedOpenTime = candle.openTime
    return computation(candle)
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
      return empty(
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
        return empty(
          openTime: candle.openTime,
          validity: candle.openTime > lastCommittedOpenTime
            ? .dataGap
            : .invalid
        )
      }
    }
    return computation(candle)
  }

  private func computation(
    _ candle: ChartCandle
  ) -> ChartIndicatorPluginComputation {
    guard let data = candle.tradingData else {
      return empty(openTime: candle.openTime, validity: .hidden)
    }
    switch kind {
    case .openInterest:
      return openInterest(data, candle: candle)
    case .topAccountRatio:
      return ratio(
        long: data.topLongAccount,
        short: data.topShortAccount,
        ratio: data.topLongShortAccountRatio,
        title: "L.S Acco.:",
        candle: candle
      )
    case .topPositionRatio:
      return ratio(
        long: data.topLongPosition,
        short: data.topShortPosition,
        ratio: data.topLongShortPositionRatio,
        title: "L.S Posit.:",
        candle: candle
      )
    case .globalAccountRatio:
      return ratio(
        long: data.globalLongAccount,
        short: data.globalShortAccount,
        ratio: data.globalLongShortAccountRatio,
        title: "L.S Ratio:",
        candle: candle
      )
    case .buySellVolume:
      return buySellVolume(data, candle: candle)
    case .basis:
      return basis(data, candle: candle)
    }
  }

  private func openInterest(
    _ data: MarketChartTradingData,
    candle: ChartCandle
  ) -> ChartIndicatorPluginComputation {
    let normalizedNotional = finite(data.openInterestNotional).flatMap {
      candle.closePrice > 0 ? $0 / candle.closePrice : nil
    }
    return ChartIndicatorPluginComputation(
      points: [
        "openInterest": point(
          candle.openTime,
          finite(data.openInterest)
        ),
        "notional": point(candle.openTime, normalizedNotional),
      ],
      legendValue: finite(data.openInterest),
      legendColorToken: .positive,
      legendComponents: [
        component(
          "openInterest",
          "O.i.:",
          finite(data.openInterest),
          .positive,
          0
        ),
        component(
          "notional",
          "O.I. NV:",
          finite(data.openInterestNotional),
          .ema21,
          1
        ),
      ]
    )
  }

  private func ratio(
    long: Double?,
    short: Double?,
    ratio: Double?,
    title: String,
    candle: ChartCandle
  ) -> ChartIndicatorPluginComputation {
    let long = finite(long)
    let short = finite(short)
    let ratio = finite(ratio)
    let total: Double? = if let long, let short {
      long + short
    } else {
      nil
    }
    return ChartIndicatorPluginComputation(
      points: [
        "total": point(candle.openTime, total),
        "long": point(candle.openTime, long),
        "ratio": point(candle.openTime, ratio),
      ],
      legendValue: ratio,
      legendColorToken: .ema21,
      legendComponents: [
        component("ratio", title, ratio, .ema21, 0),
        component(
          "long",
          "L:",
          long.map { $0 * 100 },
          .positive,
          1
        ),
        component(
          "short",
          "S:",
          short.map { $0 * 100 },
          .negative,
          2
        ),
      ]
    )
  }

  private func buySellVolume(
    _ data: MarketChartTradingData,
    candle: ChartCandle
  ) -> ChartIndicatorPluginComputation {
    let buy = finite(data.takerBuyVolume)
    let sell = finite(data.takerSellVolume)
    return ChartIndicatorPluginComputation(
      points: [
        "buy": point(candle.openTime, buy),
        "sell": point(candle.openTime, sell),
      ],
      legendValue: buy,
      legendColorToken: .positive,
      legendComponents: [
        component("buy", "B:", buy, .positive, 0),
        component("sell", "S:", sell, .negative, 1),
      ]
    )
  }

  private func basis(
    _ data: MarketChartTradingData,
    candle: ChartCandle
  ) -> ChartIndicatorPluginComputation {
    let basis = finite(data.basis)
    let referencePrice = finite(data.indexPrice)
      ?? finite(data.futuresPrice)
      ?? candle.closePrice
    let basisRateDelta = finite(data.basisRate).map {
      $0 * referencePrice
    }
    let futuresPremium = finite(data.futuresPrice).map {
      $0 - candle.closePrice
    }
    let indexPremium = finite(data.indexPrice).map {
      $0 - candle.closePrice
    }
    return ChartIndicatorPluginComputation(
      points: [
        "basis": point(candle.openTime, basis),
        "basisRate": point(candle.openTime, basisRateDelta),
        "futuresPremium": point(candle.openTime, futuresPremium),
        "indexPremium": point(candle.openTime, indexPremium),
      ],
      legendValue: basis,
      legendColorToken: .ema21,
      legendComponents: [
        component("basis", "Basis:", basis, .ema21, 0),
        component(
          "basisRate",
          "BR:",
          finite(data.basisRate),
          .orange,
          1
        ),
        component(
          "futuresPrice",
          "FP:",
          finite(data.futuresPrice),
          .ema55,
          2
        ),
        component(
          "indexPrice",
          "PI:",
          finite(data.indexPrice),
          .positive,
          3
        ),
      ]
    )
  }

  private func empty(
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

  private func point(
    _ openTime: Int64,
    _ value: Double?
  ) -> IndicatorPoint {
    IndicatorPoint(
      openTime: openTime,
      value: value,
      validity: value == nil ? .hidden : .valid
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

  private func finite(_ value: Double?) -> Double? {
    guard let value, value.isFinite else {
      return nil
    }
    return value
  }
}
