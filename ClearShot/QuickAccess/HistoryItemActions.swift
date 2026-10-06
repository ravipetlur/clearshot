import AppKit
import CSAnnotation
import CSCapture
import CSCore
import CSHistory
import CSRecording
import UniformTypeIdentifiers

/// What can be done with a history item: copy, save, Save As, Show in Finder, Move to Trash, Extract Text. The Quick
/// Access Overlay and the History window both use it. A save, Save As, image change, Extract Text or Print holds its
/// item in history while it runs, so a thumbnail, editor or pin closing meanwhile can't purge it (retention "Never").
final class HistoryItemActions {
    private let preferences: Preferences
    private let history: HistoryStore
    private let hud: HUDController
    /// Reads Extract Text's picture and puts its text on the clipboard.
    private let text: TextResultPresenter
    /// Every alert here reports what an action did, so each waits until no capture or recording is under way.
    private let gate: ModalGate
    /// ClearShot's last copy of a capture on the clipboard, so Trash can take it off again (`ClipboardOwnership`).
    private var lastCopy: ClipboardOwnership?

    init(preferences: Preferences, history: HistoryStore, hud: HUDController, text: TextResultPresenter, gate: ModalGate) {
        self.preferences = preferences
        self.history = history
        self.hud = hud
        self.text = text
        self.gate = gate
    }

    /// What a save's failure calls the item: "screenshot", "recording" (a video, as the router's save failure and "Close
    /// this recording?" call it) or "GIF".
    static func noun(for kind: MediaKind) -> String {
        switch kind {
        case .video: "recording"
        case .gif: "GIF"
        case .screenshot, .studioProject: "screenshot"
        }
    }

    /// The lossless PNG in the history folder.
    func workingCopy(for item: HistoryItem) -> URL {
        item.mediaURL(in: history.root)
    }

    /// What a copy, drag, share or Quick Look uses: the saved file while it still exists, otherwise a temporary copy of
    /// the working copy that survives the history folder being removed (retention "Never" does that when the thumbnail
    /// closes). Falls back to the working copy itself if the temporary copy can't be made.
    func file(for item: HistoryItem) -> URL {
        if let saved = existingSavedFile(of: item) { return saved }
        return (try? HistoryWriter.temporaryCopy(of: item, root: history.root, in: AfterCaptureRouter.temporaryDirectory))
            ?? workingCopy(for: item)
    }

    /// What a drag carries: `file(for:)`, and for a screenshot a PNG for targets that take only an image (a video or GIF
    /// carries only its file). Both point outside the history folder, which retention "Never" removes when the thumbnail
    /// closes.
    func dragFiles(for item: HistoryItem) -> QuickAccessDragFiles {
        let file = file(for: item)
        guard item.kind == .screenshot else { return QuickAccessDragFiles(file: file, png: nil) }
        let png = file.pathExtension.lowercased() == "png"
            ? file
            : ((try? HistoryWriter.temporaryCopy(of: item, root: history.root, in: AfterCaptureRouter.temporaryDirectory))
               ?? workingCopy(for: item))
        return QuickAccessDragFiles(file: file, png: png)
    }

    /// What Show in Finder reveals: the saved file while it exists; else, for an imported image, the original while it
    /// exists; else `file(for:)`.
    func revealFile(for item: HistoryItem) -> URL {
        existingSavedFile(of: item) ?? existingSourceFile(of: item) ?? file(for: item)
    }

    /// What Open With opens: the saved file while it exists; else, for an imported image, the original while it exists,
    /// is an image and the item is unchanged since it was imported (after a rotate or an annotation the original no
    /// longer shows the item); else `file(for:)`.
    func openWithFile(for item: HistoryItem) -> URL {
        if let saved = existingSavedFile(of: item) { return saved }
        if item.isUnchangedSinceCreation, let source = existingSourceFile(of: item),
           (try? source.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true {
            return source
        }
        return file(for: item)
    }

    /// The file the person saved, while it exists.
    private func existingSavedFile(of item: HistoryItem) -> URL? {
        guard let saved = item.savedURL, FileManager.default.fileExists(atPath: saved.path(percentEncoded: false)) else {
            return nil
        }
        return saved
    }

    /// The file the item was imported from, while it exists.
    private func existingSourceFile(of item: HistoryItem) -> URL? {
        guard let source = item.sourceURL, FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            return nil
        }
        return source
    }

