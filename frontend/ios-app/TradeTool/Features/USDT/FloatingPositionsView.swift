import SwiftUI

enum FloatingPositionsPreferences {
  static let enabledKey = "integrated.floatingPositions.enabled"
  // AppStorage observers must share the same store instance, including in visual tests.
  static let defaults: UserDefaults = {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--web-parity-fixture") {
        return UserDefaults(suiteName: "com.riskon.visual-fixture.floating")!
      }
    #endif
    return .standard
  }()
}

/// Arming inline playback must not open a second window until the app actually leaves the foreground.
enum FloatingPiPActivation: Equatable {
  case disabled, inline, external

  static func requested(enabled: Bool, bound: Bool, inBackground: Bool) -> Self {
    guard enabled && bound else { return .disabled }
    return inBackground ? .external : .inline
  }
}

struct FloatingPosition: Identifiable, Equatable {
  let id: String
  let symbol: String
  let isShort: Bool
  let price: Decimal?
  let profit: Decimal?

  init?(_ row: JSONValue) {
    let symbol = row.value("symbol", fallback: "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !symbol.isEmpty else { return nil }
    self.symbol = symbol
    isShort = row.value("side") == "1"
    id = row.value("id", fallback: symbol + (isShort ? ":short" : ":long"))
    price = Self.decimal(row["current_price"]).flatMap { $0 > 0 ? $0 : nil }
    profit = Self.decimal(row["pnl"])
  }

  var priceText: String { price.map { DisplayNumber.text($0) } ?? "--" }
  var profitText: String {
    profit.map { DisplayNumber.text($0, signed: true) + " U" } ?? "--"
  }

  private static func decimal(_ value: JSONValue?) -> Decimal? {
    guard let number = value?.decimal, !number.isNaN else { return nil }
    return number
  }

}

/// Owns only read-only snapshots. A reset invalidates in-flight responses, including failures.
@MainActor
final class FloatingPositionsModel: ObservableObject {
  @Published private(set) var positions: [FloatingPosition] = []
  @Published private(set) var scope = ""
  @Published private(set) var hasLoaded = false
  @Published private(set) var failed = false
  @Published private(set) var updatedAt: Date?
  private var requestID: UUID?

  func reset(scope: String) {
    requestID = nil
    self.scope = scope
    positions = []
    hasLoaded = false
    failed = false
    updatedAt = nil
  }

  func refresh(_ store: USDTStore) async {
    let scope = store.scope
    guard self.scope == scope, requestID == nil else { return }
    let id = UUID()
    requestID = id
    defer { if requestID == id { requestID = nil } }
    do {
      let response = try await store.get("/v1/position/list")
      guard case .array = response else { throw APIError.invalidResponse }
      guard !Task.isCancelled, self.scope == scope, store.scope == scope, requestID == id else {
        return
      }
      positions = response.rows.compactMap(FloatingPosition.init)
      hasLoaded = true
      failed = false
      updatedAt = Date()
    } catch {
      guard !Task.isCancelled, self.scope == scope, store.scope == scope, requestID == id else {
        return
      }
      // Never present an old price as current after an unsuccessful update.
      positions = []
      hasLoaded = true
      failed = true
      updatedAt = nil
    }
  }
}

enum FloatingPanelPlacement {
  static let size = CGSize(width: 184, height: 82)
  static func bounds(in available: CGSize) -> CGRect {
    let left = min(available.width / 2, size.width / 2 + 12)
    let top = min(available.height / 2, size.height / 2 + 12)
    return CGRect(
      x: left, y: top,
      width: max(0, available.width - left * 2),
      height: max(0, available.height - top - size.height / 2 - 76))
  }
  static func center(in available: CGSize, fraction: CGPoint, translation: CGSize = .zero) -> CGPoint {
    let bounds = bounds(in: available)
    return CGPoint(
      x: min(bounds.maxX, max(bounds.minX, bounds.minX + bounds.width * fraction.x + translation.width)),
      y: min(bounds.maxY, max(bounds.minY, bounds.minY + bounds.height * fraction.y + translation.height)))
  }
  static func fraction(for center: CGPoint, in available: CGSize) -> CGPoint {
    let bounds = bounds(in: available)
    return CGPoint(
      x: bounds.width > 0 ? min(1, max(0, (center.x - bounds.minX) / bounds.width)) : 0.5,
      y: bounds.height > 0 ? min(1, max(0, (center.y - bounds.minY) / bounds.height)) : 0.5)
  }
}

private struct FloatingPositionsOverlay: ViewModifier {
  @EnvironmentObject private var store: USDTStore
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage(FloatingPositionsPreferences.enabledKey, store: FloatingPositionsPreferences.defaults)
  private var enabled = false
  @AppStorage("integrated.floatingPositions.x", store: FloatingPositionsPreferences.defaults)
  private var x = 1.0
  @AppStorage("integrated.floatingPositions.y", store: FloatingPositionsPreferences.defaults)
  private var y = 0.22
  @StateObject private var model = FloatingPositionsModel()
  @StateObject private var pip = FloatingPositionsPiP()
  @State private var selectedID: String?
  @GestureState private var translation = CGSize.zero

