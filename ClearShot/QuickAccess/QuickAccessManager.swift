import AppKit
import CSCapture
import CSCore
import CSHistory

/// The stack of Quick Access thumbnails: where they go, their auto-close timers, gestures, hover buttons and keys, and
/// the overlay hotkeys.
final class QuickAccessManager: QuickAccessViewDelegate {
    // Internal rather than private so QuickAccessManager+Menu.swift can use them.
    let preferences: Preferences
    let history: HistoryStore
    let actions: HistoryItemActions
    let hud: HUDController
    /// The one modal policy: a thumbnail's question or panel isn't shown while a capture or recording is under way.
    let gate: ModalGate
    /// Newest first.
    private var controllers: [QuickAccessItemController] = []
    private(set) var isHidden = false
    /// The display the stack is on.
    private var displayID: CGDirectDisplayID?
    /// The settings the last layout used, so a tick can notice a change made in Settings.
    private var lastAppearance: (size: QuickAccessSize, position: QuickAccessPosition, saveAsks: Bool)?
    private var ticker: Task<Void, Never>?
    /// Captures open in Annotate or Video Editor windows, or being loaded into one. They need no thumbnail;
    /// `hold(itemID:)` holds them in history.
    private var editingIDs: Set<UUID> = []
    /// The items whose thumbnails closed, oldest first, for Restore Last Capture: one closed again moves to the end.
    /// Kept in memory only, and to the last `closedOrderLimit`.
    private var closedOrder: [UUID] = []
    private static let closedOrderLimit = 100
    /// Opens a capture in Annotate (⌘E, double-click, the Annotate button).
    var onAnnotate: ((HistoryItem) -> Void)?
    /// Opens a video or GIF in the Video Editor (⌘E, double-click, the pencil, "Open Video Editor…"), with its trimming
    /// handles up for Trim the GIF….
    var onEditVideo: ((_ item: HistoryItem, _ startsTrimming: Bool) -> Void)?
    /// Pins a capture (the Pin button and menu item); true when it is pinned. The pin holds the capture before this
    /// returns, so the thumbnail closing next can't purge it.
    var onPin: ((HistoryItem) -> Bool)?

