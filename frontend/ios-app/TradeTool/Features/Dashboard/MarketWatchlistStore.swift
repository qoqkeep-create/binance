import Foundation

struct MarketWatchlistPreferences: Codable, Equatable {
    let quoteAsset: String
    let orderedSymbols: [String]
    let visibleSymbols: Set<String>
    let pinnedSymbols: Set<String>
    let isCustomized: Bool
    var needsSync: Bool? = nil
}

protocol MarketWatchlistStoring {
    func load(for userID: String) -> MarketWatchlistPreferences?
    func save(
        _ preferences: MarketWatchlistPreferences,
        for userID: String
    )
}

final class UserDefaultsMarketWatchlistStore: MarketWatchlistStoring {
    private let defaults: UserDefaults
    private let keyPrefix: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        service: String,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        keyPrefix = "\(service).market-watchlist.v3"
    }

    func load(for userID: String) -> MarketWatchlistPreferences? {
        guard let data = defaults.data(forKey: key(for: userID)) else {
            return nil
        }

        return try? decoder.decode(
            MarketWatchlistPreferences.self,
            from: data
        )
    }

    func save(
        _ preferences: MarketWatchlistPreferences,
        for userID: String
    ) {
        guard let data = try? encoder.encode(preferences) else {
            return
        }

        defaults.set(data, forKey: key(for: userID))
    }

    private func key(for userID: String) -> String {
        "\(keyPrefix).\(userID)"
    }
}
