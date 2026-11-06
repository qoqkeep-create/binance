import XCTest

final class ChartCalibrationUITests: XCTestCase {
    private enum TargetApp {
        case binance
        case tradeTool

        var bundleIdentifier: String {
            switch self {
            case .binance:
                AppID.binance
            case .tradeTool:
                AppID.tradeTool
            }
        }

        var attachmentPrefix: String {
            switch self {
            case .binance:
                "binance"
            case .tradeTool:
                "trade-tool-dev-b"
            }
        }

        var oneHourLabel: String {
            "1小时"
        }

        var alternateIntervalLabel: String {
            "4小时"
        }

    }

    private enum AppID {
        static let binance = "com.czzhao.binance"
        static let tradeTool = "com.waibao2025.trade.integrated"
    }

    private let calibrationRoundCount = 5
    private let oldestBoundaryApproachRoundCount = 120
    private let primaryChartGestureY = 0.36

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testCaptureBinancePreparedChartState() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()
        guard requireBinanceChartDetail(in: app) else {
            return
        }
        attachScreenshot(named: "binance-chart-prepared")
        attachText(
            named: "binance-chart-prepared-hierarchy",
            contents: app.debugDescription
        )
    }

    func testRecoverBinancePublicChartDetail() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()

        for _ in 0..<4 {
            let indicatorSheet = app.staticTexts["指标"].firstMatch
            if indicatorSheet.exists {
                let window = app.windows.firstMatch
                let sheetHandle = window.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.37)
                )
                let dismissTarget = window.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)
                )
                sheetHandle.press(
                    forDuration: 0.05,
                    thenDragTo: dismissTarget,
                    withVelocity: .fast,
                    thenHoldForDuration: 0
                )
                wait(seconds: 1.0)
                continue
            }

            let oneHour = element(labeled: "1小时", in: app)
            if oneHour.exists,
                oneHour.isHittable,
                !app.staticTexts["指标设置"].exists
            {
                attachScreenshot(named: "binance-chart-recovered")
                return
            }

            if oneHour.exists {
                let detailTable = app.tables.firstMatch
                if detailTable.exists {
                    detailTable.swipeDown(velocity: .fast)
                    wait(seconds: 1.0)
                    continue
                }
            }

            let confirm = app.buttons["确认"].firstMatch
            if confirm.exists, confirm.isHittable {
                confirm.tap()
                wait(seconds: 1.0)
                continue
            }

            let back = app.buttons["返回"].firstMatch
            if back.exists, back.isHittable {
                back.tap()
                wait(seconds: 1.0)
                continue
            }
            break
        }

        XCTFail(
            "Could not return Binance to the prepared public 1-hour chart."
        )
        attachScreenshot(named: "binance-chart-recovery-failed")
        attachText(
            named: "binance-chart-recovery-failed-hierarchy",
            contents: app.debugDescription
        )
    }

    func testCaptureBinancePrimaryIndicatorReferences() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()
        guard requireBinanceChartDetail(in: app) else {
            return
        }

        let baselineIndicators = ["EMA", "SUPER"]
        let referenceIndicators = ["MA", "BOLL", "SAR", "AVL"]

        // Binance does not expose indicator selection state reliably to
        // XCUITest. Start this test with EMA + SUPER enabled and MA/BOLL/SAR/AVL
        // disabled. The test restores that same stable state when it finishes.
        // Reference overlays are always captured one at a time.
        for indicator in baselineIndicators {
            tapIndicator(indicator, in: app)
        }
        attachScreenshot(named: "binance-primary-indicator-clean-baseline")

        for indicator in referenceIndicators {
            tapIndicator(indicator, in: app)
            attachScreenshot(
                named: "binance-primary-indicator-\(indicator.lowercased())"
            )
            attachText(
                named: "binance-primary-indicator-\(indicator.lowercased())-hierarchy",
                contents: app.debugDescription
            )
            tapIndicator(indicator, in: app)
        }
        for indicator in baselineIndicators {
            tapIndicator(indicator, in: app)
        }
    }

    func testRecoverBinanceBTCUSDCDetailFromMarketList() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()

        let oneHour = element(labeled: "1小时", in: app)
        if oneHour.exists, oneHour.isHittable {
            resetToOneHour(target: .binance, in: app)
            attachScreenshot(named: "binance-btcusdc-detail-recovered")
            return
        }

        let marketSearch = app.staticTexts["搜索代币交易对和趋势"].firstMatch
        XCTAssertTrue(
            marketSearch.waitForExistence(timeout: 5),
            "Binance is neither on the chart detail nor the public market list."
        )

        let marketTable = app.tables.allElementsBoundByIndex.first { table in
            let frame = table.frame
            return frame.minY >= 190 && frame.height >= 500
        }
        guard let marketTable else {
            XCTFail("Missing the Binance public market table.")
            return
        }

        let btcusdc = app.staticTexts["BTCUSDC"].firstMatch
        for _ in 0..<8 where !btcusdc.isHittable {
            marketTable.swipeDown(velocity: .fast)
            wait(seconds: 0.5)
        }
        guard btcusdc.exists, btcusdc.isHittable else {
            attachText(
                named: "binance-market-list-recovery-failure-hierarchy",
                contents: app.debugDescription
            )
            XCTFail("BTCUSDC perpetual row did not become tappable.")
            return
        }

        btcusdc.tap()
        XCTAssertTrue(
            oneHour.waitForExistence(timeout: 12),
            "BTCUSDC public perpetual detail did not open."
        )
        resetToOneHour(target: .binance, in: app)
        attachScreenshot(named: "binance-btcusdc-detail-recovered")
        attachText(
            named: "binance-btcusdc-detail-recovered-hierarchy",
            contents: app.debugDescription
        )
    }

    func testCaptureBinanceRemainingPanelIndicatorReferences() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()
        guard requireBinanceChartDetail(in: app) else {
            return
        }

        let baselineIndicators = ["VOL", "MACD"]
        let referenceIndicators = [
            "KDJ", "OBV", "WR", "StochRSI", "ATR", "O.I.",
            "L.S Acco.", "L.S Posit.", "L.S Ratio", "B.S Vol.",
            "Basis",
        ]

        // Stable start/end state: VOL + MACD enabled, all reference panel
        // indicators disabled. Binance does not expose reliable selection
        // state, so each reference panel is captured in isolation.
        for indicator in baselineIndicators {
            tapBinanceIndicatorInBar(indicator, in: app)
        }
        attachScreenshot(named: "binance-panel-indicator-clean-baseline")

        for indicator in referenceIndicators {
            tapBinanceIndicatorInBar(indicator, in: app)
            wait(seconds: 2.0)
            let attachmentName = indicator
                .lowercased()
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: " ", with: "-")
            attachScreenshot(
                named: "binance-panel-indicator-\(attachmentName)"
            )
            attachText(
                named: "binance-panel-indicator-\(attachmentName)-hierarchy",
                contents: app.debugDescription
            )
            tapBinanceIndicatorInBar(indicator, in: app)
        }

        for indicator in baselineIndicators {
            tapBinanceIndicatorInBar(indicator, in: app)
        }
    }

    func testRestoreBinancePanelReferenceBaseline() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()
        guard requireBinanceChartDetail(in: app) else {
            return
        }
        tapBinanceIndicatorInBar("VOL", in: app)
        tapBinanceIndicatorInBar("MACD", in: app)
        attachScreenshot(named: "binance-panel-reference-baseline-restored")
    }

    func testDisableBinanceATRInterruptedReference() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()
        tapBinanceIndicatorInBar("ATR", in: app)
        attachScreenshot(named: "binance-atr-interrupted-reference-disabled")
    }

    func testNormalizeBinancePanelReferenceBaseline() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()
        guard openBinanceIndicatorPicker(in: app) else {
            XCTFail("Could not open the Binance indicator picker.")
            return
        }

        let enabledIndicators: Set<String> = ["VOL", "MACD"]
        let panelIndicators = [
            "VOL", "MACD", "RSI", "KDJ", "OBV", "WR", "StochRSI",
            "ATR", "O.I.", "L.S Acco.", "L.S Posit.", "L.S Ratio",
            "B.S Vol.", "Basis",
        ]
        for label in panelIndicators {
            let candidates = app.buttons.matching(
                NSPredicate(format: "label == %@", label)
            ).allElementsBoundByIndex
            guard let button = candidates.first(where: {
                $0.frame.width >= 70 && $0.frame.height >= 34
            }) else {
                XCTFail("Missing Binance indicator picker button \(label).")
                return
            }
            let shouldBeSelected = enabledIndicators.contains(label)
            if button.isSelected != shouldBeSelected {
                button.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ).tap()
                wait(seconds: 0.45)
            }
            XCTAssertEqual(
                button.isSelected,
                shouldBeSelected,
                "Unexpected Binance picker state for \(label)."
            )
        }
        attachScreenshot(named: "binance-panel-reference-picker-normalized")

        let title = app.staticTexts["指标"].firstMatch
        let window = app.windows.firstMatch
        let handleY = max(
            0.1,
            (title.frame.minY - 24) / window.frame.height
        )
        window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: handleY)
        ).press(
            forDuration: 0.05,
            thenDragTo: window.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)
            ),
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
        wait(seconds: 1.0)

        let oneHour = element(labeled: "1小时", in: app)
        let detailTable = app.tables.firstMatch
        for _ in 0..<6 where !oneHour.isHittable {
            detailTable.swipeDown(velocity: .fast)
            wait(seconds: 0.7)
        }
        XCTAssertTrue(
            oneHour.isHittable,
            "Binance chart did not return to its visible top state."
        )
        attachScreenshot(named: "binance-panel-reference-baseline-normalized")
    }

    func testCaptureBinanceIndicatorPicker() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()
        guard openBinanceIndicatorPicker(in: app) else {
            XCTFail("Could not open the Binance indicator picker.")
            return
        }
        attachScreenshot(named: "binance-indicator-picker")
        attachText(
            named: "binance-indicator-picker-hierarchy",
            contents: app.debugDescription
        )
    }

    func testCaptureBinanceATRAndMarketPanelIndicatorReferences() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()
        guard requireBinanceChartDetail(in: app) else {
            return
        }

        let baselineIndicators = ["VOL", "MACD"]
        let referenceIndicators = [
            "ATR", "O.I.", "L.S Acco.", "L.S Posit.", "L.S Ratio",
            "B.S Vol.", "Basis",
        ]
        for indicator in baselineIndicators {
            tapBinanceIndicatorInBar(indicator, in: app)
        }
        attachScreenshot(named: "binance-atr-market-clean-baseline")

        for indicator in referenceIndicators {
            tapBinanceIndicatorInBar(indicator, in: app)
            wait(seconds: 2.0)
            let attachmentName = indicator
                .lowercased()
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: " ", with: "-")
            attachScreenshot(
                named: "binance-panel-indicator-\(attachmentName)-clean"
            )
            attachText(
                named: "binance-panel-indicator-\(attachmentName)-clean-hierarchy",
                contents: app.debugDescription
            )
            tapBinanceIndicatorInBar(indicator, in: app)
        }
        for indicator in baselineIndicators {
            tapBinanceIndicatorInBar(indicator, in: app)
        }
    }

    func testCaptureBinanceAllPanelIndicatorReferencesViaPicker() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()
        let pickerAlreadyOpen = binanceIndicatorPickerButton(
            "VOL",
            in: app
        ) != nil
        if !pickerAlreadyOpen {
            guard requireBinanceChartDetail(in: app) else {
                return
            }
            resetToOneHour(target: .binance, in: app)
        }

        let referenceIndicators = [
            "KDJ", "OBV", "WR", "StochRSI", "ATR", "O.I.",
            "L.S Acco.", "L.S Posit.", "L.S Ratio", "B.S Vol.",
            "Basis",
        ]
        let panelIndicators = ["VOL", "MACD", "RSI"]
            + referenceIndicators

        XCTAssertTrue(openBinanceIndicatorPicker(in: app))
        for label in panelIndicators {
            guard let button = binanceIndicatorPickerButton(
                label,
                in: app
            ) else {
                XCTFail("Missing Binance indicator picker button \(label).")
                return
            }
            if button.isSelected {
                button.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ).tap()
                wait(seconds: 0.35)
            }
        }

        var previousIndicator: String?
        for indicator in referenceIndicators {
            if let previousIndicator,
                let previousButton = binanceIndicatorPickerButton(
                    previousIndicator,
                    in: app
                ),
                previousButton.isSelected
            {
                previousButton.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ).tap()
                wait(seconds: 0.35)
            }

            guard let currentButton = binanceIndicatorPickerButton(
                indicator,
                in: app
            ) else {
                XCTFail("Missing Binance indicator picker button \(indicator).")
                return
            }
            if !currentButton.isSelected {
                currentButton.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ).tap()
                wait(seconds: 0.35)
            }
            XCTAssertTrue(
                currentButton.isSelected,
                "Binance did not select \(indicator)."
            )

            dismissBinanceIndicatorPicker(in: app)
            returnBinanceDetailToTop(in: app)
            wait(seconds: 3.0)
            let attachmentName = indicator
                .lowercased()
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: " ", with: "-")
            attachScreenshot(
                named: "binance-panel-latest-\(attachmentName)"
            )
            attachText(
                named: "binance-panel-latest-\(attachmentName)-hierarchy",
                contents: app.debugDescription
            )
            previousIndicator = indicator
            if indicator != referenceIndicators.last {
                XCTAssertTrue(openBinanceIndicatorPicker(in: app))
            }
        }

        XCTAssertTrue(openBinanceIndicatorPicker(in: app))
        if let previousIndicator,
            let previousButton = binanceIndicatorPickerButton(
                previousIndicator,
                in: app
            ),
            previousButton.isSelected
        {
            previousButton.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).tap()
        }
        for label in ["VOL", "MACD"] {
            if let button = binanceIndicatorPickerButton(label, in: app),
                !button.isSelected
            {
                button.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ).tap()
            }
        }
        dismissBinanceIndicatorPicker(in: app)
        returnBinanceDetailToTop(in: app)
        attachScreenshot(named: "binance-panel-latest-baseline-restored")
    }

    func testCaptureBinanceIndicatorSettings() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()

        let settingsButton = app.buttons.allElementsBoundByIndex.first {
            let frame = $0.frame
            return frame.minX >= 350
                && frame.minX <= 365
                && frame.minY >= 600
                && frame.minY <= 620
                && frame.width <= 24
        }
        XCTAssertNotNil(
            settingsButton,
            "Binance indicator settings control was not found."
        )
        guard let settingsButton else {
            return
        }
        settingsButton.tap()
        wait(seconds: 2.0)
        attachScreenshot(named: "binance-indicator-settings")
        attachText(
            named: "binance-indicator-settings-hierarchy",
            contents: app.debugDescription
        )
    }

    func testCaptureBinanceIndicatorParameterSettings() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        wait(seconds: 1.0)

        let parameterSettings = app.staticTexts["指标设置"]
        XCTAssertTrue(
            parameterSettings.waitForExistence(timeout: 5),
            "Binance parameter settings row was not found."
        )
        parameterSettings.tap()
        wait(seconds: 2.0)
        attachScreenshot(named: "binance-indicator-parameter-settings")
        attachText(
            named: "binance-indicator-parameter-settings-hierarchy",
            contents: app.debugDescription
        )
    }

    func testOpenBinanceIndicatorParameterList() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()
        guard openBinanceIndicatorPicker(in: app) else {
            XCTFail("Could not open the Binance indicator picker.")
            return
        }

        let parameterSettings = app.staticTexts["指标设置"].firstMatch
        XCTAssertTrue(
            parameterSettings.waitForExistence(timeout: 5),
            "Binance parameter settings row was not found."
        )
        parameterSettings.tap()
        wait(seconds: 1.5)
        XCTAssertNil(
            binanceIndicatorPickerButton("VOL", in: app),
            "Binance indicator picker remained open."
        )
        attachScreenshot(named: "binance-indicator-parameter-list")
        attachText(
            named: "binance-indicator-parameter-list-hierarchy",
            contents: app.debugDescription
        )
    }

    func testCaptureBinancePrimaryIndicatorParameterDetails() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        wait(seconds: 1.0)

        for indicator in ["MA", "BOLL", "SAR", "AVL"] {
            let row = app.staticTexts[indicator]
            XCTAssertTrue(
                row.waitForExistence(timeout: 5),
                "Missing Binance parameter row \(indicator)."
            )
            row.tap()
            wait(seconds: 1.2)
            attachScreenshot(
                named: "binance-indicator-parameters-\(indicator.lowercased())"
            )
            attachText(
                named: "binance-indicator-parameters-\(indicator.lowercased())-hierarchy",
                contents: app.debugDescription
            )

            let back = app.buttons["返回"]
            XCTAssertTrue(
                back.waitForExistence(timeout: 5),
                "Missing Binance parameter back button."
            )
            back.tap()
            wait(seconds: 0.8)
        }
    }

    func testCaptureBinancePanelIndicatorParameterDetails() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        wait(seconds: 1.0)

        let settingsTitle = app.staticTexts["指标设置"]
        XCTAssertTrue(
            settingsTitle.waitForExistence(timeout: 5),
            "Open the Binance indicator parameter list before this test."
        )
        let table = app.tables.firstMatch
        XCTAssertTrue(
            table.waitForExistence(timeout: 5),
            "Binance indicator parameter table was not found."
        )

        let indicators = [
            "KDJ", "OBV", "WR", "StochRSI", "ATR", "O.I.",
            "L.S Acco.", "L.S Posit.", "L.S Ratio", "B.S Vol.",
            "Basis",
        ]
        for indicator in indicators {
            guard let row = bringBinanceSettingsRowIntoView(
                indicator,
                table: table,
                in: app
            ) else {
                XCTFail("Missing Binance parameter row \(indicator).")
                return
            }
            row.tap()
            wait(seconds: 1.2)
            let attachmentName = indicator
                .lowercased()
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: " ", with: "-")
            attachScreenshot(
                named: "binance-panel-parameters-\(attachmentName)"
            )
            attachText(
                named: "binance-panel-parameters-\(attachmentName)-hierarchy",
                contents: app.debugDescription
            )

            let back = app.buttons["返回"].firstMatch
            if back.exists, back.isHittable {
                back.tap()
            } else {
                let confirm = app.buttons["确认"].firstMatch
                XCTAssertTrue(
                    confirm.waitForExistence(timeout: 5),
                    "Missing Binance parameter close control."
                )
                confirm.tap()
            }
            wait(seconds: 0.8)
        }
    }

    func testCaptureBinanceCandleGeometryZoomSequence() {
        let app = XCUIApplication(bundleIdentifier: AppID.binance)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        wait(seconds: 4)
        let chartCell = app.cells.allElementsBoundByIndex.first {
            let frame = $0.frame
            return frame.minY >= 220
                && frame.minY <= 250
                && frame.height >= 450
                && frame.height <= 520
        }
        XCTAssertNotNil(chartCell, "Binance chart cell was not found.")
        guard let chartCell else {
            return
        }
        attachScreenshot(named: "binance-candle-geometry-sequence-start")
        for round in 1...5 {
            chartCell.pinch(withScale: 1.05, velocity: 0.2)
            wait(seconds: 4)
            attachScreenshot(named: String(
                format: "binance-candle-geometry-sequence-%02d",
                round
            ))
        }
    }

    func testContinuousScalePinchPanAndCrosshairFixture() throws {
        let app = XCUIApplication(bundleIdentifier: AppID.tradeTool)
        app.launchArguments = ["--chart-calibration-fixture"]
        app.launch()
        openTradeToolDetailIfNeeded(in: app)
        let chart = app.descendants(matching: .any)["market-chart-plot"]
        XCTAssertTrue(chart.waitForExistence(timeout: 15))
        waitForAnimations()
        attachScreenshot(named: "continuous-scale-start")
        chart.pinch(withScale: 0.5, velocity: -0.25)
        attachScreenshot(named: "continuous-scale-zoom-out")
        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2))
        let end = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        wait(seconds: 2.2)
        XCTAssertTrue(chart.exists)
        XCTAssertTrue((chart.value as? String)?.contains("历史") == true)
        attachScreenshot(named: "continuous-scale-pan")
        chart.pinch(withScale: 1.5, velocity: 0.3)
        attachScreenshot(named: "continuous-scale-zoom-in")
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(forDuration: 0.6)
        attachScreenshot(named: "continuous-scale-crosshair")
        XCTAssertFalse(app.staticTexts["K线渲染器初始化失败"].exists)
    }

    func testCaptureTradeToolCandleGeometryZoomSequence() {
        let app = XCUIApplication(bundleIdentifier: AppID.tradeTool)
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Trade Tool did not enter the foreground."
        )
        openTradeToolDetailIfNeeded(in: app)
        let chartPlot = app.descendants(matching: .any)[
            "market-chart-plot"
        ]
        XCTAssertTrue(
            chartPlot.waitForExistence(timeout: 15),
            "Trade Tool chart plot was not found."
        )
        wait(seconds: 4)

        for _ in 1...4 {
            chartPlot.pinch(withScale: 0.5, velocity: -1)
            wait(seconds: 1.5)
        }
        wait(seconds: 4)
        attachScreenshot(
            named: "trade-tool-dev-a-candle-geometry-sequence-minimum"
        )

        let binanceMatchedZoomScales = [
            1.666_666_7,
            1.7,
            1.941_176_5,
            2.090_909_1,
            2.0,
        ]
        for (index, scale) in binanceMatchedZoomScales.enumerated() {
            chartPlot.pinch(withScale: scale, velocity: 0.5)
            wait(seconds: 4)
            attachScreenshot(named: String(
                format: "trade-tool-dev-a-candle-geometry-sequence-%02d",
                index + 1
            ))
        }
    }

    func testCaptureTradeToolPreparedChartState() {
        let app = XCUIApplication(bundleIdentifier: AppID.tradeTool)
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Trade Tool did not enter the foreground."
        )
        openTradeToolDetailIfNeeded(in: app)
        waitForAnimations()
        attachScreenshot(named: "trade-tool-chart-prepared-dev-a")
    }

    func testCaptureTradeToolChartOnlyDetail() {
        let app = XCUIApplication(bundleIdentifier: AppID.tradeTool)
        app.launchArguments = [
            "--chart-calibration-fixture",
            "--chart-calibration-panel", "VOL",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        openTradeToolDetailIfNeeded(in: app)
        waitForAnimations()

        XCTAssertTrue(app.descendants(matching: .any)[
            "market-chart-plot"
        ].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)[
            "market-chart-indicator-bar"
        ].exists)
        for title in [
            "委托订单", "深度图", "最新成交",
            "今日", "7 天", "30 天", "90 天", "180 天", "1 年",
            "最新价格", "标记价格", "24h最高价", "24h最低价",
            "信息", "数据", "广场", "交易-X", "更多",
        ] {
            XCTAssertFalse(app.staticTexts[title].exists)
        }

        let header = app.descendants(matching: .any)["market-chart-header"]
        let chart = app.descendants(matching: .any)["market-chart-plot"]
        let strip = app.scrollViews["market-chart-quick-indicator-strip"]
        let detailScroll = app.scrollViews["market-chart-detail-scroll"]
        let favorite = app.buttons["market-chart-favorite"]
        XCTAssertTrue(favorite.isHittable)
        XCTAssertFalse(app.images["bell"].exists)
        // The existing 44 pt target is inset 11 pt from the header edge.
        XCTAssertEqual(favorite.frame.midX, header.frame.maxX - 33, accuracy: 1)
        XCTAssertLessThanOrEqual(favorite.frame.maxX, header.frame.maxX - 11)
        favorite.tap()
        XCTAssertEqual(favorite.value as? String, "未收藏")
        favorite.tap()
        XCTAssertEqual(favorite.value as? String, "已收藏")
        XCTAssertLessThan(header.frame.maxY, strip.frame.maxY)
        XCTAssertLessThanOrEqual(strip.frame.maxY, app.buttons["chart-interval.1h"].frame.minY)
        XCTAssertLessThanOrEqual(app.buttons["chart-interval.1h"].frame.maxY, chart.frame.minY + 1)
        XCTAssertLessThanOrEqual(app.buttons["chart-ticket.submit"].frame.maxY, app.frame.maxY - 20)
        XCTAssertTrue(app.buttons["market-chart-indicator-settings-shortcut"].isHittable)
        XCTAssertTrue(app.buttons["自动杠杆"].isHittable)
        XCTAssertTrue(app.buttons["设置"].isHittable)
        XCTAssertFalse(app.buttons["market-chart-order-long"].exists)
        XCTAssertFalse(app.buttons["market-chart-order-short"].exists)
        XCTAssertTrue(app.buttons["chart-ticket.submit"].isHittable)
        attachScreenshot(named: "trade-tool-square-chart-and-ticket")
        detailScroll.swipeUp(velocity: .slow)
        waitForAnimations()
        XCTAssertTrue(app.buttons["chart-ticket.submit"].isHittable)
        attachScreenshot(named: "trade-tool-compact-additional-panels")
        detailScroll.swipeDown(velocity: .slow)
        setTradeToolIndicator("MA", enabled: true, in: app)
        setTradeToolIndicator("MA", enabled: false, in: app)
    }

    func testCaptureTradeToolPanelActivationOrder() throws {
        let app = XCUIApplication(bundleIdentifier: AppID.tradeTool)
        let initialArguments = [
            "--chart-calibration-fixture",
            "--chart-calibration-panel", "VOL",
        ]
        app.launchArguments = initialArguments
        app.launch()
        defer {
            app.terminate()
            app.launchArguments = initialArguments
            app.launch()
        }
        openTradeToolDetailIfNeeded(in: app)
        waitForAnimations()
        setTradeToolIndicator("MACD", enabled: false, in: app)
        setTradeToolIndicator("VOL", enabled: false, in: app)
        for indicator in ["ATR", "RSI", "OBV"] {
            setTradeToolIndicator(indicator, enabled: true, in: app)
        }
        try assertTradeToolPanelOrder(["ATR", "RSI", "OBV"], in: app)
        app.scrollViews["market-chart-detail-scroll"].swipeUp(velocity: .slow)
        attachScreenshot(named: "trade-tool-panel-order-atr-rsi-obv")

        setTradeToolIndicator("ATR", enabled: false, in: app)
        setTradeToolIndicator("ATR", enabled: true, in: app)
        let reordered = ["RSI", "OBV", "ATR"]
        try assertTradeToolPanelOrder(reordered, in: app)
        app.scrollViews["market-chart-detail-scroll"].swipeUp(velocity: .slow)
        attachScreenshot(named: "trade-tool-panel-order-rsi-obv-atr")

        selectTradeToolInterval("4小时", in: app)
        waitForAnimations()
        try assertTradeToolPanelOrder(reordered, in: app)
        app.buttons["market-chart-symbols"].tap()
        app.buttons["pairs.select.ETHUSDC"].tap()
        waitForAnimations()
        XCTAssertTrue(app.buttons["market-chart-symbols"].label.contains("ETHUSDC"))
        try assertTradeToolPanelOrder(reordered, in: app)

        app.terminate()
        app.launchArguments = ["--chart-calibration-fixture"]
        app.launch()
        openTradeToolDetailIfNeeded(in: app)
        waitForAnimations()
        try assertTradeToolPanelOrder(reordered, in: app)
    }

    func testCaptureTradeToolIndicatorSettingsShortcut() throws {
        let app = XCUIApplication(bundleIdentifier: AppID.tradeTool)
        app.launchArguments.append("--chart-calibration-fixture")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        openTradeToolDetailIfNeeded(in: app)
        waitForAnimations()
        let shortcut = app.buttons["market-chart-indicator-settings-shortcut"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 10))
        shortcut.tap()
        XCTAssertTrue(
            app.staticTexts["指标设置"].waitForExistence(timeout: 10)
        )
        attachScreenshot(named: "trade-tool-bottom-indicator-settings")
        let backButton = try XCTUnwrap(
            app.buttons.matching(identifier: "返回")
                .allElementsBoundByIndex.first { $0.isHittable }
        )
        backButton.tap()
        waitForAnimations()
    }

    func testChartIntervalShortcutsAndSettings() {
        let app = XCUIApplication(bundleIdentifier: AppID.tradeTool)
        app.launchArguments = ["--chart-calibration-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["chart-interval.edit"].waitForExistence(timeout: 10))
        app.buttons["chart-interval.edit"].tap()
        app.buttons["恢复默认周期"].tap()
        XCTAssertTrue(app.staticTexts["图表周期"].exists)
        XCTAssertTrue(app.staticTexts["备选周期"].exists)
        XCTAssertTrue(app.buttons["interval-settings.favorite.3m"].exists)
        XCTAssertTrue(app.buttons["interval-settings.favorite.1m"].isEnabled)
        XCTAssertEqual(app.buttons["interval-settings.favorite.1m"].value as? String, "0")
        app.buttons["interval-settings.favorite.1m"].tap()
        XCTAssertEqual(app.buttons["interval-settings.favorite.1m"].value as? String, "1")
        app.buttons["interval-settings.favorite.30m"].tap()
        XCTAssertTrue(app.staticTexts["最多可选 7 个周期"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["interval-settings.favorite.30m"].value as? String, "0")
        app.buttons["interval-settings.favorite.1d"].tap()
        attachScreenshot(named: "chart-interval-sections")
        app.buttons["interval-settings.select.3m"].tap()
        XCTAssertTrue(app.staticTexts["图表周期"].exists, "Editing a shortcut must keep the settings open")
        XCTAssertEqual(app.buttons["interval-settings.favorite.3m"].value as? String, "0")
        app.buttons["interval-settings.select.3m"].tap()
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(app.buttons["chart-interval.3m"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chart-interval.1m"].exists)
        XCTAssertLessThanOrEqual(app.buttons["chart-interval.edit"].frame.minX
            - app.buttons["chart-interval.4h"].frame.maxX, 14)
        let auto = app.descendants(matching: .any)["chart-interval.auto"].firstMatch
        XCTAssertTrue(auto.exists)
        if auto.value as? String != "1" { auto.tap() }
        auto.tap()
        XCTAssertEqual(auto.value as? String, "0")
        let plot = app.descendants(matching: .any)["market-chart-plot"].firstMatch
        let start = plot.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 65)))
        attachScreenshot(named: "chart-auto-off-manual-pan")
        auto.tap()
        XCTAssertEqual(auto.value as? String, "1")
        app.buttons["chart-interval.4h"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["market-chart-plot"].exists)
        attachScreenshot(named: "chart-configurable-intervals")
    }

    func testCaptureTradeToolPrimaryIndicatorReferences() {
        let app = XCUIApplication(bundleIdentifier: AppID.tradeTool)
        app.launchArguments.append("--chart-calibration-fixture")
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Trade Tool did not enter the foreground."
        )
        openTradeToolDetailIfNeeded(in: app)
        waitForAnimations()

        let baselineIndicators = ["EMA", "SUPER"]
        let referenceIndicators = ["MA", "BOLL", "SAR", "AVL"]
        for indicator in baselineIndicators + referenceIndicators {
            setTradeToolIndicator(indicator, enabled: false, in: app)
        }
        attachScreenshot(
            named: "trade-tool-primary-indicator-clean-baseline-dev-b"
        )

        for indicator in referenceIndicators {
            setTradeToolIndicator(indicator, enabled: true, in: app)
            attachScreenshot(
                named: "trade-tool-primary-indicator-\(indicator.lowercased())-dev-b"
            )
            setTradeToolIndicator(indicator, enabled: false, in: app)
        }
        for indicator in baselineIndicators {
            setTradeToolIndicator(indicator, enabled: true, in: app)
        }
    }

    func testCaptureTradeToolAllIndicatorPanels() {
        let app = XCUIApplication(bundleIdentifier: AppID.tradeTool)
        app.launchArguments.append("--chart-indicators-all")
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Trade Tool did not enter the foreground."
        )
        openTradeToolDetailIfNeeded(in: app)
        waitForAnimations()

        for indicator in ["VOL", "MACD", "RSI"] {
            let button = app.buttons[
                "market-chart-quick-indicator-\(indicator)"
            ]
            XCTAssertTrue(
                button.waitForExistence(timeout: 10),
                "Missing \(indicator) indicator control."
            )
            XCTAssertEqual(
                button.value as? String,
                "已开启",
                "\(indicator) was not active."
            )
        }
        attachScreenshot(named: "trade-tool-vol-macd-rsi-dev-a")
    }

    func testCaptureTradeToolRemainingPanelIndicatorReferences() {
        captureTradeToolPanelIndicatorReferences([
            "KDJ", "OBV", "WR", "StochRSI", "ATR", "O.I.",
            "L.S Acco.", "L.S Posit.", "L.S Ratio", "B.S Vol.",
            "Basis",
        ])
    }

    func testCaptureTradeToolTechnicalPanelIndicatorReferences() {
        captureTradeToolPanelIndicatorReferences([
            "KDJ", "OBV", "WR", "StochRSI", "ATR",
        ])
    }

    func testVerifyTradeToolProductionOpenInterest() {
        captureTradeToolPanelIndicatorReferences(["O.I."])
    }

    private func captureTradeToolPanelIndicatorReferences(
        _ referenceIndicators: [String]
    ) {
        let app = XCUIApplication(bundleIdentifier: AppID.tradeTool)
        let expectedProductionLegends: [String: String] = [
            "O.I.": "O.i.:",
            "L.S Acco.": "L.S Acco.:",
            "L.S Posit.": "L.S Posit.:",
            "L.S Ratio": "L.S Ratio:",
            "B.S Vol.": "B:",
            "Basis": "Basis:",
        ]

        for indicator in referenceIndicators {
            app.terminate()
            app.launchArguments = [
                "--chart-calibration-panel", indicator,
            ]
            app.launch()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 15),
                "Trade Tool did not enter the foreground for \(indicator)."
            )
            openTradeToolDetailIfNeeded(in: app)
            wait(seconds: expectedProductionLegends[indicator] == nil
                ? 1.2
                : 3.0)
            let indicatorButton = app.buttons[
                "market-chart-quick-indicator-\(indicator)"
            ]
            XCTAssertTrue(
                indicatorButton.waitForExistence(timeout: 10),
                "Missing \(indicator) indicator control."
            )
            XCTAssertEqual(
                indicatorButton.value as? String,
                "已开启",
                "Release launch did not activate \(indicator)."
            )

            let chart = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "K线图"))
                .firstMatch
            XCTAssertTrue(
                chart.waitForExistence(timeout: 10),
                "Missing accessible chart for \(indicator)."
            )
            let chartValue = chart.value as? String ?? ""
            if let expectedLegend = expectedProductionLegends[indicator] {
                XCTAssertTrue(
                    chartValue.contains(expectedLegend),
                    "Production \(indicator) values were absent: \(chartValue)"
                )
            }

            let detailScroll = app.scrollViews[
                "market-chart-detail-scroll"
            ]
            XCTAssertTrue(
                detailScroll.waitForExistence(timeout: 5),
                "Missing chart detail scroll view for \(indicator)."
            )
            detailScroll.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74)
            ).press(
                forDuration: 0.05,
                thenDragTo: detailScroll.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.56)
                ),
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
            wait(seconds: 0.6)

            let attachmentName = indicator
                .lowercased()
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: " ", with: "-")
            attachScreenshot(
                named: "trade-tool-release-panel-\(attachmentName)"
            )
            attachText(
                named: "trade-tool-release-panel-\(attachmentName)-chart-value",
                contents: chartValue
            )
        }

        app.terminate()
        app.launchArguments = []
        app.launch()
        openTradeToolDetailIfNeeded(in: app)
        waitForAnimations()
        attachScreenshot(named: "trade-tool-release-panel-baseline-restored")
    }

    func testCaptureBinancePreparedGestureStates() {
        capturePreparedGestureStates(
            target: .binance
        )
    }

    func testCaptureBinanceCurrentPriceReferenceStates() {
        captureCurrentPriceReferenceStates(target: .binance)
    }

    func testCaptureBinanceIntervalLoadingReference() {
        let target = TargetApp.binance
        let app = XCUIApplication(
            bundleIdentifier: target.bundleIdentifier
        )
        start(app, target: target)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()

        let oneHour = element(
            labeled: target.oneHourLabel,
            in: app
        )
        let fourHours = element(
            labeled: target.alternateIntervalLabel,
            in: app
        )
        XCTAssertTrue(oneHour.waitForExistence(timeout: 5))
        XCTAssertTrue(fourHours.waitForExistence(timeout: 5))

        oneHour.tap()
        wait(seconds: 1.2)
        attachImmediateScreenshot(
            named: "binance-interval-loading-baseline"
        )

        for round in 1...4 {
            let targetInterval = round.isMultiple(of: 2)
                ? oneHour
                : fourHours
            XCTContext.runActivity(
                named: "binance-interval-loading-round-\(round)"
            ) { _ in
                targetInterval.tap()
                for sample in 1...6 {
                    attachImmediateScreenshot(named: String(
                        format:
                            "binance-interval-loading-%02d-%02d",
                        round,
                        sample
                    ))
                }
                wait(seconds: 1.2)
            }
        }
    }

    func testCaptureTradeToolIntervalLoadingReference() {
        let target = TargetApp.tradeTool
        let app = XCUIApplication(
            bundleIdentifier: target.bundleIdentifier
        )
        start(app, target: target)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Trade Tool did not enter the foreground."
        )
        openTradeToolDetailIfNeeded(in: app)
        resetToOneHour(target: target, in: app)

        let oneHour = element(
            labeled: target.oneHourLabel,
            in: app
        )
        let fourHours = element(
            labeled: target.alternateIntervalLabel,
            in: app
        )
        attachImmediateScreenshot(
            named: "trade-tool-interval-loading-baseline"
        )

        for round in 1...4 {
            let targetInterval = round.isMultiple(of: 2)
                ? oneHour
                : fourHours
            XCTContext.runActivity(
                named: "trade-tool-interval-loading-round-\(round)"
            ) { _ in
                targetInterval.tap()
                for sample in 1...6 {
                    attachImmediateScreenshot(named: String(
                        format:
                            "trade-tool-interval-loading-%02d-%02d",
                        round,
                        sample
                    ))
                }
                wait(seconds: 1.2)
            }
        }
    }

    func testCaptureBinanceUnifiedScaleIndicatorVolumeReference() {
        let target = TargetApp.binance
        let app = XCUIApplication(
            bundleIdentifier: target.bundleIdentifier
        )
        start(app, target: target)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        resetToOneHour(target: target, in: app)

        attachScreenshot(named: "binance-unified-reference-baseline")

        let scaleStart = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.94, dy: 0.42)
        )
        let scaleUp = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.94, dy: 0.31)
        )
        scaleStart.press(
            forDuration: 0.05,
            thenDragTo: scaleUp,
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        wait(seconds: 1.2)
        attachScreenshot(named: "binance-price-scale-drag-up")

        resetToOneHour(target: target, in: app)
        let scaleDown = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.94, dy: 0.55)
        )
        scaleStart.press(
            forDuration: 0.05,
            thenDragTo: scaleDown,
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        wait(seconds: 1.2)
        attachScreenshot(named: "binance-price-scale-drag-down")

        resetToOneHour(target: target, in: app)
        tapIndicator("EMA", in: app)
        attachScreenshot(named: "binance-ema-disabled")
        tapIndicator("SUPER", in: app)
        attachScreenshot(named: "binance-ema-super-disabled")
        tapIndicator("EMA", in: app)
        tapIndicator("SUPER", in: app)

        let historyStart = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.26, dy: primaryChartGestureY)
        )
        let historyEnd = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.78, dy: primaryChartGestureY)
        )
        for _ in 1...3 {
            historyStart.press(
                forDuration: 0.05,
                thenDragTo: historyEnd,
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
            wait(seconds: 0.8)
        }
        attachScreenshot(named: "binance-history-legends-current-marker")

        resetToOneHour(target: target, in: app)
        tapIndicator("MACD", in: app)
        tapIndicator("VOL", in: app)
        wait(seconds: 1.2)
        attachScreenshot(named: "binance-volume-latest")
        for _ in 1...3 {
            historyStart.press(
                forDuration: 0.05,
                thenDragTo: historyEnd,
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
            wait(seconds: 0.8)
        }
        attachScreenshot(named: "binance-volume-history")
    }

    func testCaptureBinanceVolumeOnlyAndPriceReturnReference() {
        let target = TargetApp.binance
        let app = XCUIApplication(
            bundleIdentifier: target.bundleIdentifier
        )
        start(app, target: target)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Binance did not enter the foreground."
        )
        waitForAnimations()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        resetToOneHour(target: target, in: app)
        setBinanceIndicator("MACD", enabled: false, in: app)
        setBinanceIndicator("VOL", enabled: true, in: app)
        attachScreenshot(named: "binance-volume-only-latest")

        let historyStart = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.26, dy: primaryChartGestureY)
        )
        let historyEnd = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.78, dy: primaryChartGestureY)
        )
        for _ in 1...3 {
            historyStart.press(
                forDuration: 0.05,
                thenDragTo: historyEnd,
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
            wait(seconds: 0.8)
        }
        attachScreenshot(named: "binance-volume-only-history")

        window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.78, dy: 0.49)
        ).tap()
        wait(seconds: 1.2)
        attachScreenshot(named: "binance-current-price-return-tap")
    }

    func testCaptureTradeToolCurrentPriceReferenceStates() {
        captureCurrentPriceReferenceStates(target: .tradeTool)
    }

    func testCaptureTradeToolUnifiedScaleIndicatorVolumeFixes() {
        let app = XCUIApplication(bundleIdentifier: AppID.tradeTool)
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Trade Tool did not enter the foreground."
        )
        openTradeToolDetailIfNeeded(in: app)
        resetToOneHour(target: .tradeTool, in: app)
        let chartPlot = app.descendants(matching: .any)[
            "market-chart-plot"
        ]
        XCTAssertTrue(
            chartPlot.waitForExistence(timeout: 15),
            "Trade Tool chart plot was not found."
        )
        setTradeToolIndicator("EMA", enabled: true, in: app)
        setTradeToolIndicator("SUPER", enabled: true, in: app)
        setTradeToolIndicator("MACD", enabled: false, in: app)
        setTradeToolIndicator("RSI", enabled: false, in: app)
        setTradeToolIndicator("VOL", enabled: true, in: app)
        attachScreenshot(named: "trade-tool-unified-volume-latest")

        let axisStart = chartPlot.coordinate(
            withNormalizedOffset: CGVector(dx: 0.94, dy: 0.42)
        )
        axisStart.press(
            forDuration: 0.05,
            thenDragTo: chartPlot.coordinate(
                withNormalizedOffset: CGVector(dx: 0.94, dy: 0.27)
            ),
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        wait(seconds: 1.0)
        attachScreenshot(named: "trade-tool-price-scale-up")

        resetToOneHour(target: .tradeTool, in: app)
        axisStart.press(
            forDuration: 0.05,
            thenDragTo: chartPlot.coordinate(
                withNormalizedOffset: CGVector(dx: 0.94, dy: 0.60)
            ),
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        wait(seconds: 1.0)
        attachScreenshot(named: "trade-tool-price-scale-down")

        resetToOneHour(target: .tradeTool, in: app)
        setTradeToolIndicator("EMA", enabled: false, in: app)
        attachScreenshot(named: "trade-tool-ema-disabled")
        setTradeToolIndicator("SUPER", enabled: false, in: app)
        attachScreenshot(named: "trade-tool-ema-super-disabled")
        setTradeToolIndicator("EMA", enabled: true, in: app)
        setTradeToolIndicator("SUPER", enabled: true, in: app)

        let historyStart = chartPlot.coordinate(
            withNormalizedOffset: CGVector(dx: 0.26, dy: 0.40)
        )
        let historyEnd = chartPlot.coordinate(
            withNormalizedOffset: CGVector(dx: 0.78, dy: 0.40)
        )
        for _ in 1...3 {
            historyStart.press(
                forDuration: 0.05,
                thenDragTo: historyEnd,
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
            wait(seconds: 0.8)
        }
        XCTAssertEqual(chartPlot.value as? String, "历史")
        attachScreenshot(
            named: "trade-tool-history-legends-volume-marker"
        )

        chartPlot.coordinate(
            withNormalizedOffset: CGVector(dx: 0.78, dy: 0.69)
        ).tap()
        wait(seconds: 1.2)
        XCTAssertEqual(chartPlot.value as? String, "最新")
        attachScreenshot(named: "trade-tool-current-price-returned")
    }

    private func captureCurrentPriceReferenceStates(
        target: TargetApp
    ) {
        let app = XCUIApplication(
            bundleIdentifier: target.bundleIdentifier
        )
        start(app, target: target)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Target app did not enter the foreground."
        )
        if target == .tradeTool {
            openTradeToolDetailIfNeeded(in: app)
        }
        waitForAnimations()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        resetToOneHour(target: target, in: app)
        attachScreenshot(
            named: "\(target.attachmentPrefix)-current-price-visible"
        )

        let rightSwipeStart = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.24,
            dy: primaryChartGestureY
        ))
        let rightSwipeEnd = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.76,
            dy: primaryChartGestureY
        ))
        for round in 1...3 {
            rightSwipeStart.press(
                forDuration: 0.05,
                thenDragTo: rightSwipeEnd,
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
            wait(seconds: 1.5)
            attachScreenshot(named: String(
                format: "%@-current-price-offscreen-%02d",
                target.attachmentPrefix,
                round
            ))
        }

        resetToOneHour(target: target, in: app)
        let leftSwipeStart = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.76,
            dy: primaryChartGestureY
        ))
        let leftSwipeEnd = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.24,
            dy: primaryChartGestureY
        ))
        for round in 1...3 {
            leftSwipeStart.press(
                forDuration: 0.05,
                thenDragTo: leftSwipeEnd,
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
            wait(seconds: 1.5)
            attachScreenshot(named: String(
                format: "%@-current-price-left-swipe-%02d",
                target.attachmentPrefix,
                round
            ))
        }
    }

    func testCaptureTradeToolPreparedGestureStates() {
        capturePreparedGestureStates(
            target: .tradeTool
        )
    }

    func testCaptureBinanceCrosshairActiveVideo() {
        captureCrosshairActiveVideo(target: .binance)
    }

    func testCaptureTradeToolCrosshairActiveVideo() {
        captureCrosshairActiveVideo(target: .tradeTool)
    }

    func testCaptureTradeToolCrosshairLossless() {
        capturePersistentTradeToolCrosshair()
    }

    func testCaptureBinanceCrosshairTapToggleReference() {
        captureCrosshairTapToggleReference(target: .binance)
    }

    func testCaptureTradeToolCrosshairTapToggleReference() {
        captureCrosshairTapToggleReference(target: .tradeTool)
    }

    func testCaptureBinanceLatestFutureBlankLimit() {
        captureLatestFutureBlankLimit(target: .binance)
    }

    func testCaptureTradeToolLatestFutureBlankLimit() {
        captureLatestFutureBlankLimit(target: .tradeTool)
    }

    func testCaptureBinanceOldestBoundaryLimit() {
        captureOldestBoundaryLimit(target: .binance)
    }

    func testCaptureTradeToolOldestBoundaryLimit() {
        captureOldestBoundaryLimit(target: .tradeTool)
    }

    private func captureLatestFutureBlankLimit(
        target: TargetApp
    ) {
        let app = XCUIApplication(
            bundleIdentifier: target.bundleIdentifier
        )
        start(app, target: target)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Target app did not enter the foreground."
        )
        if target == .tradeTool {
            openTradeToolDetailIfNeeded(in: app)
        }
        waitForAnimations()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        resetToOneHour(target: target, in: app)

        let firstStart = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.68,
            dy: primaryChartGestureY
        ))
        let firstEnd = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.35,
            dy: primaryChartGestureY
        ))
        let edgeStart = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.35,
            dy: primaryChartGestureY
        ))
        let edgeEnd = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.05,
            dy: primaryChartGestureY
        ))
        for round in 1...calibrationRoundCount {
            XCTContext.runActivity(
                named: "future-blank-limit-round-\(round)"
            ) { _ in
                let start = round == 1 ? firstStart : edgeStart
                let end = round == 1 ? firstEnd : edgeEnd
                start.press(
                    forDuration: 0.05,
                    thenDragTo: end,
                    withVelocity: .slow,
                    thenHoldForDuration: 0
                )
                wait(seconds: 1.8)
                attachScreenshot(named: String(
                    format: "%@-future-blank-limit-%02d",
                    target.attachmentPrefix,
                    round
                ))
            }
        }
    }

    private func captureOldestBoundaryLimit(
        target: TargetApp
    ) {
        let app = XCUIApplication(
            bundleIdentifier: target.bundleIdentifier
        )
        start(app, target: target)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Target app did not enter the foreground."
        )
        if target == .tradeTool {
            openTradeToolDetailIfNeeded(in: app)
        }
        waitForAnimations()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        resetToOneHour(target: target, in: app)

        for _ in 1...calibrationRoundCount {
            window.pinch(withScale: 0.5, velocity: -1)
            wait(seconds: 0.7)
        }

        let start = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.12,
            dy: primaryChartGestureY
        ))
        let end = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.88,
            dy: primaryChartGestureY
        ))
        for approachRound in 1...oldestBoundaryApproachRoundCount {
            XCTContext.runActivity(
                named: "oldest-boundary-approach-\(approachRound)"
            ) { _ in
                start.press(
                    forDuration: 0.05,
                    thenDragTo: end,
                    withVelocity: .slow,
                    thenHoldForDuration: 0
                )
                wait(seconds: 0.5)
            }
        }
        attachScreenshot(
            named: "\(target.attachmentPrefix)-oldest-boundary-approach"
        )

        for round in 1...calibrationRoundCount {
            XCTContext.runActivity(
                named: "oldest-boundary-limit-round-\(round)"
            ) { _ in
                start.press(
                    forDuration: 0.05,
                    thenDragTo: end,
                    withVelocity: .slow,
                    thenHoldForDuration: 0
                )
                wait(seconds: 1.8)
                attachScreenshot(named: String(
                    format: "%@-oldest-boundary-limit-%02d",
                    target.attachmentPrefix,
                    round
                ))
            }
        }
    }

    private func capturePreparedGestureStates(
        target: TargetApp
    ) {
        let app = XCUIApplication(
            bundleIdentifier: target.bundleIdentifier
        )
        start(app, target: target)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Target app did not enter the foreground."
        )
        if target == .tradeTool {
            openTradeToolDetailIfNeeded(in: app)
        }
        waitForAnimations()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        attachScreenshot(
            named: "\(target.attachmentPrefix)-gesture-preflight"
        )
        resetToOneHour(target: target, in: app)
        captureCrosshairRounds(
            window: window,
            prefix: target.attachmentPrefix
        )
        captureLatestBoundaryRounds(
            target: target,
            app: app,
            window: window
        )
        captureInertiaRounds(
            target: target,
            app: app,
            window: window
        )
        captureZoomExtremes(
            target: target,
            app: app,
            window: window
        )
    }

    private func captureCrosshairActiveVideo(
        target: TargetApp
    ) {
        let app = XCUIApplication(
            bundleIdentifier: target.bundleIdentifier
        )
        start(app, target: target)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Target app did not enter the foreground."
        )
        if target == .tradeTool {
            openTradeToolDetailIfNeeded(in: app)
        }
        waitForAnimations()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        resetToOneHour(target: target, in: app)
        attachScreenshot(
            named: "\(target.attachmentPrefix)-crosshair-video-preflight"
        )

        let start = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.48,
            dy: primaryChartGestureY
        ))
        let end = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.70,
            dy: primaryChartGestureY + 0.02
        ))
        for round in 1...calibrationRoundCount {
            XCTContext.runActivity(
                named: "crosshair-active-video-round-\(round)"
            ) { _ in
                start.press(
                    forDuration: 0.55,
                    thenDragTo: end,
                    withVelocity: .slow,
                    thenHoldForDuration: 3.0
                )
                wait(seconds: 1.0)
            }
        }

        attachScreenshot(
            named: "\(target.attachmentPrefix)-crosshair-video-released"
        )
    }

    private func capturePersistentTradeToolCrosshair() {
        let target = TargetApp.tradeTool
        let app = XCUIApplication(
            bundleIdentifier: target.bundleIdentifier
        )
        app.launchArguments.append(
            "--chart-calibration-persist-crosshair"
        )
        start(app, target: target)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Target app did not enter the foreground."
        )
        openTradeToolDetailIfNeeded(in: app)
        waitForAnimations()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        resetToOneHour(target: target, in: app)

        let start = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.48,
            dy: primaryChartGestureY
        ))
        let end = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.70,
            dy: primaryChartGestureY + 0.02
        ))
        start.press(
            forDuration: 0.55,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 1
        )
        wait(seconds: 1)
        attachScreenshot(
            named: "trade-tool-crosshair-active-lossless-dev-a"
        )
    }

    private func captureCrosshairTapToggleReference(
        target: TargetApp
    ) {
        let app = XCUIApplication(
            bundleIdentifier: target.bundleIdentifier
        )
        start(app, target: target)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Target app did not enter the foreground."
        )
        if target == .tradeTool {
            openTradeToolDetailIfNeeded(in: app)
        }
        waitForAnimations()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        resetToOneHour(target: target, in: app)
        attachScreenshot(named:
            "\(target.attachmentPrefix)-crosshair-toggle-inactive"
        )

        let firstTap = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.46, dy: 0.36)
        )
        firstTap.tap()
        wait(seconds: 1)
        attachScreenshot(named:
            "\(target.attachmentPrefix)-crosshair-toggle-first-tap"
        )

        firstTap.tap()
        wait(seconds: 1)
        attachScreenshot(named:
            "\(target.attachmentPrefix)-crosshair-toggle-second-tap"
        )

        let historicalTap = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.28, dy: 0.39)
        )
        historicalTap.tap()
        wait(seconds: 1)
        attachScreenshot(named:
            "\(target.attachmentPrefix)-crosshair-historical-first-tap"
        )
        historicalTap.tap()
        wait(seconds: 1)

        let dragStart = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.40, dy: 0.36)
        )
        let dragEnd = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.68, dy: 0.43)
        )
        dragStart.press(
            forDuration: 0.55,
            thenDragTo: dragEnd,
            withVelocity: .slow,
            thenHoldForDuration: 0.5
        )
        wait(seconds: 1)
        attachScreenshot(named:
            "\(target.attachmentPrefix)-crosshair-long-press-released"
        )
        dragEnd.tap()
        wait(seconds: 1)
        attachScreenshot(named:
            "\(target.attachmentPrefix)-crosshair-after-dismiss-tap"
        )
    }

    private func captureCrosshairRounds(
        window: XCUIElement,
        prefix: String
    ) {
        let start = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.48,
            dy: primaryChartGestureY
        ))
        let end = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.70,
            dy: primaryChartGestureY + 0.02
        ))

        for round in 1...calibrationRoundCount {
            XCTContext.runActivity(
                named: "crosshair-round-\(round)"
            ) { _ in
                start.press(
                    forDuration: 0.45,
                    thenDragTo: end,
                    withVelocity: .slow,
                    thenHoldForDuration: 0.8
                )
                wait(seconds: 0.25)
            }
        }
        attachScreenshot(named: "\(prefix)-crosshair-released")
    }

    private func captureLatestBoundaryRounds(
        target: TargetApp,
        app: XCUIApplication,
        window: XCUIElement
    ) {
        let start = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.68,
            dy: primaryChartGestureY
        ))
        let end = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.35,
            dy: primaryChartGestureY
        ))

        for round in 1...calibrationRoundCount {
            resetToOneHour(target: target, in: app)
            XCTContext.runActivity(
                named: "latest-boundary-round-\(round)"
            ) { _ in
                start.press(
                    forDuration: 0.05,
                    thenDragTo: end,
                    withVelocity: .slow,
                    thenHoldForDuration: 0
                )
                wait(seconds: 1.8)
                attachScreenshot(named: String(
                    format: "%@-latest-boundary-%02d",
                    target.attachmentPrefix,
                    round
                ))
            }
        }
    }

    private func captureInertiaRounds(
        target: TargetApp,
        app: XCUIApplication,
        window: XCUIElement
    ) {
        let preloadStart = window.coordinate(
            withNormalizedOffset: CGVector(
                dx: 0.34,
                dy: primaryChartGestureY
            )
        )
        let preloadEnd = window.coordinate(
            withNormalizedOffset: CGVector(
                dx: 0.61,
                dy: primaryChartGestureY
            )
        )
        let flickStart = window.coordinate(
            withNormalizedOffset: CGVector(
                dx: 0.42,
                dy: primaryChartGestureY
            )
        )
        let flickEnd = window.coordinate(
            withNormalizedOffset: CGVector(
                dx: 0.72,
                dy: primaryChartGestureY
            )
        )

        for round in 1...calibrationRoundCount {
            resetToOneHour(target: target, in: app)
            preloadStart.press(
                forDuration: 0.05,
                thenDragTo: preloadEnd,
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
            wait(seconds: 0.8)
            XCTContext.runActivity(
                named: "inertia-round-\(round)"
            ) { _ in
                flickStart.press(
                    forDuration: 0.05,
                    thenDragTo: flickEnd,
                    withVelocity: .fast,
                    thenHoldForDuration: 0
                )
                wait(seconds: 2.2)
                attachScreenshot(named: String(
                    format: "%@-inertia-%02d",
                    target.attachmentPrefix,
                    round
                ))
            }
        }
    }

    private func captureZoomExtremes(
        target: TargetApp,
        app: XCUIApplication,
        window: XCUIElement
    ) {
        resetToOneHour(target: target, in: app)
        for round in 1...calibrationRoundCount {
            XCTContext.runActivity(
                named: "zoom-in-round-\(round)"
            ) { _ in
                window.pinch(withScale: 1.5, velocity: 1)
                wait(seconds: 0.7)
            }
        }
        attachScreenshot(
            named: "\(target.attachmentPrefix)-zoom-maximum"
        )

        resetToOneHour(target: target, in: app)
        for round in 1...calibrationRoundCount {
            XCTContext.runActivity(
                named: "zoom-out-round-\(round)"
            ) { _ in
                window.pinch(withScale: 0.5, velocity: -1)
                wait(seconds: 0.7)
            }
        }
        attachScreenshot(
            named: "\(target.attachmentPrefix)-zoom-minimum"
        )
        resetToOneHour(target: target, in: app)
    }

    private func selectTradeToolInterval(
        _ title: String,
        in app: XCUIApplication
    ) {
        let intervals = ["1分": "1m", "3分": "3m", "5分": "5m", "15分": "15m", "1小时": "1h", "4小时": "4h", "1天": "1d"]
        guard let key = intervals[title] else { XCTFail("Unknown interval " + title); return }
        if !app.buttons["chart-interval." + key].exists {
            app.buttons["chart-interval.edit"].tap()
            app.buttons["恢复默认周期"].tap()
            let favorite = app.buttons["interval-settings.favorite." + key]
            XCTAssertTrue(favorite.waitForExistence(timeout: 5))
            if favorite.value as? String != "1" { favorite.tap() }
            app.buttons["关闭"].firstMatch.tap()
        }
        XCTAssertTrue(app.buttons["chart-interval." + key].waitForExistence(timeout: 5))
        app.buttons["chart-interval." + key].tap()
    }

    private func resetToOneHour(
        target: TargetApp,
        in app: XCUIApplication
    ) {
        if target == .tradeTool {
            selectTradeToolInterval(target.alternateIntervalLabel, in: app)
            selectTradeToolInterval(target.oneHourLabel, in: app)
            return
        }
        let alternate = element(
            labeled: target.alternateIntervalLabel,
            in: app
        )
        let oneHour = element(
            labeled: target.oneHourLabel,
            in: app
        )
        XCTAssertTrue(
            alternate.waitForExistence(timeout: 5),
            "Missing interval \(target.alternateIntervalLabel)."
        )
        XCTAssertTrue(
            oneHour.waitForExistence(timeout: 5),
            "Missing interval \(target.oneHourLabel)."
        )
        alternate.tap()
        wait(seconds: 1.0)
        oneHour.tap()
        wait(seconds: 1.4)
    }

    private func element(
        labeled label: String,
        identifier: String? = nil,
        in app: XCUIApplication
    ) -> XCUIElement {
        if let identifier {
            return app.descendants(matching: .any)
                .matching(
                    NSPredicate(
                        format: "identifier == %@ OR label == %@",
                        identifier,
                        label
                    )
                )
                .firstMatch
        }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    private func tapIndicator(
        _ label: String,
        in app: XCUIApplication
    ) {
        let indicator = element(labeled: label, in: app)
        XCTAssertTrue(
            indicator.waitForExistence(timeout: 5),
            "Missing Binance indicator \(label)."
        )
        indicator.tap()
        wait(seconds: 1.0)
        if app.staticTexts["指标"].exists {
            XCTFail(
                "Binance indicator picker opened instead of toggling "
                    + "\(label); discard this sample."
            )
        }
    }

    private func tapBinanceIndicatorInBar(
        _ label: String,
        in app: XCUIApplication
    ) {
        guard let indicator = bringBinanceIndicatorIntoView(
            label,
            in: app
        ) else {
            XCTFail("Missing Binance chart indicator \(label).")
            return
        }
        indicator.tap()
        wait(seconds: 1.0)
    }

    private func bringBinanceIndicatorIntoView(
        _ label: String,
        in app: XCUIApplication
    ) -> XCUIElement? {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            return nil
        }

        func visibleControl() -> XCUIElement? {
            app.buttons.matching(
                NSPredicate(format: "label == %@", label)
            ).allElementsBoundByIndex.first {
                let frame = $0.frame
                return frame.width > 0
                    && frame.height > 0
                    && frame.minX >= window.frame.minX
                    && frame.maxX <= window.frame.maxX - 40
                    && frame.minY >= window.frame.minY
                    && frame.maxY <= window.frame.maxY
                    && $0.isHittable
            }
        }

        if let visible = visibleControl() {
            return visible
        }

        let barLabels = [
            "MA", "EMA", "BOLL", "SAR", "AVL", "SUPER", "VOL",
            "MACD", "RSI", "KDJ", "OBV", "WR", "StochRSI", "ATR",
            "O.I.", "L.S Acco.", "L.S Posit.", "L.S Ratio",
            "B.S Vol.", "Basis",
        ]
        func visibleBarAnchor() -> XCUIElement? {
            barLabels.lazy.compactMap({ barLabel in
                app.buttons.matching(
                    NSPredicate(format: "label == %@", barLabel)
                ).allElementsBoundByIndex.first { candidate in
                    let frame = candidate.frame
                    return frame.width > 0
                        && frame.height > 0
                        && frame.minX >= window.frame.minX
                        && frame.maxX <= window.frame.maxX - 40
                        && frame.minY >= window.frame.minY
                        && frame.maxY <= window.frame.maxY
                }
            }).first
        }

        var anchor = visibleBarAnchor()
        if anchor == nil {
            let detailTable = app.tables.firstMatch
            for _ in 0..<5 where anchor == nil {
                detailTable.swipeUp(velocity: .slow)
                wait(seconds: 0.5)
                anchor = visibleBarAnchor()
            }
        }
        guard let anchor else {
            return nil
        }
        let normalizedY = anchor.frame.midY / window.frame.height
        let leftStart = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.82, dy: normalizedY)
        )
        let leftEnd = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.18, dy: normalizedY)
        )
        for _ in 0..<10 {
            leftStart.press(
                forDuration: 0.05,
                thenDragTo: leftEnd,
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
            wait(seconds: 0.35)
            if let visible = visibleControl() {
                return visible
            }
        }

        for _ in 0..<12 {
            leftEnd.press(
                forDuration: 0.05,
                thenDragTo: leftStart,
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
            wait(seconds: 0.35)
            if let visible = visibleControl() {
                return visible
            }
        }
        return nil
    }

    private func bringBinanceSettingsRowIntoView(
        _ label: String,
        table: XCUIElement,
        in app: XCUIApplication
    ) -> XCUIElement? {
        let row = app.staticTexts[label].firstMatch
        if row.exists, row.isHittable {
            return row
        }
        for _ in 0..<12 {
            table.swipeUp(velocity: .slow)
            wait(seconds: 0.35)
            if row.exists, row.isHittable {
                return row
            }
        }
        for _ in 0..<12 {
            table.swipeDown(velocity: .slow)
            wait(seconds: 0.35)
            if row.exists, row.isHittable {
                return row
            }
        }
        return nil
    }

    private func openBinanceIndicatorPicker(
        in app: XCUIApplication
    ) -> Bool {
        if app.staticTexts["指标"].exists,
            binanceIndicatorPickerButton("VOL", in: app) != nil
        {
            return true
        }
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            return false
        }
        let barLabels = [
            "MA", "EMA", "BOLL", "SAR", "AVL", "SUPER", "VOL",
            "MACD", "RSI", "KDJ", "OBV", "WR", "StochRSI", "ATR",
            "O.I.", "L.S Acco.", "L.S Posit.", "L.S Ratio",
            "B.S Vol.", "Basis",
        ]
        func anchor() -> XCUIElement? {
            barLabels.lazy.compactMap { label in
                app.buttons.matching(
                    NSPredicate(format: "label == %@", label)
                ).allElementsBoundByIndex.first { candidate in
                    let frame = candidate.frame
                    return frame.height >= 28
                        && frame.height <= 32
                        && frame.width > 0
                        && frame.minX >= window.frame.minX
                        && frame.maxX <= window.frame.maxX - 40
                        && frame.minY >= window.frame.minY
                        && frame.minY <= window.frame.maxY - 90
                }
            }.first
        }

        var visibleAnchor = anchor()
        let detailTable = app.tables.firstMatch
        for _ in 0..<6 where visibleAnchor == nil {
            detailTable.swipeUp(velocity: .slow)
            wait(seconds: 0.6)
            visibleAnchor = anchor()
        }
        guard let visibleAnchor else {
            return false
        }
        let normalizedY = (
            visibleAnchor.frame.minY
                + min(5, visibleAnchor.frame.height / 2)
        ) / window.frame.height
        window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.95, dy: normalizedY)
        ).tap()
        wait(seconds: 1.0)
        return app.staticTexts["指标"].waitForExistence(timeout: 5)
    }

    private func binanceIndicatorPickerButton(
        _ label: String,
        in app: XCUIApplication
    ) -> XCUIElement? {
        app.buttons.matching(
            NSPredicate(format: "label == %@", label)
        ).allElementsBoundByIndex.first { button in
            button.frame.width >= 70 && button.frame.height >= 34
        }
    }

    private func dismissBinanceIndicatorPicker(
        in app: XCUIApplication
    ) {
        let title = app.staticTexts["指标"].firstMatch
        XCTAssertTrue(
            title.waitForExistence(timeout: 5),
            "Binance indicator picker is not open."
        )
        let window = app.windows.firstMatch
        let handleY = max(
            0.1,
            (title.frame.minY - 24) / window.frame.height
        )
        window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: handleY)
        ).press(
            forDuration: 0.05,
            thenDragTo: window.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)
            ),
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
        for _ in 0..<6 {
            if binanceIndicatorPickerButton("VOL", in: app) == nil {
                return
            }
            wait(seconds: 0.3)
        }
        XCTFail("Binance indicator picker did not close.")
    }

    private func returnBinanceDetailToTop(
        in app: XCUIApplication
    ) {
        let oneHour = element(labeled: "1小时", in: app)
        let detailTable = app.tables.firstMatch
        for _ in 0..<5 where !oneHour.isHittable {
            detailTable.swipeDown(velocity: .fast)
            wait(seconds: 0.5)
        }
        XCTAssertTrue(
            oneHour.isHittable,
            "Binance chart did not return to its visible top state."
        )
    }

    private func requireBinanceChartDetail(
        in app: XCUIApplication
    ) -> Bool {
        if app.staticTexts["指标设置"].exists {
            XCTFail(
                "Binance is on an indicator settings page. Return to the "
                    + "public 1-hour chart detail before running this test."
            )
            return false
        }

        let oneHour = element(labeled: "1小时", in: app)
        guard oneHour.waitForExistence(timeout: 5) else {
            XCTFail(
                "Binance public 1-hour chart detail is not prepared. No "
                    + "third-party control was tapped."
            )
            return false
        }
        return true
    }

    private func setBinanceIndicator(
        _ label: String,
        enabled: Bool,
        in app: XCUIApplication
    ) {
        let indicator = element(labeled: label, in: app)
        XCTAssertTrue(
            indicator.waitForExistence(timeout: 5),
            "Missing Binance indicator \(label)."
        )
        if indicator.isSelected != enabled {
            indicator.tap()
            wait(seconds: 1.0)
        }
    }

    private func assertTradeToolPanelOrder(
        _ labels: [String],
        in app: XCUIApplication
    ) throws {
        let chart = element(labeled: "K线图", in: app)
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        let value = try XCTUnwrap(chart.value as? String)
        var cursor = value.startIndex
        for label in labels {
            let range = try XCTUnwrap(
                value.range(of: label, range: cursor..<value.endIndex),
                "Missing or out-of-order panel \(label): \(value)"
            )
            cursor = range.upperBound
        }
    }

    private func setTradeToolIndicator(
        _ label: String,
        enabled: Bool,
        in app: XCUIApplication
    ) {
        let indicator = app.buttons[
            "market-chart-quick-indicator-\(label)"
        ]
        XCTAssertTrue(
            indicator.waitForExistence(timeout: 5),
            "Missing Trade Tool indicator \(label)."
        )
        let expected = enabled ? "已开启" : "已关闭"
        if indicator.value as? String != expected {
            let strip = app.scrollViews["market-chart-quick-indicator-strip"]
            for _ in 0..<16 where !indicator.isHittable {
                let moveRight = indicator.frame.midX < strip.frame.minX
                strip.coordinate(withNormalizedOffset: CGVector(
                    dx: moveRight ? 0.2 : 0.8,
                    dy: 0.5
                )).press(
                    forDuration: 0.05,
                    thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(
                        dx: moveRight ? 0.8 : 0.2,
                        dy: 0.5
                    )),
                    withVelocity: .slow,
                    thenHoldForDuration: 0.15
                )
            }
            XCTAssertTrue(indicator.isHittable)
            indicator.tap()
            wait(seconds: 0.8)
        }
        XCTAssertEqual(indicator.value as? String, expected)
    }

    private func attachScreenshot(named name: String) {
        for sample in 1...2 {
            let attachment = XCTAttachment(
                screenshot: XCUIScreen.main.screenshot()
            )
            attachment.name = String(
                format: "%@-sample-%02d",
                name,
                sample
            )
            attachment.lifetime = .keepAlways
            add(attachment)
            if sample == 1 {
                wait(seconds: 0.8)
            }
        }
    }

    private func attachText(named name: String, contents: String) {
        let attachment = XCTAttachment(
            data: Data(contents.utf8),
            uniformTypeIdentifier: "public.plain-text"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachImmediateScreenshot(named name: String) {
        let attachment = XCTAttachment(
            screenshot: XCUIScreen.main.screenshot()
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func start(
        _ app: XCUIApplication,
        target: TargetApp
    ) {
        if target == .tradeTool {
            app.launch()
        } else {
            app.activate()
        }
    }

    private func openTradeToolDetailIfNeeded(
        in app: XCUIApplication
    ) {
        let chart = app.descendants(matching: .any)["market-chart-plot"]
        if chart.waitForExistence(timeout: 3) {
            return
        }
        let marketTitle = app.staticTexts["合约自选"]
        guard marketTitle.waitForExistence(timeout: 10) else {
            return
        }
        let symbol = app.staticTexts["BTCUSDC"].firstMatch
        XCTAssertTrue(
            symbol.waitForExistence(timeout: 10),
            "BTCUSDC was not available in the Dev B market list."
        )
        symbol.tap()
        XCTAssertTrue(
            chart.waitForExistence(timeout: 15),
            "Trade Tool did not open the BTCUSDC chart detail."
        )
    }

    private func waitForAnimations() {
        wait(seconds: 1.2)
    }

    private func wait(seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

/// Opt-in smoke against a configured account without an exchange binding.
final class IntegratedNativeUITests: XCTestCase {
    /// Explicitly opted in; reads market data only. App logs provide the timing
    /// boundaries, since accessibility waits include XCTest polling overhead.
    func testConfiguredKlineFirstFramePerformance() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["INTEGRATION_KLINE_PERFORMANCE"] == "1",
              let password = environment["INTEGRATION_QA_PASSWORD"], !password.isEmpty,
              let account = environment["INTEGRATION_QA_ACCOUNT"],
              let baseURL = environment["INTEGRATION_QA_API_BASE"] else {
            throw XCTSkip("Requires explicit performance opt-in and an unbound QA account")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.waibao2025.trade.integrated")
        addUIInterruptionMonitor(withDescription: "Password save prompt during chart measurement") { alert in
            for title in ["以后", "暂不", "Not Now"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        app.launchArguments = ["-selectedAPIOrigin", baseURL]
        app.terminate()
        app.launch()
        if app.secureTextFields.firstMatch.waitForExistence(timeout: 5) {
            app.textFields.firstMatch.tap()
            app.textFields.firstMatch.typeText(account)
            app.secureTextFields.firstMatch.tap()
            app.secureTextFields.firstMatch.typeText(password)
            let agreement = app.buttons["login.agreement"]
            if (agreement.value as? String) != "1" { agreement.tap() }
            app.buttons["登录"].tap()
        }
        let market = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "BTCUSDT、")).firstMatch
        XCTAssertTrue(market.waitForExistence(timeout: 30))
        let postpone = app.buttons["以后"]
        if postpone.waitForExistence(timeout: 3) { postpone.tap() }
        let warmCount = Int(environment["INTEGRATION_KLINE_WARM_COUNT"] ?? "20") ?? 20
        let coldCount = Int(environment["INTEGRATION_KLINE_COLD_COUNT"] ?? "5") ?? 5
        for index in 0..<(warmCount + coldCount) {
            if index >= warmCount {
                app.terminate()
                app.launch()
            }
            XCTAssertTrue(market.waitForExistence(timeout: 20))
            market.tap()
            let chart = app.descendants(matching: .any)["market-chart-plot"].firstMatch
            XCTAssertTrue(chart.waitForExistence(timeout: 20))
            let loaded = expectation(for: NSPredicate(format: "label == %@", "K线图"), evaluatedWith: chart)
            wait(for: [loaded], timeout: 30)
            // iOS may show this asynchronously after login, once the chart is open.
            let delayedPasswordPrompt = app.buttons["以后"]
            if delayedPasswordPrompt.exists { delayedPasswordPrompt.tap() }
            if index == 0 || index == warmCount - 1 || index == warmCount + coldCount - 1 {
                capture(app, "kline-first-frame-\(index)")
            }
            app.buttons["market-chart-back"].tap()
        }
    }

    func testConfiguredLoginMarketAndBusinessPages() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let password = environment["INTEGRATION_QA_PASSWORD"] ?? environment["INTEGRATION_LOCAL_QA_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Set the isolated QA credential in the test-run environment")
        }
        let baseURL = environment["INTEGRATION_QA_API_BASE"] ?? "http://127.0.0.1:8787/"
        let accountName = environment["INTEGRATION_QA_ACCOUNT"] ?? "local-qa@example.invalid"
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.waibao2025.trade.integrated")
        addUIInterruptionMonitor(withDescription: "System password save prompt") { alert in
            for title in ["以后", "暂不", "Not Now"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        app.launchArguments = ["-selectedAPIOrigin", baseURL]
        app.terminate()
        app.launch()
        if !app.secureTextFields.firstMatch.waitForExistence(timeout: 8) {
            app.buttons["我的"].firstMatch.tap()
            let logout = app.buttons["退出登录"].firstMatch
            for _ in 0..<5 where !logout.isHittable { app.swipeUp() }
            XCTAssertTrue(logout.isHittable)
            logout.tap()
            let confirmLogout = app.buttons["退出登录"].firstMatch
            XCTAssertTrue(confirmLogout.waitForExistence(timeout: 5))
            confirmLogout.tap()
        }
        if app.secureTextFields.firstMatch.waitForExistence(timeout: 8) {
            let account = app.textFields.firstMatch
            account.tap(); account.typeText(accountName)
            let secure = app.secureTextFields.firstMatch
            secure.tap(); secure.typeText(password)
            let agreement = app.buttons["login.agreement"]
            XCTAssertTrue(agreement.exists)
            if (agreement.value as? String) != "1" { agreement.tap() }
            XCTAssertTrue(app.buttons["登录"].isEnabled)
            app.buttons["登录"].tap()
            capture(app, "integrated-login-transition")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "integrated-login-state"; tree.lifetime = .keepAlways; add(tree)
        }
        let market = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "BTCUSDT、")).firstMatch
        XCTAssertTrue(market.waitForExistence(timeout: 30), "Real BTC ticker should appear")
        let postponePasswordSave = app.buttons["以后"]
        if postponePasswordSave.waitForExistence(timeout: 5) {
            postponePasswordSave.tap()
            XCTAssertTrue(postponePasswordSave.waitForNonExistence(timeout: 5))
        }
        let marketReady = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: market)
        wait(for: [marketReady], timeout: 5)
        capture(app, "integrated-ios-market")
        market.tap()
        let chart = app.descendants(matching: .any)["market-chart-plot"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 20))
        let loaded = expectation(for: NSPredicate(format: "label == %@", "K线图"), evaluatedWith: chart)
        wait(for: [loaded], timeout: 30)
        capture(app, "integrated-ios-chart")
        let submit = app.buttons["chart-ticket.submit"].firstMatch
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled, "Unbound account must not place an order")
        app.buttons["返回"].firstMatch.tap()
        app.buttons["持仓"].firstMatch.tap()
        XCTAssertTrue(app.buttons["限价委托"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["开仓"].exists)
        app.buttons["信号"].firstMatch.tap()
        XCTAssertTrue(app.buttons["内部信号规则"].waitForExistence(timeout: 10))
        app.buttons["我的"].firstMatch.tap()
        XCTAssertTrue(app.buttons["profile.bind"].waitForExistence(timeout: 10))
        capture(app, "integrated-ios-profile")
        app.buttons["profile.bind"].tap()
        XCTAssertTrue(app.buttons["确认绑定"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["确认绑定"].isEnabled)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Deterministic native visual checks. Only local static capital / EMA previews allow POST.
final class WebParityUITests: XCTestCase {
  private let app = XCUIApplication(bundleIdentifier: "com.waibao2025.trade.integrated")
  override func setUpWithError() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }
  private func launch(_ page: String, _ options: [String] = []) {
    app.terminate()
    app.launchArguments = ["--web-parity-fixture", page] + options
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
  }
  private func capture(_ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = "web-parity-" + name
    image.lifetime = .keepAlways
    add(image)
  }

  func testStrategyEditorKeepsDraftChoicesAndFocusesName() {
    launch("strategy-editor")
    app.buttons["编辑策略名称"].tap()
    let name = app.textFields["strategy.name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    name.typeText("测试\n")
    XCTAssertTrue(app.staticTexts["新策略测试"].waitForExistence(timeout: 5))
    let reduce = app.textFields["strategy.level.0.reduce"]
    XCTAssertTrue(reduce.exists)
    reduce.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    reduce.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
    XCTAssertTrue(reduce.exists, "Clearing the percentage must preserve the enabled reduction input")
    XCTAssertEqual(reduce.value as? String, "")
    XCTAssertTrue(app.buttons["strategy.level.0.reduce-enabled"].isSelected)
    reduce.typeText("20")
    app.buttons["移动止损位"].tap()
    let absolute = app.textFields["strategy.level.0.absolute-stop"]
    let trailing = app.textFields["strategy.level.0.trailing-stop"]
    XCTAssertTrue(absolute.waitForExistence(timeout: 3))
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.46))
      .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.24)))
    absolute.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    absolute.typeText(XCUIKeyboardKey.delete.rawValue + "2")
    trailing.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    trailing.typeText(XCUIKeyboardKey.delete.rawValue + "3")
    XCTAssertEqual(absolute.value as? String, "2")
    XCTAssertEqual(trailing.value as? String, "3")
    capture("strategy-independent-inputs-keyboard")
    app.buttons["编辑策略名称"].tap()
    app.textFields["strategy.name"].typeText("\n")
    if !app.buttons["添加层级"].isHittable { app.swipeUp() }
    app.buttons["添加层级"].tap()
    XCTAssertTrue(app.staticTexts["剩余仓位 80%"].waitForExistence(timeout: 3))
    capture("strategy-new-level")
  }

  func testStrategyListRowEditingAndSwipeDelete() {
    launch("strategies")
    let row = app.descendants(matching: .any)["strategy.row.1"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    XCTAssertEqual(row.value as? String, "使用中")
    XCTAssertFalse(app.buttons["strategy.use.1"].exists)
    XCTAssertFalse(app.buttons["使用"].exists)
    XCTAssertFalse(app.buttons["删除"].exists)
    XCTAssertTrue(app.staticTexts["L1：当 RR≥1，卖出 30%，止损位移动到 0R 处"].exists)
    let edit = app.buttons["strategy.edit.1"]
    let summary = app.staticTexts["L1：当 RR≥1，卖出 30%，止损位移动到 0R 处"]
    XCTAssertTrue(edit.exists)
    XCTAssertGreaterThan(edit.frame.midX, row.frame.midX)
    XCTAssertGreaterThan(edit.frame.minY, summary.frame.maxY)
    XCTAssertGreaterThanOrEqual(app.buttons["strategy.create"].frame.height, 52)
    capture("strategy-list-compact")
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2)).tap()
    XCTAssertFalse(app.buttons["保存策略"].exists, "Selecting a card must not enter the editor")
    XCTAssertTrue(app.staticTexts["确认选择"].waitForExistence(timeout: 3))
    app.buttons["strategy.selection.cancel"].tap()
    XCTAssertTrue(row.exists, "Cancelling selection must stay on the strategy list")
    edit.tap()
    XCTAssertTrue(app.buttons["保存策略"].waitForExistence(timeout: 5))
    app.buttons["返回"].firstMatch.tap()
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.swipeLeft()
    XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 3))
    capture("strategy-list-swipe-delete")
    app.buttons["删除"].tap()
    XCTAssertTrue(app.staticTexts["确认删除"].waitForExistence(timeout: 3))
    app.buttons["取消"].tap()
  }

  func testIndicatorCardsSuperOpacityAndProfileMenu() {
    for (options, appearance) in [([String](), "light"), (["--fixture-dark"], "dark")] {
      launch("market", options + ["--fixture-entry-ready"])
      app.buttons["搜索币种、币对或合约"].tap()
      XCTAssertEqual(app.buttons["pairs.favorite.BTCUSDT"].value as? String, "已自选")
      XCTAssertEqual(app.buttons["pairs.favorite.ADAUSDT"].value as? String, "未自选")
      capture("pair-stars-" + appearance)
      app.buttons["pairs.select.BTCUSDT"].tap()
      let leverage = app.buttons["market-chart-leverage"]
      XCTAssertTrue(leverage.waitForExistence(timeout: 10))
      XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "杠杆 × 50"), object: leverage)], timeout: 5), .completed)
      capture("super-connected-fill-" + appearance)
      app.buttons["market-chart-indicator-settings-shortcut"].tap()
      let tabs = ["MA", "EMA", "BOLL", "SAR"].map { app.buttons["indicator-settings.tab." + $0] }
      XCTAssertTrue(tabs[0].waitForExistence(timeout: 5))
      for tab in tabs { XCTAssertEqual(tab.frame.minY, tabs[0].frame.minY, accuracy: 1) }
      app.buttons["indicator-settings.tab.Super"].tap()
      let opacity = app.sliders["indicator-settings.super-opacity"]
      XCTAssertTrue(opacity.waitForExistence(timeout: 5))
      let initialOpacity = opacity.value as? String
      XCTAssertNotNil(initialOpacity)
      opacity.adjust(toNormalizedSliderPosition: 0)
      XCTAssertEqual(opacity.value as? String, "0%")
      opacity.adjust(toNormalizedSliderPosition: 1)
      // XCTest drags can land one native slider step short of the endpoint.
      let upperValue = Int((opacity.value as? String ?? "").replacingOccurrences(of: "%", with: ""))
      XCTAssertGreaterThanOrEqual(upperValue ?? 0, 99)
      opacity.adjust(toNormalizedSliderPosition: 0.65)
      let savedOpacity = opacity.value as? String
      XCTAssertNotNil(savedOpacity)
      XCTAssertTrue(app.staticTexts[savedOpacity!].exists)
      capture("indicator-super-opacity-" + appearance)
      app.buttons["应用"].tap()
      XCTAssertTrue(leverage.waitForExistence(timeout: 5))
      app.buttons["market-chart-indicator-settings-shortcut"].tap()
      app.buttons["indicator-settings.tab.Super"].tap()
      XCTAssertTrue(opacity.waitForExistence(timeout: 5))
      XCTAssertEqual(opacity.value as? String, savedOpacity)
      XCTAssertTrue(app.staticTexts[savedOpacity!].exists)
      app.buttons["返回"].firstMatch.tap()
      app.buttons["返回"].firstMatch.tap()
      app.buttons["我的"].firstMatch.tap()
      let mode = app.buttons["profile.switchMode"], collect = app.buttons["profile.collectBalance"]
      XCTAssertTrue(collect.waitForExistence(timeout: 5))
      XCTAssertTrue(mode.exists)
      XCTAssertEqual(mode.label, "切换带单模式")
      let settings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "设置")).firstMatch
      XCTAssertGreaterThan(mode.frame.minY, settings.frame.maxY)
      XCTAssertGreaterThan(mode.frame.width, collect.frame.width)
      XCTAssertFalse(app.buttons["profile.floatingPositions"].exists)
      capture("profile-mode-menu-" + appearance)
      mode.tap()
      app.buttons["确认切换"].tap()
      XCTAssertTrue(app.staticTexts["带单组合可用余额 (USDT)"].waitForExistence(timeout: 5))
      XCTAssertEqual(mode.label, "切换合约模式")
      capture("profile-contract-menu-" + appearance)
      mode.tap()
      app.buttons["确认切换"].tap()
      XCTAssertTrue(app.staticTexts["合约余额 (USDT)"].waitForExistence(timeout: 5))
      app.buttons["持仓"].firstMatch.tap()
      let segments = ["positions", "limits", "history"].map { app.buttons["positions.tabs." + $0] }
      XCTAssertTrue(segments[0].waitForExistence(timeout: 5))
      for segment in segments { XCTAssertEqual(segment.frame.width, segments[0].frame.width, accuracy: 1) }
      XCTAssertGreaterThanOrEqual(segments[0].frame.height, 44)
      XCTAssertLessThanOrEqual(segments[0].frame.minX,
        app.otherElements["positions.header"].frame.minX + 12)
      segments[2].tap()
      capture("positions-equal-segments-" + appearance)
    }
    launch("signals")
    XCTAssertTrue(app.staticTexts["自有"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["85分"].exists)
  }

  func testSignalListKeepsSnapshotAndScrollPositionAcrossTabsAndBackground() {
    launch("signals", ["--fixture-page-state"])
    let first = app.buttons["signals.card.1"]
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["读取 1 · 测试信号 1"].exists)
    app.scrollViews["signals.list"].swipeUp()
    let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "signals.card."))
    let visible = cards.allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY > 120 }!
    let id = visible.identifier
    let previousY = visible.frame.minY
    app.buttons["我的"].firstMatch.tap()
    XCTAssertTrue(app.buttons["profile.switchMode"].waitForExistence(timeout: 5))
    app.buttons["信号"].firstMatch.tap()
    let retained = app.buttons[id]
    XCTAssertTrue(retained.waitForExistence(timeout: 5))
    XCTAssertEqual(retained.frame.minY, previousY, accuracy: 2)
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "读取 2 ·")).firstMatch.exists)
    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(retained.waitForExistence(timeout: 5))
    XCTAssertEqual(retained.frame.minY, previousY, accuracy: 2)
    capture("signals-retained-scroll")
  }

  func testChartAccountFeedbackInBothAppearances() {
    for (options, name) in [([String](), "light"), (["--fixture-dark"], "dark")] {
      launch("market", options + ["--fixture-entry-ready", "--fixture-extra-leverage"])
      app.buttons["搜索币种、币对或合约"].tap()
      app.buttons["pairs.select.BTCUSDT"].tap()
      let ticket = app.buttons["chart-ticket.submit"]
      XCTAssertTrue(ticket.waitForExistence(timeout: 10))
      XCTAssertEqual(ticket.label, "在 K 线图上选择止损价开仓")
      let star = app.buttons["market-chart-favorite"]
      XCTAssertEqual(star.value as? String, "已收藏")
      capture("feedback-chart-" + name)
      app.buttons["market-chart-leverage"].tap()
      let choice = app.descendants(matching: .any)["chart-leverage.bracket.25"]
      XCTAssertTrue(choice.waitForExistence(timeout: 5))
      XCTAssertTrue(app.staticTexts["杠杆"].firstMatch.exists)
      XCTAssertFalse(app.staticTexts["自动杠杆"].exists)
      XCTAssertFalse(app.descendants(matching: .any)["chart-leverage.bracket.5"].exists)
      capture("feedback-leverage-" + name)
      choice.tap()
      app.buttons["chart-leverage.confirm"].tap()
      XCTAssertTrue(app.buttons["market-chart-leverage"].label.contains("杠杆 × 25"))

      launch("profile", options)
      let refresh = app.buttons["profile.refreshBalance"]
      XCTAssertTrue(refresh.waitForExistence(timeout: 10))
      let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: refresh)
      XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
      XCTAssertTrue(refresh.isHittable)
      XCTAssertGreaterThanOrEqual(refresh.frame.height, 44)
      refresh.tap()
      capture("feedback-profile-" + name)
      app.buttons["profile.switchMode"].tap()
      app.buttons["确认切换"].tap()
      XCTAssertTrue(app.staticTexts["带单组合可用余额 (USDT)"].waitForExistence(timeout: 5))
      capture("feedback-profile-lead-" + name)
    }
    launch("signals")
    XCTAssertTrue(app.staticTexts["自有"].waitForExistence(timeout: 5))
    capture("feedback-signals")
  }

  func testChartAutoIntervalPanelAndLimitLinesInBothAppearances() {
    for (options, appearance) in [([String](), "light"), (["--fixture-dark"], "dark")] {
      launch("market", options + ["--fixture-entry-ready"])
      capture("compact-market-" + appearance)
      app.buttons["搜索币种、币对或合约"].tap()
      app.buttons["pairs.select.BTCUSDT"].tap()
      let ticket = app.buttons["chart-ticket.submit"]
      XCTAssertTrue(ticket.waitForExistence(timeout: 10))
      XCTAssertEqual(ticket.label, "在 K 线图上选择止损价开仓")
      XCTAssertFalse(ticket.isEnabled)
      let auto = app.descendants(matching: .any)["chart-interval.auto"].firstMatch
      XCTAssertTrue(auto.exists)
      if auto.value as? String != "1" { auto.tap() }
      capture("green-stop-prompt-" + appearance)
      app.buttons["chart-interval.edit"].tap()
      app.buttons["恢复默认周期"].tap()
      let defaultRestored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"),
        object: app.buttons["interval-settings.favorite.1m"])
      XCTAssertEqual(XCTWaiter.wait(for: [defaultRestored], timeout: 3), .completed)
      let shown = app.staticTexts["图表周期"]
      let alternatives = app.staticTexts["备选周期"]
      XCTAssertTrue(shown.exists)
      XCTAssertTrue(alternatives.exists)
      XCTAssertLessThan(shown.frame.minY, alternatives.frame.minY)
      XCTAssertLessThan(app.buttons["interval-settings.select.3m"].frame.minY,
        app.buttons["interval-settings.select.1w"].frame.minY)
      for key in ["30m", "2h", "8h", "16h", "3d", "1w"] {
        XCTAssertTrue(app.buttons["interval-settings.select." + key].exists)
      }
      capture("interval-options-" + appearance)
      app.buttons["关闭"].firstMatch.tap()
      auto.tap()
      XCTAssertEqual(auto.value as? String, "0")
      app.segmentedControls["chart-ticket.order-type"].buttons["限价"].tap()
      let stop = app.descendants(matching: .any)["chart-order-line.stopLoss"].firstMatch
      XCTAssertTrue(stop.waitForExistence(timeout: 5))
      let chart = app.descendants(matching: .any)["market-chart-plot"].firstMatch
      XCTAssertEqual(stop.frame.maxX, chart.frame.maxX, accuracy: 1)
      let before = stop.value as? String
      // Drag into the indicator area. This only edits a local draft; no submit is tapped.
      let start = stop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      let outside = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
      start.press(forDuration: 0.05, thenDragTo: outside)
      XCTAssertNotEqual(stop.value as? String, before)
      capture("manual-limit-offscreen-" + appearance)
      auto.tap()
      XCTAssertEqual(auto.value as? String, "1")
      capture("auto-limit-axis-" + appearance)
    }
  }

  func testSharedTradingPairSheetMembershipAndTradeSelection() {
    launch("market")
    app.buttons["搜索币种、币对或合约"].tap()
    let ada = app.buttons["pairs.favorite.ADAUSDT"]
    XCTAssertTrue(ada.waitForExistence(timeout: 5))
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "Market search starts ready for typing")
    XCTAssertEqual(ada.value as? String, "未自选")
    XCTAssertEqual(app.buttons["pairs.favorite.BTCUSDT"].value as? String, "已自选")
    ada.tap()
    XCTAssertEqual(ada.value as? String, "已自选")
    capture("shared-pair-sheet-market")
    app.buttons["pairs.close"].tap()
    app.buttons["编辑行情列表"].tap()
    XCTAssertTrue(app.buttons["watchlist.delete.ADAUSDT"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["全选"].exists)
    XCTAssertFalse(app.buttons["添加到群组"].exists)
    app.buttons["watchlist.delete.ADAUSDT"].tap()
    XCTAssertTrue(app.buttons["删除自选"].waitForExistence(timeout: 3))
    app.buttons["取消"].tap()
    XCTAssertTrue(app.buttons["watchlist.delete.ADAUSDT"].exists)
    app.buttons["watchlist.delete.ADAUSDT"].tap()
    app.buttons["删除自选"].tap()
    XCTAssertFalse(app.buttons["watchlist.delete.ADAUSDT"].exists)
    app.buttons["watchlist.add"].tap()
    XCTAssertTrue(ada.waitForExistence(timeout: 5))
    XCTAssertFalse(app.keyboards.firstMatch.exists, "Watchlist picker should not focus search automatically")
    XCTAssertEqual(ada.value as? String, "未自选")
    let search = app.textFields["pairs.search"]
    search.tap(); search.typeText("ADA")
    XCTAssertTrue(app.buttons["pairs.select.ADAUSDT"].exists)
    XCTAssertFalse(app.buttons["pairs.select.BTCUSDT"].exists)
    app.buttons["pairs.close"].tap()

    launch("trade")
    app.buttons["trade.symbol"].tap()
    XCTAssertTrue(app.buttons["pairs.select.ETHUSDT"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.keyboards.firstMatch.exists, "Trade picker should keep the keyboard closed")
    capture("shared-pair-sheet-trade")
    app.buttons["pairs.select.ETHUSDT"].tap()
    XCTAssertTrue(app.buttons["trade.symbol"].label.contains("ETHUSDT"))
    XCTAssertTrue(app.buttons["2600.00"].waitForExistence(timeout: 3))
  }

  func testPairNamesOpenChartsWithoutChangingWatchlist() {
    launch("market")
    app.buttons["搜索币种、币对或合约"].tap()
    let ada = app.buttons["pairs.favorite.ADAUSDT"]
    XCTAssertTrue(ada.waitForExistence(timeout: 5))
    XCTAssertEqual(ada.value as? String, "未自选")
    app.buttons["pairs.select.ADAUSDT"].tap()

    let switcher = app.buttons["market-chart-symbols"]
    XCTAssertTrue(switcher.waitForExistence(timeout: 5))
    XCTAssertTrue(switcher.label.contains("ADAUSDT"))
    switcher.tap()
    XCTAssertTrue(ada.waitForExistence(timeout: 5))
    XCTAssertEqual(ada.value as? String, "未自选")
    ada.tap()
    XCTAssertEqual(ada.value as? String, "已自选")
    XCTAssertTrue(app.buttons["pairs.select.BTCUSDT"].exists)
    app.buttons["pairs.select.BTCUSDT"].tap()
    XCTAssertTrue(switcher.waitForExistence(timeout: 5))
    XCTAssertTrue(switcher.label.contains("BTCUSDT"))
    switcher.tap()
    XCTAssertTrue(ada.waitForExistence(timeout: 5))
    XCTAssertEqual(ada.value as? String, "已自选")
    XCTAssertEqual(app.buttons["pairs.favorite.BTCUSDT"].value as? String, "已自选")
    ada.tap()
    app.buttons["取消"].tap()
    XCTAssertEqual(ada.value as? String, "已自选")
    ada.tap()
    app.buttons["删除自选"].tap()
    XCTAssertEqual(ada.value as? String, "未自选")
    capture("chart-shared-pair-sheet")
    app.buttons["pairs.close"].tap()
    app.buttons["market-chart-back"].tap()
    app.buttons["编辑行情列表"].tap()
    app.buttons["watchlist.add"].tap()
    app.buttons["pairs.select.ADAUSDT"].tap()
    XCTAssertTrue(switcher.waitForExistence(timeout: 5))
    XCTAssertTrue(switcher.label.contains("ADAUSDT"))
    switcher.tap()
    XCTAssertTrue(ada.waitForExistence(timeout: 5))
    XCTAssertEqual(ada.value as? String, "未自选")
  }

  func testChartHoldingContextUsesActualPositionDataAndSelectableLeverageCards() {
    launch("market", ["--fixture-chart-position", "--fixture-extra-leverage"])
    app.buttons["搜索币种、币对或合约"].tap()
    app.buttons["pairs.select.BTCUSDT"].tap()
    let ticket = app.buttons["chart-ticket.submit"]
    XCTAssertTrue(ticket.waitForExistence(timeout: 10))
    let holding = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "正在持仓中"), object: ticket)
    XCTAssertEqual(XCTWaiter.wait(for: [holding], timeout: 5), .completed)
    XCTAssertTrue(ticket.isEnabled)
    XCTAssertEqual(app.staticTexts["chart-ticket.仓位"].label, "1000.00 U")
    XCTAssertEqual(app.staticTexts["chart-ticket.开仓价"].label, "64400.00")
    XCTAssertEqual(app.staticTexts["chart-ticket.止损价"].label, "64100.00")
    XCTAssertEqual(app.staticTexts["chart-ticket.手续费"].label, "0.5 U")
    let heldRisk = app.staticTexts["chart-ticket.止损金额"]
    XCTAssertEqual(heldRisk.label, "10 U")
    XCTAssertFalse(app.buttons["chart-ticket.risk-settings"].exists)
    heldRisk.tap()
    XCTAssertFalse(app.buttons["stop-loss.submit"].exists)
    capture("chart-held-data")
    XCTAssertEqual(app.sheets.count, 0)
    XCTAssertTrue(app.descendants(matching: .any)["position-line.101.0.entry"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["position-line.101.0.stopLoss"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["position-line.101.0.takeProfit"].exists)
    app.buttons["market-chart-leverage"].tap()
    let firstBracket = app.descendants(matching: .any)["chart-leverage.bracket.50"]
    let secondBracket = app.descendants(matching: .any)["chart-leverage.bracket.25"]
    XCTAssertTrue(firstBracket.waitForExistence(timeout: 5))
    XCTAssertTrue(secondBracket.exists)
    XCTAssertTrue(app.descendants(matching: .any)["chart-leverage.bracket.10"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["chart-leverage.bracket.5"].exists)
    XCTAssertEqual(firstBracket.frame.minX, secondBracket.frame.minX, accuracy: 1)
    XCTAssertEqual(firstBracket.frame.width, secondBracket.frame.width, accuracy: 1)
    XCTAssertGreaterThanOrEqual(secondBracket.frame.minY, firstBracket.frame.maxY)
    let confirmLeverage = app.buttons["chart-leverage.confirm"]
    capture("chart-leverage-compact-before-selection")
    XCTAssertTrue(confirmLeverage.isHittable)
    XCTAssertEqual(firstBracket.frame.width, confirmLeverage.frame.width, accuracy: 1)
    XCTAssertEqual(firstBracket.value as? String, "已选中")
    secondBracket.tap()
    XCTAssertEqual(secondBracket.value as? String, "已选中")
    capture("chart-leverage-compact-selection")
    confirmLeverage.tap()
    XCTAssertTrue(app.buttons["market-chart-leverage"].label.contains("杠杆 × 25"))
    app.buttons["market-chart-leverage"].tap()
    XCTAssertTrue(secondBracket.waitForExistence(timeout: 5))
    XCTAssertEqual(secondBracket.value as? String, "已选中")
    confirmLeverage.tap()
    XCTAssertFalse(app.buttons["market-chart-settings"].exists)
    XCTAssertTrue(app.buttons["market-chart-indicator-settings-shortcut"].isHittable)
    XCTAssertEqual(app.buttons["market-chart-favorite"].label, "自选")
    ticket.tap()
    XCTAssertTrue(app.scrollViews["positions.list"].waitForExistence(timeout: 5))
    app.buttons["position.chart.101"].tap()
    XCTAssertTrue(app.buttons["market-chart-symbols"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.sheets.count, 0)
    launch("positions", ["--fixture-chart-position", "--fixture-dark"])
    app.buttons["position.chart.101"].tap()
    XCTAssertTrue(ticket.waitForExistence(timeout: 10))
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "正在持仓中"), object: ticket)], timeout: 5), .completed)
    XCTAssertFalse(app.buttons["chart-ticket.risk-settings"].exists)
    capture("chart-held-data-dark")
  }

  func testChartCrosshairLimitLinesAndSharedEntryConfirmation() {
    launch("market", ["--fixture-entry-ready"])
    app.buttons["搜索币种、币对或合约"].tap()
    app.buttons["pairs.select.BTCUSDT"].tap()
    let ticket = app.buttons["chart-ticket.submit"]
    XCTAssertTrue(ticket.waitForExistence(timeout: 10))
    let modes = app.segmentedControls["chart-ticket.order-type"]
    modes.buttons["市价"].tap()
    let chart = app.descendants(matching: .any)["market-chart-plot"]
    let side = chart.frame.width - 62
    let base = app.coordinate(withNormalizedOffset: .zero)
    let lower = base.withOffset(CGVector(dx: chart.frame.minX + side * 0.6, dy: chart.frame.minY + 30 + side * 0.85))
    // The fixture quote sits above its candle history, near the top of the expanded price range.
    let upper = base.withOffset(CGVector(dx: chart.frame.minX + side * 0.6, dy: chart.frame.minY + 30 + side * 0.02))
    lower.press(forDuration: 0.6)
    XCTAssertTrue(NSPredicate(format: "label == %@", "开多").evaluate(with: ticket))
    XCTAssertNotEqual(app.staticTexts["chart-ticket.预估仓位"].label, "-")
    capture("chart-market-long-crosshair")
    lower.tap()
    let clearedPosition = app.staticTexts["chart-ticket.预估仓位"]
    let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "-"), object: clearedPosition)
    XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 3), .completed)
    XCTAssertFalse(ticket.isEnabled)
    upper.press(forDuration: 0.6)
    XCTAssertEqual(ticket.label, "开空")
    capture("chart-market-short-crosshair")
    app.buttons["chart-ticket.risk-settings"].tap()
    XCTAssertTrue(app.sliders["stop-loss.percentage"].waitForExistence(timeout: 5))
    app.buttons["关闭"].firstMatch.tap()
    modes.buttons["限价"].tap()
    let stopLine = app.descendants(matching: .any)["chart-order-line.stopLoss"].firstMatch
    let entryLine = app.descendants(matching: .any)["chart-order-line.entry"].firstMatch
    XCTAssertTrue(stopLine.waitForExistence(timeout: 5))
    XCTAssertTrue(entryLine.exists)
    let linePoint = stopLine.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
    linePoint.press(forDuration: 0.1, thenDragTo: upper)
    XCTAssertEqual(ticket.label, "开空")
    capture("chart-limit-short-lines")
    ticket.tap()
    XCTAssertTrue(app.staticTexts["委托确认"].waitForExistence(timeout: 5))
    app.buttons["取消"].tap()
    XCTAssertTrue(ticket.exists)
    modes.buttons["市价"].tap()
    lower.press(forDuration: 0.6)
    ticket.tap()
    XCTAssertTrue(app.staticTexts["开仓确认"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["方向初筛"].exists)
    capture("chart-shared-market-confirmation")
    app.buttons["取消"].tap()
  }

  func testNativeWatchlistDragAndMoveToTop() {
    launch("market")
    app.buttons["编辑行情列表"].tap()
    let btc = app.buttons["watchlist.top.BTCUSDT"]
    let eth = app.buttons["watchlist.top.ETHUSDT"]
    let sol = app.buttons["watchlist.top.SOLUSDT"]
    XCTAssertTrue(btc.waitForExistence(timeout: 5))
    let start = app.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: app.frame.maxX - 24, dy: btc.frame.midY))
    let end = app.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: app.frame.maxX - 24, dy: sol.frame.maxY + 10))
    start.press(forDuration: 0.7, thenDragTo: end)
    XCTAssertGreaterThan(btc.frame.midY, sol.frame.midY)
    XCTAssertLessThan(eth.frame.midY, sol.frame.midY)
    capture("watchlist-native-reordered")
    btc.tap()
    XCTAssertLessThan(btc.frame.midY, eth.frame.midY)
    capture("watchlist-moved-to-top")
  }

  func testTradeUsesProfileRiskSheetAndCompactUnboundAvatarHeader() {
    launch("trade", ["--fixture-unbound"])
    app.buttons["调整止损金额"].tap()
    XCTAssertTrue(app.sliders["stop-loss.percentage"].waitForExistence(timeout: 5))
    let tradeFooter = app.buttons["stop-loss.submit"].frame
    capture("trade-shared-stop-loss")
    app.buttons["关闭"].firstMatch.tap()
    launch("profile", ["--fixture-unbound"])
    let bind = app.buttons["profile.bind"]
    let avatar = app.descendants(matching: .any)["profile.avatar"].firstMatch
    XCTAssertTrue(bind.waitForExistence(timeout: 5))
    XCTAssertTrue(avatar.exists)
    XCTAssertLessThan(avatar.frame.maxX, bind.frame.minX)
    let mode = app.buttons["profile.switchMode"]
    XCTAssertTrue(mode.exists)
    XCTAssertEqual(bind.frame.minX - avatar.frame.maxX, 8, accuracy: 1)
    XCTAssertEqual(bind.frame.midY, avatar.frame.midY, accuracy: 1)
    XCTAssertGreaterThan(mode.frame.minY, avatar.frame.maxY)
    XCTAssertEqual(bind.frame.height, 36, accuracy: 1)
    XCTAssertGreaterThanOrEqual(mode.frame.height, 44)
    XCTAssertLessThan(bind.frame.width, 150)
    capture("profile-compact-bind-with-avatar")
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "止损额设置")).firstMatch.tap()
    XCTAssertTrue(app.sliders["stop-loss.percentage"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["stop-loss.submit"].frame.height, tradeFooter.height, accuracy: 1)
    XCTAssertEqual(app.buttons["stop-loss.submit"].frame.maxY, tradeFooter.maxY, accuracy: 1)
  }

  func testAccountInitialIgnoresBindingAndMaskedKeyIsCompact() {
    for unbound in [false, true] {
      launch("profile", unbound ? ["--fixture-unbound"] : [])
      let avatar = app.descendants(matching: .any)["profile.avatar"].firstMatch
      XCTAssertTrue(avatar.waitForExistence(timeout: 5))
      let ready = NSPredicate(format: "value == %@", "V")
      expectation(for: ready, evaluatedWith: avatar)
      waitForExpectations(timeout: 5)
      if !unbound {
        let key = app.staticTexts["profile.apiKeyLabel"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertEqual(key.label, "abcde**vwxyz")
        XCTAssertLessThanOrEqual(key.label.count, 12)
        XCTAssertLessThan(key.frame.maxX, app.buttons["解除 API 绑定"].frame.minX)
      }
      capture(unbound ? "profile-account-initial-unbound" : "profile-account-initial-bound")
    }
  }

  func testRegistrationControlOnlyAppearsForOperator() {
    launch("settings")
    XCTAssertTrue(app.descendants(matching: .any)["settings.notifications"].firstMatch.waitForExistence(timeout: 5))
    XCTAssertFalse(app.descendants(matching: .any)["settings.registration"].firstMatch.exists)
    launch("settings", ["--fixture-registration-operator"])
    XCTAssertTrue(app.descendants(matching: .any)["settings.registration"].firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["开启注册"].exists)
    capture("settings-registration-operator")
  }

  func testAllUnboundPositionTabsOnlyShowBindingPrompt() {
    launch("positions", ["--fixture-unbound"])
    for tab in ["持仓", "限价委托", "历史仓位"] {
      if tab != "持仓" { app.buttons[tab].tap() }
      let bind = app.buttons["positions.bind"]
      XCTAssertTrue(bind.waitForExistence(timeout: 5))
      XCTAssertEqual(bind.frame.midY, app.scrollViews["positions.list"].frame.midY, accuracy: 2)
      XCTAssertFalse(app.buttons["重新加载"].exists)
      XCTAssertFalse(app.staticTexts["开仓额度："].exists)
      XCTAssertFalse(app.buttons["追单"].exists)
      XCTAssertFalse(app.staticTexts["加载中..."].exists)
      XCTAssertFalse(app.staticTexts["平仓盈亏"].exists)
      XCTAssertFalse(app.buttons["一天内"].exists)
      capture("unbound-" + tab)
      bind.tap()
      XCTAssertTrue(app.buttons["确认绑定"].waitForExistence(timeout: 5))
      app.buttons["关闭"].firstMatch.tap()
    }
  }

  func testMarketLatencySignalAndInternalOnlyHeader() {
    for (options, value) in [([], "86 ms, good"), (["--fixture-latency-fair"], "280 ms, fair"),
                              (["--fixture-latency-slow", "--fixture-dark"], "780 ms, poor"),
                              (["--fixture-latency-overflow"], "999 ms, poor"),
                              (["--fixture-latency-unavailable"], "-- ms, poor"),
                              (["--fixture-latency-measuring"], "测量中, fair, 正在刷新")] {
      launch("market", options)
      let latency = app.descendants(matching: .any)["market.latency"].firstMatch
      XCTAssertTrue(latency.waitForExistence(timeout: 5))
      XCTAssertEqual(latency.value as? String, value)
      XCTAssertLessThan(latency.frame.maxX, app.buttons["编辑行情列表"].frame.minX)
      capture("market-latency-" + value)
    }
    launch("market")
    let latencyButton = app.buttons["market.latency"]
    latencyButton.tap()
    XCTAssertEqual(latencyButton.value as? String, "86 ms, good, 正在刷新")
    let measuredAgain = expectation(for: NSPredicate(format: "value == %@", "86 ms, good"),
      evaluatedWith: latencyButton)
    wait(for: [measuredAgain], timeout: 3)
    launch("signals")
    XCTAssertTrue(app.buttons["内部信号规则"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["自有"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["外部"].exists)
    XCTAssertFalse(app.buttons["内部"].exists)
    capture("signals-internal-only")
    app.buttons["内部信号规则"].tap()
    XCTAssertTrue(app.staticTexts["信号规则"].waitForExistence(timeout: 5))
    app.buttons["我知道了"].tap()
    XCTAssertTrue(app.buttons["内部信号规则"].waitForExistence(timeout: 5))
  }

  func testLatencyRefreshRetainsValueAndNativeStopLossFooterStaysFixed() {
    launch("market", ["--fixture-latency-refresh-slow"])
    let latency = app.buttons["market.latency"]
    XCTAssertTrue(latency.waitForExistence(timeout: 5))
    latency.tap()
    XCTAssertEqual(latency.value as? String, "86 ms, good, 正在刷新")
    capture("latency-refresh-keeps-number")
    let refreshed = expectation(for: NSPredicate(format: "value == %@", "86 ms, good"), evaluatedWith: latency)
    wait(for: [refreshed], timeout: 8)
    app.swipeDown()
    XCTAssertEqual(latency.value as? String, "86 ms, good, 正在刷新")
    let pulled = expectation(for: NSPredicate(format: "value == %@", "86 ms, good"), evaluatedWith: latency)
    wait(for: [pulled], timeout: 8)

    for (options, name) in [(["--fixture-unbound"], "light"),
                             (["--fixture-unbound", "--fixture-dark"], "dark")] {
      launch("profile", options)
      XCTAssertTrue(app.buttons["profile.bind"].waitForExistence(timeout: 5))
      capture("profile-red-binding-" + name)
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "止损额设置")).firstMatch.tap()
      let submit = app.buttons["stop-loss.submit"]
      XCTAssertTrue(submit.waitForExistence(timeout: 5))
      let footerY = submit.frame.maxY
      let slider = app.sliders["stop-loss.percentage"]
      XCTAssertTrue(slider.waitForExistence(timeout: 5))
      XCTAssertEqual(app.staticTexts["stop-loss.percentageText"].label, "10%")
      XCTAssertEqual(app.staticTexts["stop-loss.amount"].label, "10 USDT")
      XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "表单控制柄")).firstMatch.exists)
      slider.adjust(toNormalizedSliderPosition: 0.7)
      XCTAssertEqual(submit.frame.maxY, footerY, accuracy: 1)
      XCTAssertTrue(submit.isEnabled)
      capture("native-stop-loss-fixed-footer-" + name)
      submit.tap()
      XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
      app.buttons["取消"].tap()
      XCTAssertTrue(submit.waitForExistence(timeout: 5))
      XCTAssertEqual(submit.frame.maxY, footerY, accuracy: 1)
      app.buttons["关闭"].firstMatch.tap()
      XCTAssertTrue(app.buttons["profile.bind"].waitForExistence(timeout: 5))
    }
  }

  func testCollectionButtonAndSmallConfirmationCanReopen() {
    launch("profile")
    let collect = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "归集余额")).firstMatch
    XCTAssertTrue(collect.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "补资提醒")).firstMatch.exists)
    capture("profile-collection-lower-position")
    let logout = app.buttons["profile.logout"]
    for _ in 0..<4 where !logout.isHittable { app.swipeUp() }
    for _ in 0..<2 {
      logout.tap()
      XCTAssertTrue(app.staticTexts["确认退出登录"].waitForExistence(timeout: 5))
      capture("small-confirmation-fade")
      app.buttons["取消"].tap()
      XCTAssertTrue(logout.waitForExistence(timeout: 5))
    }
    launch("launch")
    capture("launch-96pt-rounded")
  }

  func testPositionTabButtonsKeepTheirCentersWhileSwitching() {
    launch("positions")
    let keys = ["positions", "limits", "history"]
    let tabs = keys.map { app.buttons["positions.tabs." + $0] }
    XCTAssertTrue(tabs[0].waitForExistence(timeout: 5))
    let frames = tabs.map { $0.frame }
    for next in [1, 2, 0, 1, 0] {
      tabs[next].tap()
      XCTAssertTrue(tabs[next].isSelected)
      for index in tabs.indices {
        XCTAssertEqual(tabs[index].frame.midX, frames[index].midX, accuracy: 0.5,
          "Tab hit areas must stay fixed when only selection changes")
        XCTAssertEqual(tabs[index].frame.width, frames[index].width, accuracy: 0.5)
      }
    }
    XCTAssertLessThan(frames[2].maxX - frames[0].minX, 225, "Keep the tab strip compact")
    XCTAssertGreaterThanOrEqual(frames[0].minX - app.otherElements["positions.header"].frame.minX, 16)
    capture("positions-compact-stable-tabs")
  }

  func testConfirmedEmptyMarginHidesReadFailureAndShowsBothCards() {
    launch("positions", ["--fixture-empty", "--fixture-margin-failure"])
    let badge = app.buttons["positions.margin"]
    XCTAssertTrue(badge.waitForExistence(timeout: 5))
    let zero = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0%"), object: badge)
    XCTAssertEqual(XCTWaiter.wait(for: [zero], timeout: 5), .completed)
    badge.tap()
    XCTAssertTrue(app.staticTexts["本地计算明细"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["币安实时保证金率"].exists)
    XCTAssertTrue(app.staticTexts["未开仓"].firstMatch.exists)
    XCTAssertFalse(app.staticTexts["保证金率更新失败，请重试"].exists)
    XCTAssertFalse(app.staticTexts["合计初始保证金占用"].exists)
    capture("positions-empty-margin-two-cards")
  }

  func testPositionPagesSwipeAndMarginDetailsStayReadOnly() {
    launch("positions", ["--fixture-margin-danger"])
    let position = app.buttons["positions.tabs.positions"]
    let limits = app.buttons["positions.tabs.limits"]
    let history = app.buttons["positions.tabs.history"]
    XCTAssertTrue(position.waitForExistence(timeout: 5))
    let badge = app.buttons["positions.margin"]
    XCTAssertTrue(badge.waitForExistence(timeout: 5))
    XCTAssertLessThanOrEqual(badge.frame.maxX, app.buttons["positions.liveActivity"].frame.minX)
    XCTAssertTrue(badge.isHittable)
    app.scrollViews["positions.list"].swipeLeft()
    XCTAssertTrue(limits.isSelected)
    app.scrollViews["positions.list"].swipeLeft()
    XCTAssertTrue(history.isSelected)
    app.scrollViews["positions.list"].swipeRight()
    XCTAssertTrue(limits.isSelected)
    app.scrollViews["positions.list"].swipeRight()
    XCTAssertTrue(position.isSelected)
    pullToRefresh(app.scrollViews["positions.list"], distance: 30)
    XCTAssertTrue(position.isSelected, "Vertical pull must not change pages")
    badge.tap()
    XCTAssertTrue(app.staticTexts["保证金详情"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["本地计算明细"].exists)
    XCTAssertTrue(app.staticTexts["合计初始保证金占用"].exists)
    let details = app.scrollViews.containing(.staticText, identifier: "本地计算明细").firstMatch
    let realtime = details.staticTexts["85%"]
    XCTAssertEqual(realtime.label, "85%")
    XCTAssertTrue(realtime.isHittable)
    capture("positions-margin-danger-details")
    for _ in 0..<4 where !app.staticTexts["TESTUSDT"].isHittable { details.swipeUp() }
    XCTAssertTrue(app.staticTexts["TESTUSDT"].isHittable)
    XCTAssertTrue(app.staticTexts["43.75%"].exists)
    capture("positions-local-margin-details")
    app.swipeLeft()
    app.buttons["关闭"].firstMatch.tap()
    XCTAssertTrue(position.isSelected, "A modal drag must not switch the page underneath")
  }

  func testPositionPageSwipesCoverHeaderCardsAndEmptySpace() {
    launch("positions")
    let position = app.buttons["positions.tabs.positions"]
    let limits = app.buttons["positions.tabs.limits"]
    let history = app.buttons["positions.tabs.history"]
    XCTAssertTrue(position.waitForExistence(timeout: 5))
    XCTAssertTrue(app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "开仓额度：")).firstMatch.waitForExistence(timeout: 5))

    func swipe(_ element: XCUIElement, y: CGFloat, left: Bool, destination: XCUIElement) {
      let start = element.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: y))
      let end = element.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.85, dy: y))
      start.press(forDuration: 0.05, thenDragTo: end)
      let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: destination)
      XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
    }

    // Anchor to the visible tab: the header AX group also includes the status safe area.
    // The old observer was inside the scroll content and missed this button row.
    let window = app.windows.firstMatch
    let headerY = position.frame.midY / window.frame.height
    swipe(window, y: headerY, left: true, destination: limits)
    swipe(app.scrollViews["positions.list"], y: 0.18, left: true, destination: history)
    swipe(app.scrollViews["positions.list"], y: 0.9, left: false, destination: limits)
    swipe(window, y: headerY, left: false, destination: position)
    swipe(app.scrollViews["positions.list"], y: 0.2, left: true, destination: limits)

    for options in [["--fixture-empty"], ["--fixture-unbound"]] {
      launch("positions", options)
      XCTAssertTrue(position.waitForExistence(timeout: 5))
      swipe(app.scrollViews["positions.list"], y: 0.9, left: true, destination: limits)
      swipe(app.scrollViews["positions.list"], y: 0.9, left: true, destination: history)
      swipe(app.scrollViews["positions.list"], y: 0.9, left: false, destination: limits)
      swipe(app.scrollViews["positions.list"], y: 0.9, left: false, destination: position)
    }
    capture("positions-full-surface-swipes")
  }

  func testShortPositionSwipesStayOnOneSideOfTheScreen() {
    for options in [[], ["--fixture-empty"]] {
      launch("positions", options)
      let position = app.buttons["positions.tabs.positions"]
      let limits = app.buttons["positions.tabs.limits"]
      let history = app.buttons["positions.tabs.history"]
      XCTAssertTrue(position.waitForExistence(timeout: 5))
      let list = app.scrollViews["positions.list"]
      func shortSwipe(left: Bool, destination: XCUIElement) {
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.88 : 0.12, dy: 0.75))
        let end = start.withOffset(CGVector(dx: left ? -52 : 52, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: destination)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
      }
      shortSwipe(left: true, destination: limits)
      shortSwipe(left: true, destination: history)
      shortSwipe(left: false, destination: limits)
      shortSwipe(left: false, destination: position)
    }
    capture("positions-same-side-short-swipes")
  }

  func testNativePositionPagingCancelsShortDragAndKeepsIndependentOffsets() {
    launch("positions", ["--fixture-position-pager"])
    let position = app.buttons["positions.tabs.positions"]
    let limits = app.buttons["positions.tabs.limits"]
    let history = app.buttons["positions.tabs.history"]
    XCTAssertTrue(position.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["position.symbol.1"].waitForExistence(timeout: 5))
    let list = app.scrollViews["positions.list"]
    let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.75))
    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -20, dy: 0)))
    XCTAssertTrue(position.isSelected, "A partial drag returns to the original page")

    list.swipeUp()
    let row = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "position.symbol."))
      .allElementsBoundByIndex.first { $0.isHittable && list.frame.contains($0.frame) }
    guard let row else { return XCTFail("Expected a visible position after scrolling") }
    let rowID = row.identifier
    let positionY = row.frame.midY
    XCTAssertNotEqual(rowID, "position.symbol.1")

    limits.tap()
    waitForNativePositionPageToSettle()
    XCTAssertTrue(app.staticTexts["LIM01USDT"].waitForExistence(timeout: 5))
    list.swipeUp()
    let limitRow = list.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "LIM"))
      .allElementsBoundByIndex.first { $0.isHittable && list.frame.contains($0.frame) }
    guard let limitRow else { return XCTFail("Expected a visible limit order after scrolling") }
    let limitSymbol = limitRow.label
    let limitY = limitRow.frame.midY
    XCTAssertNotEqual(limitSymbol, "LIM01USDT")

    history.tap()
    waitForNativePositionPageToSettle()
    XCTAssertTrue(app.staticTexts["HIS01USDT"].waitForExistence(timeout: 5))
    list.swipeUp()
    position.tap()
    waitForNativePositionPageToSettle()
    let restored = app.buttons[rowID]
    XCTAssertTrue(restored.waitForExistence(timeout: 5))
    XCTAssertTrue(restored.isHittable)
    XCTAssertEqual(restored.frame.midY, positionY, accuracy: 2)
    limits.tap()
    waitForNativePositionPageToSettle()
    XCTAssertTrue(app.staticTexts[limitSymbol].isHittable)
    XCTAssertEqual(app.staticTexts[limitSymbol].frame.midY, limitY, accuracy: 2)
    capture("positions-native-independent-scroll")
  }

  func testNativePositionPagingRetainsLoadedPagination() {
    launch("positions", ["--fixture-position-pager"])
    let limits = app.buttons["positions.tabs.limits"]
    XCTAssertTrue(limits.waitForExistence(timeout: 5))
    limits.tap()
    waitForNativePositionPageToSettle()
    XCTAssertTrue(app.staticTexts["LIM01USDT"].waitForExistence(timeout: 5))
    let list = app.scrollViews["positions.list"]
    let more = app.buttons["加载更多"]
    for _ in 0..<8 where !more.isHittable { list.swipeUp() }
    XCTAssertTrue(more.isHittable)
    more.tap()
    XCTAssertTrue(app.staticTexts["LIM06USDT"].waitForExistence(timeout: 5))
    for _ in 0..<4 where !app.staticTexts["LIM06USDT"].isHittable { list.swipeUp() }
    let y = app.staticTexts["LIM06USDT"].frame.midY
    app.buttons["positions.tabs.history"].tap()
    waitForNativePositionPageToSettle()
    XCTAssertTrue(app.staticTexts["HIS01USDT"].waitForExistence(timeout: 5))
    limits.tap()
    waitForNativePositionPageToSettle()
    XCTAssertTrue(app.staticTexts["LIM06USDT"].isHittable)
    XCTAssertEqual(app.staticTexts["LIM06USDT"].frame.midY, y, accuracy: 2)
    capture("positions-native-retained-pagination")
  }

  private func waitForNativePositionPageToSettle(file: StaticString = #filePath, line: UInt = #line) {
    let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      let frame = app.scrollViews["positions.list"].frame
      let window = app.windows.firstMatch.frame
      return abs(frame.minX - window.minX) < 0.5 && abs(frame.width - window.width) < 0.5
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 4), .completed, file: file, line: line)
  }

  func testAllPositionTabsRefreshFromEmptyLists() {
    launch("positions", ["--fixture-refresh-lists"])
    for (tab, empty, content) in [
      ("持仓", "暂无持仓", "开仓额度："),
      ("限价委托", "暂无限价委托", "追单"),
      ("历史仓位", "暂无历史仓位记录", "平仓盈亏"),
    ] {
      if tab != "持仓" { app.buttons[tab].tap() }
      XCTAssertTrue(app.staticTexts[empty].waitForExistence(timeout: 5))
      let list = app.scrollViews["positions.list"]
      list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        .press(forDuration: 0.1,
          thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
      XCTAssertTrue(app.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS %@", content)).firstMatch
        .waitForExistence(timeout: 10), tab)
      capture("refreshed-" + tab)
    }
  }

  private var refreshIndicator: XCUIElement {
    app.activityIndicators.matching(NSPredicate(format: "label == %@", "正在刷新")).firstMatch
  }

  private func assertRefreshIndicatorVisible(_ indicator: XCUIElement, page: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    // The overlay is intentionally passive, so tappability is not a visibility check.
    XCTAssertEqual(indicator.frame.width, 20, accuracy: 1, page, file: file, line: line)
    XCTAssertEqual(indicator.frame.height, 20, accuracy: 1, page, file: file, line: line)
    XCTAssertTrue(app.windows.firstMatch.frame.contains(indicator.frame), page, file: file, line: line)
  }

  private func pullToRefresh(_ list: XCUIElement, distance: CGFloat? = nil) {
    let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
    let end = distance.map { start.withOffset(CGVector(dx: 0, dy: $0)) }
      ?? list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
    start.press(forDuration: 0.1, thenDragTo: end)
  }

  func testSignalsPullRefreshShowsIndicatorAndLoadsNewSnapshot() {
    launch("signals", ["--fixture-page-state", "--fixture-refresh-delay"])
    XCTAssertTrue(app.staticTexts["读取 1 · 测试信号 1"].waitForExistence(timeout: 10))
    let list = app.scrollViews["signals.list"]
    let indicator = refreshIndicator
    pullToRefresh(list, distance: 30)
    XCTAssertFalse(indicator.exists)
    XCTAssertTrue(app.staticTexts["读取 1 · 测试信号 1"].exists)
    pullToRefresh(list)
    XCTAssertTrue(indicator.waitForExistence(timeout: 2))
    assertRefreshIndicatorVisible(indicator)
    capture("signals-pull-refresh-indicator")
    XCTAssertTrue(app.staticTexts["读取 2 · 测试信号 1"].waitForExistence(timeout: 10))
    XCTAssertFalse(indicator.exists)
  }

  func testRefreshReleaseKeepsContentAtRestPosition() {
    launch("signals", ["--fixture-page-state", "--fixture-refresh-delay"])
    let first = app.staticTexts["读取 1 · 测试信号 1"]
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    let restingY = first.frame.minY
    pullToRefresh(app.scrollViews["signals.list"])
    let indicator = refreshIndicator
    XCTAssertTrue(indicator.waitForExistence(timeout: 2))
    assertRefreshIndicatorVisible(indicator)
    capture("refresh-after-release")
    XCTAssertEqual(first.frame.minY, restingY, accuracy: 1,
      "Releasing the pull must not insert a new row and move the list")
    XCTAssertTrue(app.staticTexts["读取 2 · 测试信号 1"].waitForExistence(timeout: 10))
    XCTAssertFalse(indicator.exists)
  }

  func testSharedRefreshIndicatorOnMarketProfileCommandsAndRecords() {
    for page in ["market", "profile", "commands", "operations", "transfers", "strategy-log", "embedded-records"] {
      launch(page, ["--fixture-refresh-delay"])
      let list = app.scrollViews.firstMatch
      XCTAssertTrue(list.waitForExistence(timeout: 10), page)
      if page == "profile" {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"),
          object: app.buttons["profile.refreshBalance"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
      } else if page == "commands" {
        XCTAssertTrue(app.staticTexts["只读命令列表"].waitForExistence(timeout: 10))
      } else if ["operations", "transfers", "strategy-log", "embedded-records"].contains(page) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
          object: app.staticTexts["正在加载..."])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
      }
      pullToRefresh(list)
      let indicator = refreshIndicator
      XCTAssertTrue(indicator.waitForExistence(timeout: 2), page)
      assertRefreshIndicatorVisible(indicator, page: page)
      capture(page + "-pull-refresh-indicator")
      let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
        object: indicator)
      XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed, page)
    }
  }

  func testBoundHistoryShowsRecordsWhileExchangeSupplementIsSlow() {
    launch("positions", ["--fixture-history-supplement-slow"])
    XCTAssertTrue(app.buttons["自动止盈中"].waitForExistence(timeout: 5))
    app.buttons["历史仓位"].tap()
    XCTAssertTrue(app.staticTexts["平仓盈亏"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["待结算"].exists)
    XCTAssertTrue(app.staticTexts["正在更新历史记录…"].exists)
    XCTAssertFalse(app.staticTexts["加载中..."].exists)
    capture("history-records-before-supplement")
    XCTAssertTrue(app.staticTexts["正在更新历史记录…"].waitForNonExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["待结算"].exists)
    XCTAssertTrue(app.staticTexts["平仓盈亏"].exists)
  }

  func testProfileLogoutButtonAndRemovedResearchEntry() {
    launch("profile")
    profileLink("更多功能")
    for retired in ["看盘计划", "开仓理由/指标校验"] {
      XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", retired))
        .firstMatch.exists)
    }
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "信号研究"))
      .firstMatch.exists)
    let logout = app.buttons["profile.logout"]
    for _ in 0..<4 where !logout.isHittable { app.swipeUp() }
    XCTAssertTrue(logout.isHittable)
    XCTAssertGreaterThan(logout.frame.width, app.frame.width * 0.8)
    XCTAssertGreaterThanOrEqual(logout.frame.height, 48)
    capture("profile-logout-button")
    logout.tap()
    XCTAssertTrue(app.staticTexts["确认退出登录"].waitForExistence(timeout: 5))
    app.buttons["取消"].tap()
  }

  func testLoginCompactTwoLineToast() {
    launch("login", ["--fixture-toast"])
    XCTAssertTrue(app.buttons["注册账号"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["没有账号"].exists)
    let toast = app.descendants(matching: .any)["app.toast"].firstMatch
    XCTAssertTrue(toast.waitForExistence(timeout: 3))
    XCTAssertLessThanOrEqual(toast.frame.width, 181)
    XCTAssertGreaterThan(toast.frame.height, 60)
    capture("login-two-line-toast")
  }
  private func rightSwipe(fromX: CGFloat = 40, toX: CGFloat = 350) {
    let origin = app.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: fromX, dy: 270)).press(forDuration: 0.1,
      thenDragTo: origin.withOffset(CGVector(dx: toX, dy: 275)),
      withVelocity: .slow, thenHoldForDuration: 0.1)
  }
  private func profileLink(_ label: String) {
    let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 5), label)
    if !button.isHittable { app.swipeUp() }
    button.tap()
  }
  func testWideSwipeReturnsFromBusinessPagesAndNestedStrategy() {
    launch("profile", ["--fixture-dark"])
    for (label, title) in [("转账历史", "转账历史"), ("设置", "设置"), ("止盈止损策略", "我的策略")] {
      profileLink(label)
      XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 5))
      capture("wide-pop-" + title)
      if title == "我的策略" {
        app.buttons["新建策略"].tap()
        XCTAssertTrue(app.buttons["保存策略"].firstMatch.waitForExistence(timeout: 5))
        rightSwipe()
        XCTAssertTrue(app.staticTexts["我的策略"].firstMatch.waitForExistence(timeout: 5))
      }
      rightSwipe()
      XCTAssertTrue(app.buttons["profile.switchMode"].waitForExistence(timeout: 5))
    }
    profileLink("更多功能")
    for (label, title) in [("日志", "日志"), ("交易命令", "交易命令")] {
      profileLink(label)
      XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 5), title)
      rightSwipe()
      XCTAssertTrue(app.buttons["profile.switchMode"].waitForExistence(timeout: 5), label)
    }
  }
  func testSwipeCanCancelAndStopLossModalClosesWithoutMovingPage() {
    launch("profile", ["--fixture-dark"])
    profileLink("设置")
    XCTAssertTrue(app.staticTexts["开启通知"].waitForExistence(timeout: 5))
    rightSwipe(toX: 85)
    XCTAssertTrue(app.staticTexts["开启通知"].exists)
    rightSwipe()
    XCTAssertTrue(app.buttons["profile.switchMode"].waitForExistence(timeout: 5))
    app.swipeDown()
    profileLink("止损额设置")
    XCTAssertTrue(app.buttons["关闭"].firstMatch.waitForExistence(timeout: 5))
    capture("dark-stop-loss-independent-backdrop")
    app.buttons["关闭"].firstMatch.tap()
    XCTAssertTrue(app.buttons["profile.switchMode"].waitForExistence(timeout: 5))
    profileLink("止损额设置")
    XCTAssertTrue(app.buttons["关闭"].firstMatch.waitForExistence(timeout: 5))
    let close = app.buttons["关闭"].firstMatch
    let grabber = app.buttons.matching(NSPredicate(format: "label IN %@", ["表单控制柄", "Sheet Grabber"])).firstMatch
    XCTAssertTrue(grabber.waitForExistence(timeout: 5))
    grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(forDuration: 0.1,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)),
        withVelocity: .fast, thenHoldForDuration: 0)
    let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
    XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 4), .completed)
    capture("dark-profile-after-modal")
  }

  func testExternalFloatingFailureUsesToastAndCanRetryWithoutAnInlineCard() {
    launch("positions", ["--fixture-multiple", "--fixture-pip-unavailable"])
    let toggle = app.buttons["positions.floatingPositions"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10))
    XCTAssertEqual(toggle.value as? String, "未开启")
    assertNoInlineFloatingCard()
    for attempt in 1...2 {
      toggle.tap()
      let toast = app.descendants(matching: .any)["app.toast"].firstMatch
      XCTAssertTrue(toast.waitForExistence(timeout: 5))
      XCTAssertTrue(toast.label.contains("此设备暂不支持画中画"))
      let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "未开启"), object: toggle)
      XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
      assertNoInlineFloatingCard()
      XCTAssertFalse(app.alerts["跨 App 浮窗"].exists)
      capture("external-floating-unavailable-attempt-\(attempt)")
      XCTAssertTrue(toast.waitForNonExistence(timeout: 5))
    }
    app.buttons["行情"].firstMatch.tap()
    assertNoInlineFloatingCard()
    app.buttons["我的"].firstMatch.tap()
    assertNoInlineFloatingCard()
    app.buttons["持仓"].firstMatch.tap()
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    XCTAssertEqual(toggle.value as? String, "未开启")
  }

  func testExternalFloatingStartsFromEntryAndSurvivesAcrossApps() {
    launch("positions", ["--fixture-multiple", "--fixture-live-floating"])
    let toggle = app.buttons["positions.floatingPositions"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10))
    toggle.tap()
    let unavailable = app.descendants(matching: .any)["app.toast"].firstMatch
    if unavailable.waitForExistence(timeout: 2), unavailable.label.contains("此设备暂不支持画中画") {
      let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "未开启"), object: toggle)
      XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
      assertNoInlineFloatingCard()
      XCTAssertFalse(app.alerts["跨 App 浮窗"].exists)
      capture("external-floating-device-capability-failure")
      return
    }
    // The controller's eight-second deadline closes a failed start. Remaining enabled
    // after that deadline requires its real AVKit didStart callback; Home is not the trigger.
    let started = expectation(description: "Explicit foreground PiP startup settles")
    DispatchQueue.main.asyncAfter(deadline: .now() + 9) { started.fulfill() }
    wait(for: [started], timeout: 11)
    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertEqual(toggle.value as? String, "已开启")
    assertNoInlineFloatingCard()
    capture("external-floating-started-in-foreground")
    XCUIDevice.shared.press(.home)
    let home = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    home.name = "external-floating-home"; home.lifetime = .keepAlways; add(home)
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.launch()
    XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
    let refresh = expectation(description: "External PiP group rotation while another app is foreground")
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { refresh.fulfill() }
    wait(for: [refresh], timeout: 8)
    let other = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    other.name = "external-floating-other-app"; other.lifetime = .keepAlways; add(other)
    app.activate()
    XCTAssertTrue(toggle.waitForExistence(timeout: 10))
    XCTAssertEqual(toggle.value as? String, "已开启")
    assertNoInlineFloatingCard()
    toggle.tap()
    XCTAssertEqual(toggle.value as? String, "未开启")
    assertNoInlineFloatingCard()
  }

  func testExternalFloatingEmptyUnboundAndDarkFailuresReturnToClosedState() {
    for (options, expected, name) in [
      (["--fixture-empty", "--fixture-pip-unavailable"], "此设备暂不支持画中画", "external-empty"),
      (["--fixture-unbound"], "请先绑定 API", "external-unbound"),
      (["--fixture-dark", "--fixture-lead", "--fixture-pip-unavailable"], "此设备暂不支持画中画", "external-lead-dark"),
    ] {
      launch("positions", options)
      let toggle = app.buttons["positions.floatingPositions"]
      XCTAssertTrue(toggle.waitForExistence(timeout: 10))
      toggle.tap()
      let toast = app.descendants(matching: .any)["app.toast"].firstMatch
      XCTAssertTrue(toast.waitForExistence(timeout: 5))
      XCTAssertTrue(toast.label.contains(expected))
      let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "未开启"), object: toggle)
      XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
      assertNoInlineFloatingCard()
      XCTAssertFalse(app.alerts["跨 App 浮窗"].exists)
      capture(name)
    }
  }

  private func assertNoInlineFloatingCard(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(app.otherElements["floating.positions.panel"].exists, file: file, line: line)
    XCTAssertFalse(app.buttons["floating.positions.next"].exists, file: file, line: line)
    XCTAssertFalse(app.buttons["floating.positions.pip"].exists, file: file, line: line)
    XCTAssertFalse(app.buttons["floating.positions.close"].exists, file: file, line: line)
    XCTAssertFalse(app.staticTexts["此视频正在以画中画播放"].exists, file: file, line: line)
    XCTAssertFalse(app.otherElements["floating.positions.pipStatus"].exists,
      "The source must remain hidden from accessibility", file: file, line: line)
  }

  func testCorePagesAndDialogs() {
    let pages: [(String, String)] = [
      ("trade", "币价"), ("positions", "开仓额度："), ("signals", "信号"), ("profile", "止损额设置"),
      ("strategies", "我的策略"), ("strategy-editor", "不移动止损位"), ("operations", "北京时间 · 最新记录在前"),
      ("transfers", "累计转出"),
      ("settings", "开启通知"), ("legal", "用户协议"), ("privacy", "隐私政策"), ("stop-loss", "止损设置"),
      ("collect", "资金归集账号"), ("login", "Binance Tools"),
    ]
    for (page, text) in pages {
      launch(page)
      XCTAssertTrue(
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
          .firstMatch.waitForExistence(timeout: 10), "Missing content on \(page)")
      capture(page + "-light")
    }
  }
  func testEmptyDarkAndLeadStates() {
    launch("positions", ["--fixture-empty", "--fixture-dark"])
    XCTAssertTrue(app.staticTexts["暂无持仓"].waitForExistence(timeout: 10))
    capture("positions-empty-dark")
    launch("trade", ["--fixture-dark", "--fixture-unbound"])
    XCTAssertTrue(app.buttons["输入止损价开仓"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["输入止损价开仓"].isEnabled)
    capture("trade-unbound-dark")
    launch("profile", ["--fixture-dark", "--fixture-lead"])
    XCTAssertTrue(app.staticTexts["带单组合可用余额 (USDT)"].waitForExistence(timeout: 10))
    capture("profile-lead-dark")
    XCTAssertFalse(app.buttons["信号"].exists)
  }
  func testNativeNavigationAndModalControls() {
    launch("profile", ["--fixture-unbound"])
    let bind = app.buttons["profile.bind"]
    XCTAssertTrue(bind.waitForExistence(timeout: 10))
    bind.tap()
    let confirm = app.buttons["确认绑定"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    XCTAssertFalse(confirm.isEnabled)
    capture("binding-empty")
    app.buttons["关闭"].firstMatch.tap()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "止损额设置")).firstMatch.tap()
    XCTAssertTrue(app.staticTexts["止损设置"].waitForExistence(timeout: 5))
    capture("stop-loss-bottom-modal")
    app.buttons["关闭"].firstMatch.tap()
    app.buttons["信号"].firstMatch.tap()
    app.buttons["内部信号规则"].tap()
    XCTAssertTrue(app.staticTexts["信号规则"].waitForExistence(timeout: 5))
    capture("signal-rules-modal")
  }
  func testSecondaryCapitalPanels() {
    for (page, text) in [
      ("capital", "归集资金"), ("reminder", "补资提醒"),
    ] {
      launch(page)
      XCTAssertTrue(
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
          .firstMatch.waitForExistence(timeout: 10), page)
      capture(page + "-light")
    }
  }
  func testPositionControlsAndTradingPicker() {
    launch("positions")
    let strategy = app.buttons["自动止盈中"]
    XCTAssertTrue(strategy.waitForExistence(timeout: 10))
    let chart = app.buttons["position.chart.101"]
    let breakEven = app.buttons["设置保本损"]
    let close = app.buttons["立即平仓"]
    XCTAssertTrue(chart.isHittable)
    XCTAssertLessThan(chart.frame.maxY, strategy.frame.minY)
    XCTAssertGreaterThan(chart.frame.minX, strategy.frame.maxX)
    XCTAssertEqual(strategy.frame.width, breakEven.frame.width, accuracy: 1)
    XCTAssertEqual(strategy.frame.width, close.frame.width, accuracy: 1)
    XCTAssertEqual(strategy.frame.minY, breakEven.frame.minY, accuracy: 1)
    XCTAssertEqual(strategy.frame.minY, close.frame.minY, accuracy: 1)
    XCTAssertFalse(app.buttons["K线"].exists)
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "绑定策略")).firstMatch.exists)
    XCTAssertFalse(app.staticTexts["30-20-50"].exists)
    capture("position-card-actions")
    strategy.tap()
    XCTAssertTrue(app.staticTexts["策略和执行日志"].waitForExistence(timeout: 5))
    capture("strategy-execution")
    app.buttons["关闭"].firstMatch.tap()
    app.buttons["设置保本损"].tap()
    XCTAssertTrue(app.staticTexts["当前浮盈"].waitForExistence(timeout: 5))
    capture("break-even")
    app.buttons["关闭"].firstMatch.tap()
    app.buttons["设置"].firstMatch.tap()
    XCTAssertTrue(app.buttons["确认设置"].waitForExistence(timeout: 5))
    capture("take-profit")
    app.buttons["关闭"].firstMatch.tap()
    app.buttons["限价委托"].tap()
    XCTAssertTrue(app.buttons["追单"].waitForExistence(timeout: 5))
    capture("limit-orders")
    app.buttons["历史仓位"].tap()
    XCTAssertTrue(app.staticTexts["平仓盈亏"].waitForExistence(timeout: 5))
    capture("position-history")
    launch("positions", ["--fixture-dark"])
    XCTAssertTrue(strategy.waitForExistence(timeout: 10))
    capture("position-card-actions-dark")
    strategy.tap()
    XCTAssertTrue(app.staticTexts["策略和执行日志"].waitForExistence(timeout: 5))
    capture("strategy-execution-dark")
    launch("trade")
    let picker = app.buttons["trade.strategy"]
    XCTAssertTrue(picker.waitForExistence(timeout: 10))
    picker.tap()
    XCTAssertTrue(app.staticTexts["我的策略"].waitForExistence(timeout: 5))
    capture("trade-strategy-navigation")
  }
  func testCapitalAndBatchPreview() {
    launch("capital", ["--fixture-capital-refill"])
    XCTAssertTrue(app.buttons["capital.submit"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["capital.submit"].isEnabled)
    capture("capital-refill-only")
    launch("positions", ["--fixture-multiple"])
    let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "全部平仓(")).firstMatch
    if !all.isHittable { app.swipeUp() }
    XCTAssertTrue(all.waitForExistence(timeout: 10))
    all.tap()
    XCTAssertTrue(app.staticTexts["全部平仓"].waitForExistence(timeout: 5))
    capture("close-all-confirmation")
    XCTAssertTrue(app.buttons["取消"].exists)
    launch("trade")
    let stop = app.textFields["usdt.field.止损价"]
    XCTAssertTrue(stop.waitForExistence(timeout: 10))
    stop.tap()
    stop.typeText("66000")
    let done = app.buttons["完成"].firstMatch
    if done.waitForExistence(timeout: 3) { done.tap() }
    let open = app.buttons["市价开多"]
    if !open.isHittable { app.swipeUp() }
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    XCTAssertTrue(open.isHittable)
    XCTAssertFalse(app.buttons["方向初筛"].exists)
    capture("entry-without-screening")
  }
  func testLoginAndPasswordResetRequest() {
    launch("login")
    XCTAssertTrue(app.staticTexts["Binance Tools"].waitForExistence(timeout: 10))
    capture("binance-tools-login")
    app.buttons["注册账号"].tap()
    XCTAssertTrue(app.staticTexts["暂未开放注册，请联系管理员"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["注册"].isEnabled)
    capture("registration-closed")
    app.buttons["返回登录"].tap()
    app.buttons["忘记密码？"].tap()
    XCTAssertTrue(app.buttons["发送重置邮件"].waitForExistence(timeout: 5))
    capture("password-reset-request")
    app.buttons["passwordReset.submit"].tap()
    XCTAssertTrue(app.staticTexts["请输入有效的邮箱地址"].waitForExistence(timeout: 5))
    app.buttons["auth.sheet.close"].tap()
    XCTAssertTrue(app.buttons["注册账号"].waitForExistence(timeout: 5))

  }

  func testAuthenticationSheetsPasswordVisibilityAndValidation() {
    launch("login", ["--fixture-registration-open"])
    app.buttons["auth.submit"].tap()
    XCTAssertTrue(app.staticTexts["请先阅读并同意用户协议和隐私政策"].waitForExistence(timeout: 5))
    let account = app.textFields["login.account"]
    account.tap()
    account.typeText("auth-ui@example.invalid")
    let password = app.secureTextFields["login.password"]
    password.tap()
    password.typeText("isolated-test-only\n")
    app.buttons["auth.passwordVisibility"].tap()
    XCTAssertEqual(app.textFields["login.password"].value as? String, "isolated-test-only")
    let hidePassword = app.buttons["auth.passwordVisibility"]
    XCTAssertEqual(hidePassword.label, "隐藏密码")
    XCTAssertTrue(hidePassword.isHittable)
    hidePassword.tap()
    XCTAssertTrue(app.secureTextFields["login.password"].waitForExistence(timeout: 5))
    app.swipeUp()
    app.buttons["注册账号"].tap()
    XCTAssertTrue(app.secureTextFields["register.confirmPassword"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.textFields["register.account"].value as? String, "auth-ui@example.invalid")
    XCTAssertEqual(app.secureTextFields["register.password"].value as? String, "至少 8 位密码")
    capture("binance-tools-registration-open")
    app.buttons["register.agreement"].tap()
    XCTAssertEqual(app.buttons["register.agreement"].value as? String, "已同意")
    // Enter visible text to avoid system strong-password suggestions interrupting rapid automation.
    // Production keeps the normal password AutoFill content types.
    app.buttons["register.passwordVisibility"].tap()
    let registrationPassword = app.textFields["register.password"]
    registrationPassword.tap()
    registrationPassword.typeText("isolated-test-only")
    XCTAssertEqual(registrationPassword.value as? String, "isolated-test-only")
    let confirmation = app.textFields["register.confirmPassword"]
    confirmation.tap()
    confirmation.typeText("different-test-only")
    XCTAssertEqual(confirmation.value as? String, "different-test-only")
    app.buttons["register.confirmVisibility"].tap()
    app.swipeUp()
    app.buttons["register.submit"].tap()
    capture("binance-tools-registration-validation")
    XCTAssertTrue(app.staticTexts["两次密码不一致"].waitForExistence(timeout: 5))
    // Validation must finish before the authentication service performs any network request.
    app.buttons["auth.sheet.close"].tap()
    XCTAssertTrue(app.buttons["注册账号"].waitForExistence(timeout: 5))
    app.buttons["注册账号"].tap()
    XCTAssertEqual(app.secureTextFields["register.confirmPassword"].value as? String, "请再次输入密码")
    // Start in the presented panel's header, independent of its safe-area inset.
    let start = app.buttons["auth.sheet.close"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .withOffset(CGVector(dx: -100, dy: 0))
    start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
    XCTAssertFalse(app.buttons["auth.sheet.close"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["注册账号"].isHittable)
  }

  func testAuthenticationDarkAndUnavailableRegistration() {
    launch("login", ["--fixture-dark", "--fixture-registration-unavailable"])
    XCTAssertTrue(app.staticTexts["Binance Tools"].waitForExistence(timeout: 10))
    capture("binance-tools-login-dark")
    app.buttons["注册账号"].tap()
    XCTAssertTrue(app.staticTexts["暂时无法获取注册状态，请重试"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["register.submit"].isEnabled)
    app.buttons["重试"].tap()
    XCTAssertTrue(app.staticTexts["暂时无法获取注册状态，请重试"].waitForExistence(timeout: 5))
    capture("binance-tools-registration-unavailable-dark")
    app.buttons["auth.sheet.close"].tap()
    app.buttons["忘记密码？"].tap()
    XCTAssertTrue(app.buttons["发送重置邮件"].waitForExistence(timeout: 5))
    capture("binance-tools-reset-dark")
    app.buttons["auth.sheet.close"].tap()
  }

  func testAuthenticationLegalSheetsReturnToRegistration() throws {
    launch("login", ["--fixture-registration-open"])
    app.buttons["注册账号"].tap()
    XCTAssertTrue(app.secureTextFields["register.confirmPassword"].waitForExistence(timeout: 5))
    let terms = try XCTUnwrap(app.links.matching(identifier: "用户协议")
      .allElementsBoundByIndex.first(where: { $0.isHittable }))
    terms.tap()
    XCTAssertTrue(app.staticTexts["欢迎使用Binance Tools"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["完成"].exists)
    capture("binance-tools-terms-sheet")
    app.buttons["auth.legal.close"].tap()
    XCTAssertTrue(app.secureTextFields["register.confirmPassword"].waitForExistence(timeout: 5))
    let privacy = try XCTUnwrap(app.links.matching(identifier: "隐私政策")
      .allElementsBoundByIndex.first(where: { $0.isHittable }))
    privacy.tap()
    XCTAssertTrue(app.staticTexts["Binance Tools隐私政策"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["完成"].exists)
    capture("binance-tools-privacy-sheet")
    app.buttons["auth.legal.close"].tap()
    XCTAssertTrue(app.buttons["auth.sheet.close"].isHittable)
    app.buttons["auth.sheet.close"].tap()
  }
}


extension WebParityUITests {
  func testCapitalWalletSheetTabsAndDirections() {
    for options in [[], ["--fixture-dark"]] {
      launch("profile", options)
      let open = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "归集余额")).firstMatch
      XCTAssertTrue(open.waitForExistence(timeout: 10))
      open.tap()
      XCTAssertTrue(app.buttons["capital.close"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.staticTexts["合约超出保留额"].exists)
      XCTAssertTrue(app.staticTexts["资金账户可划转"].exists)
      XCTAssertEqual(app.staticTexts["capital.futuresBalance"].label, "100.00")
      XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "合约余额超过止损额")).firstMatch.exists)
      XCTAssertTrue(app.buttons["capital.submit"].isEnabled)
      let total = app.descendants(matching: .any)["capital.total"].firstMatch
      let totalVisible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: total)
      XCTAssertEqual(XCTWaiter.wait(for: [totalVisible], timeout: 3), .completed,
        "The fixed footer total must remain visible above the confirm button")
      capture(options.isEmpty ? "capital-wallet-light" : "capital-wallet-dark")
      app.buttons["capital.tab.transfer"].tap()
      XCTAssertTrue(app.staticTexts["现货账户"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.staticTexts["本次转出金额"].exists)
      XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "本次转出金额")).count, 1)
      XCTAssertFalse(app.staticTexts["转出账户"].exists)
      XCTAssertFalse(app.buttons["capital.refresh"].exists)
      XCTAssertFalse(app.descendants(matching: .any)["capital.total"].exists)
      XCTAssertTrue(app.staticTexts["0x1234••••••BEEF"].exists)
      XCTAssertFalse(app.staticTexts["0x123456789012345678901234567890123456BEEF"].exists)
      capture(options.isEmpty ? "capital-transfer-light" : "capital-transfer-dark")
      app.buttons["capital.tab.records"].tap()
      XCTAssertTrue(app.buttons["collection.refresh"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.staticTexts["历史记录"].exists)
      XCTAssertFalse(app.buttons["capital.submit"].exists)
      XCTAssertFalse(app.buttons["collection.addAccount"].exists)
      XCTAssertFalse(app.descendants(matching: .any)["collection.account"].exists)
      capture(options.isEmpty ? "capital-records-light" : "capital-records-dark")
      app.buttons["capital.tab.move"].tap()
      XCTAssertTrue(app.buttons["capital.submit"].waitForExistence(timeout: 5))
      app.buttons["capital.close"].tap()
      XCTAssertTrue(open.waitForExistence(timeout: 5))
    }
    launch("capital", ["--fixture-capital-refill"])
    let direction = app.buttons["capital.direction"]
    XCTAssertTrue(direction.waitForExistence(timeout: 10))
    direction.tap()
    app.buttons["资金 → 合约"].tap()
    XCTAssertTrue(app.staticTexts["本次转入合约"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["capital.submit"].isEnabled)
    capture("capital-funding-refill")
    direction.tap()
    app.buttons["现货 → 合约"].tap()
    XCTAssertTrue(app.staticTexts["现货账户可用"].waitForExistence(timeout: 5))
  }

  func testCapitalCollectionAccountAndModeEntry() {
    launch("profile", ["--fixture-lead-disabled"])
    let switchMode = app.buttons["profile.switchMode"]
    XCTAssertTrue(switchMode.waitForExistence(timeout: 10))
    XCTAssertEqual(switchMode.label, "切换带单模式")
    capture("mode-switch-to-lead")
    switchMode.tap()
    XCTAssertTrue(app.buttons["确认切换"].waitForExistence(timeout: 5))
    app.buttons["确认切换"].tap()
    XCTAssertTrue(app.staticTexts["带单组合可用余额 (USDT)"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["profile.switchMode"].label, "切换合约模式")
    capture("mode-switch-to-contract")
    launch("transfers", ["--fixture-collection-configured"])
    XCTAssertTrue(app.staticTexts["历史记录"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["collection.addAccount"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["collection.account"].exists)
    capture("collection-history-without-account")
    launch("capital", ["--fixture-collection-configured"])
    XCTAssertTrue(app.buttons["capital.tab.transfer"].waitForExistence(timeout: 10))
    app.buttons["capital.tab.transfer"].tap()
    let manageAccount = app.buttons["collection.manageAccount"]
    XCTAssertTrue(manageAccount.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["0x1234••••••BEEF"].exists)
    manageAccount.tap()
    XCTAssertTrue(app.staticTexts["资金归集账号"].waitForExistence(timeout: 5))
    capture("collection-existing-account-editor")
    launch("capital", ["--fixture-collection-unconfigured"])
    XCTAssertTrue(app.buttons["capital.tab.transfer"].waitForExistence(timeout: 10))
    app.buttons["capital.tab.transfer"].tap()
    let addAccount = app.buttons["collection.addAccount"]
    XCTAssertTrue(addAccount.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["collection.manageAccount"].exists)
    XCTAssertFalse(app.buttons["capital.submit"].isEnabled)
    capture("collection-add-account-card")
    addAccount.tap()
    XCTAssertTrue(app.staticTexts["资金归集账号"].waitForExistence(timeout: 5))
    capture("collection-new-account-editor")
    launch("profile")
    XCTAssertTrue(app.buttons["归集余额"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["资金归集"].exists)
    app.buttons["归集余额"].tap()
    app.buttons["capital.tab.records"].tap()
    XCTAssertTrue(app.buttons["collection.refresh"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["capital.submit"].exists)
  }

  func testCapitalWalletBlockedAndEmptyStates() {
    launch("capital", ["--fixture-capital-blocked"])
    XCTAssertTrue(app.staticTexts["capital.notice"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["capital.submit"].isEnabled)
    capture("capital-wallet-blocked")
    launch("capital", ["--fixture-capital-empty"])
    XCTAssertTrue(app.staticTexts["当前方向暂无可划转金额"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["capital.submit"].isEnabled)
    capture("capital-wallet-empty")
    launch("capital", ["--fixture-capital-legacy"])
    let legacy = app.buttons["capital.submit"]
    XCTAssertTrue(legacy.waitForExistence(timeout: 10))
    XCTAssertTrue(legacy.isEnabled)
    XCTAssertEqual(legacy.label, "核对之前的归集")
    legacy.tap()
    XCTAssertTrue(app.staticTexts["调整账户资金"].waitForExistence(timeout: 5))
    capture("capital-legacy-recovery")
  }
}
