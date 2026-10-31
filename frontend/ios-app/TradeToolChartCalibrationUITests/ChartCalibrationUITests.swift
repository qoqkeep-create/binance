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
        XCTAssertEqual(favorite.frame.midX, header.frame.maxX - 26, accuracy: 1)
        XCTAssertLessThanOrEqual(favorite.frame.maxX, header.frame.maxX - 11)
        favorite.tap()
        XCTAssertEqual(favorite.value as? String, "未收藏")
        favorite.tap()
        XCTAssertEqual(favorite.value as? String, "已收藏")
        XCTAssertEqual(chart.frame.minY, header.frame.maxY, accuracy: 1)
        XCTAssertEqual(detailScroll.frame.maxY, strip.frame.minY, accuracy: 1)
        XCTAssertEqual(
            chart.frame.height - detailScroll.frame.height,
            74,
            accuracy: 1
        )
        XCTAssertGreaterThan(chart.frame.height, 520)

        XCTAssertTrue(app.scrollViews[
            "market-chart-quick-indicator-strip"
        ].exists)
        for identifier in [
            "market-chart-quick-symbol-wheel",
            "market-chart-quick-interval-wheel",
        ] {
            XCTAssertTrue(app.collectionViews[identifier].isHittable)
        }
        for identifier in [
            "market-chart-indicator-settings-shortcut",
            "market-chart-order-long", "market-chart-order-short",
        ] {
            XCTAssertTrue(app.buttons[identifier].isHittable)
        }
        XCTAssertTrue(app.buttons["设置"].isHittable)
        attachScreenshot(named: "trade-tool-chart-time-axis-and-panel-footer")
        detailScroll.swipeUp(velocity: .slow)
        waitForAnimations()
        attachScreenshot(named: "trade-tool-chart-additional-panels")
        XCTAssertTrue(app.buttons["market-chart-order-long"].isHittable)
        detailScroll.swipeDown(velocity: .slow)
        waitForAnimations()
        setTradeToolIndicator("MA", enabled: true, in: app)
        setTradeToolIndicator("MA", enabled: false, in: app)
        setTradeToolIndicator("Basis", enabled: true, in: app)
        setTradeToolIndicator("Basis", enabled: false, in: app)
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
        app.descendants(matching: .any)["market-chart-quick-symbol-next"].tap()
        waitForAnimations()
        XCTAssertEqual(
            app.descendants(matching: .any)["market-chart-quick-symbol-current"].label,
            "ETHUSDC"
        )
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

    func testCaptureTradeToolQuickSwitcherFlow() {
        let app = XCUIApplication(bundleIdentifier: AppID.tradeTool)
        app.launchArguments.append("--chart-calibration-fixture")
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Trade Tool did not enter the foreground."
        )
        openTradeToolDetailIfNeeded(in: app)
        waitForAnimations()

        let chartPlot = app.descendants(matching: .any)[
            "market-chart-plot"
        ]
        let symbolWheel = app.collectionViews[
            "market-chart-quick-symbol-wheel"
        ]
        let intervalWheel = app.collectionViews[
            "market-chart-quick-interval-wheel"
        ]
        let currentSymbol = app.descendants(matching: .any)[
            "market-chart-quick-symbol-current"
        ]
        let currentInterval = app.descendants(matching: .any)[
            "market-chart-quick-interval-current"
        ]
        XCTAssertTrue(chartPlot.waitForExistence(timeout: 15))
        XCTAssertTrue(symbolWheel.waitForExistence(timeout: 10))
        XCTAssertEqual(currentSymbol.label, "BTCUSDC")
        XCTAssertEqual(currentInterval.label, "1小时")

        let indicatorStrip = app.descendants(matching: .any)[
            "market-chart-quick-indicator-strip"
        ]
        let bottomMA = app.buttons[
            "market-chart-quick-indicator-MA"
        ]
        XCTAssertTrue(indicatorStrip.waitForExistence(timeout: 10))
        XCTAssertTrue(intervalWheel.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(
            indicatorStrip.frame.maxX,
            symbolWheel.frame.minX
        )
        XCTAssertLessThanOrEqual(
            symbolWheel.frame.maxX,
            intervalWheel.frame.minX
        )
        XCTAssertTrue(bottomMA.waitForExistence(timeout: 10))
        XCTAssertTrue(bottomMA.isHittable)
        let initialMAValue = bottomMA.value as? String
        bottomMA.tap()
        let toggledMAValue = initialMAValue == "已开启"
            ? "已关闭"
            : "已开启"
        wait(seconds: 0.8)
        XCTAssertEqual(
            bottomMA.value as? String,
            toggledMAValue
        )
        bottomMA.tap()
        wait(seconds: 0.8)
        XCTAssertEqual(bottomMA.value as? String, initialMAValue)

        attachScreenshot(named: "trade-tool-quick-switcher-btc-1h")

        let lastPanelIndicator = app.buttons[
            "market-chart-quick-indicator-Basis"
        ]
        for _ in 0..<6 where !lastPanelIndicator.isHittable {
            indicatorStrip.swipeLeft(velocity: .fast)
            wait(seconds: 0.2)
        }
        XCTAssertTrue(
            lastPanelIndicator.isHittable,
            "Bottom indicator strip did not scroll to the final panel item."
        )
        attachScreenshot(named: "trade-tool-quick-indicator-panels")

        let nextSymbol = app.descendants(matching: .any)[
            "market-chart-quick-symbol-next"
        ]
        XCTAssertTrue(nextSymbol.waitForExistence(timeout: 10))
        nextSymbol.tap()
        XCTAssertTrue(currentSymbol.waitForExistence(timeout: 10))
        wait(seconds: 1.5)
        XCTAssertEqual(currentSymbol.label, "ETHUSDC")

        let nextInterval = app.descendants(matching: .any)[
            "market-chart-quick-interval-next"
        ]
        XCTAssertTrue(nextInterval.waitForExistence(timeout: 10))
        nextInterval.tap()
        wait(seconds: 1.5)
        XCTAssertEqual(currentInterval.label, "4小时")
        XCTAssertTrue(chartPlot.exists)
        attachScreenshot(named: "trade-tool-quick-switcher-eth-4h")

        intervalWheel.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)
        ).press(
            forDuration: 0.05,
            thenDragTo: intervalWheel.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)
            ),
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        attachImmediateScreenshot(
            named: "trade-tool-quick-switcher-wheel-preview"
        )
        wait(seconds: 1.5)
        XCTAssertFalse(app.descendants(matching: .any)[
            "market-chart-wheel-preview"
        ].exists)
        XCTAssertEqual(currentInterval.label, "1天")
        XCTAssertTrue(chartPlot.exists)
        attachScreenshot(named: "trade-tool-quick-switcher-dragged-1d")

        let indicatorSettingsShortcut = app.buttons[
            "market-chart-indicator-settings-shortcut"
        ]
        XCTAssertTrue(
            indicatorSettingsShortcut.waitForExistence(timeout: 10)
        )
        indicatorSettingsShortcut.tap()
        XCTAssertTrue(
            app.staticTexts["指标设置"].waitForExistence(timeout: 10)
        )
        attachScreenshot(named: "trade-tool-bottom-indicator-settings")
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
        let current = app.descendants(matching: .any)[
            "market-chart-quick-interval-current"
        ]
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        for _ in 0..<6 where current.label != title {
            app.descendants(matching: .any)[
                "market-chart-quick-interval-next"
            ].tap()
            wait(seconds: 0.8)
        }
        XCTAssertEqual(current.label, title)
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
        let marketTitle = app.staticTexts["合约"]
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
        app.buttons["返回"].firstMatch.tap()
        app.buttons["持仓"].firstMatch.tap()
        XCTAssertTrue(app.buttons["限价委托"].waitForExistence(timeout: 10))
        app.buttons["开仓"].firstMatch.tap()
        let submit = app.buttons["输入止损价开仓"].firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        XCTAssertFalse(submit.isEnabled, "Unbound account must not place an order")
        capture(app, "integrated-ios-open")
        app.buttons["信号"].firstMatch.tap()
        XCTAssertTrue(app.buttons["外部"].waitForExistence(timeout: 10))
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
  func testFloatingPositionsAcrossPagesAndDragging() {
    launch("profile", ["--fixture-multiple"])
    let toggle = app.buttons["profile.floatingPositions"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10))
    if !toggle.isHittable { app.swipeUp() }
    toggle.tap()
    let panel = app.otherElements["floating.positions.panel"]
    let price = app.staticTexts["floating.position.price"]
    let profit = app.staticTexts["floating.position.profit"]
    XCTAssertTrue(price.waitForExistence(timeout: 10))
    XCTAssertEqual(price.label, "68000")
    XCTAssertEqual(profit.label, "+25.00 U")
    capture("floating-profile")
    app.buttons["floating.positions.next"].tap()
    XCTAssertEqual(price.label, "2600.5")
    XCTAssertEqual(profit.label, "-3.50 U")
    app.buttons["持仓"].firstMatch.tap()
    XCTAssertTrue(app.buttons["限价委托"].waitForExistence(timeout: 5))
    XCTAssertEqual(price.label, "2600.5")
    capture("floating-positions")
    app.buttons["我的"].firstMatch.tap()
    let strategy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "止盈止损策略")).firstMatch
    XCTAssertTrue(strategy.waitForExistence(timeout: 5))
    if !strategy.isHittable { app.swipeUp() }
    strategy.tap()
    XCTAssertTrue(app.staticTexts["我的策略"].waitForExistence(timeout: 5))
    XCTAssertEqual(price.label, "2600.5")
    let before = panel.frame
    let start = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
    let target = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: before.midX - 100, dy: before.midY + 160))
    start.press(forDuration: 0.1, thenDragTo: target)
    XCTAssertLessThan(panel.frame.minX, before.minX - 40)
    capture("floating-dragged-detail")
    app.buttons["floating.positions.close"].tap()
    XCTAssertFalse(panel.exists)
    app.buttons["返回"].firstMatch.tap()
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    XCTAssertEqual(toggle.value as? String, "未开启")
  }

  func testFloatingPositionsEmptyUnboundAndDarkStates() {
    for (options, expected, name) in [
      (["--fixture-empty"], "暂无持仓", "floating-empty"),
      (["--fixture-unbound"], "请先绑定 API", "floating-unbound"),
      (["--fixture-dark", "--fixture-lead"], "+25.00 U", "floating-lead-dark"),
    ] {
      launch("profile", options)
      let toggle = app.buttons["profile.floatingPositions"]
      XCTAssertTrue(toggle.waitForExistence(timeout: 10))
      if !toggle.isHittable { app.swipeUp() }
      toggle.tap()
      XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 10))
      capture(name)
      app.buttons["floating.positions.close"].tap()
      XCTAssertFalse(app.otherElements["floating.positions.panel"].exists)
    }
  }

  func testWatchEditingAndResearchModel() {
    launch("watch-editor")
    XCTAssertTrue(app.staticTexts["写计划"].waitForExistence(timeout: 10))
    capture("watch-editor-final")
    launch("watch-score")
    let save = app.buttons["确定"]
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    capture("watch-score-initial")
    XCTAssertTrue(app.staticTexts["评分"].isHittable)
    XCTAssertTrue(save.isHittable)
    let pinnedY = save.frame.minY
    app.swipeUp()
    XCTAssertEqual(save.frame.minY, pinnedY, accuracy: 1)
    capture("watch-score-pinned")
    launch("watch-review")
    XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue((app.textViews.firstMatch.value as? String)?.contains("严格按计划执行") == true)
    XCTAssertLessThan(app.textViews.firstMatch.frame.minY - app.buttons["关闭"].frame.maxY, 50)
    capture("watch-review")
    launch("watch-result")
    XCTAssertTrue(app.textFields["usdt.field.止盈止损金额"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.textFields["usdt.field.止盈止损金额"].value as? String, "25")
    XCTAssertTrue(app.buttons["确定"].isHittable)
    capture("watch-result")
    launch("research-rules")
    let model = app.buttons["选择大模型"]
    XCTAssertTrue(model.waitForExistence(timeout: 10))
    model.tap()
    XCTAssertTrue(app.buttons["确定使用"].waitForExistence(timeout: 5))
    capture("research-model")
  }
  func testCorePagesAndDialogs() {
    let pages: [(String, String)] = [
      ("trade", "币价"), ("positions", "开仓额度："), ("signals", "外部"), ("profile", "止损额设置"),
      ("strategies", "我的策略"), ("strategy-editor", "不移动止损位"), ("operations", "北京时间 · 最新记录在前"),
      ("transfers", "累计转出"), ("watch", "记录"), ("watch-editor", "写计划"), ("research", "录入一个已收盘信号样本"),
      ("settings", "颜色模式"), ("legal", "用户协议"), ("privacy", "隐私政策"), ("stop-loss", "止损设置"),
      ("collect", "资金归集账号"), ("login", "RISKON"),
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
    app.buttons["内部"].firstMatch.tap()
    app.buttons["内部信号规则"].tap()
    XCTAssertTrue(app.staticTexts["信号规则"].waitForExistence(timeout: 5))
    capture("signal-rules-modal")
  }
  func testSecondaryResearchCapitalAndPreflight() {
    for (page, text) in [
      ("research-analysis", "量化特征快照"), ("research-rules", "AI 生成策略草案"),
      ("research-backtest", "运行策略回测"), ("capital", "调整账户资金"), ("reminder", "补资提醒"),
      ("indicators", "创建指标"), ("preflight", "交易前校准"),
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
    launch("trade")
    let picker = app.buttons["trade.strategy"]
    XCTAssertTrue(picker.waitForExistence(timeout: 10))
    picker.tap()
    XCTAssertTrue(app.staticTexts["我的策略"].waitForExistence(timeout: 5))
    capture("trade-strategy-navigation")
  }
  func testResearchDateCapitalAndBatchPreview() {
    launch("research-analysis")
    let chart = app.buttons["查看蜡烛图"]
    XCTAssertTrue(chart.waitForExistence(timeout: 10))
    chart.tap()
    XCTAssertTrue(app.descendants(matching: .any)["research.candles"].waitForExistence(timeout: 10))
    capture("research-candles")
    launch("capital", ["--fixture-capital-refill"])
    XCTAssertTrue(app.buttons["确认调整"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["确认调整"].isEnabled)
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
    app.buttons["方向初筛"].tap()
    let open = app.buttons["市价开多"]
    if !open.isHittable { app.swipeUp() }
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    XCTAssertTrue(open.isHittable)
    capture("ema-passed")
  }
  func testLoginAndLocalIndicatorEditing() {
    launch("login")
    app.buttons["注册账号"].tap()
    XCTAssertTrue(app.staticTexts["暂未开放注册，请联系管理员"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["注册"].isEnabled)
    capture("registration-closed")
    app.buttons["返回登录"].tap()
    app.buttons["忘记密码？"].tap()
    XCTAssertTrue(app.buttons["发送重置邮件"].waitForExistence(timeout: 5))
    capture("password-reset-request")
    launch("indicators")
    app.buttons["创建指标"].tap()
    XCTAssertTrue(app.buttons["保存指标"].waitForExistence(timeout: 5))
    capture("indicator-editor")
  }
}
