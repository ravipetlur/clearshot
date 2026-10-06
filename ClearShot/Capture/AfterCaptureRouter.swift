import AppKit
import CSAnnotation
import CSCapture
import CSCore
import CSHistory
import CSRecording

enum CaptureOverride {
    case annotate, copy, save, pin, raycast
}

/// A screenshot as it came off the screen, with the post-processing it still needs and the background it gets.
/// Everything in it is Sendable, so the slow work can leave the main actor.
nonisolated struct RawCapture: Sendable {
    var image: CGImage
    var displayScale: CGFloat
    var processing: PostProcessOptions
    var kind: CaptureKind
    var displayID: UInt32
    var globalRect: CGRect
    var appName: String?
    /// The bundle ID of the app the capture was taken in, for the history item's source app.
    var appBundleID: String?
    var windowTitle: String?
    /// Whether `image` itself has see-through pixels (a window shot). With a background, the render decides instead.
    var isTransparent: Bool
    /// The background the capture gets, its picture already resolved, or nil for none. With one, the capture becomes a
    /// document whose base is the processed capture.
    var background: CaptureBackground?
    /// Whether the capture is a window shot, so its document takes window presets and Previous Settings.
    var isWindowShot: Bool
    var createdAt = Date()

    func processed() -> CaptureResult {
        CaptureResult(kind: kind, image: PostProcessor.apply(image, scale: displayScale, options: processing),
                      scale: processing.scaleTo1x ? 1 : displayScale, displayID: displayID, globalRect: globalRect,
                      appName: appName, windowTitle: windowTitle, createdAt: createdAt, isTransparent: isTransparent,
                      appBundleID: appBundleID)
    }
}

/// The output preferences, read on the main actor before the work leaves it.
nonisolated struct OutputSettings: Sendable {
    var preferredFormat: ImageFormat
    var quality: Double
    var exportDirectory: URL
    var template: FileNameTemplate
    /// The auto-increment value this capture's file names use. It is bumped after a save, on the main actor.
    var autoIncrement: Int
    var useUTC: Bool
    var removeIllegalCharacters: Bool
    var addRetinaSuffix: Bool
    var clipboardMode: ClipboardMode

    /// What a file name template reads for a capture or recording made at `date` in `appName`'s `windowTitle`.
    func nameContext(date: Date, appName: String?, windowTitle: String?) -> FileNameContext {
        FileNameContext(date: date, timeZone: useUTC ? .gmt : .current, appName: appName, windowTitle: windowTitle,
                        autoIncrement: autoIncrement, removeIllegalCharacters: removeIllegalCharacters)
    }

    /// The save of a screenshot just captured, so its file (the saved one, or the temporary one the clipboard gets) is
    /// marked as a screenshot.
    func exportRequest(for result: CaptureResult, in directory: URL) -> ExportRequest {
        let context = nameContext(date: result.createdAt, appName: result.appName, windowTitle: result.windowTitle)
        return ExportRequest(image: result.image,
                             format: ExportFormatPolicy.format(preferred: preferredFormat, isTransparent: result.isTransparent),
                             quality: quality, pixelsPerPoint: Double(result.scale), directory: directory, template: template,
                             nameContext: context, retinaSuffix: addRetinaSuffix && result.scale > 1,
                             screenCapture: ScreenCaptureTag(kind: result.kind, globalRect: result.globalRect))
    }
}

/// Runs the after-capture actions for one screenshot, and the after-recording actions for one recording
/// (`routeRecording`).
final class AfterCaptureRouter {
    let preferences: Preferences
    let hud: HUDController
    let sounds: SoundPlayer
    let history: HistoryStore
    let itemActions: HistoryItemActions
    let quickAccess: QuickAccessManager
    let annotate: AnnotateManager
    /// Opens a recording after it is made (Open Video Editor), and the trim prompt's editor.
    let videoEditor: VideoEditorManager
    let pins: PinManager
    /// Where recordings are written while they record; a routed recording's folder there is removed.
    let recordingFolders: RecordingFolders
    /// Actions that run late (the trim flow's, as its editor closes) report a failed save once no capture or recording
    /// is under way.
    let gate: ModalGate

