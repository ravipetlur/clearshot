import AppKit
import CSAnnotation
import CSCapture
import CSCore
import CSRecording
import CSScrolling

/// Every screenshot mode and Record Screen, from the hotkey to the after-capture actions.
final class CaptureFlow {
    let preferences: Preferences
    let permissions: PermissionCenter
    let hud: HUDController
    let service: ScreenCaptureService
    let sounds: SoundPlayer
    /// Where recordings are written while they record (`Application Support/ClearShot/Recordings`).
    let recordingFolders: RecordingFolders
    /// Do Not Disturb while recording, through the user's two Shortcuts; shared with launch recovery.
    let focus: FocusController
    /// Shared with the editors (`BackgroundPictures`), so a Space change clears the desktop pictures both use.
    private let wallpapers: WallpaperProvider
    private let pictures: BackgroundPictures
    let router: AfterCaptureRouter
    /// Reads Capture Text's picture and puts its text on the clipboard (`presentText`).
    private let text: TextResultPresenter
    let countdown = CountdownController()
    /// `run` is running a capture or a recording (a recording's tail waits for it to end before its alerts).
    private(set) var isRunning = false
    /// Capture Text or All-In-One's O is presenting its own result: its overlay has closed, though the capture still runs.
    private var isPresentingText = false
    /// The window numbers of the pins on screen: captures keep pins and leave out every other ClearShot window.
    var pinWindowIDs: () -> Set<UInt32> = { [] }
    /// Whether Hide Desktop Icons is covering the desktop, so captures leave out the icons and widgets under the cover.
    var desktopIconsHidden: () -> Bool = { false }
    /// Runs as every capture starts, before anything is captured: pins hide their hover controls. A selected area taken
    /// live runs it again just before, since the pointer may have moved over a pin meanwhile (during a countdown, say).
    var willCapture: () -> Void = {}
    /// Where a running scrolling capture is (Select, Ready, capturing, finishing; `.none` without one), for the Start/Stop
    /// hotkey, which reaches it directly rather than through `run` (`toggleScrollingCapture`).
    var scrollingControl = ScrollingControlState()
    /// The scrolling capture's overlay while it is up (Select and Ready), and the capture itself while it captures.
    var activeOverlay: OverlaySession?
    var activeScrollingCapture: ScrollingCapture?
    /// The menu bar icon, which a recording turns into its Stop button (set in `AppCoordinator.start`).
    weak var statusItem: StatusItemController?
    /// Opens Settings at a pane (Ready's gear; set in `AppCoordinator.start`).
    var openSettings: (SettingsPane) -> Void = { _ in }
    /// Where a recording is (Select, Ready, the countdown, recording, paused, finishing; `.none` without one), for its
    /// three hotkeys, which reach it directly rather than through `run` (`recordingHotkey`).
    var recordingControl = RecordingControlState()
    /// The recording's overlay while it is up (Select and Ready), and the recording itself from its countdown to its stop.
    var activeRecordingOverlay: OverlaySession?
    var activeRecording: RecordingSession?
    /// A recording is past Ready: from its folder being made until its file has been routed.
    var recordingInProgress = false
    /// A recording's post-stop tail (the audio merge or the GIF conversion, then routing), which runs after `run` has
    /// returned, so screenshots can be taken meanwhile. Quitting waits for it, and recovery counts it as busy
    /// (`isIdle`).
    var recordingTail: Task<Void, Never>?
    /// The GIF conversion of a GIF recording's tail, while it runs: Record is refused with "Still creating a GIF", Stop
    /// (the status item, the progress panel) asks it, and quitting cancels it.
    var gifJob: GIFConversionJob?
    /// A GIF recording whose conversion a quit stopped; routed as a video if the quit is then cancelled. Its folder
    /// stays in Recordings meanwhile, for the next launch's recovery should the quit go ahead.
    var stoppedForQuit: RecordingResult?
    /// The tail is in a modal moment: the merge question, one of its alerts, or routing, which may show one. No capture
    /// starts meanwhile (`run` refuses, as it does while any app-modal session is up), so no overlay opens over a modal
    /// alert it couldn't take events from.
    var recordingTailIsModal = false
    /// The app is quitting: the recording finishes and is routed without any dialog.
    var isFinishingRecordingForQuit = false
    /// `finishRecordingForQuit` calls waiting for the recording to be routed.
    var recordingEndWaiters: [CheckedContinuation<Void, Never>] = []

