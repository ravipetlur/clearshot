import AppKit
import CSCapture
import CSCore
import CSHistory

/// What the History grid's keys, mouse and menus do with the selected items. Every call takes item IDs, in display
/// order, and resolves them from the store as it acts, skipping any that have left history.
protocol HistoryGridActions: AnyObject {
    /// Shows the items in Quick Access, oldest first, so the newest ends at the bottom of the stack (⏎).
    func restore(_ ids: [UUID])
    /// Opens the screenshots among them in Annotate, and the videos and GIFs in the Video Editor (double-click, ⌘E, the
    /// menu). A GIF opened from a file has no source video and opens nowhere, so it is passed over; a recorded GIF that
    /// lost its source gets the editor's HUD saying so.
    func annotate(_ ids: [UUID])
    /// Pins the screenshots among them.
    func pin(_ ids: [UUID])
    /// Opens Quick Look over them (Space, the menu). Space closes it again; the collection view handles that.
    func quickLook(_ ids: [UUID])
    /// Copies one item as a thumbnail does, several as their files (⌘C, the menu).
    func copy(_ ids: [UUID])
    func showInFinder(_ ids: [UUID])
    /// Removes the items from history after asking; saved files stay (⌫, ⌘⌫, forward delete, Edit › Delete, the menu).
    func delete(_ ids: [UUID])
    /// The context menu for them.
    func menu(for ids: [UUID]) -> NSMenu
}

extension HistoryWindowController: HistoryGridActions {
    func restore(_ ids: [UUID]) {
        // The stack puts each new thumbnail at the bottom. The window stays open and key: thumbnails never take key.
        for item in resolved(ids).sorted(by: { $0.createdAt < $1.createdAt }) {
            quickAccess.show(item)
        }
    }

    func annotate(_ ids: [UUID]) {
        for item in resolved(ids) {
            if item.kind == .screenshot {
                annotate.open(item)
            } else if item.opensInVideoEditor(root: history.root) || item.origin == .capture {
                // A recorded GIF whose source video is missing reaches the editor too, which says so instead of
                // opening ("This GIF's recording is missing…").
                videoEditor.open(item)
            }
        }
    }

    func pin(_ ids: [UUID]) {
        let items = resolved(ids)
        let screenshots = items.filter { $0.kind == .screenshot }
        if screenshots.count < items.count { hud.show("Only screenshots can be pinned", symbol: "pin.slash") }
        // Each new pin cascades from the last on the active screen.
        for item in screenshots { pins.pin(item, anchor: .activeScreen) }
    }

    func quickLook(_ ids: [UUID]) {
        // The grid's collection view is the panel's controller and shows its selection, which `ids` always is: the menu
        // is built for the selection, after a right-click has selected its item.
        guard !ids.isEmpty else { return }
        grid.collectionView.showQuickLook()
    }

    func copy(_ ids: [UUID]) {
        let items = resolved(ids)
        if items.count == 1, let item = items.first {
            itemActions.copy(item)
            return
        }
        guard !items.isEmpty else { return }
        if ClipboardWriter.write(fileURLs: items.map { itemActions.file(for: $0) }) {
            hud.show("Copied \(items.count) files", symbol: "doc.on.clipboard")
        } else {
            Log.capture.error("Couldn't copy \(items.count) captures to the clipboard")
            hud.show("Couldn't copy to the clipboard", symbol: "exclamationmark.triangle.fill")
        }
    }

    func showInFinder(_ ids: [UUID]) {
        let files = resolved(ids).map { itemActions.revealFile(for: $0) }
        guard !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    /// Refused, with a HUD, while any of the items is open in Annotate or its thumbnail is busy. Otherwise asks in a sheet
    /// unless the person turned the question off, then removes them.
    func delete(_ ids: [UUID]) {
        let items = resolved(ids)
        guard !items.isEmpty, let window, window.attachedSheet == nil else { return }
        let deleting = items.map(\.id)
        guard !refusesDelete(deleting) else { return }
        guard preferences[Prefs.confirmHistoryDelete] else {
            remove(deleting)
            return
        }
        let text = HistoryDeleteRule.confirmation(names: items.map(\.displayName))
        let alert = NSAlert()
        alert.messageText = text.message
        alert.informativeText = text.detail
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        // Quick Look's panel floats above the window, so the sheet would open behind it.
        grid.collectionView.endQuickLook()
        NSApp.activate()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on { preferences[Prefs.confirmHistoryDelete] = false }
            // The sheet waited: an item may have been opened in Annotate, or a change started on it, meanwhile.
            guard !refusesDelete(deleting) else { return }
            remove(deleting)
        }
    }

