import SwiftUI
import UIKit
import XCTest
@testable import TradeTool

@MainActor
final class PositionPagerTests: XCTestCase {
  private func update(_ controller: PositionPagerController, selection: Int = 0, enabled: Bool = true,
    onSelection: @escaping (Int) -> Void = { _ in }) {
    controller.update(header: AnyView(Text("Header")),
      pages: (0..<3).map { AnyView(Text("Page \($0)")) }, selection: selection,
      enabled: enabled, headerHeight: 44, animated: false, onSelection: onSelection)
  }

  private func pager() -> PositionPagerController {
    let controller = PositionPagerController()
    update(controller)
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    return controller
  }

  func testPartialDragShowsTwoPagesKeepsHeaderPinnedAndDoesNotCommit() throws {
    let controller = pager()
    var selections: [Int] = []
    update(controller) { selections.append($0) }
    XCTAssertTrue(controller.scrollView.isPagingEnabled)
    controller.scrollView.contentOffset.x = 120
    let viewport = controller.scrollView.bounds
    XCTAssertTrue(viewport.intersects(controller.pageHosts[0].view.frame))
    XCTAssertTrue(viewport.intersects(controller.pageHosts[1].view.frame))
    let header = try XCTUnwrap(controller.headerHost?.view)
    XCTAssertEqual(header.convert(header.bounds, to: controller.view).minX, 0, accuracy: 0.1)
    XCTAssertEqual(controller.settledIndex, 0)
    XCTAssertTrue(selections.isEmpty, "Exposing an adjacent page must not commit selection or trigger its fetch")
    controller.scrollView.contentOffset.x = 0
    controller.scrollViewDidEndDecelerating(controller.scrollView)
    XCTAssertEqual(selections, [0], "A cancelled drag stays on the original page")
    controller.scrollView.contentOffset.x = 390
    controller.scrollViewDidEndDecelerating(controller.scrollView)
    XCTAssertEqual(selections, [0, 1])
    XCTAssertTrue(controller.pageHosts[0].view.accessibilityElementsHidden)
    XCTAssertFalse(controller.pageHosts[1].view.accessibilityElementsHidden)
  }

  func testDataUpdatesRetainHostsAndPartialOffsetWithoutSelection() {
    let controller = pager()
    let hosts = controller.pageHosts
    let header = controller.headerHost
    controller.scrollView.contentOffset.x = 90
    update(controller)
    XCTAssertEqual(controller.scrollView.contentOffset.x, 90, accuracy: 0.1)
    XCTAssertTrue(controller.headerHost === header)
    for index in hosts.indices { XCTAssertTrue(controller.pageHosts[index] === hosts[index]) }
  }

  func testDisableAndRotationRestoreCommittedPageWithoutPublishing() {
    let controller = pager()
    var selections: [Int] = []
    update(controller, selection: 1) { selections.append($0) }
    controller.scrollView.contentOffset.x = 450
    update(controller, selection: 1, enabled: false) { selections.append($0) }
    XCTAssertFalse(controller.scrollView.isScrollEnabled)
    XCTAssertEqual(controller.scrollView.contentOffset.x, 390, accuracy: 0.1)
    XCTAssertTrue(selections.isEmpty)
    controller.view.frame.size = CGSize(width: 700, height: 390)
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    XCTAssertEqual(controller.scrollView.contentOffset.x, 700, accuracy: 0.1)
    XCTAssertEqual(controller.pageHosts[2].view.frame.minX, 1400, accuracy: 0.1)
    XCTAssertEqual(controller.pageHosts[1].view.frame.height, 346, accuracy: 0.1)
    controller.stop()
    controller.scrollViewDidEndDecelerating(controller.scrollView)
    XCTAssertTrue(selections.isEmpty)
  }
}
