import XCTest
@testable import TradeTool

final class DisplayNumberTests: XCTestCase {
  func testDisplayBandsAndSignificantDigits() {
    let cases = [
      ("1234.5678", "1234.57"), ("100", "100.00"), ("99.12345", "99.123"),
      ("1", "1.000"), ("0.123456", "0.1235"), ("0.01", "0.01"),
      ("0.01050098", "0.0105"), ("0.01000057", "0.01"), ("0.001000057", "0.001"),
      ("0.000012345", "0.00001235"), ("0.00000000123456", "0.000000001235"),
      ("-25.005", "-25.005"), ("-0.00123456", "-0.001235"), ("0", "0")
    ]
    for (input, expected) in cases { XCTAssertEqual(DisplayNumber.text(input), expected, input) }
  }

  func testCarriesReevaluateTheDisplayBand() {
    for (input, expected) in [("99.9995", "100.00"), ("0.99995", "1.000"),
      ("0.0099995", "0.01"), ("-99.9995", "-100.00")] {
      XCTAssertEqual(DisplayNumber.text(input), expected, input)
    }
  }

  func testDecimalPrecisionGroupingAndSigns() {
    let original = Decimal(string: "123456789012345.125")!
    XCTAssertEqual(DisplayNumber.text(original, signed: true, grouped: true), "+123,456,789,012,345.13")
    XCTAssertEqual(original, Decimal(string: "123456789012345.125")!)
    XCTAssertEqual(DisplayNumber.text(-0.0, signed: true), "0")
    XCTAssertEqual(DisplayNumber.text("1e-20"), "0.00000000000000000001")
  }

  func testMissingOrNonfiniteValuesRemainUnavailable() {
    for input in ["", "--", "NaN", "Infinity", "12 USDT", "1,234.56", "abc"] {
      XCTAssertEqual(DisplayNumber.text(input), "--", input)
    }
    XCTAssertEqual(DisplayNumber.text(Double.nan), "--")
    XCTAssertEqual(DisplayNumber.text(Double.infinity), "--")
    XCTAssertEqual(DisplayNumber.text(Decimal.nan), "--")
    XCTAssertEqual(DisplayNumber.compact(.infinity), "--")
    XCTAssertEqual(DisplayNumber.turnover(.nan), "--")
  }

  func testMarketAndVolumeAdaptersUseSamePrecision() {
    XCTAssertEqual(DisplayNumber.text(0.000012345), "0.00001235")
    XCTAssertEqual(DisplayNumber.compact(12_345), "12.345K")
    XCTAssertEqual(DisplayNumber.turnover(123_456_789), "1.235亿")
    let market = MarketSnapshot(symbol: "TESTUSDT", quoteAsset: "USDT", price: 0.000012345,
      changePercent24h: -1.23456, updatedAt: .now)
    XCTAssertEqual(market.formattedPrice, "0.00001235")
    XCTAssertEqual(market.formattedChange, "-1.235%")
  }

  func testPositionAmountsRoundWithoutChangingPricesOrAddingZeroes() {
    for (input, digits, expected) in [
      ("12.345", 2, "12.35"), ("-12.345", 2, "-12.35"),
      ("10.000", 1, "10"), ("1.06", 1, "1.1"),
      ("0.004", 2, "0"), ("-0.004", 2, "0")
    ] {
      XCTAssertEqual(DisplayNumber.amount(Decimal(string: input)!, maximumFractionDigits: digits), expected)
    }
    XCTAssertEqual(DisplayNumber.text("0.000012345"), "0.00001235")
  }
}

final class WebRefreshInteractionTests: XCTestCase {
  func testReleaseBelowThresholdAndProgrammaticBounceDoNotRefresh() {
    var interaction = WebRefreshInteraction()
    interaction.update(distance: 100, dragging: false)
    XCTAssertFalse(interaction.release())
    interaction.update(distance: 69, dragging: true)
    XCTAssertFalse(interaction.release())
  }

  func testSeventyPointReleaseStartsOnlyOneReadUntilCompleted() {
    var interaction = WebRefreshInteraction()
    interaction.update(distance: 70, dragging: true)
    XCTAssertTrue(interaction.release())
    interaction.update(distance: 140, dragging: true)
    XCTAssertFalse(interaction.release())
    interaction.complete()
    interaction.update(distance: 70, dragging: true)
    XCTAssertTrue(interaction.release())
  }

  func testPullingBackBeforeReleaseDisarmsRefresh() {
    var interaction = WebRefreshInteraction()
    interaction.update(distance: 95, dragging: true)
    interaction.update(distance: 40, dragging: true)
    XCTAssertFalse(interaction.release())
    interaction.update(distance: -200, dragging: true)
    XCTAssertEqual(interaction.distance, 0)
  }
}

