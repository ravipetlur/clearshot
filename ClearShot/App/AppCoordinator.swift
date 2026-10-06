import AppKit
import CSAnnotation
import CSCapture
import CSCore
import CSHistory
import CSOCR
import CSRecording

/// Owns everything long-lived and routes every action.
final class AppCoordinator {
    let preferences: Preferences
    let permissions: PermissionCenter
    let hud: HUDController
    let sounds: SoundPlayer
    let captureFlow: CaptureFlow
    let history: HistoryStore
    let itemActions: HistoryItemActions
    let quickAccess: QuickAccessManager
    let annotate: AnnotateManager
    let videoEditor: VideoEditorManager
    let pins: PinManager
    let importer: ImageImporter
    let desktopIcons: DesktopIcons
    /// Kept for launch recovery, which routes what it recovers.
    let router: AfterCaptureRouter
    let recordingFolders: RecordingFolders
    /// Do Not Disturb through the user's two Shortcuts, for recordings, launch recovery and Settings' check.
    let focus: FocusController
    /// The one modal policy's app side; URL commands' choosers ask it too.
    let gate: ModalGate
    /// Reads text in pictures for Capture Text, All-In-One's O, Extract Text and `capture-text?filepath=`.
    let text: TextResultPresenter
    /// The one wallpaper provider window shots, editors and the desktop covers share; it drops its desktop pictures when
    /// macOS says the desktop picture changed.
    private let wallpapers: WallpaperProvider
    private var historyPurge: Task<Void, Never>?
    private(set) var statusItem: StatusItemController?
    /// Runs `clearshot://` commands; made in `start(activation:)`, before the receiver hands any over.
    private(set) var urlCommands: URLCommandRouter?
    /// The URL scheme API's consent, in the Keychain: the router and Settings › Advanced read and write it.
    let consentStore = KeychainConsentStore()
    private let hotkeys = HotkeyController()
    private var settingsWindow: SettingsWindowController?
    private var historyWindow: HistoryWindowController?
    private var onboardingWindow: OnboardingWindowController?

