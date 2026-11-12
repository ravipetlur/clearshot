import AppKit
import CSCapture
import CSCore

/// Z, ⌘ and WASD in the selection overlay: a 10× lens, a pointer slowed to a quarter, and a pointer nudged by key. The
/// math is in `PointerTools` (CSCapture); this is the AppKit side.
///
/// Z and ⌘ work in every style. WASD nudges only in plain Capture Area, Capture Window and the self-timer's selection
/// (the `.capture` style): All-In-One uses W, A and S as commands, and it and the scrolling and recording selections
/// move their selection with the arrows instead.
extension OverlaySession {
    private static let keyCodeZ: UInt16 = 6

    private var displayFrames: [CGRect] { layout.displays.map(\.frame) }

    func pointerToolsEnd() {
        zoomHeld = false
        lastPointer = nil
    }

    /// Puts the real cursor at an AppKit point. A warp makes the system drop pointer events for a moment after it, which
    /// would swallow the movement that follows; associating mouse and cursor again ends that pause at once.
    private func warpCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(layout.cgPoint(fromAppKit: point))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: Pointer

    /// Where a mouse event's pointer is: the system's, or with ⌘ held on a move or drag a quarter of the hardware's
    /// movement from the last precise point, with the real cursor warped there. ⌘ alone moves nothing, and a press or
    /// release is at the pointer wherever it is.
    func pointerLocation(for event: NSEvent) -> CGPoint {
        let system = NSEvent.mouseLocation
        guard event.modifierFlags.contains(.command) else {
            precision.reset()
            return system
        }
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard event.deltaX != 0 || event.deltaY != 0 else { return system }
            let point = precision.move(byHardwareDelta: CGVector(dx: event.deltaX, dy: -event.deltaY),
                                       systemPointer: system, displays: displayFrames)
            warpCursor(to: point)
            return point
        default:
            return system
        }
    }

    /// WASD: moves the real cursor by a point (ten with ⇧), then tells the selection as a move or drag would.
    func nudgePointer(_ direction: PointerNudge.Direction, large: Bool) {
        let target = PointerNudge.target(from: lastPointer ?? NSEvent.mouseLocation, direction, large: large, displays: displayFrames)
        precision.reset()
        warpCursor(to: target)
        if controller?.phase == .dragging {
            mouseDragged(to: target, flags: NSEvent.modifierFlags)
        } else {
            mouseMoved(to: target, flags: NSEvent.modifierFlags)
        }
    }

    /// A WASD key in the `.capture` style; whether it was one.
    func nudgeKeyDown(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        let direction: PointerNudge.Direction
        switch event.keyCode {
        case 13: direction = .up // W
        case 0: direction = .left // A
        case 1: direction = .down // S
        case 2: direction = .right // D
        default: return false
        }
        nudgePointer(direction, large: event.modifierFlags.contains(.shift))
        return true
    }

    // MARK: Lens

    /// Z held or let go; whether the key was Z (⌘Z, ⌃Z and ⌥Z are not).
    func zoomKey(_ event: NSEvent, down: Bool) -> Bool {
        guard event.keyCode == Self.keyCodeZ, event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        if !event.isARepeat {
            zoomHeld = down
            updateLens()
        }
        return true
    }

    /// Shows the lens on the pointer's display while Z is held, and hides it on the others. It samples the display's
    /// snapshot, as the magnifier does: the picture taken as the overlay opened, which with Freeze screen is the one on
    /// show, and without it is the screen as it was then (a live capture would catch the overlay's own dim).
    func updateLens() {
        let point = lastPointer ?? NSEvent.mouseLocation
        let cursorDisplay = layout.display(containingMouse: point)
        for display in layout.displays {
            guard let view = overlayWindows[display.id]?.overlayView else { continue }
            guard zoomHeld, display.id == cursorDisplay?.id, let snapshot = snapshots[display.id] else {
                view.setLens(nil)
                continue
            }
            let local = layout.localRect(CGRect(origin: point, size: .zero), in: display).origin
            let pixel = Magnifier.pixel(forLocalPoint: local, scale: display.scale)
            let sample = ZoomLens.sampleRect(centeredOn: pixel, scale: display.scale,
                                             imageSize: CGSize(width: snapshot.width, height: snapshot.height))
            let cursor = CGPoint(x: point.x - display.frame.minX, y: point.y - display.frame.minY)
            let frame = ZoomLens.frame(near: cursor, in: CGRect(origin: .zero, size: display.frame.size))
            view.setLens(OverlayLens(image: snapshot.cropping(to: sample), frame: frame,
                                     marker: ZoomLens.markerRect(pixel: pixel, sample: sample, lensSide: frame.width)))
        }
    }
}
