import AppKit
import CSCapture
import CSCore
import CSRecording
import CSScrolling

struct OverlayOptions {
    var freeze: Bool
    var crosshair: CrosshairMode
    var showMagnifier: Bool
    var dim: Bool
}

enum OverlayMode {
    case area, window
}

/// How the overlay behaves. `.capture` confirms an area on mouse-up (Capture Area, Capture Window, Self-Timer,
/// Annotate's Take Screenshot); `.allInOne` keeps an adjustable selection and runs what its keys ask for;
/// `.scrollingSelection` is a scrolling capture's Select and Ready, starting in Ready on `initial` when given, with the
/// keys held as that selection was dragged out (All-In-One's S); `.recordingSelection` is a recording's Select and
/// Ready, with Ready's state.
enum OverlayStyle {
    case capture, allInOne(AllInOneSetup)
    case scrollingSelection(initial: (rect: CGRect, display: DisplayInfo, startModifiers: SelectionModifiers)?)
    case recordingSelection(RecordingReadyModel)
}

enum OverlayOutcome {
    /// `modifiers` are the keys held at mouse-up (⌃ for Copy); `startModifiers` those held as the drag began (⇧ to skip
    /// the background preset), so a ⇧ that squares the selection mid-drag doesn't also skip it.
    case area(CGRect, DisplayInfo, frozen: Bool, modifiers: SelectionModifiers, startModifiers: SelectionModifiers)
    /// `modifiers` are the keys held at the click.
    case window(WindowRecord, modifiers: SelectionModifiers)
    /// A command All-In-One's keys ran, with what it runs on.
    case allInOne(AllInOnePick)
    /// The region a scrolling capture runs on and how it starts; `startModifiers` are those held as its drag began.
    case scrollingRegion(CGRect, DisplayInfo, start: ScrollingStart, startModifiers: SelectionModifiers)
    /// What a recording's Ready records.
    case recording(RecordingPick)
    case cancelled
}

/// One selection: shows the overlay on every display and returns what the person picked.
final class OverlaySession {
    let layout: DisplayLayout
    let snapshots: [UInt32: CGImage]
    let windows: [WindowRecord]
    let excludedWindowIDs: Set<UInt32>
    let options: OverlayOptions
    let style: OverlayStyle
    private var mode: OverlayMode
    private(set) var frozen: Bool
    private(set) var overlayWindows: [UInt32: OverlayWindow] = [:]
    private var controller: SelectionController?
    private var activeDisplay: DisplayInfo?
    var hoveredWindow: WindowRecord?
    var modifiers: SelectionModifiers = []
    /// All-In-One's mode and selection; nil in the `.capture` style.
    var allInOne: AllInOneController?
    /// All-In-One's toolbar; nil in the `.capture` style.
    var allInOneToolbar: AllInOneToolbar?
    /// The mouse is down on a selection All-In-One is dragging out fresh, which shows no toolbar until it is let go.
    var allInOneDraggingFresh = false
    /// The scrolling capture's selection and Ready toolbar; nil in the other styles.
    var scrollingSelection: AdjustableSelection?
    var scrollingToolbar: SelectionToolbar?
    /// The mouse is down on a scrolling selection being dragged out fresh, which shows no toolbar until it is let go.
    var scrollingDraggingFresh = false
    /// Whether a scrolling selection exists (Ready), as last reported to `onScrollingReadyChange`.
    var scrollingReady = false
    /// Told each time the scrolling selection comes or goes: true once it exists (Ready), false without one (Select).
    var onScrollingReadyChange: ((Bool) -> Void)?
    /// The scrolling capture's tips open over the overlay as it appears (the first scrolling capture).
    var opensScrollingTips = false
    /// The tips closed, however that happened.
    var onScrollingTipsClosed: (() -> Void)?
    /// The recording's selection and Ready toolbar; nil in the other styles.
    var recordingSelection: AdjustableSelection?
    var recordingToolbar: RecordingReadyToolbar?
    /// The mouse is down on a recording selection being dragged out fresh, which shows no toolbar until it is let go.
    var recordingDraggingFresh = false
    /// The recording's overlay is picking a window (Record Window starts so; Space switches); the selection waits, hidden.
    var recordingPicksWindow = false
    private var continuation: CheckedContinuation<OverlayOutcome, Never>?