    init(preferences: Preferences) {
        let permissions = PermissionCenter()
        let hud = HUDController()
        let sounds = SoundPlayer(preferences: preferences)
        // The one modal policy (`ModalPolicy`): what the thumbnails, pins, hotkeys, the status menu and ClearShot's own
        // alerts may show while a capture or recording is under way. It reads the capture flow, made below.
        let gate = ModalGate(hud: hud)
        // Capture Text, All-In-One's O and Extract Text share one presenter for the clipboard, HUDs, sound and link prompt.
        let text = TextResultPresenter(preferences: preferences, hud: hud, sounds: sounds, gate: gate)
        let history = HistoryStore()
        // One capture service and one wallpaper provider (its desktop pictures cached per display) for captures and editors.
        let service = ScreenCaptureService()
        let wallpapers = WallpaperProvider(capture: service)
        let pictures = BackgroundPictures(wallpapers: wallpapers,
                                          library: BackgroundLibrary(directory: BackgroundLibrary.defaultDirectory))
        let itemActions = HistoryItemActions(preferences: preferences, history: history, hud: hud, text: text, gate: gate)
        let quickAccess = QuickAccessManager(preferences: preferences, history: history, actions: itemActions, hud: hud,
                                             gate: gate)
        let importer = ImageImporter(preferences: preferences, history: history, quickAccess: quickAccess, hud: hud,
                                     gate: gate)
        let pins = PinManager(preferences: preferences, history: history, actions: itemActions, importer: importer, hud: hud,
                              gate: gate)
        quickAccess.onPin = { [weak pins] item in pins?.pin(item, anchor: .activeScreen) ?? false }
        // Annotate's windows and the Video Editor's decide the Dock icon together.
        let documents = DocumentWindows(preferences: preferences)
        let annotate = AnnotateManager(preferences: preferences, history: history, quickAccess: quickAccess, pins: pins,
                                       hud: hud, pictures: pictures, documents: documents, gate: gate)
        quickAccess.onAnnotate = { [weak annotate] item in annotate?.open(item) }
        pins.onAnnotate = { [weak annotate] item in annotate?.open(item) }
        let videoEditor = VideoEditorManager(preferences: preferences, history: history, quickAccess: quickAccess, hud: hud,
                                             documents: documents, gate: gate)
        quickAccess.onEditVideo = { [weak videoEditor] item, startsTrimming in
            videoEditor?.open(item, startsTrimming: startsTrimming)
        }
        let recordingFolders = RecordingFolders(root: RecordingFolders.defaultRoot)
        let router = AfterCaptureRouter(preferences: preferences, hud: hud, sounds: sounds, history: history,
                                        itemActions: itemActions, quickAccess: quickAccess, annotate: annotate,
                                        videoEditor: videoEditor, pins: pins, recordingFolders: recordingFolders,
                                        gate: gate)
        let focus = FocusController(runner: SystemShortcutRunner(), hud: hud)
        let captureFlow = CaptureFlow(preferences: preferences, permissions: permissions, hud: hud, router: router,
                                      service: service, wallpapers: wallpapers, pictures: pictures, text: text,
                                      sounds: sounds, folders: recordingFolders, focus: focus)
        // Extract Text holds its link prompt back while a capture is under way: the prompt would open under the overlay.
        text.isCapturing = { [weak captureFlow] in captureFlow?.isCapturing ?? false }
        gate.flowState = { [weak captureFlow] in captureFlow?.modalFlowState ?? .idle }
        gate.recordingOnScreen = { [weak captureFlow] in captureFlow?.isRecordingOnScreen ?? false }
        // Captures keep pins, and pins hide their hover controls as a capture starts.
        captureFlow.pinWindowIDs = { [weak pins] in pins?.windowNumbers ?? [] }
        captureFlow.willCapture = { [weak pins] in pins?.prepareForCapture() }
        // The desktop covers show the same wallpapers as window shots; while they are up, captures leave out the icons
        // and widgets under them.
        let desktopIcons = DesktopIcons(preferences: preferences, wallpapers: wallpapers, hud: hud, gate: gate)
        captureFlow.desktopIconsHidden = { [weak desktopIcons] in desktopIcons?.isHidden ?? false }
        self.preferences = preferences
        self.permissions = permissions
        self.hud = hud
        self.sounds = sounds
        self.history = history
        self.itemActions = itemActions
        self.quickAccess = quickAccess
        self.annotate = annotate
        self.videoEditor = videoEditor
        self.pins = pins
        self.importer = importer
        self.desktopIcons = desktopIcons
        self.router = router
        self.recordingFolders = recordingFolders
        self.focus = focus
        self.gate = gate
        self.text = text
        self.wallpapers = wallpapers
        self.captureFlow = captureFlow
        annotate.captureImage = { [weak self] beforeSelecting in
            await self?.captureFlow.captureImageForEditor(beforeSelecting: beforeSelecting)
        }
        // Whatever shows or works on a capture holds it; each release may leave one that "Never" no longer keeps. The
        // store keeps these closures for good, so they capture the coordinator weakly.
        history.holds.onRelease = { [weak self] _ in self?.purgeIfNever() }
        history.observe { [weak self] change in self?.historyChanged(change) }
    }

