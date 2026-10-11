import Foundation

struct RestoreDownloadPolicy: Sendable {
    var workerCount: Int
    var bufferedByteLimit: Int64
    var freeSpaceReserve: Int64
    var bufferedItemLimit: Int?
    private let usesAvailableSpace: Bool
    private let bufferBudget = RestorePrefetchBudget()

    static var serial: Self { Self(workerCount: 1, bufferedItemLimit: 1) }

    init(workerCount: Int = 2, bufferedByteLimit: Int64? = nil,
         freeSpaceReserve: Int64 = 64 * 1024 * 1024, bufferedItemLimit: Int? = nil) {
        self.workerCount = workerCount
        self.bufferedByteLimit = max(0, bufferedByteLimit ?? RestorePrefetchBudget.fallbackBytes)
        self.freeSpaceReserve = freeSpaceReserve
        self.bufferedItemLimit = bufferedItemLimit
        usesAvailableSpace = bufferedByteLimit == nil
    }

    func resolvingBufferLimit(availableCapacity: () -> Int64?) -> Self {
        var policy = self
        if usesAvailableSpace { policy.bufferedByteLimit = bufferBudget.resolve(availableCapacity: availableCapacity) }
        return policy
    }

    func isOversized(_ bytes: Int64) -> Bool { bytes > bufferedByteLimit }

    func hasItemRoom(estimatedBytes: Int64, pendingCount: Int) -> Bool {
        guard let bufferedItemLimit, !isOversized(estimatedBytes) else { return true }
        return pendingCount < max(1, bufferedItemLimit)
    }

    static func estimatedBytes(for instances: [RemoteAssetResourceInstance]) -> Int64 {
        var hashes = Set<Data>()
        var bytes: Int64 = 0
        for instance in instances {
            if !instance.resourceHash.isEmpty, !hashes.insert(instance.resourceHash).inserted { continue }
            bytes = adding(bytes, max(0, instance.fileSize))
        }
        return bytes
    }

    static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    func admits(bytes: Int64, reserved: RestoreReservations.Snapshot, available: Int64?) -> Bool {
        let total = Self.adding(reserved.totalBytes, bytes)
        if !reserved.isEmpty {
            guard bytes > 0, reserved.unknownCount == 0 else { return false }
        }
        if !isOversized(bytes) {
            guard Self.adding(reserved.bufferedBytes, bytes) <= bufferedByteLimit else { return false }
        }
        guard let available else { return true }
        let largest = max(bytes, reserved.largestBytes)
        let required = Self.adding(Self.adding(total, Self.adding(largest, largest)), freeSpaceReserve)
        return required <= available
    }

    func hasImportCapacity(bytes: Int64, available: Int64?) -> Bool {
        guard let available else { return true }
        return Self.adding(Self.adding(bytes, bytes), freeSpaceReserve) <= available
    }
}

final class OrderedRestorePipeline<Value: Sendable>: Sendable {
    private final class Tasks: @unchecked Sendable {
        struct Snapshot {
            let revision: Int
            let reserved: RestoreReservations.Snapshot
            let worker: Int?
            let exclusive: Bool
            let canSchedule: Bool
        }

        enum Assignment {
            case task(Task<Value, Error>)
            case finishRequired
            case stopped
            case wait(Int)
        }

        private let lock = NSLock()
        private var tasks: [Int: Task<Value, Error>] = [:]
        private var reservations = RestoreReservations()
        private var workers: [Int: Int] = [:]
        private var idleWorkers: [Int]
        private var exclusiveIndex: Int?
        private var currentIndex = 0
        private var draining = false
        private var cancelled = false
        private var failed = false
        private var schedulingFinished = false
        private var needsFinalization = false
        private var revision = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(workerCount: Int) { idleWorkers = Array(0..<workerCount) }

        private func change<T>(_ body: () throws -> T) rethrows -> T {
            var pending: [CheckedContinuation<Void, Never>] = []
            let result = try lock.withLock {
                let result = try body()
                revision += 1
                pending = waiters
                waiters.removeAll()
                return result
            }
            pending.forEach { $0.resume() }
            return result
        }

