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

/// The entry requests an external window immediately; scene changes never create an inline card.
enum FloatingPiPActivation: Equatable {
  case disabled, external

  static func requested(enabled: Bool, bound: Bool) -> Self {
    enabled && bound ? .external : .disabled
  }
}

/// Shared by the controller and host regressions, including the source-readiness gate.
struct FloatingPiPLifecycle: Equatable {
  enum Phase { case stopped, waitingForSource, starting, active }
  private(set) var phase = Phase.stopped
  private var awaitingSystemStop = false
  var isActive: Bool { phase == .active }
  var isStarting: Bool { phase == .waitingForSource || phase == .starting }

  mutating func request() -> Bool {
    guard phase == .stopped else { return false }
    phase = .waitingForSource
    return true
  }

  mutating func issueStart(sourceReady: Bool) -> Bool {
    guard phase == .waitingForSource, sourceReady, !awaitingSystemStop else { return false }
    phase = .starting
    return true
  }

  mutating func didStart() -> Bool {
    guard phase == .starting, !awaitingSystemStop else { return false }
    phase = .active
    return true
  }

  mutating func stop(awaitingSystemStop: Bool = false) {
    self.awaitingSystemStop = self.awaitingSystemStop || awaitingSystemStop
    phase = .stopped
  }

  /// A quick retry waits until AVKit has finished closing the previous window.
  mutating func didStop() -> Bool {
    awaitingSystemStop = false
    if phase == .waitingForSource { return false }
    let requested = isActive || isStarting
    phase = .stopped
    return requested
  }
}

struct FloatingPosition: Identifiable, Equatable {
  let id: String
  let symbol: String
  let isShort: Bool
  let price: Decimal?
  let profit: Decimal?
  let quoteTime: Date?

  init?(_ row: JSONValue, quote: PositionMarketQuote? = nil) {
    let symbol = row.value("symbol", fallback: "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !symbol.isEmpty else { return nil }
    self.symbol = symbol
    isShort = row.value("side") == "1"
    id = row.value("id", fallback: symbol + (isShort ? ":short" : ":long"))
    let valuation = PositionLiveValuation(row: row, quote: quote)
    price = valuation?.price
    profit = valuation?.profit
    quoteTime = quote.map { Date(timeIntervalSince1970: Double($0.eventTime) / 1_000) }
  }

  var priceText: String { price.map { DisplayNumber.text($0) } ?? "--" }
  var profitText: String {
    profit.map { DisplayNumber.amount($0, maximumFractionDigits: 2, signed: true) + " U" } ?? "--"
  }
}

/// One read-only position snapshot is shared by the positions page and the external floating presentation.
@MainActor
final class FloatingPositionsModel: ObservableObject {
  @Published private(set) var rows: [JSONValue] = []
  @Published private(set) var loading = false
  @Published private(set) var scope = ""
  @Published private(set) var hasLoaded = false
  @Published private(set) var failed = false
  @Published private(set) var updatedAt: Date?
  private var requestID: UUID?
  private var refreshTask: Task<Void, Never>?

  func reset(scope: String) {
    refreshTask?.cancel()
    refreshTask = nil
    requestID = nil
    self.scope = scope
    rows = []
    loading = false
    hasLoaded = false
    failed = false
    updatedAt = nil
  }

  func refresh(_ store: USDTStore) async {
    let scope = store.scope
    guard self.scope == scope else { return }
    if let refreshTask { await refreshTask.value; return }
    let id = UUID()
    requestID = id
    loading = true
    // This read belongs to the shared snapshot, not to the first view that requested it.
    // Cancelling an overlay/page task must not cancel another consumer's pending read.
    let task = Task { [weak self] in
      guard let self else { return }
      await self.read(store, scope: scope, requestID: id)
    }
    refreshTask = task
    await task.value
  }

