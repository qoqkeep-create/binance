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

enum PositionExposureState: Equatable { case unknown, empty, open }

enum PositionMarginNumber {
  static func decimal(_ value: JSONValue?) -> Decimal? {
    guard let value else { return nil }
    let text: String
    switch value {
    case .string(let string): text = string
    case .number(let number) where number.isFinite: text = value.text
    default: return nil
    }
    guard text.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$", options: .regularExpression) != nil,
      let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else { return nil }
    return number
  }
  static func usage(_ amount: JSONValue?, equity: JSONValue?) -> Decimal? {
    guard let numerator = decimal(amount), numerator >= 0, let denominator = decimal(equity), denominator > 0 else { return nil }
    return numerator / denominator * 100
  }
}

struct PositionMarginPresentation {
  let snapshot: JSONValue
  let isCurrent: Bool
  var exposure: PositionExposureState = .unknown
  private var isEmpty: Bool {
    if exposure == .empty { return true }
    guard exposure != .open, isCurrent, snapshot["supported"]?.flag == true,
      case .array(let positions)? = snapshot["positions"] else { return false }
    return positions.allSatisfy { PositionMarginNumber.decimal($0["quantity"]) == 0 }
  }
  var ratio: Decimal? { PositionMarginNumber.decimal(snapshot["margin_ratio_percent"]).flatMap { $0 < 0 ? nil : $0 } }
  var level: PositionMarginLevel {
    if isEmpty { return .normal }
    guard isCurrent, snapshot["supported"]?.flag == true else { return .unavailable }
    if snapshot["liquidation_reached"]?.flag == true { return .danger }
    guard let ratio else { return .unavailable }
    return ratio >= 80 ? .danger : ratio >= 50 ? .caution : .normal
  }
  var percentText: String {
    if isEmpty { return "0%" }
    guard level != .unavailable else { return "--%" }
    return ratio.map { Self.percent($0) } ?? "100%"
  }
  var badgePercentText: String {
    if isEmpty { return "0%" }
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
  static let refreshInterval: TimeInterval = 2
  @Published private(set) var snapshot: JSONValue = .null
  @Published private(set) var scope = ""
  @Published private(set) var loading = false
  @Published private(set) var error = ""
  @Published private(set) var active = false
  private var requestID = UUID()
  private var monitorID = UUID()
  private var refreshAfterChange = false

  func exposure(in store: USDTStore, now: Date = .now) -> PositionExposureState {
    guard store.isBound else { return .unknown }
    let positions = store.positionSnapshots
    var state = PositionExposureState.unknown
    var observed = Date.distantPast
    if positions.scope == store.scope, positions.hasLoaded, !positions.failed,
      let date = positions.updatedAt, now.timeIntervalSince(date) <= 20 {
      state = positions.rows.isEmpty ? .empty : .open
      observed = date
    }
    if isCurrent(scope: store.scope, now: now), snapshot["supported"]?.flag == true,
      let timestamp = PositionMarginNumber.decimal(snapshot["observed_at"]),
      case .array(let rows)? = snapshot["positions"] {
      let date = Date(timeIntervalSince1970: NSDecimalNumber(decimal: timestamp).doubleValue / 1000)
      let quantities = rows.compactMap { PositionMarginNumber.decimal($0["quantity"]) }
      guard quantities.count == rows.count else { return state }
      let hasPosition = quantities.contains(where: { $0 != 0 })
      // The app list can omit external positions or return cached rows. A live
      // exchange position must not become zero just because that list is empty.
      if hasPosition || date >= observed { state = hasPosition ? .open : .empty }
    }
    return state
  }

  func reset(scope: String) {
    requestID = UUID()
    self.scope = scope; snapshot = .null; loading = false; error = ""; active = false
    refreshAfterChange = false
  }

  func isCurrent(scope: String, now: Date) -> Bool {
    guard active, self.scope == scope, error.isEmpty,
      let milliseconds = PositionMarginNumber.decimal(snapshot["observed_at"]),
      let maximumAge = PositionMarginNumber.decimal(snapshot["max_age_seconds"]) else { return false }
    let age = now.timeIntervalSince1970 - NSDecimalNumber(decimal: milliseconds).doubleValue / 1000
    let limit = NSDecimalNumber(decimal: maximumAge).doubleValue
    return age.isFinite && limit.isFinite && age >= -2 && age <= min(limit, 20) && limit > 0
  }

  func refresh(_ store: USDTStore, afterChange: Bool = false) async {
    let owner = store.scope
    if scope != owner { reset(scope: owner) }
    guard store.isBound else { return }
    guard !loading else { refreshAfterChange = refreshAfterChange || afterChange; return }
    let id = UUID(); requestID = id; loading = true
    defer { if requestID == id { loading = false; refreshAfterChange = false } }
    var fresh = afterChange
    repeat {
      refreshAfterChange = false
      do {
        let value = try await store.get("/v1/position/margin", query: fresh ? [.init(name: "fresh", value: "1")] : [])
        guard owner == store.scope, scope == owner, requestID == id, !Task.isCancelled else { return }
        snapshot = value; error = ""
      } catch {
        guard owner == store.scope, scope == owner, requestID == id, !Task.isCancelled else { return }
        self.error = "保证金率更新失败，请重试"
      }
      // A trade event during a read needs one fresh follow-up; ordinary polls join.
      fresh = true
    } while refreshAfterChange && !Task.isCancelled
  }

  func monitor(_ store: USDTStore) async {
    let owner = store.scope
    if scope != owner { reset(scope: owner) }
    let id = UUID(); monitorID = id; active = true
    defer {
      if monitorID == id {
        active = false
        // A cancelled read must not prevent a new foreground read.
        requestID = UUID(); loading = false; refreshAfterChange = false
      }
    }
    while !Task.isCancelled, owner == store.scope, store.isBound {
      await refresh(store)
      do { try await Task.sleep(for: .seconds(Self.refreshInterval)) } catch { return }
    }
  }

  func suspend() {
    monitorID = UUID(); requestID = UUID(); active = false; loading = false; refreshAfterChange = false
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
  var exposure: PositionExposureState = .unknown
  let action: () -> Void
  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { timeline in
      let value = PositionMarginPresentation(snapshot: model.snapshot,
        isCurrent: model.isCurrent(scope: scope, now: timeline.date), exposure: exposure)
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
    WebModal(title: "保证金详情", maximumWidth: 420, contentSpacing: 12) {
      TimelineView(.periodic(from: .now, by: 1)) { timeline in
        let data = model.scope == store.scope ? model.snapshot : .null
        let current = model.isCurrent(scope: store.scope, now: timeline.date)
        let exposure = model.exposure(in: store, now: timeline.date)
        let value = PositionMarginPresentation(snapshot: data, isCurrent: current, exposure: exposure)
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text(exposure == .empty ? "未开仓" : exposure == .open ? "当前持仓保证金" : "正在确认持仓…")
                .font(.system(size: 14)).foregroundStyle(WebTheme.secondary)
              Spacer()
              Button(model.loading ? "更新中…" : "刷新") {
                Task {
                  async let positions: Void = store.refreshPositions()
                  await model.refresh(store, afterChange: true)
                  await positions
                }
              }.disabled(model.loading).foregroundStyle(WebTheme.brand).frame(minHeight: 44)
            }
            USDTCard(radius: 12, padding: 12, spacing: 10) {
              Text("币安实时保证金率").font(.system(size: 16, weight: .semibold))
              if exposure == .empty {
                Text("未开仓").foregroundStyle(WebTheme.muted)
              } else {
                HStack(alignment: .firstTextBaseline) {
                  Text("实时保证金率").foregroundStyle(WebTheme.secondary)
                  Spacer()
                  Text(value.percentText).font(.system(size: 26, weight: .bold)).monospacedDigit()
                    .foregroundStyle(value.level.foreground)
                    .accessibilityIdentifier("positions.margin.realtimePercent")
                }
                if !model.error.isEmpty { Text(model.error).foregroundStyle(WebTheme.danger) }
                if data["supported"]?.flag != true {
                  Text(data.value("reason", fallback: model.loading ? "正在读取币安账户…" : "保证金率暂不可用"))
                    .foregroundStyle(WebTheme.secondary)
                } else {
                  Text("按币安实时账户的维持保证金 ÷ 保证金余额计算，100% 为强平线。与初始保证金占用比例不同。")
                    .font(.system(size: 12)).foregroundStyle(WebTheme.secondary)
                  Text("前台约每 2 秒更新，收到交易事件后重读。实际风险以币安为准。")
                    .font(.system(size: 12)).foregroundStyle(WebTheme.muted)
                  if !current { Text("实时比例待更新").foregroundStyle(WebTheme.muted) }
                }
                if let timestamp = PositionMarginNumber.decimal(data["observed_at"]) {
                  Text("快照：" + Date(timeIntervalSince1970: NSDecimalNumber(decimal: timestamp).doubleValue / 1000)
                    .formatted(date: .omitted, time: .standard)).font(.system(size: 11)).foregroundStyle(WebTheme.muted)
                }
              }
            }.overlay { RoundedRectangle(cornerRadius: 12).stroke(WebTheme.border, lineWidth: 1) }
              .accessibilityIdentifier("positions.margin.binanceCard")
            USDTCard(radius: 12, padding: 12, spacing: 10) {
              Text("本地计算明细").font(.system(size: 16, weight: .semibold))
              if exposure == .empty {
                Text("未开仓").foregroundStyle(WebTheme.muted)
              } else if data["supported"]?.flag == true {
                if !current { Text("上次计算快照，正在更新").foregroundStyle(WebTheme.muted) }
                USDTMetric(title: "合计初始保证金占用", value: money(data, "initial_margin"))
                USDTMetric(title: "合计占用 / 保证金余额", value: PositionMarginPresentation.percent(
                  PositionMarginNumber.usage(data["initial_margin"], equity: data["margin_balance"])))
                USDTMetric(title: "持仓初始保证金", value: money(data, "position_initial_margin"))
                USDTMetric(title: "委托初始保证金", value: money(data, "open_order_initial_margin"))
                Divider()
                USDTMetric(title: "钱包余额", value: money(data, "wallet_balance"))
                USDTMetric(title: "未实现盈亏（标记价格）", value: money(data, "unrealized_profit"))
                USDTMetric(title: "保证金余额", value: money(data, "margin_balance"))
                USDTMetric(title: "维持保证金", value: money(data, "maintenance_margin"))
                USDTMetric(title: "可用余额", value: money(data, "available_balance"))
                ForEach(Array((data["positions"]?.rows ?? []).enumerated()), id: \.offset) { _, row in
                  Divider()
                  HStack {
                    Text(row.value("symbol")).fontWeight(.semibold)
                    Spacer()
                    Text((PositionMarginNumber.decimal(row["quantity"]) == 0 ? "委托" : row.value("side") == "long" ? "多" : "空")
                      + " · 全仓 · " + row.value("leverage") + "×").foregroundStyle(WebTheme.secondary)
                  }
                  USDTMetric(title: "初始保证金", value: money(row, "position_initial_margin"))
                  USDTMetric(title: "占保证金余额", value: PositionMarginPresentation.percent(
                    PositionMarginNumber.usage(row["position_initial_margin"], equity: data["margin_balance"])))
                  USDTMetric(title: "维持保证金", value: money(row, "maintenance_margin"))
                  USDTMetric(title: "未实现盈亏", value: money(row, "unrealized_profit"))
                  if (PositionMarginNumber.decimal(row["open_order_initial_margin"]) ?? 0) > 0 {
                    USDTMetric(title: "关联委托保证金", value: money(row, "open_order_initial_margin"))
                  }
                }
                Text("占用比例 = 初始保证金 ÷ 保证金余额。保证金余额 = 钱包余额 + 标记价格未实现盈亏。")
                  .font(.system(size: 12)).foregroundStyle(WebTheme.muted)
              } else {
                Text(exposure == .open ? "正在读取计算明细…" : "等待持仓快照")
                  .foregroundStyle(WebTheme.muted)
              }
            }.overlay { RoundedRectangle(cornerRadius: 12).stroke(WebTheme.border, lineWidth: 1) }
              .accessibilityIdentifier("positions.margin.localCard")
          }
        }.frame(maxHeight: exposure == .empty ? 240 : 500)
      }
    }.accessibilityIdentifier("positions.marginDetails")
  }
  private func money(_ value: JSONValue, _ key: String) -> String {
    PositionMarginNumber.decimal(value[key]).map { DisplayNumber.amount($0, maximumFractionDigits: 4) + " USDT" } ?? "--"
  }
}
