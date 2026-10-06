import AppKit
import CSCapture
import CSCore
import CSRecording

/// What a recording's Ready records: an area (a selection, or a picked window's frame) or a whole display, in which mode,
/// with the keys held as the selection's drag began.
struct RecordingPick {
    enum Target: Equatable {
        case area(CGRect, DisplayInfo), display(DisplayInfo)
    }

    let target: Target
    let mode: RecordingMode
    let startModifiers: SelectionModifiers
}

extension RecordingPick.Target {
    var display: DisplayInfo {
        switch self {
        case let .area(_, display), let .display(display): display
        }
    }

    /// The selected area, AppKit global points; nil for a whole display.
    var area: CGRect? {
        if case let .area(rect, _) = self { return rect }
        return nil
    }

    var captureKind: CaptureKind {
        area == nil ? .display : .selection
    }

    /// What is recorded, AppKit global points: an area snapped outward to whole pixels, as the stream records it, or the
    /// display's frame.
    func recordedRect(in layout: DisplayLayout) -> CGRect {
        guard let area else { return display.frame }
        return RegionStreamGeometry.make(region: area, display: display, layout: layout).globalRect
    }
}

/// A recording's Select and Ready: a live overlay (dimmed as selections are) with an adjustable selection in the
/// recording ratio (handles, moves, arrows, ⇧/⌥ and other displays, as in the scrolling capture) and, once there is
/// one, the Ready toolbar (`RecordingReadyToolbar`). Space, unless a selection is being dragged out (when it moves it),
/// switches to picking a window: hovering highlights one (never ClearShot's own) and a click makes its frame the
/// selection, clamped to its display, back in area mode. Return records the selection, or with none the pointer's
/// display; Esc closes an open list first, then cancels. No letter keys.
extension OverlaySession {
    var isRecordingSelection: Bool {
        if case .recordingSelection = style { return true }
        return false
    }

    /// Ready's state; nil in the other styles.
    var recordingModel: RecordingReadyModel? {
        if case .recordingSelection(let model) = style { return model }
        return nil
    }

    /// A selection over every display in the recording ratio, with each display's snap lines, starting in Ready on
    /// All-In-One's selection or the remembered area (`RecordingReadyModel.startingSelection`).
    func makeRecordingSelection(_ model: RecordingReadyModel) -> AdjustableSelection {
        let lines = Dictionary(uniqueKeysWithValues: layout.displays.map { ($0.id, snapLines(on: $0)) })
        var selection = AdjustableSelection(displays: layout.displays, snapLines: lines, aspectRatio: model.ratio.aspect)
        if let start = model.startingSelection(in: layout) {
            selection.setRect(start.rect, onDisplay: start.display.id, startModifiers: start.startModifiers)
        }
        return selection
    }

    /// Ready's toolbar; what changes in the model redraws it, and the meter updates it alone.
    func makeRecordingToolbar(_ model: RecordingReadyModel) -> RecordingReadyToolbar {
        // Not once the overlay has closed: the model outlives it (its microphone goes on into the recording).
        model.onChange = { [weak self] in
            guard let self, !overlayWindows.isEmpty else { return }
            recordingRefresh(cursor: NSEvent.mouseLocation)
        }
        model.onMeterLevel = { [weak self] level in
            guard let self, !overlayWindows.isEmpty else { return }
            recordingToolbar?.updateMeter(level)
        }
        return RecordingReadyToolbar { [weak self] action in self?.recordingToolbarAction(action) }
    }

    /// Ready → the recording of the selection, in `mode` (nil: the last mode used, `RecordingReadyModel.mode`, which
    /// `recordingLastMode` keeps). Record Video and Record GIF give theirs; Return and the Record hotkey the last one.
    /// Nothing without a selection, or while picking a window.
    func startRecording(_ mode: RecordingMode?) {
        guard let model = recordingModel, !recordingPicksWindow, let selection = recordingSelection, selection.isAdjustable,
              let rect = selection.rect, let display = selection.display else { return }
        finish(.recording(RecordingPick(target: .area(rect, display), mode: mode ?? model.mode,
                                        startModifiers: selection.startModifiers)))
    }

    // MARK: Mouse

