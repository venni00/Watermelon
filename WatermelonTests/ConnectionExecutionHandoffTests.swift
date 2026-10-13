import XCTest
@testable import Watermelon

@MainActor
final class ConnectionExecutionHandoffTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppRuntimeFlags._testReset()
    }

    override func tearDown() {
        AppRuntimeFlags._testReset()
        super.tearDown()
    }

    func testConnectionHandsOffToWaitingShortcutBeforeAnotherConnectionCanStart() async throws {
        let home = AppRuntimeFlags()
        let shortcut = AppRuntimeFlags()
        XCTAssertTrue(home.tryBeginConnecting(profileID: 1))
        let task = await enqueue(shortcut)

        XCTAssertTrue(shortcut.isExecuting)
        XCTAssertFalse(home.tryBeginConnecting(profileID: 2))
        home.endConnecting(profileID: 1)
        XCTAssertFalse(home.tryBeginConnecting(profileID: 2))
        let result = try await task.value
        let claim = try XCTUnwrap(result)
        shortcut.exitExecution(claim)
        XCTAssertTrue(home.tryBeginConnecting(profileID: 2))
        home.endConnecting(profileID: 2)
    }

    func testCancellingWaitLeavesHomeConnectionRunning() async throws {
        let home = AppRuntimeFlags()
        let shortcut = AppRuntimeFlags()
        XCTAssertTrue(home.tryBeginConnecting(profileID: 1))
        let task = await enqueue(shortcut)
        task.cancel()
        await assertCancelled(task)

        XCTAssertTrue(home.isConnecting(profileID: 1))
        XCTAssertFalse(shortcut.isExecuting)
        home.endConnecting(profileID: 1)
        let claim = try XCTUnwrap(shortcut.tryEnterExecution())
        shortcut.exitExecution(claim)
    }

    func testAlreadyCancelledWaitDoesNotLeaveReservation() async {
        let home = AppRuntimeFlags()
        let shortcut = AppRuntimeFlags()
        XCTAssertTrue(home.tryBeginConnecting(profileID: 1))
        let task = Task { try await shortcut.enterExecutionAfterConnecting() }
        task.cancel()
        await assertCancelled(task)
        XCTAssertFalse(shortcut.isExecuting)
        home.endConnecting(profileID: 1)
    }

    func testCancellationRacingHandoffDoesNotLeakExecution() async throws {
        for _ in 0..<30 {
            let home = AppRuntimeFlags()
            let shortcut = AppRuntimeFlags()
            XCTAssertTrue(home.tryBeginConnecting(profileID: 1))
            let task = await enqueue(shortcut)
            home.endConnecting(profileID: 1)
            task.cancel()
            do {
                if let claim = try await task.value { shortcut.exitExecution(claim) }
            } catch is CancellationError {
            }
            XCTAssertFalse(shortcut.isExecuting)
            XCTAssertTrue(home.tryBeginConnecting(profileID: 2))
            home.endConnecting(profileID: 2)
        }
    }

    func testSecondShortcutCannotReplaceWaitingRequest() async throws {
        let home = AppRuntimeFlags()
        let first = AppRuntimeFlags()
        let second = AppRuntimeFlags()
        XCTAssertTrue(home.tryBeginConnecting(profileID: 1))
        let task = await enqueue(first)
        let secondClaim = try await second.enterExecutionAfterConnecting()
        XCTAssertNil(secondClaim)
        home.endConnecting(profileID: 1)
        let result = try await task.value
        first.exitExecution(try XCTUnwrap(result))
    }

    func testExistingExecutionStillRejectsAnotherBackup() async throws {
        let first = AppRuntimeFlags()
        let second = AppRuntimeFlags()
        let claim = try XCTUnwrap(first.tryEnterExecution())
        defer { first.exitExecution(claim) }
        let result = try await second.enterExecutionAfterConnecting()
        XCTAssertNil(result)
    }

    func testConnectionOwnerDeinitReleasesWaitingShortcut() async throws {
        var home: AppRuntimeFlags? = AppRuntimeFlags()
        let shortcut = AppRuntimeFlags()
        XCTAssertTrue(home?.tryBeginConnecting(profileID: 1) == true)
        let task = await enqueue(shortcut)
        home = nil
        let result = try await task.value
        shortcut.exitExecution(try XCTUnwrap(result))
        XCTAssertFalse(shortcut.isExecuting)
    }

    func testHandoffWaitsForConcurrentProfileMutationToFinish() async throws {
        let home = AppRuntimeFlags()
        let shortcut = AppRuntimeFlags()
        XCTAssertTrue(home.tryBeginConnecting(profileID: 1))
        let queued = await home.withAsyncProfileMutationLease(profileID: 2) {
            let task = await self.enqueue(shortcut)
            home.endConnecting(profileID: 1)
            XCTAssertTrue(shortcut.isExecuting)
            XCTAssertNil(home.tryEnterExecution())
            return task
        }
        let task = try XCTUnwrap(queued)
        let result = try await task.value
        shortcut.exitExecution(try XCTUnwrap(result))
    }

    func testEphemeralConnectionAlsoHandsOff() async throws {
        let home = AppRuntimeFlags()
        let shortcut = AppRuntimeFlags()
        XCTAssertTrue(home.tryBeginEphemeralConnecting(sessionID: "test"))
        let task = await enqueue(shortcut)
        home.endEphemeralConnecting(sessionID: "test")
        let result = try await task.value
        shortcut.exitExecution(try XCTUnwrap(result))
    }

    func testShortcutSessionBlocksOnlyAutomaticConnectionsUntilAllSessionsEnd() {
        let home = AppRuntimeFlags()
        let first = AppRuntimeFlags.beginShortcutSession()
        let second = AppRuntimeFlags.beginShortcutSession()
        XCTAssertFalse(home.tryBeginConnecting(profileID: 1, isAutomatic: true))
        XCTAssertTrue(home.tryBeginConnecting(profileID: 1))
        home.endConnecting(profileID: 1)
        AppRuntimeFlags.endShortcutSession(first)
        AppRuntimeFlags.endShortcutSession(first)
        XCTAssertTrue(AppRuntimeFlags.hasActiveShortcutSession)
        XCTAssertFalse(home.tryBeginConnecting(profileID: 1, isAutomatic: true))
        AppRuntimeFlags.endShortcutSession(second)
        XCTAssertFalse(AppRuntimeFlags.hasActiveShortcutSession)
        XCTAssertTrue(home.tryBeginConnecting(profileID: 1, isAutomatic: true))
        home.endConnecting(profileID: 1)
    }

    private func enqueue(_ flags: AppRuntimeFlags) async -> Task<AppRuntimeFlags.ExecutionClaim?, Error> {
        let queued = expectation(description: "shortcut reserves execution behind connection")
        let observer = NotificationCenter.default.addObserver(
            forName: .ExecutionLifecycleDidChange, object: nil, queue: nil
        ) { _ in
            if flags.isExecuting { queued.fulfill() }
        }
        let task = Task { try await flags.enterExecutionAfterConnecting() }
        await fulfillment(of: [queued], timeout: 2)
        NotificationCenter.default.removeObserver(observer)
        return task
    }

    private func assertCancelled(_ task: Task<AppRuntimeFlags.ExecutionClaim?, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancelled wait")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
