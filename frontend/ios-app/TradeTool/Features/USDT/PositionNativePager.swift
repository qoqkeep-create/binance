import SwiftUI
import UIKit

/// UIKit owns horizontal dragging, deceleration and paging. The header is a
/// pinned child of the same scroll view, so its controls also accept a page drag.
struct PositionNativePager<Header: View, Page: View>: UIViewControllerRepresentable {
  @Binding var selection: String
  var enabled: Bool
  var headerHeight: CGFloat
  @ViewBuilder var header: () -> Header
  @ViewBuilder var page: (String) -> Page
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeUIViewController(context: Context) -> PositionPagerController {
    PositionPagerController()
  }

  func updateUIViewController(_ controller: PositionPagerController, context: Context) {
    let environment = context.environment
    controller.update(
      header: AnyView(header().environment(\.self, environment)),
      pages: PositionPageSwipe.pages.map { AnyView(page($0).environment(\.self, environment)) },
      selection: PositionPageSwipe.pages.firstIndex(of: selection) ?? 0,
      enabled: enabled, headerHeight: headerHeight, animated: !reduceMotion
    ) { index in
      let next = PositionPageSwipe.pages[index]
      if selection != next { selection = next }
    }
  }

  static func dismantleUIViewController(_ controller: PositionPagerController, coordinator: ()) {
    controller.stop()
  }
}

@MainActor
final class PositionPagerController: UIViewController, UIScrollViewDelegate {
  let scrollView = PositionPagingScrollView()
  private(set) var pageHosts: [UIHostingController<AnyView>] = []
  private(set) var headerHost: UIHostingController<AnyView>?
  private(set) var settledIndex = 0
  private var requestedIndex = 0
  private var dragIndex = 0
  private var headerHeight: CGFloat = 44
  private var previousSize = CGSize.zero
  private var isUpdating = false
  private var onSelection: ((Int) -> Void)?

  override func loadView() {
    view = UIView()
    view.backgroundColor = .clear
    scrollView.backgroundColor = .clear
    scrollView.isPagingEnabled = true
    scrollView.isDirectionalLockEnabled = true
    scrollView.alwaysBounceVertical = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.delaysContentTouches = false
    scrollView.delegate = self
    scrollView.accessibilityIdentifier = "positions.pager"
    view.addSubview(scrollView)
  }

  func update(header: AnyView, pages: [AnyView], selection: Int, enabled: Bool,
    headerHeight: CGFloat, animated: Bool, onSelection: @escaping (Int) -> Void) {
    loadViewIfNeeded()
    isUpdating = true
    defer { isUpdating = false }
    self.onSelection = onSelection
    self.headerHeight = headerHeight
    if let headerHost { headerHost.rootView = header }
    else { headerHost = host(header) }
    if pageHosts.isEmpty { pageHosts = pages.map(host) }
    else { for (host, root) in zip(pageHosts, pages) { host.rootView = root } }
    // Header stays above the three page hosts, including while a page is moving.
    if let headerHost { scrollView.bringSubviewToFront(headerHost.view) }
    scrollView.isScrollEnabled = enabled
    let changed = requestedIndex != selection
    requestedIndex = selection
    layoutPages()
    if !enabled {
      scrollView.setContentOffset(CGPoint(x: CGFloat(selection) * scrollView.bounds.width, y: 0), animated: false)
      settledIndex = selection
    } else if changed, !scrollView.isDragging {
      scrollView.setContentOffset(CGPoint(x: CGFloat(selection) * scrollView.bounds.width, y: 0),
        animated: animated && previousSize.width > 0)
      settledIndex = selection
    }
    updateAccessibility()
  }

  private func host(_ root: AnyView) -> UIHostingController<AnyView> {
    let host = UIHostingController(rootView: root)
    host.safeAreaRegions = []
    host.view.backgroundColor = .clear
    addChild(host)
    scrollView.addSubview(host.view)
    host.didMove(toParent: self)
    return host
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layoutPages()
  }

  private func layoutPages() {
    scrollView.frame = view.bounds
    let size = scrollView.bounds.size
    guard size.width > 0, size.height > 0 else { return }
    scrollView.contentSize = CGSize(width: size.width * CGFloat(pageHosts.count), height: size.height)
    for (index, host) in pageHosts.enumerated() {
      host.view.frame = CGRect(x: CGFloat(index) * size.width, y: headerHeight,
        width: size.width, height: max(0, size.height - headerHeight))
    }
    if size != previousSize {
      previousSize = size
      scrollView.setContentOffset(CGPoint(x: CGFloat(requestedIndex) * size.width, y: 0), animated: false)
      settledIndex = requestedIndex
    }
    pinHeader()
  }

  private func pinHeader() {
    headerHost?.view.frame = CGRect(x: scrollView.contentOffset.x, y: 0,
      width: scrollView.bounds.width, height: headerHeight)
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) { pinHeader() }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    dragIndex = settledIndex
  }

  func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
    targetContentOffset: UnsafeMutablePointer<CGPoint>) {
    let translation = self.scrollView.dragTranslation
    let destination = PositionPageSwipe.destination(from: PositionPageSwipe.pages[dragIndex],
      horizontal: translation.x, vertical: translation.y)
    // A short deliberate swipe can finish on the same side of the screen.
    // Reversing toward the starting page cancels instead of fetching a new page.
    let index = destination.flatMap { PositionPageSwipe.pages.firstIndex(of: $0) } ?? dragIndex
    targetContentOffset.pointee = CGPoint(x: CGFloat(index) * scrollView.bounds.width, y: 0)
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishPaging() }
  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { finishPaging() }
  }
  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { finishPaging() }

  private func finishPaging() {
    guard !isUpdating, scrollView.bounds.width > 0, !pageHosts.isEmpty else { return }
    let index = min(pageHosts.count - 1, max(0,
      Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())))
    settledIndex = index
    requestedIndex = index
    updateAccessibility()
    onSelection?(index)
  }

  private func updateAccessibility() {
    for (index, host) in pageHosts.enumerated() {
      host.view.accessibilityElementsHidden = index != settledIndex
    }
  }

  func stop() {
    onSelection = nil
    scrollView.isScrollEnabled = false
    scrollView.delegate = nil
  }
}

@MainActor
final class PositionPagingScrollView: UIScrollView {
  private var dragOrigin = CGPoint.zero
  override init(frame: CGRect) {
    super.init(frame: frame)
    observeTouchOrigin()
  }
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    observeTouchOrigin()
  }
  private func observeTouchOrigin() {
    addGestureRecognizer(PositionPageTouchOrigin { [weak self] point in self?.dragOrigin = point })
  }
  var dragTranslation: CGPoint {
    let point = panGestureRecognizer.location(in: window)
    return CGPoint(x: point.x - dragOrigin.x, y: point.y - dragOrigin.y)
  }
  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    if gestureRecognizer === panGestureRecognizer {
      let velocity = panGestureRecognizer.velocity(in: self)
      guard abs(velocity.x) > abs(velocity.y) * 1.8 else { return false }
    }
    return super.gestureRecognizerShouldBegin(gestureRecognizer)
  }
  override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// Observe only the original touch coordinate, then fail immediately. This
/// neither drives scrolling nor competes with the native scroll recognizers.
private final class PositionPageTouchOrigin: UIGestureRecognizer {
  private let onOrigin: (CGPoint) -> Void
  init(onOrigin: @escaping (CGPoint) -> Void) {
    self.onOrigin = onOrigin
    super.init(target: nil, action: nil)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
  }
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch = touches.first { onOrigin(touch.location(in: view?.window)) }
    state = .failed
  }
}
