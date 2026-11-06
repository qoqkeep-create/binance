import SwiftUI
import UIKit
import XCTest
@testable import TradeTool

@MainActor
final class NavigationTransitionTests: XCTestCase {
  func testInactiveModalDoesNotDisableContentTransactions() async throws {
    let appeared = expectation(description: "Dialog source mounted")
    let observed = expectation(description: "Source update transaction observed")
    let state = NavigationProbeState()
    var disabled: [Bool] = []
    let view = NavigationTransactionProbe(state: state) { transaction in
      guard state.generation > 0 else { return }
      disabled.append(transaction.disablesAnimations)
      if disabled.count == 1 { observed.fulfill() }
    }
      .webModal(isPresented: .constant(false)) { Text("Inactive dialog") }
      .onAppear { appeared.fulfill() }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(rootView: view)
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    await fulfillment(of: [appeared], timeout: 4)
    withAnimation(.default) { state.generation += 1 }
    await fulfillment(of: [observed], timeout: 4)
    XCTAssertFalse(disabled.isEmpty)
    XCTAssertFalse(disabled.contains(true),
      "A dialog's system-cover transaction must not disable navigation and controls in its source page")
  }

  func testPushWithInactiveModalKeepsNativeTransition() async throws {
    try await checkPush(sourceHasModal: false, destinationHasModal: true)
  }

  func testPushFromPageWithInactiveModalKeepsNativeTransition() async throws {
    try await checkPush(sourceHasModal: true, destinationHasModal: false)
  }

  func testPushWithoutModalKeepsNativeTransition() async throws {
    try await checkPush(sourceHasModal: false, destinationHasModal: false)
  }

  private func checkPush(sourceHasModal: Bool, destinationHasModal: Bool) async throws {
    let sourceAppeared = expectation(description: "Native source appeared")
    let destinationShown = expectation(description: "Native destination transition started")
    let state = NavigationProbeState()
    var nativeNavigation: UINavigationController?
    let view = NavigationProbeRoot(state: state, sourceHasModal: sourceHasModal,
      destinationHasModal: destinationHasModal) { navigation in
        nativeNavigation = navigation
        sourceAppeared.fulfill()
      }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let host = UIHostingController(rootView: view)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    await fulfillment(of: [sourceAppeared], timeout: 4)
    let navigation = try XCTUnwrap(nativeNavigation)
    let originalDelegate = navigation.delegate
    let observer = NativeNavigationObserver(original: originalDelegate) { animated in
      XCTAssertTrue(animated, "Inactive dialog presenters must not suppress a navigation push")
      destinationShown.fulfill()
    }
    navigation.delegate = observer
    defer { navigation.delegate = originalDelegate }
    withAnimation(.default) { state.presented = true }
    await fulfillment(of: [destinationShown], timeout: 4)
  }
}

@MainActor
private final class NavigationProbeState: ObservableObject {
  @Published var presented = false
  @Published var generation = 0
}

private struct NavigationTransactionProbe: View {
  @ObservedObject var state: NavigationProbeState
  let observed: (Transaction) -> Void
  var body: some View {
    Text("Source action \(state.generation)").transaction { observed($0) }
  }
}

private struct NavigationProbeRoot: View {
  @ObservedObject var state: NavigationProbeState
  let sourceHasModal: Bool
  let destinationHasModal: Bool
  let sourceAppeared: (UINavigationController) -> Void
  var body: some View {
    NavigationStack {
      probePage(hasModal: sourceHasModal)
        .background(NativeNavigationProbe(appeared: sourceAppeared))
        .navigationDestination(isPresented: $state.presented) {
          probePage(hasModal: destinationHasModal)
        }
    }
  }
  private func probePage(hasModal: Bool) -> some View {
    Group {
      if hasModal {
        Text("Navigation probe").frame(maxWidth: .infinity, maxHeight: .infinity)
          .webModal(isPresented: .constant(false)) { Text("Inactive dialog") }
      } else {
        Text("Navigation probe").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.toolbar(.hidden, for: .navigationBar)
  }
}

private struct NativeNavigationProbe: UIViewControllerRepresentable {
  let appeared: (UINavigationController) -> Void
  func makeUIViewController(context: Context) -> ProbeController {
    let controller = ProbeController()
    controller.appeared = appeared
    return controller
  }
  func updateUIViewController(_ controller: ProbeController, context: Context) {
    controller.appeared = appeared
  }
  final class ProbeController: UIViewController {
    var appeared: ((UINavigationController) -> Void)?
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      if let navigationController { appeared?(navigationController) }
    }
  }
}

@MainActor
private final class NativeNavigationObserver: NSObject, UINavigationControllerDelegate {
  let original: UINavigationControllerDelegate?
  let shown: (Bool) -> Void
  init(original: UINavigationControllerDelegate?, shown: @escaping (Bool) -> Void) {
    self.original = original
    self.shown = shown
  }
  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || (original?.responds(to: selector) ?? false)
  }
  override func forwardingTarget(for selector: Selector!) -> Any? {
    original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
  }
  func navigationController(_ navigationController: UINavigationController,
    willShow viewController: UIViewController, animated: Bool) {
    original?.navigationController?(navigationController, willShow: viewController, animated: animated)
    shown(animated)
  }
}
