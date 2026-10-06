import AppKit
import CSCapture
import CSCore

/// What the two styles with an adjustable selection share (All-In-One's area mode, the scrolling capture's Select and
/// Ready): drawing the selection, the cursor over it, reshaping it when a modifier changes mid-drag, and where its
/// toolbar goes.
extension OverlaySession {
    /// Draws `selection` with its handles (while it is adjustable) on every display's overlay, with the W × H label, or
    /// the pointer's coordinates when it isn't on the pointer's display, and the crosshair and magnifier as the area
    /// overlay draws them. Nil draws none of that (All-In-One's window mode). `windowHighlight` (AppKit global points) and
    /// `prompt` show as given; the prompt on the pointer's display.
    func renderSelection(_ selection: AdjustableSelection?, windowHighlight: CGRect?, prompt: String?,
                         cursor point: CGPoint) {
        let cursorDisplay = layout.display(containingMouse: point)
        let rect = selection?.rect
        var handles: [CGPoint] = []
        if let selection, selection.isAdjustable, let rect { handles = SelectionHandle.allCases.map { $0.point(on: rect) } }
        let showsCrosshair = selection != nil && crosshairOn

        for display in layout.displays {
            guard let window = overlayWindows[display.id] else { continue }
            let origin = display.frame.origin
            func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -origin.x, dy: -origin.y) }
            var state = OverlayRenderState()
            state.selection = rect.flatMap { display.frame.intersects($0) ? local($0) : nil }
            state.windowHighlight = windowHighlight.flatMap { display.frame.intersects($0) ? local($0) : nil }
            // A handle on an edge this display shares with the selection's shows here too (and grabs from here).
            let reach = OverlayView.handleDiameter / 2
            state.handles = handles
                .filter { display.frame.insetBy(dx: -reach, dy: -reach).contains($0) }
                .map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
            if cursorDisplay?.id == display.id {
                let cursor = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
                state.cursor = cursor
                state.showsCrosshair = showsCrosshair
                if showsCrosshair, options.showMagnifier { state.magnifierImage = magnifierImage(at: point, on: display) }
                if let selection {
                    if let rect, selection.displayID == display.id {
                        state.label = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
                        state.labelAnchor = CGPoint(x: local(rect).maxX, y: local(rect).minY)
                    } else {
                        let localPoint = layout.localRect(CGRect(origin: point, size: .zero), in: display).origin
                        state.label = "\(Int(localPoint.x)), \(Int(localPoint.y))"
                        state.labelAnchor = cursor
                    }
                }
                state.prompt = prompt
            }
            window.overlayView.render(state)
        }
    }

    /// Over a toolbar or a panel of the overlay (`overPanel`) the arrow; over a handle (or dragging one) its resize
    /// cursor, over the selection an open hand (closed while moving it), elsewhere, or without a selection, the
    /// crosshair. Set on every event: the overlay never makes ClearShot active, so cursor rects don't apply.
    func selectionCursor(_ selection: AdjustableSelection?, at point: CGPoint, overPanel: Bool) -> NSCursor {
        if overPanel { return .arrow }
        guard let selection else { return .crosshair }
        switch selection.phase {
        case .resizing(let handle):
            return handle.cursor
        case .moving:
            return .closedHand
        case .adjusting:
            if let handle = selection.handle(at: point) { return handle.cursor }
            return selection.rect?.contains(point) == true ? .openHand : .crosshair
        default:
            return .crosshair
        }
    }

    /// A modifier pressed or released mid-drag or mid-resize (the selection's `phase`) reshapes the selection at once
    /// through `reshape` (⇧ squares, ⌥ centres); then the overlay redraws.
    func selectionFlagsChanged(_ flags: NSEvent.ModifierFlags, phase: SelectionController.Phase?,
                               reshape: (CGPoint, SelectionModifiers) -> Void) {
        modifiers = SelectionModifiers(flags)
        let point = NSEvent.mouseLocation
        switch phase {
        case .dragging?, .resizing?:
            reshape(point, modifiers)
        default:
            break
        }
        refresh(cursor: point)
    }

    /// Where `selection`'s toolbar goes: its rect, its display's overlay and that screen's visible frame. Nil while there
    /// is no adjustable selection (or it is hidden: nil) or it is being dragged out fresh.
    func toolbarAnchor(for selection: AdjustableSelection?, draggingFresh: Bool)
        -> (rect: CGRect, window: OverlayWindow, visibleFrame: CGRect)? {
        guard let selection, selection.isAdjustable, !draggingFresh, let rect = selection.rect,
              let display = selection.display, let window = overlayWindows[display.id] else { return nil }
        return (rect, window, display.visibleFrame)
    }
}

extension DisplayInfo {
    /// The display's screen without the menu bar and the Dock (`NSScreen.visibleFrame`); the whole display if its screen
    /// is gone.
    var visibleFrame: CGRect {
        NSScreen.screens.first { $0.displayID == id }?.visibleFrame ?? frame
    }
}