    func recordingMouseMoved(to point: CGPoint, flags: NSEvent.ModifierFlags) {
        modifiers = SelectionModifiers(flags)
        if recordingToolbar?.isEditing != true, let display = layout.display(containingMouse: point),
           let window = overlayWindows[display.id], !window.isKeyWindow {
            window.makeKey()
        }
        if recordingPicksWindow {
            hoveredWindow = WindowPicker.window(at: layout.cgPoint(fromAppKit: point), in: windows,
                                                excluding: recordingExcludedWindowIDs)
        }
        recordingRefresh(cursor: point)
    }

    func recordingMouseDown(at point: CGPoint, flags: NSEvent.ModifierFlags) {
        modifiers = SelectionModifiers(flags)
        // A click while a toolbar field edits commits it, and one while a list is open closes it; neither starts a drag.
        if recordingToolbar?.endInteraction() == true {
            recordingRefresh(cursor: point)
            return
        }
        if recordingPicksWindow {
            if let hoveredWindow { pickRecordingWindow(hoveredWindow) }
            return
        }
        recordingSelection?.mouseDown(at: point, modifiers: modifiers)
        recordingDraggingFresh = recordingSelection?.phase == .dragging
        recordingRefresh(cursor: point)
    }

    func recordingMouseDragged(to point: CGPoint, flags: NSEvent.ModifierFlags) {
        modifiers = SelectionModifiers(flags)
        recordingSelection?.mouseDragged(to: point, modifiers: modifiers)
        recordingRefresh(cursor: point)
    }

    func recordingMouseUp(at point: CGPoint, flags: NSEvent.ModifierFlags) {
        modifiers = SelectionModifiers(flags)
        recordingSelection?.mouseUp(at: point, modifiers: modifiers)
        recordingDraggingFresh = false
        recordingRefresh(cursor: point)
    }

    /// ClearShot's own windows are never offered, pins included; the rest as the overlay leaves them out.
    private var recordingExcludedWindowIDs: Set<UInt32> {
        excludedWindowIDs.union(windows.filter { $0.ownerBundleID == CSCore.bundleIdentifier }.map(\.id))
    }

    /// The window's frame becomes the selection, clamped to the display it is mostly on, and the overlay goes back to
    /// area mode: Ready on that frame, adjustable like any selection. The window's later moves aren't followed.
    private func pickRecordingWindow(_ window: WindowRecord) {
        let frame = layout.appKitRect(fromCG: window.frame)
        if let display = layout.display(bestMatching: frame) {
            recordingSelection?.setRect(frame.intersection(display.frame), onDisplay: display.id)
        }
        recordingPicksWindow = false
        hoveredWindow = nil
        recordingRefresh(cursor: NSEvent.mouseLocation)
    }

    // MARK: Keys

    func recordingKeyDown(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        switch event.keyCode {
        case 53: // Esc closes an open list first; the next one cancels.
            guard !event.isARepeat else { return }
            if recordingToolbar?.closeLists() == true { return }
            finish(.cancelled)
        case 36, 76: // Return, keypad Enter: the selection, or with none the pointer's display.
            guard !event.isARepeat else { return }
            if !recordingPicksWindow, recordingSelection?.isAdjustable == true {
                startRecording(nil)
            } else if let model = recordingModel {
                let display = layout.display(containingMouse: point) ?? layout.main
                finish(.recording(RecordingPick(target: .display(display), mode: model.mode, startModifiers: [])))
            }
        case 49: // Space moves a selection being dragged out; otherwise it switches between areas and windows.
            guard !event.isARepeat else { return }
            switch recordingSelection?.phase {
            case .dragging?:
                recordingSelection?.spaceDown(at: point)
                recordingRefresh(cursor: point)
            case .idle?, .adjusting?:
                recordingPicksWindow.toggle()
                hoveredWindow = nil
                recordingMouseMoved(to: point, flags: event.modifierFlags)
            default:
                break
            }
        case 123, 124, 125, 126:
            guard !recordingPicksWindow, recordingSelection?.phase == .adjusting else { return }
            let arrow: ArrowKey = switch event.keyCode {
            case 123: .left
            case 124: .right
            case 125: .down
            default: .up
            }
            recordingSelection?.arrow(arrow, modifiers: SelectionModifiers(event.modifierFlags))
            recordingRefresh(cursor: point)
        default:
            break
        }
    }

