import MetalKit
import UIKit

@MainActor
final class KlineChartHostView: UIView {
    var onCrosshairSelection: ((ChartCrosshairSelection) -> Void)?
    var onCrosshairDismiss: (() -> Void)?
    private let metalView: MTKView
    private let candleMarkerContainer = UIView()
    private let loadingCover = UIView()
    private var candleMarkers: [ChartCandleMarker] = []
    private var candleMarkerExclusions: [CGRect] = []
    private var candleMarkerLabels: [String: UILabel] = [:]
    private let errorLabel = UILabel()
    private let rendererHealth = MetalRendererHealth()
    private let interactionMetrics = ChartInteractionMetrics.standard
    private let motionMetrics = ChartTimelineMotionMetrics.standard
    private let crosshairOverlayBuilder =
        ChartCrosshairOverlayBuilder()
    private let crosshairFeedback = UIImpactFeedbackGenerator(
        style: .light
    )
    private var frameCoordinator: MetalFrameCoordinator?
    private lazy var timelinePanGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleTimelinePan(_:))
    )
    private lazy var priceScalePanGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handlePriceScalePan(_:))
    )
    private lazy var timelinePinchGesture = UIPinchGestureRecognizer(
        target: self,
        action: #selector(handleTimelinePinch(_:))
    )
    private lazy var crosshairGesture = UILongPressGestureRecognizer(
        target: self,
        action: #selector(handleCrosshair(_:))
    )
    private lazy var crosshairTapGesture = UITapGestureRecognizer(
        target: self,
        action: #selector(handleCrosshairTap(_:))
    )
    private weak var coordinatedScrollView: UIScrollView?
    private var interactionState = ChartInteractionStateMachine()
    private var timelineMotion = ChartTimelineMotion()
    private var timelineViewport: ChartTimelineViewport?
    private var priceViewport: ChartPriceViewport = .automatic
    private var automaticallyFitsPrice = false
    private var priceViewportBaseline: ChartPriceViewport?
    private var lastPublishedPriceViewport: ChartPriceViewport?
    private var isPriceScaleGestureActive = false
    private var interactionBaseline: ChartTimelineViewport?
    private var gestureViewportBaseline: ChartTimelineViewport?
    private var interactionBaseStaticRevision: UInt64?
    private var pendingGuardBandRebase: ChartTimelineViewport?
    private var pendingContinuousViewport: ChartTimelineViewport?
    private var committedViewportAwaitingRender:
        ChartTimelineViewport?
    private var baseRenderState: RenderState?
    private var interactionRevision: UInt64 = 0
    private var boundaryTranslationPoints: Double = 0
    private var lastInteractionFrameTimestamp: CFTimeInterval?
    private var pinchAnchorFraction: Double = 0.5
    private var pricePinchAnchorFraction: Double = 0.5
    private var currentCrosshair: CrosshairSnapshot? {
        didSet {
            if oldValue != nil, currentCrosshair == nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.currentCrosshair == nil else { return }
                    self.onCrosshairDismiss?()
                }
            }
        }
    }
    private var crosshairLocationPixels: ChartPolylinePoint?
    private var totalSlotCount = 0
    private var onTimelineViewportChange:
        ((ChartTimelineViewport) -> Void)?
    private var onPriceViewportChange:
        ((ChartPriceViewport) -> Void)?
    private var applicationActivity:
        MetalApplicationActivity = .unknown
    private var isDisposed = false
    private var appearance: ChartAppearance = .dark
    private var presentationID: ChartPresentationID?
    private var isLoadingPresentation = false
    private var firstPresentationDelivered = false
    private var onFirstFramePresented: ((ChartPresentationID, TimeInterval) -> Void)?

    func observeFirstPresentation(for id: ChartPresentationID?,
        _ callback: @escaping (ChartPresentationID, TimeInterval) -> Void) {
        guard !isDisposed else { return }
        onFirstFramePresented = callback
        guard presentationID != id else { return }
        setLoadingPresentation(true)
        // A cached switch can replace the epoch without an intermediate nil frame.
        // Clear every gesture baseline before configuring the new interval.
        cancelActiveInteraction(publishViewport: false)
        resetCrosshairWithoutSubmitting()
        timelineViewport = nil
        interactionBaseline = nil
        gestureViewportBaseline = nil
        interactionBaseStaticRevision = nil
        pendingGuardBandRebase = nil
        pendingContinuousViewport = nil
        committedViewportAwaitingRender = nil
        baseRenderState = nil
        presentationID = id
        firstPresentationDelivered = false
        rendererHealth.observeFirstPresentation(for: id) { [weak self] submittedID, time in
            Task { @MainActor [weak self] in
                guard let self, !self.isDisposed, !self.firstPresentationDelivered,
                      self.presentationID == submittedID else { return }
                self.firstPresentationDelivered = true
                self.isUserInteractionEnabled = !self.isLoadingPresentation
                if !self.isLoadingPresentation { self.loadingCover.isHidden = true }
                self.onFirstFramePresented?(submittedID, time)
            }
        }
    }

    func setLoadingPresentation(_ loading: Bool) {
        guard !isDisposed, isLoadingPresentation != loading else { return }
        isLoadingPresentation = loading
        loadingCover.isHidden = !loading && (presentationID == nil || firstPresentationDelivered)
        isUserInteractionEnabled = !loading && (presentationID == nil || firstPresentationDelivered)
        if loading {
            frameCoordinator?.suspend()
            cancelActiveInteraction(publishViewport: false)
            resetCrosshairWithoutSubmitting()
            baseRenderState = nil
            candleMarkerContainer.isHidden = true
        }
        reconcileRenderingActivity()
    }

    private var isApplicationActive: Bool {
        applicationActivity == .active
    }

    override init(frame: CGRect) {
        let device = MTLCreateSystemDefaultDevice()
        metalView = MTKView(frame: .zero, device: device)
        super.init(frame: frame)
#if DEBUG
        Self.diagnosticInitializationCount += 1
#endif

        configureMetalView()
        candleMarkerContainer.isUserInteractionEnabled = false
        candleMarkerContainer.clipsToBounds = true
        addSubview(candleMarkerContainer)
        loadingCover.isUserInteractionEnabled = false
        loadingCover.isHidden = true
        addSubview(loadingCover)
        configureErrorLabel()
        setAppearance(appearance)
        configureGestures()
        applicationActivity = Self.metalApplicationActivity(
            for: UIApplication.shared.applicationState
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didReceiveMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        updateHostPresentationContext()

        guard let device else {
            showError("当前设备无法创建 Metal 渲染器")
            return
        }

        do {
            let health = rendererHealth
            let pixelFormat = metalView.colorPixelFormat
            let rendererFactory = {
                try MetalRenderer(
                    device: device,
                    pixelFormat: pixelFormat,
                    health: health
                )
            }
            let renderer = try rendererFactory()
            frameCoordinator = MetalFrameCoordinator(
                view: metalView,
                renderer: renderer,
                rendererFactory: rendererFactory,
                onRendererStopped: { [weak self] message in
                    self?.rendererDidStop(message)
                },
                onInteractionFrame: { [weak self] timestamp in
                    self?.interactionFrameDidFire(timestamp)
                }
            )
            reconcileRenderingActivity()
        } catch {
            showError("K线渲染器初始化失败")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        loadingCover.frame = bounds
        errorLabel.frame = bounds.insetBy(dx: 24, dy: 24)

        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalView.contentScaleFactor = scale
        metalView.drawableSize = CGSize(
            width: max(0, bounds.width * scale),
            height: max(0, bounds.height * scale)
        )
        updateHostPresentationContext()
        updateCandleMarkers()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            cancelActiveInteraction(publishViewport: true)
        }
        coordinateWithParentScrollView()
        reconcileRenderingActivity()
    }

    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let beginsPinch = gestureRecognizer === timelinePinchGesture
        guard !isDisposed,
              !isLoadingPresentation,
              !isPriceScaleGestureActive,
              (beginsPinch ? interactionState.canBeginPinch : interactionState.state == .idle),
              committedViewportAwaitingRender == nil,
              pendingGuardBandRebase == nil else {
            return false
        }
        let shouldBegin: Bool
        if gestureRecognizer === priceScalePanGesture {
            guard currentCrosshair == nil else {
                return false
            }
            let velocity = priceScalePanGesture.velocity(in: self)
            let location = priceScalePanGesture.location(in: self)
            shouldBegin = !automaticallyFitsPrice && isPriceScaleAxisLocation(location)
                && abs(velocity.y) > abs(velocity.x)
        } else if gestureRecognizer === timelinePanGesture {
            guard interactionState.state != .trackingCrosshair else { return false }
            let velocity = timelinePanGesture.velocity(in: self)
            let location = timelinePanGesture.location(in: self)
            let translation = timelinePanGesture.translation(in: self)
            let initialLocation = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            shouldBegin = (!automaticallyFitsPrice && isManualPricePlotLocation(initialLocation))
                || ChartPanDirectionResolver.ownership(
                velocityX: Double(velocity.x),
                velocityY: Double(velocity.y),
                initialX: Double(location.x - translation.x),
                metrics: interactionMetrics
            ) == .chart
        } else if gestureRecognizer === timelinePinchGesture {
            shouldBegin = true
        } else if gestureRecognizer === crosshairGesture {
            let location = crosshairGesture.location(in: self)
            shouldBegin = Double(location.x)
                > interactionMetrics.systemNavigationEdgeWidthPoints
                && resolveCrosshair(
                    location: location,
                    preferredOpenTime: nil,
                    preferredPanelID: nil,
                    clampsToPlot: false
                ) != nil
        } else if gestureRecognizer === crosshairTapGesture {
            let location = crosshairTapGesture.location(in: self)
            shouldBegin = currentCrosshair != nil
                || isLatestPriceReturnHit(location)
                || (
                    Double(location.x)
                        > interactionMetrics
                            .systemNavigationEdgeWidthPoints
                    && resolveCrosshair(
                        location: location,
                        preferredOpenTime: nil,
                        preferredPanelID: nil,
                        clampsToPlot: false
                    ) != nil
                )
        } else {
            shouldBegin = false
        }
        if timelineMotion.isActive {
            interruptTimelineMotionForGesture()
            if !shouldBegin {
                settleInteractionViewport()
            }
        }
        return shouldBegin
    }

    func configureTimelineInteraction(
        viewport: ChartTimelineViewport,
        totalSlotCount: Int,
        onChange: @escaping (ChartTimelineViewport) -> Void
    ) {
        self.totalSlotCount = max(0, totalSlotCount)
        onTimelineViewportChange = onChange
        let clamped = viewport.clamped(
            totalSlotCount: self.totalSlotCount,
            metrics: interactionMetrics
        )
        if interactionState.state == .idle,
           !timelineMotion.isActive,
           interactionBaseline == nil,
           committedViewportAwaitingRender == nil,
           pendingGuardBandRebase == nil {
            timelineViewport = clamped
        }
        updateTimelineAccessibilityState()
    }

    func configurePriceInteraction(
        viewport: ChartPriceViewport,
        automaticallyFitsPrice: Bool = false,
        onChange: @escaping (ChartPriceViewport) -> Void
    ) {
        onPriceViewportChange = onChange
        self.automaticallyFitsPrice = automaticallyFitsPrice
        if !isPriceScaleGestureActive && priceViewportBaseline == nil {
            priceViewport = viewport
        }
    }

    func setAppearance(_ appearance: ChartAppearance) {
        self.appearance = appearance
        let background = ChartColor.chartBackground.resolved(for: appearance)
        let color = UIColor(
            red: CGFloat(background.red),
            green: CGFloat(background.green),
            blue: CGFloat(background.blue),
            alpha: CGFloat(background.alpha)
        )
        let linear = background.linearRGBA
        backgroundColor = color
        loadingCover.backgroundColor = color
        metalView.backgroundColor = color
        metalView.clearColor = MTLClearColor(
            red: Double(linear.x),
            green: Double(linear.y),
            blue: Double(linear.z),
            alpha: Double(linear.w)
        )
        errorLabel.backgroundColor = color
        errorLabel.textColor = .secondaryLabel
        updateCandleMarkers()
    }

    func setCandleMarkers(_ markers: [ChartCandleMarker], exclusions: [CGRect] = []) {
        guard candleMarkers != markers || candleMarkerExclusions != exclusions else { return }
        candleMarkers = markers
        candleMarkerExclusions = exclusions
        let identifiers = Set(markers.map(\.id))
        for id in candleMarkerLabels.keys.filter({ !identifiers.contains($0) }) {
            candleMarkerLabels.removeValue(forKey: id)?.removeFromSuperview()
        }
        updateCandleMarkers()
    }

    private func updateCandleMarkers() {
        guard !isDisposed, !candleMarkers.isEmpty,
              let state = baseRenderState, let data = state.staticScene.crosshairData,
              let plot = data.panelLayout.pricePanel?.plot else {
            candleMarkerContainer.isHidden = true
            return
        }
        let scale = Double(data.displayScale)
        candleMarkerContainer.frame = CGRect(x: Double(plot.left) / scale, y: Double(plot.top) / scale,
            width: Double(plot.width) / scale, height: Double(plot.height) / scale)
        candleMarkerContainer.isHidden = false
        let transform = currentTimelineTransform()
        for marker in candleMarkers {
            var frame: CGRect?
            if marker.symbol == data.stream.symbol {
                let candle: ChartCandle?
                let slot: Int?
                if let tail = state.liveTail.candle, data.reservesLiveSlot,
                   tail.openTime <= marker.timestamp, marker.timestamp <= tail.closeTime {
                    candle = tail
                    slot = data.historyCount
                } else if let index = marker.candleIndex(in: data.history.candles) {
                    candle = data.history.candles[index]
                    slot = index
                } else {
                    candle = nil
                    slot = nil
                }
                if let candle, let slot, let x = data.baselineX(globalSlot: slot) {
                    frame = ChartCandleMarkerLayout.frame(marker: marker, candle: candle, baselineX: x,
                        plot: plot, domain: data.priceDomain, transform: transform, displayScale: scale,
                        boundaryTranslationPoints: boundaryTranslationPoints, avoiding: candleMarkerExclusions)
                }
            }
            guard let frame else { candleMarkerLabels[marker.id]?.isHidden = true; continue }
            let label: UILabel
            if let existing = candleMarkerLabels[marker.id] { label = existing }
            else {
                label = UILabel()
                label.font = .systemFont(ofSize: 7.5, weight: .bold)
                label.textAlignment = .center
                label.textColor = .white
                label.layer.cornerRadius = 2
                label.clipsToBounds = true
                label.isAccessibilityElement = true
                label.accessibilityIdentifier = marker.id
                candleMarkerLabels[marker.id] = label
                candleMarkerContainer.addSubview(label)
            }
            label.isHidden = false
            label.text = marker.text
            label.accessibilityLabel = marker.accessibilityLabel
            let color = marker.color.resolved(for: appearance)
            label.backgroundColor = UIColor(red: CGFloat(color.red), green: CGFloat(color.green),
                blue: CGFloat(color.blue), alpha: CGFloat(color.alpha))
            label.frame = frame.offsetBy(dx: -candleMarkerContainer.frame.minX,
                dy: -candleMarkerContainer.frame.minY)
        }
    }

    func submit(_ incomingState: RenderState) {
        let state = incomingState.withAppearance(appearance).withPresentationID(presentationID)
        baseRenderState = state
        defer { updateCandleMarkers() }
        updateTimelineAccessibilityState()
        if currentCrosshair != nil,
           let location = crosshairLocationPixels {
            let refreshed = updateCrosshair(
                locationPixels: location,
                preferredOpenTime:
                    currentCrosshair?.hit.selection.openTime,
                preferredPanelID:
                    currentCrosshair?.hit.selection.panelID,
                clampsToPlot: true,
                producesFeedback: false
            )
            if !refreshed {
                resetCrosshairWithoutSubmitting()
            }
        }
        if resolveRebasedSceneIfNeeded(state) {
            return
        }
        if interactionState.state != .idle
            || timelineMotion.isActive
            || interactionBaseline != nil
            || committedViewportAwaitingRender != nil {
            submitInteractiveFrame()
        } else {
            frameCoordinator?.submit(state)
        }
    }

    func startInteractionFrames() {
        frameCoordinator?.startInteractionFrames()
    }

    func stopInteractionFrames() {
        frameCoordinator?.stopInteractionFrames()
    }

    func dispose() {
        guard !isDisposed else {
            return
        }
        isDisposed = true
        cancelActiveInteraction(publishViewport: false)
        onTimelineViewportChange = nil
        onPriceViewportChange = nil
        onCrosshairSelection = nil
        onCrosshairDismiss = nil
        onFirstFramePresented = nil
        baseRenderState = nil
        candleMarkerContainer.isHidden = true
        candleMarkers = []
        candleMarkerLabels.values.forEach { $0.removeFromSuperview() }
        candleMarkerLabels = [:]
        pendingGuardBandRebase = nil
        pendingContinuousViewport = nil
        committedViewportAwaitingRender = nil
        timelinePanGesture.isEnabled = false
        priceScalePanGesture.isEnabled = false
        timelinePinchGesture.isEnabled = false
        crosshairGesture.isEnabled = false
        crosshairTapGesture.isEnabled = false
        NotificationCenter.default.removeObserver(self)
        frameCoordinator?.dispose()
        frameCoordinator = nil
    }

