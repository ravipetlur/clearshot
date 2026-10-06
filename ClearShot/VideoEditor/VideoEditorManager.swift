import AppKit
import CSCapture
import CSCore
import CSHistory
import CSRecording

/// What the Video Editor's Save does.
enum VideoEditorMode: Equatable {
    /// A video from Quick Access or History, or a recording whose only after-recording action is Open Video Editor:
    /// Save asks whether to replace it or save as a new video.
    case edit
    /// A GIF (⌘E on it, Trim the GIF…): its source video is trimmed and converted again, replacing the GIF. A GIF always
    /// opens in this mode.
    case trimGIF
    /// The trim prompt's editor: a recording that has just finished, its other after-recording actions waiting. Nothing
    /// has been saved from it yet, so Save replaces its working copy without asking.
    case afterRecording
}

/// Opens the Video Editor, one window per history item, and does what their saves need in history: the item is held for
/// its window's life, as Annotate holds its captures, and replaced or joined by a new one on Save. Its windows count
/// towards the Dock icon (`DocumentWindows`). After-recording actions waiting on an editor run as it closes, on what it
/// saved or on the item as it was, before the item's hold is let go; quitting runs them too.
final class VideoEditorManager {
    let preferences: Preferences
    let history: HistoryStore
    let quickAccess: QuickAccessManager
    let hud: HUDController
    private let documents: DocumentWindows
    /// An alert whose editor window has gone reports a save, so it waits until no capture or recording is under way.
    private let gate: ModalGate
    private var windows: [VideoEditorWindowController] = []
    /// Items whose source is being read for a window, so a fast second open can't make a second window.
    private var opening: Set<UUID> = []
    /// After-recording actions not yet finished: counted the moment `open` takes them, while the editor's source is read,
    /// while its window is open and while they run, and uncounted only once they have run (`finish`). Never counted in
    /// a task that may not have started yet, so a quit always sees them, and waits.
    private var pendingCompletions = 0
    /// ClearShot is quitting, from the moment its quit question waits on these editors: the after-recording actions run
    /// without alerts. Reset when the quit is cancelled.
    private(set) var isQuitting = false
    /// The quit is going ahead (`finishForQuit` has started), so it can't be cancelled any more: an editor that finishes
    /// loading with after-recording actions waiting on it runs them at once instead of opening. Any other editor still
    /// opens, and so does every editor while the quit only waits on a save, since that quit may yet be cancelled.
    private var isFinishingForQuit = false
    /// Told when a quit this replies to later is cancelled after all, so what the quit stopped can carry on.
    var onQuitCancelled: () -> Void = {}

    init(preferences: Preferences, history: HistoryStore, quickAccess: QuickAccessManager, hud: HUDController,
         documents: DocumentWindows, gate: ModalGate) {
        self.preferences = preferences
        self.history = history
        self.quickAccess = quickAccess
        self.hud = hud
        self.documents = documents
        self.gate = gate
    }

    private var actions: HistoryItemActions { quickAccess.actions }

    /// A recorded GIF whose source video is gone: found as it opens, or, if the file went in between, as it is read.
    private static let missingRecording = "This GIF's recording is missing, so it can't be trimmed"

    // MARK: Opening

