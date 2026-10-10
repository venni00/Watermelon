import XCTest
@testable import Watermelon

@MainActor
final class HomeLocalIndexRefreshBatcherTests: XCTestCase {
    func testFlushCoalescesDeduplicatesAndDoesNotWaitForTimer() async {
        var batches: [Set<String>] = []
        let batcher = HomeLocalIndexRefreshBatcher(interval: .seconds(60)) { batches.append($0) }
        batcher.enqueue("a")
        batcher.enqueue("b")
        batcher.enqueue("a")
        XCTAssertTrue(batches.isEmpty)
        await batcher.flush()
        await batcher.flush()
        XCTAssertEqual(batches, [["a", "b"]])
    }

    func testTimerRefreshAndFinalFlushSerializeArrivalsDuringRefresh() async {
        let started = expectation(description: "timer starts refresh")
        let gate = RestoreTestLatch()
        var batches: [Set<String>] = []
        var active = false
        let batcher = HomeLocalIndexRefreshBatcher(interval: .milliseconds(10)) { ids in
            XCTAssertFalse(active)
            active = true
            batches.append(ids)
            if batches.count == 1 {
                started.fulfill()
                await gate.wait()
            }
            active = false
        }
        batcher.enqueue("a")
        await fulfillment(of: [started], timeout: 3)
        batcher.enqueue("b")
        let firstFlush = Task { await batcher.flush() }
        let secondFlush = Task { await batcher.flush() }
        await gate.open()
        await firstFlush.value
        await secondFlush.value
        XCTAssertEqual(batches, [["a"], ["b"]])
        XCTAssertFalse(active)
    }

    func testCancelledCallerStillFlushesDurableRestores() async {
        var batches: [Set<String>] = []
        let batcher = HomeLocalIndexRefreshBatcher(interval: .seconds(60)) {
            XCTAssertFalse(Task.isCancelled)
            batches.append($0)
        }
        batcher.enqueue("restored")
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await batcher.flush()
        }.value
        XCTAssertEqual(batches, [["restored"]])
    }
}
