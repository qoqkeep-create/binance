import SwiftUI

enum AppTab: Hashable, CaseIterable, Identifiable {
    case markets
    case positions
    case trade
    case signals
    case reference
    case settings

    var id: Self { self }

    static func availableTabs(
        canViewReferenceNotifications: Bool
    ) -> [AppTab] {
        return [.markets, .positions, .trade, .signals, .settings]
    }

    var title: String {
        switch self {
        case .markets:
            return "行情"
        case .positions:
            return "持仓"
        case .signals:
            return "信号"
        case .reference:
            return "参考"
        case .trade:
            return "开仓"
        case .settings:
            return "我的"
        }
    }

    var icon: String {
        switch self {
        case .markets:
            return "chart.xyaxis.line"
        case .positions:
            return "briefcase"
        case .signals:
            return "bell"
        case .reference:
            return "bookmark"
        case .trade:
            return "plus.circle"
        case .settings:
            return "person.crop.circle"
        }
    }

    var selectedIcon: String {
        switch self {
        case .markets:
            return "chart.xyaxis.line"
        case .positions:
            return "briefcase.fill"
        case .signals:
            return "bell.fill"
        case .reference:
            return "bookmark.fill"
        case .trade:
            return "plus.circle.fill"
        case .settings:
            return "person.crop.circle.fill"
        }
    }
}

struct BottomNavigationBar: View {
    @Binding var selection: AppTab
    let tabs: [AppTab]
    @ScaledMetric(relativeTo: .caption2) private var labelSize = 10.0

    init(
        selection: Binding<AppTab>,
        tabs: [AppTab] = AppTab.allCases
    ) {
        _selection = selection
        self.tabs = tabs
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                navigationButton(for: tab)
            }
        }
        .padding(.horizontal, 8)
        .padding(
            .top,
            BinanceTheme.Layout.bottomNavigationTopPadding
        )
        .padding(
            .bottom,
            BinanceTheme.Layout.bottomNavigationBottomPadding
        )
        .background {
            BinanceTheme.navigationBackground
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BinanceTheme.navigationBorder)
                .frame(
                    height:
                        BinanceTheme.Layout.bottomNavigationBorderHeight
                )
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func navigationButton(for tab: AppTab) -> some View {
        let isSelected = selection == tab

        return Button {
            guard selection != tab else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selection = tab
            }
        } label: {
            VStack(
                spacing: BinanceTheme.Layout.bottomNavigationItemSpacing
            ) {
                Image(
                    systemName: isSelected
                        ? tab.selectedIcon
                        : tab.icon
                )
                .font(
                    .system(
                        size:
                            BinanceTheme.Layout.bottomNavigationIconSize,
                        weight: .medium
                    )
                )
                .symbolEffectsRemoved()
                .contentTransition(.identity)
                .frame(
                    height:
                        BinanceTheme.Layout.bottomNavigationIconFrameHeight
                )

                Text(tab.title)
                    .font(
                        .system(
                            size: labelSize,
                            weight: isSelected ? .semibold : .medium
                        )
                    )
            }
            .foregroundStyle(
                isSelected
                    ? BinanceTheme.selectedNavigationText
                    : BinanceTheme.unselectedNavigationText
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: BinanceTheme.Layout.bottomNavigationButtonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    VStack(spacing: 0) {
        Spacer()
        BottomNavigationBar(selection: .constant(.markets))
    }
    .background(BinanceTheme.background)
    .preferredColorScheme(.dark)
}
