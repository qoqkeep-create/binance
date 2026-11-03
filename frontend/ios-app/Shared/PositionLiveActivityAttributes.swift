import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

struct PositionLiveRow: Codable, Hashable, Identifiable, Sendable {
  let id: String
  let symbol: String
  let isShort: Bool
  let profit: String
}

/// Shared wire schema: dates are Unix seconds so APNs and ActivityKit decode identically.
struct PositionLiveContentState: Codable, Hashable, Sendable {
  static let freshnessInterval = 90
  let positions: [PositionLiveRow]
  let totalCount: Int
  let updatedAt: Int
  let status: String

  var updatedDate: Date { Date(timeIntervalSince1970: TimeInterval(updatedAt)) }
  func isExpired(at now: Date) -> Bool {
    updatedAt <= 0 || now.timeIntervalSince(updatedDate) > Double(Self.freshnessInterval)
  }
}

#if os(iOS) && canImport(ActivityKit)
struct PositionLiveActivityAttributes: ActivityAttributes {
  typealias ContentState = PositionLiveContentState
  /// Opaque account/server identity; never contains credentials or a visible account name.
  let ownerKey: String
  let tradingMode: String
  let startedAt: Double
}
#endif
