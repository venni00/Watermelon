import XCTest
@testable import Watermelon

final class RestoreCapacityBudgetTests: XCTestCase {
    func testReservationSizesAndOversizedPromotionRemainReservedUntilFinalization() {
        var reservations = RestoreReservations()
        reservations.insert(0, bytes: 0, oversized: false)
        reservations.insert(1, bytes: 50, oversized: false)
        reservations.insert(2, bytes: 500, oversized: true)
        XCTAssertEqual(reservations.snapshot, .init(count: 3, pendingCount: 3, bufferedPendingCount: 2,
            unknownCount: 1, totalBytes: 550, bufferedBytes: 50, largestBytes: 500))
        reservations.update(0, bytes: 25, oversized: false)
        reservations.update(1, bytes: 750, oversized: true)
        reservations.markCommitted(1)
        XCTAssertEqual(reservations.snapshot, .init(count: 3, pendingCount: 2, bufferedPendingCount: 1,
            totalBytes: 1_275, bufferedBytes: 25, largestBytes: 750))
        reservations.remove(1)
        XCTAssertEqual(reservations.snapshot.largestBytes, 500)
        reservations.markCommitted(0)
        reservations.markCommitted(0)
        XCTAssertEqual(reservations.snapshot, .init(count: 2, pendingCount: 1, bufferedPendingCount: 0,
            totalBytes: 525, bufferedBytes: 25, largestBytes: 500))
        reservations.remove(0)
        reservations.remove(2)
        XCTAssertEqual(reservations.snapshot, .init())
    }

    func testLargestReservationTracksDuplicateSizesAndResizing() {
        var reservations = RestoreReservations()
        for (index, bytes) in [30, 100, 100, 40, 10].enumerated() {
            reservations.insert(index, bytes: Int64(bytes), oversized: bytes > 50)
        }
        reservations.remove(1)
        XCTAssertEqual(reservations.snapshot.largestBytes, 100)
        reservations.update(2, bytes: 20, oversized: false)
        XCTAssertTrue(reservations.isOversized(2))
        XCTAssertEqual(reservations.snapshot.largestBytes, 40)
        reservations.update(4, bytes: 90, oversized: true)
        XCTAssertEqual(reservations.snapshot.largestBytes, 90)
        reservations.remove(4)
        XCTAssertEqual(reservations.snapshot.largestBytes, 40)
        reservations.remove(0)
        reservations.remove(2)
        XCTAssertEqual(reservations.snapshot, .init(count: 1, pendingCount: 1, bufferedPendingCount: 1,
            totalBytes: 40, bufferedBytes: 40, largestBytes: 40))
    }

    func testReservationTotalsRecoverAfterOverflowAndRemoval() {
        var reservations = RestoreReservations()
        for index in 0..<3 { reservations.insert(index, bytes: .max, oversized: false) }
        XCTAssertEqual(reservations.snapshot.totalBytes, .max)
        XCTAssertEqual(reservations.snapshot.bufferedBytes, .max)
        reservations.update(0, bytes: 1, oversized: false)
        reservations.remove(1)
        XCTAssertEqual(reservations.snapshot.totalBytes, .max)
        reservations.markCommitted(2)
        reservations.remove(2)
        XCTAssertEqual(reservations.snapshot, .init(count: 1, pendingCount: 1, bufferedPendingCount: 1,
            totalBytes: 1, bufferedBytes: 1, largestBytes: 1))
        reservations.remove(0)
        XCTAssertEqual(reservations.snapshot, .init())
    }

    func testIncrementalReservationsMatchReferenceAcrossMixedLifecycleChanges() {
        struct Entry {
            var bytes: Int64
            var oversized: Bool
            var committed = false
        }
        var reservations = RestoreReservations()
        var reference: [Int: Entry] = [:]
        var random: UInt64 = 0x5EED
        func next(_ limit: Int) -> Int {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((random >> 32) % UInt64(limit))
        }
        let policy = RestoreDownloadPolicy(bufferedByteLimit: 1_000, freeSpaceReserve: 10)
        for _ in 0..<10_000 {
            let index = next(512)
            let size = Int64(next(2_001))
            if var entry = reference[index] {
                switch next(3) {
                case 0 where !entry.committed:
                    reservations.update(index, bytes: size, oversized: policy.isOversized(size))
                    entry.bytes = size
                    entry.oversized = entry.oversized || policy.isOversized(size)
                    reference[index] = entry
                case 1:
                    reservations.markCommitted(index)
                    entry.committed = true
                    reference[index] = entry
                default:
                    reservations.remove(index)
                    reference[index] = nil
                }
            } else {
                reservations.insert(index, bytes: size, oversized: policy.isOversized(size))
                reference[index] = Entry(bytes: size, oversized: policy.isOversized(size))
            }
            let all = Array(reference.values)
            let total = all.reduce(Int64(0)) { $0 + $1.bytes }
            let buffered = all.filter { !$0.oversized }.reduce(Int64(0)) { $0 + $1.bytes }
            let largest = all.map(\.bytes).max() ?? 0
            let expected = RestoreReservations.Snapshot(count: all.count,
                pendingCount: all.filter { !$0.committed }.count,
                bufferedPendingCount: all.filter { !$0.committed && !$0.oversized }.count,
                unknownCount: all.filter { $0.bytes == 0 }.count,
                totalBytes: total, bufferedBytes: buffered, largestBytes: largest)
            XCTAssertEqual(reservations.snapshot, expected)
            let available: Int64? = next(3) == 0 ? nil : total + size + 2 * max(size, largest) + Int64(next(21))
            let expectedAdmission = (all.isEmpty || (size > 0 && all.allSatisfy { $0.bytes > 0 }))
                && (policy.isOversized(size) || buffered + size <= policy.bufferedByteLimit)
                && (available == nil || total + size + 2 * max(size, largest) + 10 <= available!)
            XCTAssertEqual(policy.admits(bytes: size, reserved: reservations.snapshot, available: available), expectedAdmission)
        }
        for index in reference.keys { reservations.remove(index) }
        XCTAssertEqual(reservations.snapshot, .init())
    }