    init(preferences: Preferences, hud: HUDController, sounds: SoundPlayer, history: HistoryStore,
         itemActions: HistoryItemActions, quickAccess: QuickAccessManager, annotate: AnnotateManager,
         videoEditor: VideoEditorManager, pins: PinManager, recordingFolders: RecordingFolders, gate: ModalGate) {
        self.preferences = preferences
        self.hud = hud
        self.sounds = sounds
        self.history = history
        self.itemActions = itemActions
        self.quickAccess = quickAccess
        self.annotate = annotate
        self.videoEditor = videoEditor
        self.pins = pins
        self.recordingFolders = recordingFolders
        self.gate = gate
    }

    func route(_ capture: RawCapture, actions: Set<AfterCaptureAction>, override: CaptureOverride?) async {
        let plan = AfterCapturePlan(actions: actions, askForName: preferences[Prefs.askForNameAfterCapture])
        let settings = outputSettings()
        let historyRoot = history.root
        sounds.playShutter()
        // Post-processing, encoding and writing a full-display image can take over a second; keep the UI responsive.
        let output = await Task.detached(priority: .userInitiated) {
            Self.produce(capture, plan: plan, settings: settings, historyRoot: historyRoot)
        }.value

        let result = output.result
        Log.capture.info("Captured \(result.kind.rawValue) \(result.image.width)×\(result.image.height) on display \(result.displayID)")
        advanceAutoIncrement(past: settings)
        if let savedURL = output.savedURL {
            Log.capture.info("Saved \(savedURL.lastPathComponent)")
        }
        if output.historyItem == nil, let historyError = output.historyError {
            Log.history.error("Couldn't add the capture to history: \(historyError)")
        }
        present(Written(item: output.historyItem, savedURL: output.savedURL, saveError: output.saveError, copy: output.copy),
                plan: plan, noun: "screenshot",
                writeClipboard: {
                    ClipboardWriter.write(pngData: output.clipboardPNG, fileURL: output.clipboardFileURL,
                                          mode: settings.clipboardMode)
                },
                openEditor: { annotate.open($0) },
                afterRelease: {
                    // "Capture Area & Send to Raycast" sends on top of whatever the after-capture actions did. It
                    // always says what happened, so the thumbnail and summary messages stay out of its way.
                    guard override == .raycast else { return false }
                    sendToRaycast(output)
                    return true
                })
    }

    /// The output preferences as they are now, read on the main actor before the work leaves it.
    func outputSettings() -> OutputSettings {
        OutputSettings(preferredFormat: preferences[Prefs.imageFormat], quality: preferences[Prefs.imageQuality],
                       exportDirectory: preferences[Prefs.exportLocation], template: preferences[Prefs.fileNameTemplate],
                       autoIncrement: preferences[Prefs.fileNameNextAutoIncrement], useUTC: preferences[Prefs.fileNameUseUTC],
                       removeIllegalCharacters: preferences[Prefs.fileNameRemoveIllegalCharacters],
                       addRetinaSuffix: preferences[Prefs.addRetinaSuffix], clipboardMode: preferences[Prefs.clipboardMode])
    }

    /// Every capture and recording uses its name now (its history copy carries it), so the counter moves on each time.
    /// max() keeps a value the person changed in Settings while the file was being written.
    func advanceAutoIncrement(past settings: OutputSettings) {
        guard settings.template.usesAutoIncrement else { return }
        preferences[Prefs.fileNameNextAutoIncrement] = max(preferences[Prefs.fileNameNextAutoIncrement], settings.autoIncrement + 1)
    }

    /// What the work off the main actor made of a screenshot or a recording, for `present`.
    struct Written {
        var item: HistoryItem?
        var savedURL: URL?
        var saveError: (any Error)?
        var copy: CopyDecision
    }