    init(preferences: Preferences, permissions: PermissionCenter, hud: HUDController, router: AfterCaptureRouter,
         service: ScreenCaptureService, wallpapers: WallpaperProvider, pictures: BackgroundPictures,
         text: TextResultPresenter, sounds: SoundPlayer, folders: RecordingFolders, focus: FocusController) {
        self.preferences = preferences
        self.permissions = permissions
        self.hud = hud
        self.service = service
        self.sounds = sounds
        recordingFolders = folders
        self.focus = focus
        self.wallpapers = wallpapers
        self.pictures = pictures
        self.router = router
        self.text = text
    }

    /// A capture is under way, other than one presenting its own text: its overlay, countdown or capture may be on screen.
    /// Extract Text, which runs beside captures, keeps its link prompt back then (`TextResultPresenter.isCapturing`).
    var isCapturing: Bool { isRunning && !isPresentingText }

    /// No capture or recording is under way: no overlay, countdown, recording, capture of any kind or recording's tail
    /// (the merge question and the merge, or the GIF conversion and its Stop question), so a modal alert can't open
    /// under ClearShot's windows or over the tail's question (launch recovery waits for this).
    var isIdle: Bool { !isRunning && recordingTail == nil }

    /// Where the flow is, for the one modal policy (`ModalGate`): capturing (`isCapturing`), idle (`isIdle`), or
    /// finishing in between (a recording's tail, or Capture Text presenting its result).
    var modalFlowState: ModalPolicy.FlowState {
        isCapturing ? .capturing : isIdle ? .idle : .finishing
    }

    // MARK: Entry points

    func captureArea(override: CaptureOverride? = nil) async {
        await run { try await self.select(mode: .area, override: override, timerSeconds: nil) }
    }

    /// `override` is a URL command's `action=` (hotkeys and the menu pass none), here and in the three below.
    func captureWindow(override: CaptureOverride? = nil) async {
        await run { try await self.select(mode: .window, override: override, timerSeconds: nil) }
    }

    func selfTimer(override: CaptureOverride? = nil) async {
        await run {
            try await self.select(mode: .area, override: override, timerSeconds: self.preferences[Prefs.selfTimerSeconds])
        }
    }

    func capturePreviousArea(override: CaptureOverride? = nil) async {
        await run {
            let layout = DisplayLayout.current()
            guard case let (rect, display)? = self.preferences[Prefs.lastCaptureArea].resolved(in: layout) else {
                self.hud.show("No previous area yet", symbol: "rectangle.dashed")
                return
            }
            try await self.captureAreaNow(rect, on: display, layout: layout, override: override)
        }
    }

    /// A URL's `capture-area` with an area (AppKit global points, clamped to `display`): taken at once with no overlay,
    /// as Capture Previous Area takes its area, and remembered for Capture Previous Area, as an area capture is.
    func captureArea(at rect: CGRect, on display: DisplayInfo, override: CaptureOverride?) async {
        await run {
            self.preferences[Prefs.lastCaptureArea] = SavedArea(rect: rect, displayID: display.id)
            try await self.captureAreaNow(rect, on: display, layout: DisplayLayout.current(), override: override)
        }
    }

    func captureFullscreen(override: CaptureOverride? = nil) async {
        await run {
            let layout = DisplayLayout.current()
            let windows = WindowList.onScreen()
            let front = FrontmostApp.current(windows: windows)
            let displays = self.preferences[Prefs.fullscreenCapturesAllDisplays]
                ? layout.displays
                : [layout.display(containingMouse: NSEvent.mouseLocation) ?? layout.main]
            for display in displays {
                let image = try await self.service.captureDisplay(display, rules: self.exclusionRules(),
                                                                  showsCursor: self.preferences[Prefs.showCursorInScreenshots])
                // No modifiers: the keys held now belong to the hotkey, not to the ⌃ for Copy or ⇧ to skip the preset.
                await self.finish(image: image, kind: .display, display: display, layout: layout, globalRect: display.frame,
                                  modifiers: [], shiftHeld: false, override: override, front: front, isTransparent: false)
            }
        }
    }