    init(preferences: Preferences, history: HistoryStore, actions: HistoryItemActions, hud: HUDController,
         gate: ModalGate) {
        self.preferences = preferences
        self.history = history
        self.actions = actions
        self.hud = hud
        self.gate = gate
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animated: false) }
        }
    }

    /// Items whose thumbnails are open.
    var shownIDs: Set<UUID> { Set(controllers.map(\.id)) }

    /// The capture is open in an Annotate or Video Editor window, or is being loaded into one.
    func isEditing(_ itemID: UUID) -> Bool {
        editingIDs.contains(itemID)
    }

    /// The capture's thumbnail has a save or an image change running.
    func isBusy(_ itemID: UUID) -> Bool {
        controllers.first { $0.id == itemID }?.isBusy ?? false
    }

    /// Thumbnails are open but hidden ("Temporarily Hide", a swipe down, or the hotkey).
    var hasHiddenOverlays: Bool { isHidden && !controllers.isEmpty }

    /// Where the thumbnails on screen are, for a panel that stacks above them (a GIF's progress).
    var shownThumbnailFrames: [CGRect] {
        controllers.compactMap { $0.panel.isVisible ? $0.panel.frame : nil }
    }

    // MARK: Showing

    /// Shows a thumbnail for `item`, newest at the bottom. `naming` opens it with the name field. With `autoCloses`
    /// false, which a failed save uses, the thumbnail has no auto-close timer and stays until it is closed or a later
    /// save succeeds (see `retrySave`).
    ///
    /// A new thumbnail holds its item in history until it closes. With `takingOverHold`, the caller has already held
    /// the item (before adding it to the store) and hands that hold over: a new thumbnail keeps it as its own; a
    /// thumbnail already open holds the item already, so the handed hold is released.
    func show(_ item: HistoryItem, naming: Bool = false, closesAfterNaming: Bool = false, autoCloses: Bool = true,
              takingOverHold: Bool = false) {
        setHidden(false)
        if let existing = controllers.first(where: { $0.id == item.id }) {
            existing.panel.orderFrontRegardless()
            if takingOverHold { history.holds.release(item.id) }
            return
        }
        if !takingOverHold { history.holds.hold(item.id) }
        let controller = QuickAccessItemController(item: item, historyRoot: history.root,
                                                   thumbnail: ImageOps.load(item.thumbnailURL(in: history.root)),
                                                   naming: naming, closesAfterNaming: closesAfterNaming)
        controller.view.delegate = self
        controller.view.saveAsksByDefault = preferences[Prefs.quickAccessSaveAsksForLocation]
        controller.panel.onCommand = { [weak self, weak controller] command, optionHeld in
            guard let self, let controller else { return }
            perform(command, on: controller, optionHeld: optionHeld)
        }
        if controllers.isEmpty { displayID = nil }
        controllers.insert(controller, at: 0)
        if autoCloses { restartClock(controller) }
        layout(animated: true, presenting: controller)
        if naming { controller.view.beginEditingName() }
        startTicking()
    }

    /// Saves a capture again after its first save failed. With a thumbnail open, the save goes through it, so a Save
    /// pressed there can't race this one, and the thumbnail starts its auto-close timer once saved.
    func retrySave(_ item: HistoryItem) async {
        if let controller = controllers.first(where: { $0.id == item.id }) {
            guard !controller.isBusy else { return }
            if await save(controller) { restartClock(controller) }
        } else {
            _ = await actions.save(item)
        }
    }

    /// Brings back the most recently closed thumbnail still in history, else the newest capture that isn't on screen
    /// ("Restore Last Capture", `QuickAccessRules.itemToRestore`).
    func restoreLastCapture() {
        guard let id = QuickAccessRules.itemToRestore(closedOldestFirst: closedOrder,
                                                      historyNewestFirst: history.items.map(\.id), shown: shownIDs),
              let item = history.item(id: id) else {
            hud.show("Can't restore any files", symbol: "clock.arrow.circlepath")
            return
        }
        show(item)
    }

    /// Holds a capture in history while an Annotate or Video Editor window has it open (or is loading it), and holds its
    /// thumbnail's countdown if it has one open.
    func hold(itemID: UUID) {
        editingIDs.insert(itemID)
        history.holds.hold(itemID)
        if let controller = controllers.first(where: { $0.id == itemID }) { hold(controller) }
    }

    /// Ends `hold(itemID:)`. The history hold goes last: releasing it can purge the item at once (retention "Never").
    func release(itemID: UUID) {
        editingIDs.remove(itemID)
        if let controller = controllers.first(where: { $0.id == itemID }) { release(controller) }
        history.holds.release(itemID)
    }

    /// Shows a capture that changed in the store on its open thumbnail. The picture is reloaded only when the image
    /// changed (its `modifiedAt` or size); a save or rename just updates the item.
    func refresh(_ item: HistoryItem) {
        guard let controller = controllers.first(where: { $0.id == item.id }) else { return }
        let imageChanged = item.modifiedAt != controller.item.modifiedAt || item.pixelSize != controller.item.pixelSize
        guard imageChanged else {
            controller.update(item)
            return
        }
        controller.update(item, thumbnail: ImageOps.load(item.thumbnailURL(in: history.root)))
        layout(animated: true)
    }

    /// Closes the item's thumbnail, if it has one open: for an item leaving history.
    func closeThumbnail(for itemID: UUID) {
        guard let controller = controllers.first(where: { $0.id == itemID }) else { return }
        close(controller)
    }

    // MARK: Hotkeys

    func toggleVisibility() {
        guard !controllers.isEmpty else {
            hud.show("There are no overlays to show", symbol: "square.stack")
            return
        }
        setHidden(!isHidden)
    }

    /// Closes every thumbnail, asking first when there are several. One that would ask is refused while a capture or
    /// recording is under way (`ModalGate`).
    func closeAll(confirm: Bool = true) {
        guard !controllers.isEmpty else { return }
        // A thumbnail with a save running stays; closing it would pull the working copy out from under the save. One
        // asking for a name stays too: it ends only through its Save, Discard or Close.
        let closing = controllers.filter { !$0.isBusy && !$0.isNaming }
        if confirm, closing.count > 1, preferences[Prefs.confirmCloseAllOverlays] {
            guard gate.allowsQuestion() else { return }
            // No countdown runs out behind the alert; on Cancel they all carry on.
            let held = controllers
            held.forEach(hold)
            let confirmed = confirmCloseAll()
            held.forEach(release)
            guard confirmed else { return }
        }
        closing.forEach(close)
    }

    /// Saves every unsaved thumbnail, then closes all the saved ones. Thumbnails waiting for a name stay.
    func saveAll() async {
        guard !controllers.isEmpty else {
            hud.show("There are no overlays to save", symbol: "square.stack")
            return
        }
        for controller in controllers where !controller.isSaved && !controller.isNaming && !controller.isBusy {
            _ = await save(controller)
        }
        controllers.filter(\.isSaved).forEach(close)
    }

    // MARK: Commands

    func perform(_ command: QuickAccessCommand, on controller: QuickAccessItemController, optionHeld: Bool) {
        guard !controller.isBusy else { return }
        let item = controller.item
        switch command {
        case .copy:
            // A thumbnail asking for a name stays open: it ends only through its Save, Discard or Close.
            if actions.copy(item), !controller.isNaming, QuickAccessRules.closesAfterCopy(optionHeld: optionHeld) {
                close(controller)
            }
        case .save:
            let asks = QuickAccessRules.saveAsksForLocation(optionHeld: optionHeld,
                                                            askByDefault: preferences[Prefs.quickAccessSaveAsksForLocation])
            saveAndClose(controller, askingWhere: controller.isSaved || asks)
        case .showInFinder:
            actions.showInFinder(item)
        case .close:
            guard confirmsClosing(controller) else { return }
            close(controller)
        case .trash:
            guard !refuseWhileAnnotating(controller) else { return }
            if actions.trash(item) { close(controller) }
        case .annotate:
            // ⌘E, a double-click and the pencil: a video or GIF opens in the Video Editor.
            if item.kind == .screenshot {
                onAnnotate?(item)
            } else {
                onEditVideo?(item, false)
            }
        case .trim:
            // The scissors and Trim the GIF…: the Video Editor with its trimming handles up (a GIF in Trim the GIF…).
            guard item.kind != .screenshot else { return }
            onEditVideo?(item, true)
        case .pin:
            // A thumbnail asking for a name stays open: it ends only through its Save, Discard or Close.
            if onPin?(item) == true, !controller.isNaming { close(controller) }
        case .quickLook:
            // The countdown waits while Quick Look is up and carries on when it lets go of this thumbnail. Set before
            // showing: closing Quick Look ends the session straight away.
            controller.panel.onPreviewEnded = { [weak self, weak controller] in
                guard let self, let controller else { return }
                controller.isPreviewing = false
                updateClock(controller)
            }
            if controller.showQuickLook(actions.file(for: item)) {
                controller.isPreviewing = true
                updateClock(controller)
            }
        case .submitName(let name):
            controller.isBusy = true
            Task { await submitName(name, for: controller) }
        case .discard:
            guard !refuseWhileAnnotating(controller) else { return }
            actions.clearClipboardCopy(of: item.id)
            history.remove(item.id)
            close(controller)
        case .swipeAway:
            // It leaves the stack first, so the others close ranks while it slides out and nothing moves it back. One
            // asking for a name ignores the swipe.
            guard !controller.isNaming, confirmsClosing(controller), detach(controller) else { return }
            controller.isBusy = true
            Task {
                await controller.slideAway(toward: preferences[Prefs.quickAccessPosition])
                controller.isBusy = false
                finishClosing(controller)
            }
        case .hideAll:
            setHidden(true)
        }
    }

    /// Saves into the export folder, or asks where first, then closes the thumbnail once it is saved. The Save panel is
    /// refused while a capture or recording is under way (`ModalGate`).
    func saveAndClose(_ controller: QuickAccessItemController, askingWhere: Bool) {
        guard !controller.isBusy, !askingWhere || gate.allowsQuestion() else { return }
        controller.isBusy = true
        Task {
            let saved = askingWhere ? await saveAs(controller) : await save(controller)
            if saved { close(controller) }
        }
    }

    /// Saves into the export folder; returns whether it worked. The countdown waits meanwhile, since a failure shows an
    /// alert. A thumbnail whose save failed loses its countdown and stays until it is closed, as the router's does.
    func save(_ controller: QuickAccessItemController, name: String? = nil) async -> Bool {
        controller.isBusy = true
        hold(controller)
        defer {
            controller.isBusy = false
            release(controller)
        }
        guard let updated = await actions.save(controller.item, name: name) else {
            controller.clock = nil
            return false
        }
        controller.update(updated)
        return true
    }

    /// Asks where to save, then saves there. The countdown waits while the Save panel is open.
    func saveAs(_ controller: QuickAccessItemController) async -> Bool {
        controller.isBusy = true
        hold(controller)
        defer {
            controller.isBusy = false
            release(controller)
        }
        guard let updated = await actions.saveAs(controller.item) else { return false }
        controller.update(updated)
        return true
    }

    private func submitName(_ name: String, for controller: QuickAccessItemController) async {
        guard await save(controller, name: name) else { return }
        controller.finishNaming(with: controller.item)
        if controller.closesAfterNaming {
            close(controller)
        } else {
            restartClock(controller)
            layout(animated: true)
        }
    }

    func close(_ controller: QuickAccessItemController) {
        guard detach(controller) else { return }
        finishClosing(controller)
    }

    /// Takes the thumbnail out of the stack and re-lays out the rest. Returns false if it wasn't in the stack.
    private func detach(_ controller: QuickAccessItemController) -> Bool {
        guard let index = controllers.firstIndex(where: { $0 === controller }) else { return false }
        controllers.remove(at: index)
        if controllers.isEmpty {
            stopTicking()
            isHidden = false
        } else {
            layout(animated: true)
        }
        return true
    }

    /// Closes a detached thumbnail's panel, remembers it for Restore Last Capture, then releases its item. The release
    /// comes last, once the thumbnail is out of `controllers`: under retention "Never" it purges the item at once
    /// (unless an editor or a running save still holds it), and the `.removed` that follows finds no thumbnail.
    private func finishClosing(_ controller: QuickAccessItemController) {
        controller.close()
        recordClosed(controller.id)
        history.holds.release(controller.id)
    }

    private func recordClosed(_ itemID: UUID) {
        closedOrder.removeAll { $0 == itemID }
        closedOrder.append(itemID)
        if closedOrder.count > Self.closedOrderLimit {
            closedOrder.removeFirst(closedOrder.count - Self.closedOrderLimit)
        }
    }

    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        for controller in controllers {
            if hidden {
                // Ordered out from under the pointer, a panel gets no mouseExited.
                controller.isHovering = false
                controller.view.resetHover()
            }
            updateClock(controller)
        }
        if hidden {
            controllers.forEach { $0.hide() }
        } else {
            layout(animated: false)
        }
    }

    /// "Close this recording?" before an unsaved video or GIF is closed by hand: Close, ⌘W or a swipe
    /// (`QuickAccessRules.asksBeforeClosing`). Auto-close and Close All never come here. While a capture or recording
    /// is under way it isn't asked (`ModalGate`): the thumbnail just closes, since Restore Last Capture brings it back,
    /// except under retention "Never", which would delete it, so the close is refused. True when the thumbnail may
    /// close.
    private func confirmsClosing(_ controller: QuickAccessItemController) -> Bool {
        let item = controller.item
        guard QuickAccessRules.asksBeforeClosing(isVideoOrGIF: item.kind == .video || item.kind == .gif,
                                                 isSaved: controller.isSaved, isOpenedFile: item.origin == .file,
                                                 isChangedSinceOpening: !item.isUnchangedSinceCreation,
                                                 askSetting: preferences[Prefs.confirmCloseRecording]) else { return true }
        switch gate.decide(ModalPolicy.closingRecording(retention: preferences[Prefs.historyRetention])) {
        case .ask: break
        case .skip: return true
        case .refuse, .wait: return false
        }
        // No countdown runs out behind the alert.
        hold(controller)
        defer { release(controller) }
        let alert = NSAlert()
        alert.messageText = "Close this recording?"
        // With retention "Never", closing deletes the unsaved recording, so there is nothing to restore (as Close All
        // says).
        alert.informativeText = preferences[Prefs.historyRetention] == .never
            ? "It hasn't been saved and will be deleted."
            : "It hasn't been saved. You can bring it back with Restore Last Capture."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate()
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on {
            preferences[Prefs.confirmCloseRecording] = false
        }
        return confirmed
    }

    private func confirmCloseAll() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close all overlays?"
        // With retention "Never", closing a thumbnail deletes its unsaved capture, so there is nothing to restore.
        alert.informativeText = preferences[Prefs.historyRetention] == .never
            ? "Captures that aren't saved will be deleted."
            : "Captures that aren't saved can be brought back with Restore Last Capture."
        alert.addButton(withTitle: "Close All")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate()
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on {
            preferences[Prefs.confirmCloseAllOverlays] = false
        }
        return confirmed
    }

    // MARK: Layout

    /// Places every thumbnail; `new` slides in, the rest move.
    func layout(animated: Bool, presenting new: QuickAccessItemController? = nil) {
        guard !controllers.isEmpty, let screen = targetScreen() else { return }
        displayID = screen.displayID
        let size = preferences[Prefs.quickAccessSize]
        let position = preferences[Prefs.quickAccessPosition]
        let saveAsks = preferences[Prefs.quickAccessSaveAsksForLocation]
        lastAppearance = (size, position, saveAsks)
        let frames = QuickAccessLayout.frames(for: controllers.map { $0.contentSize(for: size) }, in: screen.visibleFrame,
                                              position: position)
        for (index, controller) in controllers.enumerated() {
            controller.setNewest(index == 0 && controllers.count > 1)
            controller.view.saveAsksByDefault = saveAsks
            guard !isHidden, let frame = frames[index] else {
                controller.hide()
                // Ordered out from under the pointer (no room for it, or the stack is hidden), it gets no mouseExited.
                controller.view.resetHover()
                controller.isHovering = false
                updateClock(controller)
                continue
            }
            if controller === new {
                controller.present(at: frame, from: position)
            } else {
                controller.move(to: frame, animated: animated)
            }
        }
    }

    /// The stack follows the pointer's display when "Move to the active screen" is on, or when it is starting out.
    /// Otherwise it stays on its display while that display is connected.
    private func targetScreen() -> NSScreen? {
        if !preferences[Prefs.quickAccessMoveToActiveScreen], let displayID,
           let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            return screen
        }
        return NSScreen.activeScreen
    }

    // MARK: Timers

    private func restartClock(_ controller: QuickAccessItemController) {
        guard preferences[Prefs.quickAccessAutoClose] else {
            controller.clock = nil
            return
        }
        controller.clock = AutoCloseClock(interval: TimeInterval(preferences[Prefs.quickAccessAutoCloseSeconds]), now: Date())
        updateClock(controller)
    }

    /// Runs or pauses the thumbnail's countdown to match its state. Every change to that state comes through here.
    func updateClock(_ controller: QuickAccessItemController) {
        let now = Date()
        if QuickAccessRules.clockRuns(hovering: controller.isHovering, hidden: isHidden, previewing: controller.isPreviewing,
                                      holds: controller.holds) {
            controller.clock?.resume(now: now)
        } else {
            controller.clock?.pause(now: now)
        }
    }

    /// Pauses the countdown until a matching `release`: for modal UI (a Save panel, the print dialog, an alert) and the
    /// Resize dialog.
    func hold(_ controller: QuickAccessItemController) {
        controller.holds += 1
        updateClock(controller)
    }

    func release(_ controller: QuickAccessItemController) {
        controller.holds = max(0, controller.holds - 1)
        updateClock(controller)
    }

    /// Twice a second while thumbnails exist: runs out auto-close timers, follows the active screen, and picks up
    /// size and position changes from Settings.
    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        let now = Date()
        if preferences[Prefs.quickAccessAutoClose] {
            for controller in controllers where !controller.isBusy && controller.clock?.isExpired(now: now) == true {
                controller.clock = nil
                autoClose(controller)
            }
        }
        guard !isHidden, !controllers.isEmpty else { return }
        let size = preferences[Prefs.quickAccessSize]
        let position = preferences[Prefs.quickAccessPosition]
        let saveAsks = preferences[Prefs.quickAccessSaveAsksForLocation]
        let appearanceChanged = lastAppearance.map { $0.size != size || $0.position != position || $0.saveAsks != saveAsks }
            ?? false
        let screenChanged = preferences[Prefs.quickAccessMoveToActiveScreen] && NSScreen.activeScreen?.displayID != displayID
        if appearanceChanged || screenChanged { layout(animated: true) }
    }

    private func autoClose(_ controller: QuickAccessItemController) {
        // An image or video opened from a file is already on disk while it is unchanged, so "Save and close" just closes
        // it instead of saving a duplicate; once edited (a rotate, Replace, Mute) the edit is only in history, so it is
        // saved. Clipboard images have no file and are saved.
        let item = controller.item
        let isOnDisk = QuickAccessRules.isOnDisk(isSaved: controller.isSaved, isOpenedFile: item.origin == .file,
                                                 isChangedSinceOpening: !item.isUnchangedSinceCreation)
        switch QuickAccessRules.autoCloseOutcome(action: preferences[Prefs.quickAccessAutoCloseAction],
                                                 isSaved: isOnDisk, isNaming: controller.isNaming) {
        case .keepOpen:
            break
        case .close:
            close(controller)
        case .saveAndClose:
            controller.isBusy = true
            Task { if await save(controller) { close(controller) } }
        }
    }

    // MARK: QuickAccessViewDelegate

    func controller(for view: QuickAccessView) -> QuickAccessItemController? {
        controllers.first { $0.view === view }
    }

    func quickAccessView(_ view: QuickAccessView, perform command: QuickAccessCommand, optionHeld: Bool) {
        guard let controller = controller(for: view) else { return }
        perform(command, on: controller, optionHeld: optionHeld)
    }

    func quickAccessView(_ view: QuickAccessView, hoverChanged hovering: Bool) {
        guard let controller = controller(for: view) else { return }
        controller.isHovering = hovering
        updateClock(controller)
    }

    func quickAccessViewDragFiles(_ view: QuickAccessView) -> QuickAccessDragFiles? {
        controller(for: view).map { actions.dragFiles(for: $0.item) }
    }

    func quickAccessView(_ view: QuickAccessView, dragEndedWith operation: NSDragOperation, optionHeld: Bool) {
        // A thumbnail with a save or image change running, or one asking for a name, stays open.
        guard !operation.isEmpty, let controller = controller(for: view), !controller.isBusy, !controller.isNaming,
              QuickAccessRules.closesAfterDrag(closeAfterDragging: preferences[Prefs.quickAccessCloseAfterDragging],
                                               optionHeld: optionHeld) else { return }
        close(controller)
    }

    func quickAccessViewMenu(_ view: QuickAccessView) -> NSMenu? {
        controller(for: view).map(menu(for:))
    }
}
