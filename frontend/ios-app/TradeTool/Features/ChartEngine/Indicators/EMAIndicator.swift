import Foundation

enum IndicatorPointValidity: Equatable, Sendable {
    case warmup
    case valid
    case hidden
    case dataGap
    case invalid
}

struct IndicatorPoint: Equatable, Sendable {
    let openTime: Int64
    let value: Double?
    let validity: IndicatorPointValidity
}

struct EMACommittedState: Equatable, Sendable {
    let period: Int
    fileprivate(set) var sampleCount: Int = 0
    fileprivate(set) var seedSum: Double = 0
    fileprivate(set) var value: Double?
    fileprivate(set) var lastOpenTime: Int64?
}

struct EMASnapshot: Equatable, Sendable {
    let committed: EMACommittedState
    let provisional: IndicatorPoint?
}

struct EMAIndicatorCalculator: Sendable {
    let intervalMilliseconds: Int64
    private(set) var committed: EMACommittedState

    init?(period: Int, intervalMilliseconds: Int64) {
        guard period > 0, intervalMilliseconds > 0 else {
            return nil
        }
        self.intervalMilliseconds = intervalMilliseconds
        committed = EMACommittedState(period: period)
    }

    @discardableResult
    mutating func commit(_ candle: ChartCandle) -> IndicatorPoint {
        guard candle.closure == .closed,
              candle.isValid,
              candle.closePrice.isFinite else {
            return IndicatorPoint(
                openTime: candle.openTime,
                value: nil,
                validity: .invalid
            )
        }

        if let lastOpenTime = committed.lastOpenTime {
            guard candle.openTime > lastOpenTime else {
                return IndicatorPoint(
                    openTime: candle.openTime,
                    value: nil,
                    validity: .invalid
                )
            }
            let expectedOpenTime = lastOpenTime
                .addingReportingOverflow(intervalMilliseconds)
            guard !expectedOpenTime.overflow,
                  candle.openTime == expectedOpenTime.partialValue else {
                restartSeed(with: candle)
                return IndicatorPoint(
                    openTime: candle.openTime,
                    value: nil,
                    validity: .dataGap
                )
            }
        }

        var candidate = self
        let point = candidate.advanceCommitted(with: candle)
        if point.validity != .invalid {
            self = candidate
        }
        return point
    }

    func provisional(_ candle: ChartCandle?) -> IndicatorPoint? {
        guard let candle else {
            return nil
        }
        guard candle.closure != .closed,
              candle.isValid,
              candle.closePrice.isFinite else {
            return IndicatorPoint(
                openTime: candle.openTime,
                value: nil,
                validity: .invalid
            )
        }

        if let lastOpenTime = committed.lastOpenTime {
            let expectedOpenTime = lastOpenTime
                .addingReportingOverflow(intervalMilliseconds)
            guard !expectedOpenTime.overflow,
                  candle.openTime == expectedOpenTime.partialValue else {
                return IndicatorPoint(
                    openTime: candle.openTime,
                    value: nil,
                    validity: candle.openTime > lastOpenTime
                        ? .dataGap
                        : .invalid
                )
            }
        }

        var temporary = self
        return temporary.advanceCommitted(
            with: candle.withClosure(.closed)
        )
    }

    func snapshot(
        provisional candle: ChartCandle? = nil
    ) -> EMASnapshot {
        EMASnapshot(
            committed: committed,
            provisional: provisional(candle)
        )
    }

    private mutating func restartSeed(with candle: ChartCandle) {
        committed.sampleCount = 1
        committed.seedSum = candle.closePrice
        committed.value = committed.period == 1
            ? candle.closePrice
            : nil
        committed.lastOpenTime = candle.openTime
    }

    private mutating func advanceCommitted(
        with candle: ChartCandle
    ) -> IndicatorPoint {
        committed.lastOpenTime = candle.openTime

        if let previousValue = committed.value {
            let alpha = 2 / Double(committed.period + 1)
            let nextValue = previousValue
                + alpha * (candle.closePrice - previousValue)
            guard nextValue.isFinite else {
                return IndicatorPoint(
                    openTime: candle.openTime,
                    value: nil,
                    validity: .invalid
                )
            }
            committed.sampleCount &+= 1
            committed.value = nextValue
            return IndicatorPoint(
                openTime: candle.openTime,
                value: nextValue,
                validity: .valid
            )
        }

        committed.sampleCount &+= 1
        committed.seedSum += candle.closePrice
        guard committed.seedSum.isFinite else {
            committed.seedSum = 0
            committed.sampleCount = 0
            committed.lastOpenTime = nil
            return IndicatorPoint(
                openTime: candle.openTime,
                value: nil,
                validity: .invalid
            )
        }
        guard committed.sampleCount >= committed.period else {
            return IndicatorPoint(
                openTime: candle.openTime,
                value: nil,
                validity: .warmup
            )
        }

        let seededValue = committed.seedSum
            / Double(committed.period)
        committed.value = seededValue
        return IndicatorPoint(
            openTime: candle.openTime,
            value: seededValue,
            validity: .valid
        )
    }
}
