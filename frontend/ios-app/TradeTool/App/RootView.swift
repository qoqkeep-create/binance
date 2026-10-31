import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var authStore: AuthStore

    var body: some View {
        ZStack {
            switch authStore.state {
            case .restoring:
                AppLaunchView()
            case .signedOut:
                LoginView()
            case .signedIn:
                MainAppView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: stateIdentifier)
        .background(KeyboardDismissGestureInstaller())
        .task {
            if case .restoring = authStore.state {
                await authStore.restore()
            }
        }
    }

    private var stateIdentifier: Int {
        switch authStore.state {
        case .restoring:
            return 0
        case .signedOut:
            return 1
        case .signedIn:
            return 2
        }
    }
}

private struct MainAppView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var store: USDTStore
    @State private var selectedTab: AppTab = .markets
    @State private var isShowingMarketSearch = false
    @State private var isShowingMarketSettings = false
    @State private var selectedMarket: MarketSnapshot?
    @State private var selectedInterval: MarketKlineInterval = .oneHour
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    switch selectedTab {
                    case .markets:
                        DashboardView(viewModel: container.dashboardViewModel,
                            apiClient: container.apiClient, realtimeClient: container.realtimeClient,
                            isShowingMarketSearch: $isShowingMarketSearch,
                            isShowingMarketSettings: $isShowingMarketSettings,
                            selectedMarket: $selectedMarket)
                    case .positions: USDTPositionsView()
                    case .trade: USDTTradeView()
                    case .signals: USDTSignalsView(openChart: openChart)
                    case .settings: USDTProfileView()
                    case .reference: EmptyView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                BottomNavigationBar(selection: $selectedTab, tabs: [.markets, .positions, .trade] + (store.mode == "ordinary" ? [.signals] : []) + [.settings])
            }
            .navigationDestination(item: $selectedMarket) { market in
                MarketChartView(market: market,
                    availableMarkets: container.dashboardViewModel.markets(onlyVisible: true),
                    apiClient: container.apiClient, realtimeClient: container.realtimeClient,
                    initialInterval: selectedInterval)
            }
        }
        .background(BinanceTheme.navigationBackground)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .floatingPositionsOverlay()
        .task {
            guard let userID = container.authStore.session?.user.id else { return }
            await store.begin(userID: userID)
            container.dashboardViewModel.startRealtime(userID: userID)
            container.realtimeClient.subscribe([.tradingAccount, .tradingPosition, .tradingOrder, .tradingFill])
            container.realtimeClient.connect()
        }
        .onChange(of: store.mode) { _, _ in
            if selectedTab == .signals { selectedTab = .markets }
            container.realtimeClient.reconnect()
        }
        .task(id: store.scope) {
            for await event in container.realtimeClient.events(bufferingPolicy: .bufferingNewest(64)) {
                guard !Task.isCancelled else { break }
                store.receive(event)
            }
        }
        .onDisappear {
            store.stopRealtime()
            container.dashboardViewModel.stopRealtime()
            container.realtimeClient.disconnect()
        }
    }
    private func openChart(_ symbol: String, _ interval: String) {
        selectedInterval = MarketKlineInterval(rawValue: interval) ?? .oneHour
        selectedMarket = container.dashboardViewModel.markets(onlyVisible: false).first { $0.symbol == symbol }
            ?? MarketSnapshot(symbol: symbol, quoteAsset: "USDT", price: 0, changePercent24h: 0, updatedAt: .now)
    }
}