  private var active: Bool { enabled && scenePhase == .active }
  private var refreshing: Bool { enabled && store.isBound && (scenePhase == .active || pip.keepsUpdating) }
  private var context: String { enabled && store.isBound ? store.scope : "" }
  private var activation: FloatingPiPActivation {
    .requested(enabled: enabled, bound: store.isBound, inBackground: scenePhase == .background)
  }
  private var positions: [FloatingPosition] { store.isBound && model.scope == store.scope ? model.positions : [] }
  private var index: Int { positions.firstIndex { $0.id == selectedID } ?? 0 }
  private var selected: FloatingPosition? { positions.isEmpty ? nil : positions[index] }
  private var snapshot: FloatingPiPSnapshot {
    FloatingPiPSnapshot(positions: positions, selectedIndex: index,
      updatedAt: model.scope == store.scope ? model.updatedAt : nil, status: status)
  }
  private var status: String {
    if !store.isBound { return "请先绑定 API" }
    if model.scope != store.scope || !model.hasLoaded { return "正在同步…" }
    return model.failed ? "更新失败，重试中" : "暂无持仓"
  }

  func body(content: Content) -> some View {
    content.overlay {
      GeometryReader { geometry in
        if enabled {
          ZStack {
            FloatingPiPSource(controller: pip)
            if !pip.isActive { panel }
          }
            .frame(width: FloatingPanelPlacement.size.width, height: FloatingPanelPlacement.size.height)
            // Keep the AVKit source attached for PiP, while hiding its inline system placeholder.
            .opacity(pip.isActive ? 0 : 1)
            .allowsHitTesting(active && !pip.isActive)
            .position(FloatingPanelPlacement.center(
              in: geometry.size, fraction: CGPoint(x: x, y: y), translation: translation))
            .gesture(DragGesture(minimumDistance: 6)
              .updating($translation) { value, state, _ in state = value.translation }
              .onEnded { value in
                let center = FloatingPanelPlacement.center(
                  in: geometry.size, fraction: CGPoint(x: x, y: y), translation: value.translation)
                let fraction = FloatingPanelPlacement.fraction(for: center, in: geometry.size)
                x = fraction.x
                y = fraction.y
              })
        }
      }
    }
    .task(id: "\(context):\(refreshing)") {
      if model.scope != context { model.reset(scope: context) }
      guard refreshing else { return }
      while !Task.isCancelled {
        await model.refresh(store)
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
      }
    }
    .onChange(of: store.liveRevision) { _, _ in
      guard refreshing else { return }
      Task { await model.refresh(store) }
    }
    .onChange(of: snapshot) { _, value in pip.update(value) }
    .onChange(of: activation, initial: true) { _, value in
      apply(value)
    }
    .onChange(of: store.scope) { _, _ in
      pip.stop()
      apply(activation)
    }
    .onAppear { pip.onSystemClose = { enabled = false }; pip.update(snapshot) }
    .onDisappear { pip.onSystemClose = nil; model.reset(scope: ""); pip.stop() }
    .alert("跨 App 浮窗", isPresented: Binding(get: { pip.notice != nil }, set: { showing in
      if !showing { Task { @MainActor in pip.notice = nil } }
    })) {
      Button("知道了", role: .cancel) {}
    } message: { Text(pip.notice ?? "") }
  }