        func wait(after observed: Int) async {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock {
                    guard revision == observed else { return true }
                    waiters.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        func begin(_ index: Int, shouldDrain: () -> Bool) throws {
            try change {
                guard !cancelled, !draining, !shouldDrain(), !Task.isCancelled else { throw CancellationError() }
                currentIndex = index
            }
        }

        func snapshot() -> Snapshot {
            lock.withLock {
                Snapshot(revision: revision, reserved: reservations.snapshot, worker: idleWorkers.first,
                    exclusive: exclusiveIndex != nil,
                    canSchedule: !cancelled && !draining && !failed)
            }
        }

        func reserve(_ index: Int, worker: Int, estimatedBytes: Int64, available: Int64?,
                     exclusive: Bool, policy: RestoreDownloadPolicy) -> Bool {
            change {
                let reserved = reservations.snapshot
                guard !cancelled, !draining, !failed, exclusiveIndex == nil,
                      idleWorkers.first == worker,
                      policy.hasItemRoom(estimatedBytes: estimatedBytes,
                          pendingCount: reserved.bufferedPendingCount)
                else { return false }
                if exclusive {
                    guard reserved.isEmpty else { return false }
                } else {
                    guard policy.admits(bytes: estimatedBytes, reserved: reserved, available: available) else { return false }
                }
                reservations.insert(index, bytes: estimatedBytes, oversized: policy.isOversized(estimatedBytes))
                idleWorkers.removeFirst()
                workers[index] = worker
                if exclusive { exclusiveIndex = index }
                needsFinalization = false
                return true
            }
        }

        func insert(_ task: Task<Value, Error>, at index: Int) {
            let cancel = change {
                tasks[index] = task
                return cancelled || (draining && index != currentIndex)
            }
            if cancel { task.cancel() }
        }

        func prepared(_ index: Int, actualBytes: Int64?, isOversized: Bool) {
            change {
                if let actualBytes {
                    reservations.update(index, bytes: actualBytes, oversized: isOversized)
                } else {
                    failed = true
                }
                // An exempt asset keeps its worker until import removes its temporary files.
                if !reservations.isOversized(index) { releaseWorker(index) }
            }
        }

        private func releaseWorker(_ index: Int) {
            if let worker = workers.removeValue(forKey: index) { idleWorkers.append(worker) }
        }

        func markCommitted(_ index: Int) {
            change {
                reservations.markCommitted(index)
                releaseWorker(index)
            }
        }

        func requireFinalization(after observed: Int) -> Int {
            change {
                guard revision == observed else { return observed }
                needsFinalization = true
                return revision + 1
            }
        }

        func stopScheduling() { change { schedulingFinished = true } }

        func assignment(_ index: Int) async -> Assignment {
            while true {
                let next: Assignment = lock.withLock {
                    if let task = tasks[index] { return .task(task) }
                    if cancelled || draining || schedulingFinished { return .stopped }
                    if needsFinalization { return .finishRequired }
                    return .wait(revision)
                }
                if case .wait(let observed) = next { await wait(after: observed) } else { return next }
            }
        }

        func finish(_ index: Int) {
            change {
                tasks[index] = nil
                reservations.remove(index)
                if exclusiveIndex == index { exclusiveIndex = nil }
                needsFinalization = false
            }
        }

        func cancel(prefetchOnly: Bool = false) -> [Task<Value, Error>] {
            let selected = change {
                if prefetchOnly { draining = true } else { cancelled = true }
                return tasks.filter { !prefetchOnly || $0.key != currentIndex }.map(\.value)
            }
            selected.forEach { $0.cancel() }
            return selected
        }
    }

    let policy: RestoreDownloadPolicy

    func run(
        estimatedBytes: [Int64],
        shouldDrain: @escaping @Sendable () -> Bool,
        availableCapacity: @escaping @Sendable () -> Int64?,
        byteCount: @escaping @Sendable (Value) -> Int64,
        resolveSize: (@Sendable (_ index: Int) async throws -> Int64?)? = nil,
        prepare: @escaping @Sendable (_ index: Int, _ workerID: Int) async throws -> Value,
        commit: (_ index: Int, _ result: Result<Value, Error>) async throws -> Void,
        finish: ((_ index: Int) async throws -> Void)? = nil
    ) async throws {
        let capacity = RestoreCapacityBudget(query: availableCapacity)
        let policy = policy.resolvingBufferLimit { capacity.available() }
        let tasks = Tasks(workerCount: min(max(1, policy.workerCount), 4))
        func finishItem(_ index: Int) async throws {
            defer { tasks.finish(index) }
            try await finish?(index)
        }
        let monitor = Task.detached {
            while !Task.isCancelled {
                if shouldDrain() {
                    _ = tasks.cancel(prefetchOnly: true)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        let producer = Task.detached(priority: .userInitiated) { [policy] in
            defer { tasks.stopScheduling() }
            var nextIndex = 0
            while nextIndex < estimatedBytes.count {
                let state = tasks.snapshot()
                guard state.canSchedule, !shouldDrain() else { return }
                let index = nextIndex
                let estimate = max(0, estimatedBytes[index])
                var available: Int64?
                let hasItemRoom = policy.hasItemRoom(estimatedBytes: estimate, pendingCount: state.reserved.bufferedPendingCount)
                var fits = !state.exclusive && policy.admits(bytes: estimate, reserved: state.reserved,
                    available: nil)
                if fits, state.worker != nil, hasItemRoom {
                    available = capacity.available()
                    fits = policy.admits(bytes: estimate, reserved: state.reserved, available: available)
                    if !fits {
                        available = capacity.available(force: true)
                        fits = policy.admits(bytes: estimate, reserved: state.reserved, available: available)
                    }
                }
                let needsResolution = !fits && state.reserved.isEmpty
                let exclusive = needsResolution || estimate == 0
                guard let worker = state.worker, hasItemRoom,
                      !state.exclusive, fits || needsResolution else {
                    let observed = state.reserved.pendingCount == 0 && !state.reserved.isEmpty
                        ? tasks.requireFinalization(after: state.revision) : state.revision
                    await tasks.wait(after: observed)
                    continue
                }
                guard tasks.reserve(index, worker: worker, estimatedBytes: estimate, available: available,
                                    exclusive: exclusive, policy: policy) else {
                    continue
                }
                capacity.consume(estimate)
                let task = Task.detached(priority: .userInitiated) {
                    do {
                        try Task.checkCancellation()
                        if needsResolution {
                            guard let resolveSize else { throw CocoaError(.fileWriteOutOfSpace) }
                            if let size = try await resolveSize(index),
                               !policy.admits(bytes: size, reserved: .init(), available: capacity.available(force: true)) {
                                throw CocoaError(.fileWriteOutOfSpace)
                            }
                        }
                        try Task.checkCancellation()
                        if needsResolution, shouldDrain() { throw CancellationError() }
                        let value = try await prepare(index, worker)
                        let actual = max(0, byteCount(value))
                        if exclusive, !policy.hasImportCapacity(bytes: actual, available: capacity.available(force: true)) {
                            throw CocoaError(.fileWriteOutOfSpace)
                        }
                        capacity.consume(max(0, actual - estimate))
                        let oversized = policy.isOversized(estimate) || policy.isOversized(actual)
                        tasks.prepared(index, actualBytes: actual, isOversized: oversized)
                        return value
                    } catch {
                        tasks.prepared(index, actualBytes: nil, isOversized: false)
                        throw error
                    }
                }
                tasks.insert(task, at: index)
                nextIndex += 1
            }
        }
        var finalizing: [Int] = []
        var outcome: Result<Void, Error> = await withTaskCancellationHandler {
            do {
                for index in estimatedBytes.indices {
                    try tasks.begin(index, shouldDrain: shouldDrain)
                    var current: Task<Value, Error>?
                    while current == nil {
                        let assignment = await tasks.assignment(index)
                        switch assignment {
                        case .task(let task): current = task
                        case .finishRequired:
                            guard !finalizing.isEmpty else { throw CancellationError() }
                            try await finishItem(finalizing.removeFirst())
                        case .stopped, .wait: throw CancellationError()
                        }
                    }
                    let result = await current!.result
                    try Task.checkCancellation()
                    try await commit(index, result)
                    tasks.markCommitted(index)
                    if finish != nil {
                        finalizing.append(index)
                        if finalizing.count > 1 { try await finishItem(finalizing.removeFirst()) }
                    } else {
                        tasks.finish(index)
                    }
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        } onCancel: {
            _ = tasks.cancel()
        }
        monitor.cancel()
        _ = tasks.cancel()
        await monitor.value
        await producer.value
        for task in tasks.cancel() { _ = await task.result }
        for index in finalizing {
            do { try await finishItem(index) }
            catch { if case .success = outcome { outcome = .failure(error) } }
        }
        try outcome.get()
    }

    init(policy: RestoreDownloadPolicy) { self.policy = policy }
}