    /// Puts the item on the clipboard in the chosen format; a video or GIF as its file whatever the format, a GIF with
    /// its data too, so it pastes animated.
    @discardableResult
    func copy(_ item: HistoryItem) -> Bool {
        let mode = preferences[Prefs.clipboardMode]
        let fileURL = file(for: item)
        let copied: Bool
        if item.kind == .screenshot {
            let png = ClipboardWriter.includesImage(mode: mode, fileURL: fileURL) ? try? Data(contentsOf: workingCopy(for: item)) : nil
            copied = ClipboardWriter.write(pngData: png, fileURL: fileURL, mode: mode)
        } else {
            copied = ClipboardWriter.write(mediaFileURL: fileURL,
                                           gifData: item.kind == .gif ? try? Data(contentsOf: fileURL) : nil)
        }
        if copied {
            noteCopied(item.id)
            hud.show("Copied to clipboard", symbol: "doc.on.clipboard")
        } else {
            Log.capture.error("Couldn't copy \(item.displayName) to the clipboard")
            hud.show("Couldn't copy to the clipboard", symbol: "exclamationmark.triangle.fill")
        }
        return copied
    }

    /// Records that the item was just put on the clipboard, right after a successful write: this class's own copy, the
    /// after-capture copy, which the router makes, and Annotate's Copy.
    func noteCopied(_ itemID: UUID) {
        lastCopy = ClipboardOwnership(itemID: itemID, changeCount: NSPasteboard.general.changeCount)
    }

    /// Takes ClearShot's copy of the item off the clipboard while the clipboard still holds it: for a capture being
    /// deleted (Trash, the name strip's Discard). Anything copied since, here or in another app, has moved the change
    /// count on and stays.
    func clearClipboardCopy(of itemID: UUID) {
        let pasteboard = NSPasteboard.general
        guard let lastCopy, lastCopy.clears(deleting: itemID, changeCount: pasteboard.changeCount) else { return }
        pasteboard.clearContents()
        self.lastCopy = nil
    }