  private func apply(_ activation: FloatingPiPActivation) {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--fixture-inline-floating") {
        pip.stop()
        return
      }
    #endif
    switch activation {
    case .disabled: pip.stop()
    case .inline: pip.prepareForAutomaticStart()
    case .external: pip.start()
    }
  }

  private var panel: some View {
    VStack(spacing: 4) {
      HStack(spacing: 4) {
        Button {
          guard positions.count > 1 else { return }
          selectedID = positions[(index + 1) % positions.count].id
        } label: {
          HStack(spacing: 4) {
            Text(selected?.symbol ?? "持仓浮窗").font(.system(size: 12, weight: .semibold))
              .lineLimit(1).minimumScaleFactor(0.7)
              .accessibilityIdentifier("floating.position.symbol")
            if let selected {
              Text(selected.isShort ? "空" : "多").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(selected.isShort ? WebTheme.danger : WebTheme.success)
            }
            Spacer(minLength: 0)
            if positions.count > 1 {
              Text("\(index + 1)/\(positions.count)").font(.system(size: 9)).foregroundStyle(WebTheme.muted)
            }
          }.frame(maxWidth: .infinity).frame(height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("切换浮窗持仓")
          .accessibilityValue("\(selected?.symbol ?? "") \(index + 1)/\(max(1, positions.count))")
          .accessibilityIdentifier("floating.positions.next")
        Button { pip.start() } label: {
          Image(systemName: "pip.enter").font(.system(size: 12)).frame(width: 22, height: 24)
        }.buttonStyle(.plain).accessibilityLabel("切换到其他 App 显示")
          .accessibilityIdentifier("floating.positions.pip")
        Button { enabled = false } label: {
          WebIcon("x", size: 12).frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("关闭持仓浮窗")
          .accessibilityIdentifier("floating.positions.close")
      }
      if let selected {
        HStack(spacing: 8) {
          metric("市价", selected.priceText, color: WebTheme.text, identifier: "floating.position.price")
          Spacer(minLength: 0)
          metric("浮盈", selected.profitText,
            color: selected.profit.map { $0 < 0 ? WebTheme.danger : WebTheme.success } ?? WebTheme.muted,
            identifier: "floating.position.profit")
        }
      } else {
        Text(status).font(.system(size: 12)).foregroundStyle(WebTheme.muted)
          .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
      }
    }.padding(8).frame(width: FloatingPanelPlacement.size.width, height: FloatingPanelPlacement.size.height)
      .foregroundStyle(WebTheme.text)
      .background(WebTheme.surface, in: RoundedRectangle(cornerRadius: 12))
      .overlay { RoundedRectangle(cornerRadius: 12).stroke(WebTheme.border, lineWidth: 1) }
      .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
      .contentShape(RoundedRectangle(cornerRadius: 12))
      .accessibilityElement(children: .contain).accessibilityIdentifier("floating.positions.panel")
  }

  private func metric(_ title: String, _ value: String, color: Color, identifier: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.system(size: 9)).foregroundStyle(WebTheme.muted)
      Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.65)
        .accessibilityIdentifier(identifier)
    }
  }
}

extension View {
  func floatingPositionsOverlay() -> some View { modifier(FloatingPositionsOverlay()) }
}
