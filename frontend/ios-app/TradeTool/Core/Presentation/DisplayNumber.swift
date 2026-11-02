import Foundation

/// Presentation only. Order inputs and payloads retain their original precision.
enum DisplayNumber {
  private static let locale = Locale(identifier: "en_US_POSIX")

  static func text(_ value: String, signed: Bool = false, grouped: Bool = false) -> String {
    let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard source.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
      options: .regularExpression) != nil, let number = Decimal(string: source, locale: locale)
    else { return "--" }
    return text(number, signed: signed, grouped: grouped)
  }

  static func text(_ value: Double, signed: Bool = false, grouped: Bool = false) -> String {
    guard value.isFinite, let number = Decimal(string: String(value), locale: locale) else { return "--" }
    return text(number, signed: signed, grouped: grouped)
  }

  static func text(_ value: Decimal, signed: Bool = false, grouped: Bool = false) -> String {
    guard !value.isNaN else { return "--" }
    var source = value
    var rounded = Decimal()
    var digits = fractionDigits(abs(value))
    NSDecimalRound(&rounded, &source, digits, .plain)
    // A carry can cross a display band or change the number of leading zeroes.
    digits = fractionDigits(abs(rounded))
    source = rounded
    NSDecimalRound(&rounded, &source, digits, .plain)
    let raw = NSDecimalNumber(decimal: abs(rounded)).stringValue
    let parts = expanded(raw).split(separator: ".", omittingEmptySubsequences: false)
    var integer = String(parts[0])
    if grouped {
      integer = String(integer.reversed().enumerated().flatMap { index, character -> [Character] in
        index > 0 && index % 3 == 0 ? [",", character] : [character]
      }.reversed())
    }
    let fraction = parts.count > 1 ? String(parts[1]) : ""
    let sign = rounded < 0 ? "-" : signed && rounded > 0 ? "+" : ""
    return sign + integer + "." + fraction + String(repeating: "0", count: max(0, digits - fraction.count))
  }

  static func compact(_ value: Double) -> String {
    guard value.isFinite else { return "--" }
    for (divisor, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where abs(value) >= divisor {
      return text(value / divisor) + suffix
    }
    return text(value)
  }

  static func turnover(_ value: Double) -> String {
    guard value.isFinite else { return "--" }
    for (divisor, suffix) in [(1e8, "亿"), (1e4, "万")] where abs(value) >= divisor {
      return text(value / divisor) + suffix
    }
    return text(value)
  }

  private static func fractionDigits(_ magnitude: Decimal) -> Int {
    if magnitude >= 100 { return 2 }
    if magnitude >= 1 { return 3 }
    if magnitude == 0 { return 4 }
    var scaled = magnitude
    var digits = 3
    while scaled < 1 { scaled *= 10; digits += 1 }
    return digits
  }

  private static func expanded(_ raw: String) -> String {
    let components = raw.lowercased().split(separator: "e")
    guard components.count == 2, let exponent = Int(components[1]) else { return raw }
    let mantissa = components[0].split(separator: ".", omittingEmptySubsequences: false)
    let digits = mantissa.joined()
    let point = mantissa[0].count + exponent
    if point <= 0 { return "0." + String(repeating: "0", count: -point) + digits }
    if point >= digits.count { return digits + String(repeating: "0", count: point - digits.count) }
    let index = digits.index(digits.startIndex, offsetBy: point)
    return String(digits[..<index]) + "." + String(digits[index...])
  }
}
