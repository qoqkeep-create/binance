import Foundation
import Metal

final class MetalResourceRing: @unchecked Sendable {
    struct Lease {
        let index: Int
        let buffer: MTLBuffer
        fileprivate let generation: UInt64
    }

    private enum SlotState {
        case available
        case leased(generation: UInt64)
        case quarantined
    }

    private struct Slot {
        let buffer: MTLBuffer
        var state: SlotState
        var nextGeneration: UInt64
    }

    private let lock = NSLock()
    private var slots: [Slot]
    let capacityPerSlot: Int

    init?(
        device: MTLDevice,
        slotCount: Int = 3,
        capacityPerSlot: Int
    ) {
        guard slotCount > 0, capacityPerSlot > 0 else {
            return nil
        }

        var allocated: [Slot] = []
        allocated.reserveCapacity(slotCount)
        for index in 0..<slotCount {
            guard let buffer = device.makeBuffer(
                length: capacityPerSlot,
                options: .storageModeShared
            ) else {
                return nil
            }
            buffer.label = "Chart dynamic frame \(index)"
            allocated.append(
                Slot(
                    buffer: buffer,
                    state: .available,
                    nextGeneration: 1
                )
            )
        }
        slots = allocated
        self.capacityPerSlot = capacityPerSlot
    }

    func acquire(requiredBytes: Int) -> Lease? {
        guard requiredBytes >= 0,
              requiredBytes <= capacityPerSlot else {
            return nil
        }

        lock.lock()
        defer {
            lock.unlock()
        }

        guard let index = slots.firstIndex(where: {
            if case .available = $0.state {
                return true
            }
            return false
        }) else {
            return nil
        }
        let generation = slots[index].nextGeneration
        slots[index].nextGeneration &+= 1
        slots[index].state = .leased(generation: generation)
        return Lease(
            index: index,
            buffer: slots[index].buffer,
            generation: generation
        )
    }

    func releaseWithoutSubmission(_ lease: Lease) {
        update(
            lease,
            newState: .available
        )
    }

    func complete(
        _ lease: Lease,
        succeeded: Bool
    ) {
        update(
            lease,
            newState: succeeded ? .available : .quarantined
        )
    }

    var availableSlotCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return slots.reduce(into: 0) { count, slot in
            if case .available = slot.state {
                count += 1
            }
        }
    }

    var quarantinedSlotCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return slots.reduce(into: 0) { count, slot in
            if case .quarantined = slot.state {
                count += 1
            }
        }
    }

    private func update(
        _ lease: Lease,
        newState: SlotState
    ) {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard slots.indices.contains(lease.index),
              slots[lease.index].buffer === lease.buffer,
              case let .leased(generation) = slots[lease.index].state,
              generation == lease.generation else {
            return
        }
        slots[lease.index].state = newState
    }
}
