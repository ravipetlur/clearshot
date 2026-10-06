import AppKit
import CSCore
import CSRecording
import QuartzCore

/// Highlight Clicks: a ring at every click on the recorded display, drawn in a click-through window over it that the
/// recording keeps (ClearShot is left out of the stream as an app, so the window is listed in `exceptingWindows`). The
/// clicks come from a global monitor only, which needs no permission for mouse events: clicks on ClearShot's own
/// windows (the control bar, notices, the menu bar icon) reach no global monitor, so they draw nothing, and they aren't
/// in the recording anyway. Left and right clicks look the same.
final class ClickHighlighter {
    private enum Button {
        case left, right
    }

    private let style: ClickRippleStyle
    private let display: DisplayInfo
    private let window: ClickOverlayWindow
    private var monitor: Any?
    private var rings = ClickRings<Button>()

    /// While paused, clicks draw nothing: the writer drops those frames. Rings already up go as usual.
    var isPaused = false

    init(style: ClickRippleStyle, display: DisplayInfo) {
        self.style = style
        self.display = display
        window = ClickOverlayWindow(display: display)
    }

    /// Orders the overlay front, above the recording's frame. Before the stream fetches its content: a window that
    /// isn't on screen yet can be missing from it, and its rings would never reach the file.
    func show() {
        window.orderFrontRegardless()
    }

    /// The overlay's window number, for the stream's kept windows, once `show` has put it on screen; nil (logged) when
    /// the window server gave it none, and then its rings aren't recorded.
    var windowID: UInt32? {
        guard window.windowNumber > 0 else {
            Log.recording.error("The click overlay has no window number (\(window.windowNumber)); its rings won't be recorded")
            return nil
        }
        return UInt32(window.windowNumber)
    }

    /// The mouse monitor on: from the moment the recording starts (not during the countdown).
    func start() {
        guard monitor == nil else { return }
        // On the main thread; each event is only layer work.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown,
                                                               .rightMouseUp]) { [weak self] event in
            self?.handle(event)
        }
        if monitor == nil {
            Log.recording.warning("Couldn't watch the mouse; this recording has no click highlights")
        }
    }

    /// The monitor off, every ring gone and the overlay closed: as the recording ends, and again (doing nothing more)
    /// as its windows close.
    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        rings.removeAll(from: window.ringLayer)
        window.orderOut(nil)
        window.close()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: press(.left)
        case .rightMouseDown: press(.right)
        case .leftMouseUp: rings.release(.left, style: style)
        case .rightMouseUp: rings.release(.right, style: style)
        default: break
        }
    }

    /// A ring where the pointer is, when it is on the recorded display (by the mouse's own edge rule, so the top row is
    /// this display's and never the one above's) and the recording isn't paused.
    private func press(_ button: Button) {
        let point = NSEvent.mouseLocation
        let local = !isPaused && display.containsMouse(point)
            ? CGPoint(x: point.x - display.frame.minX, y: point.y - display.frame.minY) : nil
        rings.press(button, at: local, style: style, in: window.ringLayer)
    }
}

/// The rings' window over the whole display, one level above the recording's frame (`.screenSaver`), so the dimming
/// never covers a ring on screen.
private final class ClickOverlayWindow: DisplayOverlayPanel {
    /// The layer the rings go in: the content view's, y up, in the display's points.
    let ringLayer = CALayer()

    init(display: DisplayInfo) {
        super.init(display: display, level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1))
        // Layer-hosting: the layer is set before wantsLayer, and nothing is drawn with draw(_:).
        let view = NSView(frame: CGRect(origin: .zero, size: display.frame.size))
        ringLayer.contentsScale = display.scale
        view.layer = ringLayer
        view.wantsLayer = true
        contentView = view
    }
}