    /// Opens `item` in the editor: a video in `mode`, a GIF (its `.source.mp4`) always in `.trimGIF`; a GIF without one
    /// (opened from a file) is refused with a HUD that says why. A second open of
    /// an item brings its window forward. `startsTrimming` shows the trimming handles as soon as the player can trim.
    /// `completion` gets the saved item, or nil when the editor closed without saving (or couldn't open, or ClearShot is
    /// quitting); it runs exactly once, before the editor lets go of the item.
    func open(_ item: HistoryItem, mode: VideoEditorMode = .edit, startsTrimming: Bool = false,
              completion: ((HistoryItem?) async -> Void)? = nil) {
        // Counted now (`pendingCompletions`); every way out below runs it once, through `finish`.
        if completion != nil { pendingCompletions += 1 }
        // A GIF is trimmed from its source video, which one opened from a file never had.
        if item.kind == .gif, !item.opensInVideoEditor(root: history.root) {
            hud.show(item.origin == .capture ? Self.missingRecording
                                             : "This GIF wasn't recorded in ClearShot, so it can't be trimmed",
                     symbol: "exclamationmark.triangle.fill")
            settle(completion, itemID: item.id)
            return
        }
        if let existing = windows.first(where: { $0.itemID == item.id }) {
            NSApp.activate()
            existing.present()
            if startsTrimming { existing.beginTrimming() }
            // Nothing can wait on an editor opened before: what waits runs now.
            settle(completion, itemID: item.id)
            return
        }
        guard item.kind != .screenshot else {
            settle(completion, itemID: item.id)
            return
        }
        // Mute Audio… running on its thumbnail is changing the file the editor would open.
        guard !quickAccess.isBusy(item.id) else {
            hud.show("Wait for the change to finish", symbol: "hourglass")
            settle(completion, itemID: item.id)
            return
        }
        guard opening.insert(item.id).inserted else {
            settle(completion, itemID: item.id)
            return
        }
        let mode: VideoEditorMode = item.kind == .gif ? .trimGIF : mode
        let source = item.kind == .gif ? item.sourceVideoURL(in: history.root) : item.mediaURL(in: history.root)
        // Held from here, so a purge that lands while the source is read can't remove the item. The window's close
        // releases it; a failed open does below.
        quickAccess.hold(itemID: item.id)
        let onClose: (VideoEditorWindowController) -> Void = { [weak self] controller in self?.closed(controller) }
        Task {
            let outcome: Result<VideoSourceInfo, any Error>
            do {
                outcome = .success(try await VideoThumbnail.info(of: source))
            } catch {
                outcome = .failure(error)
            }
            opening.remove(item.id)
            switch outcome {
            case .success(let info):
                // The quit went ahead while the source was read: nothing will wait for this editor, so what waits on it
                // runs now, on the recording as it is. An editor nothing waits on opens anyway; one opening while the
                // quit only waits on a save opens too, and if the quit then goes ahead `finishForQuit` runs what waits
                // on it, as for any open editor.
                guard !(isFinishingForQuit && completion != nil) else {
                    await finish(completion, saved: nil)
                    quickAccess.release(itemID: item.id)
                    return
                }
                let controller = VideoEditorWindowController(item: item, mode: mode, source: info, sourceURL: source,
                                                             gifSize: item.kind == .gif ? gifSize(of: item) : nil,
                                                             manager: self, completion: completion, onClose: onClose)
                windows.append(controller)
                if let window = controller.window { documents.opened(window) }
                NSApp.activate()
                controller.present()
                if startsTrimming { controller.beginTrimming() }
            case .failure(let error):
                Log.recording.error("Couldn't open \(item.displayName) in the Video Editor: \(error)")
                if item.kind == .gif, !FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) {
                    hud.show(Self.missingRecording, symbol: "exclamationmark.triangle.fill")
                } else {
                    hud.show((error as? LocalizedError)?.errorDescription ?? "Couldn't open the video",
                             symbol: "exclamationmark.triangle.fill")
                }
                await finish(completion, saved: nil)
                quickAccess.release(itemID: item.id)
            }
        }
    }

    /// The Dock icon, clicked while editors are open: brings the frontmost one forward, out of the Dock if it was
    /// minimised. False when no editor is open.
    func presentFrontmost() -> Bool {
        // Front to back; the last one opened when none is listed there (all of them minimised, say).
        let front = NSApp.orderedWindows.lazy.compactMap { window in self.windows.first { $0.window === window } }.first
        guard let controller = front ?? windows.last else { return false }
        NSApp.activate()
        controller.present()
        return true
    }

    /// Whether `window` is one of the editors' windows.
    func hasWindow(_ window: NSWindow) -> Bool {
        windows.contains { $0.window === window }
    }

    /// Runs once per window. The after-recording actions waiting on it run first, while it still holds the item, so
    /// retention "Never" can't purge the item between Save and them.
    private func closed(_ controller: VideoEditorWindowController) {
        guard windows.contains(where: { $0 === controller }) else { return }
        windows.removeAll { $0 === controller }
        if let window = controller.window { documents.closed(window) }
        let itemID = controller.itemID
        guard let completion = controller.takeCompletion() else {
            quickAccess.release(itemID: itemID)
            return
        }
        let saved = controller.savedItem
        Task {
            await finish(completion, saved: saved)
            quickAccess.release(itemID: itemID)
        }
    }

    /// Runs what waited on an editor that never opened, holding the item until it has run.
    private func settle(_ completion: ((HistoryItem?) async -> Void)?, itemID: UUID) {
        guard let completion else { return }
        history.holds.hold(itemID)
        Task {
            await finish(completion, saved: nil)
            history.holds.release(itemID)
        }
    }

    /// Runs a completion `open` counted, then uncounts it.
    private func finish(_ completion: ((HistoryItem?) async -> Void)?, saved: HistoryItem?) async {
        guard let completion else { return }
        await completion(saved)
        pendingCompletions -= 1
    }

    // MARK: Saving (for the windows)

    /// The item as it is now; nil, after saying so, once it has left history (trashed from History meanwhile). `noun`
    /// is "video" or "GIF".
    func currentItem(_ itemID: UUID, noun: String) -> HistoryItem? {
        if let item = history.item(id: itemID) { return item }
        showAlert(message: "The \(noun) was removed from ClearShot's history, so the changes can't be saved to it.",
                  about: itemID)
        return nil
    }

    /// Replace (and an after-recording save): the export becomes the item's working copy, and its saved file when
    /// ClearShot wrote it and it hasn't changed since.
    func replace(_ item: HistoryItem, withExport file: URL) async -> HistoryItem? {
        await actions.replaceMedia(of: item, withExport: file)
    }

    /// Trim the GIF…'s save: the converted GIF replaces the item's, with its own size and length and, as its thumbnail,
    /// the source video's frame at the trim's start.
    func replace(_ item: HistoryItem, withGIF file: URL, converted: GIFConversionResult, source: URL,
                 trim: TrimRange) async -> HistoryItem? {
        let thumbnail: CGImage
        do {
            thumbnail = try await VideoThumbnail.image(of: source, at: trim.start)
        } catch {
            try? FileManager.default.removeItem(at: file)
            Log.recording.error("Couldn't make the trimmed GIF's thumbnail: \(error)")
            showAlert(message: "The GIF couldn't be saved", error: error, about: item.id)
            return nil
        }
        return await actions.replaceMedia(of: item, withFile: file, pixelWidth: converted.pixelWidth,
                                          pixelHeight: converted.pixelHeight, duration: converted.duration,
                                          hasAudio: false, thumbnail: thumbnail)
    }

    /// Save as New Video: the export becomes a new unsaved item, with its own thumbnail, beside the one it was edited
    /// from. It is ClearShot's own video now, so it is a capture (its auto-close "Save and close" saves it) with the
    /// original's app and place but no source file.
    func addAsNewVideo(_ file: URL, editedFrom item: HistoryItem) async -> HistoryItem? {
        let root = history.root
        let createdAt = Date()
        let outcome: Result<HistoryItem, any Error>
        do {
            let info = try await VideoThumbnail.info(of: file)
            let thumbnail = try await VideoThumbnail.image(of: file)
            let details = HistoryWriter.Details(kind: .video, origin: .capture, captureKind: item.captureKind,
                                                displayName: item.displayName, savedURL: nil, scale: item.scale,
                                                appName: item.appName, isTransparent: false, globalRect: item.globalRect,
                                                createdAt: createdAt, appBundleID: item.appBundleID,
                                                windowTitle: item.windowTitle)
            outcome = .success(try await Self.createItem(file, info: info, thumbnail: thumbnail, details: details, root: root))
        } catch {
            outcome = .failure(error)
        }
        switch outcome {
        case .success(let created):
            // Held from before it is listed until its thumbnail holds it, so no release in between can purge it.
            history.holds.hold(created.id)
            history.add(created)
            quickAccess.show(created)
            history.holds.release(created.id)
            return created
        case .failure(let error):
            try? FileManager.default.removeItem(at: file)
            Log.recording.error("Couldn't add the edited video to history: \(error)")
            showAlert(message: "The video couldn't be saved", error: error, about: item.id)
            return nil
        }
    }

    /// Moves `file` into a new item folder, off the main actor.
    @concurrent
    private nonisolated static func createItem(_ file: URL, info: VideoSourceInfo, thumbnail: CGImage,
                                               details: HistoryWriter.Details, root: URL) async throws -> HistoryItem {
        try HistoryWriter.createMedia(file, transfer: .move, pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight,
                                      duration: info.duration, hasAudio: !info.audioChannelCounts.isEmpty,
                                      thumbnail: thumbnail, details: details, root: root)
    }

    /// A GIF's file size and length now, for its estimate.
    private func gifSize(of item: HistoryItem) -> (bytes: Int64, duration: Double)? {
        let path = item.mediaURL(in: history.root).path(percentEncoded: false)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
              let duration = item.duration else { return nil }
        return (size.int64Value, duration)
    }

    // MARK: Quitting

    /// ⌘Q with editors open: a save in flight is waited for; then each editor with a pending change asks "Your changes
    /// will be lost if you exit." (Cancel cancels the quit); then the after-recording actions waiting on editors run on
    /// the recordings as they were, without alerts, and those already running (or about to: a save that finished while
    /// the quit waited) finish, before ClearShot quits.
    func terminateReply() -> NSApplication.TerminateReply {
        if windows.contains(where: { $0.state.isSaving }) {
            // Already, so the actions a finishing save sets off run without alerts.
            isQuitting = true
            Task {
                while windows.contains(where: { $0.state.isSaving }) {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard confirmExitAll() else {
                    isQuitting = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                    onQuitCancelled()
                    return
                }
                await finishForQuit()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        guard confirmExitAll() else { return .terminateCancel }
        guard pendingCompletions > 0 else { return .terminateNow }
        isQuitting = true
        Task {
            await finishForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Asks about each editor's pending change; false when the person cancels.
    private func confirmExitAll() -> Bool {
        for controller in windows where controller.state.hasPendingChanges {
            controller.present()
            guard controller.confirmExit() else { return false }
        }
        return true
    }

    /// The quit is going ahead (`isQuitting` is set): what waits in an open editor runs now, and everything counted
    /// elsewhere (running, or an editor still loading, which then runs it instead of opening) finishes.
    private func finishForQuit() async {
        isFinishingForQuit = true
        for controller in windows {
            if let completion = controller.takeCompletion() {
                await finish(completion, saved: nil)
            }
        }
        while pendingCompletions > 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Alerts

    /// An alert headed `message`, with the error's own description and suggestion beneath it, about the save of the
    /// editor on `itemID`.
    func showAlert(message: String, error: any Error, about itemID: UUID) {
        let localized = error as? LocalizedError
        let detail = [localized?.errorDescription, localized?.recoverySuggestion].compactMap { $0 }.joined(separator: "\n")
        showAlert(message: message, detail: detail.isEmpty ? error.localizedDescription : detail, about: itemID)
    }

    /// A sheet on the window of the editor on `itemID`, a document window, so no app-modal session runs under a capture
    /// or recording; once that window has gone, an app-modal alert that waits until none is under way
    /// (`ModalGate.report`).
    private func showAlert(message: String, detail: String = "", about itemID: UUID) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window = windows.first(where: { $0.itemID == itemID })?.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: nil)
            return
        }
        gate.report {
            NSApp.activate()
            alert.runModal()
        }
    }
}
