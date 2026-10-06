import AppKit
import Quartz

/// The History grid's collection view. Its items are history item IDs (an `NSCollectionViewDiffableDataSource<Int,
/// UUID>`), and the selection is read and set by ID, since index paths shift as captures come and go. It takes the
/// keys, double-click, context menu and Edit menu items that act on the selection and hands them to `actions`, and it
/// is Quick Look's controller while the panel shows the selection.
final class HistoryCollectionView: NSCollectionView, NSMenuItemValidation {
    /// Does what the keys, mouse and menus ask (the window controller).
    weak var actions: HistoryGridActions?
    /// Told after every selection change with what is now selected, so the model keeps it.
    var onSelectionChange: ((Set<UUID>) -> Void)?
    /// The file Quick Look shows for an item (`HistoryItemActions.file(for:)`), or nil once it has left history.
    var previewFile: ((UUID) -> URL?)?

    /// The selected items, in display order.
    var selectedIDs: [UUID] {
        guard let source = diffableSource else { return [] }
        return selectionIndexPaths.sorted().compactMap { source.itemIdentifier(for: $0) }
    }

    // MARK: Selection

    /// Selects exactly the listed items that are shown. This is the one way code changes the selection: setting index
    /// paths tells the delegate nothing, so it reports the change itself, as the delegate's callbacks do for clicks,
    /// ⌘A and arrows.
    func select(_ ids: Set<UUID>) {
        guard let source = diffableSource else { return }
        let paths = Set(ids.compactMap { source.indexPath(for: $0) })
        if paths != selectionIndexPaths { selectionIndexPaths = paths }
        selectionDidChange()
    }

    /// Every selection change ends here, the person's (through the grid's delegate callbacks) and `select(_:)`'s: the
    /// model takes the new selection, and Quick Look, while it shows this grid, shows it instead.
    func selectionDidChange() {
        let ids = selectedIDs
        onSelectionChange?(Set(ids))
        previewSelection(ids)
    }

    /// The item under the event's pointer.
    private func itemID(at event: NSEvent) -> UUID? {
        guard let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return diffableSource?.itemIdentifier(for: indexPath)
    }

    // MARK: Keys and mouse

    /// ⏎ and keypad Enter restore, Space opens Quick Look or closes it when it shows this grid, and ⌫, ⌘⌫ and forward
    /// delete delete. They all arrive here: no menu item claims them. Arrows and the rest are the collection view's.
    override func keyDown(with event: NSEvent) {
        let ids = selectedIDs
        guard let actions, !ids.isEmpty else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        // A held key acts once.
        switch (event.keyCode, modifiers) {
        case (36, []), (76, []):
            if !event.isARepeat { actions.restore(ids) }
        case (49, []):
            guard !event.isARepeat else { return }
            if isPreviewing { endQuickLook() } else { actions.quickLook(ids) }
        case (51, []), (51, .command), (117, []):
            if !event.isARepeat { actions.delete(ids) }
        default:
            super.keyDown(with: event)
        }
    }

    /// ⌘E (exactly ⌘; Caps Lock is ignored) opens the selection in Annotate. No menu item has it, so it is caught here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "e", let actions,
              !selectionIndexPaths.isEmpty else {
            return super.performKeyEquivalent(with: event)
        }
        actions.annotate(selectedIDs)
        return true
    }

    /// The collection view selects first; a double-click then opens the item under the pointer in Annotate.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2, let id = itemID(at: event) else { return }
        actions?.annotate([id])
    }

    /// The selection's menu. A right-click on an item that isn't selected selects it alone first; on empty space there
    /// is no menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let actions, let id = itemID(at: event) else { return nil }
        if !selectedIDs.contains(id) { select([id]) }
        return actions.menu(for: selectedIDs)
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) {
        guard takesEditCommands else { return }
        actions?.copy(selectedIDs)
    }

    @objc func delete(_ sender: Any?) {
        guard takesEditCommands else { return }
        actions?.delete(selectedIDs)
    }

    /// Copy and Delete need a selection. The Edit menu reaches them only while the grid is first responder.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(delete(_:)): takesEditCommands && !selectionIndexPaths.isEmpty
        default: true
        }
    }

    /// The Edit menu acts on this grid only while its window is key, or while Quick Look shows this grid's selection.
    /// With another panel key (a thumbnail's Quick Look, a pin) the menu still reaches the grid through the History
    /// window, which stays main, and ⌘C there would put the History selection on the clipboard.
    private var takesEditCommands: Bool {
        window?.isKeyWindow == true || isPreviewing
    }

    // MARK: Quick Look (the app has one panel)

    /// What Quick Look shows while this grid controls it: the selection, in display order, as it was when the panel
    /// began or the selection last changed, and the files it resolved to.
    private var previewedIDs: [UUID] = []
    private var previewURLs: [URL] = []

    /// Quick Look is open and shows this grid.
    private var isPreviewing: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return false }
        return panel.isVisible && (panel.currentController as AnyObject?) === self
    }

    /// Opens Quick Look over the selection, or brings it forward (Space, "Quick Look"). Space closes it again (`keyDown`).
    func showQuickLook() {
        guard !selectionIndexPaths.isEmpty, let window, let panel = QLPreviewPanel.shared() else { return }
        // The panel takes its controller from the key window's responder chain.
        window.makeFirstResponder(self)
        if !window.isKeyWindow {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        // Open for a thumbnail, it switches to this grid.
        if panel.isVisible, !isPreviewing { panel.updateController() }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closes Quick Look when this grid controls it: as the window closes, and before the delete sheet opens.
    func endQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              (panel.currentController as AnyObject?) === self else { return }
        panel.orderOut(nil)
    }

    /// Closes Quick Look when it shows this item: before the item is deleted.
    func endQuickLook(showing id: UUID) {
        guard previewedIDs.contains(id) else { return }
        endQuickLook()
    }

    private func takePreviewItems(_ ids: [UUID]) {
        previewedIDs = ids
        previewURLs = ids.compactMap { previewFile?($0) }
    }

    /// The selection changed while Quick Look shows this grid: it shows the new selection, or closes with none.
    private func previewSelection(_ ids: [UUID]) {
        guard ids != previewedIDs, isPreviewing else { return }
        guard !ids.isEmpty else {
            endQuickLook()
            return
        }
        takePreviewItems(ids)
        QLPreviewPanel.shared()?.reloadData()
    }

    // The informal protocol's methods are nonisolated in the SDK. AppKit calls them on the main thread.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { !selectionIndexPaths.isEmpty }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
            takePreviewItems(selectedIDs)
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            previewedIDs = []
            previewURLs = []
        }
    }

    // MARK: Focus

    /// The grid takes keyboard focus whenever it appears in the window: as the window opens, or in place of an empty
    /// state (the first capture after "No captures yet"). The window has nothing else that types.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    private var diffableSource: NSCollectionViewDiffableDataSource<Int, UUID>? {
        dataSource as? NSCollectionViewDiffableDataSource<Int, UUID>
    }
}

extension HistoryCollectionView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURLs.indices.contains(index) ? previewURLs[index] as NSURL : nil
    }

    /// The panel is key while it shows, so the keys it leaves alone come here: Space closes it, and arrows move the
    /// selection, which it then shows.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, [49, 123, 124, 125, 126].contains(event.keyCode) else { return false }
        keyDown(with: event)
        return true
    }
}