private struct KeyboardDismissGestureInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(
        _ uiView: InstallerView,
        context: Context
    ) {
        context.coordinator.install(on: uiView.window)
    }

    static func dismantleUIView(
        _ uiView: InstallerView,
        coordinator: Coordinator
    ) {
        coordinator.uninstall()
    }

    final class InstallerView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.install(on: window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var installedWindow: UIWindow?

        private lazy var tapGesture: UITapGestureRecognizer = {
            let gesture = UITapGestureRecognizer(
                target: self,
                action: #selector(dismissKeyboard)
            )
            gesture.cancelsTouchesInView = false
            gesture.delegate = self
            return gesture
        }()

        private lazy var panGesture: UIPanGestureRecognizer = {
            let gesture = UIPanGestureRecognizer(
                target: self,
                action: #selector(dismissKeyboard)
            )
            gesture.cancelsTouchesInView = false
            gesture.delegate = self
            return gesture
        }()

        func install(on window: UIWindow?) {
            guard let window, installedWindow !== window else {
                return
            }

            uninstall()
            installedWindow = window
            window.addGestureRecognizer(tapGesture)
            window.addGestureRecognizer(panGesture)
        }

        func uninstall() {
            installedWindow?.removeGestureRecognizer(tapGesture)
            installedWindow?.removeGestureRecognizer(panGesture)
            installedWindow = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            !isInsideTextInput(touch.view)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith
                otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc
        private func dismissKeyboard() {
            installedWindow?.endEditing(true)
        }

        private func isInsideTextInput(_ view: UIView?) -> Bool {
            var candidate = view
            while let current = candidate {
                if current is UITextField || current is UITextView {
                    return true
                }
                candidate = current.superview
            }
            return false
        }
    }
}

private extension View {
    func rootPageVisibility(isVisible: Bool) -> some View {
        opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .zIndex(isVisible ? 1 : 0)
    }
}

extension View {
    func interactivePopGestureEnabled() -> some View {
        background {
            InteractivePopGestureInstaller()
                .frame(width: 0, height: 0)
        }
    }
}

@MainActor
private struct InteractivePopGestureInstaller:
    UIViewControllerRepresentable {

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> ResolverViewController {
        let viewController = ResolverViewController()
        viewController.resolveNavigationController = { navigationController in
            context.coordinator.install(on: navigationController)
        }
        return viewController
    }

    func updateUIViewController(
        _ uiViewController: ResolverViewController,
        context: Context
    ) {
        uiViewController.resolveNavigationController = { navigationController in
            context.coordinator.install(on: navigationController)
        }
        uiViewController.resolve()
    }

    static func dismantleUIViewController(
        _ uiViewController: ResolverViewController,
        coordinator: Coordinator
    ) {
        uiViewController.resolveNavigationController = nil
        coordinator.uninstall()
    }

    final class ResolverViewController: UIViewController {
        var resolveNavigationController:
            ((UINavigationController?) -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            resolve()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            resolve()
        }

        func resolve() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                resolveNavigationController?(navigationController)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var navigationController: UINavigationController?
        private weak var originalDelegate: UIGestureRecognizerDelegate?

        func install(on navigationController: UINavigationController?) {
            guard let navigationController,
                  let gesture = navigationController
                    .interactivePopGestureRecognizer else {
                return
            }

            if self.navigationController !== navigationController {
                uninstall()
                self.navigationController = navigationController
                originalDelegate = gesture.delegate
            }

            gesture.delegate = self
            gesture.isEnabled = navigationController.viewControllers.count > 1
        }

        func uninstall() {
            guard let navigationController,
                  let gesture = navigationController
                    .interactivePopGestureRecognizer else {
                self.navigationController = nil
                originalDelegate = nil
                return
            }

            if gesture.delegate === self {
                gesture.delegate = originalDelegate
            }
            gesture.isEnabled = navigationController.viewControllers.count > 1
            self.navigationController = nil
            originalDelegate = nil
        }

        func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let navigationController else {
                return false
            }
            return navigationController.viewControllers.count > 1
                && navigationController.transitionCoordinator == nil
        }
    }
}

private struct AppLaunchView: View {
    var body: some View {
        ZStack {
            BinanceTheme.background
                .ignoresSafeArea()

            VStack(spacing: 18) {
                BinanceLogoMark(size: 58)

                ProgressView()
                    .tint(BinanceTheme.accent)
            }
        }
    }
}

#Preview {
    let runtime = AppRuntime()
    let container = runtime.container

    return RootView()
        .environmentObject(runtime)
        .environmentObject(container)
        .environmentObject(container.authStore)
        .environmentObject(container.usdt)
        .environmentObject(container.toastCenter)
        .environmentObject(container.strategySignalNotifications)
}
