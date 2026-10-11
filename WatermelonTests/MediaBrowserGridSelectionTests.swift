import Photos
import UIKit
import XCTest
@testable import Watermelon

@MainActor
final class MediaBrowserGridSelectionTests: XCTestCase {
    func testLargeSelectAllSurvivesIdleReloadScrollAndNativeDeselection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dependencies = DependencyContainer(databaseManager: try DatabaseManager(databaseURL: directory.appendingPathComponent("index.sqlite")),
            reconcileOneDriveAccounts: false)
        defer { try? dependencies.databaseManager.dbQueue.close() }
        let presence = LibraryPresenceIndex(hashIndexRepository: dependencies.hashIndexRepository,
            coordinator: dependencies.backupCoordinator, profileKey: { nil })
        let runner = MediaBrowserActionRunner(env: .init(appSession: dependencies.appSession,
            backupCoordinator: dependencies.backupCoordinator, restoreService: dependencies.restoreService,
            photoLibraryService: dependencies.photoLibraryService, hashIndexRepository: dependencies.hashIndexRepository,
            localHashIndexBuildService: dependencies.localHashIndexBuildService,
            localIndexChangePublisher: dependencies.localIndexChangePublisher, allAccessibleAssetIDs: { [] },
            presenceIndex: presence, appRuntimeFlags: dependencies.appRuntimeFlags, isTaskActive: { false },
            iCloudPhotoBackupMode: { .disable }, monthGroupingTimeZone: { .frozenCurrent() }))
        let items = (0..<50_000).map { index in
            MediaBrowserItem(kind: .photo, creationDateMs: Int64(index),
                localIdentifier: "asset-\(index)", fingerprint: nil, isBackedUp: index.isMultiple(of: 2))
        }
        let source = SelectionSource(items: items)
        let remoteSource = SelectionSource(items: Array(items.prefix(4)))
        let controller = MediaBrowserGridViewController(
            specs: [.init(mode: .local, isAvailable: { true }, makeSource: { source }),
                    .init(mode: .remote, isAvailable: { true }, makeSource: { remoteSource })],
            initialMode: .local, initialMonth: nil, remoteStorageImage: { nil }, sessionToken: { nil },
            actionRunner: runner, presenceIndex: presence, title: "Selection test")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        controller.loadViewIfNeeded()
        let collection = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        try await waitUntil {
            controller.view.layoutIfNeeded()
            return collection.numberOfSections == 1 && collection.numberOfItems(inSection: 0) == items.count
                && !collection.indexPathsForVisibleItems.isEmpty
        }
        let dataSource = try XCTUnwrap(collection.dataSource as? UICollectionViewDiffableDataSource<LibraryMonthKey, MediaBrowserItemID>)
        let firstPath = IndexPath(item: 0, section: 0)
        let firstCell = try XCTUnwrap(collection.cellForItem(at: firstPath))
        let firstCheckbox = try checkbox(in: firstCell)
        firstCheckbox.sendActions(for: .touchUpInside)
        XCTAssertTrue(firstCheckbox.isSelected)
        XCTAssertEqual(collection.indexPathsForSelectedItems, [firstPath])
        firstCheckbox.sendActions(for: .touchUpInside)
        XCTAssertFalse(firstCheckbox.isSelected)
        XCTAssertTrue(collection.indexPathsForSelectedItems?.isEmpty ?? true)
        let selectionStarted = ProcessInfo.processInfo.systemUptime
        controller.perform(NSSelectorFromString("selectAllItems"))
        let selectionMilliseconds = (ProcessInfo.processInfo.systemUptime - selectionStarted) * 1_000
        assertVisibleSelection(collection, selected: true)

        let reloadStarted = ProcessInfo.processInfo.systemUptime
        for round in 0..<3 {
            let marker = MediaBrowserItem(kind: .photo, creationDateMs: 0,
                localIdentifier: "refresh-\(round)", fingerprint: nil, isBackedUp: false)
            source.replace(items: items.dropLast() + [marker])
            NotificationCenter.default.post(name: .LibraryPresenceDidChange, object: presence)
            try await waitUntil {
                dataSource.itemIdentifier(for: IndexPath(item: items.count - 1, section: 0)) == marker.id
            }
            await Task.yield()
            collection.layoutIfNeeded()
            assertVisibleSelection(collection, selected: true)
        }
        print("GRID_SELECTION count=\(items.count) nativeSelected=\(collection.indexPathsForSelectedItems?.count ?? 0) visible=\(collection.indexPathsForVisibleItems.count) selectAllMs=\(selectionMilliseconds) threeReloadsMs=\((ProcessInfo.processInfo.systemUptime - reloadStarted) * 1_000)")

