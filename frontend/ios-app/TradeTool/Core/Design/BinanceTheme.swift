import SwiftUI
import UIKit

extension AppAppearance {
    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }
}

enum BinanceTheme {
    static let background = adaptive(light: 0xFFFFFF, dark: 0x212731)
    static let marketBackground = background
    static let navigationBackground = background
    static let navigationBorder = adaptive(light: 0xEAECEF, dark: 0x333B47)
    static let surface = adaptive(light: 0xFAFAFA, dark: 0x272F3A)
    static let elevated = adaptive(light: 0xF5F5F5, dark: 0x2B3441)
    static let border = navigationBorder
    static let primaryText = adaptive(light: 0x181A20, dark: 0xEAECEF)
    static let secondaryText = adaptive(light: 0x667080, dark: 0x848E9C)
    static let accent = Color(hex: 0xFCD535)
    static let accentPressed = Color(hex: 0xE8C527)
    static let accentText = adaptive(light: 0x8D6E00, dark: 0xFCD535)
    static let onAccent = Color(hex: 0x181A20)
    static let onColor = adaptive(light: 0xFFFFFF, dark: 0x181A20)
    static let onTradeAction = Color.white
    static let positive = adaptive(light: 0x08805E, dark: 0x0ECB81)
    static let negative = adaptive(light: 0xD92D4C, dark: 0xFF4D67)
    static let positiveFill = Color(hex: 0x32BD82)
    static let negativeFill = Color(hex: 0xF6485E)
    static let selectedNavigationText = adaptive(light: 0x010101, dark: 0xF0B90B)
    static let unselectedNavigationText = adaptive(light: 0x767676, dark: 0x929AA5)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    enum Layout {
        static let pageHorizontalPadding: CGFloat = 16
        static let compactSearchFieldHeight: CGFloat = 46
        static let compactSearchTapHeight: CGFloat = 48
        static let compactSearchCornerRadius: CGFloat = 8
        static let marketRowHeight: CGFloat = 60
        static let marketSearchRowHeight: CGFloat = 60
        static let marketChangeHeight: CGFloat = 30
        static let minimumTapSize: CGFloat = 44
        static let controlHeight: CGFloat = 48
        static let settingsRowHeight: CGFloat = 56
        static let sectionSpacing: CGFloat = 24
        static let itemSpacing: CGFloat = 12
        static let cardCornerRadius: CGFloat = 12
        static let bottomNavigationButtonHeight: CGFloat = 48
        static let bottomNavigationTopPadding: CGFloat = 7
        static let bottomNavigationBottomPadding: CGFloat = 5
        static let bottomNavigationBorderHeight: CGFloat = 0.5
        static let bottomNavigationIconSize: CGFloat = 22
        static let bottomNavigationIconFrameHeight: CGFloat = 24
        static let bottomNavigationItemSpacing: CGFloat = 3
    }

    enum Typography {
        static func text(
            _ style: Font.TextStyle,
            weight: Font.Weight = .regular
        ) -> Font {
            .system(style, design: .default)
                .weight(weight)
        }

        static func number(
            _ style: Font.TextStyle,
            weight: Font.Weight = .regular
        ) -> Font {
            .system(style, design: .default)
                .weight(weight)
                .monospacedDigit()
        }

        static let rootTitle = text(.title2, weight: .semibold)
        static let modalTitle = text(.headline, weight: .semibold)
        static let selectedTab = text(.subheadline, weight: .semibold)
        static let tab = text(.subheadline, weight: .semibold)
        static let tableHeader = text(.caption2)
        static let sectionHeader = text(.caption, weight: .semibold)
        static let listSymbol = text(.subheadline, weight: .semibold)
        static let marketSymbol = listSymbol
        static let marketQuoteAsset = text(.caption)
        static let marketDetail = text(.caption2)
        static let smallLabel = text(.caption2, weight: .medium)
        static let marketPrice = number(.footnote, weight: .medium)
        static let marketPriceSecondary = number(.caption2)
        static let marketChange = number(.caption, weight: .semibold)
        static let marketSearchChange = number(.caption2, weight: .medium)
        static let settingsRowTitle = text(.body, weight: .medium)
        static let rowTitle = text(.body, weight: .medium)
        static let body = text(.subheadline)
        static let caption = text(.caption)
        static let balance = number(.largeTitle, weight: .semibold)
    }
}

struct BinancePanelModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                BinanceTheme.surface,
                in: RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .stroke(BinanceTheme.border.opacity(0.75), lineWidth: 1)
            }
    }
}

struct BinancePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BinanceTheme.Typography.text(.body, weight: .semibold))
            .foregroundStyle(BinanceTheme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .frame(minHeight: BinanceTheme.Layout.controlHeight)
            .background(
                configuration.isPressed
                    ? BinanceTheme.accentPressed
                    : BinanceTheme.accent,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(
                .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

struct BinanceInputModifier: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .font(BinanceTheme.Typography.text(.body))
            .foregroundStyle(BinanceTheme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: BinanceTheme.Layout.controlHeight)
            .background(
                BinanceTheme.elevated,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isFocused
                            ? BinanceTheme.accent
                            : BinanceTheme.border,
                        lineWidth: isFocused ? 1.5 : 1
                    )
            }
    }
}

struct BinanceLogoMark: View {
    var size: CGFloat = 44

    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct BinanceBackButton: View {
    @Environment(\.dismiss) private var dismiss

    private let action: (() -> Void)?

    init(action: (() -> Void)? = nil) {
        self.action = action
    }

    var body: some View {
        Button {
            if let action {
                action()
            } else {
                dismiss()
            }
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BinanceTheme.primaryText)
                .frame(
                    width: BinanceTheme.Layout.minimumTapSize,
                    height: BinanceTheme.Layout.minimumTapSize
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回")
    }
}

struct BinanceNavigationHeader: View {
    let title: String
    var showsBackButton = true

    var body: some View {
        ZStack {
            Text(title)
                .font(BinanceTheme.Typography.modalTitle)
                .foregroundStyle(BinanceTheme.primaryText)

            HStack {
                if showsBackButton {
                    BinanceBackButton()
                }
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 52)
    }
}

extension View {
    func binancePanel(cornerRadius: CGFloat = BinanceTheme.Layout.cardCornerRadius) -> some View {
        modifier(BinancePanelModifier(cornerRadius: cornerRadius))
    }

    func binanceInput(isFocused: Bool) -> some View {
        modifier(BinanceInputModifier(isFocused: isFocused))
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