final class PositionEntryFeePresentationTests: XCTestCase {
  func testConfirmedFeeIsDisplayedWithoutAnEstimateIncludingZero() {
    XCTAssertEqual(PositionEntryFeePresentation.text(.object([
      "entry_fee_status": .string("confirmed"), "entry_realized_fee": .string("1.254"),
      "entry_fee_asset": .string("USDT"), "estimated_total_fee": .string("9")
    ])), "1.25 USDT")
    XCTAssertEqual(PositionEntryFeePresentation.text(.object([
      "entry_fee_status": .string("confirmed"), "entry_realized_fee": .string("1.255")
    ]), abbreviatedUnit: true), "1.26 U")
    XCTAssertEqual(PositionEntryFeePresentation.text(.object([
      "entry_fee_status": .string("confirmed"), "entry_realized_fee": .string("0")
    ]), abbreviatedUnit: true), "0 U")
  }

  func testUnconfirmedEntryUsesAnExplicitSingleSideEstimate() {
    for status in ["pending", "estimated", "failed", "confirmed"] {
      XCTAssertEqual(PositionEntryFeePresentation.text(.object([
        "entry_fee_status": .string(status), "estimated_total_fee": .string("8")
      ])), "估 -4 USDT")
    }
  }
}

final class PositionCardPresentationTests: XCTestCase {
  private func row(_ overrides: [String: JSONValue] = [:]) -> JSONValue {
    .object([
      "entry_fee_status": .string("pending"), "entry_fee_asset": .string("USDT"),
      "estimated_total_fee": .string("1"), "open_price": .string("100"),
      "current_price": .string("120"), "size": .string("10"),
      "exchange_size": .string("10")
    ].merging(overrides, uniquingKeysWith: { _, value in value }))
  }

  // The host runner also resolves these adapters from the actual position-card call sites.
  private func cardFee(_ row: JSONValue, price: Decimal? = nil) -> String { PositionCardPresentation.feeText(row, currentPrice: price) }
  private func cardProfit(_ profit: Decimal?) -> String { PositionCardPresentation.profitText(profit) }
  private func cardStrategyError(_ row: JSONValue) -> String { PositionCardPresentation.strategyErrorText(row) }

  func testOpeningStrategySummaryIsHiddenWhileActualFailuresRemainVisible() {
    for info in ["开仓绑定策略：策略 A", "限价成交绑定策略：策略 B", " 开仓绑定策略:策略 C "] {
      XCTAssertEqual(cardStrategyError(row(["latest_strategy_error": .string(info)])), "")
    }
    for failure in ["余额不足", "止损保护待恢复", "开仓绑定策略失败：余额不足"] {
      XCTAssertEqual(cardStrategyError(row(["latest_strategy_error": .string(failure)])), failure)
    }
  }

  func testPendingEntryAndTotalRemainEstimatesUntilEntryFeeIsConfirmed() {
    XCTAssertEqual(cardFee(row()), "估 -0.5 U（估总 -1.1 U）")
    XCTAssertEqual(cardFee(row([
      "entry_fee_status": .string("confirmed"), "entry_realized_fee": .string("-0.3")
    ])), "-0.3 U（估总 -0.9 U）")
  }

  func testConfirmedZeroIsActualAndNotReplacedWithAnEntryEstimate() {
    XCTAssertEqual(cardFee(row([
      "entry_fee_status": .string("confirmed"), "entry_realized_fee": .string("0")
    ])), "0 U（估总 -0.6 U）")
  }

  func testPartialCloseEstimatesEachExitPortionOnceWithoutReaddingTheRoundTripFee() {
    XCTAssertEqual(cardFee(row([
      "entry_fee_status": .string("confirmed"), "entry_realized_fee": .string("-0.3"),
      "exchange_size": .string("4")
    ])), "-0.3 U（估总 -0.84 U）")
  }

  func testPendingPartialEntryIsNeverPresentedAsTheCompleteActualFee() {
    XCTAssertEqual(cardFee(row([
      "entry_realized_fee": .string("-0.1"), "exchange_size": .string("4")
    ])), "估 -0.5 U（估总 -1.04 U）")
  }

  func testMissingOrMalformedActualFeesNeverBecomeAConfirmedZero() {
    for value in [JSONValue.null, .string("--"), .string("NaN"), .string("1 invalid")] {
      XCTAssertEqual(cardFee(row([
        "entry_fee_status": .string("confirmed"), "entry_realized_fee": value
      ])), "估 -0.5 U（估总 -1.1 U）")
    }
  }

  func testLivePriceUpdatesOnlyTheRemainingExitEstimate() {
    XCTAssertEqual(cardFee(row([
      "entry_fee_status": .string("confirmed"), "entry_realized_fee": .string("-0.3"),
      "exchange_size": .string("4")
    ]), price: 150), "-0.3 U（估总 -0.9 U）")
  }

