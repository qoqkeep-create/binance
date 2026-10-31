import Foundation
import MetricKit
import os

final class ChartMetricKitSubscriber:
    NSObject,
    MXMetricManagerSubscriber,
    @unchecked Sendable {
    static let shared = ChartMetricKitSubscriber()

    private let lock = NSLock()
    private var isStarted = false
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier
            ?? "com.oovso.tradetool",
        category: "KlineChartMetricKit"
    )

    private override init() {
        super.init()
    }

    func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let signpostMetricCount = payloads.reduce(into: 0) {
            $0 += $1.signpostMetrics?.count ?? 0
        }
        let availableCategoryCount = payloads.reduce(into: 0) {
            $0 += Self.availableMetricCategoryCount(in: $1)
        }
        logger.notice(
            """
            chart_metric_payloads=\(payloads.count, privacy: .public) \
            categories=\(availableCategoryCount, privacy: .public) \
            signposts=\(signpostMetricCount, privacy: .public)
            """
        )
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let crashCount = payloads.reduce(into: 0) {
            $0 += $1.crashDiagnostics?.count ?? 0
        }
        let hangCount = payloads.reduce(into: 0) {
            $0 += $1.hangDiagnostics?.count ?? 0
        }
        let cpuExceptionCount = payloads.reduce(into: 0) {
            $0 += $1.cpuExceptionDiagnostics?.count ?? 0
        }
        let diskWriteCount = payloads.reduce(into: 0) {
            $0 += $1.diskWriteExceptionDiagnostics?.count ?? 0
        }
        let launchCount = payloads.reduce(into: 0) {
            $0 += $1.appLaunchDiagnostics?.count ?? 0
        }
        logger.notice(
            """
            chart_diagnostic_payloads=\(payloads.count, privacy: .public) \
            crashes=\(crashCount, privacy: .public) \
            hangs=\(hangCount, privacy: .public) \
            cpu_exceptions=\(cpuExceptionCount, privacy: .public) \
            disk_writes=\(diskWriteCount, privacy: .public) \
            launch=\(launchCount, privacy: .public)
            """
        )
    }

    private static func availableMetricCategoryCount(
        in payload: MXMetricPayload
    ) -> Int {
        [
            payload.cpuMetrics,
            payload.gpuMetrics,
            payload.applicationTimeMetrics,
            payload.networkTransferMetrics,
            payload.applicationLaunchMetrics,
            payload.applicationResponsivenessMetrics,
            payload.diskIOMetrics,
            payload.memoryMetrics,
            payload.displayMetrics,
            payload.animationMetrics,
            payload.applicationExitMetrics,
        ].reduce(into: 0) { count, value in
            if value != nil {
                count += 1
            }
        }
    }
}
