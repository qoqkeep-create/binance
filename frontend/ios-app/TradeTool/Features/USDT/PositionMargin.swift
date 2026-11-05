import Foundation
import Combine
import SwiftUI
import UIKit

enum PositionPageSwipe {
  static let pages = ["positions", "limits", "history"]
  static func destination(from page: String, horizontal: Double, vertical: Double) -> String? {
    guard horizontal.isFinite, vertical.isFinite, abs(horizontal) >= 60,
      abs(horizontal) > abs(vertical) * 1.8, let index = pages.firstIndex(of: page)
    else { return nil }
    let next = index + (horizontal < 0 ? 1 : -1)
    return pages.indices.contains(next) ? pages[next] : nil
  }
}

enum PositionMarginLevel: Equatable { case unavailable, normal, caution, danger }

struct PositionMarginPresentation {
  let snapshot: JSONValue
  let isCurrent: Bool
  var ratio: Decimal? { snapshot["margin_ratio_percent"]?.decimal.flatMap { $0.isNaN || $0 < 0 ? nil : $0 } }
  var level: PositionMarginLevel {
    guard isCurrent, snapshot["supported"]?.flag == true else { return .unavailable }
    if snapshot["liquidation_reached"]?.flag == true { return .danger }
    guard let ratio else { return .unavailable }
    return ratio >= 80 ? .danger : ratio >= 50 ? .caution : .normal
  }
  var percentText: String {
    guard level != .unavailable else { return "--%" }
    return ratio.map { Self.percent($0) } ?? "100%"
  }
  var badgePercentText: String {
    guard level != .unavailable else { return "--%" }
    guard let ratio else { return "100%" }
    // Keep the compact integer in the same risk band as the unrounded value.
    var source = ratio, whole = Decimal()
    NSDecimalRound(&whole, &source, 0, .down)
    let digits = NSDecimalNumber(decimal: whole).stringValue
    return (digits.count < 2 ? "0" : "") + digits + "%"
  }
  static func percent(_ value: Decimal?) -> String {
    guard let value, !value.isNaN else { return "--" }
    return DisplayNumber.amount(value, maximumFractionDigits: 2) + "%"
  }
}

/// One account snapshot, refreshed only while the positions screen is active.
@MainActor
final class PositionMarginModel: ObservableObject {
  @Published private(set) var snapshot: JSONValue = .null
  @Published private(set) var scope = ""
  @Published private(set) var loading = false
  @Published private(set) var error = ""
  @Published private(set) var active = false
  private var requestID = UUID()
  private var monitorID = UUID()

  func reset(scope: String) {
    requestID = UUID()
    self.scope = scope; snapshot = .null; loading = false; error = ""; active = false
  }

  func isCurrent(scope: String, now: Date) -> Bool {
    guard active, self.scope == scope, error.isEmpty,
      let milliseconds = snapshot["observed_at"]?.decimal,
      let maximumAge = snapshot["max_age_seconds"]?.decimal else { return false }
    let age = now.timeIntervalSince1970 - NSDecimalNumber(decimal: milliseconds).doubleValue / 1000
    let limit = NSDecimalNumber(decimal: maximumAge).doubleValue
    return age.isFinite && limit.isFinite && age >= -2 && age <= min(limit, 20) && limit > 0
  }

  func refresh(_ store: USDTStore) async {
    let owner = store.scope
    if scope != owner { reset(scope: owner) }
    guard store.isBound, !loading else { return }
    let id = UUID(); requestID = id; loading = true
    defer { if requestID == id { loading = false } }
    do {
      let value = try await store.get("/v1/position/margin")
      guard owner == store.scope, scope == owner, requestID == id, !Task.isCancelled else { return }
      snapshot = value; error = ""
    } catch {
      guard owner == store.scope, scope == owner, requestID == id, !Task.isCancelled else { return }
      self.error = "保证金率更新失败，请重试"
    }
  }

  func monitor(_ store: USDTStore) async {
    let owner = store.scope
    if scope != owner { reset(scope: owner) }
    let id = UUID(); monitorID = id; active = true
    defer {
      if monitorID == id {
        active = false
        // A cancelled read must not prevent a new foreground read.
        requestID = UUID(); loading = false
      }
    }
    while !Task.isCancelled, owner == store.scope, store.isBound {
      await refresh(store)
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
    }
  }

  func suspend() {
    monitorID = UUID(); requestID = UUID(); active = false; loading = false
  }
}

