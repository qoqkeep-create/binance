import Foundation

struct ChartIndicatorParameters: Equatable, Sendable {
  static let movingAveragePeriodRange = 1...500
  static let emaPeriodRange = 1...500
  static let bollingerPeriodRange = 1...500
  static let bollingerMultiplierRange = 0.1...20.0
  static let parabolicSARStartRange = 0.001...1.0
  static let parabolicSARMaximumRange = 0.001...5.0
  static let superTrendATRPeriodRange = 1...200
  static let superTrendMultiplierRange = 0.1...20.0
  static let volumeFastPeriodRange = 1...200
  static let volumeSlowPeriodRange = 1...500
  static let macdFastPeriodRange = 1...200
  static let macdSlowPeriodRange = 2...500
  static let macdSignalPeriodRange = 1...200
  static let rsiPeriodRange = 1...200
  static let kdjPeriodRange = 1...200
  static let kdjSmoothingRange = 1...50
  static let williamsRPeriodRange = 1...200
  static let stochasticRSIPeriodRange = 1...200
  static let stochasticRSISmoothingRange = 1...50
  static let atrPeriodRange = 1...200

  static let standard = ChartIndicatorParameters(
    validatedMovingAveragePeriods: [7, 25, 99],
    validatedEMAPeriods: [21, 55, 144],
    bollingerPeriod: 20,
    bollingerMultiplier: 2,
    parabolicSARStart: 0.02,
    parabolicSARMaximum: 0.2,
    superTrendATRPeriod: 10,
    superTrendMultiplier: 6,
    volumeFastPeriod: 5,
    volumeSlowPeriod: 10,
    macdFastPeriod: 12,
    macdSlowPeriod: 26,
    macdSignalPeriod: 9,
    rsiPeriod: 14,
    kdjPeriod: 9,
    kdjKSmoothing: 3,
    kdjDSmoothing: 3,
    williamsRPeriod: 14,
    stochasticRSIPeriod: 14,
    stochasticRSIWindow: 14,
    stochasticRSIKSmoothing: 3,
    stochasticRSIDSmoothing: 3,
    atrPeriod: 14
  )

  let movingAveragePeriods: [Int]
  let emaPeriods: [Int]
  let bollingerPeriod: Int
  let bollingerMultiplier: Double
  let parabolicSARStart: Double
  let parabolicSARMaximum: Double
  let superTrendATRPeriod: Int
  let superTrendMultiplier: Double
  let superTrendFillAlpha: Double
  let volumeFastPeriod: Int
  let volumeSlowPeriod: Int
  let macdFastPeriod: Int
  let macdSlowPeriod: Int
  let macdSignalPeriod: Int
  let rsiPeriod: Int
  let kdjPeriod: Int
  let kdjKSmoothing: Int
  let kdjDSmoothing: Int
  let williamsRPeriod: Int
  let stochasticRSIPeriod: Int
  let stochasticRSIWindow: Int
  let stochasticRSIKSmoothing: Int
  let stochasticRSIDSmoothing: Int
  let atrPeriod: Int