    func recordingKeyUp(_ event: NSEvent) {
        guard event.keyCode == 49 else { return }
        let point = NSEvent.mouseLocation
        recordingSelection?.spaceUp(at: point)
        recordingRefresh(cursor: point)
    }

    /// A modifier pressed or released mid-drag or mid-resize reshapes the selection at once (⇧, ⌥).
    func recordingFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        selectionFlagsChanged(flags, phase: recordingSelection?.phase) {
            recordingSelection?.mouseDragged(to: $0, modifiers: $1)
        }
    }

    // MARK: Drawing

    /// The Ready toolbar, the cursor and the selection with its handles, labels, crosshair and magnifier
    /// (`renderSelection`), with the prompt until there is a selection; while picking a window, the hovered window's
    /// highlight instead. Tells the model whether Ready has a selection to record.
    func recordingRefresh(cursor point: CGPoint) {
        guard let selection = recordingSelection, let model = recordingModel else { return }
        model.isReady = selection.isAdjustable && !recordingPicksWindow
        placeRecordingToolbar(model)
        let shown = recordingPicksWindow ? nil : selection
        selectionCursor(shown, at: point, overPanel: recordingToolbar?.contains(point) == true).set()
        let prompt: String? = if recordingPicksWindow {
            "Click a window to record it. Press Space to select an area."
        } else if selection.phase == .idle {
            "Drag to record a part of the screen. Press Space to select a window."
        } else {
            nil
        }
        let highlight = recordingPicksWindow ? hoveredWindow.map { layout.appKitRect(fromCG: $0.frame) } : nil
        renderSelection(shown, windowHighlight: highlight, prompt: prompt, cursor: point)
    }

    // MARK: Toolbar

    /// Under (or over, or inside) the selection on its display's overlay, while there is a selection that isn't being
    /// dragged out fresh; hidden while picking a window. The message slot shows a warning first (the lid, the
    /// microphone permission, low disk), else the encoder's note when it can't keep up with the frame rate
    /// (`RecordingReadyModel.message`).
    private func placeRecordingToolbar(_ model: RecordingReadyModel) {
        guard let toolbar = recordingToolbar else { return }
        guard !recordingPicksWindow,
              let anchor = toolbarAnchor(for: recordingSelection, draggingFresh: recordingDraggingFresh),
              let display = recordingSelection?.display else {
            toolbar.hide()
            return
        }
        toolbar.update(model: model, size: anchor.rect.size, isFullscreen: anchor.rect == display.frame,
                       message: model.message(for: .area(anchor.rect, display)))
        toolbar.show(attachedTo: anchor.window, selection: anchor.rect, visibleFrame: anchor.visibleFrame)
    }

    private func recordingToolbarAction(_ action: RecordingReadyToolbarAction) {
        guard !overlayWindows.isEmpty, let model = recordingModel else { return } // the session may have finished
        let point = NSEvent.mouseLocation
        switch action {
        case .record(let mode):
            startRecording(mode)
            return
        case .microphone(let id):
            model.chooseMicrophone(id)
        case .toggleSystemAudio:
            model.systemAudio.toggle()
        case .toggleHighlightClicks:
            model.highlightClicks.toggle()
        case let .size(width, height):
            recordingSelection?.setSize(width: width.map { CGFloat($0) }, height: height.map { CGFloat($0) })
        case .ratio(let ratio):
            model.ratio = ratio
            recordingSelection?.aspectRatio = ratio.aspect
            if recordingSelection?.isAdjustable == true { recordingSelection?.fitToAspectRatio() }
        case .toggleFullscreen:
            if var selection = recordingSelection {
                model.fullscreen.toggle(&selection)
                recordingSelection = selection
            }
        case .settings:
            model.opensSettings = true
            finish(.cancelled)
            return
        case .editingEnded:
            // The keys come back to the overlay, so a second Esc cancels the session.
            let display = recordingSelection?.display ?? layout.display(containingMouse: point) ?? layout.main
            overlayWindows[display.id]?.makeKey()
        }
        recordingRefresh(cursor: point)
    }
}