#if DEBUG
    private(set) static var diagnosticInitializationCount = 0

    var diagnosticRendererIdentity: ObjectIdentifier? {
        frameCoordinator?.diagnosticRendererIdentity
    }

    var diagnosticIsLoadingCovered: Bool { !loadingCover.isHidden }

    var diagnosticVisibleRendererError: String? {
        guard !isHidden, !errorLabel.isHidden,
              let labelIndex = subviews.firstIndex(of: errorLabel),
              let coverIndex = subviews.firstIndex(of: loadingCover), labelIndex > coverIndex else { return nil }
        return errorLabel.text
    }

    var diagnosticHasInteractionBaseline: Bool {
        interactionBaseline != nil || gestureViewportBaseline != nil
            || committedViewportAwaitingRender != nil || pendingGuardBandRebase != nil
            || pendingContinuousViewport != nil || currentCrosshair != nil || timelineMotion.isActive
    }

    func diagnosticRecordPresentation(for id: ChartPresentationID, at time: TimeInterval) {
        rendererHealth.recordPresented(revision: 1, liveRevision: 1, liveReadyTime: 1,
            presentedTime: time, readyTime: 1, submittedTime: 2, presentationID: id)
    }

    func diagnosticHealthSnapshot()
        -> MetalRendererHealthSnapshot {
        rendererHealth.snapshot()
    }

    func diagnosticSuspend() {
        frameCoordinator?.suspend()
    }

    func diagnosticResume() {
        frameCoordinator?.resume()
    }

    var diagnosticIsRendererSuspended: Bool {
        frameCoordinator?.isSuspended ?? true
    }

    var diagnosticIsInteractionActive: Bool {
        frameCoordinator?.diagnosticIsInteractionActive ?? false
    }

    var diagnosticIsApplicationActive: Bool {
        isApplicationActive
    }

    func diagnosticSetApplicationActive(_ isActive: Bool) {
        setApplicationActive(isActive)
    }

    func diagnosticMemoryWarning() {
        frameCoordinator?.handleMemoryWarning()
    }

    func diagnosticDraw() {
        metalView.draw()
    }

    func diagnosticInteractionFrame(at timestamp: CFTimeInterval) {
        interactionFrameDidFire(timestamp)
    }

    func diagnosticInjectCommandFailure() {
        frameCoordinator?.diagnosticInjectCommandFailure()
    }

    var diagnosticIsRendererStopped: Bool {
        frameCoordinator?.diagnosticIsStopped ?? true
    }

    func diagnosticDispose() {
        dispose()
    }
