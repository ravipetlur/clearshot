import AppKit
import CSAnnotation
import CSCore
import UniformTypeIdentifiers

/// File › Export Before/After GIF…
extension AnnotateManager {
    /// A two-frame looping GIF, the picture without its topmost image and then with it (`BeforeAfterGIF`), saved where a
    /// save panel says, named as Save As names the picture. The panel starts in the last Save As folder. Refused while
    /// another Save or Save As of this editor is running.
    func exportBeforeAfterGIF(_ editor: AnnotationEditor) async {
        guard !editor.isSaving, BeforeAfterGIF.isAvailable(for: editor.document) else { return }
        editor.isSaving = true
        defer { editor.isSaving = false }
        let lastFolder = preferences[Prefs.annotateLastSaveFolder]
        let folder = lastFolder.isEmpty ? preferences[Prefs.exportLocation] : URL(filePath: lastFolder, directoryHint: .isDirectory)
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = FileNamer.sanitize(editor.title, removeIllegalCharacters: true) + ".gif"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let document = editor.document
        let images = editor.images
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Void, any Error> in
            Result {
                let data = try BeforeAfterGIF.data(for: document, images: images)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
        }.value
        switch outcome {
        case .success:
            hud.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)", symbol: "checkmark.circle.fill")
        case .failure(let error):
            Log.annotate.error("Export Before/After GIF failed: \(error)")
            showAlert(for: error)
        }
    }
}