    init(layout: DisplayLayout, snapshots: [UInt32: CGImage], windows: [WindowRecord], excludedWindowIDs: Set<UInt32>,
         options: OverlayOptions, mode: OverlayMode, style: OverlayStyle = .capture) {
        self.layout = layout
        self.snapshots = snapshots
        self.windows = windows
        self.excludedWindowIDs = excludedWindowIDs
        self.options = options
        self.mode = mode
        self.style = style
        self.frozen = options.freeze
        if case .allInOne(let setup) = style {
            allInOne = makeAllInOneController(setup)
            allInOneToolbar = makeAllInOneToolbar()
        }
        if case .scrollingSelection(let initial) = style {
            // Live whatever the Freeze screen setting says: the capture scrolls the live page.
            frozen = false
            scrollingSelection = makeScrollingSelection(initial: initial)
            scrollingToolbar = makeScrollingToolbar()
        }
        if case .recordingSelection(let model) = style {
            // Live whatever the Freeze screen setting says: the recording shows the live screen.
            frozen = false
            recordingSelection = makeRecordingSelection(model)
            recordingToolbar = makeRecordingToolbar(model)
            // Record Window starts picking a window. The recording style switches with `recordingPicksWindow` alone, and
            // its own mode stays area, which the crosshair setting reads (`crosshairOn`) once Space switches to areas.
            recordingPicksWindow = mode == .window
            self.mode = .area
        }
    }