    func testPrefetchThresholdUsesTenPercentAndRemainsStableAcrossPolicyCopies() {
        let source = CapacitySource()
        let policy = RestoreDownloadPolicy()
        let copy = policy
        let first = policy.resolvingBufferLimit(availableCapacity: { source.read() })
        XCTAssertEqual(first.bufferedByteLimit, 100)
        XCTAssertFalse(first.isOversized(100))
        XCTAssertTrue(first.isOversized(101))
        source.space = 500
        let nextMonth = copy.resolvingBufferLimit(availableCapacity: { source.read() })
        XCTAssertEqual(nextMonth.bufferedByteLimit, 100)
        XCTAssertEqual(source.calls, 1)
        let nextRun = RestoreDownloadPolicy().resolvingBufferLimit(availableCapacity: { source.read() })
        XCTAssertEqual(nextRun.bufferedByteLimit, 50)
        XCTAssertEqual(source.calls, 2)
    }

    func testSerialPoliciesDoNotSharePrefetchThresholdBetweenRuns() {
        XCTAssertEqual(RestoreDownloadPolicy.serial.resolvingBufferLimit(availableCapacity: { 1_000 }).bufferedByteLimit, 100)
        XCTAssertEqual(RestoreDownloadPolicy.serial.resolvingBufferLimit(availableCapacity: { 500 }).bufferedByteLimit, 50)
    }

    func testPrefetchThresholdHandlesUnavailableAndNegativeCapacity() {
        XCTAssertEqual(RestoreDownloadPolicy().resolvingBufferLimit(availableCapacity: { nil }).bufferedByteLimit,
                       RestorePrefetchBudget.fallbackBytes)
        XCTAssertEqual(RestoreDownloadPolicy().resolvingBufferLimit(availableCapacity: { -1 }).bufferedByteLimit, 0)
    }

    func testCachedSpaceDeductsAllThreeCopiesUntilNextSample() {
        let source = CapacitySource()
        let budget = RestoreCapacityBudget(query: { source.read() }, clock: { source.now })
        XCTAssertEqual(budget.available(), 1_000)
        budget.consume(100)
        XCTAssertEqual(budget.available(), 700)
        budget.consume(50)
        source.now = 1.999
        XCTAssertEqual(budget.available(), 550)
        XCTAssertEqual(source.calls, 1)
        source.space = 800
        source.now = 2
        XCTAssertEqual(budget.available(), 800)
        XCTAssertEqual(source.calls, 2)
    }

    func testForcedRecheckDetectsExternalSpaceLoss() {
        let source = CapacitySource()
        let budget = RestoreCapacityBudget(query: { source.read() }, clock: { source.now })
        XCTAssertEqual(budget.available(), 1_000)
        source.space = 100
        XCTAssertEqual(budget.available(force: true), 100)
        XCTAssertEqual(source.calls, 2)
        budget.consume(.max)
        XCTAssertEqual(budget.available(), 0)
    }

    func testUnknownSpaceIsRetriedAfterCacheExpires() {
        let source = CapacitySource()
        source.space = nil
        let budget = RestoreCapacityBudget(query: { source.read() }, clock: { source.now })
        XCTAssertNil(budget.available())
        budget.consume(100)
        XCTAssertNil(budget.available())
        source.now = 2
        source.space = 500
        XCTAssertEqual(budget.available(), 500)
        XCTAssertEqual(source.calls, 2)
    }

    func testOversizedReservationDebitsCapacityBeforeNextWorkerStarts() async throws {
        let source = CapacitySource()
        let release = RestoreTestLatch()
        let secondStarted = expectation(description: "second oversized asset checks debited capacity")
        let task = Task {
            try await OrderedRestorePipeline<Int>(policy: .init(bufferedByteLimit: 100, freeSpaceReserve: 0)).run(
                estimatedBytes: [200, 200], shouldDrain: { false }, availableCapacity: { source.read() },
                byteCount: { _ in 200 },
                prepare: { index, _ in
                    if index == 1 {
                        XCTAssertEqual(source.calls, 2)
                        secondStarted.fulfill()
                    }
                    await release.wait()
                    return index
                },
                commit: { _, result in _ = try result.get() }
            )
        }
        await fulfillment(of: [secondStarted], timeout: 3)
        await release.open()
        try await task.value
    }
}

private final class CapacitySource: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 0
    private var capacity: Int64? = 1_000
    private var count = 0
    var now: Double {
        get { lock.withLock { time } }
        set { lock.withLock { time = newValue } }
    }
    var space: Int64? {
        get { lock.withLock { capacity } }
        set { lock.withLock { capacity = newValue } }
    }
    var calls: Int { lock.withLock { count } }
    func read() -> Int64? { lock.withLock { count += 1; return capacity } }
}
