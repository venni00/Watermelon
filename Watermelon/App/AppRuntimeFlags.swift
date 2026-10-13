import Foundation

/// Stays true from `enter()` until `exit()` — not until `phase == .completed/.failed`.
/// Non-MainActor so `DependencyContainer` stays instantiable from background tasks.
final class AppRuntimeFlags: @unchecked Sendable {
    struct ExecutionClaim: Sendable {
        fileprivate let token: UUID
    }

    struct ShortcutSessionClaim: Sendable {
        fileprivate let token: UUID
    }

    private struct PendingExecution {
        let owner: ObjectIdentifier
        let token: UUID
        let continuation: CheckedContinuation<ExecutionClaim?, Error>
    }

    @TaskLocal private static var profileMutationLeaseToken: UUID?

    private static let lock = NSLock()
    private static var executionOwner: ObjectIdentifier?
    private static var executionClaimToken: UUID?
    private static var pendingExecution: PendingExecution?
    private static var shortcutSessions: Set<UUID> = []
    private static var activeProfileMutationToken: UUID?
    private static var profileMutationDepth = 0
    private static var connectingProfileID: Int64?
    private static var connectingEphemeralID: String?
    private static var connectingOwner: ObjectIdentifier?

    var isExecuting: Bool {
        Self.lock.withLock { Self.executionOwner != nil || Self.pendingExecution != nil }
    }

    static var hasActiveShortcutSession: Bool {
        lock.withLock { !shortcutSessions.isEmpty }
    }

    static func beginShortcutSession() -> ShortcutSessionClaim {
        let claim = ShortcutSessionClaim(token: UUID())
        let didChange = lock.withLock {
            let wasEmpty = shortcutSessions.isEmpty
            shortcutSessions.insert(claim.token)
            return wasEmpty
        }
        if didChange { NotificationCenter.default.post(name: .ShortcutSessionDidChange, object: nil) }
        return claim
    }

    static func endShortcutSession(_ claim: ShortcutSessionClaim) {
        let didChange = lock.withLock {
            shortcutSessions.remove(claim.token) != nil && shortcutSessions.isEmpty
        }
        if didChange { NotificationCenter.default.post(name: .ShortcutSessionDidChange, object: nil) }
    }

    func isConnecting(profileID: Int64?) -> Bool {
        guard let profileID else { return false }
        return Self.lock.withLock { Self.connectingProfileID == profileID }
    }

    @discardableResult
    func tryEnterExecution() -> ExecutionClaim? {
        let owner = ObjectIdentifier(self)
        let claim: ExecutionClaim? = Self.lock.withLock {
            guard Self.executionOwner == nil,
                  Self.pendingExecution == nil,
                  Self.activeProfileMutationToken == nil,
                  Self.connectingOwner == nil else { return nil }
            let token = UUID()
            Self.executionOwner = owner
            Self.executionClaimToken = token
            return ExecutionClaim(token: token)
        }
        guard let claim else { return nil }
        NotificationCenter.default.post(
            name: .ExecutionLifecycleDidChange,
            object: self
        )
        return claim
    }

