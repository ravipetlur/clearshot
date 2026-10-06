import AppKit
import CSAnnotation
import CSCapture
import CSCore
import CSHistory

/// Opens and closes Annotate windows and applies their edits (Done). Its windows count towards the Dock icon
/// (`DocumentWindows`).
final class AnnotateManager {
    let preferences: Preferences
    let history: HistoryStore
    let hud: HUDController
    /// Holds an item while its editor is open. Internal rather than private so AnnotateManager+Output.swift can save
    /// through its item actions.
    let quickAccess: QuickAccessManager
    /// Pins what an editor shows (its Pin button, File › Pin to the Screen).
    private let pins: PinManager
    /// Where the background tool gets the pictures of image-backed fills, for an editor window's screen.
    let pictures: BackgroundPictures
    /// Annotate's windows and the Video Editor's share the activation policy.
    private let documents: DocumentWindows
    /// This manager's alerts report what an open or a Done did, which can finish during a capture or a recording, so
    /// each waits until none is under way.
    private let gate: ModalGate
    private var windows: [EditorWindowController] = []
    /// Documents being loaded, by item id or project path, so a fast second open can't make a second editor on one folder.
    private var opening: Set<String> = []
    /// The drag file last made for each editor, with the document it shows, so dragging an unchanged document again
    /// starts at once. Internal for AnnotateManager+Output.swift.
    var dragFiles: [ObjectIdentifier: (document: AnnotationDocument, file: URL)] = [:]
    /// Area selection for Add Image › Take Screenshot: the picture and its pixels per point. The coordinator supplies it,
    /// because the capture flow is made after this manager. It calls `beforeSelecting` once the capture is allowed to start
    /// (no other is running, screen recording is allowed) and just before the selection begins, which is where the editor
    /// steps aside. Nil when the selection is cancelled or nothing could be captured.
    var captureImage: (@MainActor (_ beforeSelecting: @escaping @MainActor () -> Void) async -> (image: CGImage, scale: Double)?)?

    init(preferences: Preferences, history: HistoryStore, quickAccess: QuickAccessManager, pins: PinManager,
         hud: HUDController, pictures: BackgroundPictures, documents: DocumentWindows, gate: ModalGate) {
        self.preferences = preferences
        self.documents = documents
        self.gate = gate
        self.history = history
        self.quickAccess = quickAccess
        self.pins = pins
        self.hud = hud
        self.pictures = pictures
    }

    // MARK: Opening

