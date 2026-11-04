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
    ])), "1.26 USDT")
    XCTAssertEqual(PositionEntryFeePresentation.text(.object([
      "entry_fee_status": .string("confirmed"), "entry_realized_fee": .string("0")
    ])), "0 USDT")
  }

  func testUnknownActualFeeDoesNotPretendAnEstimateHasBeenCharged() {
    for status in ["pending", "estimated", "failed", "confirmed"] {
      XCTAssertEqual(PositionEntryFeePresentation.text(.object([
        "entry_fee_status": .string(status), "estimated_total_fee": .string("8")
      ])), "待核对")
    }
  }
}
