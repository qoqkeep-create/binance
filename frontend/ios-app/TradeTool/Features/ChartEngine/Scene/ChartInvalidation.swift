struct ChartInvalidation: OptionSet, Sendable {
    let rawValue: UInt16

    static let data = ChartInvalidation(rawValue: 1 << 0)
    static let indicators = ChartInvalidation(rawValue: 1 << 1)
    static let geometry = ChartInvalidation(rawValue: 1 << 2)
    static let axes = ChartInvalidation(rawValue: 1 << 3)
    static let layout = ChartInvalidation(rawValue: 1 << 4)
    static let annotations = ChartInvalidation(rawValue: 1 << 5)
    static let interaction = ChartInvalidation(rawValue: 1 << 6)
    static let textAndAccessibility = ChartInvalidation(
        rawValue: 1 << 7
    )

    static let full: ChartInvalidation = [
        .data,
        .indicators,
        .geometry,
        .axes,
        .layout,
        .annotations,
        .interaction,
        .textAndAccessibility,
    ]
}