    /// Annotates a capture (Quick Access ⌘E, "Capture Area & Annotate", the after-capture action, reopening one).
    func open(_ item: HistoryItem) {
        if let existing = windows.first(where: { controller in
            if case .history(let open) = controller.editor.source { open.id == item.id } else { false }
        }) {
            NSApp.activate()
            existing.present()
            return
        }
        // A rotate, resize or save still running on its thumbnail changes the capture under the editor: it would load the
        // state from before and a later Done would overwrite the change.
        guard !quickAccess.isBusy(item.id) else {
            hud.show("Wait for the change to finish", symbol: "hourglass")
            return
        }
        let key = item.id.uuidString
        guard opening.insert(key).inserted else { return }
        // Held from here, so a purge that lands while the document loads can't remove the item. A window's close
        // releases it; a failed load does below.
        quickAccess.hold(itemID: item.id)
        let root = history.root
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try AnnotationStorage.open(item, root: root) }
            }.value
            opening.remove(key)
            switch outcome {
            case .success(let opened):
                show(AnnotationEditor(document: opened.document, images: opened.images, source: .history(item), preferences: preferences))
                if opened.recovered {
                    // After the editor is up, so the person sees what the alert is about.
                    Task {
                        runAlert(message: "The annotations on “\(item.displayName)” couldn't be read.",
                                 detail: "You're editing the original screenshot; pressing Done will replace the annotated version.")
                    }
                }
            case .failure(let error):
                quickAccess.release(itemID: item.id)
                showAlert(for: error)
            }
        }
    }

    /// Opens a `.clearshot` project.
    func open(projectAt url: URL) {
        let key = Self.projectKey(url)
        if let existing = windows.first(where: { Self.projectKey(of: $0.editor) == key }) {
            NSApp.activate()
            existing.present()
            return
        }
        guard opening.insert(key).inserted else { return }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try DocumentPackage.read(from: url) }
            }.value
            opening.remove(key)
            switch outcome {
            case .success(let opened):
                show(AnnotationEditor(document: opened.document, images: opened.images, source: .project(url), preferences: preferences))
            case .failure(let error):
                showAlert(for: error)
            }
        }
    }

    /// What identifies a project, whatever form its URL came in: Finder hands over a package with a trailing slash, a
    /// save panel without one, and a path may go through a link (`/var` is `/private/var`).
    static func projectKey(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func projectKey(of editor: AnnotationEditor) -> String? {
        if case .project(let url) = editor.source { projectKey(url) } else { nil }
    }

    /// Whether another editor than `editor` has the project at `url` open.
    func hasOtherEditor(onProjectAt url: URL, besides editor: AnnotationEditor) -> Bool {
        let key = Self.projectKey(url)
        return windows.contains { $0.editor !== editor && Self.projectKey(of: $0.editor) == key }
    }

    /// Opens the newest screenshot; videos and GIFs are skipped.
    func annotateLastScreenshot() {
        guard let item = history.newestScreenshot else {
            hud.show("There's no screenshot to annotate", symbol: "pencil.tip.crop.circle")
            return
        }
        open(item)
    }

    /// The Dock icon, clicked while editors are open: brings the frontmost editor forward, out of the Dock if it was
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

    private func show(_ editor: AnnotationEditor) {
        let controller = EditorWindowController(editor: editor, manager: self, alwaysOnTop: preferences[Prefs.annotateAlwaysOnTop],
                                                onClose: { [weak self] controller in self?.closed(controller) })
        windows.append(controller)
        if let window = controller.window { documents.opened(window) }
        NSApp.activate()
        controller.present()
    }

    /// Runs once per window: a second call (a repeated `windowWillClose`) must not release the item twice.
    private func closed(_ controller: EditorWindowController) {
        guard windows.contains(where: { $0 === controller }) else { return }
        // Read before the manager lets go of the controller, which may be its last owner.
        let itemID: UUID? = if case .history(let item) = controller.editor.source { item.id } else { nil }
        windows.removeAll { $0 === controller }
        if let dragged = dragFiles.removeValue(forKey: ObjectIdentifier(controller.editor)) {
            try? FileManager.default.removeItem(at: dragged.file.deletingLastPathComponent())
        }
        if let itemID { quickAccess.release(itemID: itemID) }
        if let window = controller.window { documents.closed(window) }
    }

    // MARK: Done

    /// Writes the editor's document back to where it came from (Done). For a capture, that means:
    /// - its history copy and thumbnail;
    /// - its saved file too, if ClearShot wrote it and nothing has changed it since.
    ///
    /// Nothing is written when there are no unapplied edits. Returns false, after telling the person why, when the
    /// edits couldn't be applied, and also when another apply of this editor is still running. Once the history copy
    /// has been replaced the outcome is a success even if the saved file then couldn't be updated; that is reported in
    /// an alert, as `HistoryItemActions.transform` does. A written document with a background leaves its style as its
    /// kind's Previous Settings.
    func apply(_ editor: AnnotationEditor) async -> Bool {
        guard !editor.isApplying else { return false }
        guard editor.hasUnappliedChanges else { return true }
        editor.isApplying = true
        defer { editor.isApplying = false }
        // What is written is this snapshot; the person may keep drawing while it is.
        let document = editor.document
        let images = editor.images
        switch editor.source {
        case .history(let item):
            // The item as it is now: a save or rename made while the editor was open must not be overwritten by the
            // snapshot the editor was opened with. If it is gone (trashed or discarded from its thumbnail), it stays
            // gone.
            guard let current = history.item(id: item.id) else {
                showAlert(message: "“\(item.displayName)” was removed from ClearShot's history, so the edits can't be applied to it.")
                return false
            }
            let root = history.root
            let quality = preferences[Prefs.imageQuality]
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(item: HistoryItem, savedFileError: (any Error)?), any Error> in
                Result {
                    guard let rendered = Renderer.render(document, images: images) else { throw CaptureError.cannotTransform }
                    var updated = try AnnotationStorage.save(document, images: images, rendered: rendered, to: current, root: root)
                    let savedFileError = HistoryItemActions.rewriteSavedFile(of: current, with: rendered, quality: quality,
                                                                             updating: &updated)
                    return (updated, savedFileError)
                }
            }.value
            switch outcome {
            case .success(let (updated, savedFileError)):
                // The history copy now shows the edits, so from here this is a success whatever happened to the saved file.
                // Recording it in the store refreshes the thumbnail (the store's `.updated`).
                do {
                    try history.update(updated)
                } catch {
                    Log.annotate.error("Couldn't record the change to \(updated.displayName) in history: \(error)")
                    // Keep memory in step with the working copy, unless the item was removed during the write.
                    if history.item(id: updated.id) != nil { history.add(updated) }
                }
                editor.source = .history(updated)
                editor.markApplied(document)
                BackgroundPresets.recordPrevious(document, in: preferences)
                if let savedFileError {
                    let message: String
                    if savedFileError is SavedFileEditedElsewhere {
                        Log.annotate.info("Left the saved file for \(updated.displayName) alone: it was edited in another app")
                        message = "Your edits are applied to the screenshot in ClearShot, but the saved file was edited in another app, so ClearShot left it alone."
                    } else {
                        Log.annotate.error("Couldn't rewrite the saved file for \(updated.displayName): \(savedFileError)")
                        message = "Your edits are applied to the screenshot in ClearShot, but the saved file wasn't updated"
                    }
                    // After this returns, so the thumbnail shows the edits before the alert blocks.
                    Task { showAlert(message: message, error: savedFileError) }
                }
                return true
            case .failure(let error):
                Log.annotate.error("Applying edits failed: \(error)")
                // A save that failed partway has already put `hasDocument` on disk (see `AnnotationStorage.save`). Read
                // the item back so memory says so too: a reopen in this run then reads the document over the untouched
                // base, instead of copying the render over the capture. The store's `.updated` refreshes the thumbnail.
                if let reloaded = history.reload(item.id) {
                    editor.source = .history(reloaded)
                }
                showAlert(for: error)
                return false
            }
        case .project(let url):
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Void, any Error> in
                Result {
                    guard let rendered = Renderer.render(document, images: images) else { throw CaptureError.cannotTransform }
                    try DocumentPackage.write(document, images: images, rendered: rendered, to: url)
                }
            }.value
            switch outcome {
            case .success:
                editor.markApplied(document)
                BackgroundPresets.recordPrevious(document, in: preferences)
                return true
            case .failure(let error):
                Log.annotate.error("Saving the project failed: \(error)")
                showAlert(for: error)
                return false
            }
        }
    }

    // MARK: Pin (D-P10)

    /// Pins what the editor shows, which stays open. A capture gets its edits applied first, as Done does, and its pin
    /// then follows later edits that Done applies. A project's render becomes a new history item each time (an imported
    /// file's, recording the project as its original), and that item is pinned.
    func pin(_ editor: AnnotationEditor) async {
        switch editor.source {
        case .history(let item):
            // False while another apply of this editor runs, or when it failed, which has said why.
            guard await apply(editor) else { return }
            guard let current = history.item(id: item.id) else {
                // Removed from history (from its thumbnail) while there were no edits to apply.
                hud.show("Couldn't pin the image", symbol: "exclamationmark.triangle.fill")
                return
            }
            pins.pin(current, anchor: .activeScreen)
        case .project(let url):
            let document = editor.document
            let images = editor.images
            let name = editor.title
            let root = history.root
            let createdAt = Date()
            let sourcePath = url.path(percentEncoded: false)
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<HistoryItem, any Error> in
                Result {
                    guard let rendered = Renderer.render(document, images: images) else { throw CaptureError.cannotTransform }
                    // The transparency check reads every pixel, so it belongs here and not on the main actor.
                    let details = HistoryWriter.Details(origin: .file, captureKind: .selection, displayName: name, savedURL: nil,
                                                        scale: document.renderedScale, appName: nil,
                                                        isTransparent: ImageOps.hasTransparentPixels(rendered),
                                                        globalRect: .zero, createdAt: createdAt, sourcePath: sourcePath)
                    return try HistoryWriter.create(rendered, details: details, root: root)
                }
            }.value
            switch outcome {
            case .success(let item):
                // Held from before it is listed until the pin holds it, so no release in between can purge it under
                // retention "Never".
                history.holds.hold(item.id)
                history.add(item)
                pins.pin(item, anchor: .activeScreen)
                history.holds.release(item.id)
            case .failure(let error):
                Log.annotate.error("Couldn't pin the project: \(error)")
                hud.show("Couldn't pin the image", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    // MARK: Quitting

    /// ⌘Q with open editors asks about each one's unapplied edits, applies the kept ones, then hands the quit on to
    /// `next` (the Video Editor's question), whose reply becomes this one's. While a Done write is in flight it neither
    /// asks nor quits: it waits for the write, then asks about whatever is still unapplied. Quitting under the write
    /// would leave the history item half written.
    func terminateReply(then next: @escaping () -> NSApplication.TerminateReply = { .terminateNow })
        -> NSApplication.TerminateReply {
        guard windows.contains(where: { $0.editor.isApplying }) else {
            guard let keep = editorsToKeep() else { return .terminateCancel }
            guard !keep.isEmpty else { return next() }
            Task { replyToQuit(await applyAll(keep), then: next) }
            return .terminateLater
        }
        Task {
            while windows.contains(where: { $0.editor.isApplying }) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let keep = editorsToKeep() else {
                replyToQuit(false, then: next)
                return
            }
            replyToQuit(await applyAll(keep), then: next)
        }
        return .terminateLater
    }

    /// Told when a quit this replies to later is cancelled after all, so what the quit stopped can carry on.
    var onQuitCancelled: () -> Void = {}

    /// The later reply to a quit: no, or `next`'s, which replies itself when it answers later too.
    private func replyToQuit(_ applied: Bool, then next: () -> NSApplication.TerminateReply) {
        let reply = applied ? next() : .terminateCancel
        switch reply {
        case .terminateLater:
            return
        case .terminateCancel:
            NSApp.reply(toApplicationShouldTerminate: false)
            onQuitCancelled()
        default:
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// Asks about each editor with unapplied edits. The editors whose edits are kept, or nil if the person cancelled.
    /// Text being typed and a pending crop are finished first, so they count as edits to keep or discard like the rest.
    private func editorsToKeep() -> [AnnotationEditor]? {
        for controller in windows { controller.canvas.canvas?.finishEditing() }
        var keep: [AnnotationEditor] = []
        for controller in windows where controller.editor.hasUnappliedChanges {
            controller.present()
            switch controller.askAboutChanges() {
            case .keep: keep.append(controller.editor)
            case .discard: break
            case .cancel: return nil
            }
        }
        return keep
    }

    /// Applies each editor's edits; false if any couldn't be applied.
    private func applyAll(_ editors: [AnnotationEditor]) async -> Bool {
        var allApplied = true
        for editor in editors where !(await apply(editor)) { allApplied = false }
        return allApplied
    }

    func showAlert(for error: any Error) {
        runAlert(message: (error as? LocalizedError)?.errorDescription ?? "Something went wrong",
                 detail: (error as? LocalizedError)?.recoverySuggestion ?? error.localizedDescription)
    }

    /// An alert headed `message`, with the error's own description and suggestion beneath it.
    private func showAlert(message: String, error: any Error) {
        let localized = error as? LocalizedError
        let detail = [localized?.errorDescription, localized?.recoverySuggestion].compactMap { $0 }.joined(separator: "\n")
        runAlert(message: message, detail: detail.isEmpty ? error.localizedDescription : detail)
    }

    private func showAlert(message: String) {
        runAlert(message: message, detail: "")
    }

    /// It reports what an open, a Done or a save did, so it waits until no capture or recording is under way
    /// (`ModalGate.report`): a Done's write can finish after a capture has started.
    private func runAlert(message: String, detail: String) {
        gate.report {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = message
            alert.informativeText = detail
            alert.addButton(withTitle: "OK")
            NSApp.activate()
            alert.runModal()
        }
    }
}
