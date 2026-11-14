import XCTest
import SwiftUI
import UIKit
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

@MainActor
final class WebNativeRefreshTests: XCTestCase {
  private final class LayoutProbe {
    var measurements = 0
    var updates = 0
  }

  private struct ContentProbe: UIViewRepresentable {
    let probe: LayoutProbe
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ uiView: UIView, context: Context) { probe.updates += 1 }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
      probe.measurements += 1
      return CGSize(width: proposal.width ?? 390, height: 1800)
    }
  }

  private func descendants<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
  }

  private func settle(_ window: UIWindow) async {
    for _ in 0..<3 {
      window.layoutIfNeeded()
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  func testOrdinaryScrollingKeepsTheNativeHostWithoutContentRelayout() async throws {
    let probe = LayoutProbe()
    var reads = 0
    let root = WebRefreshScrollView { ContentProbe(probe: probe) }.webRefreshable { reads += 1 }
    let host = UIHostingController(rootView: root)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    await settle(window)
    let scroll = try XCTUnwrap(descendants(host.view, UIScrollView.self).first)
    let before = probe.measurements
    for step in 1...12 {
      scroll.contentOffset.y = CGFloat(step * 10)
      await settle(window)
    }
    XCTAssertEqual(probe.measurements, before,
      "Ordinary scrolling must not invalidate the SwiftUI content's layout")
    XCTAssertEqual(reads, 0, "Scrolling a list must never submit a refresh")
    XCTAssertNotNil(scroll.refreshControl,
      "The vertical scroll host must own pull progress and its inset, before release starts the read")
  }

  func testRefreshRetainsNativeHostUntilTheReadFinishesAndRejectsDuplicateRelease() async throws {
    var reads = 0
    var finish: CheckedContinuation<Void, Never>?
    let action: @MainActor () async -> Void = {
      reads += 1
      await withCheckedContinuation { finish = $0 }
    }
    func root(_ version: Int, active: Bool = true) -> AnyView {
      AnyView(WebRefreshScrollView(isActive: active) {
        Text("Snapshot \(version)").frame(height: 1800)
      }.webRefreshable(action))
    }
    let host = UIHostingController(rootView: root(1))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    await settle(window)
    let scroll = try XCTUnwrap(descendants(host.view, UIScrollView.self).first)
    let control = try XCTUnwrap(scroll.refreshControl)
    let originalInset = scroll.contentInset
    control.beginRefreshing()
    control.sendActions(for: .valueChanged)
    await settle(window)
    XCTAssertEqual(reads, 1)
    XCTAssertTrue(control.isRefreshing)
    let heldOffset = scroll.contentOffset
    host.rootView = root(2)
    await settle(window)
    XCTAssertTrue(descendants(host.view, UIScrollView.self).first === scroll)
    XCTAssertTrue(scroll.refreshControl === control)
    XCTAssertEqual(scroll.contentOffset, heldOffset)
    control.sendActions(for: .valueChanged)
    await settle(window)
    XCTAssertEqual(reads, 1)
    finish?.resume()
    await settle(window)
    XCTAssertFalse(control.isRefreshing)
    XCTAssertEqual(scroll.contentInset, originalInset)
  }

  func testDeactivationDisablesFeedbackAndIgnoresALateReadCompletion() async throws {
    var finish: CheckedContinuation<Void, Never>?
    let action: @MainActor () async -> Void = {
      await withCheckedContinuation { finish = $0 }
    }
    func root(_ active: Bool) -> AnyView {
      AnyView(WebRefreshScrollView(isActive: active) { Text("Content") }.webRefreshable(action))
    }
    let host = UIHostingController(rootView: root(true))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    await settle(window)
    let scroll = try XCTUnwrap(descendants(host.view, UIScrollView.self).first)
    let control = try XCTUnwrap(scroll.refreshControl)
    control.beginRefreshing()
    control.sendActions(for: .valueChanged)
    await settle(window)
    host.rootView = root(false)
    await settle(window)
    XCTAssertTrue(scroll.refreshControl === control)
    XCTAssertFalse(control.isEnabled)
    XCTAssertFalse(control.isRefreshing)
    finish?.resume()
    await settle(window)
    XCTAssertFalse(control.isEnabled)
    host.rootView = root(true)
    await settle(window)
    XCTAssertNotNil(scroll.refreshControl)
    XCTAssertFalse(try XCTUnwrap(scroll.refreshControl).isRefreshing)
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
