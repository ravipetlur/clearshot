import AppKit
import AVFoundation
import AVKit
import CSCore
import CSHistory
import CSRecording
import Observation
import SwiftUI

/// One Video Editor window: titled and resizable, named after its item, with an `AVPlayerView` (inline controls, whose
/// trimming gives the yellow handles) over the video and the bar beneath it. Save exports to a temporary file in the
/// item's folder behind a progress sheet, then replaces the item (asking first in `.edit`) or adds a new one; the
/// player never reads a file being written. The close button shows the unsaved dot, and closing, Cancel or quitting
/// with a pending change asks first.
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let itemID: UUID
    let state: VideoEditorState
    /// The file the player shows: the working copy, or a GIF's source video.
    let sourceURL: URL
    /// The manager owns every controller and outlives it, so the reference is never dangling.
    private unowned let manager: VideoEditorManager
    private let onClose: (VideoEditorWindowController) -> Void
    private let playerView = AVPlayerView()
    private let player: AVPlayer
    /// The item as Save left it, for the after-recording actions waiting on this editor (nil until a save).
    private(set) var savedItem: HistoryItem?
    /// The after-recording actions waiting on this editor; the manager runs them once, as it closes.
    private var completion: ((HistoryItem?) async -> Void)?
    private var hasPresented = false
    private var isClosed = false
    /// Trim was asked for before the player could trim; it begins once it can.
    private var wantsTrimming = false
    /// Key-value observations of the player's readiness to trim, while a Trim waits for it.
    private var readinessObservations: [NSKeyValueObservation] = []
    /// Stops the running export: the progress sheet's Cancel.
    private var cancelExport: (() -> Void)?
    /// "Your changes will be lost if you exit." is up on the window.
    private var isAskingToExit = false

    init(item: HistoryItem, mode: VideoEditorMode, source: VideoSourceInfo, sourceURL: URL,
         gifSize: (bytes: Int64, duration: Double)?, manager: VideoEditorManager,
         completion: ((HistoryItem?) async -> Void)?, onClose: @escaping (VideoEditorWindowController) -> Void) {
        itemID = item.id
        state = VideoEditorState(mode: mode, source: source, gifSize: gifSize)
        self.sourceURL = sourceURL
        self.manager = manager
        self.completion = completion
        self.onClose = onClose
        player = AVPlayer(playerItem: AVPlayerItem(url: sourceURL))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = item.displayName
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        let bar = NSHostingView(rootView: VideoEditorBar(state: state,
                                                          trim: { [weak self] in self?.beginTrimming() },
                                                          cancel: { [weak self] in self?.window?.performClose(nil) },
                                                          save: { [weak self] in self?.save() }))
        let content = NSView()
        for view in [playerView, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: playerView.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        // The bar's controls need their width; the player gets the rest.
        let barSize = bar.fittingSize
        window.contentMinSize = NSSize(width: barSize.width.rounded(.up), height: (barSize.height + 240).rounded(.up))
        window.setContentSize(Self.initialSize(for: source, scale: item.scale, bar: barSize))
        observeState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The video as it is shown (its rotation applied, so a portrait phone video gets a portrait window) at its point
    /// size, plus the bar, within 85% of the screen, and at least as wide as the bar.
    private static func initialSize(for source: VideoSourceInfo, scale: Double, bar: NSSize) -> NSSize {
        let scale = scale > 0 ? scale : 1
        let visible = (NSScreen.activeScreen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let maximum = NSSize(width: visible.width * 0.85, height: visible.height * 0.85 - bar.height)
        var video = NSSize(width: Double(source.displayWidth) / scale, height: Double(source.displayHeight) / scale)
        if video.width > 0, video.height > 0 {
            let fit = min(1, maximum.width / video.width, maximum.height / video.height)
            video = NSSize(width: video.width * fit, height: video.height * fit)
        } else {
            video = NSSize(width: 960, height: 540)
        }
        return NSSize(width: max(video.width, bar.width, 720).rounded(.up),
                      height: (max(video.height, 360) + bar.height).rounded(.up))
    }

    /// The unsaved dot, and the player's preview of Mute and Volume (up to 100%), follow the edit.
    private func observeState() {
        withObservationTracking {
            window?.isDocumentEdited = state.hasPendingChanges
            player.isMuted = state.edit.mute
            player.volume = Float(min(1, max(0, state.edit.volume)))
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeState() }
        }
    }

    /// Brings the editor forward; only the first time does it centre the window.
    func present() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !hasPresented {
            hasPresented = true
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Trimming

    /// The player's trimming controls (the yellow handles). They need a loaded item, so a Trim asked for before the
    /// player can trim waits for it (`startTrimmingIfReady`) rather than doing nothing; another click checks again. OK
    /// keeps the handles' range as the trim, snapped to the source's frames; Cancel keeps the previous one. The handles
    /// start where the last trim left them.
    func beginTrimming() {
        guard !state.isTrimming, !state.isSaving else { return }
        wantsTrimming = true
        startTrimmingIfReady()
    }

    /// Starts the trim that Trim asked for as soon as the player can trim: now, if it can; otherwise when key-value
    /// observing says the player view's `canBeginTrimming` or the item's status changed. An item that fails to load
    /// says so instead.
    private func startTrimmingIfReady() {
        guard wantsTrimming, !isClosed, !state.isSaving, !state.isTrimming else { return }
        if player.currentItem?.status == .failed {
            stopWaitingForReadiness()
            manager.hud.show("This video can't be trimmed", symbol: "exclamationmark.triangle.fill")
            return
        }
        guard playerView.canBeginTrimming else {
            observeReadiness()
            return
        }
        stopWaitingForReadiness()
        state.isTrimming = true
        Task {
            let result = await playerView.beginTrimming()
            state.isTrimming = false
            guard result == .okButton, let item = player.currentItem else { return }
            let duration = state.source.duration
            let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime.seconds : 0
            let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime.seconds : duration
            state.edit.trim = TrimRange(start: start, end: end, duration: duration,
                                        framesPerSecond: state.source.framesPerSecond)
        }
    }

    /// Watches what decides whether the player can trim, once (`.initial` covers a change just before). The handlers run
    /// on whatever thread changed the value, so they only hop to the main actor.
    private func observeReadiness() {
        guard readinessObservations.isEmpty else { return }
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.startTrimmingIfReady() }
        }
        readinessObservations = [
            playerView.observe(\.canBeginTrimming, options: [.initial, .new]) { @Sendable _, _ in changed() },
        ]
        if let item = player.currentItem {
            readinessObservations.append(item.observe(\.status, options: [.initial, .new]) { @Sendable _, _ in changed() })
        }
    }

    private func stopWaitingForReadiness() {
        wantsTrimming = false
        readinessObservations.forEach { $0.invalidate() }
        readinessObservations = []
    }

    // MARK: Saving

    /// Save: nothing to save closes the editor. Otherwise the export runs behind its progress sheet, then the item is
    /// replaced (or a new one added); the editor closes once saved and stays open, as it was, when the save is
    /// cancelled or fails.
    func save() {
        guard !state.isSaving, !state.isTrimming, !isClosed else { return }
        let plan = state.plan
        guard plan.path != .nothing else {
            close()
            return
        }
        state.isSaving = true
        Task {
            let saved = await state.mode == .trimGIF ? saveGIF(plan) : saveVideo(plan)
            state.isSaving = false
            guard let saved else { return }
            savedItem = saved
            close()
        }
    }

    /// The video's save: the export, then in `.edit` the question (Replace, Save as New Video, Cancel).
    private func saveVideo(_ plan: VideoEditPlan) async -> HistoryItem? {
        guard let item = manager.currentItem(itemID, noun: "video"), let window else { return nil }
        // An MP4, or a QuickTime movie when the video is copied from a codec MP4 can't carry (`VideoContainer`).
        let temporary = HistoryWriter.temporaryEditURL(for: item, pathExtension: plan.container.fileExtension,
                                                       root: manager.history.root)
        let title = plan.path == .passthrough && plan.timeRange != nil ? "Trimming video..." : "Saving video…"
        let source = sourceURL
        let exported: Void? = await runExport(title, to: temporary) { progress in
            try await RecordingExporter.export(source, to: temporary, plan: plan, progress: progress)
        }
        guard exported != nil else { return nil }
        switch state.mode {
        case .edit:
            let alert = NSAlert()
            alert.messageText = "Do you want to replace the existing video?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Save as New Video")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            switch await alert.beginSheetModal(for: window) {
            case .alertFirstButtonReturn:
                return await manager.replace(item, withExport: temporary)
            case .alertSecondButtonReturn:
                return await manager.addAsNewVideo(temporary, editedFrom: item)
            default:
                try? FileManager.default.removeItem(at: temporary)
                return nil
            }
        case .afterRecording, .trimGIF:
            // A recording that has just finished has nothing saved from it yet: its working copy is replaced as it is.
            return await manager.replace(item, withExport: temporary)
        }
    }

    /// Trim the GIF…: the trim of the source video converted again with the GIF settings as they are now, replacing the
    /// GIF (and a saved copy ClearShot wrote that hasn't changed since). The source video stays whole, so the next trim
    /// starts from the whole recording.
    private func saveGIF(_ plan: VideoEditPlan) async -> HistoryItem? {
        guard let item = manager.currentItem(itemID, noun: "GIF"), let trim = plan.timeRange else { return nil }
        let temporary = HistoryWriter.temporaryEditURL(for: item, pathExtension: "gif", root: manager.history.root)
        let settings = GIFConversionSettings(preferences: manager.preferences, trim: trim)
        let source = sourceURL
        let converted = await runExport("Creating GIF…", to: temporary) { progress in
            try await StreamingGIFEncoder().convert(source, to: temporary, settings: settings,
                                                    progress: { progress($0.fraction) })
        }
        guard let converted else { return nil }
        return await manager.replace(item, withGIF: temporary, converted: converted, source: source, trim: trim)
    }

    /// Runs `work` behind the progress sheet, whose Cancel stops it. Nil when it was cancelled (nothing is said) or
    /// failed (an alert says why); either way nothing is left at `destination`.
    private func runExport<Value: Sendable>(_ title: String, to destination: URL,
                                            _ work: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Value)
        async -> Value? {
        guard let window else { return nil }
        let progress = VideoEditorProgress(title: title)
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: VideoEditorProgressView(progress: progress, cancel: { [weak self] in
            self?.cancelExport?()
        }))
        sheet.contentViewController = hosting
        sheet.setContentSize(hosting.view.fittingSize)
        window.beginSheet(sheet, completionHandler: nil)
        // From the exporter's threads, onto the main actor.
        let report: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in progress.fraction = max(progress.fraction, fraction) }
        }
        let task = Task { () -> Result<Value, any Error> in
            do {
                return .success(try await work(report))
            } catch {
                return .failure(error)
            }
        }
        cancelExport = { task.cancel() }
        let outcome = await task.value
        cancelExport = nil
        // Before any failure's sheet, which takes the window next.
        window.endSheet(sheet)
        switch outcome {
        case .success(let value):
            return value
        case .failure(let error):
            try? FileManager.default.removeItem(at: destination)
            guard !(error is CancellationError) else { return nil }
            Log.recording.error("The Video Editor's save failed: \(error)")
            manager.showAlert(message: state.mode == .trimGIF ? "The GIF couldn't be saved" : "The video couldn't be saved",
                              error: error, about: itemID)
            return nil
        }
    }

    // MARK: Closing

    /// "Your changes will be lost if you exit." with Exit and Cancel, app-modal, for the quit (which asks about each
    /// editor in turn and replies at once, as Annotate's quit does; a recording has finished by then); true for Exit.
    func confirmExit() -> Bool {
        let alert = Self.exitAlert()
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The same question as a sheet on the editor, for closing it (the close button, ⌘W, Cancel): a document window's
    /// question, so no app-modal session runs under a capture or a recording. Exit closes the editor.
    private func askToExit() {
        guard let window, !isAskingToExit else { return }
        isAskingToExit = true
        Self.exitAlert().beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            isAskingToExit = false
            if response == .alertFirstButtonReturn { close() }
        }
    }

    private static func exitAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Your changes will be lost if you exit."
        alert.addButton(withTitle: "Exit")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    /// The after-recording actions waiting on this editor, handed over once (to run as it closes, or as ClearShot quits).
    func takeCompletion() -> ((HistoryItem?) async -> Void)? {
        defer { completion = nil }
        return completion
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A save is under way: closing now would leave its question or its write without a window. The trimming
        // controls end through their own Trim or Cancel, which the editor waits for.
        guard !state.isSaving, !state.isTrimming else { return false }
        guard state.hasPendingChanges else { return true }
        // Asked on the window; Exit closes it.
        askToExit()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        stopWaitingForReadiness()
        cancelExport?()
        player.pause()
        onClose(self)
    }

    // MARK: Menu items

    /// File › Save (⌘S), as the Save button.
    @objc func saveImage(_ sender: Any?) {
        save()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveImage(_:)): !state.isSaving && !state.isTrimming
        default: true
        }
    }
}
