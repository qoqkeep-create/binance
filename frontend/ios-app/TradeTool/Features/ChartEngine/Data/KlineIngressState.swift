import Foundation

struct KlineIngressEvent: Equatable, Sendable {
    let epoch: KlineStreamEpoch
    let stream: ChartStreamKey
    let sequence: Int64
    let eventTime: Int64
    let candle: ChartCandle
}

enum KlineRecoveryReason: Equatable, Sendable {
    case epochChanged
    case sequenceGap(expected: Int64, received: Int64)
    case upstreamBufferDropped
    case barrierOverflow(capacity: Int)
    case invalidCandle
    case missingTrustedClose(openTime: Int64)
    case outOfOrderOpenTime(received: Int64, newest: Int64)
    case downstreamStateInvalid(openTime: Int64)
}

struct KlineRecoveryRequest: Equatable, Sendable {
    let stream: ChartStreamKey
    let epoch: KlineStreamEpoch
    let reason: KlineRecoveryReason
}

enum KlineIngressDisposition: Equatable, Sendable {
    case accepted
    case coalesced
    case ignoredDuplicateOrLate
    case ignoredWrongEpochOrStream
    case recoveryRequired(KlineRecoveryReason)
}

struct KlineIngressMutation: Equatable, Sendable {
    let revision: UInt64
    let candle: ChartCandle
}

struct KlineIngressDrain: Equatable, Sendable {
    let mutations: [KlineIngressMutation]
    let recoveryRequest: KlineRecoveryRequest?
}

struct KlineIngressState: Sendable {
    private(set) var epoch: KlineStreamEpoch?
    private(set) var stream: ChartStreamKey?
    private(set) var lastReceivedSequence: Int64?
    private(set) var lastAppliedRevision: UInt64 = 0
    private(set) var newestOpenTime: Int64?
    private(set) var pendingLiveUpsert: KlineIngressEvent?
    private(set) var recoveryRequest: KlineRecoveryRequest?

    let barrierCapacity: Int

    private var barrierQueue: [ChartCandle] = []
    private var nextRevision: UInt64 = 1
    private var latestObservedEvent: KlineIngressEvent?

    var pendingBarrierCount: Int {
        barrierQueue.count
    }

    init(barrierCapacity: Int = 8) {
        self.barrierCapacity = max(1, barrierCapacity)
    }

    mutating func beginEpoch(
        _ epoch: KlineStreamEpoch,
        stream: ChartStreamKey
    ) {
        self.epoch = epoch
        self.stream = stream
        lastReceivedSequence = nil
        lastAppliedRevision = 0
        newestOpenTime = nil
        pendingLiveUpsert = nil
        latestObservedEvent = nil
        barrierQueue.removeAll(keepingCapacity: true)
        nextRevision = 1
        recoveryRequest = KlineRecoveryRequest(
            stream: stream,
            epoch: epoch,
            reason: .epochChanged
        )
    }

    mutating func accept(
        _ event: KlineIngressEvent
    ) -> KlineIngressDisposition {
        guard event.epoch == epoch,
              event.stream == stream else {
            return .ignoredWrongEpochOrStream
        }

        guard event.candle.isValid else {
            setRecovery(.invalidCandle)
            return .recoveryRequired(.invalidCandle)
        }

        if let lastReceivedSequence {
            guard event.sequence > lastReceivedSequence else {
                return .ignoredDuplicateOrLate
            }

            let (expected, overflow) =
                lastReceivedSequence.addingReportingOverflow(1)
            guard !overflow, event.sequence == expected else {
                self.lastReceivedSequence = event.sequence
                return requireRecovery(
                    .sequenceGap(
                        expected: overflow
                            ? lastReceivedSequence
                            : expected,
                        received: event.sequence
                    ),
                    preserving: event
                )
            }
        }
        lastReceivedSequence = event.sequence

        if event.candle.closure == .closed {
            return acceptTrustedClose(event)
        }
        return acceptLiveUpsert(event)
    }

    mutating func markUpstreamBufferDropped() {
        _ = requireRecovery(
            .upstreamBufferDropped,
            preserving: pendingLiveUpsert ?? latestObservedEvent
        )
    }

    mutating func drain(
        includeLiveTail: Bool = true
    ) -> KlineIngressDrain {
        var candles = barrierQueue
        barrierQueue.removeAll(keepingCapacity: true)

        if includeLiveTail, let pendingLiveUpsert {
            candles.append(pendingLiveUpsert.candle)
            self.pendingLiveUpsert = nil
        }

        let mutations = candles.map { candle in
            defer {
                nextRevision &+= 1
            }
            return KlineIngressMutation(
                revision: nextRevision,
                candle: candle
            )
        }

        return KlineIngressDrain(
            mutations: mutations,
            recoveryRequest: recoveryRequest
        )
    }