        collection.scrollToItem(at: IndexPath(item: 40_000, section: 0), at: .top, animated: false)
        collection.layoutIfNeeded()
        assertVisibleSelection(collection, selected: true)
        collection.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: false)
        collection.layoutIfNeeded()
        assertVisibleSelection(collection, selected: true)

        let path = try XCTUnwrap(collection.indexPathsForVisibleItems.first)
        controller.collectionView(collection, didBeginMultipleSelectionInteractionAt: path)
        collection.deselectItem(at: path, animated: false)
        controller.collectionView(collection, didDeselectItemAt: path)
        controller.collectionViewDidEndMultipleSelectionInteraction(collection)
        XCTAssertFalse(collection.indexPathsForSelectedItems?.contains(path) ?? false)
        collection.scrollToItem(at: IndexPath(item: 40_000, section: 0), at: .top, animated: false)
        collection.layoutIfNeeded()
        collection.scrollToItem(at: path, at: .top, animated: false)
        collection.layoutIfNeeded()
        XCTAssertFalse(collection.indexPathsForSelectedItems?.contains(path) ?? false)

        controller.perform(NSSelectorFromString("selectAllItems"))
        collection.scrollToItem(at: firstPath, at: .top, animated: false)
        collection.layoutIfNeeded()
        let dragCell = try XCTUnwrap(collection.cellForItem(at: firstPath))
        let drag = SelectionDragGesture()
        drag.testState = .began
        dragCell.perform(NSSelectorFromString("selectionButtonDragged:"), with: drag)
        drag.testState = .changed
        drag.testLocation = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 8, section: 0))).center
        dragCell.perform(NSSelectorFromString("selectionButtonDragged:"), with: drag)
        for index in 0...8 { XCTAssertFalse(collection.indexPathsForSelectedItems?.contains(IndexPath(item: index, section: 0)) ?? false) }
        drag.testLocation = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 3, section: 0))).center
        dragCell.perform(NSSelectorFromString("selectionButtonDragged:"), with: drag)
        for index in 4...8 { XCTAssertTrue(collection.indexPathsForSelectedItems?.contains(IndexPath(item: index, section: 0)) ?? false) }
        drag.testState = .ended
        dragCell.perform(NSSelectorFromString("selectionButtonDragged:"), with: drag)
        controller.perform(NSSelectorFromString("selectAllItems"))
        assertVisibleSelection(collection, selected: true)

        let inserted = MediaBrowserItem(kind: .photo, creationDateMs: 0,
            localIdentifier: "inserted", fingerprint: nil, isBackedUp: false)
        source.replace(items: [inserted] + items.dropFirst())
        NotificationCenter.default.post(name: .LibraryPresenceDidChange, object: presence)
        try await waitUntil { dataSource.itemIdentifier(for: IndexPath(item: 0, section: 0)) == inserted.id }
        collection.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(collection.indexPathsForSelectedItems?.contains(IndexPath(item: 0, section: 0)) ?? false)
        XCTAssertLessThanOrEqual(collection.indexPathsForSelectedItems?.count ?? 0, collection.indexPathsForVisibleItems.count)

        let switcher = try XCTUnwrap(controller.navigationItem.titleView as? UISegmentedControl)
        switcher.selectedSegmentIndex = 1
        switcher.sendActions(for: .valueChanged)
        try await waitUntil { collection.numberOfSections == 1 && collection.numberOfItems(inSection: 0) == 4 }
        collection.layoutIfNeeded()
        assertVisibleSelection(collection, selected: false)
        controller.perform(NSSelectorFromString("enterSelection"))
        controller.perform(NSSelectorFromString("selectAllItems"))
        assertVisibleSelection(collection, selected: true)
        switcher.selectedSegmentIndex = 0
        switcher.sendActions(for: .valueChanged)
        try await waitUntil { collection.numberOfSections == 1 && collection.numberOfItems(inSection: 0) == items.count }
        collection.layoutIfNeeded()
        assertVisibleSelection(collection, selected: false)
        controller.perform(NSSelectorFromString("enterSelection"))
        controller.perform(NSSelectorFromString("selectAllItems"))
        controller.setFilter(.backedUp)
        controller.perform(NSSelectorFromString("enterSelection"))
        controller.perform(NSSelectorFromString("selectAllItems"))
        XCTAssertTrue(collection.indexPathsForSelectedItems?.isEmpty ?? true)
        try await waitUntil { collection.numberOfSections == 1 && collection.numberOfItems(inSection: 0) == 24_999 }
        collection.layoutIfNeeded()
        assertVisibleSelection(collection, selected: false)
        controller.perform(NSSelectorFromString("enterSelection"))
        controller.perform(NSSelectorFromString("selectAllItems"))
        assertVisibleSelection(collection, selected: true)
        controller.setFilter(.all)
        try await waitUntil { collection.numberOfSections == 1 && collection.numberOfItems(inSection: 0) == items.count }
        collection.layoutIfNeeded()
        assertVisibleSelection(collection, selected: false)
        controller.perform(NSSelectorFromString("enterSelection"))
        controller.perform(NSSelectorFromString("selectAllItems"))
        let checkbox = try checkbox(in: XCTUnwrap(collection.cellForItem(at: firstPath)))
        checkbox.sendActions(for: .touchUpInside)
        XCTAssertFalse(checkbox.isSelected)

        let gate = ActionGate()
        XCTAssertTrue(controller.runExternalSelectionAction { _ in await gate.wait(); return false })
        try await waitUntil { gate.continuation != nil }
        checkbox.sendActions(for: .touchUpInside)
        controller.perform(NSSelectorFromString("selectAllItems"))
        controller.perform(NSSelectorFromString("cancelSelection"))
        XCTAssertFalse(checkbox.isSelected)
        XCTAssertFalse(collection.indexPathsForSelectedItems?.isEmpty ?? true)
        XCTAssertFalse(controller.collectionView(collection, shouldBeginMultipleSelectionInteractionAt: firstPath))
        switcher.selectedSegmentIndex = 1
        switcher.sendActions(for: .valueChanged)
        XCTAssertEqual(switcher.selectedSegmentIndex, 0)
        source.replace(items: [])
        NotificationCenter.default.post(name: .LibraryPresenceDidChange, object: presence)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(collection.numberOfItems(inSection: 0), items.count)
        gate.finish()
        try await waitUntil { collection.numberOfSections == 0 || collection.numberOfItems(inSection: 0) == 0 }
        XCTAssertTrue(collection.indexPathsForSelectedItems?.isEmpty ?? true)
        controller.perform(NSSelectorFromString("exitSelection"))
    }

    private func assertVisibleSelection(_ collection: UICollectionView, selected: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let visible = Set(collection.indexPathsForVisibleItems)
        XCTAssertFalse(visible.isEmpty, file: file, line: line)
        XCTAssertEqual(Set(collection.indexPathsForSelectedItems ?? []), selected ? visible : [], file: file, line: line)
        for cell in collection.visibleCells {
            XCTAssertEqual(cell.isSelected, selected, file: file, line: line)
            XCTAssertEqual(try checkbox(in: cell).isSelected, selected, file: file, line: line)
        }
    }

    private func checkbox(in view: UIView) throws -> UIButton {
        if let button = view as? UIButton { return button }
        for child in view.subviews {
            if let button = try? checkbox(in: child) { return button }
        }
        throw NSError(domain: "SelectionCheckboxMissing", code: 1)
    }

    private final class SelectionDragGesture: UILongPressGestureRecognizer {
        var testState = UIGestureRecognizer.State.possible
        var testLocation = CGPoint.zero
        override var state: UIGestureRecognizer.State { get { testState } set { testState = newValue } }
        override func location(in view: UIView?) -> CGPoint { testLocation }
    }

    private final class ActionGate {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func finish() { continuation?.resume(); continuation = nil }
        deinit { continuation?.resume() }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Grid did not reach the expected state")
        throw NSError(domain: "SelectionTestTimeout", code: 1)
    }

    private final class SelectionSource: MediaBrowserSource, @unchecked Sendable {
        let mode = MediaBrowserMode.local
        private let lock = NSLock()
        private var items: [MediaBrowserItem]

        init(items: [MediaBrowserItem]) { self.items = items }
        func replace(items: [MediaBrowserItem]) { lock.withLock { self.items = items } }
        func load() async -> MediaBrowserLoadResult {
            lock.withLock {
                return .loaded(.init(sections: [.init(month: .init(year: 2026, month: 1), items: items)]))
            }
        }
        func thumbnail(for item: MediaBrowserItem) async -> UIImage? { nil }
        func photoImage(for item: MediaBrowserItem) async -> UIImage? { nil }
        func livePhoto(for item: MediaBrowserItem, targetSize: CGSize) async -> PHLivePhoto? { nil }
        func video(for item: MediaBrowserItem) async -> MaterializedVideo? { nil }
    }
}
