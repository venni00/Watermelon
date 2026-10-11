import XCTest
@testable import Watermelon

final class OrderedRestorePipelineTests: XCTestCase {
    func testDefaultPolicyPrefetchesPastEightItemsWhileHeadDownloadIsBlocked() async throws {
        let head = RestoreTestLatch()
        let prefetched = expectation(description: "all later downloads prepared behind blocked head")
        let probe = RestorePipelineProbe()
        let count = 128
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: .init()).run(
                estimatedBytes: Array(repeating: 1, count: count), shouldDrain: { false },
                availableCapacity: { nil }, byteCount: { _ in 1 },
                prepare: { index, worker in
                    await probe.start(index, worker: worker)
                    if index == 0 { await head.wait() }
                    if index == count - 1 { prefetched.fulfill() }
                    return index
                },
                commit: { _, result in await probe.commit(try result.get()) }
            )
        }
        await fulfillment(of: [prefetched], timeout: 3)
        let before = await probe.snapshot()
        XCTAssertEqual(before.started, Set(0..<count))
        XCTAssertTrue(before.committed.isEmpty)
        XCTAssertEqual(Set(before.workerByItem.filter { $0.key != 0 }.values).count, 1)
        await head.open()
        try await task.value
        let after = await probe.snapshot()
        XCTAssertEqual(after.committed, Array(0..<count))
        XCTAssertEqual(Set(after.workers), [0, 1])
    }

    func testByteBudgetBoundsLargePrefetchQueueUntilHeadFinalizes() async throws {
        let head = RestoreTestLatch()
        let full = expectation(description: "32 pending items fill the byte budget")
        let probe = RestorePipelineProbe()
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: .init(bufferedByteLimit: 320)).run(
                estimatedBytes: Array(repeating: 10, count: 64), shouldDrain: { false },
                availableCapacity: { nil }, byteCount: { _ in 10 },
                prepare: { index, worker in
                    if index >= 32 {
                        let state = await probe.snapshot()
                        XCTAssertGreaterThanOrEqual(state.committed.count, index - 31)
                    }
                    await probe.start(index, worker: worker)
                    if index == 0 { await head.wait() }
                    if index == 31 { full.fulfill() }
                    return index
                },
                commit: { _, result in _ = try result.get() },
                finish: { index in await probe.commit(index) }
            )
        }
        await fulfillment(of: [full], timeout: 3)
        let before = await probe.snapshot()
        XCTAssertEqual(before.started, Set(0..<32))
        XCTAssertTrue(before.committed.isEmpty)
        await head.open()
        try await task.value
        let after = await probe.snapshot()
        XCTAssertEqual(after.committed, Array(0..<64))
    }

    func testOutOfOrderDownloadsCommitInOrderAndBoundLookahead() async throws {
        let head = RestoreTestLatch()
        let laterReady = expectation(description: "third download prefetched behind blocked head")
        let probe = RestorePipelineProbe()
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: .init(bufferedItemLimit: 3)).run(
                estimatedBytes: [1, 1, 1, 1], shouldDrain: { false }, availableCapacity: { nil }, byteCount: { _ in 1 },
                prepare: { index, worker in
                    await probe.start(index, worker: worker)
                    if index == 0 { await head.wait() }
                    if index == 2 { laterReady.fulfill() }
                    return index
                },
                commit: { _, result in await probe.commit(try result.get()) }
            )
        }
        await fulfillment(of: [laterReady], timeout: 3)
        let before = await probe.snapshot()
        XCTAssertEqual(before.started, [0, 1, 2])
        XCTAssertEqual(before.committed, [])
        await head.open()
        try await task.value
        let after = await probe.snapshot()
        XCTAssertEqual(after.committed, [0, 1, 2, 3])
        XCTAssertEqual(Set(after.workers), [0, 1])
    }

    func testLaterFailureIsDeliveredAfterEarlierCommit() async throws {
        let head = RestoreTestLatch()
        let laterFailed = expectation(description: "second download failed")
        let probe = RestorePipelineProbe()
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: .init()).run(
                estimatedBytes: [1, 1, 1], shouldDrain: { false }, availableCapacity: { nil }, byteCount: { _ in 1 },
                prepare: { index, _ in
                    if index == 0 { await head.wait() }
                    if index == 1 {
                        laterFailed.fulfill()
                        throw RestorePipelineTestError.failed
                    }
                    return index
                },
                commit: { _, result in await probe.commit(try result.get()) }
            )
        }
        await fulfillment(of: [laterFailed], timeout: 3)
        let before = await probe.snapshot()
        XCTAssertEqual(before.committed, [])
        await head.open()
        do { try await task.value; XCTFail("expected download failure") } catch RestorePipelineTestError.failed {}
        let after = await probe.snapshot()
        XCTAssertEqual(after.committed, [0])
    }

    func testWorkerContinuesPreparingWhilePhotosCommitIsBlocked() async throws {
        let importing = RestoreTestLatch()
        let releaseImport = RestoreTestLatch()
        let prefetched = expectation(description: "worker reused during import")
        let probe = RestorePipelineProbe()
        let policy = RestoreDownloadPolicy(workerCount: 1, bufferedItemLimit: 3)
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: policy).run(
                estimatedBytes: [1, 1, 1, 1], shouldDrain: { false }, availableCapacity: { nil }, byteCount: { _ in 1 },
                prepare: { index, worker in
                    await probe.start(index, worker: worker)
                    if index == 1 { await importing.wait() }
                    if index == 2 { prefetched.fulfill() }
                    return index
                },
                commit: { index, result in
                    if index == 0 {
                        await importing.open()
                        await releaseImport.wait()
                    }
                    await probe.commit(try result.get())
                }
            )
        }
        await fulfillment(of: [prefetched], timeout: 3)
        let before = await probe.snapshot()
        XCTAssertEqual(before.started, [0, 1, 2])
        XCTAssertTrue(before.committed.isEmpty)
        await releaseImport.open()
        try await task.value
        let after = await probe.snapshot()
        XCTAssertEqual(after.committed, [0, 1, 2, 3])
        XCTAssertEqual(Set(after.workers), [0])
    }

    func testQueuedReadyAssetsStillHoldByteBudgetDuringImport() async throws {
        let releaseImport = RestoreTestLatch()
        let bothPrepared = expectation(description: "byte budget filled")
        let probe = RestorePipelineProbe()
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: .init(bufferedByteLimit: 10, bufferedItemLimit: 8)).run(
                estimatedBytes: [5, 5, 5], shouldDrain: { false }, availableCapacity: { nil }, byteCount: { _ in 5 },
                prepare: { index, worker in
                    await probe.start(index, worker: worker)
                    if index == 1 { bothPrepared.fulfill() }
                    if index == 2 {
                        let state = await probe.snapshot()
                        XCTAssertFalse(state.committed.isEmpty)
                    }
                    return index
                },
                commit: { index, result in
                    if index == 0 { await releaseImport.wait() }
                    await probe.commit(try result.get())
                }
            )
        }
        await fulfillment(of: [bothPrepared], timeout: 3)
        let before = await probe.snapshot()
        XCTAssertEqual(before.started, [0, 1])
        await releaseImport.open()
        try await task.value
    }

    func testUnknownSizeDoesNotPrefetchUntilItsFinalizationCompletes() async throws {
        let finalized = ExecutionTerminationControl()
        try await OrderedRestorePipeline<Int>(policy: .init()).run(
            estimatedBytes: [0, 1], shouldDrain: { false }, availableCapacity: { nil }, byteCount: { _ in 1 },
            prepare: { index, _ in
                if index == 1 { XCTAssertTrue(finalized.shouldDrain) }
                return index
            },
            commit: { _, result in _ = try result.get() },
            finish: { index in if index == 0 { finalized.request(.stop) } }
        )
    }

    func testDrainCancelsPrefetchWhileFinishingHead() async throws {
        let head = RestoreTestLatch()
        let started = expectation(description: "both downloads started")
        started.expectedFulfillmentCount = 2
        let prefetchCancelled = expectation(description: "prefetch cancelled")
        let drain = ExecutionTerminationControl()
        let probe = RestorePipelineProbe()
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: .init()).run(
                estimatedBytes: [1, 1, 1], shouldDrain: { drain.shouldDrain }, availableCapacity: { nil }, byteCount: { _ in 1 },
                prepare: { index, _ in
                    started.fulfill()
                    if index == 0 {
                        await head.wait()
                        XCTAssertFalse(Task.isCancelled)
                    } else {
                        do { try await Task.sleep(for: .seconds(30)) }
                        catch { prefetchCancelled.fulfill(); throw error }
                    }
                    return index
                },
                commit: { _, result in await probe.commit(try result.get()) }
            )
        }
        await fulfillment(of: [started], timeout: 3)
        drain.request(.pause)
        await fulfillment(of: [prefetchCancelled], timeout: 3)
        await head.open()
        do { try await task.value; XCTFail("expected drain") } catch is CancellationError {}
        let state = await probe.snapshot()
        XCTAssertEqual(state.committed, [0])
    }

    func testHardCancellationCancelsEveryDownload() async throws {
        let started = expectation(description: "both downloads started")
        started.expectedFulfillmentCount = 2
        let cancelled = expectation(description: "both downloads cancelled")
        cancelled.expectedFulfillmentCount = 2
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: .init()).run(
                estimatedBytes: [1, 1], shouldDrain: { false }, availableCapacity: { nil }, byteCount: { _ in 1 },
                prepare: { index, _ in
                    started.fulfill()
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { cancelled.fulfill(); throw error }
                    return index
                },
                commit: { _, result in _ = try result.get(); XCTFail("must not commit") }
            )
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do { try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        await fulfillment(of: [cancelled], timeout: 3)
    }

    func testDrainDiscardsLargeReadyQueueAndFinalizesImportedHead() async throws {
        let importing = RestoreTestLatch()
        let releaseImport = RestoreTestLatch()
        let full = expectation(description: "64 assets prepared while head import is blocked")
        let drain = ExecutionTerminationControl()
        let probe = RestorePipelineProbe()
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: .init()).run(
                estimatedBytes: Array(repeating: 1, count: 64), shouldDrain: { drain.shouldDrain },
                availableCapacity: { nil }, byteCount: { _ in 1 },
                prepare: { index, worker in
                    await probe.start(index, worker: worker)
                    if index == 63 { full.fulfill() }
                    return index
                },
                commit: { _, result in
                    await importing.open()
                    await releaseImport.wait()
                    await probe.commit(try result.get())
                },
                finish: { index in XCTAssertEqual(index, 0) }
            )
        }
        await fulfillment(of: [full], timeout: 3)
        await importing.wait()
        drain.request(.pause)
        await releaseImport.open()
        do { try await task.value; XCTFail("expected pause") } catch is CancellationError {}
        let state = await probe.snapshot()
        XCTAssertEqual(state.committed, [0])
        XCTAssertEqual(state.started, Set(0..<64))
    }

    func testFailureWaitsForCancelledPrefetchToSettle() async throws {
        let failHead = RestoreTestLatch()
        let releasePrefetch = RestoreTestLatch()
        let started = expectation(description: "prefetch started")
        let cancelled = expectation(description: "prefetch cancellation requested")
        let returned = ExecutionTerminationControl()
        let task = Task {
            defer { returned.request(.stop) }
            try await OrderedRestorePipeline<Int>(policy: .init()).run(
                estimatedBytes: [1, 1], shouldDrain: { false }, availableCapacity: { nil }, byteCount: { _ in 1 },
                prepare: { index, _ in
                    if index == 0 { await failHead.wait(); throw RestorePipelineTestError.failed }
                    started.fulfill()
                    await withTaskCancellationHandler { await releasePrefetch.wait() } onCancel: { cancelled.fulfill() }
                    return index
                },
                commit: { _, result in _ = try result.get() }
            )
        }
        await fulfillment(of: [started], timeout: 3)
        await failHead.open()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertFalse(returned.shouldDrain)
        await releasePrefetch.open()
        do { try await task.value; XCTFail("expected failure") } catch RestorePipelineTestError.failed {}
        XCTAssertTrue(returned.shouldDrain)
    }

    func testOversizedAssetAllowsNormalPrefetchWithinByteBudget() async throws {
        let head = RestoreTestLatch()
        let full = expectation(description: "ordinary byte budget filled beside oversized head")
        let probe = RestorePipelineProbe()
        let sizes: [Int64] = [100, 5, 5, 5]
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: .init(bufferedByteLimit: 10)).run(
                estimatedBytes: sizes, shouldDrain: { false }, availableCapacity: { nil }, byteCount: { sizes[$0] },
                prepare: { index, worker in
                    await probe.start(index, worker: worker)
                    if index == 0 { await head.wait() }
                    if index == 2 { full.fulfill() }
                    if index == 3 {
                        let state = await probe.snapshot()
                        XCTAssertTrue(state.committed.contains(1))
                    }
                    return index
                },
                commit: { _, result in await probe.commit(try result.get()) }
            )
        }
        await fulfillment(of: [full], timeout: 3)
        let before = await probe.snapshot()
        XCTAssertEqual(before.started, [0, 1, 2])
        XCTAssertTrue(before.committed.isEmpty)
        await head.open()
        try await task.value
        let after = await probe.snapshot()
        XCTAssertEqual(after.committed, [0, 1, 2, 3])
    }

    func testOversizedAssetsKeepWorkersUntilImportAndDoNotUseItemSlots() async throws {
        let releaseImport = RestoreTestLatch()
        let both = expectation(description: "two oversized assets prepared with only one ordinary item slot")
        both.expectedFulfillmentCount = 2
        let probe = RestorePipelineProbe()
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: .init(bufferedByteLimit: 10, bufferedItemLimit: 1)).run(
                estimatedBytes: [100, 100, 100], shouldDrain: { false }, availableCapacity: { nil },
                byteCount: { _ in 100 },
                prepare: { index, worker in
                    if index == 2 {
                        let state = await probe.snapshot()
                        XCTAssertTrue(state.committed.contains(0))
                    }
                    await probe.start(index, worker: worker)
                    if index < 2 { both.fulfill() }
                    return index
                },
                commit: { index, result in
                    if index == 0 { await releaseImport.wait() }
                    await probe.commit(try result.get())
                }
            )
        }
        await fulfillment(of: [both], timeout: 3)
        let before = await probe.snapshot()
        XCTAssertEqual(before.started, [0, 1])
        await releaseImport.open()
        try await task.value
        let after = await probe.snapshot()
        XCTAssertEqual(after.committed, [0, 1, 2])
    }

    func testOversizedAssetCanStartWhileOrdinaryItemSlotsAreFull() async throws {
        let head = RestoreTestLatch()
        let large = expectation(description: "large asset admitted beyond ordinary item slot")
        let sizes: [Int64] = [1, 100]
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: .init(bufferedByteLimit: 10, bufferedItemLimit: 1)).run(
                estimatedBytes: sizes, shouldDrain: { false }, availableCapacity: { nil }, byteCount: { sizes[$0] },
                prepare: { index, _ in
                    if index == 0 { await head.wait() } else { large.fulfill() }
                    return index
                },
                commit: { _, result in _ = try result.get() }
            )
        }
        await fulfillment(of: [large], timeout: 3)
        await head.open()
        try await task.value
    }

    func testUnderestimatedOversizedAssetKeepsItsWorkerUntilImport() async throws {
        let head = RestoreTestLatch()
        let prepared = expectation(description: "underestimated second item prepared")
        let probe = RestorePipelineProbe()
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: .init(workerCount: 2, bufferedByteLimit: 10)).run(
                estimatedBytes: [1, 1, 1], shouldDrain: { false }, availableCapacity: { nil },
                byteCount: { index in
                    if index == 1 { prepared.fulfill() }
                    return index == 1 ? 100 : 1
                },
                prepare: { index, worker in
                    if index == 2 {
                        let state = await probe.snapshot()
                        XCTAssertEqual(worker, state.workerByItem[0])
                    }
                    await probe.start(index, worker: worker)
                    if index == 0 { await head.wait() }
                    return index
                },
                commit: { _, result in await probe.commit(try result.get()) }
            )
        }
        await fulfillment(of: [prepared], timeout: 3)
        let before = await probe.snapshot()
        XCTAssertEqual(before.started, [0, 1])
        await head.open()
        try await task.value
        let after = await probe.snapshot()
        XCTAssertEqual(after.committed, [0, 1, 2])
    }

    func testDrainStopsOversizedPrefetchAfterCurrentImport() async throws {
        let releaseImport = RestoreTestLatch()
        let importing = RestoreTestLatch()
        let both = expectation(description: "both oversized downloads prepared")
        both.expectedFulfillmentCount = 2
        let drain = ExecutionTerminationControl()
        let probe = RestorePipelineProbe()
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: .init(bufferedByteLimit: 10)).run(
                estimatedBytes: [100, 100, 100], shouldDrain: { drain.shouldDrain }, availableCapacity: { nil },
                byteCount: { _ in 100 },
                prepare: { index, worker in
                    await probe.start(index, worker: worker)
                    both.fulfill()
                    return index
                },
                commit: { index, result in
                    await probe.commit(try result.get())
                    XCTAssertEqual(index, 0)
                    await importing.open()
                    await releaseImport.wait()
                }
            )
        }
        await fulfillment(of: [both], timeout: 3)
        await importing.wait()
        drain.request(.pause)
        await releaseImport.open()
        do { try await task.value; XCTFail("expected pause") } catch is CancellationError {}
        let state = await probe.snapshot()
        XCTAssertEqual(state.started, [0, 1])
        XCTAssertEqual(state.committed, [0])
    }

    func testSpaceAdmissionReservesImportRoomAndHandlesOverflow() {
        let policy = RestoreDownloadPolicy(workerCount: 2, bufferedByteLimit: 100, freeSpaceReserve: 10)
        func admits(bytes: Int64, reserved: [Int64], available: Int64?) -> Bool {
            var reservations = RestoreReservations()
            for (index, value) in reserved.enumerated() {
                reservations.insert(index, bytes: value, oversized: policy.isOversized(value))
            }
            return policy.admits(bytes: bytes, reserved: reservations.snapshot, available: available)
        }
        XCTAssertTrue(admits(bytes: 200, reserved: [], available: 610))
        XCTAssertFalse(admits(bytes: 200, reserved: [], available: 609))
        XCTAssertTrue(admits(bytes: 50, reserved: [200], available: 660))
        XCTAssertFalse(admits(bytes: 50, reserved: [200], available: 659))
        XCTAssertTrue(admits(bytes: 200, reserved: [50], available: 660))
        XCTAssertFalse(admits(bytes: 200, reserved: [50], available: 659))
        XCTAssertFalse(admits(bytes: 60, reserved: [60], available: nil))
        XCTAssertFalse(admits(bytes: 0, reserved: [1], available: nil))
        XCTAssertFalse(admits(bytes: 1, reserved: [0], available: nil))
        XCTAssertFalse(admits(bytes: .max, reserved: [], available: 1_000))
        XCTAssertEqual(RestoreDownloadPolicy.adding(.max, 1), .max)
    }

    func testFinalizingAssetKeepsItsBudgetUntilNextDownloadCanFit() async throws {
        let probe = RestorePipelineProbe()
        let policy = RestoreDownloadPolicy(workerCount: 2, bufferedByteLimit: 10, freeSpaceReserve: 0)
        try await OrderedRestorePipeline<Int>(policy: policy).run(
            estimatedBytes: [8, 8], shouldDrain: { false }, availableCapacity: { nil }, byteCount: { _ in 8 },
            prepare: { index, worker in
                if index == 1 {
                    let state = await probe.snapshot()
                    XCTAssertEqual(state.committed, [0])
                }
                await probe.start(index, worker: worker)
                return index
            },
            commit: { _, result in _ = try result.get() },
            finish: { index in await probe.commit(index) }
        )
        let state = await probe.snapshot()
        XCTAssertEqual(state.committed, [0, 1])
    }

    func testRepeatedCapacityBackpressureDoesNotLoseFinalizationWakeups() async throws {
        let probe = RestorePipelineProbe()
        let settled = expectation(description: "all tightly budgeted assets finalized")
        let task = Task {
            defer { settled.fulfill() }
            try await OrderedRestorePipeline<Int>(policy: .init(bufferedByteLimit: 1)).run(
                estimatedBytes: Array(repeating: 1, count: 300), shouldDrain: { false },
                availableCapacity: { nil }, byteCount: { _ in 1 },
                prepare: { index, _ in
                    let state = await probe.snapshot()
                    XCTAssertEqual(state.committed.count, index)
                    return index
                },
                commit: { _, result in _ = try result.get() },
                finish: { index in
                    await Task.yield()
                    await probe.commit(index)
                }
            )
        }
        await fulfillment(of: [settled], timeout: 5)
        task.cancel()
        try await task.value
        let state = await probe.snapshot()
        XCTAssertEqual(state.committed, Array(0..<300))
    }
}

private enum RestorePipelineTestError: Error { case failed }

actor RestoreTestLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor RestorePipelineProbe {
    private var started: Set<Int> = []
    private var workers: [Int] = []
    private var committed: [Int] = []
    private var workerByItem: [Int: Int] = [:]

    func start(_ index: Int, worker: Int) { started.insert(index); workers.append(worker); workerByItem[index] = worker }
    func commit(_ index: Int) { committed.append(index) }
    func snapshot() -> (started: Set<Int>, workers: [Int], committed: [Int], workerByItem: [Int: Int]) {
        (started, workers, committed, workerByItem)
    }
}