#endif

    @objc
    private func didReceiveMemoryWarning() {
        frameCoordinator?.handleMemoryWarning()
    }

    @objc
    private func applicationWillResignActive() {
        setApplicationActivity(.inactive)
    }

    @objc
    private func applicationDidEnterBackground() {
        setApplicationActivity(.background)
    }

    @objc
    private func applicationWillEnterForeground() {
        setApplicationActivity(.inactive)
    }

    @objc
    private func applicationDidBecomeActive() {
        setApplicationActivity(.active)
    }

    private func setApplicationActive(_ isActive: Bool) {
        setApplicationActivity(isActive ? .active : .inactive)
    }

    private func setApplicationActivity(
        _ activity: MetalApplicationActivity
    ) {
        guard !isDisposed else {
            return
        }
        if activity != .active {
            cancelActiveInteraction(publishViewport: true)
        }
        applicationActivity = activity
        reconcileRenderingActivity()
    }

    private func reconcileRenderingActivity() {
        guard !isDisposed else {
            return
        }
        updateHostPresentationContext()
        if window != nil, isApplicationActive, !isLoadingPresentation {
            frameCoordinator?.resume()
        } else {
            frameCoordinator?.suspend()
        }
    }

    private func updateHostPresentationContext() {
        let attachedWindow = window
        let isAttached = attachedWindow != nil
        let hasVisibleBounds =
            bounds.width > 0 && bounds.height > 0
        rendererHealth.updateHostPresentationContext(
            applicationActivity: applicationActivity,
            isAttachedToWindow: isAttached,
            isHostVisible: isAttached
                && !isHidden
                && alpha > 0.01
                && hasVisibleBounds,
            isWindowVisible: attachedWindow.map {
                !$0.isHidden && $0.alpha > 0.01
            } ?? false
        )
    }

    private static func metalApplicationActivity(
        for state: UIApplication.State
    ) -> MetalApplicationActivity {
        switch state {
        case .active:
            .active
        case .inactive:
            .inactive
        case .background:
            .background
        @unknown default:
            .unknown
        }
    }

    private func configureMetalView() {
        metalView.colorPixelFormat = .bgra8Unorm_srgb
        metalView.sampleCount = 1
        metalView.framebufferOnly = true
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.autoResizeDrawable = false
        addSubview(metalView)
    }

    private func configureErrorLabel() {
        errorLabel.isHidden = true
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.textColor = UIColor(
            red: 156 / 255,
            green: 156 / 255,
            blue: 156 / 255,
            alpha: 1
        )
        errorLabel.font = .systemFont(ofSize: 12)
        addSubview(errorLabel)
    }

    private func configureGestures() {
        priceScalePanGesture.delegate = self
        priceScalePanGesture.maximumNumberOfTouches = 1
        priceScalePanGesture.cancelsTouchesInView = true
        addGestureRecognizer(priceScalePanGesture)

        timelinePanGesture.delegate = self
        timelinePanGesture.maximumNumberOfTouches = 1
        timelinePanGesture.cancelsTouchesInView = true
        addGestureRecognizer(timelinePanGesture)

        timelinePinchGesture.delegate = self
        timelinePinchGesture.cancelsTouchesInView = true
        addGestureRecognizer(timelinePinchGesture)

        crosshairGesture.delegate = self
        crosshairGesture.minimumPressDuration =
            interactionMetrics
                .crosshairMinimumPressDurationSeconds
        crosshairGesture.allowableMovement = CGFloat(
            interactionMetrics.crosshairAllowableMovementPoints
        )
        crosshairGesture.numberOfTouchesRequired = 1
        crosshairGesture.cancelsTouchesInView = true
        addGestureRecognizer(crosshairGesture)

        crosshairTapGesture.delegate = self
        crosshairTapGesture.numberOfTapsRequired = 1
        crosshairTapGesture.cancelsTouchesInView = true
        crosshairTapGesture.require(toFail: crosshairGesture)
        addGestureRecognizer(crosshairTapGesture)
    }

    private func coordinateWithParentScrollView() {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView {
                guard coordinatedScrollView !== scrollView else {
                    return
                }
                coordinatedScrollView = scrollView
                scrollView.panGestureRecognizer.require(
                    toFail: timelinePanGesture
                )
                scrollView.panGestureRecognizer.require(
                    toFail: priceScalePanGesture
                )
                return
            }
            ancestor = current.superview
        }
        coordinatedScrollView = nil
    }

    @objc
    private func handlePriceScalePan(
        _ recognizer: UIPanGestureRecognizer
    ) {
        switch recognizer.state {
        case .began:
            priceViewportBaseline = priceViewport
            lastPublishedPriceViewport = priceViewport
            isPriceScaleGestureActive = true
            startInteractionFrames()
        case .changed:
            guard let baseline = priceViewportBaseline else {
                return
            }
            let next = baseline.adjusted(
                verticalTranslationPoints: Double(
                    recognizer.translation(in: self).y
                )
            )
            publishPriceViewport(next, force: false)
        case .ended, .cancelled, .failed:
            guard let baseline = priceViewportBaseline else {
                isPriceScaleGestureActive = false
                stopInteractionFrames()
                return
            }
            let next = baseline.adjusted(
                verticalTranslationPoints: Double(
                    recognizer.translation(in: self).y
                )
            )
            publishPriceViewport(next, force: true)
            priceViewportBaseline = nil
            lastPublishedPriceViewport = nil
            isPriceScaleGestureActive = false
            stopInteractionFrames()
        default:
            break
        }
    }

    private func publishPriceViewport(
        _ viewport: ChartPriceViewport,
        force: Bool
    ) {
        let prior = lastPublishedPriceViewport
        priceViewport = viewport
        guard force || prior != viewport else {
            return
        }
        lastPublishedPriceViewport = viewport
        onPriceViewportChange?(viewport)
    }

    private func beginTimelinePan() -> Bool {
        if currentCrosshair != nil { dismissCrosshair() }
        guard interactionState.beginPan(), let timelineViewport else { return false }
        gestureViewportBaseline = timelineViewport
        if interactionBaseline == nil {
            interactionBaseline = timelineViewport
            interactionBaseStaticRevision = baseRenderState?.staticScene.revision
        }
        timelineMotion.cancel()
        boundaryTranslationPoints = 0
        lastInteractionFrameTimestamp = nil
        pendingGuardBandRebase = nil
        committedViewportAwaitingRender = nil
        startInteractionFrames()
        return true
    }

    private func updateTimelinePan(translationPoints: Double) {
        guard interactionState.state == .panningTimeline,
              let baseline = gestureViewportBaseline else { return }
        let sample = baseline.pannedWithBoundaryResistance(
            translationPoints: translationPoints,
            plotWidthPoints: interactionMetrics.plotWidth(totalWidthPoints: Double(bounds.width)),
            totalSlotCount: totalSlotCount, interactionMetrics: interactionMetrics, motionMetrics: motionMetrics)
        boundaryTranslationPoints = sample.boundaryTranslationPoints
        updateInteractiveTimelineViewport(sample.viewport)
    }

    @objc
    private func handleTimelinePan(
        _ recognizer: UIPanGestureRecognizer
    ) {
        switch recognizer.state {
        case .began:
            guard beginTimelinePan() else {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
                return
            }
            if !automaticallyFitsPrice, priceViewport.fixedRange != nil,
               isManualPricePlotLocation(recognizer.location(in: self)) {
                priceViewportBaseline = priceViewport
            }
        case .changed:
            updateManualPricePan(recognizer, force: false)
            updateTimelinePan(translationPoints: Double(recognizer.translation(in: self).x))
        case .ended:
            updateManualPricePan(recognizer, force: true)
            priceViewportBaseline = nil
            lastPublishedPriceViewport = nil
            finishPanInteraction(
                velocityPointsPerSecond: Double(
                    recognizer.velocity(in: self).x
                ),
                allowsInertia: true
            )
        case .cancelled, .failed:
            priceViewportBaseline = nil
            lastPublishedPriceViewport = nil
            finishPanInteraction(
                velocityPointsPerSecond: 0,
                allowsInertia: false
            )
        default:
            break
        }
    }

    private func updateManualPricePan(_ recognizer: UIPanGestureRecognizer, force: Bool) {
        guard !automaticallyFitsPrice, let baseline = priceViewportBaseline,
              let plot = baseRenderState?.staticScene.crosshairData?.panelLayout.pricePanel?.plot,
              let scale = baseRenderState?.staticScene.crosshairData?.displayScale,
              scale > 0 else { return }
        publishPriceViewport(baseline.panned(
            verticalTranslationPoints: Double(recognizer.translation(in: self).y),
            plotHeightPoints: Double(plot.height) / Double(scale)
        ), force: force)
    }

    @objc
    private func handleTimelinePinch(
        _ recognizer: UIPinchGestureRecognizer
    ) {
        switch recognizer.state {
        case .began:
            guard interactionState.canBeginPinch, let timelineViewport else {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
                return
            }
            if currentCrosshair != nil || interactionState.state == .trackingCrosshair {
                dismissCrosshair()
                // A second finger takes over the creating contact. Its late
                // long-press callbacks must not end the pinch that follows.
                crosshairGesture.isEnabled = false
                crosshairGesture.isEnabled = true
            }
            guard interactionState.beginPinch() else { return }
            gestureViewportBaseline = timelineViewport
            if interactionBaseline == nil {
                interactionBaseline = timelineViewport
                interactionBaseStaticRevision =
                    baseRenderState?.staticScene.revision
            }
            timelineMotion.cancel()
            boundaryTranslationPoints = 0
            lastInteractionFrameTimestamp = nil
            pendingGuardBandRebase = nil
            committedViewportAwaitingRender = nil
            let plotWidth = interactionMetrics.plotWidth(
                totalWidthPoints: Double(bounds.width)
            )
            let locationX = Double(recognizer.location(in: self).x)
            pinchAnchorFraction = min(
                1,
                max(
                    0,
                    (locationX
                        - interactionMetrics.plotLeadingInsetPoints)
                        / plotWidth
                )
            )
            if !automaticallyFitsPrice, priceViewport.fixedRange != nil,
               let data = baseRenderState?.staticScene.crosshairData,
               let plot = data.panelLayout.pricePanel?.plot {
                priceViewportBaseline = priceViewport
                pricePinchAnchorFraction = (Double(recognizer.location(in: self).y)
                    * Double(data.displayScale) - Double(plot.top)) / Double(plot.height)
            }
            startInteractionFrames()
        case .changed:
            guard interactionState.state == .pinchingTimeline,
                  let baseline = gestureViewportBaseline else {
                return
            }
            boundaryTranslationPoints = 0
            if let priceBaseline = priceViewportBaseline, !automaticallyFitsPrice {
                publishPriceViewport(priceBaseline.pinched(
                    scale: Double(recognizer.scale), anchorFraction: pricePinchAnchorFraction
                ), force: false)
            }
            updateInteractiveTimelineViewport(
                baseline.pinched(
                    scale: Double(recognizer.scale),
                    anchorFraction: pinchAnchorFraction,
                    totalSlotCount: totalSlotCount,
                    metrics: interactionMetrics
                )
            )
        case .ended, .cancelled, .failed:
            priceViewportBaseline = nil
            lastPublishedPriceViewport = nil
            finishGestureWithoutMotion()
        default:
            break
        }
    }

    @objc
    private func handleCrosshairTap(
        _ recognizer: UITapGestureRecognizer
    ) {
        guard recognizer.state == .ended else {
            return
        }
        let location = recognizer.location(in: self)
        if currentCrosshair == nil,
           isLatestPriceReturnHit(location) {
            returnToLatestViewport()
            return
        }
        if currentCrosshair != nil {
            dismissCrosshair()
            return
        }
        guard interactionState.beginCrosshair(),
              prepareCrosshairInteraction() else {
            resetCrosshairWithoutSubmitting()
            return
        }
        crosshairFeedback.prepare()
        guard updateCrosshair(
            location: location,
            preferredOpenTime: nil,
            preferredPanelID: nil,
            clampsToPlot: false,
            producesFeedback: true
        ) else {
            dismissCrosshair()
            return
        }
        interactionState.finishInteraction()
        gestureViewportBaseline = nil
        stopInteractionFrames()
        submitInteractiveFrame()
    }

    private func isPriceScaleAxisLocation(
        _ location: CGPoint
    ) -> Bool {
        guard let data = baseRenderState?
                .staticScene.crosshairData,
              let pricePanel = data.panelLayout.pricePanel else {
            return false
        }
        let scale = CGFloat(data.displayScale)
        guard scale > 0 else {
            return false
        }
        let x = location.x * scale
        let y = location.y * scale
        return x >= CGFloat(data.panelLayout.plotRight)
            && x <= CGFloat(data.widthPixels)
            && y >= CGFloat(pricePanel.plot.top)
            && y <= CGFloat(pricePanel.plot.bottom)
    }

    private func isManualPricePlotLocation(_ location: CGPoint) -> Bool {
        guard Double(location.x) > interactionMetrics.systemNavigationEdgeWidthPoints,
              let data = baseRenderState?.staticScene.crosshairData,
              let plot = data.panelLayout.pricePanel?.plot else { return false }
        let x = Double(location.x) * Double(data.displayScale)
        let y = Double(location.y) * Double(data.displayScale)
        return x >= Double(plot.left) && x < Double(plot.right)
            && y >= Double(plot.top) && y <= Double(plot.bottom)
    }

    private func isLatestPriceReturnHit(
        _ location: CGPoint
    ) -> Bool {
        guard let marker = baseRenderState?
                .liveTail.latestPriceMarker,
              marker.returnsToLatest else {
            return false
        }
        let scale = Float(
            baseRenderState?.staticScene.crosshairData?
                .displayScale
                ?? Float(metalView.contentScaleFactor)
        )
        return marker.contains(
            x: Float(location.x) * scale,
            y: Float(location.y) * scale,
            padding: 4 * scale
        )
    }

    private func returnToLatestViewport() {
        guard totalSlotCount > 0 else {
            return
        }
        let latest = ChartTimelineViewport.latest(
            totalWidthPoints: Double(bounds.width)
        ).clamped(
            totalSlotCount: totalSlotCount,
            metrics: interactionMetrics
        )
        publishTimelineViewport(latest)
    }

    @objc
    private func handleCrosshair(
        _ recognizer: UILongPressGestureRecognizer
    ) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            guard interactionState.beginCrosshair(),
                  prepareCrosshairInteraction() else {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
                return
            }
            crosshairFeedback.prepare()
            guard updateCrosshair(
                location: location,
                preferredOpenTime: nil,
                preferredPanelID: nil,
                clampsToPlot: false,
                producesFeedback: true
            ) else {
                finishCrosshairInteraction()
                return
            }
            startInteractionFrames()
            submitInteractiveFrame()
        case .changed:
            guard interactionState.state
                    == .trackingCrosshair else {
                return
            }
            if updateCrosshair(
                location: location,
                preferredOpenTime: nil,
                preferredPanelID:
                    currentCrosshair?.hit.selection.panelID,
                clampsToPlot: true,
                producesFeedback: true
            ) {
                submitInteractiveFrame()
            }
        case .ended, .cancelled, .failed:
            guard interactionState.state == .trackingCrosshair else { return }
            finishCrosshairInteraction()
        default:
            break
        }
    }

    private func prepareCrosshairInteraction() -> Bool {
        guard let timelineViewport else {
            return false
        }
        gestureViewportBaseline = timelineViewport
        if interactionBaseline == nil {
            interactionBaseline = timelineViewport
            interactionBaseStaticRevision =
                baseRenderState?.staticScene.revision
        }
        timelineMotion.cancel()
        boundaryTranslationPoints = 0
        lastInteractionFrameTimestamp = nil
        pendingGuardBandRebase = nil
        committedViewportAwaitingRender = nil
        return true
    }

    private func publishTimelineViewport(
        _ viewport: ChartTimelineViewport
    ) {
        guard !isDisposed,
              let currentViewport = timelineViewport else {
            return
        }
        timelineMotion.cancel()
        boundaryTranslationPoints = 0
        lastInteractionFrameTimestamp = nil
        timelineViewport = viewport
        updateTimelineAccessibilityState()
        guard viewport != currentViewport else {
            onTimelineViewportChange?(viewport)
            return
        }
        if interactionBaseline == nil {
            interactionBaseline = currentViewport
            interactionBaseStaticRevision =
                baseRenderState?.staticScene.revision
        }
        committedViewportAwaitingRender = viewport
        submitInteractiveFrame()
        stopInteractionFrames()
        onTimelineViewportChange?(viewport)
    }

    private func updateInteractiveTimelineViewport(
        _ viewport: ChartTimelineViewport
    ) {
        guard !isDisposed,
              interactionBaseline != nil else {
            return
        }
        timelineViewport = viewport
        updateTimelineAccessibilityState()
        submitInteractiveFrame()
    }

    private func submitInteractiveFrame() {
        guard let state = baseRenderState,
              let baseline = interactionBaseline,
              let current = timelineViewport else {
            return
        }
        let displayScale = Double(
            metalView.contentScaleFactor
        )
        let transform = ChartTimelineInteractionTransform.mapping(
            from: baseline,
            to: current,
            totalWidthPoints: Double(bounds.width),
            displayScale: displayScale,
            metrics: interactionMetrics
        )
        interactionRevision = max(
            interactionRevision,
            state.revision
        )
        interactionRevision &+= 1
        // Keep the fixed-axis price overlay throughout a gesture and scene rebase.
        let liveTail = state.liveTail
        updateCandleMarkers()
        frameCoordinator?.submit(RenderState(
            staticScene: state.staticScene,
            liveTail: liveTail,
            interaction: InteractionSnapshot(
                revision: interactionRevision,
                translationX: transform.translationPixels
                    + boundaryTranslationPoints * displayScale,
                scaleX: transform.scaleX,
                candleHalfBodyWidthPixels:
                    interactionMetrics.candleHalfBodyWidthPixels(
                        visibleSlotCount:
                            current.visibleSlotCount,
                        totalWidthPoints: Double(bounds.width),
                        displayScale: displayScale
                    ),
                candleHalfWickWidthPixels:
                    interactionMetrics.candleHalfWickWidthPixels(
                        displayScale: displayScale
                    ),
                crosshair: currentCrosshair
                    ?? state.interaction.crosshair
            ),
            invalidation: .interaction,
            appearance: appearance,
            axisPriceLabels: state.axisPriceLabels,
            presentationID: state.presentationID,
            readyTime: state.readyTime
        ))
    }

    private func resolveRebasedSceneIfNeeded(
        _ state: RenderState
    ) -> Bool {
        let priorRevision = interactionBaseStaticRevision
        guard let target = pendingGuardBandRebase
                ?? committedViewportAwaitingRender
                ?? pendingContinuousViewport,
              priorRevision != state.staticScene.revision else {
            return false
        }
        let isContinuousUpdate = (interactionState.state != .idle
                || timelineMotion.isActive)
            && committedViewportAwaitingRender == nil
            && (pendingContinuousViewport != nil
                || pendingGuardBandRebase != nil)
        let wasWaitingForGuardBand = pendingGuardBandRebase != nil
        let renderedViewport = (
            state.staticScene.timelineViewport ?? target
        ).clamped(
            totalSlotCount: totalSlotCount,
            metrics: interactionMetrics
        )
        let currentViewport = (
            timelineViewport ?? target
        ).clamped(
            totalSlotCount: totalSlotCount,
            metrics: interactionMetrics
        )
        timelineViewport = currentViewport
        updateTimelineAccessibilityState()
        interactionBaseline = renderedViewport
        interactionBaseStaticRevision = state.staticScene.revision
        pendingContinuousViewport = nil
        if isContinuousUpdate {
            // Rebase drawing only. The recognizer's cumulative translation,
            // pinch anchor and inertia clock still describe the same gesture.
            pendingGuardBandRebase = nil
            if wasWaitingForGuardBand, timelineMotion.isActive {
                lastInteractionFrameTimestamp = nil
                startInteractionFrames()
            }
            submitInteractiveFrame()
            return true
        }
        let shouldResumeMotion = timelineMotion.isActive
        boundaryTranslationPoints = 0
        lastInteractionFrameTimestamp = nil
        pendingGuardBandRebase = nil
        committedViewportAwaitingRender = nil
        timelinePanGesture.setTranslation(.zero, in: self)
        timelinePinchGesture.scale = 1
        gestureViewportBaseline = currentViewport
        if interactionState.state == .idle,
           !shouldResumeMotion {
            if currentViewport == renderedViewport {
                interactionBaseline = nil
                gestureViewportBaseline = nil
                interactionBaseStaticRevision = nil
                frameCoordinator?.submit(state)
            } else {
                committedViewportAwaitingRender = currentViewport
                submitInteractiveFrame()
                onTimelineViewportChange?(currentViewport)
            }
            stopInteractionFrames()
            return true
        }

        submitInteractiveFrame()
        if !currentViewport.isRenderable(
            from: renderedViewport,
            guardBandSlotCount:
                interactionMetrics.guardBandSlotCount
        ) {
            pendingGuardBandRebase = currentViewport
            onTimelineViewportChange?(currentViewport)
            if shouldResumeMotion {
                stopInteractionFrames()
            }
        } else if shouldResumeMotion {
            startInteractionFrames()
        }
        return true
    }

    private func interactionFrameDidFire(
        _ timestamp: CFTimeInterval
    ) {
        defer { publishContinuousViewportIfNeeded() }
        guard timelineMotion.isActive,
              pendingGuardBandRebase == nil,
              let timelineViewport else {
            return
        }
        guard let previousTimestamp =
                lastInteractionFrameTimestamp else {
            lastInteractionFrameTimestamp = timestamp
            return
        }
        lastInteractionFrameTimestamp = timestamp
        let step = timelineMotion.advance(
            from: timelineViewport,
            deltaTimeSeconds: timestamp - previousTimestamp,
            plotWidthPoints: interactionMetrics.plotWidth(
                totalWidthPoints: Double(bounds.width)
            ),
            totalSlotCount: totalSlotCount,
            interactionMetrics: interactionMetrics,
            motionMetrics: motionMetrics
        )
        boundaryTranslationPoints =
            step.boundaryTranslationPoints
        updateInteractiveTimelineViewport(step.viewport)
        if pendingGuardBandRebase != nil {
            lastInteractionFrameTimestamp = nil
            stopInteractionFrames()
            return
        }
        if step.isFinished {
            settleInteractionViewport()
        }
    }

    private func publishContinuousViewportIfNeeded() {
        guard !isDisposed,
              interactionState.state == .panningTimeline
                || interactionState.state == .pinchingTimeline
                || timelineMotion.isActive,
              pendingContinuousViewport == nil,
              pendingGuardBandRebase == nil,
              committedViewportAwaitingRender == nil,
              let viewport = timelineViewport,
              let baseline = interactionBaseline,
              viewport != interactionBaseline else {
            return
        }
        // One in-flight scene; gesture events continue updating the latest
        // viewport and the cheap horizontal Metal transform while it builds.
        if viewport.isRenderable(
            from: baseline,
            guardBandSlotCount: interactionMetrics.guardBandSlotCount
        ) {
            pendingContinuousViewport = viewport
        } else {
            pendingGuardBandRebase = viewport
            if timelineMotion.isActive {
                lastInteractionFrameTimestamp = nil
                stopInteractionFrames()
            }
        }
        onTimelineViewportChange?(viewport)
    }

    private func interruptTimelineMotionForGesture() {
        guard timelineMotion.isActive else {
            return
        }
        timelineMotion.cancel()
        boundaryTranslationPoints = 0
        lastInteractionFrameTimestamp = nil
        submitInteractiveFrame()
        stopInteractionFrames()
    }

    private func resolveCrosshair(
        location: CGPoint,
        preferredOpenTime: Int64?,
        preferredPanelID: String?,
        clampsToPlot: Bool
    ) -> ChartCrosshairHit? {
        guard let data = baseRenderState?
                .staticScene.crosshairData else {
            return nil
        }
        let scale = Double(data.displayScale)
        return ChartCrosshairResolver.resolve(
            screenX: Double(location.x) * scale,
            screenY: Double(location.y) * scale,
            transform: currentTimelineTransform(),
            data: data,
            liveData: baseRenderState?
                .liveTail.crosshairLiveData,
            preferredOpenTime: preferredOpenTime,
            preferredPanelID: preferredPanelID,
            clampsToPlot: clampsToPlot
        )
    }

    private func updateTimelineAccessibilityState() {
        isAccessibilityElement = true
        accessibilityLabel = "K线图"
        let position = timelineViewport?.followsLatest == true
            ? "最新"
            : "历史"
        let indicators = baseRenderState?.liveTail.displayedLegends
            .compactMap { entry -> String? in
                guard let value = entry.value, value.isFinite else {
                    return nil
                }
                return "\(entry.label)\(DisplayNumber.text(value))"
            }
            .prefix(16)
            .joined(separator: "，") ?? ""
        accessibilityValue = indicators.isEmpty
            ? position
            : "\(position)；\(indicators)"
    }

    @discardableResult
    private func updateCrosshair(
        location: CGPoint,
        preferredOpenTime: Int64?,
        preferredPanelID: String?,
        clampsToPlot: Bool,
        producesFeedback: Bool
    ) -> Bool {
        guard let data = baseRenderState?
                .staticScene.crosshairData,
              let hit = resolveCrosshair(
                location: location,
                preferredOpenTime: preferredOpenTime,
                preferredPanelID: preferredPanelID,
                clampsToPlot: clampsToPlot
              ) else {
            return false
        }
        let priorOpenTime = currentCrosshair?
            .hit.selection.openTime
        currentCrosshair = crosshairOverlayBuilder.makeSnapshot(
            hit: hit,
            data: data,
            latestPrice: baseRenderState?.liveTail.latestPrice
                ?? baseRenderState?.liveTail
                    .crosshairLiveData?.candle?.closePrice
        )
        crosshairLocationPixels = ChartPolylinePoint(
            x: Float(Double(location.x) * Double(data.displayScale)),
            y: Float(Double(location.y) * Double(data.displayScale))
        )
        let selection = hit.selection
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentCrosshair?.hit.selection == selection else { return }
            self.onCrosshairSelection?(selection)
        }
        if producesFeedback,
           priorOpenTime != hit.selection.openTime {
            crosshairFeedback.impactOccurred(intensity: 0.55)
            crosshairFeedback.prepare()
        }
        return true
    }

    @discardableResult
    private func updateCrosshair(
        locationPixels: ChartPolylinePoint,
        preferredOpenTime: Int64?,
        preferredPanelID: String?,
        clampsToPlot: Bool,
        producesFeedback: Bool
    ) -> Bool {
        guard let data = baseRenderState?
                .staticScene.crosshairData else {
            return false
        }
        return updateCrosshair(
            location: CGPoint(
                x: Double(locationPixels.x)
                    / Double(data.displayScale),
                y: Double(locationPixels.y)
                    / Double(data.displayScale)
            ),
            preferredOpenTime: preferredOpenTime,
            preferredPanelID: preferredPanelID,
            clampsToPlot: clampsToPlot,
            producesFeedback: producesFeedback
        )
    }

    private func currentTimelineTransform()
        -> ChartTimelineInteractionTransform {
        guard let baseline = interactionBaseline,
              let current = timelineViewport else {
            return .identity
        }
        return ChartTimelineInteractionTransform.mapping(
            from: baseline,
            to: current,
            totalWidthPoints: Double(bounds.width),
            displayScale: Double(
                baseRenderState?.staticScene.crosshairData?
                    .displayScale
                    ?? Float(metalView.contentScaleFactor)
            ),
            metrics: interactionMetrics
        )
    }

    private func finishCrosshairInteraction() {
        guard currentCrosshair != nil else {
            dismissCrosshair()
            return
        }
        interactionState.finishInteraction()
        gestureViewportBaseline = nil
        timelineMotion.cancel()
        boundaryTranslationPoints = 0
        lastInteractionFrameTimestamp = nil
        stopInteractionFrames()
        submitInteractiveFrame()
    }

    private func dismissCrosshair() {
        interactionState.finishInteraction()
        currentCrosshair = nil
        crosshairLocationPixels = nil
        gestureViewportBaseline = nil
        timelineMotion.cancel()
        boundaryTranslationPoints = 0
        lastInteractionFrameTimestamp = nil
        pendingGuardBandRebase = nil
        committedViewportAwaitingRender = nil
        if interactionBaseline != nil {
            submitInteractiveFrame()
        }
        stopInteractionFrames()
        interactionBaseline = nil
        interactionBaseStaticRevision = nil
    }

    private func resetCrosshairWithoutSubmitting() {
        crosshairGesture.isEnabled = false
        crosshairGesture.isEnabled = true
        interactionState.finishInteraction()
        currentCrosshair = nil
        crosshairLocationPixels = nil
        gestureViewportBaseline = nil
        interactionBaseline = nil
        interactionBaseStaticRevision = nil
        stopInteractionFrames()
    }

    private func finishPanInteraction(
        velocityPointsPerSecond: Double,
        allowsInertia: Bool
    ) {
        interactionState.finishInteraction()
        gestureViewportBaseline = nil
        if pendingGuardBandRebase != nil {
            timelineMotion.cancel()
            lastInteractionFrameTimestamp = nil
            stopInteractionFrames()
            return
        }
        let velocity = allowsInertia
            ? velocityPointsPerSecond
            : 0
        if timelineMotion.begin(
            velocityPointsPerSecond: velocity,
            boundaryTranslationPoints:
                boundaryTranslationPoints,
            metrics: motionMetrics
        ) {
            lastInteractionFrameTimestamp = nil
            startInteractionFrames()
            return
        }
        boundaryTranslationPoints = 0
        submitInteractiveFrame()
        settleInteractionViewport()
    }

    private func finishGestureWithoutMotion() {
        interactionState.finishInteraction()
        gestureViewportBaseline = nil
        timelineMotion.cancel()
        boundaryTranslationPoints = 0
        lastInteractionFrameTimestamp = nil
        submitInteractiveFrame()
        settleInteractionViewport()
    }

    private func settleInteractionViewport() {
        let committedViewport = timelineViewport
        let baseline = interactionBaseline
        // An intermediate scene can still arrive after the fingers return
        // to the drawing baseline. Always supersede that request on finish.
        let hasPendingScene = pendingContinuousViewport != nil
            || pendingGuardBandRebase != nil
        timelineMotion.cancel()
        boundaryTranslationPoints = 0
        lastInteractionFrameTimestamp = nil
        gestureViewportBaseline = nil
        pendingContinuousViewport = nil
        stopInteractionFrames()
        if let committedViewport,
           committedViewport != baseline || hasPendingScene {
            committedViewportAwaitingRender = committedViewport
            onTimelineViewportChange?(committedViewport)
        } else {
            interactionBaseline = nil
            interactionBaseStaticRevision = nil
            pendingGuardBandRebase = nil
            committedViewportAwaitingRender = nil
        }
    }

    private func cancelActiveInteraction(
        publishViewport: Bool
    ) {
        guard interactionState.state != .idle
                || isPriceScaleGestureActive
                || timelineMotion.isActive
                || interactionBaseline != nil
                || pendingGuardBandRebase != nil
                || committedViewportAwaitingRender != nil
                || currentCrosshair != nil else {
            return
        }
        let hasPendingContinuousScene = pendingContinuousViewport != nil
        if interactionState.state != .idle
            || isPriceScaleGestureActive {
            priceScalePanGesture.isEnabled = false
            timelinePanGesture.isEnabled = false
            timelinePinchGesture.isEnabled = false
            crosshairGesture.isEnabled = false
            crosshairTapGesture.isEnabled = false
            priceScalePanGesture.isEnabled = true
            timelinePanGesture.isEnabled = true
            timelinePinchGesture.isEnabled = true
            crosshairGesture.isEnabled = true
            crosshairTapGesture.isEnabled = true
        }
        interactionState.finishInteraction()
        isPriceScaleGestureActive = false
        pendingContinuousViewport = nil
        priceViewportBaseline = nil
        lastPublishedPriceViewport = nil
        currentCrosshair = nil
        crosshairLocationPixels = nil
        gestureViewportBaseline = nil
        timelineMotion.cancel()
        boundaryTranslationPoints = 0
        lastInteractionFrameTimestamp = nil
        submitInteractiveFrame()
        stopInteractionFrames()
        guard publishViewport else {
            interactionBaseline = nil
            interactionBaseStaticRevision = nil
            pendingGuardBandRebase = nil
            committedViewportAwaitingRender = nil
            return
        }
        if pendingGuardBandRebase != nil
            || committedViewportAwaitingRender != nil {
            return
        }
        if let timelineViewport,
           timelineViewport != interactionBaseline
                || hasPendingContinuousScene {
            committedViewportAwaitingRender = timelineViewport
            onTimelineViewportChange?(timelineViewport)
        } else {
            interactionBaseline = nil
            interactionBaseStaticRevision = nil
        }
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        bringSubviewToFront(errorLabel)
    }

    private func rendererDidStop(_ message: String) {
        cancelActiveInteraction(publishViewport: true)
        showError(message)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        let coordinator = frameCoordinator
        Task { @MainActor in
            coordinator?.dispose()
        }
    }
}

extension KlineChartHostView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer:
            UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer === timelinePinchGesture && otherGestureRecognizer === crosshairGesture)
            || (gestureRecognizer === crosshairGesture && otherGestureRecognizer === timelinePinchGesture)
    }
}