    func run() async -> OverlayOutcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            present()
        }
    }

    // MARK: Lifecycle

    private func present() {
        for display in layout.displays {
            let window = OverlayWindow(display: display)
            window.overlayView.session = self
            window.overlayView.configure(snapshot: frozen ? snapshots[display.id] : nil, dim: options.dim)
            overlayWindows[display.id] = window
            window.orderFrontRegardless()
        }
        // The overlay panels are non-activating: ClearShot never becomes the active app, so the frontmost app keeps
        // its open menus and its active window chrome, which is what live and window captures should show. A
        // non-activating panel can still be key, and being key is all Esc, Space, F and the modifier keys need.
        NSCursor.crosshair.push()
        // One panel is key from the start, so Esc, Space, F and the modifier keys work before the first mouse move.
        let point = NSEvent.mouseLocation
        let keyDisplay = layout.display(containingMouse: point) ?? layout.main
        overlayWindows[keyDisplay.id]?.makeKey()
        mouseMoved(to: point, flags: NSEvent.modifierFlags)
        if isScrollingSelection { scrollingPresented() }
    }

    func finish(_ outcome: OverlayOutcome) {
        guard let continuation else { return }
        self.continuation = nil
        NSCursor.pop()
        // All-In-One's toolbar, hover label and ratio list, the scrolling toolbar and tips, and Ready's toolbar and lists are
        // children of an overlay window: they go first.
        allInOneToolbar?.hide()
        scrollingToolbar?.hide()
        recordingToolbar?.hide()
        if isScrollingSelection { ScrollingTipsPanel.close() }
        for window in overlayWindows.values {
            window.overlayView.session = nil
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        continuation.resume(returning: outcome)
    }

    func cancel() {
        finish(.cancelled)
    }

    // MARK: Events

    func mouseMoved(to point: CGPoint, flags: NSEvent.ModifierFlags) {
        if case .allInOne = style { allInOneMouseMoved(to: point, flags: flags); return }
        if isScrollingSelection { scrollingMouseMoved(to: point, flags: flags); return }
        if isRecordingSelection { recordingMouseMoved(to: point, flags: flags); return }
        modifiers = SelectionModifiers(flags)
        if let display = layout.display(containingMouse: point), let window = overlayWindows[display.id], !window.isKeyWindow {
            window.makeKey()
        }
        if mode == .window {
            hoveredWindow = WindowPicker.window(at: layout.cgPoint(fromAppKit: point), in: windows, excluding: excludedWindowIDs)
        }
        refresh(cursor: point)
    }

    func mouseDown(at point: CGPoint, flags: NSEvent.ModifierFlags) {
        if case .allInOne = style { allInOneMouseDown(at: point, flags: flags); return }
        if isScrollingSelection { scrollingMouseDown(at: point, flags: flags); return }
        if isRecordingSelection { recordingMouseDown(at: point, flags: flags); return }
        modifiers = SelectionModifiers(flags)
        switch mode {
        case .window:
            if let hoveredWindow { finish(.window(hoveredWindow, modifiers: modifiers)) }
        case .area:
            guard let display = layout.display(containingMouse: point) else { return }
            activeDisplay = display
            var selection = SelectionController(bounds: display.frame, confirmsOnMouseUp: true, snapLines: snapLines(on: display))
            selection.mouseDown(at: point, modifiers: modifiers)
            controller = selection
            refresh(cursor: point)
        }
    }

    func mouseDragged(to point: CGPoint, flags: NSEvent.ModifierFlags) {
        if case .allInOne = style { allInOneMouseDragged(to: point, flags: flags); return }
        if isScrollingSelection { scrollingMouseDragged(to: point, flags: flags); return }
        if isRecordingSelection { recordingMouseDragged(to: point, flags: flags); return }
        modifiers = SelectionModifiers(flags)
        controller?.mouseDragged(to: point, modifiers: modifiers)
        refresh(cursor: point)
    }

    func mouseUp(at point: CGPoint, flags: NSEvent.ModifierFlags) {
        if case .allInOne = style { allInOneMouseUp(at: point, flags: flags); return }
        if isScrollingSelection { scrollingMouseUp(at: point, flags: flags); return }
        if isRecordingSelection { recordingMouseUp(at: point, flags: flags); return }
        modifiers = SelectionModifiers(flags)
        guard controller != nil, let display = activeDisplay else { return }
        controller?.mouseUp(at: point, modifiers: modifiers)
        guard let selection = controller else { return }
        switch selection.phase {
        case .done:
            finish(.area(selection.rect, display, frozen: frozen, modifiers: modifiers, startModifiers: selection.startModifiers))
        case .idle:
            controller = nil
            activeDisplay = nil
            refresh(cursor: point)
        default:
            refresh(cursor: point)
        }
    }

    func keyDown(_ event: NSEvent) {
        if case .allInOne = style { allInOneKeyDown(event); return }
        if isScrollingSelection { scrollingKeyDown(event); return }
        if isRecordingSelection { recordingKeyDown(event); return }
        switch event.keyCode {
        case 53: // Esc
            finish(.cancelled)
        case 49: // Space
            guard !event.isARepeat else { return }
            if controller?.phase == .dragging {
                controller?.spaceDown(at: NSEvent.mouseLocation)
            } else if controller == nil {
                mode = mode == .area ? .window : .area
                hoveredWindow = nil
                mouseMoved(to: NSEvent.mouseLocation, flags: event.modifierFlags)
            }
        case 3: // F: freeze or unfreeze the screen
            guard !event.isARepeat else { return }
            frozen.toggle()
            for (id, window) in overlayWindows {
                window.overlayView.setSnapshot(frozen ? snapshots[id] : nil)
            }
        default:
            break
        }
    }

    func keyUp(_ event: NSEvent) {
        if case .allInOne = style { allInOneKeyUp(event); return }
        if isScrollingSelection { scrollingKeyUp(event); return }
        if isRecordingSelection { recordingKeyUp(event); return }
        if event.keyCode == 49 { controller?.spaceUp(at: NSEvent.mouseLocation) }
    }

    func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        if case .allInOne = style { allInOneFlagsChanged(flags); return }
        if isScrollingSelection { scrollingFlagsChanged(flags); return }
        if isRecordingSelection { recordingFlagsChanged(flags); return }
        modifiers = SelectionModifiers(flags)
        let point = NSEvent.mouseLocation
        if controller?.phase == .dragging { controller?.mouseDragged(to: point, modifiers: modifiers) }
        refresh(cursor: point)
    }

    // MARK: Drawing

    /// The crosshair setting, in area mode (All-In-One and the scrolling and recording selections always run in it).
    var crosshairOn: Bool {
        guard mode == .area else { return false }
        switch options.crosshair {
        case .always: return true
        case .whileCommandHeld: return modifiers.contains(.command)
        case .off: return false
        }
    }

    /// Redraws the overlay for the pointer at `point`, in the session's style.
    func refresh(cursor point: CGPoint) {
        if case .allInOne = style { allInOneRefresh(cursor: point); return }
        if isScrollingSelection { scrollingRefresh(cursor: point); return }
        if isRecordingSelection { recordingRefresh(cursor: point); return }
        let cursorDisplay = layout.display(containingMouse: point)
        let selection = controller.flatMap { $0.rect.width > 0 ? $0.rect : nil }
        let highlight = hoveredWindow.map { layout.appKitRect(fromCG: $0.frame) }

        for display in layout.displays {
            guard let window = overlayWindows[display.id] else { continue }
            let origin = display.frame.origin
            func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -origin.x, dy: -origin.y) }
            let isCursorDisplay = cursorDisplay?.id == display.id
            var state = OverlayRenderState()
            state.selection = selection.flatMap { display.frame.intersects($0) ? local($0) : nil }
            state.windowHighlight = highlight.flatMap { display.frame.intersects($0) ? local($0) : nil }
            if isCursorDisplay {
                let cursor = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
                state.cursor = cursor
                state.showsCrosshair = crosshairOn
                if crosshairOn, options.showMagnifier { state.magnifierImage = magnifierImage(at: point, on: display) }
                if let selection, activeDisplay?.id == display.id {
                    state.label = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
                    state.labelAnchor = CGPoint(x: local(selection).maxX, y: local(selection).minY)
                } else if mode == .area {
                    let localPoint = layout.localRect(CGRect(origin: point, size: .zero), in: display).origin
                    state.label = "\(Int(localPoint.x)), \(Int(localPoint.y))"
                    state.labelAnchor = cursor
                }
                if controller == nil {
                    state.prompt = mode == .area
                        ? "Drag to select capture area. Press Space to select a window."
                        : "Click a window to capture it. Press Space to select an area."
                }
            }
            window.overlayView.render(state)
        }
    }

    func magnifierImage(at point: CGPoint, on display: DisplayInfo) -> CGImage? {
        guard let snapshot = snapshots[display.id] else { return nil }
        let local = layout.localRect(CGRect(origin: point, size: .zero), in: display).origin
        let pixel = Magnifier.pixel(forLocalPoint: local, scale: display.scale)
        let rect = Magnifier.sampleRect(centeredOn: pixel, gridSize: Magnifier.gridSize,
                                        imageSize: CGSize(width: snapshot.width, height: snapshot.height))
        return snapshot.cropping(to: rect)
    }

    func snapLines(on display: DisplayInfo) -> SnapLines {
        let frames = windows
            .filter { (0..<20).contains($0.layer) && !excludedWindowIDs.contains($0.id) }
            .map { layout.appKitRect(fromCG: $0.frame) }
        return SnapLines.from(windowFrames: frames, bounds: display.frame)
    }
}
