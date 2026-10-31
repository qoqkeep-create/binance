actor RealtimeKlineIngress {
    private var state: KlineIngressState

    init(barrierCapacity: Int = 8) {
        state = KlineIngressState(
            barrierCapacity: barrierCapacity
        )
    }

    func beginEpoch(
        _ epoch: KlineStreamEpoch,
        stream: ChartStreamKey
    ) {
        state.beginEpoch(epoch, stream: stream)
    }

    func accept(
        _ event: KlineIngressEvent
    ) -> KlineIngressDisposition {
        state.accept(event)
    }

    func markUpstreamBufferDropped() {
        state.markUpstreamBufferDropped()
    }

    func drain(
        includeLiveTail: Bool = true
    ) -> KlineIngressDrain {
        state.drain(includeLiveTail: includeLiveTail)
    }

    func confirmApplied(revision: UInt64) {
        state.confirmApplied(revision: revision)
    }

    func completeRecovery(
        newestOpenTime: Int64?
    ) {
        state.completeRecovery(newestOpenTime: newestOpenTime)
    }

    func snapshot() -> KlineIngressState {
        state
    }
}
