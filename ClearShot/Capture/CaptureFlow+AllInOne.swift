import AppKit
import CSCapture
import CSCore

/// All-In-One: one overlay with an adjustable selection whose keys pick the capture, routed to the same steps as the
/// other modes.
extension CaptureFlow {
    /// `initial` is a URL's area to open on (`all-in-one` with x, y, width and height) instead of the remembered one.
    /// Opening on it doesn't remember it: only a command run on it may (`AllInOneCommand.remembersArea`).
    func allInOne(initial: SavedArea? = nil) async {
        await run { try await self.runAllInOne(initial: initial) }
    }

    private func runAllInOne(initial: SavedArea?) async throws {
        let remembered = initial
            ?? (preferences[Prefs.allInOneRememberSelection] ? preferences[Prefs.allInOneLastArea] : nil)
        let setup = AllInOneSetup(remembered: remembered, ratio: preferences[Prefs.allInOneRatio],
                                  saveRatio: { [preferences] in preferences[Prefs.allInOneRatio] = $0 })
        let selection = try await runOverlay(mode: .area, style: .allInOne(setup),
                                             frontmostApp: FrontmostApp.current(windows:))
        switch selection.outcome {
        case .cancelled, .area, .scrollingRegion, .recording:
            // All-In-One never confirms an area on mouse-up (`.area`); its keys run commands instead.
            return
        case let .window(record, modifiers):
            try await captureWindow(record, layout: selection.layout, modifiers: modifiers, override: nil)
        case let .allInOne(pick):
            try await perform(pick, in: selection)
        }
    }

    /// Remembers the area, then runs the command. The overlay has closed by now.
    private func perform(_ pick: AllInOnePick, in selection: Selection) async throws {
        if case let .area(rect, display) = pick.target {
            let area = SavedArea(rect: rect, displayID: display.id)
            if pick.command.remembersArea { preferences[Prefs.allInOneLastArea] = area }
            if pick.command.updatesLastCaptureArea { preferences[Prefs.lastCaptureArea] = area }
        }
        let layout = selection.layout
        switch (pick.command, pick.target) {
        case let (.captureArea, .area(rect, display)):
            let image = try await capturePickedArea(rect, on: display, in: selection, fromSnapshot: pick.frozen)
            // ⇧ skips the preset when held as the drag began or on the key; ⌃ on the key adds Copy.
            let shiftHeld = pick.startModifiers.union(pick.keyModifiers).contains(.shift)
            await finish(image: image, kind: .selection, display: display, layout: layout, globalRect: rect,
                         modifiers: pick.keyModifiers, shiftHeld: shiftHeld, override: nil, front: selection.front,
                         isTransparent: false)
        case let (.captureAndCopy, .area(rect, display)):
            let image = try await capturePickedArea(rect, on: display, in: selection, fromSnapshot: pick.frozen)
            await finish(image: image, kind: .selection, display: display, layout: layout, globalRect: rect,
                         modifiers: [], shiftHeld: pick.startModifiers.contains(.shift), override: .copy,
                         front: selection.front, isTransparent: false)
        case let (.captureAndCopy, .window(record)):
            try await captureWindow(record, layout: layout, modifiers: [], override: .copy)
        case let (.fullscreen, .display(display)):
            try await captureDisplays(from: display, in: selection, frozen: pick.frozen)
        case let (.selfTimer, .area(rect, display)):
            let seconds = preferences[Prefs.selfTimerSeconds]
            guard await countdown.run(seconds: seconds, on: display, preferences: preferences) else { return }
            let image = try await capturePickedArea(rect, on: display, in: selection, fromSnapshot: false,
                                                    showsCursor: preferences[Prefs.showCursorInScreenshots])
            // ⇧ held as the drag began skips the preset, as for the plain Self-Timer; ⇧ and ⌃ on T itself are ignored
            // (the key modifiers are read on A, Return and the Area button only).
            await finish(image: image, kind: .selection, display: display, layout: layout, globalRect: rect,
                         modifiers: [], shiftHeld: pick.startModifiers.contains(.shift), override: nil,
                         front: selection.front, isTransparent: false)
        case let (.text, .area(rect, display)):
            // As Capture Text: the clipboard only, never the router or history; the keys held on O are ignored.
            let image = try await capturePickedArea(rect, on: display, in: selection, fromSnapshot: pick.frozen)
            await presentText(image, keepLineBreaks: nil)
        case let (.scrolling, .area(rect, display)):
            // Ready on the same selection, named after the app in front as All-In-One began. ⇧ held as the selection's
            // drag began skips the preset, as for T, while Ready keeps that selection; ⇧ and ⌃ on S itself are ignored.
            try await runScrollingCapture(initial: (rect, display, pick.startModifiers), front: selection.front)
        case let (.record, .area(rect, display)):
            // Ready on the same selection, as S does, named after the app in front as All-In-One began.
            try await runRecording(initial: (rect, display, pick.startModifiers), front: selection.front)
        case (.record, .none):
            try await runRecording(initial: nil, front: selection.front)
        default:
            // The overlay pairs each command with its target, so this is a command without an arm.
            Log.capture.error("All-In-One has no route for \(pick.command.rawValue) on \(pick.target.name)")
            return
        }
    }

    /// F: the display (or every display with "Capture all displays" on), from the frozen picture when the overlay showed
    /// it, otherwise live once the overlay has left the screen, and then without the cursor whatever Show cursor says, as
    /// in the frozen picture.
    private func captureDisplays(from target: DisplayInfo, in selection: Selection, frozen: Bool) async throws {
        let layout = selection.layout
        let displays = preferences[Prefs.fullscreenCapturesAllDisplays] ? layout.displays : [target]
        if !frozen {
            try await Task.sleep(for: .milliseconds(40)) // let the overlay leave the screen
            willCapture()
        }
        for display in displays {
            let image: CGImage
            if frozen, let snapshot = selection.snapshots[display.id] {
                image = snapshot
            } else {
                image = try await service.captureDisplay(display, rules: exclusionRules(), showsCursor: false)
            }
            await finish(image: image, kind: .display, display: display, layout: layout, globalRect: display.frame,
                         modifiers: [], shiftHeld: false, override: nil, front: selection.front, isTransparent: false)
        }
    }
}

private extension AllInOnePick.Target {
    /// What kind of target it is, for the log.
    var name: String {
        switch self {
        case .area: "an area"
        case .window: "a window"
        case .display: "a display"
        case .none: "nothing"
        }
    }
}