    mutating func confirmApplied(revision: UInt64) {
        guard revision >= lastAppliedRevision,
              revision < nextRevision else {
            return
        }
        lastAppliedRevision = revision
    }

    mutating func completeRecovery(
        newestOpenTime: Int64?
    ) {
        self.newestOpenTime = newestOpenTime
        recoveryRequest = nil
    }

    mutating func requireDownstreamRecovery(
        openTime: Int64
    ) {
        setRecovery(
            .downstreamStateInvalid(openTime: openTime)
        )
    }

    private mutating func acceptLiveUpsert(
        _ event: KlineIngressEvent
    ) -> KlineIngressDisposition {
        let openTime = event.candle.openTime
        let observedOpenTime = pendingLiveUpsert?.candle.openTime
            ?? newestOpenTime

        if let observedOpenTime, openTime < observedOpenTime {
            let reason = KlineRecoveryReason.outOfOrderOpenTime(
                received: openTime,
                newest: observedOpenTime
            )
            setRecovery(reason)
            return .recoveryRequired(reason)
        }

        if let pendingLiveUpsert,
           pendingLiveUpsert.candle.openTime == openTime {
            self.pendingLiveUpsert = event
            latestObservedEvent = event
            newestOpenTime = max(newestOpenTime ?? openTime, openTime)
            return .coalesced
        }

        let previousEvent = pendingLiveUpsert ?? latestObservedEvent
        if let previousEvent,
           openTime > previousEvent.candle.openTime,
           previousEvent.candle.closure != .closed {
            guard enqueueBarrier(
                previousEvent.candle.withClosure(.unverifiedClosed)
            ) else {
                return requireRecovery(
                    .barrierOverflow(capacity: barrierCapacity),
                    preserving: event
                )
            }
            self.pendingLiveUpsert = event
            latestObservedEvent = event
            newestOpenTime = openTime
            let missingClose = KlineRecoveryReason.missingTrustedClose(
                openTime: previousEvent.candle.openTime
            )
            setRecoveryIfNeeded(missingClose)
            return .recoveryRequired(missingClose)
        }

        pendingLiveUpsert = event
        latestObservedEvent = event
        newestOpenTime = max(newestOpenTime ?? openTime, openTime)
        return .accepted
    }

    private mutating func acceptTrustedClose(
        _ event: KlineIngressEvent
    ) -> KlineIngressDisposition {
        let openTime = event.candle.openTime

        if pendingLiveUpsert?.candle.openTime == openTime {
            pendingLiveUpsert = nil
        }

        if let queuedIndex = barrierQueue.lastIndex(where: {
            $0.openTime == openTime
        }) {
            barrierQueue[queuedIndex] = event.candle
            if latestObservedEvent?.candle.openTime == openTime {
                latestObservedEvent = event
            }
            newestOpenTime = max(newestOpenTime ?? openTime, openTime)
            return .accepted
        }

        guard enqueueBarrier(event.candle) else {
            return requireRecovery(
                .barrierOverflow(capacity: barrierCapacity),
                preserving: event
            )
        }
        if latestObservedEvent == nil
            || openTime
                >= (latestObservedEvent?.candle.openTime
                    ?? Int64.min) {
            latestObservedEvent = event
        }
        newestOpenTime = max(newestOpenTime ?? openTime, openTime)
        return .accepted
    }

    private mutating func enqueueBarrier(
        _ candle: ChartCandle
    ) -> Bool {
        guard barrierQueue.count < barrierCapacity else {
            return false
        }
        barrierQueue.append(candle)
        return true
    }

    private mutating func requireRecovery(
        _ reason: KlineRecoveryReason,
        preserving event: KlineIngressEvent?
    ) -> KlineIngressDisposition {
        barrierQueue.removeAll(keepingCapacity: true)

        if let event {
            let recoveredClosure: ChartCandleClosure =
                event.candle.closure == .closed
                ? .unverifiedClosed
                : .provisional
            pendingLiveUpsert = KlineIngressEvent(
                epoch: event.epoch,
                stream: event.stream,
                sequence: event.sequence,
                eventTime: event.eventTime,
                candle: event.candle.withClosure(recoveredClosure)
            )
            latestObservedEvent = pendingLiveUpsert
            newestOpenTime = max(
                newestOpenTime ?? event.candle.openTime,
                event.candle.openTime
            )
        } else {
            pendingLiveUpsert = nil
        }

        setRecovery(reason)
        return .recoveryRequired(reason)
    }

    private mutating func setRecoveryIfNeeded(
        _ reason: KlineRecoveryReason
    ) {
        guard recoveryRequest == nil else {
            return
        }
        setRecovery(reason)
    }

    private mutating func setRecovery(
        _ reason: KlineRecoveryReason
    ) {
        guard let epoch, let stream else {
            return
        }
        recoveryRequest = KlineRecoveryRequest(
            stream: stream,
            epoch: epoch,
            reason: reason
        )
    }
}
