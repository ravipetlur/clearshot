import AppKit
import CSCapture
import CSCore
import CSScrolling

/// How a scrolling capture starts: scrolled by hand, or by Auto-Scroll down (vertical) or to the right (horizontal).
enum ScrollingStart: Equatable {
    case manual, auto(ScrollAxis)
}

/// What the capture log counts over a scrolling capture.
private struct StitchLogTally {
    var frames = 0
    /// Frames the session dropped unseen (a newer one replaced them while waiting).
    var skipped = 0
    var accepted = 0
    var unmatched = 0
    /// The first frame of the current run with no verified match, while one runs.
    var unmatchedSince: Int?
    var slowestMilliseconds = 0.0
}

/// A scrolling capture's Capturing phase: the click-through frame over the region, the control bar and the live
/// preview; a region stream whose frames are stitched as they come; the cursor watch and, for Auto-Scroll, the driver.
/// It ends with Done, Return, the Start/Stop hotkey, the cap or the end of the page (`finish`: the picture), or with
/// Cancel or Esc (`cancel`: nothing).
final class ScrollingCapture {
    private enum Ending {
        case finish, cancel
    }

    private let preferences: Preferences
    private let permissions: PermissionCenter
    private let layout: DisplayLayout
    private let display: DisplayInfo
    private let start: ScrollingStart
    /// The region on whole pixels, as streamed.
    private let geometry: RegionStreamGeometry
    private let frameWindow: RegionFrameWindow
    private lazy var controlBar = ScrollingControlBar(size: initialOutputSize, onDone: { [weak self] in self?.finish() },
                                                      onCancel: { [weak self] in self?.cancel() })
    private let previewPanel = ScrollingPreviewPanel()
    private var driver: AutoScrollDriver?
    private var cursorWatch: Task<Void, Never>?
    private var hasRun = false
    private var windowsShown = false
    private var hasFirstFrame = false
    private var ending: Ending?
    private var endingContinuation: CheckedContinuation<Ending, Never>?
    /// Why the stream stopped by itself, if it did.
    private var streamError: (any Error)?
    /// What the capture log counts.
    private var tally = StitchLogTally()

    /// Runs once, as the capture starts to finish or is cancelled: the Start/Stop hotkey has nothing more to do.
    var onEnding: (() -> Void)?

    /// A capture of `region` (AppKit global points) on `display`, started by hand or with Auto-Scroll.
    init(preferences: Preferences, permissions: PermissionCenter, layout: DisplayLayout, region: CGRect,
         display: DisplayInfo, start: ScrollingStart) {
        self.preferences = preferences
        self.permissions = permissions
        self.layout = layout
        self.display = display
        self.start = start
        geometry = RegionStreamGeometry.make(region: region, display: display, layout: layout)
        frameWindow = RegionFrameWindow(display: display, region: geometry.globalRect,
                                        dims: preferences[Prefs.dimScreenWhileSelecting], prompt: Self.prompt)
    }

    /// Shows the frame, the control bar and the preview, streams and stitches the region until the capture ends, and
    /// returns the picture with the region it shows. Nil when cancelled or when no frame came; throws when the stream
    /// couldn't start, or stopped by itself before anything was stitched. Runs once.
    func run() async throws -> (image: CGImage, globalRect: CGRect)? {
        guard !hasRun else { return nil }
        hasRun = true
        showWindows()
        defer {
            stopCursorWatch()
            closeWindows()
        }
        let screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        defer { NotificationCenter.default.removeObserver(screens) }
        logStart()
        let session = makeSession()
        // Kept here until `stop` returns: nothing else holds it.
        let stream = makeStream(feeding: session)
        // The cursor goes back on every way out (Done, Cancel, Esc, the cap, the end of the page, a stream error).
        defer {
            driver?.stop()
            driver = nil
        }
        // After the windows: ClearShot needs a window on screen to be among the applications the stream leaves out.
        do {
            try await stream.start()
        } catch {
            session.cancel()
            guard ending != .cancel else { return nil }
            throw error
        }
        // `end` has stopped Auto-Scroll by now, so the cursor is back before the stream stops and the picture is composed.
        let howItEnded = await waitForEnding()
        await stream.stop()
        guard howItEnded == .finish else {
            session.cancel()
            return nil
        }
        guard let image = await session.finish() else {
            if let streamError { throw streamError }
            return nil
        }
        return (image, geometry.globalRect)
    }

    /// Done, Return, the Start/Stop hotkey, the cap, the end of the page: the capture ends with what was stitched.
    func finish() {
        end(.finish)
    }

    /// Cancel, Esc: the capture ends with nothing.
    func cancel() {
        end(.cancel)
    }

    // MARK: Ending

    private func end(_ how: Ending) {
        guard ending == nil else { return }
        ending = how
        logEnd(how)
        onEnding?()
        driver?.stop()
        driver = nil
        endingContinuation?.resume(returning: how)
        endingContinuation = nil
    }

