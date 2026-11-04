#!/usr/bin/env python3
"""Run actual App notification preference and cancellation logic on macOS.

The production notification manager and API request/protocol are extracted.
Only access control is widened; UIKit, UserNotifications and HTTP transport use
in-memory platform fixtures. No real registration, push or network send occurs.
Pass an output directory to retain the generated package and input hashes, or
omit it to use a temporary directory. No simulator is started.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile

IOS = Path(__file__).resolve().parents[1]
APP = IOS / "TradeTool"


def generate(destination):
    app = APP
    out = destination
    (out / 'Sources/NotificationChecks').mkdir(parents=True, exist_ok=True)
    (out / 'Tests/NotificationChecksTests').mkdir(parents=True, exist_ok=True)

    def block(text, marker):
        start = text.index(marker)
        opening = text.index('{', start)
        depth = 0
        for index in range(opening, len(text)):
            if text[index] == '{': depth += 1
            if text[index] == '}':
                depth -= 1
                if depth == 0: return text[start:index + 1]
        raise ValueError(marker)

    container = app / 'App/AppContainer.swift'
    source = container.read_text()
    manager = '@MainActor\n' + block(source, 'final class StrategySignalNotificationManager:')
    # Only access control is widened. The production method bodies stay unchanged.
    manager = manager.replace('private(set) ', '').replace('private ', '')
    manager += '\n' + block(source, 'private struct PushDeviceRegistrationBody:').replace('private ', '')
    manager += '\n' + block(source, 'private struct PushDeviceIdentityBody:').replace('private ', '')
    (out / 'Sources/NotificationChecks/Manager.swift').write_text('import Foundation\nimport Combine\n' + manager + '\n')
    api = app / 'Core/Networking/APIClient.swift'
    (out / 'Sources/NotificationChecks/APIClient.swift').write_text(api.read_text().split('struct URLSessionAPIClient', 1)[0])
    request = app / 'Core/Networking/APIRequest.swift'
    (out / 'Sources/NotificationChecks/APIRequest.swift').write_text(request.read_text())
    (out / 'Package.swift').write_text('''// swift-tools-version: 6.0
    import PackageDescription
    let package = Package(name: "NotificationChecks", platforms: [.macOS(.v14)], targets: [
      .target(name: "NotificationChecks"),
      .testTarget(name: "NotificationChecksTests", dependencies: ["NotificationChecks"])
    ], swiftLanguageModes: [.v5])
    ''')
    (out / 'Sources/NotificationChecks/PlatformBoundaries.swift').write_text('''import Foundation
    struct RequestDiagnostics {}
    enum APIError: Error { case requestEncoding, invalidURL, invalidResponse }
    struct StrategySignal: Equatable, Sendable {
      enum Direction: String, Sendable { case long, short }
      let id: UUID
      let symbol: String
      let interval: String
      let strategyName: String
      let direction: Direction
      let triggerPrice: Double
      let triggeredAt: Date
    }
    enum MarketKlineInterval: String { case oneHour = "1h" }
    enum SignalNotificationDestination: Equatable, Sendable {
      case strategy(StrategySignal)
      case positions(tradingMode: String?)
    }
    struct SignalNotificationNavigationRequest: Equatable, Sendable {
      let id: UUID
      let destination: SignalNotificationDestination
    }
    enum UNAuthorizationStatus { case notDetermined, denied, authorized, provisional, ephemeral }
    struct UNNotificationSettings { let authorizationStatus: UNAuthorizationStatus }
    struct UNAuthorizationOptions: OptionSet {
      let rawValue: Int
      static let alert = Self(rawValue: 1)
      static let sound = Self(rawValue: 2)
    }
    struct UNNotificationPresentationOptions: OptionSet {
      let rawValue: Int
      static let banner = Self(rawValue: 1)
      static let list = Self(rawValue: 2)
      static let sound = Self(rawValue: 4)
    }
    protocol UNUserNotificationCenterDelegate: AnyObject {}
    struct UNNotificationContent { let userInfo: [AnyHashable: Any] }
    struct UNNotificationRequest { let content: UNNotificationContent }
    struct UNNotification { let request: UNNotificationRequest }
    struct UNNotificationResponse { let notification: UNNotification }
    final class UNUserNotificationCenter {
      static func current() -> UNUserNotificationCenter { UNUserNotificationCenter() }
      weak var delegate: UNUserNotificationCenterDelegate?
      var status: UNAuthorizationStatus = .authorized
      var prompts = 0
      var clears = 0
      var pausePrompt = false
      var promptStarted: CheckedContinuation<Void, Never>?
      var prompt: CheckedContinuation<Bool, Never>?
      func notificationSettings() async -> UNNotificationSettings { .init(authorizationStatus: status) }
      func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        prompts += 1
        if pausePrompt {
          return await withCheckedContinuation { continuation in
            prompt = continuation
            promptStarted?.resume(); promptStarted = nil
          }
        }
        status = .authorized
        return true
      }
      func waitForPrompt() async {
        if prompt != nil { return }
        await withCheckedContinuation { promptStarted = $0 }
      }
      func completePrompt(authorized: Bool) {
        status = authorized ? .authorized : .denied
        prompt?.resume(returning: authorized); prompt = nil
      }
      func removeAllDeliveredNotifications() { clears += 1 }
    }
    @MainActor
    final class UIApplication {
      static let shared = UIApplication()
      var registrations = 0
      func registerForRemoteNotifications() { registrations += 1 }
    }
    enum PushInstallationIdentity {
      static func current(userDefaults: UserDefaults) -> String { "fixture-installation" }
      static let apnsEnvironment: String? = "sandbox"
      static let bundleIdentifier: String? = "local.notification.fixture"
    }
    extension Notification.Name {
      static let apnsDeviceTokenReceived = Notification.Name("FixtureToken")
      static let apnsRegistrationFailed = Notification.Name("FixtureRegistrationFailure")
    }
    ''')
    (out / 'Tests/NotificationChecksTests/NotificationChecksTests.swift').write_text('''import Foundation
    import XCTest
    @testable import NotificationChecks
    @MainActor
    final class NotificationChecksTests: XCTestCase {
      func testOneSavedPreferenceRestoresAndDefaultsToEnabled() async {
        let (manager, center, api, defaults) = fixture()
        defer { clean(manager, defaults) }
        XCTAssertTrue(manager.isEnabled)
        manager.setEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: StrategySignalNotificationManager.enabledDefaultsKey))
        XCTAssertFalse(manager.isEnabled)
        let restored = StrategySignalNotificationManager(apiClient: api, notificationCenter: center, userDefaults: defaults)
        XCTAssertFalse(restored.isEnabled)
        XCTAssertEqual(UIApplication.shared.registrations, 0)
      }
      func testDeniedSystemPermissionDoesNotBecomeGrantedOrOverwritePreference() async {
        let (manager, center, api, defaults) = fixture()
        defer { clean(manager, defaults) }
        center.status = .denied
        manager.activateSession()
        await manager.authorizationTask?.value
        await manager.registrationTask?.value
        XCTAssertTrue(manager.isEnabled)
        XCTAssertTrue(manager.systemNotificationsDenied)
        XCTAssertEqual(center.prompts, 0)
        XCTAssertEqual(UIApplication.shared.registrations, 0)
        XCTAssertEqual(api.paths, ["/api/push/devices/unregister"])
        XCTAssertNil(defaults.object(forKey: StrategySignalNotificationManager.enabledDefaultsKey))
      }
      func testOpeningSettingsOnlyRechecksAndDoesNotPrompt() async {
        let (manager, center, _, defaults) = fixture()
        defer { clean(manager, defaults) }
        manager.isSessionActive = true
        center.status = .notDetermined
        await manager.refreshAuthorizationStatus()
        XCTAssertEqual(center.prompts, 0)
        XCTAssertEqual(UIApplication.shared.registrations, 0)
      }
      func testAuthorizedEnableRegistersDeviceAndDisableUsesExistingUnregister() async {
        let (manager, center, api, defaults) = fixture()
        defer { clean(manager, defaults) }
        manager.activateSession()
        await manager.authorizationTask?.value
        XCTAssertEqual(UIApplication.shared.registrations, 1)
        manager.receivedDeviceToken("fixture-token")
        await manager.registrationTask?.value
        XCTAssertEqual(api.paths, ["/api/push/devices/register"])
        manager.setEnabled(false)
        await manager.registrationTask?.value
        XCTAssertEqual(api.paths, ["/api/push/devices/register", "/api/push/devices/unregister"])
        XCTAssertEqual(api.methods, [.post, .post])
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(center.clears, 1)
      }
      func testSwitchingOffWhileSystemPromptWaitsCannotRegisterAfterReply() async {
        let (manager, center, api, defaults) = fixture()
        defer { clean(manager, defaults) }
        center.status = .notDetermined
        center.pausePrompt = true
        manager.activateSession()
        await center.waitForPrompt()
        let waiting = manager.authorizationTask
        manager.setEnabled(false)
        center.completePrompt(authorized: true)
        await waiting?.value
        await manager.registrationTask?.value
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(UIApplication.shared.registrations, 0)
        XCTAssertEqual(api.paths, ["/api/push/devices/unregister"])
      }
      func testReturningFromSystemSettingsRefreshesPermissionAndRegistration() async {
        let (manager, center, _, defaults) = fixture()
        defer { clean(manager, defaults) }
        center.status = .denied
        manager.activateSession()
        await manager.authorizationTask?.value
        await manager.registrationTask?.value
        center.status = .authorized
        await manager.refreshAuthorizationStatus()
        XCTAssertFalse(manager.systemNotificationsDenied)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(center.prompts, 0)
        XCTAssertEqual(UIApplication.shared.registrations, 1)
      }
      func testDisabledPreferenceSuppressesForegroundPresentation() async {
        let (manager, center, _, defaults) = fixture()
        defer { clean(manager, defaults) }
        manager.setEnabled(false)
        let notification = UNNotification(request: .init(content: .init(userInfo: ["route": "strategy.signal", "source": "internal"])))
        let options = await manager.userNotificationCenter(center, willPresent: notification)
        XCTAssertTrue(options.isEmpty)
      }
      func testCancellingRetryDelayCannotSendAnotherRequest() async {
        let (manager, _, _, defaults) = fixture()
        defer { clean(manager, defaults) }
        var attempts = 0
        let started = expectation(description: "first in-memory attempt")
        let work = Task {
          await manager.retryingRequest {
            attempts += 1
            if attempts == 1 { started.fulfill() }
            throw APIError.invalidResponse
          }
        }
        await fulfillment(of: [started], timeout: 1)
        work.cancel()
        await work.value
        XCTAssertEqual(attempts, 1)
      }
      private func fixture() -> (StrategySignalNotificationManager, UNUserNotificationCenter, MemoryAPI, UserDefaults) {
        UIApplication.shared.registrations = 0
        let defaults = UserDefaults(suiteName: "NotificationChecks." + UUID().uuidString)!
        let center = UNUserNotificationCenter()
        let api = MemoryAPI()
        let manager = StrategySignalNotificationManager(apiClient: api, notificationCenter: center, userDefaults: defaults)
        return (manager, center, api, defaults)
      }
      private func clean(_ manager: StrategySignalNotificationManager, _ defaults: UserDefaults) {
        manager.deactivateSession()
        defaults.removeObject(forKey: StrategySignalNotificationManager.enabledDefaultsKey)
      }
    }
    @MainActor
    private final class MemoryAPI: APIClient {
      var paths: [String] = []
      var methods: [HTTPMethod] = []
      func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        guard ["/api/push/devices/register", "/api/push/devices/unregister"].contains(request.path) else {
          XCTFail("Unexpected API path"); throw APIError.invalidResponse
        }
        paths.append(request.path); methods.append(request.method)
        return try JSONDecoder().decode(Response.self, from: Data("{}".utf8))
      }
    }
    ''')
    (out / 'production-inputs.json').write_text(json.dumps({
        'sources': {str(p.relative_to(IOS)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [container, api, request]},
        'test_count': 8, 'network': False, 'simulator': False,
        'changes': ['Access control only', 'UIKit/UserNotifications replaced at platform boundary']
    }, indent=2) + '\n')
    print('Extracted actual notification manager + request/protocol for 8 isolated host tests')


def run(destination):
    generate(destination)
    return subprocess.run(["swift", "test", "--package-path", str(destination)], check=False).returncode


if __name__ == "__main__":
    if len(sys.argv) > 1:
        target = Path(sys.argv[1]).resolve()
        target.mkdir(parents=True, exist_ok=True)
        sys.exit(run(target))
    with tempfile.TemporaryDirectory(prefix="notification-preferences-") as directory:
        sys.exit(run(Path(directory)))
