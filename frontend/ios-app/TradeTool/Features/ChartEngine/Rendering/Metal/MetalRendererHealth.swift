import Foundation

struct MetalCommandBufferFailureSummary: Equatable, Sendable {
    private static let maximumMessageLength = 240

    let status: String
    let errorDomain: String?
    let errorCode: Int?
    let message: String?

    init(
        status: String,
        error: Error?
    ) {
        let nsError = error.map { $0 as NSError }
        self.init(
            status: status,
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            message: nsError?.localizedDescription
        )
    }

    init(
        status: String,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        message: String? = nil
    ) {
        self.status = status
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.message = message.map {
            String($0.prefix(Self.maximumMessageLength))
        }
    }
}

struct MetalPresentationSample: Equatable, Sendable {
    let revision: UInt64
    let liveRevision: UInt64
    let liveReadyTime: TimeInterval
    let readyTime: TimeInterval
    let submittedTime: TimeInterval
    let presentedTime: TimeInterval

    var readyToSubmitDuration: TimeInterval? {
        Self.validDuration(
            endingAt: submittedTime,
            startingAt: readyTime
        )
    }

    var submitToPresentDuration: TimeInterval? {
        Self.validDuration(
            endingAt: presentedTime,
            startingAt: submittedTime
        )
    }

    var readyToPresentDuration: TimeInterval? {
        Self.validDuration(
            endingAt: presentedTime,
            startingAt: readyTime
        )
    }

    var liveReadyToPresentDuration: TimeInterval? {
        Self.validDuration(
            endingAt: presentedTime,
            startingAt: liveReadyTime
        )
    }

    var liveReadyToSubmitDuration: TimeInterval? {
        Self.validDuration(
            endingAt: submittedTime,
            startingAt: liveReadyTime
        )
    }

    private static func validDuration(
        endingAt end: TimeInterval,
        startingAt start: TimeInterval
    ) -> TimeInterval? {
        let duration = end - start
        return duration.isFinite && duration >= 0
            ? duration
            : nil
    }
}

enum MetalApplicationActivity: String, Equatable, Sendable {
    case active
    case inactive
    case background
    case unknown
}

struct MetalPresentationContext: Equatable, Sendable {
    var applicationActivity: MetalApplicationActivity = .unknown
    var isHostAttachedToWindow = false
    var isHostVisible = false
    var isWindowVisible = false
    var isRendererSuspended = true
    var isInteractionActive = false
}

struct MetalDroppedPresentationSample: Equatable, Sendable {
    let revision: UInt64
    let liveRevision: UInt64
    let callbackTime: TimeInterval
    let liveReadyTime: TimeInterval
    let readyTime: TimeInterval
    let submittedTime: TimeInterval
    let submissionContext: MetalPresentationContext
    let callbackContext: MetalPresentationContext
    let submittedFrames: UInt64
    let completedFrames: UInt64
    let currentInFlightFrames: UInt64
    let rendererSuspends: UInt64
    let rendererResumes: UInt64

    var submitToCallbackDuration: TimeInterval? {
        let duration = callbackTime - submittedTime
        return duration.isFinite && duration >= 0
            ? duration
            : nil
    }
}

struct MetalPresentationLatencyHistogram: Equatable, Sendable {
    private static let upperBounds: [TimeInterval] = [
        0.004,
        0.007,
        0.008,
        0.012,
        0.016,
        0.020,
        0.024,
        0.032,
        0.034,
        0.036,
        0.040,
        0.050,
        0.050_250,
        0.050_500,
        0.051,
        0.051_500,
        0.052,
        0.055,
        0.060,
        0.064,
        0.067,
        0.100,
        0.150,
        0.250,
        0.500,
    ]

    private(set) var bucketCounts: [UInt64] = Array(
        repeating: 0,
        count: upperBounds.count + 1
    )

    var sampleCount: UInt64 {
        bucketCounts.reduce(0, &+)
    }

    mutating func record(_ duration: TimeInterval) {
        guard duration.isFinite, duration >= 0 else {
            return
        }
        let index = Self.upperBounds.firstIndex {
            duration <= $0
        } ?? Self.upperBounds.count
        bucketCounts[index] &+= 1
    }

    func subtracting(
        _ baseline: MetalPresentationLatencyHistogram
    ) -> MetalPresentationLatencyHistogram {
        var result = MetalPresentationLatencyHistogram()
        for index in result.bucketCounts.indices {
            let current = bucketCounts[index]
            let previous = baseline.bucketCounts[index]
            result.bucketCounts[index] = current >= previous
                ? current - previous
                : 0
        }
        return result
    }