    /// Saves into the export folder as `name` (default: the item's name). Returns the updated item, or nil after
    /// telling the person why it failed. The capture stays in history either way. It is held from before the write
    /// until the save is recorded, also when no thumbnail shows it (a retried save, Annotate's Save). A video or GIF is
    /// saved as a copy of its working copy, keeping its extension, never re-encoded.
    func save(_ item: HistoryItem, name: String? = nil) async -> HistoryItem? {
        let directory = preferences[Prefs.exportLocation]
        let format = ExportFormatPolicy.format(preferred: preferences[Prefs.imageFormat], isTransparent: item.isTransparent)
        let quality = preferences[Prefs.imageQuality]
        let baseName = FileNamer.sanitize(name ?? item.displayName,
                                          removeIllegalCharacters: preferences[Prefs.fileNameRemoveIllegalCharacters])
        let source = workingCopy(for: item)
        let isMedia = item.kind != .screenshot
        let screenCapture = item.screenCaptureTag
        history.holds.hold(item.id)
        defer { history.holds.release(item.id) }
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL, any Error> in
            Result {
                if isMedia { return try Exporter.saveCopy(of: source, in: directory, baseName: baseName) }
                guard let image = ImageOps.load(source) else { throw CaptureError.imageMissing }
                return try Exporter.save(ExportRequest(image: image, format: format, quality: quality, pixelsPerPoint: item.scale,
                                                       directory: directory, baseName: baseName, screenCapture: screenCapture))
            }
        }.value
        return finishSave(item, outcome: outcome)
    }

    /// Asks where to save, then saves there (⌥-Save, Save As…, a pin's Save As…). The item is held from the panel's OK
    /// until the save is recorded. A screenshot's panel has a format menu starting on the format Save would use, and
    /// writes the one chosen. A video or GIF is a copy of its working copy in that file's own type, so an opened `.mov`
    /// stays a QuickTime movie.
    func saveAs(_ item: HistoryItem) async -> HistoryItem? {
        let preferred = ExportFormatPolicy.format(preferred: preferences[Prefs.imageFormat], isTransparent: item.isTransparent)
        let quality = preferences[Prefs.imageQuality]
        let source = workingCopy(for: item)
        let folder = preferences[Prefs.exportLocation]
        let isMedia = item.kind != .screenshot
        let screenCapture = item.screenCaptureTag
        let url: URL
        let format: ImageFormat
        if isMedia {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(item.displayName).\(source.pathExtension)"
            let ownType = UTType(filenameExtension: source.pathExtension)
            panel.allowedContentTypes = [ownType ?? (item.kind == .gif ? .gif : .mpeg4Movie)]
            panel.directoryURL = folder
            panel.canCreateDirectories = true
            NSApp.activate()
            guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
            url = chosen
            // Not used: a copy keeps its bytes.
            format = preferred
        } else {
            // The image formats only, starting on the one Save would use.
            guard let chosen = SaveAsPanel.run(name: item.displayName, folder: folder, format: AnnotateSaveFormat(preferred),
                                               formats: AnnotateSaveFormat.imageFormats),
                  let imageFormat = chosen.format.imageFormat else { return nil }
            url = chosen.url
            format = imageFormat
        }
        history.holds.hold(item.id)
        defer { history.holds.release(item.id) }
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL, any Error> in
            Result {
                if isMedia {
                    try Exporter.writeCopy(of: source, to: url)
                    return url
                }
                guard let image = ImageOps.load(source) else { throw CaptureError.imageMissing }
                try Exporter.write(image, as: format, quality: quality, pixelsPerPoint: item.scale, to: url,
                                   screenCapture: screenCapture)
                return url
            }
        }.value
        return finishSave(item, outcome: outcome)
    }

    /// Extract Text: copies the text in a screenshot as it looks now, annotations included, since its working copy is
    /// the render. Not for a video or GIF. The item is held from before the working copy is read until its text has
    /// been presented, so a thumbnail or pin closing meanwhile can't purge it (retention "Never").
    func extractText(_ item: HistoryItem) async {
        guard item.kind == .screenshot else {
            hud.show("Extract Text works on screenshots only", symbol: "text.viewfinder")
            return
        }
        history.holds.hold(item.id)
        defer { history.holds.release(item.id) }
        let source = workingCopy(for: item)
        let image = await Task.detached(priority: .userInitiated) { ImageOps.load(source) }.value
        guard let image else {
            Log.capture.error("Couldn't read the working copy of \(item.displayName) to extract its text")
            hud.show("Couldn't read the screenshot", symbol: "exclamationmark.triangle.fill")
            return
        }
        await text.recognizeAndPresent(image, keepLineBreaks: nil)
    }

    func showInFinder(_ item: HistoryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([revealFile(for: item)])
    }

    /// A new Mail message with the file attached ("Open in Mail…").
    func mail(_ item: HistoryItem) {
        guard let service = NSSharingService(named: .composeEmail) else {
            hud.show("Mail isn't available", symbol: "exclamationmark.triangle.fill")
            return
        }
        service.perform(withItems: [file(for: item)])
    }

    /// The system print dialog for the working copy at the item's point size, starting with it on one page ("Print…");
    /// the panel's checkbox pages a tall or wide capture instead. The item is held from before the working copy is read
    /// until the dialog and the printing it starts are over.
    func printImage(_ item: HistoryItem) {
        guard item.kind == .screenshot else {
            hud.show("Printing works on screenshots only", symbol: "printer")
            return
        }
        history.holds.hold(item.id)
        defer { history.holds.release(item.id) }
        guard let image = ImageOps.load(workingCopy(for: item)) else {
            showAlert(for: CaptureError.imageMissing)
            return
        }
        let scale = item.scale > 0 ? item.scale : 1
        ImagePrinter.run(image, pointSize: NSSize(width: Double(image.width) / scale, height: Double(image.height) / scale),
                         fitOnOnePage: true)
    }

    /// Rewrites the saved file with `image` (a rotate, flip, resize or annotation), unless it has been edited in another
    /// app since ClearShot wrote it. The file records `updated`'s scale, the image's after the change, as its density.
    /// On success the new file date goes into `updated`. Returns what the caller should report, or nil when the file is up
    /// to date or there was nothing to rewrite. Image changes here and the editor's Done both use it, so they treat the
    /// saved file alike.
    nonisolated static func rewriteSavedFile(of item: HistoryItem, with image: CGImage, quality: Double,
                                             updating updated: inout HistoryItem) -> (any Error)? {
        guard let saved = item.savedURL, FileManager.default.fileExists(atPath: saved.path(percentEncoded: false)) else { return nil }
        guard item.savedFileIsUnchanged(modifiedAt: HistoryWriter.modificationDate(of: saved)) else { return SavedFileEditedElsewhere() }
        guard let format = ImageFormat(fileExtension: saved.pathExtension) else {
            // Not a format ClearShot writes; PNG bytes under another extension would corrupt the file.
            Log.history.info("Left \(saved.lastPathComponent) as it was: .\(saved.pathExtension) isn't a format ClearShot writes")
            return nil
        }
        do {
            try Exporter.write(image, as: format, quality: quality, pixelsPerPoint: updated.scale, to: saved,
                               screenCapture: item.screenCaptureTag)
            updated.savedFileDate = HistoryWriter.modificationDate(of: saved)
            return nil
        } catch {
            return error
        }
    }

    /// Rotates, flips or resizes the working copy and the thumbnail, and rewrites the saved file in place if there is
    /// one and it hasn't been edited in another app since ClearShot wrote it. The working copy is the source of truth:
    /// once it has changed, the updated item is recorded and returned even if the saved file wasn't rewritten, which is
    /// then reported in an alert. Returns nil, after telling the person why, only when the working copy itself couldn't
    /// be changed. The item is held while the change runs and is recorded.
    ///
    /// An annotated capture takes the change as an image operation in its document, so the annotations turn with the
    /// picture and stay editable; its working copy is the re-render. A resize asks for the size of the whole output,
    /// the background's frame included, as the working copy shows it. Writing a document with a background records its
    /// style as its kind's Previous Settings. If its document can't be read, the working copy is changed like any
    /// other, so the annotations it shows turn with the picture instead of being dropped, and it becomes the capture of
    /// record (`AnnotationStorage.makeCaptureOfRecord`).
    func transform(_ item: HistoryItem, _ change: ImageTransform) async -> HistoryItem? {
        guard item.kind == .screenshot else {
            hud.show("Rotate, flip and resize work on screenshots only", symbol: "photo")
            return nil
        }
        let root = history.root
        let quality = preferences[Prefs.imageQuality]
        history.holds.hold(item.id)
        defer { history.holds.release(item.id) }
        let outcome = await Task.detached(priority: .userInitiated) {
            () -> Result<(item: HistoryItem, savedFileError: (any Error)?, document: AnnotationDocument?), any Error> in
            Result {
                if item.hasDocument == true {
                    let opened = try AnnotationStorage.open(item, root: root)
                    if !opened.recovered {
                        let outputSize = Renderer.outputBounds(of: opened.document, images: opened.images, cache: nil).size
                        let op = opened.document.imageOp(for: change, itemScale: item.scale, outputSize: outputSize)
                        let document = opened.document.applying(op)
                        guard let rendered = Renderer.render(document, images: opened.images) else { throw CaptureError.cannotTransform }
                        var updated = try AnnotationStorage.save(document, images: opened.images, rendered: rendered, to: item,
                                                                 root: root)
                        let savedFileError = Self.rewriteSavedFile(of: item, with: rendered, quality: quality, updating: &updated)
                        return (updated, savedFileError, document)
                    }
                    Log.history.info("Couldn't read the annotations of \(item.displayName); changing its working copy instead")
                }
                guard let image = ImageOps.load(item.mediaURL(in: root)) else { throw CaptureError.imageMissing }
                guard let changed = ImageOps.apply(change, to: image, scale: item.scale) else { throw CaptureError.cannotTransform }
                // Only an annotated item gets here when its document couldn't be read.
                var updated = item.hasDocument == true
                    ? try AnnotationStorage.makeCaptureOfRecord(changed.image, scale: changed.scale, for: item, root: root)
                    : try HistoryWriter.replaceImage(of: item, with: changed.image, scale: changed.scale, root: root)
                let savedFileError = Self.rewriteSavedFile(of: item, with: changed.image, quality: quality, updating: &updated)
                return (updated, savedFileError, nil)
            }
        }.value
        switch outcome {
        case .success(let (updated, savedFileError, document)):
            do {
                try history.update(updated)
            } catch {
                Log.history.error("Couldn't record the change to \(updated.displayName) in history: \(error)")
            }
            if let document { BackgroundPresets.recordPrevious(document, in: preferences) }
            if let savedFileError {
                let message: String
                if savedFileError is SavedFileEditedElsewhere {
                    Log.capture.info("Left the saved file for \(updated.displayName) alone: it was edited in another app")
                    message = "The image changed, but the saved file was edited in another app, so ClearShot left it alone."
                } else {
                    Log.capture.error("Couldn't rewrite the saved file for \(updated.displayName): \(savedFileError)")
                    message = "The image changed, but the saved file wasn't updated"
                }
                // After this returns, so the thumbnail shows the new image before the alert blocks.
                Task { showAlert(message: message, error: savedFileError) }
            }
            return updated
        case .failure(let error):
            Log.capture.error("Image change failed: \(error)")
            showAlert(for: error)
            return nil
        }
    }

    /// Moves the saved file (if it still exists) to the Trash, takes ClearShot's copy of the capture off the clipboard
    /// if it is still there, and removes the capture from history, which closes its thumbnail and pins. Returns false,
    /// leaving everything in place, if the file couldn't be moved.
    @discardableResult
    func trash(_ item: HistoryItem) -> Bool {
        if let saved = item.savedURL, FileManager.default.fileExists(atPath: saved.path(percentEncoded: false)) {
            do {
                try FileManager.default.trashItem(at: saved, resultingItemURL: nil)
            } catch {
                Log.history.error("Couldn't move \(saved.lastPathComponent) to the Trash: \(error)")
                hud.show("Couldn't move the file to the Trash", symbol: "exclamationmark.triangle.fill")
                return false
            }
        }
        clearClipboardCopy(of: item.id)
        history.remove(item.id)
        return true
    }

    private func finishSave(_ item: HistoryItem, outcome: Result<URL, any Error>) -> HistoryItem? {
        switch outcome {
        case .success(let url):
            Log.capture.info("Saved \(url.lastPathComponent)")
            hud.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)", symbol: "checkmark.circle.fill")
            // The item as it is now, not as the caller saw it: a rename or an annotation made while the save ran must
            // survive. Only if it has left history is the caller's copy used.
            var updated = history.item(id: item.id) ?? item
            updated.savedPath = url.path(percentEncoded: false)
            updated.savedFileDate = HistoryWriter.modificationDate(of: url)
            updated.displayName = url.deletingPathExtension().lastPathComponent
            do {
                try history.update(updated)
            } catch {
                Log.history.error("Couldn't record the save of \(updated.displayName) in history: \(error)")
            }
            return updated
        case .failure(let error):
            Log.capture.error("Save failed: \(error)")
            showAlert(for: error, noun: Self.noun(for: item.kind))
            return nil
        }
    }

    /// An alert with the error's own description, or "The `noun` couldn't be saved", and its suggestion.
    func showAlert(for error: any Error, noun: String = "screenshot") {
        runAlert(message: (error as? LocalizedError)?.errorDescription ?? "The \(noun) couldn't be saved",
                 detail: (error as? LocalizedError)?.recoverySuggestion ?? error.localizedDescription)
    }

    /// An alert headed `message`, with the error's own description and suggestion beneath it.
    func showAlert(message: String, error: any Error) {
        let localized = error as? LocalizedError
        let detail = [localized?.errorDescription, localized?.recoverySuggestion].compactMap { $0 }.joined(separator: "\n")
        runAlert(message: message, detail: detail.isEmpty ? error.localizedDescription : detail)
    }

    /// It reports what an action did, so it waits until no capture or recording is under way (`ModalGate.report`).
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

