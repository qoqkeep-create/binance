import Foundation

@MainActor
final class ReferenceNotificationsViewModel: ObservableObject {
    @Published private(set) var notifications: [ReferenceTradeNotification] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var loadFailed = false

    private let apiClient: any APIClient
    private var activeUserID: String?
    private var hasLoaded = false
    private var nextCursor: String?
    private var requestRevision = 0

    init(apiClient: any APIClient) {
        self.apiClient = apiClient
    }

    func startSession(userID: String) {
        guard activeUserID != userID else { return }
        reset()
        activeUserID = userID
    }

    func endSession() {
        reset()
        activeUserID = nil
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await loadFirstPage(showsErrorToast: false)
    }

    func refresh() async {
        await loadFirstPage(showsErrorToast: true)
    }

    func loadMore() async {
        guard let activeUserID,
              let nextCursor,
              hasMore,
              !isLoading,
              !isLoadingMore else {
            return
        }

        let revision = requestRevision
        isLoadingMore = true
        loadFailed = false
        defer {
            if requestRevision == revision {
                isLoadingMore = false
            }
        }

        do {
            let response = try await apiClient.send(
                APIRequest<ReferenceTradeNotificationPageResponse>(
                    path: "/api/reference/trade-notifications",
                    queryItems: [
                        URLQueryItem(name: "cursor", value: nextCursor),
                    ],
                    showsErrorToast: false
                )
            )
            guard requestRevision == revision,
                  self.activeUserID == activeUserID,
                  !Task.isCancelled else {
                return
            }
            let existingIDs = Set(notifications.map(\.id))
            notifications.append(contentsOf: response.items.filter {
                !existingIDs.contains($0.id)
            })
            hasMore = response.hasNext
            self.nextCursor = response.nextCursor
        } catch {
            guard requestRevision == revision,
                  self.activeUserID == activeUserID,
                  !Task.isCancelled else {
                return
            }
            loadFailed = true
        }
    }

    private func loadFirstPage(showsErrorToast: Bool) async {
        guard let activeUserID, !isLoading else { return }

        requestRevision += 1
        let revision = requestRevision
        isLoading = true
        isLoadingMore = false
        loadFailed = false
        defer {
            if requestRevision == revision {
                isLoading = false
            }
        }

        do {
            let response = try await apiClient.send(
                APIRequest<ReferenceTradeNotificationPageResponse>(
                    path: "/api/reference/trade-notifications",
                    showsErrorToast: showsErrorToast
                )
            )
            guard requestRevision == revision,
                  self.activeUserID == activeUserID,
                  !Task.isCancelled else {
                return
            }
            notifications = response.items
            hasMore = response.hasNext
            nextCursor = response.nextCursor
            hasLoaded = true
        } catch {
            guard requestRevision == revision,
                  self.activeUserID == activeUserID,
                  !Task.isCancelled else {
                return
            }
            loadFailed = true
        }
    }

    private func reset() {
        requestRevision += 1
        notifications.removeAll()
        isLoading = false
        isLoadingMore = false
        hasMore = false
        loadFailed = false
        hasLoaded = false
        nextCursor = nil
    }
}
