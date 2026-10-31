import Foundation

struct RelativeChartCoordinateSpace: Equatable, Sendable {
    let timeOrigin: Int64
    let priceOrigin: Double
    let intervalMilliseconds: Int64
    let pixelsPerSlot: Double
    let pixelsPerPriceUnit: Double

    init?(
        timeOrigin: Int64,
        priceOrigin: Double,
        intervalMilliseconds: Int64,
        pixelsPerSlot: Double,
        pixelsPerPriceUnit: Double
    ) {
        guard intervalMilliseconds > 0,
              priceOrigin.isFinite,
              pixelsPerSlot.isFinite,
              pixelsPerSlot > 0,
              pixelsPerPriceUnit.isFinite,
              pixelsPerPriceUnit != 0 else {
            return nil
        }
        self.timeOrigin = timeOrigin
        self.priceOrigin = priceOrigin
        self.intervalMilliseconds = intervalMilliseconds
        self.pixelsPerSlot = pixelsPerSlot
        self.pixelsPerPriceUnit = pixelsPerPriceUnit
    }

    func screenX(openTime: Int64) -> Float? {
        let (delta, overflow) = openTime.subtractingReportingOverflow(
            timeOrigin
        )
        guard !overflow else {
            return nil
        }
        let slots = Double(delta) / Double(intervalMilliseconds)
        let pixels = slots * pixelsPerSlot
        guard pixels.isFinite,
              abs(pixels) <= Double(Float.greatestFiniteMagnitude) else {
            return nil
        }
        return Float(pixels)
    }

    func screenY(price: Double) -> Float? {
        let pixels = (price - priceOrigin) * pixelsPerPriceUnit
        guard pixels.isFinite,
              abs(pixels) <= Double(Float.greatestFiniteMagnitude) else {
            return nil
        }
        return Float(pixels)
    }

    func openTime(screenX: Float) -> Int64? {
        guard screenX.isFinite else {
            return nil
        }
        let offset = Double(screenX)
            / pixelsPerSlot
            * Double(intervalMilliseconds)
        guard offset.isFinite,
              offset >= Double(Int64.min),
              offset <= Double(Int64.max) else {
            return nil
        }
        let roundedOffset = Int64(offset.rounded())
        let (time, overflow) = timeOrigin.addingReportingOverflow(
            roundedOffset
        )
        return overflow ? nil : time
    }

    func price(screenY: Float) -> Double? {
        guard screenY.isFinite else {
            return nil
        }
        let value = priceOrigin
            + Double(screenY) / pixelsPerPriceUnit
        return value.isFinite ? value : nil
    }
}
