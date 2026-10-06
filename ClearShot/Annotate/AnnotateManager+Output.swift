import AppKit
import CSAnnotation
import CSCapture
import CSCore
import CSHistory

/// The editor's outputs.
extension AnnotateManager {
    /// The finished picture, rendered off the main actor.
    func render(_ editor: AnnotationEditor) async -> CGImage? {
        let document = editor.document
        let images = editor.images
        return await Task.detached(priority: .userInitiated) { Renderer.render(document, images: images) }.value
    }

    /// The finished picture as PNG data and, when `name` is given, as a file of that name in the temporary folder (copy,
    /// share), in a folder of its own. Rendered, encoded and written once, off the main actor. The file is nil if it
    /// couldn't be written.
    func renderPNG(_ editor: AnnotationEditor, fileNamed name: String?) async -> (data: Data, file: URL?)? {
        let document = editor.document
        let images = editor.images
        let screenCapture = screenCaptureTag(of: editor)
        return await Task.detached(priority: .userInitiated) {
            Self.makePNG(document, images: images, fileNamed: name, screenCapture: screenCapture)
        }.value
    }

    /// What marks the editor's files as a screenshot: a captured screenshot's tag, so its Save As, copies, shares and
    /// drags carry it as its saved file does; an opened image's or a project's files have none.
    func screenCaptureTag(of editor: AnnotationEditor) -> ScreenCaptureTag? {
        if case .history(let item) = editor.source { item.screenCaptureTag } else { nil }
    }

    nonisolated static func makePNG(_ document: AnnotationDocument, images: ImageStore, fileNamed name: String?,
                                    subfolder: String? = nil, screenCapture: ScreenCaptureTag?) -> (data: Data, file: URL?)? {
        guard let image = Renderer.render(document, images: images),
              let data = try? ImageEncoder.encode(image, as: .png, quality: 1, pixelsPerPoint: document.renderedScale)
        else { return nil }
        let file = name.flatMap { writeTemporaryPNG(data, name: $0, subfolder: subfolder) }
        if let file, let screenCapture { ScreenCaptureMetadata.apply(screenCapture, to: file) }
        return (data, file)
    }

