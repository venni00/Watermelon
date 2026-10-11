import UIKit

@MainActor
final class MediaBrowserCollectionView: UICollectionView {
    var onLayout: (() -> Void)?
    private var isReconcilingSelection = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isReconcilingSelection else { return }
        isReconcilingSelection = true
        onLayout?()
        isReconcilingSelection = false
    }
}

@MainActor
enum MediaBrowserCollectionSelection {
    static func synchronize(
        in collectionView: UICollectionView,
        visibleIndexPaths: Set<IndexPath>,
        isSelecting: Bool,
        selectedItemIDs: Set<MediaBrowserItemID>,
        preservesOffscreenSelection: Bool = false,
        itemID: (IndexPath) -> MediaBrowserItemID?
    ) {
        // UIKit only needs visible selections; the complete selection lives in selectedItemIDs.
        let current = Set(collectionView.indexPathsForSelectedItems ?? [])
        let desired: Set<IndexPath> = isSelecting ? Set(visibleIndexPaths.filter { indexPath in
            guard let id = itemID(indexPath) else { return false }
            return selectedItemIDs.contains(id)
        }) : []
        let retained = preservesOffscreenSelection && isSelecting ? current.subtracting(visibleIndexPaths) : []
        for indexPath in current.subtracting(desired).subtracting(retained) {
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        for indexPath in desired.subtracting(current) {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
        // UIKit may reset a reused cell after willDisplay, even when its index path is already selected.
        for indexPath in visibleIndexPaths {
            guard let cell = collectionView.cellForItem(at: indexPath) else { continue }
            let selected = desired.contains(indexPath)
            if cell.isSelected != selected { cell.isSelected = selected }
        }
    }
}