    /// What screenshots and recordings share once their files are written: the history item is held while something
    /// will show it, added to history, copied, shown in its thumbnail, opened in the editor or pinned, and the hold let
    /// go; then the save-failure alert (unless `showsAlerts` is false: quitting, recovering) or the summary HUD, saying
    /// `noun` ("screenshot", "recording"). With `runsLate` (the trim flow's actions, run as its editor closes, outside
    /// any capture) the alert waits until no capture or recording is under way (`ModalGate.report`), the item held
    /// until the alert and any retry it starts are done; inside a capture's `run` or a recording's tail it shows at
    /// once, the capture's windows gone and new captures held back.
    ///
    /// `writeClipboard` puts it on the clipboard and says whether that worked. `openEditor` opens Annotate or the Video
    /// Editor, which holds the item before it returns. `afterRelease` runs once the hold is let go, ahead of the alert,
    /// and returns true when it has said what happened itself, so no summary follows. `warning` (what went wrong
    /// before: the GIF that couldn't be made) joins the HUD, which then shows the warning symbol, and joins the
    /// save-failure alert's text.
    func present(_ written: Written, plan: AfterCapturePlan, noun: String, showsAlerts: Bool = true, runsLate: Bool = false,
                 warning: String? = nil, writeClipboard: () -> Bool, openEditor: (HistoryItem) -> Void,
                 afterRelease: () -> Bool = { false }) {
        let item = written.item
        let thumbnailShown = plan.showsThumbnail && item != nil
        let editorOpened = plan.opensEditor && item != nil
        let pinned = plan.pins && item != nil
        // Shown items are held from before they are listed until what shows them holds them, so a release in between
        // (even one an observer of `.added` causes) can't purge them under retention "Never". The thumbnail takes this
        // hold over; the editor and the pin hold the item themselves, and then this hold is let go. An item shown
        // nowhere isn't held, so "Never" removes it at the next release.
        var routerHolds = false
        if let item {
            if thumbnailShown || editorOpened || pinned {
                history.holds.hold(item.id)
                routerHolds = true
            }
            history.add(item)
        }
        var copied = false
        if written.copy != .none {
            copied = writeClipboard()
            if !copied { Log.capture.error("Couldn't put the \(noun) on the clipboard") }
            // Deleting the item from its thumbnail then takes this copy off the clipboard, while it's still there.
            if copied, let item { itemActions.noteCopied(item.id) }
        }
        if thumbnailShown, let item {
            // A thumbnail whose save failed stays until the person closes it: the alert below says the item is there.
            quickAccess.show(item, naming: plan.defersSave, closesAfterNaming: plan.defersSave && !plan.showsQuickAccess,
                             autoCloses: written.saveError == nil, takingOverHold: true)
            routerHolds = false
        }
        if editorOpened, let item {
            openEditor(item)
        }
        if pinned, let item {
            // Over the area it was taken from: exactly over a selection, centred on a window (its image has the shadow),
            // zoomed to fit a display. The pin holds the capture before this returns, ahead of the release below.
            pins.pin(item, anchor: .capture(item.globalRect))
        }
        if routerHolds, let item {
            history.holds.release(item.id)
        }
        let spoke = afterRelease()
        if let saveError = written.saveError {
            Log.capture.error("Save failed: \(saveError)")
            guard showsAlerts else { return }
            let whereItIs = saveFailureNote(thumbnailShown: thumbnailShown, editorOpened: editorOpened, pinned: pinned,
                                            copied: copied, copy: written.copy, inHistory: item != nil, noun: noun)
            let note = warning.map { "\(whereItIs) \($0)." } ?? whereItIs
            if runsLate {
                // The editor that held the item lets go once this returns, long before the alert may show, so the alert
                // holds it itself until it is done (a retry included), or "Choose Another Folder…" would find it purged
                // under retention "Never".
                if let item { history.holds.hold(item.id) }
                gate.report { [self] in
                    showSaveFailure(saveError, note: note, item: item, noun: noun) { [self] in
                        if let item { history.holds.release(item.id) }
                    }
                }
            } else {
                showSaveFailure(saveError, note: note, item: item, noun: noun)
            }
            return
        }
        if spoke { return }
        var message: (text: String, symbol: String)?
        if thumbnailShown {
            // The thumbnail shows it worked; only a failed copy needs a word.
            if written.copy == .requested, !copied {
                message = ("Couldn't copy to the clipboard", "exclamationmark.triangle.fill")
            }
        } else if editorOpened || pinned, !copied, written.savedURL == nil, written.copy != .requested {
            // The editor or the pin is the only place it went and it is on screen, so there is nothing to confirm (the
            // summary would call it uncopied). "Capture Area & Pin" ends here.
        } else {
            let kept = copied || written.savedURL != nil
            message = (summary(copied: copied, savedURL: written.savedURL, noun: noun),
                       kept ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        }
        let text = [message?.text, warning].compactMap { $0 }.joined(separator: ". ")
        guard !text.isEmpty else { return }
        let symbol = warning != nil ? "exclamationmark.triangle.fill" : message?.symbol ?? "checkmark.circle.fill"
        hud.show(text, symbol: symbol)
    }

    /// Copies the capture and opens Raycast AI Chat. The history copy is the lossless image; without one (its write
    /// failed) the capture is encoded here.
    private func sendToRaycast(_ output: Output) {
        let png = output.historyItem.flatMap { try? Data(contentsOf: $0.mediaURL(in: history.root)) }
            ?? (try? ImageEncoder.encode(output.result.image, as: .png, quality: 1, pixelsPerPoint: Double(output.result.scale)))
        guard let png else {
            hud.show("Couldn't send the screenshot to Raycast", symbol: "exclamationmark.triangle.fill")
            return
        }
        RaycastBridge.send(pngData: png, hud: hud)
    }

    nonisolated static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "ClearShot", directoryHint: .isDirectory)
    }

    /// What the work off the main actor hands back.
    private nonisolated struct Output: Sendable {
        var result: CaptureResult
        var savedURL: URL?
        var saveError: (any Error)?
        var historyItem: HistoryItem?
        var historyError: (any Error)?
        var copy = CopyDecision.none
        var clipboardPNG: Data?
        var clipboardFileURL: URL?
    }

    /// Post-processes, makes the document of a capture with a background, saves, writes the history copy, and prepares
    /// the clipboard copy. Runs off the main actor and touches no preferences.
    ///
    /// With a background, the processed capture (no border) is the document's base and the render is the capture from
    /// here on: it is saved, copied and kept as the working copy of a history item that opens as that document.
    private nonisolated static func produce(_ capture: RawCapture, plan: AfterCapturePlan, settings: OutputSettings,
                                            historyRoot: URL) -> Output {
        let base = capture.processed()
        let backgrounded = document(for: capture, base: base)
        // The render's transparency, not the capture's: a fill of None with corners makes any capture transparent, so it
        // isn't saved in a format that can't hold that.
        var output = Output(result: backgrounded.map { made in
            CaptureResult(id: base.id, kind: base.kind, image: made.rendered, scale: base.scale, displayID: base.displayID,
                          globalRect: base.globalRect, appName: base.appName, windowTitle: base.windowTitle,
                          createdAt: base.createdAt, isTransparent: ImageOps.hasTransparentPixels(made.rendered),
                          appBundleID: base.appBundleID)
        } ?? base)
        var request = settings.exportRequest(for: output.result, in: settings.exportDirectory)
        // Fix the name once: a template with random characters would give the file and the history copy different names.
        request.nameOverride = request.baseName
        if plan.saves {
            do {
                output.savedURL = try Exporter.save(request)
            } catch {
                output.saveError = error
            }
        }
        // The lossless working copy behind the thumbnail, history, unsaved copies and drags; for a capture with a
        // background, the render, with the document beside it.
        do {
            let details = HistoryWriter.Details(capture: output.result, displayName: request.baseName, savedURL: output.savedURL)
            if let backgrounded {
                output.historyItem = try AnnotationStorage.createItem(document: backgrounded.document, images: backgrounded.images,
                                                                      rendered: backgrounded.rendered, details: details,
                                                                      root: historyRoot)
            } else {
                output.historyItem = try HistoryWriter.create(output.result.image, details: details, root: historyRoot)
            }
        } catch {
            output.historyError = error
        }
        // "Ask for name" saves from the thumbnail's name field, and without a history copy there is no thumbnail: save
        // now under the template name instead.
        if plan.defersSave, output.historyItem == nil {
            do {
                output.savedURL = try Exporter.save(request)
            } catch {
                output.saveError = error
            }
        }
        let workingCopy = output.historyItem?.mediaURL(in: historyRoot)
        // Whatever isn't saved or shown is copied, so the screenshot is never lost.
        output.copy = plan.copy(saved: output.savedURL != nil, shown: plan.showsCapture && output.historyItem != nil)
        guard output.copy != .none else { return output }
        if settings.clipboardMode != .imageOnly {
            // A copy that includes the file needs one on disk even when Save is off: a temporary copy of the history
            // copy (it outlives the history folder, which retention "Never" removes), else a temporary file.
            output.clipboardFileURL = output.savedURL
                ?? output.historyItem.flatMap { try? HistoryWriter.temporaryCopy(of: $0, root: historyRoot, in: temporaryDirectory) }
                ?? (try? Exporter.save(settings.exportRequest(for: output.result, in: temporaryDirectory)))
        }
        if ClipboardWriter.includesImage(mode: settings.clipboardMode, fileURL: output.clipboardFileURL) {
            output.clipboardPNG = workingCopy.flatMap { try? Data(contentsOf: $0) }
                ?? (try? ImageEncoder.encode(output.result.image, as: .png, quality: 1, pixelsPerPoint: Double(output.result.scale)))
        }
        return output
    }

    /// The document a capture with a background becomes, over `base`, the processed capture; nil without a background.
    /// Also nil, after logging, when the document can't be made: the capture is then kept plain. An image-backed fill
    /// whose picture couldn't be had (or prepared) takes the first gradient, logged here (`CaptureDocument.make`
    /// doesn't log).
    private nonisolated static func document(for capture: RawCapture, base: CaptureResult)
        -> (document: AnnotationDocument, images: ImageStore, rendered: CGImage)? {
        guard let background = capture.background else { return nil }
        guard let made = CaptureDocument.make(base: base.image, pixelScale: Double(base.scale),
                                              isWindowShot: capture.isWindowShot, background: background) else {
            Log.capture.error("Couldn't give the \(capture.kind.rawValue) capture its background; keeping it without one")
            return nil
        }
        if let fill = made.document.background?.style.fill, fill != background.style.fill {
            Log.capture.info("No usable picture for the background fill \(background.style.fill); using the first gradient instead")
        }
        return made
    }

    /// What happened to the screenshot or recording (`noun`), e.g. "Copied to clipboard".
    func summary(copied: Bool, savedURL: URL?, noun: String) -> String {
        switch (copied, savedURL) {
        case (true, .some): "Copied and saved"
        case (true, nil): "Copied to clipboard"
        case (false, .some(let url)): "Saved to \(url.deletingLastPathComponent().lastPathComponent)"
        case (false, nil): "The \(noun) couldn't be copied to the clipboard"
        }
    }

    func saveFailureNote(thumbnailShown: Bool, editorOpened: Bool, pinned: Bool, copied: Bool, copy: CopyDecision,
                         inHistory: Bool, noun: String) -> String {
        if thumbnailShown { return "The \(noun) is still in the Quick Access Overlay." }
        if editorOpened {
            return noun == "screenshot" ? "The screenshot is open in Annotate." : "The \(noun) is open in the Video Editor."
        }
        if pinned { return "The \(noun) is pinned to the screen." }
        if copied {
            return copy == .requested
                ? "The \(noun) is on the clipboard."
                : "The \(noun) was copied to the clipboard instead, so it isn't lost."
        }
        if inHistory {
            // Retention "Never" removes it at the next release of any hold.
            return preferences[Prefs.historyRetention] == .never
                ? "It stays in Capture History only until the next thumbnail, editor or pin closes; use Restore Last Capture to bring it back."
                : "Use Restore Last Capture to bring it back."
        }
        return "It couldn't be copied to the clipboard either."
    }

    /// The alert offers another folder and saves there straight away. `finished` runs once, when it is all over: the
    /// alert closed with OK, the folder panel cancelled, or the save in the chosen folder done.
    func showSaveFailure(_ error: any Error, note: String, item: HistoryItem?, noun: String,
                         then finished: @escaping () -> Void = {}) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = (error as? LocalizedError)?.errorDescription ?? "The \(noun) couldn't be saved"
        let recovery = (error as? LocalizedError)?.recoverySuggestion ?? error.localizedDescription
        alert.informativeText = "\(recovery) \(note)"
        if item != nil { alert.addButton(withTitle: "Choose Another Folder…") }
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn, let item else {
            finished()
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = preferences[Prefs.exportLocation]
        guard panel.runModal() == .OK, let folder = panel.url else {
            finished()
            return
        }
        preferences[Prefs.exportLocation] = folder
        Task {
            await quickAccess.retrySave(item)
            finished()
        }
    }
}