    /// An area taken at once, with no overlay and no cursor: Capture Previous Area's, and a URL's. Runs inside `run`.
    private func captureAreaNow(_ rect: CGRect, on display: DisplayInfo, layout: DisplayLayout,
                                override: CaptureOverride?) async throws {
        let windows = WindowList.onScreen()
        let front = FrontmostApp.current(windows: windows)
        let image = try await service.captureArea(layout.localRect(rect, in: display), on: display,
                                                  rules: exclusionRules(), showsCursor: false)
        // No modifiers: the keys held now belong to the hotkey, not to the ⌃ for Copy or ⇧ to skip the preset.
        await finish(image: image, kind: .selection, display: display, layout: layout, globalRect: rect,
                     modifiers: [], shiftHeld: false, override: override, front: front, isTransparent: false)
    }

    func spaceDidChange() {
        if preferences[Prefs.updateWallpaperOnSpaceChange] { wallpapers.invalidate() }
    }

    // MARK: Annotate's Take Screenshot

    /// An area, or a window if the person switches to window selection, for Annotate's Add Image › Take Screenshot: the
    /// picture and its pixels per point. It is post-processed like any capture (Retina to 1x, sRGB) but runs none of the
    /// after-capture actions and makes no history item. Nil when the selection is cancelled, another capture is running,
    /// or the capture failed (which is shown, as for any capture).
    ///
    /// `beforeSelecting` runs once the capture is allowed to start (none is running, screen recording is allowed) and just
    /// before the selection begins: the editor steps aside there, so a refusal is not shown over a window that has gone.
    func captureImageForEditor(beforeSelecting: @escaping @MainActor () -> Void) async -> (image: CGImage, scale: Double)? {
        var picked: (image: CGImage, scale: Double)?
        await run {
            beforeSelecting()
            picked = try await self.selectImageForEditor()
        }
        return picked
    }

    private func selectImageForEditor() async throws -> (image: CGImage, scale: Double)? {
        guard let picked = try await selectImage() else { return nil }
        let raw = picked.image
        let processing = PostProcessOptions(scaleTo1x: preferences[Prefs.scaleRetinaTo1x], convertToSRGB: preferences[Prefs.convertToSRGB])
        let scale = picked.display.scale
        let image = await Task.detached(priority: .userInitiated) {
            PostProcessor.apply(raw, scale: scale, options: processing)
        }.value
        return (image, processing.scaleTo1x ? 1 : Double(scale))
    }

    // MARK: Shared steps

    /// Runs the `.capture` overlay in area mode (Space picks a window, F freezes) and returns the pixels of what the person
    /// picked, as taken, with the display they come from: an area cut from the frozen picture when the overlay froze, a
    /// window by itself. Nil when the selection is cancelled. Annotate's Take Screenshot and Capture Text use it.
    func selectImage() async throws -> (image: CGImage, display: DisplayInfo)? {
        let selection = try await runOverlay(mode: .area)
        switch selection.outcome {
        case .cancelled, .allInOne, .scrollingRegion, .recording: // the `.capture` style picks only areas and windows
            return nil
        case let .area(rect, display, frozen, _, _):
            return (try await capturePickedArea(rect, on: display, in: selection, fromSnapshot: frozen), display)
        case let .window(record, _):
            let shot = try await capturePickedWindow(record, layout: selection.layout)
            return (shot.image, shot.display)
        }
    }

    /// Recognizes the picture and presents its text, for Capture Text and All-In-One's O once their overlay has closed. It
    /// doesn't count as capturing meanwhile (`isCapturing`), so its own link prompt can show.
    func presentText(_ image: CGImage, keepLineBreaks: Bool?) async {
        isPresentingText = true
        defer { isPresentingText = false }
        await text.recognizeAndPresent(image, keepLineBreaks: keepLineBreaks)
    }

    func run(_ body: @escaping () async throws -> Void) async {
        // Any app-modal alert or panel is up (recovery's, a thumbnail's question, a Save panel, the tail's merge question)
        // or the tail is in a modal moment: an overlay would open over it, unusable. The alert comes forward instead.
        guard !ModalPolicy.refusesCapture(isRunning: isRunning, tailIsModal: recordingTailIsModal,
                                          appModalIsUp: NSApp.modalWindow != nil) else {
            hud.show("A capture is already in progress", symbol: "hourglass")
            NSApp.modalWindow?.orderFrontRegardless()
            URLCommandContext.logRefusal("A capture is already in progress")
            return
        }
        // Running from here on, so a hotkey pressed while the permission alert is up doesn't stack a second one.
        isRunning = true
        defer { isRunning = false }
        guard ensurePermission() else { return }
        willCapture()
        do {
            // The capture has started: what it does from here isn't a URL command's refusal (`URLCommandContext`).
            try await URLCommandContext.$label.withValue(nil) { try await body() }
        } catch {
            Log.capture.error("Capture failed: \(error)")
            show(error)
        }
    }