  init?(
    emaPeriods: [Int],
    superTrendATRPeriod: Int,
    superTrendMultiplier: Double,
    volumeFastPeriod: Int,
    volumeSlowPeriod: Int,
    macdFastPeriod: Int,
    macdSlowPeriod: Int,
    macdSignalPeriod: Int,
    rsiPeriod: Int = 14,
    movingAveragePeriods: [Int] = [7, 25, 99],
    bollingerPeriod: Int = 20,
    bollingerMultiplier: Double = 2,
    parabolicSARStart: Double = 0.02,
    parabolicSARMaximum: Double = 0.2,
    kdjPeriod: Int = 9,
    kdjKSmoothing: Int = 3,
    kdjDSmoothing: Int = 3,
    williamsRPeriod: Int = 14,
    stochasticRSIPeriod: Int = 14,
    stochasticRSIWindow: Int = 14,
    stochasticRSIKSmoothing: Int = 3,
    stochasticRSIDSmoothing: Int = 3,
    atrPeriod: Int = 14,
    superTrendFillAlpha: Double = 0.16
  ) {
    guard movingAveragePeriods.count == 3,
      movingAveragePeriods.allSatisfy(
        Self.movingAveragePeriodRange.contains
      ),
      zip(
        movingAveragePeriods,
        movingAveragePeriods.dropFirst()
      ).allSatisfy(<),
      emaPeriods.count == 3,
      emaPeriods.allSatisfy(Self.emaPeriodRange.contains),
      zip(emaPeriods, emaPeriods.dropFirst()).allSatisfy(<),
      Self.bollingerPeriodRange.contains(bollingerPeriod),
      Self.bollingerMultiplierRange.contains(
        bollingerMultiplier
      ),
      Self.isAligned(bollingerMultiplier, step: 0.1),
      Self.parabolicSARStartRange.contains(
        parabolicSARStart
      ),
      Self.parabolicSARMaximumRange.contains(
        parabolicSARMaximum
      ),
      parabolicSARStart <= parabolicSARMaximum,
      Self.superTrendATRPeriodRange.contains(
        superTrendATRPeriod
      ),
      Self.superTrendMultiplierRange.contains(
        superTrendMultiplier
      ),
      Self.isAligned(
        superTrendMultiplier,
        step: 0.1
      ),
      Self.volumeFastPeriodRange.contains(volumeFastPeriod),
      Self.volumeSlowPeriodRange.contains(volumeSlowPeriod),
      volumeFastPeriod <= volumeSlowPeriod,
      Self.macdFastPeriodRange.contains(macdFastPeriod),
      Self.macdSlowPeriodRange.contains(macdSlowPeriod),
      macdFastPeriod < macdSlowPeriod,
      Self.macdSignalPeriodRange.contains(macdSignalPeriod),
      Self.rsiPeriodRange.contains(rsiPeriod),
      Self.kdjPeriodRange.contains(kdjPeriod),
      Self.kdjSmoothingRange.contains(kdjKSmoothing),
      Self.kdjSmoothingRange.contains(kdjDSmoothing),
      Self.williamsRPeriodRange.contains(williamsRPeriod),
      Self.stochasticRSIPeriodRange.contains(stochasticRSIPeriod),
      Self.stochasticRSIPeriodRange.contains(stochasticRSIWindow),
      Self.stochasticRSISmoothingRange.contains(
        stochasticRSIKSmoothing
      ),
      Self.stochasticRSISmoothingRange.contains(
        stochasticRSIDSmoothing
      ),
      Self.atrPeriodRange.contains(atrPeriod),
      superTrendFillAlpha.isFinite, (0...1).contains(superTrendFillAlpha)
    else {
      return nil
    }

    self.init(
      validatedMovingAveragePeriods: movingAveragePeriods,
      validatedEMAPeriods: emaPeriods,
      bollingerPeriod: bollingerPeriod,
      bollingerMultiplier: bollingerMultiplier,
      parabolicSARStart: parabolicSARStart,
      parabolicSARMaximum: parabolicSARMaximum,
      superTrendATRPeriod: superTrendATRPeriod,
      superTrendMultiplier: superTrendMultiplier,
      volumeFastPeriod: volumeFastPeriod,
      volumeSlowPeriod: volumeSlowPeriod,
      macdFastPeriod: macdFastPeriod,
      macdSlowPeriod: macdSlowPeriod,
      macdSignalPeriod: macdSignalPeriod,
      rsiPeriod: rsiPeriod,
      kdjPeriod: kdjPeriod,
      kdjKSmoothing: kdjKSmoothing,
      kdjDSmoothing: kdjDSmoothing,
      williamsRPeriod: williamsRPeriod,
      stochasticRSIPeriod: stochasticRSIPeriod,
      stochasticRSIWindow: stochasticRSIWindow,
      stochasticRSIKSmoothing: stochasticRSIKSmoothing,
      stochasticRSIDSmoothing: stochasticRSIDSmoothing,
      atrPeriod: atrPeriod,
      superTrendFillAlpha: superTrendFillAlpha
    )
  }

  var superTrendMultiplierText: String {
    Self.decimalText(superTrendMultiplier)
  }

  var bollingerMultiplierText: String {
    Self.decimalText(bollingerMultiplier)
  }

