import Foundation

enum ChartPanelID {
  static let price = "price"
  static let volume = "volume"
  static let macd = "macd"
  static let rsi = "rsi"
  static let kdj = "kdj"
  static let obv = "obv"
  static let williamsR = "williams-r"
  static let stochasticRSI = "stochastic-rsi"
  static let atr = "atr"
  static let openInterest = "open-interest"
  static let topAccountRatio = "top-account-ratio"
  static let topPositionRatio = "top-position-ratio"
  static let globalAccountRatio = "global-account-ratio"
  static let buySellVolume = "buy-sell-volume"
  static let basis = "basis"
}

struct ChartPanelRect: Equatable, Sendable {
  let left: Float
  let top: Float
  let right: Float
  let bottom: Float

  var width: Float {
    right - left
  }

  var height: Float {
    bottom - top
  }

  var isValid: Bool {
    [left, top, right, bottom].allSatisfy(\.isFinite)
      && right > left
      && bottom > top
  }
}

struct ChartPanelFrame: Equatable, Sendable {
  let id: String
  let frame: ChartPanelRect
  let plot: ChartPanelRect
  let legendBaseline: Float
  let isPricePanel: Bool
}

struct ChartPanelLayout: Equatable, Sendable {
  static let pricePanelHeightPoints = 298.0
  static let pricePlotTopPoints = 30.0
  static let referencePricePlotHeightPoints =
    pricePanelHeightPoints - pricePlotTopPoints
  static let indicatorPanelHeightPoints = 72.0
  static let indicatorLegendHeightPoints = 16.0
  static let panelGapPoints = 2.0
  static let timeAxisHeightPoints = 24.0

  static func squareViewportHeightPoints(widthPoints: Double, indicatorPanelCount: Int) -> Double {
    let plotWidth = max(120, widthPoints - 4 - 58)
    return pricePlotTopPoints + plotWidth + timeAxisHeightPoints
      + Double(max(0, indicatorPanelCount)) * (panelGapPoints + indicatorPanelHeightPoints)
  }

  let panels: [ChartPanelFrame]
  let plotLeft: Float
  let plotRight: Float
  let timeAxisTop: Float
  let timeAxisBottom: Float

  var pricePanel: ChartPanelFrame? {
    panel(id: ChartPanelID.price)
  }

  var indicatorPanels: [ChartPanelFrame] {
    panels.filter { !$0.isPricePanel }
  }

  func panel(id: String) -> ChartPanelFrame? {
    panels.first { $0.id == id }
  }

  static func preferredViewportHeightPoints(
    indicatorPanelCount: Int
  ) -> Double {
    let count = max(0, indicatorPanelCount)
    return pricePanelHeightPoints
      + Double(count)
        * (panelGapPoints + indicatorPanelHeightPoints)
      + timeAxisHeightPoints
  }

  static func scrollContentHeightPoints(
    availableHeightPoints: Double,
    indicatorPanelCount: Int
  ) -> Double {
    let preferredHeight = preferredViewportHeightPoints(
      indicatorPanelCount: indicatorPanelCount
    )
    guard availableHeightPoints.isFinite, availableHeightPoints > 0 else {
      return preferredHeight
    }
    let overflowPanelCount = max(0, max(0, indicatorPanelCount) - 1)
    let overflowHeight = Double(overflowPanelCount)
      * (panelGapPoints + indicatorPanelHeightPoints)
    return max(
      preferredHeight,
      availableHeightPoints + overflowHeight
    )
  }

  static func indicatorPanelIDs(
    series: [ChartIndicatorSeriesHistory]
  ) -> [String] {
    series.reduce(into: [String]()) { result, item in
      guard case .panel(let id) = item.placement,
        !result.contains(id)
      else {
        return
      }
      result.append(id)
    }
  }

