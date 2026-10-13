import UIKit

@MainActor
final class HomeAutoConnectCoordinator {
    enum AttemptResult {
        case deferred
        case finished
    }

    struct Hooks {
        let isReady: () -> Bool
        let attempt: () -> AttemptResult
    }

    private enum State {
        case waitingForBootstrap
        case pending
        case attempting
        case finished
    }

    private let hooks: Hooks
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var state = State.waitingForBootstrap

    init(notificationCenter: NotificationCenter = .default, hooks: Hooks) {
        self.notificationCenter = notificationCenter
        self.hooks = hooks
        let notifications: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            .ExecutionLifecycleDidChange,
            .ConnectionLifecycleDidChange,
            .RemoteMaintenanceDidChange,
            .ShortcutSessionDidChange,
            .ProfileMutationLeaseDidEnd
        ]
        for name in notifications {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeIfPossible() }
            })
        }
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }

    func request() {
        if state == .waitingForBootstrap { state = .pending }
        resumeIfPossible()
    }

    func resumeIfPossible() {
        guard state == .pending, hooks.isReady() else { return }
        state = .attempting
        switch hooks.attempt() {
        case .deferred: state = .pending
        case .finished: state = .finished
        }
    }
}