  var parabolicSARStartText: String {
    Self.decimalText(parabolicSARStart)
  }

  var parabolicSARMaximumText: String {
    Self.decimalText(parabolicSARMaximum)
  }

  private init(
    validatedMovingAveragePeriods: [Int],
    validatedEMAPeriods: [Int],
    bollingerPeriod: Int,
    bollingerMultiplier: Double,
    parabolicSARStart: Double,
    parabolicSARMaximum: Double,
    superTrendATRPeriod: Int,
    superTrendMultiplier: Double,
    volumeFastPeriod: Int,
    volumeSlowPeriod: Int,
    macdFastPeriod: Int,
    macdSlowPeriod: Int,
    macdSignalPeriod: Int,
    rsiPeriod: Int,
    kdjPeriod: Int,
    kdjKSmoothing: Int,
    kdjDSmoothing: Int,
    williamsRPeriod: Int,
    stochasticRSIPeriod: Int,
    stochasticRSIWindow: Int,
    stochasticRSIKSmoothing: Int,
    stochasticRSIDSmoothing: Int,
    atrPeriod: Int,
    superTrendFillAlpha: Double = 0.16
  ) {
    movingAveragePeriods = validatedMovingAveragePeriods
    emaPeriods = validatedEMAPeriods
    self.bollingerPeriod = bollingerPeriod
    self.bollingerMultiplier = bollingerMultiplier
    self.parabolicSARStart = parabolicSARStart
    self.parabolicSARMaximum = parabolicSARMaximum
    self.superTrendATRPeriod = superTrendATRPeriod
    self.superTrendMultiplier = superTrendMultiplier
    self.superTrendFillAlpha = superTrendFillAlpha
    self.volumeFastPeriod = volumeFastPeriod
    self.volumeSlowPeriod = volumeSlowPeriod
    self.macdFastPeriod = macdFastPeriod
    self.macdSlowPeriod = macdSlowPeriod
    self.macdSignalPeriod = macdSignalPeriod
    self.rsiPeriod = rsiPeriod
    self.kdjPeriod = kdjPeriod
    self.kdjKSmoothing = kdjKSmoothing
    self.kdjDSmoothing = kdjDSmoothing
    self.williamsRPeriod = williamsRPeriod
    self.stochasticRSIPeriod = stochasticRSIPeriod
    self.stochasticRSIWindow = stochasticRSIWindow
    self.stochasticRSIKSmoothing = stochasticRSIKSmoothing
    self.stochasticRSIDSmoothing = stochasticRSIDSmoothing
    self.atrPeriod = atrPeriod
  }

  private static func isAligned(
    _ value: Double,
    step: Double
  ) -> Bool {
    guard value.isFinite, step.isFinite, step > 0 else {
      return false
    }
    let scaled = value / step
    return abs(scaled - scaled.rounded()) <= 0.000_000_1
  }

  private static func decimalText(_ value: Double) -> String {
    if value.rounded() == value {
      return String(Int(value))
    }
    return String(format: "%.3f", value)
      .replacingOccurrences(
        of: "0+$",
        with: "",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: "\\.$",
        with: "",
        options: .regularExpression
      )
  }
}

struct ChartIndicatorParametersStore {
  private struct Payload: Codable {
    let schemaVersion: Int
    let movingAveragePeriods: [Int]?
    let emaPeriods: [Int]
    let bollingerPeriod: Int?
    let bollingerMultiplier: Double?
    let parabolicSARStart: Double?
    let parabolicSARMaximum: Double?
    let superTrendATRPeriod: Int
    let superTrendMultiplier: Double
    let superTrendFillAlpha: Double?
    let volumeFastPeriod: Int
    let volumeSlowPeriod: Int
    let macdFastPeriod: Int
    let macdSlowPeriod: Int
    let macdSignalPeriod: Int
    let rsiPeriod: Int?
    let kdjPeriod: Int?
    let kdjKSmoothing: Int?
    let kdjDSmoothing: Int?
    let williamsRPeriod: Int?
    let stochasticRSIPeriod: Int?
    let stochasticRSIWindow: Int?
    let stochasticRSIKSmoothing: Int?
    let stochasticRSIDSmoothing: Int?
    let atrPeriod: Int?