  static func make(
    viewport: ChartSceneViewport,
    indicatorPanelIDs: [String]
  ) -> ChartPanelLayout? {
    let uniqueIDs = indicatorPanelIDs.reduce(into: [String]()) {
      result, id in
      guard !id.isEmpty,
        id != ChartPanelID.price,
        !result.contains(id)
      else {
        return
      }
      result.append(id)
    }
    guard uniqueIDs.count == indicatorPanelIDs.count else {
      return nil
    }

    let width = Float(viewport.widthPixels)
    let height = Float(viewport.heightPixels)
    let scale = Float(viewport.displayScale)
    let plotLeft = 4 * scale
    let plotRight = width - 58 * scale
    let timeAxisHeight = Float(timeAxisHeightPoints) * scale
    let panelHeightBudget = height - timeAxisHeight
    let pricePlotTop = Float(pricePlotTopPoints) * scale
    let panelGap = Float(panelGapPoints) * scale
    guard plotRight - plotLeft >= 48 * scale,
      panelHeightBudget > pricePlotTop
    else {
      return nil
    }

    let panelCount = uniqueIDs.count
    let desiredIndicatorHeight =
      Float(indicatorPanelHeightPoints) * scale
    let minimumIndicatorHeight = 54 * scale
    let minimumPriceHeight = 120 * scale
    let totalGaps = Float(panelCount) * panelGap
    let maximumIndicatorTotal =
      panelHeightBudget
      - pricePlotTop
      - minimumPriceHeight
      - totalGaps
    let indicatorHeight: Float
    let priceBottom: Float
    let usesFixedPanelHeights: Bool
    if panelCount == 0 {
      indicatorHeight = 0
      priceBottom = panelHeightBudget
      usesFixedPanelHeights = true
    } else {
      let fixedPriceBottom =
        Float(pricePanelHeightPoints) * scale
      let requiredBottom = fixedPriceBottom
        + Float(panelCount)
          * (panelGap + desiredIndicatorHeight)
      usesFixedPanelHeights = panelHeightBudget >= requiredBottom
      if usesFixedPanelHeights {
        indicatorHeight = desiredIndicatorHeight
        priceBottom = panelHeightBudget
          - Float(panelCount) * (panelGap + desiredIndicatorHeight)
      } else {
        indicatorHeight = min(
          desiredIndicatorHeight,
          maximumIndicatorTotal / Float(panelCount)
        )
        priceBottom =
          panelHeightBudget
          - Float(panelCount) * indicatorHeight
          - totalGaps
      }
      guard indicatorHeight >= minimumIndicatorHeight else {
        return nil
      }
    }
    let priceFrame = ChartPanelFrame(
      id: ChartPanelID.price,
      frame: ChartPanelRect(
        left: 0,
        top: 0,
        right: width,
        bottom: priceBottom
      ),
      plot: ChartPanelRect(
        left: plotLeft,
        top: pricePlotTop,
        right: plotRight,
        bottom: priceBottom
      ),
      legendBaseline: 10.5 * scale,
      isPricePanel: true
    )
    guard priceFrame.frame.isValid,
      priceFrame.plot.isValid
    else {
      return nil
    }

    let timeAxisTop = priceBottom
    let timeAxisBottom = timeAxisTop + timeAxisHeight
    var panels = [priceFrame]
    var nextTop = timeAxisBottom
    for (index, id) in uniqueIDs.enumerated() {
      let top = nextTop + panelGap
      let bottom =
        !usesFixedPanelHeights
          && index == uniqueIDs.count - 1
        ? height
        : top + indicatorHeight
      let frame = ChartPanelFrame(
        id: id,
        frame: ChartPanelRect(
          left: 0,
          top: top,
          right: width,
          bottom: bottom
        ),
        plot: ChartPanelRect(
          left: plotLeft,
          top: top,
          right: plotRight,
          bottom: bottom - Float(indicatorLegendHeightPoints) * scale
        ),
        legendBaseline: bottom - 5 * scale,
        isPricePanel: false
      )
      guard frame.frame.isValid,
        frame.plot.isValid
      else {
        return nil
      }
      panels.append(frame)
      nextTop = bottom
    }

    return ChartPanelLayout(
      panels: panels,
      plotLeft: plotLeft,
      plotRight: plotRight,
      timeAxisTop: timeAxisTop,
      timeAxisBottom: timeAxisBottom
    )
  }
}