  private func read(_ store: USDTStore, scope: String, requestID id: UUID) async {
    guard self.scope == scope, store.scope == scope, requestID == id else { return }
    defer {
      if requestID == id { requestID = nil; refreshTask = nil; loading = false }
    }
    do {
      let response = try await store.get("/v1/position/list")
      guard case .array = response else { throw APIError.invalidResponse }
      guard !Task.isCancelled, self.scope == scope, store.scope == scope, requestID == id else {
        return
      }
      rows = response.rows
      hasLoaded = true
      failed = false
      updatedAt = Date()
    } catch {
      guard !Task.isCancelled, self.scope == scope, store.scope == scope, requestID == id else {
        return
      }
      // A failed read does not mean a position closed. Keep the shared last-known rows.
      // PiP independently marks a snapshot stale rather than presenting it as a fresh update.
      hasLoaded = true
      failed = true
    }
  }
}

enum FloatingPanelPlacement {
  // The covered source needs stable, nonzero geometry for AVKit readiness.
  static let sourceSize = CGSize(width: 160, height: 120)
}

private struct FloatingPositionsOverlay: ViewModifier {
  @EnvironmentObject private var store: USDTStore
  @EnvironmentObject private var container: AppContainer
  @EnvironmentObject private var dashboard: DashboardViewModel
  @AppStorage(FloatingPositionsPreferences.enabledKey, store: FloatingPositionsPreferences.defaults)
  private var enabled = false
  private var model: FloatingPositionsModel { store.positionSnapshots }
  @StateObject private var pip = FloatingPositionsPiP()
  private var refreshing: Bool { enabled && store.isBound && pip.keepsUpdating }
  private var context: String { enabled && store.isBound ? store.scope : "" }
  private var activation: FloatingPiPActivation {
    .requested(enabled: enabled, bound: store.isBound)
  }
  private var positions: [FloatingPosition] {
    guard store.isBound, model.scope == store.scope else { return [] }
    return model.rows.compactMap { row in
      FloatingPosition(row, quote: store.positionQuotes.quotes[row.value("symbol").uppercased()])
    }
  }
  private var tickerSymbols: [String] {
    guard refreshing, model.scope == store.scope else { return [] }
    return Array(Set(model.rows.map { $0.value("symbol", fallback: "").uppercased() }
      .filter { !$0.isEmpty })).sorted()
  }
  private var snapshot: FloatingPiPSnapshot {
    FloatingPiPSnapshot(positions: positions,
      updatedAt: model.scope == store.scope ? model.updatedAt : nil, status: status)
  }
  private var status: String {
    if !store.isBound { return "请先绑定 API" }
    if model.scope != store.scope || !model.hasLoaded { return "正在同步…" }
    return model.failed ? "更新失败，重试中" : "暂无持仓"
  }

  func body(content: Content) -> some View {
    content.background(alignment: .bottomTrailing) {
      // Keep a nonzero, attached source with normal visibility for AVKit readiness.
      // An opaque sibling covers its video and system placeholder; no inline card exists.
      ZStack {
        FloatingPiPSource(controller: pip)
        BinanceTheme.navigationBackground
      }.frame(width: FloatingPanelPlacement.sourceSize.width, height: FloatingPanelPlacement.sourceSize.height)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
    .task(id: "\(context):\(refreshing)") {
      guard refreshing else { return }
      while !Task.isCancelled {
        await store.refreshPositions()
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
      }
    }
    .task(id: "floating-quotes:\(store.scope):\(tickerSymbols.joined(separator: ","))") {
      let symbols = tickerSymbols
      let session = store.positionQuotes.begin(scope: store.scope, symbols: symbols, owner: "floating")
      dashboard.trackPositionTickerSymbols(symbols, owner: "floating")
      defer {
        if store.positionQuotes.end(session) { dashboard.trackPositionTickerSymbols([], owner: "floating") }
      }
      guard !symbols.isEmpty else { return }
      for await event in container.realtimeClient.events(bufferingPolicy: .bufferingNewest(256)) {
        guard !Task.isCancelled else { break }
        if container.realtimeClient.state == .connected { store.positionQuotes.receive(event, session: session) }
      }
    }
    .onChange(of: store.liveRevision) { _, _ in
      guard refreshing else { return }
      Task { await store.refreshPositions() }
    }
    .onChange(of: snapshot) { _, value in if enabled { pip.update(value) } }
    .onChange(of: enabled) { _, value in
      guard value, !store.isBound else { return }
      enabled = false
      container.toastCenter.present("请先绑定 API，再开启持仓浮窗。")
    }
    .onChange(of: activation, initial: true) { _, value in
      apply(value)
    }
    .onChange(of: store.scope) { _, _ in
      enabled = false
      pip.stop()
    }
    .onAppear { pip.onSystemClose = { enabled = false } }
    .onDisappear { pip.onSystemClose = nil; enabled = false; pip.stop() }
    .onChange(of: pip.notice) { _, message in
      guard let message else { return }
      enabled = false
      container.toastCenter.present(message)
      pip.notice = nil
    }
  }

  private func apply(_ activation: FloatingPiPActivation) {
    switch activation {
    case .disabled: pip.stop()
    case .external: pip.update(snapshot); pip.start()
    }
  }

}

extension View {
  func floatingPositionsOverlay() -> some View { modifier(FloatingPositionsOverlay()) }
}
