import SwiftUI

struct KlineChartRepresentable: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let renderState: RenderState
    let timelineViewport: ChartTimelineViewport
    let priceViewport: ChartPriceViewport
    let totalSlotCount: Int
    let onTimelineViewportChange: (ChartTimelineViewport) -> Void
    let onPriceViewportChange: (ChartPriceViewport) -> Void
    var automaticallyFitsPrice = true
    var onFirstFramePresented: (TimeInterval) -> Void = { _ in }
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
        view.observeFirstPresentation(onFirstFramePresented)
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
        view.submit(renderState)
    }

    static func dismantleUIView(
        _ view: KlineChartHostView,
        coordinator: Void
    ) {
        view.dispose()
    }
}
