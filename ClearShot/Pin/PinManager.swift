import AppKit
import CSCapture
import CSCore
import CSHistory
import UniformTypeIdentifiers

/// Pinned screenshots: one floating panel per history item, showing its working copy. A pin holds its item in history
/// until it closes, refreshes when the item changes and closes when it leaves history. Pins can be locked, and all of
/// them hidden, shown and closed together. Captures keep pins, without their hover controls, and a display change moves
/// pins left off every screen back onto the main one.
final class PinManager: PinViewDelegate {
    private let preferences: Preferences
    private let history: HistoryStore
    private let actions: HistoryItemActions
    /// Turns an image file into a history item to pin (Choose and Pin an Image, `pin(fileAt:)`).
    private let importer: ImageImporter
    // Internal rather than private so PinManager+Menu.swift can use it.
    let hud: HUDController
    /// Choose and Pin an Image and a pin's Save As… open a panel, refused while a capture or recording is under way.
    private let gate: ModalGate
    /// Every pin, oldest first, including those still decoding their picture. One per item.
    private var controllers: [PinController] = []
    /// Toggle Pins Visibility ordered every pin out. Hidden pins stay held.
    private var isHidden = false
    /// The global and local `.mouseMoved`/`.leftMouseDragged` monitors, installed while at least one pin is locked.
    private var pointerMonitors: [Any] = []
    /// Opens a capture in Annotate (⌘E).
    var onAnnotate: ((HistoryItem) -> Void)?

    init(preferences: Preferences, history: HistoryStore, actions: HistoryItemActions, importer: ImageImporter,
         hud: HUDController, gate: ModalGate) {
        self.preferences = preferences
        self.history = history
        self.actions = actions
        self.importer = importer
        self.hud = hud
        self.gate = gate
        // The store keeps the handler for good, so it captures the manager weakly.
        history.observe { [weak self] change in self?.historyChanged(change) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    func isPinned(_ itemID: UUID) -> Bool {
        controllers.contains { $0.itemID == itemID }
    }

    // MARK: Pinning

    /// Pins a screenshot, or brings its pin forward if it has one; hidden pins are shown first. The item is held at
    /// once, before the picture decodes, so a caller that lets go of it straight after (a thumbnail closing under
    /// retention "Never") can't purge it. Returns false, after saying why, for a video or GIF.
    @discardableResult
    func pin(_ item: HistoryItem, anchor: PinAnchor) -> Bool {
        guard item.kind == .screenshot else {
            hud.show("Only screenshots can be pinned", symbol: "pin.slash")
            return false
        }
        setHidden(false)
        if let existing = controllers.first(where: { $0.itemID == item.id }) {
            if existing.isPresented { existing.panel.orderFrontRegardless() }
            return true
        }
        history.holds.hold(item.id)
        let controller = PinController(item: item, anchor: anchor, style: PinStyle.defaults(in: preferences))
        controller.view.delegate = self
        controller.panel.onCommand = { [weak self, weak controller] command in
            guard let self, let controller else { return }
            perform(command, on: controller)
        }
        controller.onUnlock = { [weak self, weak controller] in
            guard let self, let controller else { return }
            unlock(controller)
        }
        controllers.append(controller)
        decode(for: controller)
        return true
    }

    /// Choose and Pin an Image (the status menu's "Pin to the Screen…" and its hotkey): one image file, pinned in the
    /// middle of the pointer's screen.
    func chooseAndPin() {
        guard gate.allowsQuestion() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to pin to the screen"
        panel.prompt = "Pin"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await pin(fileAt: url) }
    }

    /// Pins an image file (Choose and Pin an Image, and the Share extension): it becomes an unsaved history item that
    /// records the file as its original, and no thumbnail is shown. The pin holds the item before the importer lets go
    /// of it. A file that can't be read or written is reported by the importer.
    func pin(fileAt url: URL) async {
        await importer.importFile(url) { item in pin(item, anchor: .activeScreen) }
    }

    /// `pin(fileAt:)` for a picture already read from `url` (`pin?filepath=`, which the router reads itself).
    func pin(_ picked: ImageInput.Picked, from url: URL) async {
        await importer.importImage(picked, from: url) { item in pin(item, anchor: .activeScreen) }
    }

    /// Pin Last Screenshot: the newest image in history; videos and GIFs are skipped.
    func pinLastScreenshot() {
        guard let item = history.newestScreenshot else {
            hud.show("There's no screenshot to pin", symbol: "pin")
            return
        }
        pin(item, anchor: .activeScreen)
    }

    /// Closes the item's pin, if it has one: forgotten first, then ordered out with its badge, then its hold released.
    /// A release can purge the item at once (retention "Never"), and the `.removed` that follows then finds no pin.
    func close(itemID: UUID) {
        guard let index = controllers.firstIndex(where: { $0.itemID == itemID }) else { return }
        let controller = controllers.remove(at: index)
        controller.close()
        if controllers.isEmpty { isHidden = false }
        updatePointerMonitors()
        history.holds.release(itemID)
    }

    // MARK: Visibility

    /// Pins are hidden and there is at least one.
    var hasHiddenPins: Bool { isHidden && !controllers.isEmpty }

    /// Hides every pin, or shows them again (Toggle Pins Visibility, "Show Hidden Pins").
    func toggleVisibility() {
        guard !controllers.isEmpty else {
            hud.show("There are no pins to show", symbol: "pin")
            return
        }
        setHidden(!isHidden)
    }

    /// Hiding orders every pin and badge out, never just alpha 0: a window at alpha 0 still takes clicks. Showing brings
    /// them back without taking key and redoes their shadows; a locked pin under the pointer shows its badge at once.
    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        for controller in controllers {
            if hidden { controller.hide() } else { controller.show() }
        }
        if !hidden { trackLockedPointer() }
    }

