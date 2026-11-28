import Foundation

@MainActor
final class ChartFrameScheduler {
    enum Priority {
        case coalesced
        case immediate
    }

    private let commit: @MainActor (ChartDataFrame) -> Void
    private var pending: ChartDataFrame?
    private var flushTask: Task<Void, Never>?
    private var generation = UUID()

    init(commit: @escaping @MainActor (ChartDataFrame) -> Void) {
        self.commit = commit
    }

    deinit {
        flushTask?.cancel()
    }

    func submit(_ frame: ChartDataFrame, priority: Priority = .coalesced) {
        pending = frame
        if priority == .immediate {
            flush()
            return
        }
        guard flushTask == nil else { return }
        let generation = generation
        flushTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) }
            catch { return }
            guard let self, self.generation == generation else { return }
            self.flushTask = nil
            self.flush()
        }
    }

    func cancel() {
        generation = UUID()
        flushTask?.cancel()
        flushTask = nil
        pending = nil
    }

    private func flush() {
        guard let pending else { return }
        self.pending = nil
        commit(pending)
    }
}
