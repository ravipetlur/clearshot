import AppKit
import CSCapture
import CSCore
import CSScrolling

/// A scrolling capture's Select and Ready: a live, dimmed overlay with an adjustable selection (handles, moves, arrows,
/// stray clicks and other displays as in All-In-One, freeform) and, once there is one, the Ready toolbar. Return or
/// Start Capture starts by hand, the Auto-Scroll buttons start scrolling down or right, Esc and Cancel cancel, Help
/// opens the tips. Space moves a selection being dragged; otherwise Space and F do nothing.
extension OverlaySession {
    private enum ToolbarID {
        static let start = "start"
        static let autoScrollDown = "autoScrollDown"
        static let autoScrollRight = "autoScrollRight"
        static let cancel = "cancel"
        static let help = "help"
    }

    var isScrollingSelection: Bool {
        if case .scrollingSelection = style { return true }
        return false
    }

    /// A freeform selection over every display, with each display's snap lines, starting on `initial` when it is still
    /// on a connected display. That selection keeps its drag's start modifiers until a fresh drag replaces it.
    func makeScrollingSelection(initial: (rect: CGRect, display: DisplayInfo, startModifiers: SelectionModifiers)?)
        -> AdjustableSelection {
        let lines = Dictionary(uniqueKeysWithValues: layout.displays.map { ($0.id, snapLines(on: $0)) })
        var selection = AdjustableSelection(displays: layout.displays, snapLines: lines)
        if let initial {
            selection.setRect(initial.rect, onDisplay: initial.display.id, startModifiers: initial.startModifiers)
        }
        return selection
    }

    func makeScrollingToolbar() -> SelectionToolbar {
        let toolbar = SelectionToolbar { [weak self] action in self?.scrollingToolbarAction(action) }
        toolbar.update([
            .button(SelectionToolbarButton(id: ToolbarID.start, symbol: "record.circle", title: "Start Capture",
                                           hoverLabel: "Start Capture (Return)", isProminent: true)),
            .button(SelectionToolbarButton(id: ToolbarID.autoScrollDown, symbol: "arrow.down.to.line",
                                           hoverLabel: "Auto-Scroll Down")),
            .button(SelectionToolbarButton(id: ToolbarID.autoScrollRight, symbol: "arrow.right.to.line",
                                           hoverLabel: "Auto-Scroll Right")),
            .divider,
            .button(SelectionToolbarButton(id: ToolbarID.cancel, symbol: "xmark", hoverLabel: "Cancel (Esc)")),
            .button(SelectionToolbarButton(id: ToolbarID.help, symbol: "questionmark.circle", hoverLabel: "Tips")),
        ])
        return toolbar
    }

    /// Ready → the capture starts by hand (Return, Start Capture, the Start/Stop hotkey), when there is a selection.
    func startScrolling() {
        startScrolling(.manual)
    }

    private func startScrolling(_ start: ScrollingStart) {
        guard let selection = scrollingSelection, selection.isAdjustable, let rect = selection.rect,
              let display = selection.display else { return }
        finish(.scrollingRegion(rect, display, start: start, startModifiers: selection.startModifiers))
    }

    /// The overlay is on screen: the first scrolling capture opens the tips over it at once.
    func scrollingPresented() {
        if opensScrollingTips { showScrollingTips() }
    }

    // MARK: Mouse

    func scrollingMouseMoved(to point: CGPoint, flags: NSEvent.ModifierFlags) {
        modifiers = SelectionModifiers(flags)
        if let display = layout.display(containingMouse: point), let window = overlayWindows[display.id], !window.isKeyWindow {
            window.makeKey()
        }
        scrollingRefresh(cursor: point)
    }

    func scrollingMouseDown(at point: CGPoint, flags: NSEvent.ModifierFlags) {
        modifiers = SelectionModifiers(flags)
        scrollingSelection?.mouseDown(at: point, modifiers: modifiers)
        scrollingDraggingFresh = scrollingSelection?.phase == .dragging
        scrollingRefresh(cursor: point)
    }

    func scrollingMouseDragged(to point: CGPoint, flags: NSEvent.ModifierFlags) {
        modifiers = SelectionModifiers(flags)
        scrollingSelection?.mouseDragged(to: point, modifiers: modifiers)
        scrollingRefresh(cursor: point)
    }

