import Foundation

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark

    static let storageKey = "TradeTool.appearance"
    static let defaultValue: AppAppearance = .light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "亮色"
        case .dark: "暗色"
        }
    }

    var icon: String {
        switch self {
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}
