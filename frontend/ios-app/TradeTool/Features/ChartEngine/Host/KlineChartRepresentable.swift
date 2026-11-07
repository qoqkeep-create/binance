import SwiftUI

struct KlineChartRepresentable: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let renderState: RenderState?
    let timelineViewport: ChartTimelineViewport
    let priceViewport: ChartPriceViewport
    let totalSlotCount: Int
    let onTimelineViewportChange: (ChartTimelineViewport) -> Void
    let onPriceViewportChange: (ChartPriceViewport) -> Void
    var automaticallyFitsPrice = true
    var candleMarkers: [ChartCandleMarker] = []
    var candleMarkerExclusions: [CGRect] = []
    var axisPriceLabels: [ChartAxisPriceLabel] = []
    var presentationID: ChartPresentationID? = nil
    var suppressesLoadingIndicator = false
    var onFirstFramePresented: (ChartPresentationID, TimeInterval) -> Void = { _, _ in }
    var onCrosshairSelection: (ChartCrosshairSelection) -> Void = { _ in }
    var onCrosshairDismiss: () -> Void = {}

    func makeUIView(
        context: Context
    ) -> KlineChartHostView {
        KlineChartHostView(frame: .zero)
    }

    func updateUIView(
        _ view: KlineChartHostView,
        context: Context
    ) {
        view.setAppearance(colorScheme == .light ? .light : .dark)
        view.setLoadingIndicatorSuppressed(suppressesLoadingIndicator)
        view.observeFirstPresentation(for: presentationID, onFirstFramePresented)
        guard let renderState else {
            view.setLoadingPresentation(true)
            return
        }
        view.setCandleMarkers(candleMarkers, exclusions: candleMarkerExclusions)
        view.onCrosshairSelection = onCrosshairSelection
        view.onCrosshairDismiss = onCrosshairDismiss
        view.configureTimelineInteraction(
            viewport: timelineViewport,
            totalSlotCount: totalSlotCount,
            onChange: onTimelineViewportChange
        )
        view.configurePriceInteraction(
            viewport: priceViewport,
            automaticallyFitsPrice: automaticallyFitsPrice,
            onChange: onPriceViewportChange
        )
        view.submit(renderState.withAxisPriceLabels(axisPriceLabels))
        // Install the new mailbox state before drawing is resumed.
        view.setLoadingPresentation(false)
    }

    static func dismantleUIView(
        _ view: KlineChartHostView,
        coordinator: Void
    ) {
        view.dispose()
    }
}