/// The saved file changed after ClearShot last wrote it (edited through Open With, say), so a rotate, resize, Done or a
/// video's edit leaves it alone rather than replace those edits. `noun` names what changed, as the alert's message does:
/// "image", "video" or "GIF".
nonisolated struct SavedFileEditedElsewhere: LocalizedError {
    var noun = "image"

    var recoverySuggestion: String? { "Use Save As… to keep the changed \(noun) as a new file." }
}

// MARK: Videos and GIFs

extension HistoryItemActions {
    /// Mute Audio…, once the person has confirmed: the whole video copied without its audio (`VideoEditPlan.mute`)
    /// replaces the working copy, and the saved file goes with it (`replaceMedia(of:withFile:…)`). It is an MP4, or a
    /// QuickTime movie for a codec MP4 can't carry (`VideoContainer`). The item is held throughout. Nil, after saying
    /// why, when it failed.
    func muteAudio(_ item: HistoryItem) async -> HistoryItem? {
        history.holds.hold(item.id)
        defer { history.holds.release(item.id) }
        let source = workingCopy(for: item)
        let temporary: URL
        do {
            let plan = VideoEditPlan.mute(try await VideoThumbnail.info(of: source))
            temporary = HistoryWriter.temporaryEditURL(for: item, prefix: ".mute-", pathExtension: plan.container.fileExtension,
                                                       root: history.root)
            // A failed export removes what it wrote.
            try await RecordingExporter.export(source, to: temporary, plan: plan)
        } catch {
            Log.recording.error("Couldn't remove the audio from \(item.displayName): \(error)")
            showAlert(message: "The audio couldn't be removed", error: error)
            return nil
        }
        return await replaceMedia(of: item, withExport: temporary)
    }

