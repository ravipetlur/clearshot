import AppKit
import CSHistory
import CSRecording
import SwiftUI

/// The History grid in the SwiftUI content. SwiftUI makes a new one each time the content switches back from an empty
/// state, so it only hands over the grid's scroll view, which the window controller keeps.
struct HistoryGridView: NSViewRepresentable {
    let grid: HistoryGrid

    func makeNSView(context: Context) -> NSScrollView {
        grid.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}

/// The History grid's AppKit side, made once with the window: the scroll view and collection view, the diffable data
/// source of item IDs, and the thumbnail and icon caches. It applies the model's refreshes (animating the differences,
/// reloading items that changed in place, then setting the selection back by ID), moves the time labels on with the
/// model's clock, and puts dragged captures on the pasteboard.
final class HistoryGrid: NSObject, NSCollectionViewDelegate {
    let scrollView = NSScrollView()
    let collectionView = HistoryCollectionView()
    private let model: HistoryModel
    private let history: HistoryStore
    private let itemActions: HistoryItemActions
    private let dataSource: NSCollectionViewDiffableDataSource<Int, UUID>
    /// True while a snapshot is applied: selection callbacks then come from items moving, not from the person.
    private var isApplying = false
    /// The PNG providers of the drag in progress, kept until it ends: a drop target may ask for the PNG late.
    private var dragProviders: [DragImageProvider] = []

    init(model: HistoryModel, history: HistoryStore, itemActions: HistoryItemActions) {
        self.model = model
        self.history = history
        self.itemActions = itemActions
        let thumbnails = HistoryThumbnails(root: history.root)
        let icons = AppIcons()
        dataSource = NSCollectionViewDiffableDataSource(collectionView: collectionView) { [weak model, weak history] view, indexPath, id in
            let cell = view.makeItem(withIdentifier: HistoryCell.identifier, for: indexPath)
            guard let cell = cell as? HistoryCell, let model, let history else { return cell }
            let item = history.item(id: id)
            // A video's or GIF's badge reads its size now, so a reload after Mute or Replace shows the new one.
            cell.configure(item, icon: item.flatMap(icons.icon(for:)),
                           badge: item.flatMap { MediaBadge(item: $0, root: history.root) }, now: model.now,
                           thumbnails: thumbnails)
            return cell
        }
        super.init()
        configureViews()
        model.onRefresh = { [weak self] updatedIDs in self?.apply(reloading: updatedIDs) }
        model.onTick = { [weak self] in self?.refreshTimes() }
        apply(reloading: [])
    }

    private func configureViews() {
        let layout = LeadingFlowLayout()
        layout.itemSize = HistoryCell.size
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        collectionView.collectionViewLayout = layout
        collectionView.register(HistoryCell.self, forItemWithIdentifier: HistoryCell.identifier)
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = self
        // Drag-out copies, never moves: to other apps, and within ClearShot onto a desktop cover or an Annotate canvas,
        // as thumbnails and pins do.
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: true)
        collectionView.onSelectionChange = { [weak model] ids in model?.selection = ids }
        collectionView.previewFile = { [weak history, weak itemActions] id in
            guard let history, let itemActions, let item = history.item(id: id) else { return nil }
            return itemActions.file(for: item)
        }

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    /// Focuses the grid when it is in the window (the content may be an empty state).
    func focus() {
        collectionView.window?.makeFirstResponder(collectionView)
    }

    // MARK: Applying the model

    /// Shows the model's visible items. Items that changed in place and were already shown are reloaded (a snapshot
    /// can only reload items it holds); the selection is then set back to those of its items still shown, through
    /// `select(_:)`, which the model follows.
    private func apply(reloading updatedIDs: Set<UUID>) {
        let ids = model.visibleIDs
        let shown = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        let reloads = ids.filter { updatedIDs.contains($0) && shown.contains($0) }
        if !reloads.isEmpty { snapshot.reloadItems(reloads) }
        let animates = collectionView.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isApplying = true
        dataSource.apply(snapshot, animatingDifferences: animates)
        isApplying = false
        collectionView.select(model.selection)
    }

    /// The minute clock moved on: only the time labels change.
    private func refreshTimes() {
        for case let cell as HistoryCell in collectionView.visibleItems() {
            cell.updateTime(now: model.now)
        }
    }

    /// The window became or stopped being key: selected cells switch between the accent and unemphasized colours.
    func refreshSelectionEmphasis() {
        for case let cell as HistoryCell in collectionView.visibleItems() {
            cell.updateSelection()
        }
    }

    // MARK: NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectionChanged()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionChanged()
    }

    /// A cell shown again after scrolling may have missed a tick.
    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? HistoryCell)?.updateTime(now: model.now)
    }

    private func selectionChanged() {
        guard !isApplying else { return }
        collectionView.selectionDidChange()
    }

    // MARK: Drag-out

    /// Each dragged capture carries its file (`HistoryItemActions.dragFiles`) and, for a screenshot, a PNG for targets
    /// that take only an image, read only when one asks. The collection view draws each item's drag image from its cell,
    /// a video's or GIF's badge included (`HistoryCell.draggingImageComponents`).
    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = history.item(id: id) else { return nil }
        let files = itemActions.dragFiles(for: item)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(files.file.absoluteString, forType: .fileURL)
        if let png = files.png {
            let provider = DragImageProvider(pngURL: png)
            dragProviders.append(provider)
            pasteboardItem.setDataProvider(provider, forTypes: [.png])
        }
        return pasteboardItem
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        dragProviders.removeAll()
    }
}

/// A flow layout whose rows start at the left inset with exactly the minimum spacing between items, keeping the stock
/// layout's rows: the stock layout spreads a row's leftover width between its items (102 pt gaps at 820 pt).
private final class LeadingFlowLayout: NSCollectionViewFlowLayout {
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        super.layoutAttributesForElements(in: rect).map(leadingAligned)
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        super.layoutAttributesForItem(at: indexPath).map(leadingAligned)
    }

    /// The stock layout puts column c at `left + c × (width + gap)` with gap at least the minimum and less than one
    /// more item's pitch spread over the row's gaps, so rounding down by the minimum pitch gives c back.
    private func leadingAligned(_ attributes: NSCollectionViewLayoutAttributes) -> NSCollectionViewLayoutAttributes {
        guard attributes.representedElementCategory == .item,
              let aligned = attributes.copy() as? NSCollectionViewLayoutAttributes else { return attributes }
        let pitch = itemSize.width + minimumInteritemSpacing
        let column = max(0, ((attributes.frame.minX - sectionInset.left) / pitch).rounded(.down))
        aligned.frame.origin.x = sectionInset.left + column * pitch
        return aligned
    }
}