    /// What the overlay returned, with the setup it ran on: shared by every capture that selects on screen.
    struct Selection {
        let outcome: OverlayOutcome
        let layout: DisplayLayout
        /// The app in front when the selection began, before the overlay took the screen; `.none` when the caller didn't ask.
        let front: FrontmostApp
        let rules: ExclusionRules
        /// The frozen picture of each display, by display id.
        let snapshots: [UInt32: CGImage]
    }

    /// Takes a snapshot of every display, runs the selection overlay in `mode` and `style` and returns what the person
    /// picked. `frontmostApp` reads the app in front from the window list, before the snapshot and the overlay; only a
    /// capture that names its file after it asks. `configure` gets the session just before it appears.
    func runOverlay(mode: OverlayMode, style: OverlayStyle = .capture,
                    frontmostApp: ([WindowRecord]) -> FrontmostApp = { _ in .none },
                    configure: (OverlaySession) -> Void = { _ in }) async throws -> Selection {
        let layout = DisplayLayout.current()
        let windows = WindowList.onScreen()
        let front = frontmostApp(windows)
        let rules = exclusionRules()
        let snapshots = try await service.snapshot(displays: layout.displays, rules: rules, showsCursor: false)
        let images = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.display.id, $0.image) })
        let options = OverlayOptions(freeze: preferences[Prefs.freezeScreen], crosshair: preferences[Prefs.crosshairMode],
                                     showMagnifier: preferences[Prefs.showMagnifier], dim: preferences[Prefs.dimScreenWhileSelecting])
        let session = OverlaySession(layout: layout, snapshots: images, windows: windows,
                                     excludedWindowIDs: rules.excludedWindowIDs(from: windows), options: options, mode: mode,
                                     style: style)
        configure(session)
        return Selection(outcome: await session.run(), layout: layout, front: front, rules: rules, snapshots: images)
    }

    /// The pixels of an area the person chose: cut from the frozen snapshot when the overlay froze the screen (and
    /// `fromSnapshot` allows it), otherwise captured live once the overlay has left the screen.
    func capturePickedArea(_ rect: CGRect, on display: DisplayInfo, in selection: Selection, fromSnapshot: Bool,
                           showsCursor: Bool = false) async throws -> CGImage {
        let layout = selection.layout
        if fromSnapshot, let snapshot = selection.snapshots[display.id],
           let cropped = PostProcessor.cropped(snapshot, to: layout.pixelRect(rect, in: display)) {
            return cropped
        }
        try await Task.sleep(for: .milliseconds(40)) // let the overlay leave the screen
        willCapture()
        return try await service.captureArea(layout.localRect(rect, in: display), on: display, rules: selection.rules,
                                             showsCursor: showsCursor)
    }

    /// The pixels of a window the person chose, with the frame it has on screen and the display it is mostly on.
    func capturePickedWindow(_ record: WindowRecord, layout: DisplayLayout) async throws
        -> (image: CGImage, frame: CGRect, display: DisplayInfo) {
        let image = try await service.captureWindow(id: record.id, includeShadow: preferences[Prefs.captureWindowShadow])
        let frame = layout.appKitRect(fromCG: record.frame)
        return (image, frame, layout.display(bestMatching: frame) ?? layout.main)
    }

    private func select(mode: OverlayMode, override: CaptureOverride?, timerSeconds: Int?) async throws {
        let selection = try await runOverlay(mode: mode, frontmostApp: FrontmostApp.current(windows:))
        let layout = selection.layout
        switch selection.outcome {
        case .cancelled, .allInOne, .scrollingRegion, .recording: // the `.capture` style picks only areas and windows
            return
        case let .area(rect, display, frozen, modifiers, startModifiers):
            preferences[Prefs.lastCaptureArea] = SavedArea(rect: rect, displayID: display.id)
            if let timerSeconds {
                guard await countdown.run(seconds: timerSeconds, on: display, preferences: preferences) else { return }
            }
            let showsCursor = timerSeconds != nil && preferences[Prefs.showCursorInScreenshots]
            let image = try await capturePickedArea(rect, on: display, in: selection, fromSnapshot: frozen && timerSeconds == nil,
                                                    showsCursor: showsCursor)
            // ⇧ skips the preset only when held as the drag began: one pressed during it squares the selection.
            await finish(image: image, kind: .selection, display: display, layout: layout, globalRect: rect,
                         modifiers: modifiers, shiftHeld: startModifiers.contains(.shift), override: override,
                         front: selection.front, isTransparent: false)
        case let .window(record, modifiers):
            try await captureWindow(record, layout: layout, modifiers: modifiers, override: override)
        }
    }

    /// A window shot is the transparent window image (with its shadow when the window-shadow setting is on); its
    /// wallpaper, if it gets one, is a background around it, which `finish` resolves.
    func captureWindow(_ record: WindowRecord, layout: DisplayLayout, modifiers: SelectionModifiers,
                       override: CaptureOverride?) async throws {
        let shot = try await capturePickedWindow(record, layout: layout)
        let front = FrontmostApp(name: record.ownerName, bundleID: record.ownerBundleID, windowTitle: record.title,
                                 windowFrames: [])
        await finish(image: shot.image, kind: .window, display: shot.display, layout: layout, globalRect: shot.frame,
                     modifiers: modifiers, shiftHeld: modifiers.contains(.shift), override: override, front: front,
                     isTransparent: true, window: record)
    }

    /// Resolves the capture's background and reads the post-processing preferences here, on the main actor; the router
    /// runs the processing and makes the document itself off it. `modifiers` are the keys held as the selection ended
    /// (⌃ adds Copy); `shiftHeld` is the ⇧ that skips the background preset (`background(for:…)`): as an area's drag
    /// began, or at a window's click. `window` is a window shot's record (nil for any other capture), which its
    /// wallpaper is cropped around.
    func finish(image raw: CGImage, kind: CaptureKind, display: DisplayInfo, layout: DisplayLayout, globalRect: CGRect,
                modifiers: SelectionModifiers, shiftHeld: Bool, override: CaptureOverride?, front: FrontmostApp,
                isTransparent: Bool, window: WindowRecord? = nil) async {
        let background = await self.background(for: raw, display: display, layout: layout, shiftHeld: shiftHeld,
                                               window: window)
        let notch = NotchCrop.pixels(for: display, kind: kind, frontmostAppWindowFrames: front.windowFrames,
                                     displayCGFrame: layout.cgRect(fromAppKit: display.frame))
        // No border around a background: it would frame the backdrop, not the screenshot.
        let options = PostProcessOptions(scaleTo1x: preferences[Prefs.scaleRetinaTo1x],
                                         convertToSRGB: preferences[Prefs.convertToSRGB],
                                         addBorder: preferences[Prefs.addBorderToScreenshots] && !isTransparent && background == nil,
                                         cropTopPixels: notch)
        let capture = RawCapture(image: raw, displayScale: display.scale, processing: options, kind: kind,
                                 displayID: display.id, globalRect: globalRect, appName: front.name,
                                 appBundleID: front.bundleID, windowTitle: front.windowTitle, isTransparent: isTransparent,
                                 background: background, isWindowShot: kind == .window)
        var actions = actions(for: override)
        if modifiers.contains(.control) { actions.insert(.copy) } // ⌃ adds Copy
        await router.route(capture, actions: actions, override: override)
    }

    // MARK: Backgrounds

    /// The background a capture gets, with its picture resolved for `display`, or nil for none. Screenshots get the
    /// screenshot preset, windows the window preset or else their own wallpaper (`AutoApply.choice`); `shiftHeld` skips
    /// the preset, or without a window preset switches a window between wallpaper and transparent. A window's own
    /// wallpaper that can't be read gives no background: the window stays transparent, as it always has.
    ///
    /// `image` is the capture as taken and `window` a window shot's record: a window wallpaper is cropped around them.
    private func background(for image: CGImage, display: DisplayInfo, layout: DisplayLayout, shiftHeld: Bool,
                            window: WindowRecord?) async -> CaptureBackground? {
        let presets = AutoApply.presets(in: preferences)
        let choice = AutoApply.choice(isWindow: window != nil, shiftHeld: shiftHeld, screenshotPreset: presets.screenshot,
                                      windowPreset: presets.window, windowMode: preferences[Prefs.windowBackground])
        switch choice {
        case .none:
            return nil
        case .preset(let presetStyle):
            var style = presetStyle.clamped()
            guard let window, style.fill == .windowWallpaper else {
                return CaptureBackground(style: style, picture: await pictures.picture(for: style.fill, display: display,
                                                                                      layout: layout))
            }
            // A window preset's captured wallpaper is the one behind this window. Without it the document takes the first
            // gradient instead (`CaptureDocument.make`), which the router logs.
            let wallpaper = await windowWallpaper(behind: window, image: image, display: display, layout: layout,
                                                  paddingPoints: style.padding + style.inset)
            if let wallpaper { style.fill = wallpaper.fill }
            return CaptureBackground(style: style, picture: wallpaper?.picture)
        case .windowWallpaper:
            guard let window else { return nil }
            var style = BackgroundStyle.windowStandard
            style.padding = Double(preferences[Prefs.windowPadding])
            style = style.clamped()
            guard let wallpaper = await windowWallpaper(behind: window, image: image, display: display, layout: layout,
                                                        paddingPoints: style.padding + style.inset) else { return nil }
            style.fill = wallpaper.fill
            return CaptureBackground(style: style, picture: wallpaper.picture)
        }
    }

    /// The window's own wallpaper, for a frame reaching `paddingPoints` past the window image on every side: the plain
    /// colour as a colour fill, or the captured wallpaper fill with the part of the desktop or custom wallpaper behind
    /// that frame. Nil when the wallpaper can't be read.
    private func windowWallpaper(behind record: WindowRecord, image: CGImage, display: DisplayInfo, layout: DisplayLayout,
                                 paddingPoints: Double) async -> (fill: BackgroundFill, picture: CGImage?)? {
        let source = preferences[Prefs.wallpaperSource]
        if source == .plainColor {
            let color = RGBAColor(hex: preferences[Prefs.wallpaperPlainColor]) ?? RGBAColor(red: 0.12, green: 0.12, blue: 0.12)
            return (.color(color), nil)
        }
        guard let wallpaper = await wallpapers.image(for: display, layout: layout, source: source,
                                                     customPath: preferences[Prefs.customWallpaperPath],
                                                     plainColorHex: preferences[Prefs.wallpaperPlainColor]) else { return nil }
        let paddingPoints = CGFloat(paddingPoints)
        // The captured image can be larger than the frame (the shadow), so center the canvas on the window.
        let imagePoints = CGSize(width: CGFloat(image.width) / display.scale, height: CGFloat(image.height) / display.scale)
        let canvas = CGRect(x: record.frame.midX - imagePoints.width / 2 - paddingPoints,
                            y: record.frame.midY - imagePoints.height / 2 - paddingPoints,
                            width: imagePoints.width + paddingPoints * 2,
                            height: imagePoints.height + paddingPoints * 2)
        let crop = WallpaperProvider.crop(wallpaper, displayCGFrame: layout.cgRect(fromAppKit: display.frame), to: canvas)
            ?? wallpaper
        return (.windowWallpaper, crop)
    }

    private func actions(for override: CaptureOverride?) -> Set<AfterCaptureAction> {
        var defaults = preferences[Prefs.afterScreenshotActions]
        if defaults.isEmpty { defaults = Prefs.afterScreenshotActions.defaultValue }
        guard let override else { return defaults }
        let requested: Set<AfterCaptureAction> = switch override {
        case .copy: [.copy]
        case .save: [.save]
        case .annotate: [.openEditor]
        case .pin: [.pin]
        case .raycast: []
        }
        return preferences[Prefs.captureAreaShortcutsIgnoreAfterCapture] ? requested : defaults.union(requested)
    }

    /// Read as each capture is taken, so a pin made or closed since the last one counts.
    func exclusionRules() -> ExclusionRules {
        ExclusionRules.forCapture(ownBundleID: CSCore.bundleIdentifier, pinWindowIDs: pinWindowIDs(),
                                  hideDesktopIconsSetting: preferences[Prefs.hideDesktopIconsWhileCapturing],
                                  desktopIconsHidden: desktopIconsHidden())
    }

    private func ensurePermission() -> Bool {
        guard permissions.status(of: .screenRecording) != .granted else { return true }
        Task { await permissions.request(.screenRecording) }
        show(CaptureError.permissionDenied)
        return false
    }

    func show(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = (error as? LocalizedError)?.errorDescription ?? "The screenshot couldn't be taken"
        alert.informativeText = (error as? LocalizedError)?.recoverySuggestion ?? error.localizedDescription
        if (error as? CaptureError) == .permissionDenied {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn, (error as? CaptureError) == .permissionDenied {
            permissions.openSettings(for: .screenRecording)
        }
    }
}