    /// Replaces a video's working copy with `file`, an MP4 (or a QuickTime movie, `VideoContainer`) exported into its item
    /// folder (Mute Audio…, the Video Editor's Replace), reading its size, length, audio and first frame; the saved file
    /// goes with it, as `replaceMedia(of:withFile:…)` says. Nil, after saying why, when it failed; `file` is gone either
    /// way.
    func replaceMedia(of item: HistoryItem, withExport file: URL) async -> HistoryItem? {
        let probed: (info: VideoSourceInfo, thumbnail: CGImage)
        do {
            probed = (try await VideoThumbnail.info(of: file), try await VideoThumbnail.image(of: file))
        } catch {
            try? FileManager.default.removeItem(at: file)
            Log.recording.error("Couldn't read the exported video for \(item.displayName): \(error)")
            showAlert(message: "The video couldn't be saved", error: error)
            return nil
        }
        return await replaceMedia(of: item, withFile: file, pixelWidth: probed.info.pixelWidth,
                                  pixelHeight: probed.info.pixelHeight, duration: probed.info.duration,
                                  hasAudio: !probed.info.audioChannelCounts.isEmpty, thumbnail: probed.thumbnail)
    }

    /// Replaces a video's or GIF's working copy with `file` (moved in; its extension becomes the working copy's) and
    /// its thumbnail, then brings the saved file up to date (`HistoryWriter.rewriteSavedMedia`): a clone of the edit
    /// when ClearShot wrote it and nothing has changed it since; one in another format (a `.mov` saved before the edit
    /// wrote MP4) stays as it was, and the edit is saved beside it, which the HUD names ("Saved as Clip.mp4") and
    /// copies, drags and Open With then hand out. As with an image change, the working copy is the source of truth:
    /// once it is replaced, the updated item is recorded and returned even if the saved file wasn't, which an alert
    /// then says. The item is held while this runs. Nil, after saying why, only when the working copy couldn't be
    /// replaced; `file` is gone either way.
    func replaceMedia(of item: HistoryItem, withFile file: URL, pixelWidth: Int, pixelHeight: Int, duration: Double,
                      hasAudio: Bool, thumbnail: CGImage) async -> HistoryItem? {
        history.holds.hold(item.id)
        defer { history.holds.release(item.id) }
        let noun = item.kind == .gif ? "GIF" : "video"
        // The item as it is now, so a save or rename made meanwhile survives. One that left history has lost its folder.
        guard let current = history.item(id: item.id) else {
            try? FileManager.default.removeItem(at: file)
            runAlert(message: "The \(noun) was removed from ClearShot's history, so the change can't be saved to it.", detail: "")
            return nil
        }
        let root = history.root
        typealias Replaced = (item: HistoryItem, savedFile: Result<HistoryWriter.SavedMediaRewrite, any Error>)
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Replaced, any Error> in
            Result {
                var updated = try HistoryWriter.replaceMedia(of: current, movingFile: file, pixelWidth: pixelWidth,
                                                             pixelHeight: pixelHeight, duration: duration, hasAudio: hasAudio,
                                                             thumbnail: thumbnail, root: root)
                var rewritten = updated
                let savedFile = Result { try HistoryWriter.rewriteSavedMedia(of: current, updating: &rewritten, root: root) }
                if case .success = savedFile { updated = rewritten }
                return (updated, savedFile)
            }
        }.value
        switch outcome {
        case .success(let (updated, savedFile)):
            do {
                try history.update(updated)
            } catch {
                Log.history.error("Couldn't record the change to \(updated.displayName) in history: \(error)")
            }
            switch savedFile {
            case .success(.savedBeside(let url)):
                Log.capture.info("Saved the edited \(noun) as \(url.lastPathComponent): the saved file is .\(current.savedURL?.pathExtension ?? "")")
                hud.show("Saved as \(url.lastPathComponent)", symbol: "checkmark.circle.fill")
            case .success(.editedElsewhere):
                Log.capture.info("Left the saved file for \(updated.displayName) alone: it was edited in another app")
                // After this returns, so the thumbnail shows the new picture before the alert blocks.
                Task {
                    showAlert(message: "The \(noun) changed, but the saved file was edited in another app, so ClearShot left it alone.",
                              error: SavedFileEditedElsewhere(noun: noun))
                }
            case .failure(let error):
                Log.capture.error("Couldn't rewrite the saved file for \(updated.displayName): \(error)")
                Task { showAlert(message: "The \(noun) changed, but the saved file wasn't updated", error: error) }
            case .success(.replaced), .success(.noSavedFile):
                break
            }
            return updated
        case .failure(let error):
            try? FileManager.default.removeItem(at: file)
            Log.capture.error("Couldn't replace the \(noun) of \(item.displayName): \(error)")
            showAlert(message: "The \(noun) couldn't be saved", error: error)
            return nil
        }
    }
}
