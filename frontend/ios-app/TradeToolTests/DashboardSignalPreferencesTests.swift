import Foundation
import XCTest
@testable import TradeTool

@MainActor
final class DashboardSignalPreferencesTests: XCTestCase {
    func testColdNotificationRestoreWaitsForPreferencesAndHidesDisabledIntervals() async {
        let hourly = signal(interval: "1h")
        let fourHourly = signal(interval: "4h")
        let client = SignalPreferencesAPIClient(
            preferences: .init(
                fifteenMinuteEnabled: false,
                oneHourEnabled: true,
                fourHourEnabled: false
            ),
            signals: [fourHourly, hourly]
        )
        let viewModel = viewModel(client: client)
        defer { viewModel.stopRealtime() }

        viewModel.restoreNotificationSignal(fourHourly)
        XCTAssertTrue(viewModel.signals.isEmpty)
        await viewModel.loadSignalsIfNeeded()

        XCTAssertEqual(viewModel.signals.map(\.id), [hourly.id])
        viewModel.restoreNotificationSignal(fourHourly)
        XCTAssertEqual(viewModel.signals.map(\.id), [hourly.id])
    }

    func testColdNotificationRestoreKeepsAnEnabledSignalOutsideLatestPage() async {
        let notification = signal(interval: "4h")
        let client = SignalPreferencesAPIClient(preferences: .allEnabled, signals: [])
        let viewModel = viewModel(client: client)
        defer { viewModel.stopRealtime() }

        viewModel.restoreNotificationSignal(notification)
        XCTAssertTrue(viewModel.signals.isEmpty)
        await viewModel.loadSignalsIfNeeded()

        XCTAssertEqual(viewModel.signals.map(\.id), [notification.id])
    }

    func testSavingPreferencesInvalidatesOldPaginationAndReloadsReenabledHistory() async {
        let hourly = signal(interval: "1h")
        let fourHourly = signal(interval: "4h")
        let client = SignalPreferencesAPIClient(
            preferences: .allEnabled,
            signals: [fourHourly, hourly],
            hasNext: true
        )
        let viewModel = viewModel(client: client)
        defer { viewModel.stopRealtime() }
        await viewModel.loadSignalsIfNeeded()

        let oldPage = Task { await viewModel.loadMoreSignals() }
        await client.waitForPagination()
        let hourlyOnly = SignalNotificationPreferences(
            fifteenMinuteEnabled: false,
            oneHourEnabled: true,
            fourHourEnabled: false
        )
        await client.configure(preferences: hourlyOnly, signals: [hourly])
        await viewModel.updateSignalNotificationPreferences(hourlyOnly)
        await client.completePagination(signals: [signal(interval: "4h")])
        await oldPage.value

        XCTAssertEqual(viewModel.signals.map(\.id), [hourly.id])
        XCTAssertFalse(viewModel.hasMoreSignals)
        XCTAssertFalse(viewModel.isLoadingMoreSignals)

        await client.configure(preferences: .allEnabled, signals: [fourHourly, hourly])
        await viewModel.updateSignalNotificationPreferences(.allEnabled)
        XCTAssertEqual(viewModel.signals.map(\.id), [fourHourly.id, hourly.id])
    }

    private func viewModel(client: SignalPreferencesAPIClient) -> DashboardViewModel {
        let viewModel = DashboardViewModel(
            apiClient: client,
            realtimeClient: RealtimeClient(
                baseURL: URL(string: "https://example.invalid")!,
                tokenProvider: { nil }
            )
        )
        viewModel.startRealtime(userID: "signal-preferences-user")
        return viewModel
    }

    private func signal(interval: String) -> StrategySignal {
        StrategySignal(
            id: UUID(),
            symbol: "ETHUSDC",
            interval: interval,
            strategyName: "EMA144回踩",
            direction: .short,
            triggerPrice: 2_500,
            triggeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private actor SignalPreferencesAPIClient: APIClient {
    private var preferences: SignalNotificationPreferences
    private var signals: [StrategySignal]
    private var hasNext: Bool
    private var pendingPagination: CheckedContinuation<[StrategySignal], Never>?
    private var paginationWaiter: CheckedContinuation<Void, Never>?

    init(
        preferences: SignalNotificationPreferences,
        signals: [StrategySignal],
        hasNext: Bool = false
    ) {
        self.preferences = preferences
        self.signals = signals
        self.hasNext = hasNext
    }

    func configure(preferences: SignalNotificationPreferences, signals: [StrategySignal]) {
        self.preferences = preferences
        self.signals = signals
        hasNext = false
    }

    func waitForPagination() async {
        guard pendingPagination == nil else { return }
        await withCheckedContinuation { paginationWaiter = $0 }
    }

    func completePagination(signals: [StrategySignal]) {
        pendingPagination?.resume(returning: signals)
        pendingPagination = nil
    }

    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        switch request.path {
        case "/api/strategy/notification-preferences":
            data = try encoder.encode(preferences)
        case "/api/strategy/signals":
            if request.queryItems.contains(where: { $0.name == "cursor" }) {
                let olderSignals = await withCheckedContinuation {
                    pendingPagination = $0
                    paginationWaiter?.resume()
                    paginationWaiter = nil
                }
                data = try encoder.encode(Page(items: olderSignals, hasNext: false))
            } else {
                data = try encoder.encode(Page(items: signals, hasNext: hasNext))
            }
        default:
            throw APIError.cancelled
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }

    private struct Page: Encodable {
        var items: [StrategySignal]
        var hasNext: Bool
        var size: Int { 10 }
        var nextCursor: String? { hasNext ? "next-page" : nil }

        enum CodingKeys: String, CodingKey {
            case items, hasNext, size, nextCursor
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(items, forKey: .items)
            try container.encode(hasNext, forKey: .hasNext)
            try container.encode(size, forKey: .size)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
        }
    }
}