  func testPositionLeverageOmitsOneAndShowsHigherLeverage() {
    XCTAssertNil(PositionCardPresentation.leverageText(row(["leverage": .string("1")])))
    XCTAssertEqual(PositionCardPresentation.leverageText(row(["leverage": .string("10")])), "x10")
    XCTAssertEqual(PositionCardPresentation.leverageText(row(["leverage": .string("10.5")])), "x10.5")
  }

  func testExplicitZeroRemainingDoesNotFallBackToInitialQuantity() {
    XCTAssertEqual(cardFee(row([
      "entry_fee_status": .string("confirmed"), "entry_realized_fee": .string("-0.3"),
      "exchange_size": .string("0"), "current_price": .null
    ])), "-0.3 U（估总 -0.8 U）")
  }

  func testUnknownEstimatesAndManualAdditionsAreNotInventedAsZero() {
    XCTAssertEqual(cardFee(.object([:])), "待核对（估总待核对）")
    XCTAssertEqual(cardFee(.object(["estimated_total_fee": .string("1")])),
      "估 -0.5 U（估总待核对）")
    XCTAssertEqual(cardFee(row(["has_manual_addition": .bool(true)])),
      "估 -0.5 U（估总待核对）")
    for quantity in [JSONValue.null, .string("--"), .string("NaN"), .string("11")] {
      XCTAssertEqual(cardFee(row(["exchange_size": quantity])), "估 -0.5 U（估总待核对）")
    }
  }

  func testDifferentFeeAssetsAreNotMislabeledOrAddedToU() {
    XCTAssertEqual(cardFee(row([
      "entry_fee_status": .string("confirmed"), "entry_realized_fee": .string("-0.01"),
      "entry_fee_asset": .string("BNB")
    ])), "-0.01 BNB（估总待核对）")
    XCTAssertEqual(cardFee(row([
      "entry_fee_status": .string("confirmed"), "entry_realized_fee": .string("-0.3"),
      "entry_fee_asset": .string("")
    ])), "-0.3 费用币种待核对（估总待核对）")
  }

  func testEntryEstimateCanUseTheOriginalNotionalWhenTheStoredEstimateIsUnavailable() {
    XCTAssertEqual(cardFee(row(["estimated_total_fee": .null])), "估 -0.5 U（估总 -1.1 U）")
    XCTAssertEqual(cardFee(row(["estimated_total_fee": .string("0")])), "估 -0.5 U（估总 -1.1 U）")
  }

  func testPositionProfitUsesUAndAtMostTwoFractionDigitsWithoutInventingMissingValues() {
    for (input, expected) in [("12.345", "12.35 U"), ("-12.345", "-12.35 U"),
      ("0", "0 U"), ("-0.004", "0 U"), ("10.00", "10 U")] {
      XCTAssertEqual(cardProfit(Decimal(string: input)), expected)
    }
    XCTAssertEqual(cardProfit(nil), "--")
    XCTAssertEqual(cardProfit(.nan), "--")
  }

  func testMarketTakeProfitShowsProjectedProfitOrLossAfterTheTriggerPrice() {
    let marketProfit = row([
      "manual_take_profit_set": .bool(true),
      "manual_take_profit_price": .string("120.00000000"),
      "manual_take_profit_order_type": .string("market"),
      "manual_take_profit_pnl": .string("20.00000000"),
    ])
    XCTAssertEqual(PositionCardPresentation.takeProfitText(marketProfit), "120.00（+20 U）")

    let marketLoss = row([
      "manual_take_profit_set": .bool(true),
      "manual_take_profit_price": .string("90"),
      "manual_take_profit_order_type": .string("market"),
      "manual_take_profit_pnl": .string("-10.125"),
    ])
    XCTAssertEqual(PositionCardPresentation.takeProfitText(marketLoss), "90.000（-10.13 U）")

    let limit = row([
      "manual_take_profit_set": .bool(true),
      "manual_take_profit_price": .string("120.00000000"),
      "manual_take_profit_order_type": .string("limit"),
      "manual_take_profit_pnl": .string("20.00000000"),
    ])
    XCTAssertEqual(PositionCardPresentation.takeProfitText(limit), "120.00")
  }

  func testMarketTakeProfitCanCalculateWhenTheServerFieldIsMissing() {
    let position = row([
      "side": .string("1"),
      "manual_take_profit_set": .bool(true),
      "manual_take_profit_price": .string("90"),
      "manual_take_profit_order_type": .string("market"),
      "exchange_size": .string("2"),
    ])
    XCTAssertEqual(PositionCardPresentation.takeProfitText(position), "90.000（+20 U）")
  }
}