    func percentileUpperBound(
        _ percentile: Double
    ) -> TimeInterval? {
        guard percentile.isFinite,
              percentile > 0,
              percentile <= 1,
              sampleCount > 0 else {
            return nil
        }
        let target = UInt64(
            ceil(Double(sampleCount) * percentile)
        )
        var cumulative: UInt64 = 0
        for (index, count) in bucketCounts.enumerated() {
            cumulative &+= count
            guard cumulative >= target else {
                continue
            }
            return index < Self.upperBounds.count
                ? Self.upperBounds[index]
                : .infinity
        }
        return nil
    }
}

struct MetalRendererHealthSnapshot: Equatable, Sendable {
    var submittedFrames: UInt64 = 0
    var completedFrames: UInt64 = 0
    var currentInFlightFrames: UInt64 = 0
    var peakInFlightFrames: UInt64 = 0
    var presentedFrames: UInt64 = 0
    var droppedPresentations: UInt64 = 0
    var gpuBusySkips: UInt64 = 0
    var nilDrawableSkips: UInt64 = 0
    var commandBufferErrors: UInt64 = 0
    var bufferCapacityRejections: UInt64 = 0
    var rendererRebuildAttempts: UInt64 = 0
    var rendererRebuildSuccesses: UInt64 = 0
    var rendererCircuitBreakerStops: UInt64 = 0
    var memoryWarnings: UInt64 = 0
    var rendererSuspends: UInt64 = 0
    var rendererResumes: UInt64 = 0
#if DEBUG
    var simulatedCommandBufferErrors: UInt64 = 0
#endif
    var lastPresentedRevision: UInt64 = 0
    var lastPresentedLiveRevision: UInt64 = 0
    var lastPresentedTime: TimeInterval = 0
    var presentationLatency =
        MetalPresentationLatencyHistogram()
    var readyToSubmitLatency =
        MetalPresentationLatencyHistogram()
    var submitToPresentLatency =
        MetalPresentationLatencyHistogram()
    var livePresentationLatency =
        MetalPresentationLatencyHistogram()
    var liveReadyToSubmitLatency =
        MetalPresentationLatencyHistogram()
    var liveSubmitToPresentLatency =
        MetalPresentationLatencyHistogram()
    var presentationContext = MetalPresentationContext()
    var recentPresentations: [MetalPresentationSample] = []
    var recentDroppedPresentations:
        [MetalDroppedPresentationSample] = []
    var recentCommandBufferFailures:
        [MetalCommandBufferFailureSummary] = []
}

final class MetalRendererHealth: @unchecked Sendable {
    private static let presentationCapacity = 256
    private static let droppedPresentationCapacity = 16
    private static let commandFailureCapacity = 16

    private let lock = NSLock()
    private var value = MetalRendererHealthSnapshot()
    private var presentationRing = Array<MetalPresentationSample?>(
        repeating: nil,
        count: presentationCapacity
    )
    private var nextPresentationIndex = 0
    private var presentationCount = 0
    private var droppedPresentationRing =
        Array<MetalDroppedPresentationSample?>(
            repeating: nil,
            count: droppedPresentationCapacity
        )
    private var nextDroppedPresentationIndex = 0
    private var droppedPresentationCount = 0
    private var commandFailureRing =
        Array<MetalCommandBufferFailureSummary?>(
            repeating: nil,
            count: commandFailureCapacity
        )
    private var nextCommandFailureIndex = 0
    private var commandFailureCount = 0
    private var firstPresentationHandler: (@Sendable (TimeInterval) -> Void)?
    private var scopedPresentationID: ChartPresentationID?
    private var scopedPresentationHandler: (@Sendable (ChartPresentationID, TimeInterval) -> Void)?

    func observeFirstPresentation(_ handler: @escaping @Sendable (TimeInterval) -> Void) {
        lock.lock()
        if value.presentedFrames == 0 { firstPresentationHandler = handler }
        lock.unlock()
    }

    func observeFirstPresentation(for id: ChartPresentationID?,
        _ handler: @escaping @Sendable (ChartPresentationID, TimeInterval) -> Void) {
        lock.lock()
        if scopedPresentationID != id { value.lastPresentedLiveRevision = 0 }
        scopedPresentationID = id
        scopedPresentationHandler = id == nil ? nil : handler
        lock.unlock()
    }

    @discardableResult
    func recordSubmitted() -> MetalPresentationContext {
        lock.lock()
        value.submittedFrames &+= 1
        value.currentInFlightFrames &+= 1
        value.peakInFlightFrames = max(
            value.peakInFlightFrames,
            value.currentInFlightFrames
        )
        let context = value.presentationContext
        lock.unlock()
        return context
    }

