import Foundation

enum MetalRendererFailureAction: Equatable, Sendable {
    case rebuild
    case stop
}

struct MetalRendererFailurePolicy: Sendable {
    let failureWindow: TimeInterval
    let maximumConsecutiveFailures: Int
    private(set) var consecutiveFailureTimes: [TimeInterval] = []

    init(
        failureWindow: TimeInterval = 60,
        maximumConsecutiveFailures: Int = 3
    ) {
        self.failureWindow = max(0, failureWindow)
        self.maximumConsecutiveFailures = max(
            1,
            maximumConsecutiveFailures
        )
    }

    mutating func recordFailure(
        at time: TimeInterval
    ) -> MetalRendererFailureAction {
        let lowerBound = time - failureWindow
        consecutiveFailureTimes.removeAll {
            $0 < lowerBound || $0 > time
        }
        consecutiveFailureTimes.append(time)
        return consecutiveFailureTimes.count
            >= maximumConsecutiveFailures
            ? .stop
            : .rebuild
    }

    mutating func recordSuccess() {
        consecutiveFailureTimes.removeAll(
            keepingCapacity: true
        )
    }
}
