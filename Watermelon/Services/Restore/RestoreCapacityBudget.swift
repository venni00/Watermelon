import Foundation

struct RestoreReservations: Sendable {
    struct Snapshot: Equatable, Sendable {
        var count = 0
        var pendingCount = 0
        var bufferedPendingCount = 0
        var unknownCount = 0
        var totalBytes: Int64 = 0
        var bufferedBytes: Int64 = 0
        var largestBytes: Int64 = 0

        var isEmpty: Bool { count == 0 }
    }

    private struct Entry: Sendable {
        let index: Int
        var bytes: Int64
        var oversized: Bool
        var committed = false
    }

    private var heap: [Entry] = []
    private var positions: [Int: Int] = [:]
    private var pendingCount = 0
    private var bufferedPendingCount = 0
    private var unknownCount = 0
    // Exact wide totals allow removals to recover from Int64 saturation.
    private var totalBytes: UInt128 = 0
    private var bufferedBytes: UInt128 = 0

    var snapshot: Snapshot {
        Snapshot(count: heap.count, pendingCount: pendingCount, bufferedPendingCount: bufferedPendingCount,
            unknownCount: unknownCount, totalBytes: Int64(min(totalBytes, UInt128(Int64.max))),
            bufferedBytes: Int64(min(bufferedBytes, UInt128(Int64.max))), largestBytes: heap.first?.bytes ?? 0)
    }

    func isOversized(_ index: Int) -> Bool {
        positions[index].map { heap[$0].oversized } ?? false
    }

    mutating func insert(_ index: Int, bytes: Int64, oversized: Bool) {
        precondition(positions[index] == nil)
        let entry = Entry(index: index, bytes: max(0, bytes), oversized: oversized)
        positions[index] = heap.count
        heap.append(entry)
        addTotals(entry)
        siftUp(from: heap.count - 1)
    }

    mutating func update(_ index: Int, bytes: Int64, oversized: Bool) {
        guard let position = positions[index] else { return }
        var entry = heap[position]
        removeTotals(entry)
        entry.bytes = max(0, bytes)
        entry.oversized = entry.oversized || oversized
        heap[position] = entry
        addTotals(entry)
        repair(at: position)
    }

    mutating func markCommitted(_ index: Int) {
        guard let position = positions[index], !heap[position].committed else { return }
        pendingCount -= 1
        if !heap[position].oversized { bufferedPendingCount -= 1 }
        heap[position].committed = true
    }

    mutating func remove(_ index: Int) {
        guard let position = positions[index] else { return }
        removeTotals(heap[position])
        let last = heap.removeLast()
        positions[index] = nil
        if position < heap.count {
            heap[position] = last
            positions[last.index] = position
            repair(at: position)
        }
    }

    private mutating func addTotals(_ entry: Entry) {
        totalBytes += UInt128(entry.bytes)
        if !entry.oversized { bufferedBytes += UInt128(entry.bytes) }
        if entry.bytes == 0 { unknownCount += 1 }
        if !entry.committed {
            pendingCount += 1
            if !entry.oversized { bufferedPendingCount += 1 }
        }
    }

    private mutating func removeTotals(_ entry: Entry) {
        totalBytes -= UInt128(entry.bytes)
        if !entry.oversized { bufferedBytes -= UInt128(entry.bytes) }
        if entry.bytes == 0 { unknownCount -= 1 }
        if !entry.committed {
            pendingCount -= 1
            if !entry.oversized { bufferedPendingCount -= 1 }
        }
    }

    private mutating func repair(at position: Int) {
        if position > 0, heap[position].bytes > heap[(position - 1) / 2].bytes {
            siftUp(from: position)
        } else {
            siftDown(from: position)
        }
    }

    private mutating func siftUp(from position: Int) {
        var child = position
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].bytes > heap[parent].bytes else { return }
            swap(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from position: Int) {
        var parent = position
        while parent * 2 + 1 < heap.count {
            var child = parent * 2 + 1
            if child + 1 < heap.count, heap[child + 1].bytes > heap[child].bytes { child += 1 }
            guard heap[child].bytes > heap[parent].bytes else { return }
            swap(parent, child)
            parent = child
        }
    }

    private mutating func swap(_ lhs: Int, _ rhs: Int) {
        heap.swapAt(lhs, rhs)
        positions[heap[lhs].index] = lhs
        positions[heap[rhs].index] = rhs
    }
}

final class RestorePrefetchBudget: @unchecked Sendable {
    static let fallbackBytes: Int64 = 256 * 1024 * 1024
    private let lock = NSLock()
    private var bytes: Int64?

    func resolve(availableCapacity: () -> Int64?) -> Int64 {
        lock.withLock {
            if let bytes { return bytes }
            let limit = availableCapacity().map { max(0, $0) / 10 } ?? Self.fallbackBytes
            bytes = limit
            return limit
        }
    }
}

final class RestoreCapacityBudget: @unchecked Sendable {
    private static let origin = ContinuousClock.now

    private static func now() -> Double {
        let duration = origin.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    private let lock = NSLock()
    private let query: @Sendable () -> Int64?
    private let clock: @Sendable () -> Double
    private var sampledAt: Double?
    private var remaining: Int64?

    init(query: @escaping @Sendable () -> Int64?,
         clock: @escaping @Sendable () -> Double = RestoreCapacityBudget.now) {
        self.query = query
        self.clock = clock
    }

    func available(force: Bool = false) -> Int64? {
        lock.withLock {
            if force || sampledAt == nil || clock() - sampledAt! >= 2 {
                remaining = query().map { max(0, $0) }
                sampledAt = clock()
            }
            return remaining
        }
    }

    func consume(_ bytes: Int64) {
        lock.withLock {
            guard let remaining else { return }
            // Cached free space must also cover writes made after the sample, including Photos copies.
            let cost = RestoreDownloadPolicy.adding(bytes, RestoreDownloadPolicy.adding(bytes, bytes))
            self.remaining = max(0, remaining - min(remaining, max(0, cost)))
        }
    }
}