    func recordPresented(
        revision: UInt64,
        liveRevision: UInt64,
        liveReadyTime: TimeInterval,
        presentedTime: TimeInterval,
        readyTime: TimeInterval,
        submittedTime: TimeInterval,
        submissionContext: MetalPresentationContext? = nil,
        presentationID: ChartPresentationID? = nil,
        callbackTime: TimeInterval =
            ProcessInfo.processInfo.systemUptime
    ) {
        lock.lock()
        let firstPresentation = presentedTime > 0 ? firstPresentationHandler : nil
        if presentedTime > 0 { firstPresentationHandler = nil }
        let scopedPresentation = presentedTime > 0 && presentationID != nil
            && presentationID == scopedPresentationID ? scopedPresentationHandler : nil
        if scopedPresentation != nil { scopedPresentationHandler = nil }
        if presentedTime > 0 {
            value.presentedFrames &+= 1
            value.lastPresentedRevision = revision
            value.lastPresentedTime = presentedTime
            let sample = MetalPresentationSample(
                revision: revision,
                liveRevision: liveRevision,
                liveReadyTime: liveReadyTime,
                readyTime: readyTime,
                submittedTime: submittedTime,
                presentedTime: presentedTime
            )
            if let duration = sample.readyToPresentDuration {
                value.presentationLatency.record(duration)
            }
            if let duration = sample.readyToSubmitDuration {
                value.readyToSubmitLatency.record(duration)
            }
            if let duration = sample.submitToPresentDuration {
                value.submitToPresentLatency.record(duration)
            }
            // Commands already in flight still count as frames, but cannot advance
            // another stream's live revision watermark after a host is reused.
            if (presentationID == nil || presentationID == scopedPresentationID),
               liveRevision >
                    value.lastPresentedLiveRevision,
               let duration =
                    sample.liveReadyToPresentDuration {
                value.lastPresentedLiveRevision = liveRevision
                value.livePresentationLatency.record(duration)
                if let readyToSubmit =
                        sample.liveReadyToSubmitDuration {
                    value.liveReadyToSubmitLatency.record(
                        readyToSubmit
                    )
                }
                if let submitToPresent =
                        sample.submitToPresentDuration {
                    value.liveSubmitToPresentLatency.record(
                        submitToPresent
                    )
                }
            }
            presentationRing[nextPresentationIndex] = sample
            nextPresentationIndex = (
                nextPresentationIndex + 1
            ) % Self.presentationCapacity
            presentationCount = min(
                presentationCount + 1,
                Self.presentationCapacity
            )
        } else {
            value.droppedPresentations &+= 1
            let sample = MetalDroppedPresentationSample(
                revision: revision,
                liveRevision: liveRevision,
                callbackTime: callbackTime,
                liveReadyTime: liveReadyTime,
                readyTime: readyTime,
                submittedTime: submittedTime,
                submissionContext:
                    submissionContext
                        ?? value.presentationContext,
                callbackContext: value.presentationContext,
                submittedFrames: value.submittedFrames,
                completedFrames: value.completedFrames,
                currentInFlightFrames:
                    value.currentInFlightFrames,
                rendererSuspends: value.rendererSuspends,
                rendererResumes: value.rendererResumes
            )
            droppedPresentationRing[
                nextDroppedPresentationIndex
            ] = sample
            nextDroppedPresentationIndex = (
                nextDroppedPresentationIndex + 1
            ) % Self.droppedPresentationCapacity
            droppedPresentationCount = min(
                droppedPresentationCount + 1,
                Self.droppedPresentationCapacity
            )
        }
        lock.unlock()
        firstPresentation?(presentedTime)
        if let presentationID { scopedPresentation?(presentationID, presentedTime) }
    }

    func recordCommandCompleted(
        succeeded: Bool,
        failure: MetalCommandBufferFailureSummary? = nil
    ) {
        lock.lock()
        value.completedFrames &+= 1
        if value.currentInFlightFrames > 0 {
            value.currentInFlightFrames -= 1
        }
        if !succeeded {
            value.commandBufferErrors &+= 1
            recordLockedCommandBufferFailure(
                failure
                    ?? MetalCommandBufferFailureSummary(
                        status: "unknown"
                    )
            )
        }
        lock.unlock()
    }

    func recordGPUBusySkip() {
        mutate {
            $0.gpuBusySkips &+= 1
        }
    }

    func recordNilDrawableSkip() {
        mutate {
            $0.nilDrawableSkips &+= 1
        }
    }