    func menu(for ids: [UUID]) -> NSMenu {
        let items = resolved(ids)
        let hasScreenshot = items.contains { $0.kind == .screenshot }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true,
                 _ handler: @escaping () -> Void) {
            let entry = NSMenuItem.action(title, key: key, handler: handler)
            entry.keyEquivalentModifierMask = modifiers
            entry.isEnabled = enabled
            menu.addItem(entry)
        }

        // Screenshots open in Annotate, videos and GIFs in the Video Editor; the title names what a selection of only
        // videos and GIFs opens. A GIF opened from a file has no source video, so a selection of only those opens
        // nothing and has no such item, as its thumbnail has none.
        let opensSomething = hasScreenshot || items.contains { $0.opensInVideoEditor(root: history.root) }
        if opensSomething || items.isEmpty {
            add(hasScreenshot || items.isEmpty ? "Open Annotation Tool…" : "Open Video Editor…", key: "e",
                enabled: !items.isEmpty) { [weak self] in self?.annotate(ids) }
        }
        add("Pin to the Screen", enabled: hasScreenshot) { [weak self] in self?.pin(ids) }
        add("Quick Look") { [weak self] in self?.quickLook(ids) }
        add("Copy", key: "c") { [weak self] in self?.copy(ids) }
        add("Restore", key: "\r", modifiers: []) { [weak self] in self?.restore(ids) }
        add("Show in Finder") { [weak self] in self?.showInFinder(ids) }
        menu.addItem(.separator())
        add("Delete…", key: "\u{8}", modifiers: []) { [weak self] in self?.delete(ids) }
        return menu
    }

    // MARK: Helpers

    /// The listed items still in history, in the same order.
    private func resolved(_ ids: [UUID]) -> [HistoryItem] {
        ids.compactMap { history.item(id: $0) }
    }

    /// True, after saying why, when any of the items is open in Annotate or its thumbnail has a save or image change
    /// running (`HistoryDeleteRule`). Nothing is deleted then.
    private func refusesDelete(_ ids: [UUID]) -> Bool {
        let editing = Set(ids.filter { quickAccess.isEditing($0) })
        let busy = Set(ids.filter { quickAccess.isBusy($0) })
        switch HistoryDeleteRule.refusal(for: ids, editing: editing, busy: busy) {
        case nil:
            return false
        case .openInAnnotate(let count):
            // The editing hold covers Annotate and the Video Editor alike.
            if editing.compactMap({ history.item(id: $0) }).allSatisfy({ $0.kind != .screenshot }) {
                hud.show(count == 1 ? "Finish editing this video first" : "Finish editing those videos first", symbol: "film")
            } else {
                hud.show(count == 1 ? "Finish annotating this screenshot first" : "Finish annotating those screenshots first",
                         symbol: "pencil.tip.crop.circle")
            }
        case .busy:
            hud.show("Wait for the change to finish", symbol: "hourglass")
        }
        return true
    }

    /// Removes the items from history. Each item's Quick Look, thumbnail and pin close before it goes. Their releases can
    /// purge other unheld items at once (retention "Never"), so each ID is looked up as it comes and one already gone is
    /// skipped. Saved files stay.
    private func remove(_ ids: [UUID]) {
        for id in ids {
            guard history.item(id: id) != nil else { continue }
            grid.collectionView.endQuickLook(showing: id)
            quickAccess.closeThumbnail(for: id)
            pins.close(itemID: id)
            history.remove(id)
        }
    }
}
