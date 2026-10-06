import AppKit
import CSCapture
import CSCore

/// What All-In-One opens with: the area to select at once (nil for none) and the aspect ratio; `saveRatio` keeps a ratio
/// chosen in the toolbar for the next time.
struct AllInOneSetup {
    var remembered: SavedArea?
    var ratio: SelectionRatio
    var saveRatio: (SelectionRatio) -> Void = { _ in }
}

/// A command All-In-One ran, with what it runs on.
struct AllInOnePick {
    enum Target {
        case area(CGRect, DisplayInfo), window(WindowRecord), display(DisplayInfo), none
    }

    let command: AllInOneCommand
    let target: Target
    /// The overlay showed the frozen picture (Freeze screen on).
    let frozen: Bool
    /// Held on the capture key or button.
    let keyModifiers: SelectionModifiers
    /// Held as the selection's drag began.
    let startModifiers: SelectionModifiers
}

/// The All-In-One style: mouse and keys go to `AllInOneController`; this draws its selection with handles, sets the
/// cursor, hovers windows in window mode, shows the toolbar and turns a command into the session's outcome.
extension OverlaySession {
    var isAllInOne: Bool {
        if case .allInOne = style { return true }
        return false
    }

    /// The controller for every display, with each display's snap lines and the ratio, the remembered area selected.
    func makeAllInOneController(_ setup: AllInOneSetup) -> AllInOneController {
        let lines = Dictionary(uniqueKeysWithValues: layout.displays.map { ($0.id, snapLines(on: $0)) })
        var controller = AllInOneController(displays: layout.displays, snapLines: lines, ratio: setup.ratio)
        if let remembered = setup.remembered { controller.restore(remembered) }
        return controller
    }

    func makeAllInOneToolbar() -> AllInOneToolbar {
        AllInOneToolbar { [weak self] action in self?.allInOneToolbarAction(action) }
    }

    // MARK: Mouse

    func allInOneMouseMoved(to point: CGPoint, flags: NSEvent.ModifierFlags) {
        modifiers = SelectionModifiers(flags)
        // While a toolbar field edits, the toolbar keeps the keys; taking them would end the typing.
        if allInOneToolbar?.isEditing != true, let display = layout.display(containingMouse: point),
           let window = overlayWindows[display.id], !window.isKeyWindow {
            window.makeKey()
        }
        if allInOne?.mode == .window {
            hoveredWindow = WindowPicker.window(at: layout.cgPoint(fromAppKit: point), in: windows, excluding: excludedWindowIDs)
        }
        allInOneRefresh(cursor: point)
    }

    func allInOneMouseDown(at point: CGPoint, flags: NSEvent.ModifierFlags) {
        modifiers = SelectionModifiers(flags)
        // A click while a toolbar field edits commits it, and one while the ratio list is open closes it; neither
        // starts a drag.
        if allInOneToolbar?.endInteraction() == true {
            allInOneRefresh(cursor: point)
            return
        }
        switch allInOne?.mode {
        case .window:
            if let hoveredWindow { finish(.window(hoveredWindow, modifiers: modifiers)) }
        case .area:
            allInOne?.mouseDown(at: point, modifiers: modifiers)
            allInOneDraggingFresh = allInOne?.selection.phase == .dragging
            allInOneRefresh(cursor: point)
        case nil:
            break
        }
    }

    func allInOneMouseDragged(to point: CGPoint, flags: NSEvent.ModifierFlags) {
        modifiers = SelectionModifiers(flags)
        allInOne?.mouseDragged(to: point, modifiers: modifiers)
        allInOneRefresh(cursor: point)
    }

    func allInOneMouseUp(at point: CGPoint, flags: NSEvent.ModifierFlags) {
        modifiers = SelectionModifiers(flags)
        allInOne?.mouseUp(at: point, modifiers: modifiers)
        allInOneDraggingFresh = false
        allInOneRefresh(cursor: point)
    }

    // MARK: Keys

    /// Returns whether All-In-One used the key.
    @discardableResult
    func allInOneKeyDown(_ event: NSEvent) -> Bool {
        let key = AllInOneKey(event)
        // Only arrows act on a held key's repeats: a held Space or W would toggle window mode over and over.
        if event.isARepeat, !key.isArrow { return false }
        // Esc closes an open ratio list first; the next one cancels.
        if key == .escape, allInOneToolbar?.closeRatioList() == true { return true }
        modifiers = SelectionModifiers(event.modifierFlags)
        guard let result = allInOne?.key(key, modifiers: modifiers, at: NSEvent.mouseLocation) else { return false }
        return handleAllInOne(result, keyModifiers: modifiers)
    }

