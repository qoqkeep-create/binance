import SwiftUI
import UIKit
import ObjectiveC

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
    @EnvironmentObject private var notifications: StrategySignalNotificationManager
    @State private var selectedTab: AppTab = .markets
    @State private var isShowingMarketSearch = false
    @State private var isShowingMarketSettings = false
    @State private var selectedMarket: MarketSnapshot?
    @State private var selectedInterval: MarketKlineInterval = .oneHour
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RetainedTradingPages(selectedTab: selectedTab, isChartOpen: selectedMarket != nil,
                    openChart: openChart) {
                    switch selectedTab {
                    case .markets:
                        DashboardView(viewModel: container.dashboardViewModel,
                            apiClient: container.apiClient, realtimeClient: container.realtimeClient,
                            isShowingMarketSearch: $isShowingMarketSearch,
                            isShowingMarketSettings: $isShowingMarketSettings,
                            selectedMarket: $selectedMarket)
                    case .positions, .signals: Color.clear
                    case .settings: USDTProfileView()
                    case .reference: EmptyView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                BottomNavigationBar(selection: $selectedTab)
            }
            .interactivePopGestureEnabled()
            .navigationDestination(item: $selectedMarket) { market in
                MarketChartView(market: market,
                    availableMarkets: container.dashboardViewModel.markets(onlyVisible: true),
                    apiClient: container.apiClient, realtimeClient: container.realtimeClient,
                    initialInterval: selectedInterval,
                    onStop: { container.dashboardViewModel.restoreRealtimeSubscriptions() },
                    onShowPositions: {
                        selectedMarket = nil
                        selectedTab = .positions
                    })
            }
        }
        .environmentObject(container.dashboardViewModel)
        .background(BinanceTheme.navigationBackground)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .floatingPositionsOverlay()
        .task {
            guard let userID = container.authStore.session?.user.id else { return }
            notifications.activateSession()
            store.prepareSession(userID: userID)
            container.dashboardViewModel.startRealtime(userID: userID)
            container.realtimeClient.subscribe([.tradingAccount, .tradingPosition, .tradingOrder, .tradingFill])
            container.realtimeClient.connect()
            await store.refresh()
        }
        .onChange(of: notifications.navigationRequest, initial: true) { _, request in
            guard let request else { return }
            switch request.destination {
            case .strategy(let signal): openChart(signal.symbol, signal.interval)
            case .reference: selectedTab = .signals
            }
            notifications.consumeNavigationRequest(request.id)
        }
        .onChange(of: store.selectedSymbol, initial: true) { _, symbol in
            container.dashboardViewModel.trackTradeTickerSymbol(symbol)
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
            notifications.deactivateSession()
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

/// Retain list and scroll state across root tabs while pausing hidden-page work.
struct RetainedTradingPages<Foreground: View>: View {
    let selectedTab: AppTab
    var isChartOpen = false
    let openChart: (String, String) -> Void
    @ViewBuilder let foreground: () -> Foreground
    @State private var hasVisitedPositions = false
    @State private var hasVisitedSignals = false

    var body: some View {
        ZStack {
            foreground()
            if hasVisitedPositions || selectedTab == .positions {
                USDTPositionsView(isVisible: selectedTab == .positions && !isChartOpen,
                    onOpenChart: openChart)
                    .rootPageVisibility(isVisible: selectedTab == .positions)
            }
            if hasVisitedSignals || selectedTab == .signals {
                USDTSignalsView(isVisible: selectedTab == .signals && !isChartOpen,
                    openChart: openChart)
                    .rootPageVisibility(isVisible: selectedTab == .signals)
            }
        }
        .onChange(of: selectedTab, initial: true) { _, tab in
            if tab == .positions { hasVisitedPositions = true }
            if tab == .signals { hasVisitedSignals = true }
        }
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
    func interactivePopGestureEnabled(localBack: (() -> Void)? = nil) -> some View {
        background {
            InteractivePopGestureInstaller(localBack: localBack)
                .frame(width: 0, height: 0)
        }
    }
}

@MainActor
private struct InteractivePopGestureInstaller:
    UIViewControllerRepresentable {
    var localBack: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> ResolverViewController {
        let viewController = ResolverViewController()
        viewController.resolveNavigationController = { navigationController in
            context.coordinator.install(on: navigationController, localBack: localBack)
        }
        return viewController
    }

    func updateUIViewController(
        _ uiViewController: ResolverViewController,
        context: Context
    ) {
        uiViewController.resolveNavigationController = { navigationController in
            context.coordinator.install(on: navigationController, localBack: localBack)
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

    @MainActor final class Coordinator {
        private let id = UUID()
        private weak var controller: WidePopController?
        func install(on navigationController: UINavigationController?, localBack: (() -> Void)?) {
            guard let navigationController else { return }
            let controller = WidePopController.install(on: navigationController)
            self.controller = controller
            controller.setLocalBack(localBack, owner: id)
        }
        func uninstall() { controller?.setLocalBack(nil, owner: id) }
    }
}

/// Public UIKit transition APIs; one recognizer per navigation stack, shared by
/// every page. SwiftUI's original delegate still receives navigation callbacks.
@MainActor
private final class WidePopController: NSObject, UIGestureRecognizerDelegate, UINavigationControllerDelegate {
    private static var associationKey: UInt8 = 0
    private weak var navigation: UINavigationController?
    private weak var forwardedDelegate: UINavigationControllerDelegate?
    private var interaction: UIPercentDrivenInteractiveTransition?
    private let pan = UIPanGestureRecognizer()
    private let animator = PopAnimator()
    private struct LocalBackAction {
        weak var page: UIViewController?
        let action: () -> Void
    }
    private var localActions: [UUID: LocalBackAction] = [:]
    private var localGesture: (() -> Void)?

    func setLocalBack(_ action: (() -> Void)?, owner: UUID) {
        if let action, let page = navigation?.topViewController { localActions[owner] = LocalBackAction(page: page, action: action) }
        else { localActions.removeValue(forKey: owner) }
    }

    @discardableResult
    static func install(on navigation: UINavigationController) -> WidePopController {
        let controller: WidePopController
        if let existing = objc_getAssociatedObject(navigation, &associationKey) as? WidePopController {
            controller = existing
        } else {
            controller = WidePopController()
            controller.navigation = navigation
            controller.pan.addTarget(controller, action: #selector(handlePan(_:)))
            controller.pan.delegate = controller
            controller.pan.maximumNumberOfTouches = 1
            navigation.view.addGestureRecognizer(controller.pan)
            objc_setAssociatedObject(navigation, &associationKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if navigation.delegate !== controller {
            controller.forwardedDelegate = navigation.delegate
            navigation.delegate = controller
        }
        navigation.interactivePopGestureRecognizer?.isEnabled = false
        return controller
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (forwardedDelegate?.responds(to: selector) ?? false)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        forwardedDelegate?.responds(to: selector) == true ? forwardedDelegate : super.forwardingTarget(for: selector)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigation, navigation.viewControllers.count > 1,
              navigation.transitionCoordinator == nil, interaction == nil else { return false }
        let velocity = pan.velocity(in: navigation.view)
        let startX = pan.location(in: navigation.view).x - pan.translation(in: navigation.view).x
        return startX >= 0 && startX <= 50 && velocity.x > abs(velocity.y) * 1.2
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view, current !== navigation?.view {
            if current is UISlider || current is UITextField || current is UITextView { return false }
            if let scroll = current as? UIScrollView {
                if scroll.contentSize.width > scroll.bounds.width + 1,
                   scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1 { return false }
                // At a table's left boundary the navigation gesture takes priority;
                // elsewhere it fails immediately and normal scrolling continues.
                scroll.panGestureRecognizer.require(toFail: pan)
            }
            view = current.superview
        }
        return true
    }
    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let navigation else { return }
        let progress = min(1, max(0, recognizer.translation(in: navigation.view).x / navigation.view.bounds.width))
        switch recognizer.state {
        case .began:
            if let action = localActions.values.first(where: { $0.page === navigation.topViewController })?.action {
                localGesture = action
                return
            }
            interaction = UIPercentDrivenInteractiveTransition()
            interaction?.completionCurve = .easeOut
            navigation.popViewController(animated: true)
        case .changed: interaction?.update(progress)
        case .ended:
            let completed = progress > 0.32 || recognizer.velocity(in: navigation.view).x > 650
            if let action = localGesture {
                localGesture = nil
                if completed { action() }
            } else if completed { interaction?.finish() }
            else { interaction?.cancel() }
        case .cancelled, .failed:
            localGesture = nil
            interaction?.cancel()
        default: break
        }
    }
    func navigationController(_ navigationController: UINavigationController,
                              animationControllerFor operation: UINavigationController.Operation,
                              from fromVC: UIViewController, to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        if operation == .pop && interaction != nil { return animator }
        return forwardedDelegate?.navigationController?(navigationController, animationControllerFor: operation, from: fromVC, to: toVC)
    }
    func navigationController(_ navigationController: UINavigationController,
                              interactionControllerFor animationController: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        if animationController === animator { return interaction }
        return forwardedDelegate?.navigationController?(navigationController, interactionControllerFor: animationController)
    }
    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        forwardedDelegate?.navigationController?(navigationController, willShow: viewController, animated: animated)
    }
    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        interaction = nil
        forwardedDelegate?.navigationController?(navigationController, didShow: viewController, animated: animated)
        navigationController.interactivePopGestureRecognizer?.isEnabled = false
    }
}

@MainActor
private final class PopAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval { 0.28 }
    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let from = context.view(forKey: .from), let to = context.view(forKey: .to) else {
            context.completeTransition(false)
            return
        }
        let width = context.containerView.bounds.width
        context.containerView.insertSubview(to, belowSubview: from)
        to.frame = context.containerView.bounds
        to.transform = CGAffineTransform(translationX: -width * 0.28, y: 0)
        UIView.animate(withDuration: transitionDuration(using: context), animations: {
            from.transform = CGAffineTransform(translationX: width, y: 0)
            to.transform = .identity
        }, completion: { _ in
            from.transform = .identity
            to.transform = .identity
            context.completeTransition(!context.transitionWasCancelled)
        })
    }
}

struct AppLaunchView: View {
    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()

            BinanceLogoMark(size: 96)
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
