import ActivityKit
import CryptoKit
import SwiftUI

enum PositionLiveIdentity {
  static func key(server: String, userID: String, mode: String) -> String {
    SHA256.hash(data: Data("\(server)|\(userID)|\(mode)".utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  /// Live updates use the server's exchange upl projection, including the initial frame.
  /// App/PiP ticker valuation is independent from the server-managed ActivityKit payload.
  static func content(rows: [JSONValue], at date: Date) -> PositionLiveContentState {
    let positions = rows.compactMap { row -> PositionLiveRow? in
      let symbol = row.value("symbol", fallback: "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !symbol.isEmpty else { return nil }
      let isShort = row.value("side") == "1"
      let id = row.value("id", fallback: symbol + (isShort ? ":short" : ":long"))
      let pnl = row["pnl"]?.decimal.flatMap { $0.isNaN ? nil : $0 }
      let profit = pnl.map { DisplayNumber.text($0, signed: true) + " U" } ?? "--"
      return PositionLiveRow(id: id, symbol: symbol, isShort: isShort, profit: profit)
    }
    return PositionLiveContentState(positions: Array(positions.prefix(4)), totalCount: positions.count,
      updatedAt: Int(date.timeIntervalSince1970), status: positions.isEmpty ? "暂无持仓" : "")
  }

}

/// ActivityKit owns the surface; the server independently refreshes it after app suspension.
@MainActor
final class PositionLiveActivityController: ObservableObject {
  @Published private(set) var isActive = false
  @Published private(set) var isStarting = false
  @Published private(set) var isRegistering = false
  @Published var notice: String?
  private var activity: Activity<PositionLiveActivityAttributes>?
  private var scope = ""
  private var generation = UUID()
  private var registrationID = UUID()
  private var startTask: Task<Void, Never>?
  private var tokenTask: Task<Void, Never>?
  private var stateTask: Task<Void, Never>?
  private var registrationTask: Task<Void, Never>?
  private var frequencyTask: Task<Void, Never>?
  private var api: (any APIClient)?
  private var latestToken: Data?
  private var tokenUpdatedAt: Double = 0
  private let installationID = PushInstallationIdentity.current()

  func toggle(store: USDTStore, container: AppContainer) {
    if isActive || isStarting { stop() }
    else { start(store: store, container: container) }
  }

  func restore(store: USDTStore, container: AppContainer) {
    guard let userID = container.authStore.session?.user.id else { return }
    store.prepareSession(userID: userID, signalReadNamespace: container.baseURL.absoluteString)
    guard activity == nil, !isStarting else { return }
    let owner = PositionLiveIdentity.key(server: container.baseURL.absoluteString,
      userID: userID, mode: store.mode)
    let candidates = Activity<PositionLiveActivityAttributes>.activities
    for old in candidates where old.attributes.ownerKey != owner {
      Task { await old.end(nil, dismissalPolicy: .immediate) }
    }
    guard store.isBound,
      let current = candidates.filter({
        $0.attributes.ownerKey == owner && [.active, .stale].contains($0.activityState)
          && Date().timeIntervalSince1970 - $0.attributes.startedAt < 8 * 60 * 60
      }).max(by: { $0.attributes.startedAt < $1.attributes.startedAt }) else { return }
    for old in candidates where old.id != current.id {
      Task { await old.end(nil, dismissalPolicy: .immediate) }
    }
    scope = store.scope
    api = container.apiClient
    activity = current
    isActive = true
    observe(current, store: store)
  }

  func contextChanged(store: USDTStore) {
    if (isActive || isStarting) && (scope != store.scope || !store.isBound) { stop() }
  }

  func resume(store: USDTStore, container: AppContainer) {
    restore(store: store, container: container)
    if let activity, let token = latestToken ?? activity.pushToken, scope == store.scope {
      register(token, activity: activity, store: store)
    }
  }

  func stop() {
    let old = activity
    let client = api
    generation = UUID()
    startTask?.cancel(); startTask = nil
    tokenTask?.cancel(); tokenTask = nil
    stateTask?.cancel(); stateTask = nil
    registrationTask?.cancel(); registrationTask = nil
    frequencyTask?.cancel(); frequencyTask = nil
    latestToken = nil
    activity = nil
    isActive = false; isStarting = false; isRegistering = false
    if let old {
      let installationID = installationID
      Task {
        await old.end(nil, dismissalPolicy: .immediate)
        if let client {
          let request = try? APIRequest<JSONValue>.json(path: "/api/push/live-activities/unregister",
            method: .post, body: ["installationId": installationID, "activityId": old.id],
            showsErrorToast: false, timeoutInterval: 10)
          if let request { _ = try? await client.send(request) }
        }
      }
    }
  }

  private func start(store: USDTStore, container: AppContainer) {
    guard store.isBound else { notice = "请先绑定 API，再开启 live 持仓卡片。"; return }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      notice = "请在系统设置中允许 Binance Tools 的实时活动。"; return
    }
    guard let userID = container.authStore.session?.user.id else { return }
    guard PushInstallationIdentity.apnsEnvironment != nil else {
      notice = "当前安装包未配置实时活动推送，请使用正式签名的新版本。"; return
    }
    let owner = PositionLiveIdentity.key(server: container.baseURL.absoluteString,
      userID: userID, mode: store.mode)
    scope = store.scope
    api = container.apiClient
    generation = UUID()
    let ticket = generation
    isStarting = true
    notice = nil
    startTask = Task { [weak self] in
      guard let self else { return }
      do {
        let response = try await store.get("/v1/position/list")
        guard case .array = response else { throw APIError.invalidResponse }
        guard !Task.isCancelled, ticket == self.generation, self.scope == store.scope,
          UIApplication.shared.applicationState == .active else {
          if ticket == self.generation { self.isStarting = false }
          return
        }
        let now = Date()
        let state = PositionLiveIdentity.content(rows: response.rows, at: now)
        let current = try Activity.request(
          attributes: PositionLiveActivityAttributes(ownerKey: owner, tradingMode: store.mode,
            startedAt: now.timeIntervalSince1970),
          content: ActivityContent(state: state, staleDate: now.addingTimeInterval(90)), pushType: .token)
        self.activity = current
        self.isActive = true
        self.isStarting = false
        self.observe(current, store: store)
      } catch {
        guard ticket == self.generation, !Task.isCancelled else { return }
        self.isStarting = false
        let mapped = APIError.map(error)
        if mapped.shouldPresent { self.notice = "live 卡片未能开启：\(mapped.userMessage)" }
      }
    }
  }

  private func observe(_ current: Activity<PositionLiveActivityAttributes>, store: USDTStore) {
    tokenTask?.cancel(); stateTask?.cancel(); frequencyTask?.cancel()
    let ticket = generation
    if let token = current.pushToken { register(token, activity: current, store: store) }
    tokenTask = Task { [weak self] in
      for await token in current.pushTokenUpdates {
        guard let self, !Task.isCancelled, ticket == self.generation,
          self.scope == store.scope else { return }
        self.register(token, activity: current, store: store)
      }
    }
    stateTask = Task { [weak self] in
      for await state in current.activityStateUpdates {
        guard let self, !Task.isCancelled, ticket == self.generation else { return }
        if state == .ended || state == .dismissed { self.stop(); return }
      }
    }
    frequencyTask = Task { [weak self] in
      for await _ in ActivityAuthorizationInfo().frequentPushEnablementUpdates {
        guard let self, !Task.isCancelled, ticket == self.generation else { return }
        if let token = self.latestToken { self.register(token, activity: current, store: store) }
      }
    }
  }

  private func register(_ token: Data, activity current: Activity<PositionLiveActivityAttributes>, store: USDTStore) {
    registrationTask?.cancel()
    registrationID = UUID()
    let registration = registrationID
    latestToken = token
    tokenUpdatedAt = max(Date().timeIntervalSince1970, tokenUpdatedAt + 0.000001)
    isRegistering = true
    let ticket = generation
    let body = PositionLiveRegistration(installationId: installationID, activityId: current.id,
      pushToken: token.map { String(format: "%02x", $0) }.joined(),
      environment: PushInstallationIdentity.apnsEnvironment ?? "production",
      bundleIdentifier: PushInstallationIdentity.bundleIdentifier ?? "",
      tradingMode: current.attributes.tradingMode,
      frequentUpdates: ActivityAuthorizationInfo().frequentPushesEnabled,
      startedAt: current.attributes.startedAt, tokenUpdatedAt: tokenUpdatedAt)
    registrationTask = Task { [weak self] in
      guard let self, let api = self.api else { return }
      defer {
        if ticket == self.generation, registration == self.registrationID { self.isRegistering = false }
      }
      var attempt = 0
      while !Task.isCancelled, ticket == self.generation, self.scope == store.scope {
        do {
          let request = try APIRequest<JSONValue>.json(path: "/api/push/live-activities/register",
            method: .post, body: body, showsErrorToast: false, timeoutInterval: 15)
          _ = try await api.send(request)
          guard !Task.isCancelled, ticket == self.generation else { return }
          self.notice = nil
          return
        } catch {
          guard !Task.isCancelled, ticket == self.generation else { return }
          let mapped = APIError.map(error)
          if !mapped.shouldPresent { return }
          switch mapped {
          case .unauthorized, .forbidden, .business, .http(statusCode: 409, message: _):
            self.stop()
            self.notice = "live 卡片已停止：\(mapped.userMessage)"
            return
          default: break
          }
          attempt += 1
          if attempt == 1 {
            self.notice = "live 后台更新暂未连接，正在重试。卡片会标记过期数据。"
          }
          do { try await Task.sleep(for: .seconds(min(60, attempt * 5))) } catch { return }
        }
      }
    }
  }
}

private struct PositionLiveRegistration: Encodable {
  let installationId: String
  let activityId: String
  let pushToken: String
  let environment: String
  let bundleIdentifier: String
  let tradingMode: String
  let frequentUpdates: Bool
  let startedAt: Double
  let tokenUpdatedAt: Double
}

struct PositionLiveActivityLifecycle: ViewModifier {
  @EnvironmentObject private var store: USDTStore
  @EnvironmentObject private var container: AppContainer
  @EnvironmentObject private var live: PositionLiveActivityController
  @Environment(\.scenePhase) private var scenePhase
  func body(content: Content) -> some View {
    content
      .onAppear { live.restore(store: store, container: container) }
      .onChange(of: store.scope) { _, _ in live.contextChanged(store: store) }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { live.resume(store: store, container: container) }
      }
      .onChange(of: store.binding) { _, _ in
        live.contextChanged(store: store)
        live.restore(store: store, container: container)
      }
      .onDisappear { live.stop() }
      .alert("Live 持仓", isPresented: Binding(get: { live.notice != nil }, set: { if !$0 { live.notice = nil } })) {
        Button("知道了", role: .cancel) {}
      } message: { Text(live.notice ?? "") }
  }
}