    init(_ parameters: ChartIndicatorParameters) {
      schemaVersion = 5
      movingAveragePeriods = parameters.movingAveragePeriods
      emaPeriods = parameters.emaPeriods
      bollingerPeriod = parameters.bollingerPeriod
      bollingerMultiplier = parameters.bollingerMultiplier
      parabolicSARStart = parameters.parabolicSARStart
      parabolicSARMaximum = parameters.parabolicSARMaximum
      superTrendATRPeriod = parameters.superTrendATRPeriod
      superTrendMultiplier = parameters.superTrendMultiplier
      superTrendFillAlpha = parameters.superTrendFillAlpha
      volumeFastPeriod = parameters.volumeFastPeriod
      volumeSlowPeriod = parameters.volumeSlowPeriod
      macdFastPeriod = parameters.macdFastPeriod
      macdSlowPeriod = parameters.macdSlowPeriod
      macdSignalPeriod = parameters.macdSignalPeriod
      rsiPeriod = parameters.rsiPeriod
      kdjPeriod = parameters.kdjPeriod
      kdjKSmoothing = parameters.kdjKSmoothing
      kdjDSmoothing = parameters.kdjDSmoothing
      williamsRPeriod = parameters.williamsRPeriod
      stochasticRSIPeriod = parameters.stochasticRSIPeriod
      stochasticRSIWindow = parameters.stochasticRSIWindow
      stochasticRSIKSmoothing = parameters.stochasticRSIKSmoothing
      stochasticRSIDSmoothing = parameters.stochasticRSIDSmoothing
      atrPeriod = parameters.atrPeriod
    }

    var parameters: ChartIndicatorParameters? {
      guard (1...5).contains(schemaVersion) else {
        return nil
      }
      return ChartIndicatorParameters(
        emaPeriods: emaPeriods,
        superTrendATRPeriod: superTrendATRPeriod,
        superTrendMultiplier: superTrendMultiplier,
        volumeFastPeriod: volumeFastPeriod,
        volumeSlowPeriod: volumeSlowPeriod,
        macdFastPeriod: macdFastPeriod,
        macdSlowPeriod: macdSlowPeriod,
        macdSignalPeriod: macdSignalPeriod,
        rsiPeriod: rsiPeriod ?? 14,
        movingAveragePeriods: movingAveragePeriods ?? [7, 25, 99],
        bollingerPeriod: bollingerPeriod ?? 20,
        bollingerMultiplier: bollingerMultiplier ?? 2,
        parabolicSARStart: parabolicSARStart ?? 0.02,
        parabolicSARMaximum: parabolicSARMaximum ?? 0.2,
        kdjPeriod: kdjPeriod ?? 9,
        kdjKSmoothing: kdjKSmoothing ?? 3,
        kdjDSmoothing: kdjDSmoothing ?? 3,
        williamsRPeriod: williamsRPeriod ?? 14,
        stochasticRSIPeriod: stochasticRSIPeriod ?? 14,
        stochasticRSIWindow: stochasticRSIWindow ?? 14,
        stochasticRSIKSmoothing: stochasticRSIKSmoothing ?? 3,
        stochasticRSIDSmoothing: stochasticRSIDSmoothing ?? 3,
        atrPeriod: atrPeriod ?? 14,
        superTrendFillAlpha: superTrendFillAlpha ?? 0.16
      )
    }
  }

  private let defaults: UserDefaults
  private let key: String
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    defaults: UserDefaults = .standard,
    key: String = "chart.indicator-parameters.v1"
  ) {
    self.defaults = defaults
    self.key = key
  }

  func load() -> ChartIndicatorParameters {
    guard let data = defaults.data(forKey: key),
      let payload = try? decoder.decode(
        Payload.self,
        from: data
      ),
      let parameters = payload.parameters
    else {
      return .standard
    }
    return parameters
  }

  func save(_ parameters: ChartIndicatorParameters) {
    guard let data = try? encoder.encode(Payload(parameters)) else {
      return
    }
    defaults.set(data, forKey: key)
  }
}
