#if DEBUG
import Darwin
import SwiftUI

enum ChartStressScenario: String, Sendable {
    case quick
    case interaction
    case soak
    case pipeline
    case lifecycle
    case appLifecycle = "app-lifecycle"
}

enum ChartStressPerformanceBudget {
    static let presentationP95Target: TimeInterval = 0.050
    static let histogramUpperBoundTolerance:
        TimeInterval = 0.000_250

    static func acceptsPresentationP95(
        _ histogramUpperBound: TimeInterval
    ) -> Bool {
        histogramUpperBound.isFinite
            && histogramUpperBound >= 0
            && histogramUpperBound
                <= presentationP95Target
                    + histogramUpperBoundTolerance
    }

    static func acceptsLongRunDroppedPresentations(
        _ droppedPresentations: UInt64
    ) -> Bool {
        droppedPresentations == 0
    }
}

struct ChartStressRunConfiguration: Equatable, Sendable {
    let scenario: ChartStressScenario
    let durationSeconds: TimeInterval
    let burstRounds: Int
    let lifecycleCycles: Int
    let appLifecycleCycles: Int
    let externalLifecycleCycles: Int
    let exitAfterResult: Bool

    static func resolve(
        arguments: [String],
        environment: [String: String]
    ) -> ChartStressRunConfiguration {
        let requestedScenario = argumentValue(
            named: "--chart-stress-scenario",
            in: arguments
        ) ?? environment["CHART_STRESS_SCENARIO"]
        let scenario = requestedScenario
            .flatMap(ChartStressScenario.init(rawValue:))
            ?? .quick

        let defaultDuration: TimeInterval
        switch scenario {
        case .quick:
            defaultDuration = 0
        case .interaction:
            defaultDuration = 30 * 60
        case .soak:
            defaultDuration = 2 * 60 * 60
        case .pipeline:
            defaultDuration = 60
        case .lifecycle:
            defaultDuration = 0
        case .appLifecycle:
            defaultDuration = 0
        }
        let requestedDuration = argumentValue(
            named: "--chart-stress-duration",
            in: arguments
        ) ?? environment["CHART_STRESS_DURATION_SECONDS"]
        let parsedDuration = requestedDuration
            .flatMap(TimeInterval.init)
            ?? defaultDuration
        let hasTimedDuration = scenario == .interaction
            || scenario == .soak
            || scenario == .pipeline
        let duration = hasTimedDuration
            ? min(max(parsedDuration, 1), 4 * 60 * 60)
            : 0

        let defaultBurstRounds =
            scenario == .soak || scenario == .pipeline
                ? 10
                : 0
        let requestedBurstRounds = argumentValue(
            named: "--chart-stress-burst-rounds",
            in: arguments
        ) ?? environment["CHART_STRESS_BURST_ROUNDS"]
        let parsedBurstRounds = requestedBurstRounds
            .flatMap(Int.init)
            ?? defaultBurstRounds
        let defaultLifecycleCycles =
            scenario == .lifecycle ? 500 : 0
        let requestedLifecycleCycles = argumentValue(
            named: "--chart-stress-lifecycle-cycles",
            in: arguments
        ) ?? environment["CHART_STRESS_LIFECYCLE_CYCLES"]
        let parsedLifecycleCycles = requestedLifecycleCycles
            .flatMap(Int.init)
            ?? defaultLifecycleCycles
        let lifecycleCycles = scenario == .lifecycle
            ? min(max(parsedLifecycleCycles, 1), 5_000)
            : 0
        let defaultAppLifecycleCycles =
            scenario == .appLifecycle ? 20 : 0
        let requestedAppLifecycleCycles = argumentValue(
            named: "--chart-stress-app-lifecycle-cycles",
            in: arguments
        ) ?? environment["CHART_STRESS_APP_LIFECYCLE_CYCLES"]
        let parsedAppLifecycleCycles = requestedAppLifecycleCycles
            .flatMap(Int.init)
            ?? defaultAppLifecycleCycles
        let appLifecycleCycles = scenario == .appLifecycle
            ? min(max(parsedAppLifecycleCycles, 1), 100)
            : 0
        let requestedExternalLifecycleCycles = argumentValue(
            named: "--chart-stress-external-lifecycle-cycles",
            in: arguments
        ) ?? environment[
            "CHART_STRESS_EXTERNAL_LIFECYCLE_CYCLES"
        ]
        let parsedExternalLifecycleCycles =
            requestedExternalLifecycleCycles
                .flatMap(Int.init)
                ?? 0
        let externalLifecycleCycles = scenario == .appLifecycle
            ? min(max(parsedExternalLifecycleCycles, 0), 10)
            : 0
        let exitAfterResult = booleanSetting(
            argument: "--chart-stress-exit-after-result",
            environmentName: "CHART_STRESS_EXIT_AFTER_RESULT",
            arguments: arguments,
            environment: environment
        )

        return ChartStressRunConfiguration(
            scenario: scenario,
            durationSeconds: duration,
            burstRounds: min(max(parsedBurstRounds, 0), 100),
            lifecycleCycles: lifecycleCycles,
            appLifecycleCycles: appLifecycleCycles,
            externalLifecycleCycles: externalLifecycleCycles,
            exitAfterResult: exitAfterResult
        )
    }

    private static func argumentValue(
        named name: String,
        in arguments: [String]
    ) -> String? {
        let prefix = name + "="
        if let value = arguments.first(where: {
            $0.hasPrefix(prefix)
        }) {
            return String(value.dropFirst(prefix.count))
        }
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func booleanSetting(
        argument: String,
        environmentName: String,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        if arguments.contains(argument) {
            return true
        }
        if let value = argumentValue(
            named: argument,
            in: arguments
        ) {
            return parseBoolean(value)
        }
        return environment[environmentName]
            .map(parseBoolean)
            ?? false
    }

    private static func parseBoolean(_ value: String) -> Bool {
        switch value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}

enum ChartStressLaunchConfiguration {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(
            "--chart-stress"
        )
    }

    static var isMetalValidationEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["MTL_DEBUG_LAYER"] == "1"
            || environment["MTL_SHADER_VALIDATION"] == "1"
    }

    static var runConfiguration: ChartStressRunConfiguration {
        ChartStressRunConfiguration.resolve(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }
}

enum ChartStressResultStore {
    private static let directoryName = "ChartStress"
    private static let maximumBytes = 8 * 1_024

    static var resultURL: URL? {
        fileURL(named: "latest-result.txt")
    }

    static var progressURL: URL? {
        fileURL(named: "latest-progress.txt")
    }

    static func prepareForRun() {
        remove(resultURL)
        remove(progressURL)
    }

    static func writeResult(_ result: String) {
        write(
            "CHART_STRESS_RESULT \(result)\n",
            to: resultURL
        )
    }

    static func writeProgress(_ progress: String) {
        write(
            "CHART_STRESS_PROGRESS \(progress)\n",
            to: progressURL
        )
    }

    private static func fileURL(named name: String) -> URL? {
        guard let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return cachesURL
            .appendingPathComponent(
                directoryName,
                isDirectory: true
            )
            .appendingPathComponent(name)
    }

    private static func write(_ value: String, to url: URL?) {
        guard let url else {
            print(
                "CHART_STRESS_RESULT_STORE_ERROR cache-unavailable"
            )
            return
        }
        let data = Data(value.utf8)
        guard data.count <= maximumBytes else {
            print(
                "CHART_STRESS_RESULT_STORE_ERROR result-too-large"
            )
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            print(
                "CHART_STRESS_RESULT_STORE_ERROR \(error)"
            )
        }
    }

    private static func remove(_ url: URL?) {
        guard let url else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }
}

struct ChartStressHarnessView: View {
    @StateObject private var controller =
        ChartStressHarnessController()
    @State private var previousIdleTimerDisabled: Bool?