/// Page-wide horizontal gesture, including controls and blank scroll space.
struct PositionPageSwipeGesture: UIViewRepresentable {
  var enabled: Bool
  var onEnd: (Double, Double) -> Void
  func makeUIView(context: Context) -> GestureView {
    let view = GestureView(); view.isUserInteractionEnabled = false
    view.enabled = enabled; view.onEnd = onEnd
    return view
  }
  func updateUIView(_ view: GestureView, context: Context) {
    view.enabled = enabled; view.onEnd = onEnd
  }
  static func dismantleUIView(_ view: GestureView, coordinator: ()) { view.detach() }

  final class GestureView: UIView, UIGestureRecognizerDelegate {
    var enabled = false
    var onEnd: ((Double, Double) -> Void)?
    private weak var installedWindow: UIWindow?
    private lazy var pan: UIPanGestureRecognizer = {
      let gesture = UIPanGestureRecognizer(target: self, action: #selector(ended))
      gesture.maximumNumberOfTouches = 1
      gesture.delegate = self
      return gesture
    }()
    override func didMoveToWindow() {
      super.didMoveToWindow()
      detach()
      installedWindow = window
      window?.addGestureRecognizer(pan)
    }
    func detach() {
      installedWindow?.removeGestureRecognizer(pan); installedWindow = nil
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard enabled, window != nil, bounds.contains(pan.location(in: self)) else { return false }
      let velocity = pan.velocity(in: self)
      return abs(velocity.x) > abs(velocity.y) * 1.8
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      guard enabled, bounds.contains(touch.location(in: self)) else { return false }
      var view = touch.view
      while let current = view, current !== window {
        if current is UISlider || current is UITextField || current is UITextView { return false }
        view = current.superview
      }
      return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    @objc private func ended(_ gesture: UIPanGestureRecognizer) {
      guard enabled, gesture.state == .ended else { return }
      let translation = gesture.translation(in: self)
      onEnd?(translation.x, translation.y)
    }
  }
}

@MainActor extension PositionMarginLevel {
  var foreground: Color {
    switch self {
    case .normal: WebTheme.color(0x087E52, 0x47D7A0)
    case .caution: WebTheme.color(0x8B6500, 0xFFE17A)
    case .danger: WebTheme.color(0xCD243D, 0xFF8293)
    case .unavailable: WebTheme.muted
    }
  }
  var background: Color {
    switch self {
    case .normal: WebTheme.color(0xDFF7ED, 0x153E32)
    case .caution: WebTheme.color(0xFFF1BF, 0x493E1A)
    case .danger: WebTheme.color(0xFFE4E8, 0x512630)
    case .unavailable: WebTheme.secondaryButton
    }
  }
}

struct PositionMarginBadge: View {
  @ObservedObject var model: PositionMarginModel
  let scope: String
  let action: () -> Void
  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { timeline in
      let value = PositionMarginPresentation(snapshot: model.snapshot,
        isCurrent: model.isCurrent(scope: scope, now: timeline.date))
      Button(action: action) {
        HStack(spacing: 2) {
          Image(systemName: "shield.lefthalf.filled").font(.system(size: 9, weight: .semibold))
          Text(value.badgePercentText)
            .font(.system(size: value.badgePercentText.count > 3 ? 16 : 20, weight: .heavy).width(.compressed))
            .monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.9)
        }.foregroundStyle(value.level.foreground).padding(.horizontal, 4)
          .frame(width: value.badgePercentText.count > 3 ? 60 : 52, height: 28)
          .background(value.level.background, in: RoundedRectangle(cornerRadius: 7))
          .frame(height: 44).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityIdentifier("positions.margin")
        .accessibilityLabel("币安保证金率").accessibilityValue(value.badgePercentText)
    }
  }
}

struct PositionMarginDetails: View {
  @ObservedObject var model: PositionMarginModel
  @EnvironmentObject private var store: USDTStore
  var body: some View {
    WebModal(title: "币安保证金率", maximumWidth: 420, contentSpacing: 14) {
      TimelineView(.periodic(from: .now, by: 1)) { timeline in
        let data = model.scope == store.scope ? model.snapshot : .null
        let current = model.isCurrent(scope: store.scope, now: timeline.date)
        let value = PositionMarginPresentation(snapshot: data, isCurrent: current)
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
              VStack(alignment: .leading, spacing: 4) {
                Text(data["supported"]?.flag == true ? "全仓 · USDT" : "账户保证金")
                  .font(.system(size: 12)).foregroundStyle(WebTheme.muted)
                Text(value.percentText).font(.system(size: 32, weight: .bold)).monospacedDigit()
                  .foregroundStyle(value.level.foreground)
              }
              Spacer()
              Button(model.loading ? "更新中…" : "刷新") { Task { await model.refresh(store) } }
                .disabled(model.loading).foregroundStyle(WebTheme.brand).frame(minHeight: 44)
            }
            if !model.error.isEmpty { Text(model.error).foregroundStyle(WebTheme.danger) }
            if !current, data != .null {
              Text("以下为上次快照，当前保证金率待更新").foregroundStyle(WebTheme.muted)
            }
            if data["supported"]?.flag == true {
              VStack(spacing: 8) {
                USDTMetric(title: "合计初始保证金占用", value: money(data, "initial_margin"))
                USDTMetric(title: "合计占用 / 保证金余额", value: PositionMarginPresentation.percent(data["total_usage_percent"]?.decimal))
                USDTMetric(title: "持仓初始保证金", value: money(data, "position_initial_margin"))
                USDTMetric(title: "委托初始保证金", value: money(data, "open_order_initial_margin"))
              }.padding(12).background(WebTheme.secondaryButton, in: RoundedRectangle(cornerRadius: 10))
              VStack(spacing: 8) {
                USDTMetric(title: "钱包余额", value: money(data, "wallet_balance"))
                USDTMetric(title: "未实现盈亏（标记价格）", value: money(data, "unrealized_profit"))
                USDTMetric(title: "保证金余额", value: money(data, "margin_balance"))
                USDTMetric(title: "维持保证金", value: money(data, "maintenance_margin"))
                USDTMetric(title: "可用余额", value: money(data, "available_balance"))
              }
              Divider()
              Text("持仓与委托保证金").fontWeight(.semibold)
              if data["positions"]?.rows.isEmpty != false { Text("暂无持仓或委托").foregroundStyle(WebTheme.muted) }
              ForEach(Array((data["positions"]?.rows ?? []).enumerated()), id: \.offset) { _, row in
                VStack(spacing: 7) {
                  HStack {
                    Text(row.value("symbol")).fontWeight(.semibold)
                    Spacer()
                    Text((row["quantity"]?.decimal == 0 ? "委托" : row.value("side") == "long" ? "多" : "空")
                      + " · 全仓 · " + row.value("leverage") + "×")
                      .foregroundStyle(WebTheme.secondary)
                  }
                  USDTMetric(title: "初始保证金", value: money(row, "position_initial_margin"))
                  USDTMetric(title: "占保证金余额", value: PositionMarginPresentation.percent(row["usage_percent"]?.decimal))
                  USDTMetric(title: "维持保证金", value: money(row, "maintenance_margin"))
                  USDTMetric(title: "未实现盈亏", value: money(row, "unrealized_profit"))
                  if (row["open_order_initial_margin"]?.decimal ?? 0) > 0 {
                    USDTMetric(title: "关联委托保证金", value: money(row, "open_order_initial_margin"))
                  }
                }.padding(12).background(WebTheme.secondaryButton, in: RoundedRectangle(cornerRadius: 10))
              }
              Text("保证金率 = 维持保证金 ÷ 保证金余额；100% 为强平线。保证金余额 = 钱包余额 + 未实现盈亏。初始保证金占用不是强平比例。")
                .font(.system(size: 12)).foregroundStyle(WebTheme.secondary)
              Text("绿色 < 50% · 黄色 50%～80% · 红色 ≥ 80%。颜色为本 App 预警分级。每 5 秒更新，实际风险以币安实时数据为准。")
                .font(.system(size: 12)).foregroundStyle(WebTheme.muted)
            } else {
              Text(data.value("reason", fallback: model.loading ? "正在读取币安账户…" : "保证金率暂不可用"))
                .foregroundStyle(WebTheme.secondary)
            }
            if let timestamp = data["observed_at"]?.decimal {
              Text("快照：" + Date(timeIntervalSince1970: NSDecimalNumber(decimal: timestamp).doubleValue / 1000)
                .formatted(date: .omitted, time: .standard)).font(.system(size: 11)).foregroundStyle(WebTheme.muted)
            }
          }
        }.frame(maxHeight: 500)
      }
    }.accessibilityIdentifier("positions.marginDetails")
  }
  private func money(_ value: JSONValue, _ key: String) -> String {
    value[key]?.decimal.map { DisplayNumber.amount($0, maximumFractionDigits: 4) + " USDT" } ?? "--"
  }
}