    func scrollingMouseUp(at point: CGPoint, flags: NSEvent.ModifierFlags) {
        modifiers = SelectionModifiers(flags)
        scrollingSelection?.mouseUp(at: point, modifiers: modifiers)
        scrollingDraggingFresh = false
        scrollingRefresh(cursor: point)
    }

    // MARK: Keys

    func scrollingKeyDown(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        switch event.keyCode {
        case 53: // Esc: closes the tips first, as it closes All-In-One's ratio list; the next one cancels.
            guard !event.isARepeat else { return }
            if ScrollingTipsPanel.isShown {
                ScrollingTipsPanel.close()
            } else {
                finish(.cancelled)
            }
        case 36, 76: // Return, keypad Enter
            guard !event.isARepeat else { return }
            startScrolling(.manual)
        case 49: // Space moves a selection being dragged out; otherwise it does nothing here.
            guard !event.isARepeat, scrollingSelection?.phase == .dragging else { return }
            scrollingSelection?.spaceDown(at: point)
            scrollingRefresh(cursor: point)
        case 123, 124, 125, 126:
            guard scrollingSelection?.phase == .adjusting else { return }
            let arrow: ArrowKey = switch event.keyCode {
            case 123: .left
            case 124: .right
            case 125: .down
            default: .up
            }
            scrollingSelection?.arrow(arrow, modifiers: SelectionModifiers(event.modifierFlags))
            scrollingRefresh(cursor: point)
        default:
            break
        }
    }

    func scrollingKeyUp(_ event: NSEvent) {
        guard event.keyCode == 49 else { return }
        let point = NSEvent.mouseLocation
        scrollingSelection?.spaceUp(at: point)
        scrollingRefresh(cursor: point)
    }

    /// A modifier pressed or released mid-drag or mid-resize reshapes the selection at once (⇧, ⌥).
    func scrollingFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        selectionFlagsChanged(flags, phase: scrollingSelection?.phase) {
            scrollingSelection?.mouseDragged(to: $0, modifiers: $1)
        }
    }

    // MARK: Drawing

    /// The Ready toolbar, the cursor (the arrow over the toolbar and the tips) and the selection with its handles,
    /// labels, crosshair and magnifier (`renderSelection`), with the prompt until there is a selection. Reports the
    /// selection coming or going.
    func scrollingRefresh(cursor point: CGPoint) {
        guard let selection = scrollingSelection else { return }
        reportScrollingReady(selection.isAdjustable)
        placeScrollingToolbar()
        let overPanel = scrollingToolbar?.frame.contains(point) == true || ScrollingTipsPanel.contains(point)
        selectionCursor(selection, at: point, overPanel: overPanel).set()
        renderSelection(selection, windowHighlight: nil,
                        prompt: selection.phase == .idle ? "Drag over the part of the screen that scrolls." : nil,
                        cursor: point)
    }

    private func reportScrollingReady(_ ready: Bool) {
        guard ready != scrollingReady else { return }
        scrollingReady = ready
        onScrollingReadyChange?(ready)
    }

    // MARK: Toolbar and tips

    /// The Ready toolbar under (or over, or inside) the selection on its display's overlay, while there is a selection
    /// that isn't being dragged out fresh.
    private func placeScrollingToolbar() {
        guard let toolbar = scrollingToolbar else { return }
        guard let anchor = toolbarAnchor(for: scrollingSelection, draggingFresh: scrollingDraggingFresh) else {
            toolbar.hide()
            return
        }
        toolbar.show(attachedTo: anchor.window, anchoredTo: anchor.rect, visibleFrame: anchor.visibleFrame)
    }

    private func scrollingToolbarAction(_ action: SelectionToolbarAction) {
        guard !overlayWindows.isEmpty, case .pressed(let id) = action else { return } // the session may have finished
        switch id {
        case ToolbarID.start: startScrolling(.manual)
        case ToolbarID.autoScrollDown: startScrolling(.auto(.vertical))
        case ToolbarID.autoScrollRight: startScrolling(.auto(.horizontal))
        case ToolbarID.cancel: finish(.cancelled)
        case ToolbarID.help: showScrollingTips()
        default: break
        }
    }

    /// The tips over the overlay of the selection's display, or of the pointer's.
    private func showScrollingTips() {
        let display = scrollingSelection?.display ?? layout.display(containingMouse: NSEvent.mouseLocation) ?? layout.main
        guard let window = overlayWindows[display.id] else { return }
        ScrollingTipsPanel.show(over: window) { [weak self] in self?.onScrollingTipsClosed?() }
    }
}