    var body: some View {
        ZStack(alignment: .bottom) {
            ChartStressHarnessRepresentable(
                controller: controller
            )
            .background(Color.black)

            Text(controller.resultText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(4)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.86))
                .accessibilityIdentifier("chartStressResult")
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear {
            if previousIdleTimerDisabled == nil {
                previousIdleTimerDisabled =
                    UIApplication.shared.isIdleTimerDisabled
            }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            guard let previousIdleTimerDisabled else {
                return
            }
            UIApplication.shared.isIdleTimerDisabled =
                previousIdleTimerDisabled
            self.previousIdleTimerDisabled = nil
        }
    }
}

private struct ChartStressHarnessRepresentable:
    UIViewRepresentable {
    @ObservedObject var controller: ChartStressHarnessController

    func makeUIView(context: Context) -> KlineChartHostView {
        let view = KlineChartHostView(frame: .zero)
        controller.attach(view)
        return view
    }

    func updateUIView(
        _ view: KlineChartHostView,
        context: Context
    ) {
        controller.attach(view)
    }

    static func dismantleUIView(
        _ view: KlineChartHostView,
        coordinator: Void
    ) {
        view.stopInteractionFrames()
        view.diagnosticDispose()
    }
}

@MainActor
private final class ChartStressHarnessController:
    ObservableObject {
    @Published private(set) var resultText = "RUNNING"

    private weak var hostView: KlineChartHostView?
    private var task: Task<Void, Never>?
    private var hasStarted = false
    private let fixture: ChartStressFixture?
    private let initializationError: Error?
    private let configuration: ChartStressRunConfiguration

    init() {
        ChartStressResultStore.prepareForRun()
        configuration =
            ChartStressLaunchConfiguration.runConfiguration
        do {
            fixture = try ChartStressFixture(
                scale: Float(UIScreen.main.scale)
            )
            initializationError = nil
        } catch {
            fixture = nil
            initializationError = error
        }
    }

    func attach(_ view: KlineChartHostView) {
        hostView = view
        guard !hasStarted else {
            return
        }
        hasStarted = true
        task = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        do {
            if let initializationError {
                throw initializationError
            }
            guard let fixture,
                  let hostView else {
                throw ChartStressHarnessError.hostUnavailable
            }
            try await Task.sleep(nanoseconds: 500_000_000)

            try await warmUp(fixture: fixture, host: hostView)
            switch configuration.scenario {
            case .quick:
                try await runQuick(
                    fixture: fixture,
                    host: hostView
                )
            case .interaction:
                try await runInteraction(
                    fixture: fixture,
                    host: hostView
                )
            case .soak:
                try await runSoak(
                    fixture: fixture,
                    host: hostView
                )
            case .pipeline:
                try await runPipeline(
                    fixture: fixture,
                    host: hostView
                )
            case .lifecycle:
                try await runLifecycle(
                    fixture: fixture,
                    host: hostView
                )
            case .appLifecycle:
                try await runAppLifecycle(
                    fixture: fixture,
                    host: hostView
                )
            }
        } catch {
            let health = hostView?.diagnosticHealthSnapshot()
            let summary = health.map {
                """
                submitted=\($0.submittedFrames) \
                completed=\($0.completedFrames) \
                presented=\($0.presentedFrames) \
                dropped=\($0.droppedPresentations) \
                inflight=\($0.currentInFlightFrames) \
                errors=\($0.commandBufferErrors) \
                \(commandFailureSummary($0)) \
                \(droppedPresentationSummary($0))
                """
            } ?? "health=unavailable"
            publish("FAIL error=\(error) \(summary)")
        }
    }

    private func warmUp(
        fixture: ChartStressFixture,
        host: KlineChartHostView
    ) async throws {
        host.startInteractionFrames()
        host.submit(fixture.state(revision: 10))
        try await waitForPresentation(
            revision: 10,
            host: host,
            requiresIdle: false
        )
        host.stopInteractionFrames()
        try await waitForIdle(host: host)
    }

    private func runQuick(
        fixture: ChartStressFixture,
        host: KlineChartHostView
    ) async throws {
        let fourHertzRange: ClosedRange<UInt64> =
            1_000...1_019
        try await runBurst(
            revisions: fourHertzRange,
            hertz: 4,
            fixture: fixture,
            host: host
        )
        let fourHertzP95 = try p95(
            revisions: fourHertzRange,
            host: host,
            minimumCoverage: 20
        )

        let twentyHertzRange: ClosedRange<UInt64> =
            2_000...2_039
        try await runBurst(
            revisions: twentyHertzRange,
            hertz: 20,
            fixture: fixture,
            host: host
        )
        let twentyHertzP95 = try p95(
            revisions: twentyHertzRange,
            host: host,
            minimumCoverage: 36
        )

        try await validateLifecycle(
            fixture: fixture,
            host: host
        )
        let snapshot = host.diagnosticHealthSnapshot()
        let isValidationRun =
            ChartStressLaunchConfiguration
                .isMetalValidationEnabled
        let latencyPassed = isValidationRun
            || (
                fourHertzP95 < 0.050
                && twentyHertzP95 < 0.050
            )
        let passed = latencyPassed
            && isHealthy(snapshot)
        let result = """
        \(passed ? "PASS" : "FAIL") scenario=quick \
        mode=\(isValidationRun ? "validation" : "performance") \
        4Hz_p95_ms=\(milliseconds(fourHertzP95)) \
        20Hz_p95_ms=\(milliseconds(twentyHertzP95)) \
        submitted=\(snapshot.submittedFrames) \
        completed=\(snapshot.completedFrames) \
        presented=\(snapshot.presentedFrames) \
        dropped=\(snapshot.droppedPresentations) \
        peak_inflight=\(snapshot.peakInFlightFrames) \
        errors=\(snapshot.commandBufferErrors) \
        \(commandFailureSummary(snapshot)) \
        \(droppedPresentationSummary(snapshot)) lifecycle=ok
        """
        publish(result)
    }

    private func runInteraction(
        fixture: ChartStressFixture,
        host: KlineChartHostView
    ) async throws {
        let duration = configuration.durationSeconds
        let start = ProcessInfo.processInfo.systemUptime
        let end = start + duration
        let baseline = host.diagnosticHealthSnapshot()
        var memory = ChartStressMemoryTracker()
        memory.capture()

        var dataRevision: UInt64 = 10_000
        var interactionRevision: UInt64 = 20_000
        var stateSubmissions: UInt64 = 0
        var marketUpdates: UInt64 = 0
        var nextMarketUpdate = start
        var liveReadyTime = start
        var nextMemorySample = start + 1
        let progressInterval = min(
            max(duration / 4, 5),
            30
        )
        var nextProgress = start + progressInterval

        host.startInteractionFrames()
        defer {
            host.stopInteractionFrames()
        }

        while true {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            guard now < end else {
                break
            }

            let dataChanged = now >= nextMarketUpdate
            if dataChanged {
                dataRevision &+= 1
                marketUpdates &+= 1
                liveReadyTime = now
                nextMarketUpdate += 0.25
            }
            interactionRevision &+= 1
            stateSubmissions &+= 1
            let elapsed = now - start
            host.submit(fixture.state(
                dataRevision: dataRevision,
                interactionRevision: interactionRevision,
                interactionPhase: elapsed * 2 * .pi / 3,
                crosshairVisible: true,
                invalidation: dataChanged
                    ? .data.union(.interaction)
                    : .interaction,
                liveReadyTime: liveReadyTime
            ))
            if now >= nextMemorySample {
                memory.capture()
                nextMemorySample = now + 1
            }

            if now >= nextProgress {
                publishProgress(
                    scenario: .interaction,
                    elapsed: elapsed,
                    duration: duration,
                    host: host,
                    memory: memory,
                    baselineDroppedPresentations:
                        baseline.droppedPresentations,
                    startedAt: start
                )
                nextProgress = now + progressInterval
            }
            try await Task.sleep(nanoseconds: 8_333_333)
        }

        host.stopInteractionFrames()
        try await waitForPresentation(
            revision: interactionRevision,
            host: host
        )
        memory.capture()
        let elapsed = max(
            ProcessInfo.processInfo.systemUptime - start,
            0.001
        )
        let snapshot = host.diagnosticHealthSnapshot()
        let presented = counterDelta(
            snapshot.presentedFrames,
            baseline.presentedFrames
        )
        let histogram = snapshot.presentationLatency
            .subtracting(baseline.presentationLatency)
        let readyToSubmitHistogram =
            snapshot.readyToSubmitLatency
                .subtracting(baseline.readyToSubmitLatency)
        let submitToPresentHistogram =
            snapshot.submitToPresentLatency
                .subtracting(baseline.submitToPresentLatency)
        let livePresentationHistogram =
            snapshot.livePresentationLatency
                .subtracting(baseline.livePresentationLatency)
        let liveReadyToSubmitHistogram =
            snapshot.liveReadyToSubmitLatency
                .subtracting(
                    baseline.liveReadyToSubmitLatency
                )
        let liveSubmitToPresentHistogram =
            snapshot.liveSubmitToPresentLatency
                .subtracting(
                    baseline.liveSubmitToPresentLatency
                )
        guard let latencyP95 =
                histogram.percentileUpperBound(0.95),
              let readyToSubmitP95 =
                readyToSubmitHistogram
                    .percentileUpperBound(0.95),
              let submitToPresentP95 =
                submitToPresentHistogram
                    .percentileUpperBound(0.95),
              let livePresentationP95 =
                livePresentationHistogram
                    .percentileUpperBound(0.95),
              let liveReadyToSubmitP95 =
                liveReadyToSubmitHistogram
                    .percentileUpperBound(0.95),
              let liveSubmitToPresentP95 =
                liveSubmitToPresentHistogram
                    .percentileUpperBound(0.95) else {
            throw ChartStressHarnessError
                .insufficientPresentations
        }
        let minimumPresentations = UInt64(
            max(1, Int(duration * 20))
        )
        let marketUpdateRate =
            Double(marketUpdates) / elapsed
        let effectiveFPS =
            Double(presented) / elapsed
        let targetFPS = Double(
            UIScreen.main.maximumFramesPerSecond
        )
        let minimumFPS = targetFPS * 0.90
        let isValidationRun =
            ChartStressLaunchConfiguration
                .isMetalValidationEnabled
        let latencyPassed = isValidationRun
            || ChartStressPerformanceBudget
                .acceptsPresentationP95(
                    livePresentationP95
                )
        let droppedPresentations = counterDelta(
            snapshot.droppedPresentations,
            baseline.droppedPresentations
        )
        let passed = isHealthy(snapshot)
            && latencyPassed
            && ChartStressPerformanceBudget
                .acceptsLongRunDroppedPresentations(
                    droppedPresentations
                )
            && presented >= minimumPresentations
            && marketUpdateRate >= 3.95
            && effectiveFPS >= minimumFPS
        let result = """
        \(passed ? "PASS" : "FAIL") scenario=interaction \
        mode=\(isValidationRun ? "validation" : "performance") \
        duration_s=\(seconds(elapsed)) \
        input=\(stateSubmissions) market_4Hz=\(marketUpdates) \
        market_hz=\(decimal(marketUpdateRate)) \
        presented=\(presented) fps=\(decimal(effectiveFPS)) \
        target_fps=\(decimal(targetFPS)) \
        p95_bucket_ms=\(milliseconds(latencyP95)) \
        market_present_p95_ms=\(milliseconds(livePresentationP95)) \
        p95_target_ms=\(milliseconds(
            ChartStressPerformanceBudget.presentationP95Target
        )) p95_tolerance_ms=\(milliseconds(
            ChartStressPerformanceBudget
                .histogramUpperBoundTolerance
        )) \
        market_ready_submit_p95_ms=\(milliseconds(liveReadyToSubmitP95)) \
        market_submit_present_p95_ms=\(milliseconds(liveSubmitToPresentP95)) \
        ready_submit_p95_ms=\(milliseconds(readyToSubmitP95)) \
        submit_present_p95_ms=\(milliseconds(submitToPresentP95)) \
        dropped=\(droppedPresentations) \
        peak_inflight=\(snapshot.peakInFlightFrames) \
        errors=\(counterDelta(
            snapshot.commandBufferErrors,
            baseline.commandBufferErrors
        )) \(commandFailureSummary(snapshot)) \
        gpu_busy=\(counterDelta(
            snapshot.gpuBusySkips,
            baseline.gpuBusySkips
        )) \(memory.summary) \
        \(droppedPresentationSummary(
            snapshot,
            since: baseline.droppedPresentations,
            startedAt: start
        ))
        """
        publish(result)
    }

    private func runSoak(
        fixture: ChartStressFixture,
        host: KlineChartHostView
    ) async throws {
        let duration = configuration.durationSeconds
        let start = ProcessInfo.processInfo.systemUptime
        let end = start + duration
        let baseline = host.diagnosticHealthSnapshot()
        var memory = ChartStressMemoryTracker()
        memory.capture()

        let windows = burstWindows(
            duration: duration,
            rounds: configuration.burstRounds
        )
        var revision: UInt64 = 30_000
        var stateSubmissions: UInt64 = 0
        var executedBurstRounds = 0
        var wasBursting = false
        var nextSubmission = start
        var nextMemorySample = start + 1
        let progressInterval = min(
            max(duration / 4, 10),
            60
        )
        var nextProgress = start + progressInterval

        while true {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            guard now < end else {
                break
            }
            let elapsed = now - start
            let isBursting = windows.contains {
                $0.contains(elapsed)
            }
            if isBursting != wasBursting {
                if isBursting {
                    executedBurstRounds += 1
                }
                wasBursting = isBursting
                nextSubmission = now
            }

            if now >= nextSubmission {
                revision &+= 1
                stateSubmissions &+= 1
                host.submit(fixture.state(revision: revision))
                let hertz: TimeInterval =
                    isBursting ? 20 : 4
                nextSubmission = now + 1 / hertz
            }
            if now >= nextMemorySample {
                memory.capture()
                nextMemorySample = now + 1
            }

            if now >= nextProgress {
                publishProgress(
                    scenario: .soak,
                    elapsed: elapsed,
                    duration: duration,
                    host: host,
                    memory: memory,
                    baselineDroppedPresentations:
                        baseline.droppedPresentations,
                    startedAt: start
                )
                nextProgress = now + progressInterval
            }

            let nextBoundary = windows
                .flatMap { [$0.lowerBound, $0.upperBound] }
                .filter { $0 > elapsed }
                .min()
                .map { start + $0 }
                ?? end
            let wakeTime = min(
                nextSubmission,
                min(nextBoundary, end)
            )
            let sleepSeconds = max(
                wakeTime
                    - ProcessInfo.processInfo.systemUptime,
                0.001
            )
            try await Task.sleep(
                nanoseconds: UInt64(
                    sleepSeconds * 1_000_000_000
                )
            )
        }

        try await waitForPresentation(
            revision: revision,
            host: host
        )
        memory.capture()
        let elapsed = max(
            ProcessInfo.processInfo.systemUptime - start,
            0.001
        )
        let snapshot = host.diagnosticHealthSnapshot()
        let presented = counterDelta(
            snapshot.presentedFrames,
            baseline.presentedFrames
        )
        let histogram = snapshot.presentationLatency
            .subtracting(baseline.presentationLatency)
        let readyToSubmitHistogram =
            snapshot.readyToSubmitLatency
                .subtracting(baseline.readyToSubmitLatency)
        let submitToPresentHistogram =
            snapshot.submitToPresentLatency
                .subtracting(baseline.submitToPresentLatency)
        guard let latencyP95 =
                histogram.percentileUpperBound(0.95),
              let readyToSubmitP95 =
                readyToSubmitHistogram
                    .percentileUpperBound(0.95),
              let submitToPresentP95 =
                submitToPresentHistogram
                    .percentileUpperBound(0.95) else {
            throw ChartStressHarnessError
                .insufficientPresentations
        }
        let minimumPresentations = UInt64(
            max(1, Int(Double(stateSubmissions) * 0.75))
        )
        let isValidationRun =
            ChartStressLaunchConfiguration
                .isMetalValidationEnabled
        let latencyPassed = isValidationRun
            || ChartStressPerformanceBudget
                .acceptsPresentationP95(latencyP95)
        let droppedPresentations = counterDelta(
            snapshot.droppedPresentations,
            baseline.droppedPresentations
        )
        let passed = isHealthy(snapshot)
            && latencyPassed
            && ChartStressPerformanceBudget
                .acceptsLongRunDroppedPresentations(
                    droppedPresentations
                )
            && presented >= minimumPresentations
            && executedBurstRounds == windows.count
        let result = """
        \(passed ? "PASS" : "FAIL") scenario=soak \
        mode=\(isValidationRun ? "validation" : "performance") \
        duration_s=\(seconds(elapsed)) \
        updates=\(stateSubmissions) burst_rounds=\(executedBurstRounds) \
        presented=\(presented) p95_bucket_ms=\(milliseconds(latencyP95)) \
        ready_submit_p95_ms=\(milliseconds(readyToSubmitP95)) \
        submit_present_p95_ms=\(milliseconds(submitToPresentP95)) \
        dropped=\(droppedPresentations) \
        peak_inflight=\(snapshot.peakInFlightFrames) \
        errors=\(counterDelta(
            snapshot.commandBufferErrors,
            baseline.commandBufferErrors
        )) \(commandFailureSummary(snapshot)) \
        gpu_busy=\(counterDelta(
            snapshot.gpuBusySkips,
            baseline.gpuBusySkips
        )) \(memory.summary) \
        \(droppedPresentationSummary(
            snapshot,
            since: baseline.droppedPresentations,
            startedAt: start
        ))
        """
        publish(result)
    }

    private func runPipeline(
        fixture: ChartStressFixture,
        host: KlineChartHostView
    ) async throws {
        guard let pipeline = ChartStressIngressPipeline(
            initialClosed:
                fixture.staticScene.candleHistory.candles
        ) else {
            throw ChartStressHarnessError.pipelineUnavailable
        }
        let duration = configuration.durationSeconds
        let start = ProcessInfo.processInfo.systemUptime
        let end = start + duration
        let baseline = host.diagnosticHealthSnapshot()
        var memory = ChartStressMemoryTracker()
        memory.capture()

        let windows = burstWindows(
            duration: duration,
            rounds: configuration.burstRounds
        )
        var executedBurstRounds = 0
        var wasBursting = false
        var renderRevision: UInt64 = 40_000
        var renderSubmissions: UInt64 = 0
        var nextSubmission = start
        var nextMemorySample = start + 1
        let progressInterval = min(
            max(duration / 4, 5),
            30
        )
        var nextProgress = start + progressInterval

        while true {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            guard now < end else {
                break
            }
            let elapsed = now - start
            let isBursting = windows.contains {
                $0.contains(elapsed)
            }
            if isBursting != wasBursting {
                if isBursting {
                    executedBurstRounds += 1
                    let faultFrames =
                        await pipeline.injectFaultRound(
                            readyTime: now
                        )
                    for frame in faultFrames {
                        renderRevision &+= 1
                        renderSubmissions &+= 1
                        host.submit(fixture.state(
                            pipelineFrame: frame,
                            interactionRevision:
                                renderRevision
                        ))
                    }
                }
                wasBursting = isBursting
                nextSubmission = now
            }

            if now >= nextSubmission {
                if let frame = await pipeline.nextFrame(
                    updatesPerDrain: isBursting ? 4 : 1,
                    readyTime: now
                ) {
                    renderRevision &+= 1
                    renderSubmissions &+= 1
                    host.submit(fixture.state(
                        pipelineFrame: frame,
                        interactionRevision: renderRevision
                    ))
                }
                let hertz: TimeInterval =
                    isBursting ? 20 : 4
                nextSubmission += 1 / hertz
                if nextSubmission < now - 1 {
                    nextSubmission = now + 1 / hertz
                }
            }
            if now >= nextMemorySample {
                memory.capture()
                nextMemorySample = now + 1
            }
            if now >= nextProgress {
                publishProgress(
                    scenario: .pipeline,
                    elapsed: elapsed,
                    duration: duration,
                    host: host,
                    memory: memory,
                    baselineDroppedPresentations:
                        baseline.droppedPresentations,
                    startedAt: start
                )
                nextProgress = now + progressInterval
            }

            let nextBoundary = windows
                .flatMap { [$0.lowerBound, $0.upperBound] }
                .filter { $0 > elapsed }
                .min()
                .map { start + $0 }
                ?? end
            let wakeTime = min(
                nextSubmission,
                min(nextBoundary, end)
            )
            let sleepSeconds = max(
                wakeTime
                    - ProcessInfo.processInfo.systemUptime,
                0.001
            )
            try await Task.sleep(
                nanoseconds: UInt64(
                    sleepSeconds * 1_000_000_000
                )
            )
        }

        try await waitForPresentation(
            revision: renderRevision,
            host: host
        )
        memory.capture()
        let elapsed = max(
            ProcessInfo.processInfo.systemUptime - start,
            0.001
        )
        let snapshot = host.diagnosticHealthSnapshot()
        let pipelineHealth = await pipeline.health()
        let counters = pipelineHealth.counters
        let presented = counterDelta(
            snapshot.presentedFrames,
            baseline.presentedFrames
        )
        let histogram = snapshot.presentationLatency
            .subtracting(baseline.presentationLatency)
        guard let latencyP95 =
                histogram.percentileUpperBound(0.95) else {
            throw ChartStressHarnessError
                .insufficientPresentations
        }
        let droppedPresentations = counterDelta(
            snapshot.droppedPresentations,
            baseline.droppedPresentations
        )
        let expectedFaultRounds = UInt64(
            executedBurstRounds
        )
        let expectedRecoveries =
            expectedFaultRounds * 4
        let minimumPresentations = UInt64(
            max(1, Int(Double(renderSubmissions) * 0.75))
        )
        let isValidationRun =
            ChartStressLaunchConfiguration
                .isMetalValidationEnabled
        let latencyPassed = isValidationRun
            || ChartStressPerformanceBudget
                .acceptsPresentationP95(latencyP95)
        let pipelinePassed =
            executedBurstRounds == windows.count
            && counters.ignoredDuplicateOrLateEvents
                == expectedFaultRounds
            && counters.sequenceGaps == expectedFaultRounds
            && counters.invalidCandles == expectedFaultRounds
            && counters.outOfOrderOpenTimes
                == expectedFaultRounds
            && counters.upstreamBufferDrops
                == expectedFaultRounds
            && counters.recoveryRequests
                == expectedRecoveries
            && counters.recoveryCompletions
                == expectedRecoveries
            && (
                windows.isEmpty
                || counters.coalescedEvents > 0
            )
            && counters.provisionalEMAFrames > 0
            && counters.invalidEMAFrames == 0
            && counters.liveHistoryCopyViolations == 0
            && counters.maximumPendingLiveUpserts <= 1
            && counters.maximumPendingBarriers <= 8
            && !pipelineHealth.hasPendingLiveUpsert
            && pipelineHealth.pendingBarrierCount == 0
            && !pipelineHealth.hasPendingRecovery
            && pipelineHealth.historyCount == 3_000
        let passed = isHealthy(snapshot)
            && latencyPassed
            && ChartStressPerformanceBudget
                .acceptsLongRunDroppedPresentations(
                    droppedPresentations
                )
            && pipelinePassed
            && presented >= minimumPresentations
        let result = """
        \(passed ? "PASS" : "FAIL") scenario=pipeline \
        mode=\(isValidationRun ? "validation" : "performance") \
        duration_s=\(seconds(elapsed)) \
        events=\(counters.upstreamEvents) \
        render_states=\(renderSubmissions) \
        burst_rounds=\(executedBurstRounds) \
        accepted=\(counters.acceptedEvents) \
        coalesced=\(counters.coalescedEvents) \
        duplicates=\(counters.ignoredDuplicateOrLateEvents) \
        recoveries=\(counters.recoveryRequests) \
        recovery_completed=\(counters.recoveryCompletions) \
        seq_gaps=\(counters.sequenceGaps) \
        invalid=\(counters.invalidCandles) \
        out_of_order=\(counters.outOfOrderOpenTimes) \
        upstream_drops=\(counters.upstreamBufferDrops) \
        applied=\(counters.appliedMutations) \
        ema_frames=\(counters.provisionalEMAFrames) \
        ema_invalid=\(counters.invalidEMAFrames) \
        history_copy_violations=\(
            counters.liveHistoryCopyViolations
        ) max_pending_live=\(
            counters.maximumPendingLiveUpserts
        ) max_barriers=\(counters.maximumPendingBarriers) \
        history=\(pipelineHealth.historyCount) \
        presented=\(presented) \
        p95_bucket_ms=\(milliseconds(latencyP95)) \
        dropped=\(droppedPresentations) \
        peak_inflight=\(snapshot.peakInFlightFrames) \
        errors=\(counterDelta(
            snapshot.commandBufferErrors,
            baseline.commandBufferErrors
        )) \(commandFailureSummary(snapshot)) \
        gpu_busy=\(counterDelta(
            snapshot.gpuBusySkips,
            baseline.gpuBusySkips
        )) \(memory.summary) \
        \(droppedPresentationSummary(
            snapshot,
            since: baseline.droppedPresentations,
            startedAt: start
        ))
        """
        publish(result)
    }

    private func runLifecycle(
        fixture: ChartStressFixture,
        host: KlineChartHostView
    ) async throws {
        let cycles = configuration.lifecycleCycles
        var memory = ChartStressMemoryTracker()
        memory.capture()
        var destroyedHosts = 0
        var immediateDestructions = 0
        var observedInFlightDestructions = 0
        var presentedCycles = 0
        var maximumPeakInFlight: UInt64 = 0
        var droppedPresentations: UInt64 = 0
        let progressStep = max(1, cycles / 10)

        for cycle in 1...cycles {
            try Task.checkCancellation()
            var candidate: KlineChartHostView? =
                makeLifecycleHost(in: host)
            let weakReference = ChartStressWeakHostReference(
                candidate
            )
            let baseRevision = UInt64(40_000 + cycle * 16)
            let shouldDestroyImmediately =
                cycle.isMultiple(of: 3)
                || (cycles < 3 && cycle == cycles)
            var expectedRevision = baseRevision
            var snapshotBeforeRemoval:
                MetalRendererHealthSnapshot?

            if let active = candidate {
                if cycle.isMultiple(of: 7) {
                    active.diagnosticMemoryWarning()
                }

                if shouldDestroyImmediately {
                    immediateDestructions += 1
                    for offset in UInt64(0)...2 {
                        expectedRevision = baseRevision + offset
                        active.submit(fixture.state(
                            revision: expectedRevision
                        ))
                        active.diagnosticDraw()
                    }
                } else if cycle.isMultiple(of: 11) {
                    active.diagnosticSuspend()
                    let beforeSuspend =
                        active.diagnosticHealthSnapshot()
                    for offset in UInt64(1)...8 {
                        expectedRevision = baseRevision + offset
                        active.submit(fixture.state(
                            revision: expectedRevision
                        ))
                    }
                    let suspended =
                        active.diagnosticHealthSnapshot()
                    guard suspended.submittedFrames
                            == beforeSuspend.submittedFrames else {
                        throw ChartStressHarnessError
                            .lifecycleHealthFailure
                    }
                    active.diagnosticResume()
                    active.diagnosticDraw()
                } else {
                    active.submit(fixture.state(
                        revision: expectedRevision
                    ))
                    active.diagnosticDraw()
                }

                if shouldDestroyImmediately {
                    snapshotBeforeRemoval =
                        active.diagnosticHealthSnapshot()
                    if snapshotBeforeRemoval?
                        .currentInFlightFrames ?? 0 > 0 {
                        observedInFlightDestructions += 1
                    }
                } else {
                    try await waitForPresentation(
                        revision: expectedRevision,
                        host: active
                    )
                    presentedCycles += 1
                    snapshotBeforeRemoval =
                        active.diagnosticHealthSnapshot()
                }
            }

            if let snapshotBeforeRemoval {
                guard snapshotBeforeRemoval.commandBufferErrors == 0,
                      snapshotBeforeRemoval
                        .bufferCapacityRejections == 0,
                      snapshotBeforeRemoval
                        .rendererCircuitBreakerStops == 0 else {
                    throw ChartStressHarnessError
                        .lifecycleHealthFailure
                }
                maximumPeakInFlight = max(
                    maximumPeakInFlight,
                    snapshotBeforeRemoval.peakInFlightFrames
                )
                droppedPresentations &+=
                    snapshotBeforeRemoval.droppedPresentations
            }

            candidate?.removeFromSuperview()
            candidate = nil
            try await waitForDeallocation(weakReference)
            destroyedHosts += 1

            if cycle.isMultiple(of: 10) {
                memory.capture()
            }
            if cycle.isMultiple(of: progressStep)
                || cycle == cycles {
                let progress = """
                RUNNING scenario=lifecycle \
                cycles=\(cycle)/\(cycles) \
                destroyed=\(destroyedHosts) \
                inflight_destroy=\(observedInFlightDestructions) \
                \(memory.summary)
                """
                resultText = progress
                print("CHART_STRESS_PROGRESS \(progress)")
            }
        }

        let faultResult = try await validateSimulatedFailures(
            fixture: fixture,
            host: host
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        memory.capture()
        let rootSnapshot = host.diagnosticHealthSnapshot()
        let expectedImmediateDestructions =
            cycles / 3 + (cycles < 3 ? 1 : 0)
        let passed = destroyedHosts == cycles
            && immediateDestructions
                == expectedImmediateDestructions
            && observedInFlightDestructions > 0
            && faultResult.simulatedFailures == 5
            && faultResult.rebuildAttempts == 4
            && faultResult.rebuildSuccesses == 4
            && faultResult.circuitBreakerStops == 1
            && isHealthy(rootSnapshot)
        let result = """
        \(passed ? "PASS" : "FAIL") scenario=lifecycle \
        mode=\(ChartStressLaunchConfiguration
            .isMetalValidationEnabled ? "validation" : "performance") \
        cycles=\(cycles) destroyed=\(destroyedHosts) \
        immediate=\(immediateDestructions) \
        inflight_destroy=\(observedInFlightDestructions) \
        presented_cycles=\(presentedCycles) \
        peak_inflight=\(maximumPeakInFlight) \
        dropped=\(droppedPresentations) \
        simulated_errors=\(faultResult.simulatedFailures) \
        \(commandFailureSummary(rootSnapshot)) \
        rebuilds=\(faultResult.rebuildSuccesses) \
        circuit_stops=\(faultResult.circuitBreakerStops) \
        \(memory.summary)
        """
        publish(result)
    }

    private func runAppLifecycle(
        fixture: ChartStressFixture,
        host: KlineChartHostView
    ) async throws {
        let cycles = configuration.appLifecycleCycles
        let externalCycles =
            configuration.externalLifecycleCycles
        let baseline = host.diagnosticHealthSnapshot()
        var observedInFlightSuspends = 0
        var coalescedStates = 0

        for cycle in 1...cycles {
            try Task.checkCancellation()
            let baseRevision = UInt64(120_000 + cycle * 64)
            let queuedRange =
                (baseRevision + 1)...(baseRevision + 25)

            host.startInteractionFrames()
            host.submit(fixture.state(revision: baseRevision))
            host.diagnosticDraw()
            if host.diagnosticHealthSnapshot()
                .currentInFlightFrames > 0 {
                observedInFlightSuspends += 1
            }

            NotificationCenter.default.post(
                name: UIApplication.willResignActiveNotification,
                object: nil
            )
            NotificationCenter.default.post(
                name: UIApplication.willResignActiveNotification,
                object: nil
            )
            let inactiveBaseline =
                host.diagnosticHealthSnapshot()
            guard host.diagnosticIsRendererSuspended,
                  !host.diagnosticIsApplicationActive,
                  !host.diagnosticIsInteractionActive,
                  inactiveBaseline.rendererSuspends
                    == baseline.rendererSuspends
                        + UInt64(cycle) else {
                throw ChartStressHarnessError
                    .appLifecycleStateMismatch
            }

            for revision in queuedRange {
                host.submit(fixture.state(revision: revision))
                host.diagnosticDraw()
            }
            if cycle.isMultiple(of: 5) {
                host.diagnosticMemoryWarning()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            let whileInactive =
                host.diagnosticHealthSnapshot()
            guard whileInactive.submittedFrames
                    == inactiveBaseline.submittedFrames,
                  whileInactive.lastPresentedRevision
                    < queuedRange.lowerBound else {
                throw ChartStressHarnessError
                    .appLifecycleSubmittedFrame
            }

            NotificationCenter.default.post(
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
            NotificationCenter.default.post(
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
            guard !host.diagnosticIsRendererSuspended,
                  host.diagnosticIsApplicationActive,
                  host.diagnosticIsInteractionActive else {
                throw ChartStressHarnessError
                    .appLifecycleStateMismatch
            }
            try await waitForPresentation(
                revision: queuedRange.upperBound,
                host: host
            )
            let resumed = host.diagnosticHealthSnapshot()
            let queuedPresentations = Set(
                resumed.recentPresentations
                    .map(\.revision)
                    .filter(queuedRange.contains)
            )
            guard resumed.rendererResumes
                    == baseline.rendererResumes
                        + UInt64(cycle),
                  queuedPresentations
                    == Set([queuedRange.upperBound]),
                  resumed.commandBufferErrors == 0,
                  resumed.bufferCapacityRejections == 0 else {
                throw ChartStressHarnessError
                    .appLifecycleStateMismatch
            }
            coalescedStates += queuedRange.count - 1
        }

        for cycleIndex in 0..<externalCycles {
            let before = host.diagnosticHealthSnapshot()
            let cycle = cycleIndex + 1
            let progress = """
            WAITING scenario=app-lifecycle \
            external_cycle=\(cycle)/\(externalCycles) \
            action=background_then_foreground
            """
            resultText = progress
            print("CHART_STRESS_PROGRESS \(progress)")
            try await waitForExternalLifecycleCycle(
                suspendTarget: before.rendererSuspends + 1,
                resumeTarget: before.rendererResumes + 1,
                host: host
            )
            try await waitForIdle(host: host)
        }

        let snapshot = host.diagnosticHealthSnapshot()
        let passed = isHealthy(snapshot)
            && !host.diagnosticIsRendererSuspended
            && host.diagnosticIsApplicationActive
        let result = """
        \(passed ? "PASS" : "FAIL") \
        scenario=app-lifecycle \
        synthetic_cycles=\(cycles) \
        external_cycles=\(externalCycles) \
        inflight_suspends=\(observedInFlightSuspends) \
        coalesced_states=\(coalescedStates) \
        suspends=\(counterDelta(
            snapshot.rendererSuspends,
            baseline.rendererSuspends
        )) \
        resumes=\(counterDelta(
            snapshot.rendererResumes,
            baseline.rendererResumes
        )) \
        submitted=\(snapshot.submittedFrames) \
        presented=\(snapshot.presentedFrames) \
        dropped=\(snapshot.droppedPresentations) \
        errors=\(snapshot.commandBufferErrors) \
        \(commandFailureSummary(snapshot)) \
        \(droppedPresentationSummary(
            snapshot,
            since: baseline.droppedPresentations
        ))
        """
        publish(result)
    }

    private func waitForExternalLifecycleCycle(
        suspendTarget: UInt64,
        resumeTarget: UInt64,
        host: KlineChartHostView
    ) async throws {
        let deadline =
            ProcessInfo.processInfo.systemUptime + 90
        while ProcessInfo.processInfo.systemUptime < deadline {
            let snapshot = host.diagnosticHealthSnapshot()
            if snapshot.rendererSuspends >= suspendTarget,
               snapshot.rendererResumes >= resumeTarget,
               !host.diagnosticIsRendererSuspended,
               host.diagnosticIsApplicationActive {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ChartStressHarnessError
            .externalLifecycleTimedOut
    }

    private func validateSimulatedFailures(
        fixture: ChartStressFixture,
        host: KlineChartHostView
    ) async throws -> ChartStressFaultInjectionResult {
        var recoveryHost: KlineChartHostView? =
            makeLifecycleHost(in: host)
        let recoveryReference = ChartStressWeakHostReference(
            recoveryHost
        )
        var recoverySnapshot = MetalRendererHealthSnapshot()
        do {
            guard let activeRecoveryHost = recoveryHost else {
                throw ChartStressHarnessError.hostUnavailable
            }
            activeRecoveryHost.diagnosticInjectCommandFailure()
            recoverySnapshot =
                activeRecoveryHost.diagnosticHealthSnapshot()
            guard recoverySnapshot
                    .simulatedCommandBufferErrors == 1,
                  recoverySnapshot.rendererRebuildAttempts == 1,
                  recoverySnapshot.rendererRebuildSuccesses == 1,
                  recoverySnapshot.rendererCircuitBreakerStops == 0,
                  !activeRecoveryHost
                    .diagnosticIsRendererStopped else {
                throw ChartStressHarnessError
                    .simulatedFailureMismatch
            }

            let recoveryRevision: UInt64 = 90_001
            activeRecoveryHost.submit(fixture.state(
                revision: recoveryRevision
            ))
            activeRecoveryHost.diagnosticDraw()
            try await waitForPresentation(
                revision: recoveryRevision,
                host: activeRecoveryHost
            )
            try await Task.sleep(nanoseconds: 10_000_000)
            activeRecoveryHost.diagnosticInjectCommandFailure()
            recoverySnapshot =
                activeRecoveryHost.diagnosticHealthSnapshot()
            guard recoverySnapshot
                    .simulatedCommandBufferErrors == 2,
                  recoverySnapshot.rendererRebuildAttempts == 2,
                  recoverySnapshot.rendererRebuildSuccesses == 2,
                  recoverySnapshot.rendererCircuitBreakerStops == 0,
                  !activeRecoveryHost
                    .diagnosticIsRendererStopped else {
                throw ChartStressHarnessError
                    .simulatedFailureMismatch
            }
        }

        recoveryHost?.removeFromSuperview()
        recoveryHost = nil
        try await waitForDeallocation(recoveryReference)

        var breakerHost: KlineChartHostView? =
            makeLifecycleHost(in: host)
        let breakerReference = ChartStressWeakHostReference(
            breakerHost
        )
        var breakerSnapshot = MetalRendererHealthSnapshot()
        do {
            guard let activeBreakerHost = breakerHost else {
                throw ChartStressHarnessError.hostUnavailable
            }
            activeBreakerHost.diagnosticInjectCommandFailure()
            activeBreakerHost.diagnosticInjectCommandFailure()
            activeBreakerHost.diagnosticInjectCommandFailure()
            breakerSnapshot =
                activeBreakerHost.diagnosticHealthSnapshot()
            guard breakerSnapshot
                    .simulatedCommandBufferErrors == 3,
                  breakerSnapshot.rendererRebuildAttempts == 2,
                  breakerSnapshot.rendererRebuildSuccesses == 2,
                  breakerSnapshot.rendererCircuitBreakerStops == 1,
                  activeBreakerHost
                    .diagnosticIsRendererStopped else {
                throw ChartStressHarnessError
                    .simulatedFailureMismatch
            }
            let submittedBeforeStop =
                breakerSnapshot.submittedFrames
            activeBreakerHost.submit(fixture.state(
                revision: 90_002
            ))
            activeBreakerHost.diagnosticDraw()
            try await Task.sleep(nanoseconds: 10_000_000)
            guard activeBreakerHost
                    .diagnosticHealthSnapshot()
                    .submittedFrames == submittedBeforeStop else {
                throw ChartStressHarnessError
                    .simulatedFailureMismatch
            }
        }

        breakerHost?.removeFromSuperview()
        breakerHost = nil
        try await waitForDeallocation(breakerReference)

        return ChartStressFaultInjectionResult(
            simulatedFailures:
                recoverySnapshot.simulatedCommandBufferErrors
                + breakerSnapshot.simulatedCommandBufferErrors,
            rebuildAttempts:
                recoverySnapshot.rendererRebuildAttempts
                + breakerSnapshot.rendererRebuildAttempts,
            rebuildSuccesses:
                recoverySnapshot.rendererRebuildSuccesses
                + breakerSnapshot.rendererRebuildSuccesses,
            circuitBreakerStops:
                recoverySnapshot.rendererCircuitBreakerStops
                + breakerSnapshot.rendererCircuitBreakerStops
        )
    }

    private func makeLifecycleHost(
        in parent: KlineChartHostView
    ) -> KlineChartHostView {
        let fallback = CGRect(
            x: 0,
            y: 0,
            width: 390,
            height: 300
        )
        let frame = parent.bounds.width > 0
            && parent.bounds.height > 0
            ? parent.bounds
            : fallback
        let child = autoreleasepool {
            KlineChartHostView(frame: frame)
        }
        child.autoresizingMask = [
            .flexibleWidth,
            .flexibleHeight,
        ]
        parent.addSubview(child)
        child.setNeedsLayout()
        child.layoutIfNeeded()
        return child
    }

    private func waitForDeallocation(
        _ reference: ChartStressWeakHostReference
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if reference.value == nil {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ChartStressHarnessError.lifecycleHostLeak
    }

    private func burstWindows(
        duration: TimeInterval,
        rounds: Int
    ) -> [ClosedRange<TimeInterval>] {
        guard rounds > 0 else {
            return []
        }
        let burstDuration = min(
            2,
            max(0.25, duration / Double(rounds * 4))
        )
        return (0..<rounds).map { index in
            let center = duration
                * Double(index + 1)
                / Double(rounds + 1)
            let lower = max(0, center - burstDuration / 2)
            let upper = min(duration, lower + burstDuration)
            return lower...upper
        }
    }

    private func runBurst(
        revisions: ClosedRange<UInt64>,
        hertz: UInt64,
        fixture: ChartStressFixture,
        host: KlineChartHostView
    ) async throws {
        let interval = 1_000_000_000 / hertz
        for revision in revisions {
            host.submit(fixture.state(revision: revision))
            try await Task.sleep(nanoseconds: interval)
        }
        try await waitForPresentation(
            revision: revisions.upperBound,
            host: host
        )
    }

    private func validateLifecycle(
        fixture: ChartStressFixture,
        host: KlineChartHostView
    ) async throws {
        host.diagnosticSuspend()
        let beforeSuspend = host.diagnosticHealthSnapshot()
        for revision in UInt64(3_001)...3_025 {
            host.submit(fixture.state(revision: revision))
        }
        host.diagnosticMemoryWarning()
        try await Task.sleep(nanoseconds: 100_000_000)
        let suspended = host.diagnosticHealthSnapshot()
        guard suspended.submittedFrames
                == beforeSuspend.submittedFrames,
              suspended.lastPresentedRevision
                == beforeSuspend.lastPresentedRevision,
              suspended.memoryWarnings
                == beforeSuspend.memoryWarnings + 1 else {
            throw ChartStressHarnessError.suspendSubmittedFrame
        }

        host.diagnosticResume()
        try await waitForPresentation(
            revision: 3_025,
            host: host
        )
    }

    private func waitForPresentation(
        revision: UInt64,
        host: KlineChartHostView,
        requiresIdle: Bool = true
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var nextRetryTime =
            ProcessInfo.processInfo.systemUptime + 0.05
        while ProcessInfo.processInfo.systemUptime < deadline {
            let now = ProcessInfo.processInfo.systemUptime
            let snapshot = host.diagnosticHealthSnapshot()
            if snapshot.lastPresentedRevision >= revision,
               !requiresIdle
                    || snapshot.currentInFlightFrames == 0 {
                return
            }
            if requiresIdle,
               snapshot.lastPresentedRevision < revision,
               snapshot.currentInFlightFrames == 0,
               now >= nextRetryTime {
                // A completed drawable may transiently report presentedTime
                // zero during rapid view churn. Retry the retained latest
                // state, but still require a real presented callback.
                host.diagnosticDraw()
                nextRetryTime = now + 0.05
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ChartStressHarnessError.presentationTimedOut
    }

    private func waitForIdle(
        host: KlineChartHostView
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while ProcessInfo.processInfo.systemUptime < deadline {
            if host.diagnosticHealthSnapshot()
                .currentInFlightFrames == 0 {
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw ChartStressHarnessError.presentationTimedOut
    }

    private func p95(
        revisions: ClosedRange<UInt64>,
        host: KlineChartHostView,
        minimumCoverage: Int
    ) throws -> TimeInterval {
        let grouped = Dictionary(
            grouping: host.diagnosticHealthSnapshot()
                .recentPresentations
                .filter { revisions.contains($0.revision) },
            by: \.revision
        )
        let durations = grouped.values.compactMap { samples in
            samples.compactMap(\.readyToPresentDuration).min()
        }.sorted()
        guard durations.count >= minimumCoverage else {
            throw ChartStressHarnessError.insufficientPresentations
        }
        let index = min(
            durations.count - 1,
            Int(ceil(Double(durations.count) * 0.95)) - 1
        )
        return durations[max(0, index)]
    }

    private func milliseconds(_ value: TimeInterval) -> String {
        String(format: "%.3f", value * 1_000)
    }

    private func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }

    private func decimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func counterDelta(
        _ current: UInt64,
        _ baseline: UInt64
    ) -> UInt64 {
        current >= baseline ? current - baseline : 0
    }

    private func isHealthy(
        _ snapshot: MetalRendererHealthSnapshot
    ) -> Bool {
        snapshot.commandBufferErrors == 0
            && snapshot.bufferCapacityRejections == 0
            && snapshot.currentInFlightFrames == 0
            && snapshot.peakInFlightFrames <= 3
    }

    private func commandFailureSummary(
        _ snapshot: MetalRendererHealthSnapshot
    ) -> String {
        guard let failure =
                snapshot.recentCommandBufferFailures.last else {
            return "last_gpu_error=none"
        }
        let domain = failure.errorDomain ?? "none"
        let code = failure.errorCode.map(String.init) ?? "none"
        return """
        last_gpu_status=\(failure.status) \
        last_gpu_domain=\(domain) \
        last_gpu_code=\(code)
        """
    }

    private func droppedPresentationSummary(
        _ snapshot: MetalRendererHealthSnapshot,
        since baselineDroppedPresentations: UInt64 = 0,
        startedAt: TimeInterval? = nil
    ) -> String {
        guard snapshot.droppedPresentations
                > baselineDroppedPresentations,
              let sample =
                snapshot.recentDroppedPresentations.last else {
            return "last_drop=none"
        }
        let submission = sample.submissionContext
        let callback = sample.callbackContext
        let timeSummary: String
        if let startedAt {
            let elapsed = seconds(max(
                sample.callbackTime - startedAt,
                0
            ))
            timeSummary = "last_drop_elapsed_s=\(elapsed)"
        } else {
            let uptime = seconds(sample.callbackTime)
            timeSummary = "last_drop_uptime_s=\(uptime)"
        }
        let callbackLatency = sample.submitToCallbackDuration
            .map(milliseconds)
            ?? "invalid"
        return """
        last_drop_revision=\(sample.revision) \
        last_drop_live_revision=\(sample.liveRevision) \
        \(timeSummary) \
        last_drop_submit_callback_ms=\(callbackLatency) \
        last_drop_submit_app=\(
            submission.applicationActivity.rawValue
        ) \
        last_drop_submit_attached=\(
            submission.isHostAttachedToWindow ? 1 : 0
        ) \
        last_drop_submit_host_visible=\(
            submission.isHostVisible ? 1 : 0
        ) \
        last_drop_submit_window_visible=\(
            submission.isWindowVisible ? 1 : 0
        ) \
        last_drop_submit_suspended=\(
            submission.isRendererSuspended ? 1 : 0
        ) \
        last_drop_submit_interaction=\(
            submission.isInteractionActive ? 1 : 0
        ) \
        last_drop_callback_app=\(
            callback.applicationActivity.rawValue
        ) \
        last_drop_callback_attached=\(
            callback.isHostAttachedToWindow ? 1 : 0
        ) \
        last_drop_callback_host_visible=\(
            callback.isHostVisible ? 1 : 0
        ) \
        last_drop_callback_window_visible=\(
            callback.isWindowVisible ? 1 : 0
        ) \
        last_drop_callback_suspended=\(
            callback.isRendererSuspended ? 1 : 0
        ) \
        last_drop_callback_interaction=\(
            callback.isInteractionActive ? 1 : 0
        ) \
        last_drop_submitted=\(sample.submittedFrames) \
        last_drop_completed=\(sample.completedFrames) \
        last_drop_inflight=\(sample.currentInFlightFrames) \
        last_drop_suspend_count=\(sample.rendererSuspends) \
        last_drop_resume_count=\(sample.rendererResumes)
        """
    }

    private func publishProgress(
        scenario: ChartStressScenario,
        elapsed: TimeInterval,
        duration: TimeInterval,
        host: KlineChartHostView,
        memory: ChartStressMemoryTracker,
        baselineDroppedPresentations: UInt64,
        startedAt: TimeInterval
    ) {
        let snapshot = host.diagnosticHealthSnapshot()
        let progress = """
        RUNNING scenario=\(scenario.rawValue) \
        elapsed_s=\(seconds(elapsed))/\(seconds(duration)) \
        submitted=\(snapshot.submittedFrames) \
        presented=\(snapshot.presentedFrames) \
        dropped=\(counterDelta(
            snapshot.droppedPresentations,
            baselineDroppedPresentations
        )) \(memory.summary) \
        \(droppedPresentationSummary(
            snapshot,
            since: baselineDroppedPresentations,
            startedAt: startedAt
        ))
        """
        resultText = progress
        ChartStressResultStore.writeProgress(progress)
        print("CHART_STRESS_PROGRESS \(progress)")
    }

    private func publish(_ result: String) {
        resultText = result
        ChartStressResultStore.writeResult(result)
        print("CHART_STRESS_RESULT \(result)")
        guard configuration.exitAfterResult else {
            return
        }
        Darwin.fflush(nil)
        Darwin._exit(
            result.hasPrefix("PASS ")
                ? EXIT_SUCCESS
                : EXIT_FAILURE
        )
    }
}

struct ChartStressPipelineCounters: Equatable, Sendable {
    var upstreamEvents: UInt64 = 0
    var acceptedEvents: UInt64 = 0
    var coalescedEvents: UInt64 = 0
    var ignoredDuplicateOrLateEvents: UInt64 = 0
    var recoveryRequests: UInt64 = 0
    var recoveryCompletions: UInt64 = 0
    var sequenceGaps: UInt64 = 0
    var invalidCandles: UInt64 = 0
    var outOfOrderOpenTimes: UInt64 = 0
    var upstreamBufferDrops: UInt64 = 0
    var appliedMutations: UInt64 = 0
    var provisionalEMAFrames: UInt64 = 0
    var invalidEMAFrames: UInt64 = 0
    var liveHistoryCopyViolations: UInt64 = 0
    var maximumPendingLiveUpserts = 0
    var maximumPendingBarriers = 0
}

struct ChartStressPipelineHealth: Equatable, Sendable {
    let counters: ChartStressPipelineCounters
    let hasPendingLiveUpsert: Bool
    let pendingBarrierCount: Int
    let hasPendingRecovery: Bool
    let historyCount: Int
}

struct ChartStressPipelineFrame: Sendable {
    let candleSnapshot: ChartCandleSnapshot
    let emaValues: [Double]
    let liveReadyTime: TimeInterval

    var revision: UInt64 {
        candleSnapshot.revision
    }
}

actor ChartStressIngressPipeline {
    private static let intervalMilliseconds: Int64 =
        3_600_000

    private var ingress: KlineIngressState
    private let store: CandleStore
    private var ema21: EMAIndicatorCalculator
    private var ema55: EMAIndicatorCalculator
    private var ema144: EMAIndicatorCalculator
    private var counters = ChartStressPipelineCounters()
    private let epoch = KlineStreamEpoch(generation: 1)
    private let stream = ChartStreamKey(
        symbol: "BTCUSDC",
        interval: "1h"
    )
    private var sequence: Int64 = 0
    private var eventOrdinal: UInt64 = 0
    private let liveOpenTime: Int64
    private let basePrice: Double

    init?(
        initialClosed: [ChartCandle],
        barrierCapacity: Int = 8
    ) {
        let closed = initialClosed
            .filter(\.isValid)
            .map { $0.withClosure(.closed) }
            .sorted { $0.openTime < $1.openTime }
        guard let last = closed.last,
              let nextOpenTime = Self.adding(
                Self.intervalMilliseconds,
                to: last.openTime
              ),
              var ema21 = EMAIndicatorCalculator(
                period: 21,
                intervalMilliseconds:
                    Self.intervalMilliseconds
              ),
              var ema55 = EMAIndicatorCalculator(
                period: 55,
                intervalMilliseconds:
                    Self.intervalMilliseconds
              ),
              var ema144 = EMAIndicatorCalculator(
                period: 144,
                intervalMilliseconds:
                    Self.intervalMilliseconds
              ) else {
            return nil
        }
        for candle in closed {
            ema21.commit(candle)
            ema55.commit(candle)
            ema144.commit(candle)
        }

        var ingress = KlineIngressState(
            barrierCapacity: barrierCapacity
        )
        ingress.beginEpoch(epoch, stream: stream)
        ingress.completeRecovery(
            newestOpenTime: last.openTime
        )

        self.ingress = ingress
        store = CandleStore(
            initialClosed: closed,
            historyLimit: 3_000
        )
        self.ema21 = ema21
        self.ema55 = ema55
        self.ema144 = ema144
        liveOpenTime = nextOpenTime
        basePrice = last.closePrice
    }

    func nextFrame(
        updatesPerDrain: Int,
        readyTime: TimeInterval
    ) async -> ChartStressPipelineFrame? {
        let updateCount = min(max(updatesPerDrain, 1), 32)
        for _ in 0..<updateCount {
            sequence += 1
            eventOrdinal &+= 1
            let event = makeEvent(
                sequence: sequence,
                openTime: liveOpenTime,
                closePrice: nextClosePrice(),
                closure: .provisional,
                readyTime: readyTime
            )
            record(ingress.accept(event))
            captureIngressBounds()
        }
        return await drainAndApply(readyTime: readyTime)
    }

    func injectFaultRound(
        readyTime: TimeInterval
    ) async -> [ChartStressPipelineFrame] {
        var frames: [ChartStressPipelineFrame] = []

        let duplicate = makeEvent(
            sequence: sequence,
            openTime: liveOpenTime,
            closePrice: nextClosePrice(),
            closure: .provisional,
            readyTime: readyTime
        )
        record(ingress.accept(duplicate))
        captureIngressBounds()
        if let frame = await drainAndApply(
            readyTime: readyTime
        ) {
            frames.append(frame)
        }

        let invalid = makeInvalidEvent(
            sequence: sequence + 1,
            readyTime: readyTime
        )
        record(ingress.accept(invalid))
        captureIngressBounds()
        if let frame = await drainAndApply(
            readyTime: readyTime
        ) {
            frames.append(frame)
        }

        sequence += 2
        eventOrdinal &+= 1
        let gap = makeEvent(
            sequence: sequence,
            openTime: liveOpenTime,
            closePrice: nextClosePrice(),
            closure: .provisional,
            readyTime: readyTime
        )
        record(ingress.accept(gap))
        captureIngressBounds()
        if let frame = await drainAndApply(
            readyTime: readyTime
        ) {
            frames.append(frame)
        }

        sequence += 1
        let previousOpenTime = max(
            0,
            liveOpenTime - Self.intervalMilliseconds
        )
        let outOfOrder = makeEvent(
            sequence: sequence,
            openTime: previousOpenTime,
            closePrice: basePrice,
            closure: .provisional,
            readyTime: readyTime
        )
        record(ingress.accept(outOfOrder))
        captureIngressBounds()
        if let frame = await drainAndApply(
            readyTime: readyTime
        ) {
            frames.append(frame)
        }

        ingress.markUpstreamBufferDropped()
        counters.upstreamBufferDrops &+= 1
        captureIngressBounds()
        if let frame = await drainAndApply(
            readyTime: readyTime
        ) {
            frames.append(frame)
        }
        return frames
    }

    func health() async -> ChartStressPipelineHealth {
        let snapshot = await store.snapshot()
        return ChartStressPipelineHealth(
            counters: counters,
            hasPendingLiveUpsert:
                ingress.pendingLiveUpsert != nil,
            pendingBarrierCount:
                ingress.pendingBarrierCount,
            hasPendingRecovery:
                ingress.recoveryRequest != nil,
            historyCount: snapshot.history.candles.count
        )
    }

    private func record(
        _ disposition: KlineIngressDisposition
    ) {
        counters.upstreamEvents &+= 1
        switch disposition {
        case .accepted:
            counters.acceptedEvents &+= 1
        case .coalesced:
            counters.coalescedEvents &+= 1
        case .ignoredDuplicateOrLate:
            counters.ignoredDuplicateOrLateEvents &+= 1
        case .ignoredWrongEpochOrStream:
            break
        case .recoveryRequired:
            break
        }
    }

    private func captureIngressBounds() {
        counters.maximumPendingLiveUpserts = max(
            counters.maximumPendingLiveUpserts,
            ingress.pendingLiveUpsert == nil ? 0 : 1
        )
        counters.maximumPendingBarriers = max(
            counters.maximumPendingBarriers,
            ingress.pendingBarrierCount
        )
    }

    private func drainAndApply(
        readyTime: TimeInterval
    ) async -> ChartStressPipelineFrame? {
        let drain = ingress.drain()
        if let recoveryRequest = drain.recoveryRequest {
            recordRecovery(recoveryRequest.reason)
            return await recover(readyTime: readyTime)
        }

        var latestSnapshot: ChartCandleSnapshot?
        for mutation in drain.mutations {
            let before = await store.snapshot()
            let after = await store.apply(mutation)
            if mutation.candle.closure != .closed,
               before.history !== after.history {
                counters.liveHistoryCopyViolations &+= 1
            }
            if mutation.candle.closure == .closed {
                ema21.commit(mutation.candle)
                ema55.commit(mutation.candle)
                ema144.commit(mutation.candle)
            }
            ingress.confirmApplied(revision: mutation.revision)
            counters.appliedMutations &+= 1
            latestSnapshot = after
        }
        guard let latestSnapshot else {
            return nil
        }
        return makeFrame(
            snapshot: latestSnapshot,
            readyTime: readyTime
        )
    }

    private func recover(
        readyTime: TimeInterval
    ) async -> ChartStressPipelineFrame {
        let current = await store.snapshot()
        let restored = await store.installSnapshot(
            closedCandles: current.history.candles,
            liveCandle: current.liveTail
        )
        let newestOpenTime =
            restored.liveTail?.openTime
                ?? restored.history.candles.last?.openTime
        ingress.completeRecovery(
            newestOpenTime: newestOpenTime
        )
        counters.recoveryCompletions &+= 1
        return makeFrame(
            snapshot: restored,
            readyTime: readyTime
        )
    }

    private func makeFrame(
        snapshot: ChartCandleSnapshot,
        readyTime: TimeInterval
    ) -> ChartStressPipelineFrame {
        let emaValues = [
            ema21.provisional(snapshot.liveTail)?.value,
            ema55.provisional(snapshot.liveTail)?.value,
            ema144.provisional(snapshot.liveTail)?.value,
        ].compactMap { $0 }
        if emaValues.count == 3 {
            counters.provisionalEMAFrames &+= 1
        } else {
            counters.invalidEMAFrames &+= 1
        }
        return ChartStressPipelineFrame(
            candleSnapshot: snapshot,
            emaValues: emaValues,
            liveReadyTime: readyTime
        )
    }

    private func recordRecovery(
        _ reason: KlineRecoveryReason
    ) {
        counters.recoveryRequests &+= 1
        switch reason {
        case .sequenceGap:
            counters.sequenceGaps &+= 1
        case .invalidCandle:
            counters.invalidCandles &+= 1
        case .outOfOrderOpenTime:
            counters.outOfOrderOpenTimes &+= 1
        case .upstreamBufferDropped:
            break
        case .epochChanged,
             .barrierOverflow,
             .missingTrustedClose,
             .downstreamStateInvalid:
            break
        }
    }

    private func nextClosePrice() -> Double {
        basePrice
            + sin(Double(eventOrdinal) * 0.17) * 24
            + cos(Double(eventOrdinal) * 0.07) * 8
    }

    private func makeEvent(
        sequence: Int64,
        openTime: Int64,
        closePrice: Double,
        closure: ChartCandleClosure,
        readyTime: TimeInterval
    ) -> KlineIngressEvent {
        let openPrice = basePrice
        let highPrice = max(openPrice, closePrice) + 8
        let lowPrice = min(openPrice, closePrice) - 8
        return KlineIngressEvent(
            epoch: epoch,
            stream: stream,
            sequence: sequence,
            eventTime: Self.eventTime(readyTime),
            candle: ChartCandle(
                openTime: openTime,
                closeTime:
                    openTime
                        + Self.intervalMilliseconds
                        - 1,
                openPrice: openPrice,
                highPrice: highPrice,
                lowPrice: lowPrice,
                closePrice: closePrice,
                volume: 10 + Double(eventOrdinal % 20),
                quoteVolume: closePrice * 10,
                closure: closure
            )
        )
    }

    private func makeInvalidEvent(
        sequence: Int64,
        readyTime: TimeInterval
    ) -> KlineIngressEvent {
        KlineIngressEvent(
            epoch: epoch,
            stream: stream,
            sequence: sequence,
            eventTime: Self.eventTime(readyTime),
            candle: ChartCandle(
                openTime: liveOpenTime,
                closeTime:
                    liveOpenTime
                        + Self.intervalMilliseconds
                        - 1,
                openPrice: basePrice,
                highPrice: basePrice + 8,
                lowPrice: basePrice - 8,
                closePrice: .nan,
                volume: 10,
                quoteVolume: basePrice * 10,
                closure: .provisional
            )
        )
    }

    private static func adding(
        _ value: Int64,
        to source: Int64
    ) -> Int64? {
        let result = source.addingReportingOverflow(value)
        return result.overflow ? nil : result.partialValue
    }

    private static func eventTime(
        _ readyTime: TimeInterval
    ) -> Int64 {
        guard readyTime.isFinite, readyTime >= 0 else {
            return 0
        }
        return Int64(
            min(
                readyTime * 1_000,
                Double(Int64.max)
            )
        )
    }
}

private final class ChartStressFixture {
    let scale: Float
    let staticScene: StaticSceneSnapshot
    private var pipelineStaticScene: StaticSceneSnapshot?

    init(scale: Float) throws {
        guard scale.isFinite, scale > 0 else {
            throw ChartStressHarnessError.invalidScale
        }
        self.scale = scale

        let candleCount = 200
        let candles = (0..<candleCount).map { index in
            let x = Float(index) * 1.85 * scale + scale
            let center = (
                85 + sin(Float(index) * 0.17) * 34
            ) * scale
            return ChartCandleInstance(
                x: x,
                openY: center - 5 * scale,
                highY: center - 13 * scale,
                lowY: center + 14 * scale,
                closeY: center + (
                    index.isMultiple(of: 2) ? 5 : -5
                ) * scale,
                halfBodyWidth: 0.75 * scale,
                isRising: index.isMultiple(of: 2)
            )
        }

        var lineSegments: [ChartLineSegmentInstance] = []
        for indicator in 0..<3 {
            let points = (0..<candleCount).map { index in
                ChartPolylinePoint(
                    x: Float(index) * 1.85 * scale + scale,
                    y: (
                        90
                        + Float(indicator) * 12
                        + sin(
                            Float(index) * 0.11
                            + Float(indicator)
                        ) * 22
                    ) * scale
                )
            }
            lineSegments.append(
                contentsOf: ChartBatchCompiler.lineSegments(
                    spans: [points],
                    width: scale,
                    color: .neutral
                )
            )
        }
        for tool in 0..<100 {
            let offset = Float(tool % 20) * 3 * scale
            lineSegments.append(
                ChartLineSegmentInstance(
                    start: ChartPolylinePoint(
                        x: 20 * scale + offset,
                        y: 170 * scale
                    ),
                    end: ChartPolylinePoint(
                        x: 160 * scale + offset,
                        y: 205 * scale
                    ),
                    width: scale,
                    dashLength: 0,
                    gapLength: 0,
                    dashPhase: 0,
                    color: .neutral
                )
            )
        }

        let volumeBars = (0..<candleCount).map { index in
            let left = Float(index) * 1.85 * scale
            return ChartBarInstance(
                left: left,
                top: (270 - Float(index % 18)) * scale,
                right: left + 1.3 * scale,
                bottom: 292 * scale,
                color: index.isMultiple(of: 2)
                    ? .positive
                    : .negative
            )
        }

        guard let key = ChartGlyphAtlasKey(
            fontName: "HelveticaNeue",
            pointSize: 11,
            displayScale: Double(scale),
            localeIdentifier: "zh-Hans"
        ) else {
            throw ChartStressHarnessError.glyphAtlasUnavailable
        }
        let atlas = try MetalGlyphAtlasBuilder().build(
            key: key,
            seedStrings: ["EMA(21) 63,900.8 最新价格"]
        )
        let glyphs = MetalTextLayouter.layout(
            text: "EMA(21) 63,900.8 最新价格",
            atlas: atlas,
            originX: Double(8 * scale),
            baselineY: Double(24 * scale),
            color: .neutral
        ).instances
        let batch = ChartRenderBatch(
            candleInstances: candles,
            lineSegments: lineSegments,
            barInstances: volumeBars,
            glyphInstances: glyphs,
            glyphAtlas: atlas
        )
        let history = (0..<3_000).map { index in
            let close = 60_000 + Double(index % 250)
            return ChartCandle(
                openTime: Int64(index) * 3_600_000,
                closeTime: Int64(index + 1) * 3_600_000 - 1,
                openPrice: close - 5,
                highPrice: close + 10,
                lowPrice: close - 10,
                closePrice: close,
                volume: 10,
                quoteVolume: close * 10,
                closure: .closed
            )
        }
        staticScene = StaticSceneSnapshot(
            revision: 1,
            candleHistory: ChartCandleHistory(candles: history),
            batches: [batch]
        )
    }

    func state(revision: UInt64) -> RenderState {
        state(
            dataRevision: revision,
            interactionRevision: revision,
            interactionPhase: 0,
            crosshairVisible: false,
            invalidation: .data
        )
    }

    func state(
        pipelineFrame: ChartStressPipelineFrame,
        interactionRevision: UInt64
    ) -> RenderState {
        state(
            dataRevision: pipelineFrame.revision,
            interactionRevision: interactionRevision,
            interactionPhase: 0,
            crosshairVisible: false,
            invalidation: [.data, .indicators],
            liveReadyTime: pipelineFrame.liveReadyTime,
            candle: pipelineFrame.candleSnapshot.liveTail,
            indicatorValues: pipelineFrame.emaValues,
            candleHistory:
                pipelineFrame.candleSnapshot.history
        )
    }

    func state(
        dataRevision: UInt64,
        interactionRevision: UInt64,
        interactionPhase: TimeInterval,
        crosshairVisible: Bool,
        invalidation: ChartInvalidation,
        liveReadyTime: TimeInterval? = nil,
        candle: ChartCandle? = nil,
        indicatorValues: [Double] = [],
        candleHistory: ChartCandleHistory? = nil
    ) -> RenderState {
        let readyTime =
            ProcessInfo.processInfo.systemUptime
        let safePhase = interactionPhase.isFinite
            ? interactionPhase
            : 0
        let priceY = candle.map {
            chartY(for: $0.closePrice)
        } ?? (
            120 * scale
                + Float(dataRevision % 7) * 0.25 * scale
        )
        let crosshair = crosshairVisible
            ? ChartPolylinePoint(
                x: (
                    195 + Float(sin(safePhase)) * 130
                ) * scale,
                y: (
                    135 + Float(cos(safePhase * 0.7)) * 75
                ) * scale
            )
            : nil
        var lineSegments = [
            ChartLineSegmentInstance(
                start: ChartPolylinePoint(x: 0, y: priceY),
                end: ChartPolylinePoint(
                    x: 390 * scale,
                    y: priceY
                ),
                width: scale,
                dashLength: 4 * scale,
                gapLength: 3 * scale,
                dashPhase: 0,
                color: .neutral
            ),
        ]
        for (index, value) in indicatorValues
            .filter(\.isFinite)
            .prefix(3)
            .enumerated() {
            let indicatorY = chartY(for: value)
            lineSegments.append(
                ChartLineSegmentInstance(
                    start: ChartPolylinePoint(
                        x: 344 * scale,
                        y: indicatorY
                    ),
                    end: ChartPolylinePoint(
                        x: 390 * scale,
                        y: indicatorY
                    ),
                    width: scale,
                    dashLength: 0,
                    gapLength: 0,
                    dashPhase: 0,
                    color: index.isMultiple(of: 2)
                        ? .positive
                        : .negative
                )
            )
        }
        if let crosshair {
            lineSegments.append(
                ChartLineSegmentInstance(
                    start: ChartPolylinePoint(
                        x: crosshair.x,
                        y: 0
                    ),
                    end: ChartPolylinePoint(
                        x: crosshair.x,
                        y: 300 * scale
                    ),
                    width: scale,
                    dashLength: 2 * scale,
                    gapLength: 2 * scale,
                    dashPhase: 0,
                    color: .neutral
                )
            )
            lineSegments.append(
                ChartLineSegmentInstance(
                    start: ChartPolylinePoint(
                        x: 0,
                        y: crosshair.y
                    ),
                    end: ChartPolylinePoint(
                        x: 390 * scale,
                        y: crosshair.y
                    ),
                    width: scale,
                    dashLength: 2 * scale,
                    gapLength: 2 * scale,
                    dashPhase: 0,
                    color: .neutral
                )
            )
        }
        let candleInstance = candle.map {
            ChartCandleInstance(
                x: 370 * scale,
                openY: chartY(for: $0.openPrice),
                highY: chartY(for: $0.highPrice),
                lowY: chartY(for: $0.lowPrice),
                closeY: chartY(for: $0.closePrice),
                halfBodyWidth: 1.5 * scale,
                isRising: $0.closePrice >= $0.openPrice
            )
        } ?? ChartCandleInstance(
            x: 370 * scale,
            openY: priceY - 8 * scale,
            highY: priceY - 14 * scale,
            lowY: priceY + 15 * scale,
            closeY: priceY + 5 * scale,
            halfBodyWidth: 1.5 * scale,
            isRising: dataRevision.isMultiple(of: 2)
        )
        let batch = ChartRenderBatch(
            candleInstances: [candleInstance],
            lineSegments: lineSegments
        )
        let selectedStaticScene: StaticSceneSnapshot
        if let candleHistory {
            if let pipelineStaticScene,
               pipelineStaticScene.candleHistory
                === candleHistory {
                selectedStaticScene = pipelineStaticScene
            } else {
                let replacement = StaticSceneSnapshot(
                    revision: dataRevision,
                    candleHistory: candleHistory,
                    batches: staticScene.batches
                )
                pipelineStaticScene = replacement
                selectedStaticScene = replacement
            }
        } else {
            selectedStaticScene = staticScene
        }
        return RenderState(
            staticScene: selectedStaticScene,
            liveTail: LiveTailSnapshot(
                revision: dataRevision,
                readyTime: liveReadyTime ?? readyTime,
                candle: candle,
                batches: [batch],
                latestPrice: candle?.closePrice ?? 63_900
            ),
            interaction: InteractionSnapshot(
                revision: interactionRevision,
                translationX: sin(safePhase) * 36 * Double(scale),
                scaleX: 1 + sin(safePhase * 0.5) * 0.18,
                crosshair: nil
            ),
            invalidation: invalidation,
            readyTime: readyTime
        )
    }

    private func chartY(for price: Double) -> Float {
        guard price.isFinite else {
            return 120 * scale
        }
        let points = 120 - Float(price - 60_125) * 0.18
        return min(max(points, 20), 240) * scale
    }
}

private struct ChartStressMemoryTracker {
    private var startBytes: UInt64?
    private var currentBytes: UInt64?
    private var peakBytes: UInt64?

    mutating func capture() {
        guard let bytes = ChartStressProcessMemory.residentBytes else {
            return
        }
        if startBytes == nil {
            startBytes = bytes
        }
        currentBytes = bytes
        peakBytes = max(peakBytes ?? bytes, bytes)
    }

    var summary: String {
        guard let startBytes,
              let currentBytes,
              let peakBytes else {
            return "rss=unavailable"
        }
        return """
        rss_start_mb=\(megabytes(startBytes)) \
        rss_end_mb=\(megabytes(currentBytes)) \
        rss_peak_delta_mb=\(megabytes(
            peakBytes >= startBytes
                ? peakBytes - startBytes
                : 0
        ))
        """
    }

    private func megabytes(_ bytes: UInt64) -> String {
        String(
            format: "%.1f",
            Double(bytes) / 1_048_576
        )
    }
}

private enum ChartStressProcessMemory {
    static var residentBytes: UInt64? {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            infoPointer in
            infoPointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        return UInt64(info.resident_size)
    }
}

private final class ChartStressWeakHostReference {
    weak var value: KlineChartHostView?

    init(_ value: KlineChartHostView?) {
        self.value = value
    }
}

private struct ChartStressFaultInjectionResult {
    let simulatedFailures: UInt64
    let rebuildAttempts: UInt64
    let rebuildSuccesses: UInt64
    let circuitBreakerStops: UInt64
}

private enum ChartStressHarnessError: Error {
    case hostUnavailable
    case invalidScale
    case glyphAtlasUnavailable
    case pipelineUnavailable
    case presentationTimedOut
    case insufficientPresentations
    case suspendSubmittedFrame
    case lifecycleHostLeak
    case lifecycleHealthFailure
    case simulatedFailureMismatch
    case appLifecycleStateMismatch
    case appLifecycleSubmittedFrame
    case externalLifecycleTimedOut
}
#endif