    func enterExecutionAfterConnecting() async throws -> ExecutionClaim? {
        let token = UUID()
        let owner = ObjectIdentifier(self)
        let claim: ExecutionClaim? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<ExecutionClaim?, Error>? = Self.lock.withLock {
                    guard !Task.isCancelled else { return .failure(CancellationError()) }
                    guard Self.executionOwner == nil, Self.pendingExecution == nil else {
                        return .success(nil)
                    }
                    if Self.connectingOwner != nil {
                        Self.pendingExecution = PendingExecution(
                            owner: owner, token: token, continuation: continuation
                        )
                        return nil
                    }
                    guard Self.activeProfileMutationToken == nil else { return .success(nil) }
                    Self.executionOwner = owner
                    Self.executionClaimToken = token
                    return .success(ExecutionClaim(token: token))
                }
                if let result {
                    if case .success(.some) = result {
                        NotificationCenter.default.post(name: .ExecutionLifecycleDidChange, object: self)
                    }
                    continuation.resume(with: result)
                } else {
                    NotificationCenter.default.post(name: .ExecutionLifecycleDidChange, object: self)
                }
            }
        } onCancel: {
            let pending = Self.lock.withLock {
                guard Self.pendingExecution?.token == token else { return Optional<PendingExecution>.none }
                let pending = Self.pendingExecution
                Self.pendingExecution = nil
                return pending
            }
            if let pending {
                pending.continuation.resume(throwing: CancellationError())
                NotificationCenter.default.post(name: .ExecutionLifecycleDidChange, object: self)
            }
        }
        if Task.isCancelled {
            if let claim { exitExecution(claim) }
            throw CancellationError()
        }
        return claim
    }

    private static func takeReadyPendingExecutionLocked() -> PendingExecution? {
        // Reserve the handoff before other connection requests can observe an idle runtime.
        guard executionOwner == nil, connectingOwner == nil, activeProfileMutationToken == nil,
              let pending = pendingExecution else { return nil }
        pendingExecution = nil
        executionOwner = pending.owner
        executionClaimToken = pending.token
        return pending
    }

    private static func resumePendingExecution(_ pending: PendingExecution?) {
        guard let pending else { return }
        pending.continuation.resume(returning: ExecutionClaim(token: pending.token))
    }

    // Scope form of the execution mutex for self-contained one-shot work: claim, run, release (even on throw).
    // Returns nil — body NOT run — when another owner holds the mutex, so the caller can surface "task in
    // progress". Prefer this over raw tryEnterExecution/exitExecution so a claim can't be leaked or skipped.
    func withExecutionLease<T: Sendable>(
        _ body: @isolated(any) () async throws -> T
    ) async rethrows -> T? {
        guard let claim = tryEnterExecution() else { return nil }
        defer { exitExecution(claim) }
        return try await body()
    }

    func exitExecution(_ claim: ExecutionClaim) {
        let owner = ObjectIdentifier(self)
        let didChange: Bool = Self.lock.withLock {
            guard Self.executionOwner == owner,
                  Self.executionClaimToken == claim.token else { return false }
            Self.executionOwner = nil
            Self.executionClaimToken = nil
            return true
        }
        guard didChange else { return }
        NotificationCenter.default.post(
            name: .ExecutionLifecycleDidChange,
            object: self
        )
    }

    func withProfileMutationLease<T>(profileID: Int64?, _ body: () throws -> T) rethrows -> T? {
        let token = Self.profileMutationLeaseToken ?? UUID()
        guard Self.acquireProfileMutationLease(token: token, profileID: profileID) else { return nil }
        defer { Self.releaseProfileMutationLease(token: token) }
        return try Self.$profileMutationLeaseToken.withValue(token) {
            try body()
        }
    }

    func withAsyncProfileMutationLease<T>(
        profileID: Int64?,
        _ body: () async throws -> T
    ) async rethrows -> T? {
        let token = Self.profileMutationLeaseToken ?? UUID()
        guard Self.acquireProfileMutationLease(token: token, profileID: profileID) else { return nil }
        defer { Self.releaseProfileMutationLease(token: token) }
        return try await Self.$profileMutationLeaseToken.withValue(token) {
            try await body()
        }
    }

    @discardableResult
    func tryBeginConnecting(profileID: Int64?, isAutomatic: Bool = false) -> Bool {
        guard let profileID else { return false }
        let owner = ObjectIdentifier(self)
        let didChange = Self.lock.withLock {
            guard Self.executionOwner == nil,
                  Self.pendingExecution == nil,
                  !isAutomatic || Self.shortcutSessions.isEmpty,
                  Self.activeProfileMutationToken == nil,
                  Self.connectingOwner == nil ||
                    (Self.connectingOwner == owner && Self.connectingEphemeralID == nil) else { return false }
            Self.connectingProfileID = profileID
            Self.connectingEphemeralID = nil
            Self.connectingOwner = owner
            return true
        }
        if didChange {
            NotificationCenter.default.post(name: .ConnectionLifecycleDidChange, object: self)
        }
        return didChange
    }

    @discardableResult
    func tryBeginEphemeralConnecting(sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        let owner = ObjectIdentifier(self)
        let didChange = Self.lock.withLock {
            guard Self.executionOwner == nil,
                  Self.pendingExecution == nil,
                  Self.activeProfileMutationToken == nil,
                  Self.connectingOwner == nil else { return false }
            Self.connectingProfileID = nil
            Self.connectingEphemeralID = sessionID
            Self.connectingOwner = owner
            return true
        }
        if didChange {
            NotificationCenter.default.post(name: .ConnectionLifecycleDidChange, object: self)
        }
        return didChange
    }

    func endConnecting(profileID: Int64?) {
        guard let profileID else { return }
        let owner = ObjectIdentifier(self)
        let released: (didChange: Bool, pending: PendingExecution?) = Self.lock.withLock {
            guard Self.connectingProfileID == profileID, Self.connectingOwner == owner else { return (false, nil) }
            Self.connectingProfileID = nil
            Self.connectingEphemeralID = nil
            Self.connectingOwner = nil
            return (true, Self.takeReadyPendingExecutionLocked())
        }
        Self.resumePendingExecution(released.pending)
        if released.didChange {
            NotificationCenter.default.post(name: .ConnectionLifecycleDidChange, object: self)
        }
    }

    func endEphemeralConnecting(sessionID: String) {
        let owner = ObjectIdentifier(self)
        let released: (didChange: Bool, pending: PendingExecution?) = Self.lock.withLock {
            guard Self.connectingEphemeralID == sessionID, Self.connectingOwner == owner else { return (false, nil) }
            Self.connectingProfileID = nil
            Self.connectingEphemeralID = nil
            Self.connectingOwner = nil
            return (true, Self.takeReadyPendingExecutionLocked())
        }
        Self.resumePendingExecution(released.pending)
        if released.didChange {
            NotificationCenter.default.post(name: .ConnectionLifecycleDidChange, object: self)
        }
    }

    deinit {
        let owner = ObjectIdentifier(self)
        let released = Self.lock.withLock {
            let releasedConnection = Self.connectingOwner == owner
            if releasedConnection {
                Self.connectingProfileID = nil
                Self.connectingEphemeralID = nil
                Self.connectingOwner = nil
            }

            let releasedExecution = Self.executionOwner == owner
            if releasedExecution {
                Self.executionOwner = nil
                Self.executionClaimToken = nil
            }
            return (connection: releasedConnection, execution: releasedExecution, pending: Self.takeReadyPendingExecutionLocked())
        }
        Self.resumePendingExecution(released.pending)
        if released.connection {
            NotificationCenter.default.post(name: .ConnectionLifecycleDidChange, object: nil)
        }
        if released.execution {
            NotificationCenter.default.post(name: .ExecutionLifecycleDidChange, object: nil)
        }
    }

    private static func acquireProfileMutationLease(token: UUID, profileID: Int64?) -> Bool {
        lock.withLock {
            guard executionOwner == nil,
                  connectingEphemeralID == nil,
                  profileID == nil || connectingProfileID != profileID else { return false }
            if let activeProfileMutationToken {
                guard activeProfileMutationToken == token else { return false }
                profileMutationDepth += 1
            } else {
                activeProfileMutationToken = token
                profileMutationDepth = 1
            }
            return true
        }
    }

    private static func releaseProfileMutationLease(token: UUID) {
        let released: (didEnd: Bool, pending: PendingExecution?) = lock.withLock {
            guard activeProfileMutationToken == token, profileMutationDepth > 0 else { return (false, nil) }
            profileMutationDepth -= 1
            guard profileMutationDepth == 0 else { return (false, nil) }
            activeProfileMutationToken = nil
            return (true, takeReadyPendingExecutionLocked())
        }
        resumePendingExecution(released.pending)
        if released.didEnd { NotificationCenter.default.post(name: .ProfileMutationLeaseDidEnd, object: nil) }
    }

    #if DEBUG
    static func _testReset() {
        let pending = lock.withLock {
            let pending = pendingExecution
            pendingExecution = nil
            shortcutSessions = []
            executionOwner = nil
            executionClaimToken = nil
            activeProfileMutationToken = nil
            profileMutationDepth = 0
            connectingProfileID = nil
            connectingEphemeralID = nil
            connectingOwner = nil
            return pending
        }
        pending?.continuation.resume(throwing: CancellationError())
    }
    #endif
}