    private func waitForEnding() async -> Ending {
        if let ending { return ending }
        return await withCheckedContinuation { endingContinuation = $0 }
    }

    // MARK: Stream and stitching

    private func makeSession() -> StitchSession {
        let scale = Double(display.scale)
        let fixedAxis: ScrollAxis? = if case .auto(let fixed) = start { fixed } else { nil }
        let configuration = StitchConfiguration(pixelsPerPoint: scale,
                                                outputScale: preferences[Prefs.scaleRetinaTo1x] ? 1 / scale : 1,
                                                axis: fixedAxis)
        let previewSide = Int((PreviewPlacement.width * display.scale).rounded())
        return StitchSession(stitcher: Stitcher(configuration: configuration), previewSide: previewSide,
                             onUpdate: Self.mainActorUpdates(to: self))
    }

    private func makeStream(feeding session: StitchSession) -> RegionStream {
        RegionStream(geometry: geometry, display: display, ownBundleID: CSCore.bundleIdentifier,
                     handler: Self.streamHandler(feeding: session, stoppedBy: self))
    }

    /// The session's updates, delivered on the main actor in the order they were made (`DispatchQueue.main` keeps it;
    /// separate tasks wouldn't). Made outside the main actor: it runs on the session's queue. It holds the capture, which
    /// never holds the session, so the two go when `run` ends.
    private nonisolated static func mainActorUpdates(to capture: ScrollingCapture)
        -> @Sendable (StitchUpdate, CGImage?) -> Void {
        { update, preview in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { capture.received(update, preview: preview) }
            }
        }
    }

    /// Frames go straight to the session on the stream's queue (their pixels moved, not copied; the session keeps at most
    /// one waiting, so memory stays bounded however fast they come); the stream's end goes to the capture on the main
    /// actor. Made outside the main actor: it runs on the stream's queues, under the stream's lock, so it never waits.
    private nonisolated static func streamHandler(feeding session: StitchSession, stoppedBy capture: ScrollingCapture)
        -> @Sendable (RegionStreamEvent) -> Void {
        { event in
            switch event {
            case .frame(let frame):
                session.submit(StitchFrame(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow,
                                           pixels: frame.pixels, colorSpace: frame.colorSpace))
            case .idle:
                break
            case .stopped(let error):
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { capture.streamStopped(error) }
                }
            }
        }
    }

    /// One frame stitched: the preview, the size and warnings, Auto-Scroll's tally, and the cap.
    private func received(_ update: StitchUpdate, preview: CGImage?) {
        guard windowsShown else { return }
        log(update)
        if let axis = update.axis { previewPanel.setAxis(axis) }
        if let preview { previewPanel.setImage(preview) }
        controlBar.show(size: update.outputSize, warnings: update.warnings, axis: update.axis)
        guard ending == nil else { return }
        if update.accepted, !hasFirstFrame {
            hasFirstFrame = true
            // Only now: a scroll posted before the first frame would leave the top of the page out.
            startAutoScrollIfAsked()
        }
        driver?.noteUpdate(update)
        if update.reachedLimit { finish() }
    }

    /// The stream ended by itself: the capture finishes with what was stitched (or `run` throws the error when nothing
    /// was).
    private func streamStopped(_ error: (any Error)?) {
        streamError = error
        finish()
    }

    /// A display was connected, unplugged, moved or rescaled: the frame, the stream, the cursor watch and Auto-Scroll's
    /// points may no longer match the screen. The capture ends as Done does once a frame is in, otherwise as Cancel.
    /// Notifications that change no display (the Dock moving, say) are ignored.
    private func screensChanged() {
        guard ending == nil, DisplayLayout.current() != layout else { return }
        Log.capture.info("The displays changed during a scrolling capture; \(hasFirstFrame ? "finishing" : "cancelling") it")
        if hasFirstFrame { finish() } else { cancel() }
    }

    // MARK: Capture log

    // Diagnostics for "Please slow down…": every stitched frame at debug level (Console with debug messages, or
    // `log stream --level debug --predicate 'subsystem == "<bundle identifier>"'`); the start, each run of frames with
    // no verified match (its first frame's trace) and the end at info level, so they reach clearshot.log too.

    private func logStart() {
        let how = switch start {
        case .manual: "by hand"
        case .auto(let axis): axis == .vertical ? "Auto-Scroll down" : "Auto-Scroll right"
        }
        Log.capture.info("Scrolling capture: region \(geometry.pixelWidth) × \(geometry.pixelHeight) px on \(display.name) "
            + "at \(display.scale)×, \(how), Scale Retina to 1x \(preferences[Prefs.scaleRetinaTo1x] ? "on" : "off")")
    }

    private func log(_ update: StitchUpdate) {
        tally.frames += 1
        let frame = tally.frames
        let trace = update.trace?.description ?? "no trace"
        tally.skipped += update.trace?.framesSkipped ?? 0
        tally.slowestMilliseconds = max(tally.slowestMilliseconds, update.trace?.milliseconds ?? 0)
        let verdict = update.accepted ? "accepted \(update.offset)" : update.noMatch ? "no match" : "not accepted"
        let warning = update.warnings.contains(.slowDown) ? " (slow down)" : ""
        Log.capture.debug("Scrolling frame \(frame): \(verdict)\(warning) | \(trace)")
        if update.accepted {
            tally.accepted += 1
            if let since = tally.unmatchedSince {
                Log.capture.info("Scrolling capture: frame \(frame) matched again, \(frame - since) frames after frame \(since)")
                tally.unmatchedSince = nil
            }
        } else if update.noMatch {
            tally.unmatched += 1
            if tally.unmatchedSince == nil {
                tally.unmatchedSince = frame
                Log.capture.info("Scrolling capture: no verified match from frame \(frame) (\(tally.accepted) accepted so far, "
                    + "pointer at \(pointerInRegion)): \(trace)")
            }
        }
    }

    private func logEnd(_ how: Ending) {
        let stuck = tally.unmatchedSince.map { ", none matched since frame \($0)" } ?? ""
        Log.capture.info("Scrolling capture \(how == .finish ? "finished" : "cancelled"): \(tally.frames) frames stitched, "
            + "\(tally.skipped) skipped unseen, \(tally.accepted) accepted, \(tally.unmatched) with no match\(stuck), "
            + "slowest \(Int(tally.slowestMilliseconds.rounded())) ms")
    }

    /// The pointer in the frames' pixels from the region's top left (hover effects follow it).
    private var pointerInRegion: String {
        let region = geometry.globalRect
        let location = NSEvent.mouseLocation
        let x = Int(((location.x - region.minX) * display.scale).rounded())
        let y = Int(((region.maxY - location.y) * display.scale).rounded())
        return "\(x), \(y) px"
    }

    // MARK: Auto-Scroll

    private func startAutoScrollIfAsked() {
        guard case .auto(let axis) = start, driver == nil, ending == nil else { return }
        // The capture flow asked for the permission before the capture; it may have been turned off since.
        guard ScrollEventPoster.canPost || permissions.status(of: .accessibility) == .granted else {
            Log.capture.warning("Auto-Scroll can't post scroll events (no Accessibility permission); scrolling by hand")
            controlBar.showNotice(Self.autoScrollStopped, for: .seconds(3))
            return
        }
        let driver = AutoScrollDriver(axis: axis, region: geometry.globalRect, layout: layout)
        self.driver = driver
        driver.start { [weak self] decision in self?.autoScrollEnded(decision) }
    }

    private static let autoScrollStopped = "Auto-Scroll stopped; scroll by hand"
    /// What the frame shows in the region while the pointer is outside it.
    private static let prompt = "Move the pointer here, then scroll"

    private func autoScrollEnded(_ decision: AutoScrollPlanner.Decision) {
        switch decision {
        case .finish:
            finish()
        case .stop:
            driver = nil
            controlBar.showNotice(Self.autoScrollStopped, for: .seconds(3))
        case .step, .scrollBack:
            break
        }
    }

    // MARK: Windows

    /// The size the file would have with no scrolling: the region in output pixels.
    private var initialOutputSize: CGSize {
        let scale = preferences[Prefs.scaleRetinaTo1x] ? 1 / display.scale : 1
        return CGSize(width: (CGFloat(geometry.pixelWidth) * scale).rounded(),
                      height: (CGFloat(geometry.pixelHeight) * scale).rounded())
    }

    /// The frame, then the control bar (key, for Return and Esc), then the preview; then the cursor watch.
    private func showWindows() {
        let region = geometry.globalRect
        let visibleFrame = display.visibleFrame
        frameWindow.showsPrompt = !Self.contains(region, NSEvent.mouseLocation)
        frameWindow.orderFrontRegardless()
        controlBar.show(attachedTo: frameWindow, region: region, visibleFrame: visibleFrame)
        let axis: ScrollAxis = if case .auto(let fixed) = start { fixed } else { .vertical }
        previewPanel.show(attachedTo: frameWindow, region: region, axis: axis, visibleFrame: visibleFrame)
        windowsShown = true
        startCursorWatch()
    }

    private func closeWindows() {
        guard windowsShown else { return }
        windowsShown = false
        previewPanel.hide()
        controlBar.hide()
        frameWindow.orderOut(nil)
    }

    /// Ten times a second: with the pointer outside the region the frame asks for it there and Auto-Scroll pauses; back
    /// inside, the prompt goes and Auto-Scroll goes on.
    private func startCursorWatch() {
        cursorWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let inside = Self.contains(self.geometry.globalRect, NSEvent.mouseLocation)
                self.frameWindow.showsPrompt = !inside
                self.driver?.setPaused(!inside)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopCursorWatch() {
        cursorWatch?.cancel()
        cursorWatch = nil
    }

    /// `NSEvent.mouseLocation` is in `rect`, counting its top row (`NSMouseInRect`'s rule for AppKit points).
    private static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        NSMouseInRect(point, rect, false)
    }
}
