import UIKit
import XCTest
@testable import Watermelon

@MainActor
final class HomeAutoConnectTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppRuntimeFlags._testReset()
    }

    override func tearDown() {
        AppRuntimeFlags._testReset()
        super.tearDown()
    }

    func testBackgroundBootstrapLeavesExecutionAvailableAndConnectsAfterActivation() async throws {
        let harness = try Harness()
        defer { harness.close() }
        let shortcut = AppRuntimeFlags()

        for state in [UIApplication.State.background, .inactive] {
            harness.applicationState = state
            harness.autoConnect.request()
            XCTAssertFalse(harness.controller.state.isConnecting)
            let claim = try XCTUnwrap(shortcut.tryEnterExecution())
            shortcut.exitExecution(claim)
        }

        harness.applicationState = .active
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(harness.controller.state.isConnecting)
        XCTAssertNil(shortcut.tryEnterExecution())
        await waitForConnectionToFinish(harness)
    }

    func testActivationDuringBackupPreservesPendingAutoConnect() async throws {
        let harness = try Harness()
        defer { harness.close() }
        let shortcut = AppRuntimeFlags()
        let claim = try XCTUnwrap(shortcut.tryEnterExecution())
        defer { shortcut.exitExecution(claim) }

        harness.applicationState = .active
        harness.autoConnect.request()
        XCTAssertFalse(harness.controller.state.isConnecting)
        XCTAssertTrue(shortcut.isExecuting)

        shortcut.exitExecution(claim)
        XCTAssertTrue(harness.controller.state.isConnecting)
        await waitForConnectionToFinish(harness)
    }

    func testShortcutStartupDefersHomeBeforeBackupHasAcquiredExecution() async throws {
        let harness = try Harness()
        defer { harness.close() }
        let session = AppRuntimeFlags.beginShortcutSession()
        defer { AppRuntimeFlags.endShortcutSession(session) }
        harness.applicationState = .active
        harness.autoConnect.request()

        XCTAssertFalse(harness.dependencies.appRuntimeFlags.isExecuting)
        XCTAssertFalse(harness.controller.state.isConnecting)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(harness.controller.state.isConnecting)

        AppRuntimeFlags.endShortcutSession(session)
        XCTAssertTrue(harness.controller.state.isConnecting)
        await waitForConnectionToFinish(harness)
    }

    func testBackupCompletionInBackgroundKeepsAutoConnectDeferred() throws {
        let harness = try Harness()
        defer { harness.close() }
        let shortcut = AppRuntimeFlags()
        let claim = try XCTUnwrap(shortcut.tryEnterExecution())
        harness.applicationState = .active
        harness.autoConnect.request()

        harness.applicationState = .background
        shortcut.exitExecution(claim)
        harness.autoConnect.request()

        XCTAssertFalse(harness.controller.state.isConnecting)
        let nextClaim = try XCTUnwrap(shortcut.tryEnterExecution())
        shortcut.exitExecution(nextClaim)
    }

    func testRejectedConnectionClaimDoesNotConsumeAutoConnect() async throws {
        let harness = try Harness()
        defer { harness.close() }
        harness.applicationState = .active
        let mutationOwner = AppRuntimeFlags()

        let blocked = mutationOwner.withProfileMutationLease(profileID: nil) {
            harness.autoConnect.request()
            return !harness.controller.state.isConnecting
        }
        XCTAssertEqual(blocked, true)

        XCTAssertTrue(harness.controller.state.isConnecting)
        await waitForConnectionToFinish(harness)
    }

    func testDeferredAutoConnectDoesNotReplaceManuallyConnectedProfile() throws {
        let harness = try Harness()
        defer { harness.close() }
        harness.autoConnect.request()
        var manualProfile = harness.profile
        manualProfile.id = 999
        harness.dependencies.appSession.activate(profile: manualProfile, password: "")

        harness.applicationState = .active
        harness.autoConnect.request()

        XCTAssertFalse(harness.controller.state.isConnecting)
        XCTAssertEqual(harness.dependencies.appSession.activeProfile?.id, manualProfile.id)
    }

    func testBrowserLinkSuppressionSurvivesForegroundActivation() throws {
        let harness = try Harness()
        defer { harness.close() }
        harness.autoConnect.request()
        harness.controller.suppressAutoConnectForBrowserLink()
        harness.applicationState = .active
        harness.autoConnect.request()

        XCTAssertFalse(harness.controller.state.isConnecting)
        let shortcut = AppRuntimeFlags()
        let claim = try XCTUnwrap(shortcut.tryEnterExecution())
        shortcut.exitExecution(claim)
    }

    func testFailedForegroundConnectionIsNotRetriedOnEveryActivation() async throws {
        let harness = try Harness()
        defer { harness.close() }
        harness.applicationState = .active
        harness.autoConnect.request()
        XCTAssertTrue(harness.controller.state.isConnecting)
        await waitForConnectionToFinish(harness)

        harness.applicationState = .background
        harness.autoConnect.request()
        harness.applicationState = .active
        harness.autoConnect.request()
        XCTAssertFalse(harness.controller.state.isConnecting)
    }

    private func waitForConnectionToFinish(_ harness: Harness) async {
        let settled = expectation(description: "invalid test destination releases connection")
        harness.controller.onStateChanged = {
            if !harness.controller.state.isConnecting { settled.fulfill() }
        }
        await fulfillment(of: [settled], timeout: 2)
        harness.controller.onStateChanged = nil
        XCTAssertFalse(harness.controller.state.isConnecting)
        XCTAssertFalse(harness.dependencies.appRuntimeFlags.isConnecting(profileID: harness.profile.id))
    }

    @MainActor
    private final class Harness {
        let directory: URL
        let dependencies: DependencyContainer
        let profile: ServerProfileRecord
        var applicationState: UIApplication.State = .background
        lazy var controller = HomeConnectionController(
            dependencies: dependencies,
            applicationState: { [unowned self] in applicationState }
        )
        lazy var autoConnect = HomeAutoConnectCoordinator(
            hooks: .init(
                isReady: { true },
                attempt: { [unowned self] in controller.attemptAutoConnect() }
            )
        )

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("home-auto-connect-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = try DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
            dependencies = DependencyContainer(
                databaseManager: database,
                startProfileReachability: false,
                reconcileOneDriveAccounts: false
            )
            var profile = ServerProfileRecord(
                id: nil,
                name: "Unavailable test destination",
                storageType: StorageType.externalVolume.rawValue,
                connectionParams: try ServerProfileRecord.encodedConnectionParams(
                    ExternalVolumeConnectionParams(rootBookmarkData: Data([1]), displayPath: "/unavailable")
                ),
                sortOrder: 0,
                host: "",
                port: 0,
                shareName: "",
                basePath: "/",
                username: "",
                domain: "",
                credentialRef: UUID().uuidString,
                backgroundBackupEnabled: false,
                backgroundBackupMinIntervalMinutes: 720,
                backgroundBackupRequiresWiFi: true,
                generateRemoteThumbnails: false,
                createdAt: Date(),
                updatedAt: Date()
            )
            try database.saveServerProfile(&profile)
            try database.setActiveServerProfileID(profile.id)
            self.profile = profile
            controller.loadProfiles()
        }

        func close() {
            controller.onStateChanged = nil
            controller.disconnect()
            try? dependencies.databaseManager.dbQueue.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
