import UIKit
import XCTest
@testable import Watermelon

@MainActor
final class MediaBrowserCollectionSelectionTests: XCTestCase {
    func testSelectAllOnlyUpdatesVisibleItemsAndRepeatedRefreshDoesNothing() {
        let fixture = Fixture(count: 50_000)
        let selected = Set((0..<50_000).map { MediaBrowserItemID.local("asset-\($0)") })
        let visible = Set((0..<40).map { IndexPath(item: $0, section: 0) })
        var lookups = 0
        func synchronize() {
            MediaBrowserCollectionSelection.synchronize(in: fixture.collection, visibleIndexPaths: visible,
                isSelecting: true, selectedItemIDs: selected, itemID: { path in
                    lookups += 1
                    return .local("asset-\(path.item)")
                })
        }

        synchronize()
        XCTAssertEqual(fixture.collection.selectionCalls, 40)
        XCTAssertEqual(lookups, 40)
        XCTAssertEqual(Set(fixture.collection.indexPathsForSelectedItems ?? []), visible)
        fixture.collection.selectionCalls = 0
        synchronize()
        XCTAssertEqual(fixture.collection.selectionCalls, 0)
        XCTAssertEqual(fixture.collection.deselectionCalls, 0)
        XCTAssertEqual(lookups, 80)
    }

    func testScrollKeepsFullBusinessSelectionAndDropsOffscreenUIKitSelection() {
        let fixture = Fixture(count: 500)
        let selected = Set((0..<500).map { MediaBrowserItemID.local("asset-\($0)") })
        for start in [0, 100, 450, 0] {
            let visible = Set((start..<(start + 30)).map { IndexPath(item: $0, section: 0) })
            MediaBrowserCollectionSelection.synchronize(in: fixture.collection, visibleIndexPaths: visible,
                isSelecting: true, selectedItemIDs: selected, itemID: { .local("asset-\($0.item)") })
            XCTAssertEqual(Set(fixture.collection.indexPathsForSelectedItems ?? []), visible)
            XCTAssertEqual(selected.count, 500)
        }
    }

    func testReorderedAndInsertedVisibleItemsResolveSelectionByIDAndExitClearsIt() {
        let fixture = Fixture(count: 4)
        let selected: Set<MediaBrowserItemID> = [.local("a"), .local("b")]
        let visible = Set((0..<4).map { IndexPath(item: $0, section: 0) })
        var ids: [MediaBrowserItemID] = [.local("a"), .local("b"), .local("c"), .local("d")]
        func synchronize(selecting: Bool) {
            MediaBrowserCollectionSelection.synchronize(in: fixture.collection, visibleIndexPaths: visible,
                isSelecting: selecting, selectedItemIDs: selected, itemID: { ids[$0.item] })
        }
        synchronize(selecting: true)
        ids = [.local("inserted"), .local("c"), .local("b"), .local("a")]
        synchronize(selecting: true)
        XCTAssertEqual(Set(fixture.collection.indexPathsForSelectedItems ?? []),
            [IndexPath(item: 2, section: 0), IndexPath(item: 3, section: 0)])
        synchronize(selecting: false)
        XCTAssertTrue(fixture.collection.indexPathsForSelectedItems?.isEmpty ?? true)
    }

    func testNativeGestureKeepsVisitedPathsUntilItEnds() {
        let fixture = Fixture(count: 100)
        let selected = Set((0..<100).map { MediaBrowserItemID.local("asset-\($0)") })
        let first = Set((0..<10).map { IndexPath(item: $0, section: 0) })
        let second = Set((10..<20).map { IndexPath(item: $0, section: 0) })
        func synchronize(_ visible: Set<IndexPath>, interacting: Bool) {
            MediaBrowserCollectionSelection.synchronize(in: fixture.collection, visibleIndexPaths: visible,
                isSelecting: true, selectedItemIDs: selected, preservesOffscreenSelection: interacting,
                itemID: { .local("asset-\($0.item)") })
        }
        synchronize(first, interacting: false)
        synchronize(second, interacting: true)
        XCTAssertEqual(Set(fixture.collection.indexPathsForSelectedItems ?? []), first.union(second))
        synchronize(second, interacting: false)
        XCTAssertEqual(Set(fixture.collection.indexPathsForSelectedItems ?? []), second)
    }

    private final class Fixture: NSObject, UICollectionViewDataSource {
        let collection = CountingCollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        let count: Int

        init(count: Int) {
            self.count = count
            super.init()
            collection.allowsMultipleSelection = true
            collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
            collection.dataSource = self
            collection.reloadData()
            collection.layoutIfNeeded()
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { count }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }
    }

    private final class CountingCollectionView: UICollectionView {
        var selectionCalls = 0
        var deselectionCalls = 0

        override func selectItem(at indexPath: IndexPath?, animated: Bool, scrollPosition: UICollectionView.ScrollPosition) {
            selectionCalls += 1
            super.selectItem(at: indexPath, animated: animated, scrollPosition: scrollPosition)
        }

        override func deselectItem(at indexPath: IndexPath, animated: Bool) {
            deselectionCalls += 1
            super.deselectItem(at: indexPath, animated: animated)
        }
    }
}