    /// Closes every pin, without asking.
    func closeAll() {
        controllers.map(\.itemID).forEach(close(itemID:))
    }

    // MARK: Captures

    /// The window numbers (CG window IDs) of the pins, which captures keep. Hidden pins are included: a hidden pin's
    /// window is off screen, so keeping it changes nothing. A window number that isn't positive has no window behind
    /// it, and a pin still decoding has no window yet.
    var windowNumbers: Set<UInt32> {
        Set(controllers.lazy.filter(\.isPresented).map(\.panel.windowNumber).filter { $0 > 0 }.map { UInt32($0) })
    }

    /// Hides every pin's hover controls and readout and puts that on screen now, so the capture that follows never shows
    /// them. They come back with the next mouse movement over the pin.
    func prepareForCapture() {
        for controller in controllers {
            controller.view.resetHover()
            controller.panel.displayIfNeeded()
        }
        CATransaction.flush()
    }

    // MARK: Display changes

    /// A pin no screen shows enough of any more (its display was unplugged) moves to the middle of the main screen
    /// (`PinPlacement.rescued`); hidden pins too, so they come back on screen.
    private func screensChanged() {
        let screens = NSScreen.screens.map { PinScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        // The first screen is the one with the menu bar.
        guard let main = screens.first else { return }
        for controller in controllers where controller.isPresented {
            // A locked pin's badge, a child window, moves with it.
            if let frame = PinPlacement.rescued(controller.panel.frame, screens: screens, main: main) {
                controller.panel.setFrame(frame, display: true)
            }
        }
    }

    // MARK: Lock

    /// Locks a pin: clicks, scrolls and drags pass through it, and its badge unlocks it. `hidingOnHover` also fades it out
    /// while the pointer is over it.
    func lock(_ controller: PinController, hidingOnHover: Bool) {
        guard controller.isPresented, controllers.contains(where: { $0 === controller }) else { return }
        controller.isLocked = true
        controller.hidesOnHover = hidingOnHover
        updatePointerMonitors()
        // Locked from its menu, the pointer is usually over the pin already: the badge shows now, not at the next move.
        controller.trackPointer(at: NSEvent.mouseLocation)
    }

    /// Unlocks a pin (a click on its badge).
    func unlock(_ controller: PinController) {
        controller.isLocked = false
        updatePointerMonitors()
    }

    /// A locked pin takes no mouse events, so the pointer is followed with monitors while any pin is locked: a global
    /// one for other apps' windows, and a local one for ClearShot's own windows that report mouse movement.
    private func updatePointerMonitors() {
        let needed = controllers.contains(where: \.isLocked)
        if needed, pointerMonitors.isEmpty {
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
                self?.trackLockedPointer()
            }) {
                pointerMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
                self?.trackLockedPointer()
                return event
            }) {
                pointerMonitors.append(local)
            }
        } else if !needed, !pointerMonitors.isEmpty {
            pointerMonitors.forEach(NSEvent.removeMonitor)
            pointerMonitors = []
        }
    }

    private func trackLockedPointer() {
        let location = NSEvent.mouseLocation
        for controller in controllers where controller.isLocked {
            controller.trackPointer(at: location)
        }
    }

    // MARK: Pictures

    /// Decodes the controller's item's working copy off the main actor, then shows the pin or its new picture.
    private func decode(for controller: PinController) {
        let generation = controller.decodes.next()
        let url = controller.item.mediaURL(in: history.root)
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { ImageOps.loadDecoded(url) }.value
            self?.finishDecoding(image, generation: generation, for: controller)
        }
    }

    /// A pin closed while decoding (its hold already released) drops the picture, as does a decode a newer one replaced.
    private func finishDecoding(_ image: CGImage?, generation: Int, for controller: PinController) {
        guard controllers.contains(where: { $0 === controller }), controller.decodes.isCurrent(generation) else { return }
        guard let image else {
            Log.history.error("Couldn't read the picture of \(controller.item.displayName) for its pin")
            guard !controller.isPresented else { return }
            // A pin that never showed: forgotten before its hold goes, as `close` does.
            controllers.removeAll { $0 === controller }
            history.holds.release(controller.itemID)
            hud.show("Couldn't pin the screenshot", symbol: "exclamationmark.triangle.fill")
            return
        }
        if controller.isPresented {
            controller.replacePicture(image)
        } else {
            // Pins hidden while this one decoded come back with it, as for a pin made while they are hidden.
            setHidden(false)
            let cascade = controllers.filter(\.isPresented).count
            controller.present(image) { imagePoints in
                Self.start(imagePoints: imagePoints, anchor: controller.anchor, cascade: cascade)
            }
        }
    }

    /// Where a new pin goes on the screens as they are now (`PinPlacement.start`).
    private static func start(imagePoints: CGSize, anchor: PinAnchor, cascade: Int) -> PinStart {
        let screens = NSScreen.screens.map { PinScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let active = NSScreen.activeScreen.map { PinScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
            ?? screens.first ?? PinScreen(frame: .zero, visibleFrame: .zero)
        return PinPlacement.start(imagePoints: imagePoints, anchor: anchor, screens: screens, active: active, cascade: cascade)
    }

    /// Keeps pins in step with the store. Events for one item can arrive out of order (an observer's change reaches later
    /// observers first), so the item is looked up rather than taken from the event.
    private func historyChanged(_ change: HistoryChange) {
        switch change {
        case .added:
            break
        case .updated(let id):
            guard let controller = controllers.first(where: { $0.itemID == id }), let item = history.item(id: id) else { return }
            let pictureChanged = item.modifiedAt != controller.item.modifiedAt || item.pixelSize != controller.item.pixelSize
                || item.isTransparent != controller.item.isTransparent
            controller.item = item
            if pictureChanged { decode(for: controller) }
        case .removed(let id):
            close(itemID: id)
        }
    }

    // MARK: Commands

    /// A key, a hover button, a gesture or a menu item.
    func perform(_ command: PinCommand, on controller: PinController) {
        switch command {
        case .close:
            close(itemID: controller.itemID)
        case .copy:
            if let item = history.item(id: controller.itemID) { actions.copy(item) }
        case .annotate:
            if let item = history.item(id: controller.itemID) { onAnnotate?(item) }
        case .saveAs:
            guard let item = history.item(id: controller.itemID), gate.allowsQuestion() else { return }
            Task { _ = await actions.saveAs(item) }
        case .zoomIn:
            if let next = PinGeometry.nextZoom(after: controller.zoom, imagePoints: controller.imagePoints) {
                controller.zoom(to: next)
            }
        case .zoomOut:
            if let previous = PinGeometry.previousZoom(before: controller.zoom) { controller.zoom(to: previous) }
        case .actualSize:
            controller.zoom(to: 1)
        case .pinch(let magnification, let ended):
            controller.pinch(by: magnification, ended: ended)
        case .scroll(let up, let precise):
            controller.setOpacity(PinGeometry.opacity(controller.opacity, scrolledUp: up, precise: precise))
        case .nudge(let direction, let large):
            controller.nudge(direction, large: large)
        }
    }

    /// Extract Text from the pin's menu, on the capture as history has it now. Extract Text holds the item, so closing the
    /// pin while it runs doesn't lose the text (retention "Never").
    func extractText(from controller: PinController) {
        guard let item = history.item(id: controller.itemID) else { return }
        Task { await actions.extractText(item) }
    }

    // MARK: PinViewDelegate

    private func controller(for view: PinView) -> PinController? {
        controllers.first { $0.view === view }
    }

    func pinView(_ view: PinView, perform command: PinCommand) {
        guard let controller = controller(for: view) else { return }
        perform(command, on: controller)
    }

    func pinViewDragFiles(_ view: PinView) -> QuickAccessDragFiles? {
        guard let controller = controller(for: view), let item = history.item(id: controller.itemID) else { return nil }
        return actions.dragFiles(for: item)
    }

    /// A drop that took the file closes the pin, unless ⌥ was held when the drag started or ended.
    func pinView(_ view: PinView, dragEndedWith operation: NSDragOperation, optionHeld: Bool) {
        guard !operation.isEmpty, !optionHeld, let controller = controller(for: view) else { return }
        close(itemID: controller.itemID)
    }

    func pinViewMenu(_ view: PinView) -> NSMenu? {
        controller(for: view).map(menu(for:))
    }
}