    func recordBufferCapacityRejection() {
        mutate {
            $0.bufferCapacityRejections &+= 1
        }
    }

    func recordRendererRebuildAttempt() {
        mutate {
            $0.rendererRebuildAttempts &+= 1
        }
    }

    func recordRendererRebuildSuccess() {
        mutate {
            $0.rendererRebuildSuccesses &+= 1
        }
    }

    func recordRendererCircuitBreakerStop() {
        mutate {
            $0.rendererCircuitBreakerStops &+= 1
        }
    }

    func recordMemoryWarning() {
        mutate {
            $0.memoryWarnings &+= 1
        }
    }

    func recordRendererSuspend() {
        mutate {
            $0.rendererSuspends &+= 1
        }
    }

    func recordRendererResume() {
        mutate {
            $0.rendererResumes &+= 1
        }
    }

    func updateHostPresentationContext(
        applicationActivity: MetalApplicationActivity,
        isAttachedToWindow: Bool,
        isHostVisible: Bool,
        isWindowVisible: Bool
    ) {
        mutate {
            $0.presentationContext.applicationActivity =
                applicationActivity
            $0.presentationContext.isHostAttachedToWindow =
                isAttachedToWindow
            $0.presentationContext.isHostVisible = isHostVisible
            $0.presentationContext.isWindowVisible = isWindowVisible
        }
    }

    func updateRendererPresentationContext(
        isSuspended: Bool,
        isInteractionActive: Bool
    ) {
        mutate {
            $0.presentationContext.isRendererSuspended =
                isSuspended
            $0.presentationContext.isInteractionActive =
                isInteractionActive
        }
    }

#if DEBUG
    func recordSimulatedCommandBufferError() {
        mutate {
            $0.simulatedCommandBufferErrors &+= 1
        }
    }
#endif

    func snapshot() -> MetalRendererHealthSnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }
        var snapshot = value
        snapshot.recentPresentations = orderedPresentations()
        snapshot.recentDroppedPresentations =
            orderedDroppedPresentations()
        snapshot.recentCommandBufferFailures =
            orderedCommandBufferFailures()
        return snapshot
    }

    private func orderedPresentations()
        -> [MetalPresentationSample] {
        guard presentationCount > 0 else {
            return []
        }
        let oldestIndex = (
            nextPresentationIndex
            - presentationCount
            + Self.presentationCapacity
        ) % Self.presentationCapacity
        var result: [MetalPresentationSample] = []
        result.reserveCapacity(presentationCount)
        for offset in 0..<presentationCount {
            let index = (
                oldestIndex + offset
            ) % Self.presentationCapacity
            if let sample = presentationRing[index] {
                result.append(sample)
            }
        }
        return result
    }

    private func orderedDroppedPresentations()
        -> [MetalDroppedPresentationSample] {
        guard droppedPresentationCount > 0 else {
            return []
        }
        let oldestIndex = (
            nextDroppedPresentationIndex
            - droppedPresentationCount
            + Self.droppedPresentationCapacity
        ) % Self.droppedPresentationCapacity
        var result: [MetalDroppedPresentationSample] = []
        result.reserveCapacity(droppedPresentationCount)
        for offset in 0..<droppedPresentationCount {
            let index = (
                oldestIndex + offset
            ) % Self.droppedPresentationCapacity
            if let sample = droppedPresentationRing[index] {
                result.append(sample)
            }
        }
        return result
    }

    private func orderedCommandBufferFailures()
        -> [MetalCommandBufferFailureSummary] {
        guard commandFailureCount > 0 else {
            return []
        }
        let oldestIndex = (
            nextCommandFailureIndex
            - commandFailureCount
            + Self.commandFailureCapacity
        ) % Self.commandFailureCapacity
        var result: [MetalCommandBufferFailureSummary] = []
        result.reserveCapacity(commandFailureCount)
        for offset in 0..<commandFailureCount {
            let index = (
                oldestIndex + offset
            ) % Self.commandFailureCapacity
            if let sample = commandFailureRing[index] {
                result.append(sample)
            }
        }
        return result
    }

    private func recordLockedCommandBufferFailure(
        _ failure: MetalCommandBufferFailureSummary
    ) {
        commandFailureRing[nextCommandFailureIndex] = failure
        nextCommandFailureIndex = (
            nextCommandFailureIndex + 1
        ) % Self.commandFailureCapacity
        commandFailureCount = min(
            commandFailureCount + 1,
            Self.commandFailureCapacity
        )
    }

    private func mutate(
        _ body: (inout MetalRendererHealthSnapshot) -> Void
    ) {
        lock.lock()
        body(&value)
        lock.unlock()
    }
}
