import Foundation
import Combine

struct PositionMarketQuote: Equatable {
  let price: Decimal
  let eventTime: Int64

}

/// USD-M quantities are base-asset units, including multiplier symbols such as 1000SHIB.
struct PositionLiveValuation: Equatable {
  let price: Decimal
  let profit: Decimal

  init?(row: JSONValue, quote: PositionMarketQuote?) {
    guard let quote, quote.price > 0, !quote.price.isNaN,
      ["0", "1"].contains(row.value("side")),
      let entry = row["open_price"]?.decimal, !entry.isNaN, entry > 0,
      let quantity = (row["exchange_size"] ?? row["size"])?.decimal,
      !quantity.isNaN, quantity > 0 else { return nil }
    price = quote.price
    profit = (row.value("side") == "0" ? price - entry : entry - price) * quantity
  }
}

@MainActor
final class PositionLiveQuotes: ObservableObject {
  @Published private(set) var quotes: [String: PositionMarketQuote] = [:]
  private var symbols: Set<String> = []
  private var generation = UUID()

  func begin(symbols: [String]) -> UUID {
    generation = UUID()
    self.symbols = Set(symbols.map { $0.uppercased() })
    clear()
    return generation
  }

  @discardableResult
  func end(_ session: UUID) -> Bool {
    guard session == generation else { return false }
    generation = UUID()
    symbols = []
    clear()
    return true
  }

  func clear() {
    if !quotes.isEmpty { quotes = [:] }
  }

  func receive(_ message: RealtimeServerMessage, session: UUID, now: Date = .now) {
    guard session == generation else { return }
    if message.type == "ready" { clear(); return }
    guard message.type == "event", message.channel == "market.ticker",
      let data = message.data,
      let symbol = data["symbol"]?.text.uppercased(), symbols.contains(symbol),
      let price = data["lastPrice"]?.decimal, !price.isNaN, price > 0,
      let time = data["eventTime"].flatMap({ Int64($0.text) }), time > 0 else { return }
    let quote = PositionMarketQuote(price: price, eventTime: time)
    let age = now.timeIntervalSince1970 - Double(time) / 1_000
    guard age >= -5, age <= 30,
      quotes[symbol].map({ $0.eventTime < time }) ?? true else { return }
    quotes[symbol] = quote
  }
}