    /// A PNG in the temporary folder, named after the document, in `subfolder` of the Annotate folder or, without one, in
    /// a new folder of its own. Every Copy and Share gets its own file that way, so a later one never rewrites the file
    /// an earlier clipboard entry points to. A name with nothing usable left in it becomes "Screenshot"
    /// (`FileNamer.sanitize` does that).
    private nonisolated static func writeTemporaryPNG(_ data: Data, name: String, subfolder: String?) -> URL? {
        let folder = AfterCaptureRouter.temporaryDirectory.appending(path: "Annotate", directoryHint: .isDirectory)
            .appending(path: subfolder ?? UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: FileNamer.sanitize(name, removeIllegalCharacters: true) + ".png")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    /// "Copy screenshot to clipboard" (⇧⌘C, or ⌘C with nothing selected), in the clipboard format setting.
    func copyImage(_ editor: AnnotationEditor) async {
        let mode = preferences[Prefs.clipboardMode]
        // The file is only wanted when the clipboard carries one.
        guard let rendered = await renderPNG(editor, fileNamed: mode == .imageOnly ? nil : editor.title) else {
            hud.show("Couldn't copy to the clipboard", symbol: "exclamationmark.triangle.fill")
            return
        }
        let copied = ClipboardWriter.write(pngData: rendered.data, fileURL: rendered.file, mode: mode)
        // So deleting the capture from its thumbnail takes this copy off the clipboard too, while it's still there.
        if copied, case .history(let item) = editor.source { quickAccess.actions.noteCopied(item.id) }
        hud.show(copied ? "Copied to clipboard" : "Couldn't copy to the clipboard",
                 symbol: copied ? "doc.on.clipboard" : "exclamationmark.triangle.fill")
    }

    /// Save (⌘S). The edits are applied, then the capture gets a saved file: Done already rewrote ClearShot's own saved
    /// file; otherwise a new file goes into the export folder, the way the thumbnail's Save does it. Refused while
    /// another Save or Save As of this editor is running.
    func save(_ editor: AnnotationEditor) async -> Bool {
        guard !editor.isSaving else { return false }
        editor.isSaving = true
        defer { editor.isSaving = false }
        guard await apply(editor) else { return false }
        guard case .history(let opened) = editor.source else {
            hud.show("Saved", symbol: "checkmark.circle.fill")
            return true
        }
        // The item as it is now: a save or rename made from its thumbnail while the editor was open counts, and Done
        // (which refreshes the editor's copy) may have had nothing to write.
        let item = history.item(id: opened.id) ?? opened
        if let saved = item.savedURL, FileManager.default.fileExists(atPath: saved.path(percentEncoded: false)),
           item.savedFileIsUnchanged(modifiedAt: HistoryWriter.modificationDate(of: saved)) {
            hud.show("Saved to \(saved.deletingLastPathComponent().lastPathComponent)", symbol: "checkmark.circle.fill")
            return true
        }
        // `apply` has just replaced the working copy, so this saves what the editor shows. It says what happened itself.
        guard let updated = await quickAccess.actions.save(item) else { return false }
        editor.source = .history(updated)
        return true
    }

    /// Save As: pick a format and place, remembered for next time. `skipDialog` (⌥) uses the last folder and format.
    /// The edits go into the new file only, not into the capture; the exception is a project saved as a project, which
    /// the editor then continues with. Refused while another Save or Save As of this editor is running.
    func saveAs(_ editor: AnnotationEditor, skipDialog: Bool) async -> Bool {
        guard !editor.isSaving else { return false }
        editor.isSaving = true
        defer { editor.isSaving = false }
        let lastFolder = preferences[Prefs.annotateLastSaveFolder]
        let folder = lastFolder.isEmpty ? preferences[Prefs.exportLocation] : URL(filePath: lastFolder, directoryHint: .isDirectory)
        let lastFormat = preferences[Prefs.annotateLastSaveFormat]
        let url: URL
        let format: AnnotateSaveFormat
        if skipDialog {
            format = lastFormat
            url = FileNamer.uniqueURL(in: folder, baseName: FileNamer.sanitize(editor.title, removeIllegalCharacters: true),
                                      pathExtension: format.fileExtension)
        } else {
            guard let chosen = SaveAsPanel.run(name: editor.title, folder: folder, format: lastFormat) else { return false }
            url = chosen.url
            format = chosen.format
        }
        preferences[Prefs.annotateLastSaveFolder] = url.deletingLastPathComponent().path(percentEncoded: false)
        preferences[Prefs.annotateLastSaveFormat] = format
        let document = editor.document
        let images = editor.images
        let quality = preferences[Prefs.imageQuality]
        // A captured screenshot's picture is marked as one; an opened image's or a project's isn't.
        let screenCapture = screenCaptureTag(of: editor)
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Void, any Error> in
            Result {
                guard let rendered = Renderer.render(document, images: images) else { throw CaptureError.cannotTransform }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let imageFormat = format.imageFormat {
                    try Exporter.write(rendered, as: imageFormat, quality: quality, pixelsPerPoint: document.renderedScale, to: url,
                                       screenCapture: screenCapture)
                } else {
                    try DocumentPackage.write(document, images: images, rendered: rendered, to: url)
                }
            }
        }.value
        switch outcome {
        case .success:
            // What was written with a background is the style the next document of its kind starts from.
            BackgroundPresets.recordPrevious(document, in: preferences)
            // Not when another editor has that project open: two editors on one package would overwrite each other. This
            // one then keeps its old source, and its edits stay unapplied to it.
            if format == .project, case .project = editor.source, !hasOtherEditor(onProjectAt: url, besides: editor) {
                // The new file is the project from here on, with exactly what was written as its saved state.
                editor.source = .project(url)
                editor.markApplied(document)
            }
            hud.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)", symbol: "checkmark.circle.fill")
            return true
        case .failure(let error):
            Log.annotate.error("Save As failed: \(error)")
            showAlert(for: error)
            return false
        }
    }

    /// Print… (⌘P) starts with the picture on one page; Print on Several Pages… starts with it running down a tall
    /// picture's pages or across a wide one's. The print panel's checkbox switches between the two.
    func printImage(_ editor: AnnotationEditor, fitOnOnePage: Bool) async {
        guard let image = await render(editor) else { return }
        // Pixels per point of the finished picture: a resize changes it from the capture's own scale.
        let scale = max(editor.document.pixelScale * editor.document.transform.scale, 0.0001)
        ImagePrinter.run(image, pointSize: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale),
                         fitOnOnePage: fitOnOnePage)
    }

    /// The Share menu.
    func share(_ editor: AnnotationEditor, from view: NSView) async {
        guard let url = await renderPNG(editor, fileNamed: editor.title)?.file else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    /// The file a drag from the bottom bar carries. It shows the current edits: made on the spot, then kept for as long
    /// as the document doesn't change, so dragging again is instant. Each editor has one, in a folder of its own that
    /// nothing else writes to and that goes when the editor closes. The caller finishes any inline text edit first.
    func dragFile(for editor: AnnotationEditor) -> URL? {
        let key = ObjectIdentifier(editor)
        let document = editor.document
        if let cached = dragFiles[key], cached.document == document,
           FileManager.default.fileExists(atPath: cached.file.path(percentEncoded: false)) {
            return cached.file
        }
        guard let file = Self.makePNG(document, images: editor.images, fileNamed: editor.title,
                                      subfolder: "Drag/\(UUID().uuidString)",
                                      screenCapture: screenCaptureTag(of: editor))?.file else { return nil }
        if let stale = dragFiles[key] { try? FileManager.default.removeItem(at: stale.file.deletingLastPathComponent()) }
        dragFiles[key] = (document, file)
        return file
    }

    /// Send to Raycast AI Chat (⌘R).
    func sendToRaycast(_ editor: AnnotationEditor) async {
        guard let rendered = await renderPNG(editor, fileNamed: nil) else { return }
        RaycastBridge.send(pngData: rendered.data, hud: hud)
    }
}