    /// `activation` hands the activation back before URL commands that capture (`ActivationHandBack`).
    func start(activation: ActivationHandBack) {
        urlCommands = URLCommandRouter(coordinator: self, activation: activation)
        let statusItem = StatusItemController(coordinator: self)
        statusItem.isVisible = preferences[Prefs.showMenuBarIcon]
        self.statusItem = statusItem
        // A recording turns the icon into its Stop button, with Resume beside it while paused and "Creating GIF…" while
        // a GIF converts.
        captureFlow.statusItem = statusItem
        statusItem.onStopClicked = { [weak self] in self?.captureFlow.stopRecording() }
        statusItem.onResumeClicked = { [weak self] in self?.captureFlow.resumeRecording() }
        statusItem.onConversionClicked = { [weak self] in self?.captureFlow.requestGIFStop() }
        // A quit the editors cancel late (after a GIF's conversion stopped for it) lets the recording be saved now.
        annotate.onQuitCancelled = { [weak self] in self?.captureFlow.quitWasCancelled() }
        videoEditor.onQuitCancelled = { [weak self] in self?.captureFlow.quitWasCancelled() }
        captureFlow.openSettings = { [weak self] pane in self?.showSettings(pane) }
        hotkeys.register { [weak self] action in self?.perform(action) }
        let taken = SystemShortcutCheck.actionsTakenBySystem()
        if !taken.isEmpty {
            Log.hotkeys.warning("macOS also uses \(SystemShortcutCheck.describe(taken))")
        }
        // A shortcut another app already holds can't be registered, and would otherwise never fire without a word.
        let unregistered = HotkeyController.actionsWithUnregisteredShortcuts()
        if !unregistered.isEmpty {
            shortcutsInUseElsewhere(unregistered)
        }
        if !preferences[Prefs.onboardingCompleted] {
            showOnboarding()
        }
        // The capture flow drops the cached desktop pictures first (when the setting says so); the covers then take the
        // new Space's.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.captureFlow.spaceDidChange()
                self?.desktopIcons.spaceDidChange()
            }
        }
        // A new desktop picture: window shots and editors read it afresh, and the covers take it once the desktop has
        // faded to it.
        DistributedNotificationCenter.default().addObserver(forName: Self.desktopNotification, object: "BackgroundChanged",
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.app.info("Desktop picture changed")
                self?.wallpapers.invalidate()
                self?.desktopIcons.desktopPictureChanged()
            }
        }
        desktopIcons.restore()
        cleanUpTemporaryFiles()
        purgeHistory()
        // The exports an edit (the Video Editor's Save, Mute Audio…) left in item folders when a crash or a quit
        // stopped it; only files from before this launch, so an edit started since keeps its own.
        let historyRoot = history.root
        let launch = Date()
        Task.detached(priority: .utility) {
            let removed = HistoryWriter.removeTemporaryEditFiles(in: historyRoot, before: launch)
            if !removed.isEmpty { Log.history.info("Removed \(removed.count) unfinished edit exports from history") }
        }
        // Recordings a crash or a kill left behind, once launch has settled; Focus Off when one turned it on.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            await RecordingRecovery.run(folders: recordingFolders, router: router, preferences: preferences,
                                        focusOff: { [focus] in await focus.turnOff() },
                                        isIdle: { [weak self] in self?.captureFlow.isIdle ?? true })
        }
        historyPurge = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
                self?.purgeHistory()
            }
        }
        // The first text recognition in a new build loads Vision's models, about half a minute; do it in the background
        // shortly after launch rather than on the first Capture Text.
        Task(priority: .utility) {
            try? await Task.sleep(for: .seconds(5))
            await TextRecognizer.warmUp()
        }
    }

    /// What macOS posts, with the object "BackgroundChanged", when a desktop picture changes.
    private static let desktopNotification = Notification.Name("com.apple.desktop")

    /// Some shortcuts couldn't be registered, because another app holds them: they won't fire until that app lets them
    /// go and ClearShot registers them again (at its next launch, or when the shortcut is set again in Settings).
    private func shortcutsInUseElsewhere(_ actions: [ClearShotAction]) {
        Log.hotkeys.warning("Couldn't register \(SystemShortcutCheck.describe(actions)); another app is using them")
        hud.show("Another app is using some of ClearShot's shortcuts", symbol: "exclamationmark.triangle.fill",
                 duration: .seconds(3))
    }

    func perform(_ action: ClearShotAction) {
        Log.app.info("Perform \(action.rawValue)")
        switch action {
        case .allInOne: Task { await captureFlow.allInOne() }
        case .captureArea: Task { await captureFlow.captureArea() }
        case .captureAreaAndCopy: Task { await captureFlow.captureArea(override: .copy) }
        case .captureAreaAndSave: Task { await captureFlow.captureArea(override: .save) }
        case .captureAreaAndAnnotate: Task { await captureFlow.captureArea(override: .annotate) }
        case .captureAreaAndPin: Task { await captureFlow.captureArea(override: .pin) }
        case .captureAreaAndSendToRaycast: Task { await captureFlow.captureArea(override: .raycast) }
        case .capturePreviousArea: Task { await captureFlow.capturePreviousArea() }
        case .captureFullscreen: Task { await captureFlow.captureFullscreen() }
        case .captureWindow: Task { await captureFlow.captureWindow() }
        case .selfTimer: Task { await captureFlow.selfTimer() }
        case .captureText: Task { await captureFlow.captureText(keepLineBreaks: nil) }
        case .captureTextWithLineBreaks: Task { await captureFlow.captureText(keepLineBreaks: true) }
        case .captureTextWithoutLineBreaks: Task { await captureFlow.captureText(keepLineBreaks: false) }
        case .scrollingCapture: Task { await captureFlow.scrollingCapture() }
        // Straight to the running scrolling capture, not through the capture flow's `run`, which it holds.
        case .startStopScrollingCapture: captureFlow.toggleScrollingCapture()
        // Straight to the recording, likewise; with none, Record Screen opens the recorder through `run`.
        case .recordScreen: captureFlow.recordingHotkey(.recordStop)
        // A new recorder, picking a window, through `run`, which refuses while anything captures or records.
        case .recordWindow: Task { await captureFlow.recordWindow() }
        case .pauseResumeRecording: captureFlow.recordingHotkey(.pauseResume)
        case .restartRecording: captureFlow.recordingHotkey(.restart)
        case .toggleOverlaysVisibility: quickAccess.toggleVisibility()
        case .closeAllOverlays: quickAccess.closeAll()
        case .saveAllOverlays: Task { await quickAccess.saveAll() }
        case .restoreLastCapture: quickAccess.restoreLastCapture()
        case .openFile: importer.openFile()
        case .openFromClipboard: importer.openFromClipboard()
        case .annotateLastScreenshot: annotate.annotateLastScreenshot()
        case .chooseAndPinImage: pins.chooseAndPin()
        case .pinLastScreenshot: pins.pinLastScreenshot()
        case .togglePinsVisibility: pins.toggleVisibility()
        case .closeAllPins: pins.closeAll()
        case .openCaptureHistory: showHistory()
        case .toggleDesktopIcons: desktopIcons.toggle()
        }
    }

    /// Files opened from Finder: projects open in Annotate; images and movies (the `public.movie` document type, Open
    /// With) in the Quick Access Overlay, each movie through `ImageImporter.importVideo`, so it then opens in the Video
    /// Editor. Only file URLs: `clearshot://` URLs go to the URL receiver, never here to be imported.
    func openFiles(_ urls: [URL]) {
        for url in urls where !url.isFileURL {
            Log.app.warning("Ignored a non-file URL: \(url.scheme ?? "no scheme")")
        }
        let fileURLs = urls.filter(\.isFileURL)
        let isProject = { (url: URL) in url.pathExtension.lowercased() == DocumentPackage.fileExtension }
        for url in fileURLs.filter(isProject) { annotate.open(projectAt: url) }
        let files = fileURLs.filter { !isProject($0) }
        if !files.isEmpty { importer.open(files) }
    }

    /// The Dock icon: the frontmost editor window comes forward, Annotate's or the Video Editor's; with none listed
    /// front to back (all minimised, say), Annotate's last, else the Video Editor's. False when none is open.
    func presentFrontmostEditor() -> Bool {
        let front = NSApp.orderedWindows.first { annotate.hasWindow($0) || videoEditor.hasWindow($0) }
        if let front, videoEditor.hasWindow(front) { return videoEditor.presentFrontmost() }
        return annotate.presentFrontmost() || videoEditor.presentFrontmost()
    }

    func showSettings(_ pane: SettingsPane? = nil) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(coordinator: self)
        }
        settingsWindow?.show(pane: pane)
    }

    /// Capture History (the status menu's "Capture History…" and its hotkey). Made once and kept, with its grid.
    func showHistory() {
        if historyWindow == nil {
            historyWindow = HistoryWindowController(coordinator: self)
        }
        historyWindow?.show()
    }

    func showAbout() {
        showSettings(.about)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController(coordinator: self) { [weak self] in
                self?.preferences[Prefs.onboardingCompleted] = true
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
        }
        onboardingWindow?.showWindow(nil)
        onboardingWindow?.window?.center()
        onboardingWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        preferences[Prefs.showMenuBarIcon] = visible
        statusItem?.isVisible = visible
    }

    /// Removes captures older than the retention setting, keeping any that something holds: an open thumbnail or
    /// editor, a running save.
    func purgeHistory() {
        let removed = history.purge(retention: preferences[Prefs.historyRetention])
        if removed > 0 { Log.history.info("Removed \(removed) expired history items") }
    }

    /// Retention "Never": removes every capture nothing holds any more. Runs after each release of a hold, so a capture
    /// goes as soon as its last thumbnail, editor or save lets it go. Does nothing for any other setting.
    func purgeIfNever() {
        guard preferences[Prefs.historyRetention] == .never else { return }
        history.purge(retention: .never)
    }

    /// "Clear History": everything except captures that something holds (an open thumbnail or editor).
    func clearHistory() {
        history.clear()
        hud.show("Capture history cleared", symbol: "trash")
    }

    /// Keeps thumbnails in step with the store. Events for one item can arrive out of order (an observer's change
    /// reaches later observers first), so the item is looked up rather than taken from the event.
    private func historyChanged(_ change: HistoryChange) {
        switch change {
        case .added:
            break
        case .updated(let id):
            if let item = history.item(id: id) { quickAccess.refresh(item) }
        case .removed(let id):
            // A capture that leaves history takes its thumbnail with it, whoever removed it. The thumbnail's own
            // Discard and Delete remove the item first, so this closes it and their close that follows does nothing.
            quickAccess.closeThumbnail(for: id)
        }
    }

    /// Removes the temporary files that unsaved copies left behind in earlier sessions.
    private func cleanUpTemporaryFiles() {
        try? FileManager.default.removeItem(at: AfterCaptureRouter.temporaryDirectory)
    }

    #if DEBUG
    func runCaptureSelfTest() {
        hud.show("Running capture self-test…", symbol: "stethoscope")
        Task {
            let header = CaptureSelfTest.header()
            let lines = await CaptureSelfTest.run(service: ScreenCaptureService())
            let report = (header + [""] + lines).joined(separator: "\n") + "\n"
            let url = FileLogSink.shared.directory.appending(path: "selftest.txt")
            try? FileManager.default.createDirectory(at: FileLogSink.shared.directory, withIntermediateDirectories: true)
            try? report.write(to: url, atomically: true, encoding: .utf8)
            lines.forEach { Log.capture.info("Self-test: \($0)") }
            let failures = lines.filter { $0.hasPrefix("FAIL") }.count
            hud.show(failures == 0 ? "Self-test passed (\(lines.count) checks)" : "Self-test: \(failures) of \(lines.count) failed",
                     symbol: failures == 0 ? "checkmark.seal.fill" : "xmark.octagon.fill")
        }
    }
    #endif
}
