import AppKit
import CSCapture
import CSCore
import CSScrolling

/// Scrolling Capture: select a region, then scroll it by hand or with Auto-Scroll while the frames are stitched into
/// one tall (or wide) picture, which goes through the after-capture actions like any area capture. The whole session
/// runs inside `run`; the Start/Stop hotkey reaches it directly (`toggleScrollingCapture`).
extension CaptureFlow {
    func scrollingCapture() async {
        await run {
            try await self.runScrollingCapture(initial: nil, front: FrontmostApp.current(windows: WindowList.onScreen()))
        }
    }

    /// A URL's `scrolling-capture` with an area (AppKit global points, clamped to `display`): Ready on it (`start`
    /// nil), or capturing at once, by hand or with Auto-Scroll, with no overlay. Auto-Scroll still asks for
    /// Accessibility first (`confirmAutoScroll`).
    func scrollingCapture(at rect: CGRect, on display: DisplayInfo, start: ScrollingStart?) async {
        await run {
            let front = FrontmostApp.current(windows: WindowList.onScreen())
            guard let start else {
                try await self.runScrollingCapture(initial: (rect, display, []), front: front)
                return
            }
            try await self.runStartedScrollingCapture(region: rect, display: display, start: start, front: front)
        }
    }

    /// The Start/Stop Capturing hotkey: in Ready it starts a capture by hand, while capturing it is Done, and otherwise
    /// (no scrolling capture, no region yet, already finishing) it does nothing. Not through `run`, which a running
    /// scrolling capture holds.
    func toggleScrollingCapture() {
        switch scrollingControl.startStop() {
        case .start: activeOverlay?.startScrolling()
        case .finish: activeScrollingCapture?.finish()
        case .none: break
        }
    }

    /// Select and Ready on the overlay (starting in Ready on `initial`, with the keys held as it was dragged out), then
    /// the capture, then its picture through `finish`. `front` is the app in front as the capture began, for the file
    /// name and history. Runs inside `run`.
    func runScrollingCapture(initial: (rect: CGRect, display: DisplayInfo, startModifiers: SelectionModifiers)?,
                             front: FrontmostApp) async throws {
        scrollingControl = ScrollingControlState(phase: .selecting)
        defer {
            scrollingControl = ScrollingControlState()
            activeOverlay = nil
            activeScrollingCapture = nil
        }
        let style = OverlayStyle.scrollingSelection(initial: initial)
        let selection = try await runOverlay(mode: .area, style: style, configure: { session in
            session.onScrollingReadyChange = { [weak self] ready in self?.scrollingReadyChanged(ready) }
            session.opensScrollingTips = !self.preferences[Prefs.scrollingTipsShown]
            session.onScrollingTipsClosed = { [preferences] in preferences[Prefs.scrollingTipsShown] = true }
            self.activeOverlay = session
        })
        activeOverlay = nil
        // Between the overlay and the capture (the Auto-Scroll alert) the hotkey has nothing to act on.
        scrollingControl.phase = .none
        guard case let .scrollingRegion(region, display, requestedStart, startModifiers) = selection.outcome,
              let start = await confirmAutoScroll(requestedStart) else { return }
        try await captureScrolling(region: region, display: display, start: start, layout: selection.layout,
                                   startModifiers: startModifiers, front: front)
    }

    /// A URL's started scrolling capture: no Select or Ready, straight to the capture, as after Ready. Runs inside `run`.
    private func runStartedScrollingCapture(region: CGRect, display: DisplayInfo, start requestedStart: ScrollingStart,
                                            front: FrontmostApp) async throws {
        // Until the capture starts (the Auto-Scroll alert) the phase stays `.none`: the hotkey has nothing to act on.
        defer {
            scrollingControl = ScrollingControlState()
            activeScrollingCapture = nil
        }
        guard let start = await confirmAutoScroll(requestedStart) else { return }
        try await captureScrolling(region: region, display: display, start: start, layout: DisplayLayout.current(),
                                   startModifiers: [], front: front)
    }

    /// The capture itself, after Ready or from a URL: the frame, the stream and the stitching, with the Start/Stop
    /// hotkey's phases and `activeScrollingCapture` set for it, then the picture through `finish`.
    private func captureScrolling(region: CGRect, display: DisplayInfo, start: ScrollingStart, layout: DisplayLayout,
                                  startModifiers: SelectionModifiers, front: FrontmostApp) async throws {
        let capture = ScrollingCapture(preferences: preferences, permissions: permissions, layout: layout,
                                       region: region, display: display, start: start)
        capture.onEnding = { [weak self] in self?.scrollingControl.phase = .finishing }
        activeScrollingCapture = capture
        scrollingControl.phase = .capturing
        let result = try await capture.run()
        activeScrollingCapture = nil
        scrollingControl.phase = .none
        guard let result else { return }
        // Like any area capture (router, history, background preset, border, naming), but Capture Previous Area's area
        // stays. ⇧ held as the selection's drag began skips the preset: Ready's own drag, or All-In-One's while Ready
        // still has the selection it handed over (moved or resized, not dragged out afresh).
        await finish(image: result.image, kind: .selection, display: display, layout: layout,
                     globalRect: result.globalRect, modifiers: [], shiftHeld: startModifiers.contains(.shift),
                     override: nil, front: front, isTransparent: false)
    }

    /// The overlay reported its selection coming (Ready) or going (Select).
    private func scrollingReadyChanged(_ ready: Bool) {
        switch scrollingControl.phase {
        case .selecting, .ready: scrollingControl.phase = ready ? .ready : .selecting
        case .none, .capturing, .finishing: break
        }
    }

    /// Auto-Scroll posts scroll events, which needs Accessibility. Without it (neither `ScrollEventPoster.canPost` nor
    /// the permission), an alert offers to scroll by hand, which goes on with `.manual`, or to open System Settings, which
    /// ends the session (nil): Settings would open over the region, and the stream, which leaves out only ClearShot,
    /// would stitch it. Shown after the overlay has closed (it would sit under it) and before the capture's windows.
    private func confirmAutoScroll(_ start: ScrollingStart) async -> ScrollingStart? {
        guard case .auto = start, !ScrollEventPoster.canPost, permissions.status(of: .accessibility) != .granted else {
            return start
        }
        let alert = NSAlert()
        alert.messageText = "Auto-Scroll needs Accessibility permission"
        alert.informativeText = "Turn on ClearShot in System Settings › Privacy & Security › Accessibility, then start "
            + "the scrolling capture again. You can scroll by hand now."
        alert.addButton(withTitle: "Scroll by Hand")
        alert.addButton(withTitle: "Open System Settings")
        NSApp.activate()
        guard alert.runModal() == .alertSecondButtonReturn else { return .manual }
        await permissions.request(.accessibility)
        permissions.openSettings(for: .accessibility)
        return nil
    }
}
