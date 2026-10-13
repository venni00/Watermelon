import UIKit
import XCTest
@testable import Watermelon

@MainActor
final class HomeAutoConnectCoordinatorTests: XCTestCase {
    func testBootstrapAndActivationCanArriveInEitherOrder() {
        for bootstrapFirst in [true, false] {
            let center = NotificationCenter()
            var active = false
            var count = 0
            let coordinator = HomeAutoConnectCoordinator(notificationCenter: center, hooks: .init(
                isReady: { active },
                attempt: { count += 1; return .finished }
            ))
            if bootstrapFirst { coordinator.request() }
            active = true
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            if !bootstrapFirst {
                XCTAssertEqual(count, 0)
                coordinator.request()
            }
            XCTAssertEqual(count, 1)
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            coordinator.request()
            XCTAssertEqual(count, 1)
        }
    }

    func testDeferredAttemptResumesOnLifecycleChangeWithoutReentrantAttempt() {
        let center = NotificationCenter()
        var blocked = true
        var count = 0
        let coordinator = HomeAutoConnectCoordinator(notificationCenter: center, hooks: .init(
            isReady: { true },
            attempt: {
                count += 1
                if blocked { return .deferred }
                center.post(name: .ConnectionLifecycleDidChange, object: nil)
                return .finished
            }
        ))
        coordinator.request()
        XCTAssertEqual(count, 1)
        blocked = false
        center.post(name: .ExecutionLifecycleDidChange, object: nil)
        XCTAssertEqual(count, 2)
        center.post(name: .ExecutionLifecycleDidChange, object: nil)
        XCTAssertEqual(count, 2)
    }

    func testMaintenanceAndShortcutCompletionRespectCurrentReadiness() {
        let center = NotificationCenter()
        var ready = false
        var count = 0
        let coordinator = HomeAutoConnectCoordinator(notificationCenter: center, hooks: .init(
            isReady: { ready },
            attempt: { count += 1; return .finished }
        ))
        coordinator.request()
        center.post(name: .RemoteMaintenanceDidChange, object: nil)
        center.post(name: .ShortcutSessionDidChange, object: nil)
        XCTAssertEqual(count, 0)
        ready = true
        center.post(name: .ShortcutSessionDidChange, object: nil)
        XCTAssertEqual(count, 1)
    }
}