    /// ⌘ letters reach the overlay as key equivalents before `keyDown` (the main menu has Edit › Copy on ⌘C). Returns
    /// whether All-In-One used the key; otherwise it goes on to the menu and then `keyDown` as usual.
    func allInOneKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command), case .character = AllInOneKey(event) else {
            return false
        }
        return allInOneKeyDown(event)
    }

    func allInOneKeyUp(_ event: NSEvent) {
        allInOne?.keyUp(AllInOneKey(event), at: NSEvent.mouseLocation)
    }

    /// A modifier pressed or released mid-drag or mid-resize reshapes the selection at once (⇧, ⌥).
    func allInOneFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        selectionFlagsChanged(flags, phase: allInOne?.selection.phase) { allInOne?.mouseDragged(to: $0, modifiers: $1) }
    }

    /// Acts on what a key asked for; `keyModifiers` are those held on it. Returns whether anything happened.
    @discardableResult
    func handleAllInOne(_ result: AllInOneKeyResult, keyModifiers: SelectionModifiers) -> Bool {
        let point = NSEvent.mouseLocation
        switch result {
        case .cancel:
            finish(.cancelled)
        case .changed:
            // The mode may have changed: hover afresh (window mode) or drop the highlight (area mode).
            hoveredWindow = nil
            allInOneMouseMoved(to: point, flags: NSEvent.modifierFlags)
        case .run(let command):
            guard let pick = allInOnePick(for: command, keyModifiers: keyModifiers, at: point) else { return false }
            finish(.allInOne(pick))
        case .ignored:
            return false
        }
        return true
    }

    /// What `command` runs on: area commands the selection, ⌘C in window mode the window under the pointer, fullscreen
    /// the selection's display or else the pointer's, Record the selection if there is one. Nil when there is nothing for
    /// it to run on.
    private func allInOnePick(for command: AllInOneCommand, keyModifiers: SelectionModifiers, at point: CGPoint)
        -> AllInOnePick? {
        guard let controller = allInOne else { return nil }
        let selection = controller.selection
        var area: AllInOnePick.Target?
        if controller.hasSelection, let rect = selection.rect, let display = selection.display {
            area = .area(rect, display)
        }
        let target: AllInOnePick.Target?
        switch command {
        case .captureArea, .selfTimer, .text, .scrolling:
            target = area
        case .captureAndCopy:
            target = controller.mode == .window ? hoveredWindow.map(AllInOnePick.Target.window) : area
        case .fullscreen:
            let display = controller.hasSelection ? selection.display : nil
            target = .display(display ?? layout.display(containingMouse: point) ?? layout.main)
        case .record:
            target = area ?? AllInOnePick.Target.none
        }
        guard let target else { return nil }
        return AllInOnePick(command: command, target: target, frozen: frozen, keyModifiers: keyModifiers,
                            startModifiers: selection.startModifiers)
    }

    // MARK: Drawing

    /// The toolbar, the cursor for what is under the pointer, and the selection with its handles, labels, crosshair and
    /// magnifier (`renderSelection`), or in window mode the hovered window's highlight; with the prompts.
    func allInOneRefresh(cursor point: CGPoint) {
        guard let controller = allInOne else { return }
        placeAllInOneToolbar()
        // Window mode keeps the selection, hidden.
        let selection = controller.mode == .area ? controller.selection : nil
        selectionCursor(selection, at: point, overPanel: allInOneToolbar?.contains(point) == true).set()
        let prompt: String? = if selection == nil {
            "Click a window to capture it. Press Space to select an area."
        } else if controller.selection.phase == .idle {
            "Drag to select capture area. Press Space to select a window."
        } else {
            nil
        }
        renderSelection(selection, windowHighlight: hoveredWindow.map { layout.appKitRect(fromCG: $0.frame) },
                        prompt: prompt, cursor: point)
    }
}

extension OverlaySession {
    // MARK: Toolbar

    /// The toolbar under (or over, or inside) the selection on its display's overlay, while there is a selection that
    /// isn't being dragged out fresh; hidden in window mode and without a selection.
    private func placeAllInOneToolbar() {
        guard let toolbar = allInOneToolbar, let controller = allInOne else { return }
        let selection = controller.mode == .area ? controller.selection : nil
        guard let anchor = toolbarAnchor(for: selection, draggingFresh: allInOneDraggingFresh) else {
            toolbar.hide()
            return
        }
        toolbar.update(for: controller)
        toolbar.show(attachedTo: anchor.window, selection: anchor.rect, visibleFrame: anchor.visibleFrame)
    }

    /// A toolbar button does what its key does, with the modifiers held at the click (⇧-click on Area skips the
    /// background preset, ⌃-click adds Copy); the other controls change the selection.
    func allInOneToolbarAction(_ action: AllInOneToolbarAction) {
        guard !overlayWindows.isEmpty else { return } // the session has finished
        let point = NSEvent.mouseLocation
        switch action {
        case .button(let button):
            guard let result = allInOne?.press(button) else { return }
            handleAllInOne(result, keyModifiers: SelectionModifiers(NSEvent.modifierFlags))
            return
        case let .size(width, height):
            allInOne?.setSize(width: width.map { CGFloat($0) }, height: height.map { CGFloat($0) })
        case .ratio(let ratio):
            allInOne?.setRatio(ratio)
            if case .allInOne(let setup) = style { setup.saveRatio(ratio) }
        case .toggleFullscreen:
            allInOne?.toggleFullscreenSelection()
        case .editingEnded:
            // The keys come back to the overlay, so a second Esc cancels the session.
            let display = allInOne?.selection.display ?? layout.display(containingMouse: point) ?? layout.main
            overlayWindows[display.id]?.makeKey()
        }
        allInOneRefresh(cursor: point)
    }
}

private extension AllInOneKey {
    /// The key as All-In-One reads it: Esc, Return (and keypad Enter), Space and the arrows by key code, everything else by
    /// `charactersIgnoringModifiers`, so letters follow the keyboard layout.
    init(_ event: NSEvent) {
        switch event.keyCode {
        case 53: self = .escape
        case 36, 76: self = .returnKey
        case 49: self = .space
        case 123: self = .arrow(.left)
        case 124: self = .arrow(.right)
        case 125: self = .arrow(.down)
        case 126: self = .arrow(.up)
        default: self = .character(event.charactersIgnoringModifiers ?? "")
        }
    }

    var isArrow: Bool {
        if case .arrow = self { return true }
        return false
    }
}

extension SelectionHandle {
    /// The resize cursor for the handle (All-In-One's and the scrolling capture's selections).
    var cursor: NSCursor {
        .frameResize(position: cursorPosition, directions: .all)
    }

    private var cursorPosition: NSCursor.FrameResizePosition {
        switch self {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
    }
}
