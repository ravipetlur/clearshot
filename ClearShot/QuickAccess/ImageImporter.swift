import AppKit
import CSAPI
import CSCapture
import CSCore
import CSHistory
import CSRecording
import UniformTypeIdentifiers

/// Brings outside images and videos into the Quick Access Overlay: Open…, Open from Clipboard and Finder's Open With.
/// They become unsaved history items; the originals are never moved or rewritten, and a file opened records itself as
/// the item's `sourcePath`. Each image's scale comes from its recorded density, read as the editor reads a dropped
/// picture (`ImageInput`, the 72·n rule of `ImagePlacement.scale(forDPI:)`), so a Retina PNG that ClearShot or macOS
/// wrote reopens as a 2× item. A video is cloned in whole and opens in the Video Editor; a GIF is cloned in whole as a
/// GIF item, except where a still is wanted (open-annotate and pin take its first frame through `importFile`).
final class ImageImporter {
    private let preferences: Preferences
    private let history: HistoryStore
    private let quickAccess: QuickAccessManager
    private let hud: HUDController
    private let gate: ModalGate

    init(preferences: Preferences, history: HistoryStore, quickAccess: QuickAccessManager, hud: HUDController,
         gate: ModalGate) {
        self.preferences = preferences
        self.history = history
        self.quickAccess = quickAccess
        self.hud = hud
        self.gate = gate
    }

    /// Open… (its hotkey, the status menu): refused while a capture or recording is under way (`ModalGate`).
    func openFile() {
        guard gate.allowsQuestion() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose images or videos to open in ClearShot"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importFiles(urls) }
    }

    /// Images and videos opened from Finder (Open With, or dropped on the app).
    func open(_ urls: [URL]) {
        Task { _ = await importFiles(urls) }
    }

    /// Image or video files copied in Finder (an MP4, say), or image data copied from any app. With files on the
    /// clipboard only the image and video files among them are opened, and the image data is never used: Finder puts
    /// each copied file's icon there (`ImageInput.carriesFiles`, the editor's rule too).
    ///
    /// Everything goes to Quick Access, unless `placingImages` places the images (the URL command opens them in
    /// Annotate): video and GIF files still go to Quick Access then.
    func openFromClipboard(placingImages: (@MainActor (HistoryItem) -> Void)? = nil) {
        let pasteboard = NSPasteboard.general
        if ImageInput.carriesFiles(pasteboard) {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true,
                .urlReadingContentsConformToTypes: [UTType.image.identifier, UTType.movie.identifier],
            ]
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
            guard !urls.isEmpty else {
                hud.show("There's no image or video on the clipboard", symbol: "doc.on.clipboard")
                return
            }
            // Each file that can't be opened is reported.
            Task { await importFiles(urls, placingImages: placingImages) }
            return
        }
        Task {
            // No files (a copy ClearShot made whose temporary file has since been cleared counts as none): use the image
            // data. Read the data, not NSImage: NSImage's CGImage can come back at point size and lose Retina pixels.
            guard let picked = ImageInput.dataTypes.lazy.compactMap({ pasteboard.data(forType: $0) })
                .compactMap({ ImageInput.load(data: $0) }).first else {
                hud.show("There's no image on the clipboard", symbol: "doc.on.clipboard")
                return
            }
            let name = FileNamer.baseName(for: FileNameTemplate(parsing: "Clipboard %y-%m-%d at %H.%M.%S"), context: FileNameContext())
            let place = placingImages ?? { [quickAccess] in quickAccess.show($0) }
            await importImage(picked, origin: .clipboard, displayName: name, then: place)
        }
    }

    /// Imports one image file as an unsaved history item that records the file as its original, and hands the item to
    /// `place` (which shows it as a thumbnail or a pin) straight after adding it to the store, in the same main-actor
    /// stretch, before this returns. The file is read off the main actor: one kept only in iCloud or on a stalled
    /// network volume can't freeze ClearShot. False, after telling the person, when the file can't be read or the item
    /// can't be written.
    @discardableResult
    func importFile(_ url: URL, then place: (HistoryItem) -> Void) async -> Bool {
        let picked = await Task.detached(priority: .userInitiated) { ImageInput.load(url) }.value
        guard let picked else {
            hud.show("Couldn't open \(Self.shownName(url))", symbol: "exclamationmark.triangle.fill")
            return false
        }
        return await importImage(picked, from: url, then: place)
    }

    /// `importFile` for a picture already read from `url` (a URL command's file, which the router reads itself through
    /// `APIFiles.read`): an unsaved history item that records `url` as its original, handed to `place` as `importFile`
    /// hands it. False, after telling the person, when the item can't be written.
    @discardableResult
    func importImage(_ picked: ImageInput.Picked, from url: URL, then place: (HistoryItem) -> Void) async -> Bool {
        await importImage(picked, origin: .file, displayName: url.deletingPathExtension().lastPathComponent,
                          sourcePath: url.path(percentEncoded: false), then: place)
    }

    /// Imports a video file (Open…, Open from Clipboard, Finder's Open With) as an unsaved history item that records the
    /// file as its original: the file is cloned in whole (`createMedia(…, transfer: .copy)`), with its first frame as
    /// the thumbnail, and handed to `place` straight after it is added to the store. False, after telling the person,
    /// when it has no video track ("The source file does not contain a video track."), can't be read, or the item
    /// can't be written.
    @discardableResult
    func importVideo(_ url: URL, then place: (HistoryItem) -> Void) async -> Bool {
        let name = FileNamer.sanitize(url.deletingPathExtension().lastPathComponent,
                                      removeIllegalCharacters: preferences[Prefs.fileNameRemoveIllegalCharacters])
        let details = HistoryWriter.Details(kind: .video, origin: .file, captureKind: .selection, displayName: name,
                                            savedURL: nil, scale: 1, appName: nil, isTransparent: false, globalRect: .zero,
                                            createdAt: Date(), sourcePath: url.path(percentEncoded: false))
        let outcome: Result<HistoryItem, any Error>
        do {
            let info = try await VideoThumbnail.info(of: url)
            let thumbnail = try await VideoThumbnail.image(of: url)
            outcome = .success(try await Self.createVideoItem(url, info: info, thumbnail: thumbnail, details: details,
                                                             root: history.root))
        } catch {
            outcome = .failure(error)
        }
        switch outcome {
        case .success(let item):
            // Held from before it is listed until `place` has shown it, as for an image.
            history.holds.hold(item.id)
            history.add(item)
            place(item)
            history.holds.release(item.id)
            return true
        case .failure(let error):
            Log.history.error("Couldn't open the video \(url.lastPathComponent): \(error)")
            let noVideo = (error as? VideoFileError) == .noVideoTrack
            hud.show(noVideo ? "The source file does not contain a video track."
                         : "Couldn't open \(Self.shownName(url))", symbol: "exclamationmark.triangle.fill")
            return false
        }
    }

    /// Clones the video into a new item folder, off the main actor.
    @concurrent
    private nonisolated static func createVideoItem(_ url: URL, info: VideoSourceInfo, thumbnail: CGImage,
                                                    details: HistoryWriter.Details, root: URL) async throws -> HistoryItem {
        try HistoryWriter.createMedia(url, transfer: .copy, pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight,
                                      duration: info.duration, hasAudio: !info.audioChannelCounts.isEmpty,
                                      thumbnail: thumbnail, details: details, root: root)
    }

    /// Imports a GIF file (Open…, Open from Clipboard, Finder's Open With, add-quick-access-overlay) as an unsaved GIF
    /// item that records the file as its original, not as a still of its first frame: the file is cloned in whole, its
    /// first frame is the thumbnail, and its length is its frames' delays. It was never recorded here, so it has no
    /// source video and can't be trimmed (`HistoryItem.opensInVideoEditor`). Held from before it is listed until
    /// `place` has shown it, as for a video. False, after saying "Couldn't open <name>", when ImageIO doesn't read it
    /// as a GIF or the item can't be written.
    @discardableResult
    func importGIF(_ url: URL, then place: (HistoryItem) -> Void) async -> Bool {
        let name = FileNamer.sanitize(url.deletingPathExtension().lastPathComponent,
                                      removeIllegalCharacters: preferences[Prefs.fileNameRemoveIllegalCharacters])
        let details = HistoryWriter.Details(kind: .gif, origin: .file, captureKind: .selection, displayName: name,
                                            savedURL: nil, scale: 1, appName: nil, isTransparent: false, globalRect: .zero,
                                            createdAt: Date(), sourcePath: url.path(percentEncoded: false))
        switch await Self.createGIFItem(url, details: details, root: history.root) {
        case .success(let item)?:
            history.holds.hold(item.id)
            history.add(item)
            place(item)
            history.holds.release(item.id)
            return true
        case .failure(let error)?:
            Log.history.error("Couldn't open the GIF \(url.lastPathComponent): \(error)")
        case nil:
            Log.history.error("Couldn't open \(url.lastPathComponent): it can't be read as a GIF")
        }
        hud.show("Couldn't open \(Self.shownName(url))", symbol: "exclamationmark.triangle.fill")
        return false
    }

    /// Reads the GIF and clones it into a new item folder, off the main actor. Nil when it can't be read as a GIF.
    @concurrent
    private nonisolated static func createGIFItem(_ url: URL, details: HistoryWriter.Details,
                                                  root: URL) async -> Result<HistoryItem, any Error>? {
        guard let info = GIFFileInfo.read(url), let thumbnail = ImageOps.load(url) else { return nil }
        return Result {
            try HistoryWriter.createMedia(url, transfer: .copy, pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight,
                                          duration: info.duration, hasAudio: false, thumbnail: thumbnail, details: details,
                                          root: root)
        }
    }

    /// A file's name as a HUD shows it: on one line and at most 40 characters (`SenderText.shown`), since a URL command
    /// (add-quick-access-overlay) can name any file.
    private static func shownName(_ url: URL) -> String {
        SenderText.shown(url.lastPathComponent)
    }

    /// Whether the file is a movie, to open as a video rather than an image: its content type, else its extension's.
    nonisolated static func isMovie(_ url: URL) -> Bool {
        let fileType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        return fileType?.conforms(to: .movie) ?? false
    }

    /// Whether the file is a GIF, to open as a GIF item rather than a still image. By its contents, not its name
    /// (`GIFFileInfo.isGIF`): a PNG or WebP saved under a `.gif` name opens as the image it is. That reads the file, which
    /// for one kept only in iCloud means downloading it, so it runs off the main actor.
    @concurrent
    nonisolated static func isGIF(_ url: URL) async -> Bool {
        GIFFileInfo.isGIF(url)
    }

    /// Imports the files one after another, so the thumbnails stack in the order given: GIFs as GIFs (checked first: a
    /// GIF is an image too), videos as videos, everything else as images. Images go to `placingImages` when given; GIFs
    /// and videos, and every image without it, go to Quick Access. Returns how many were opened.
    private func importFiles(_ urls: [URL], placingImages: (@MainActor (HistoryItem) -> Void)? = nil) async -> Int {
        var imported = 0
        for url in urls {
            let opened: Bool
            if await Self.isGIF(url) {
                opened = await importGIF(url, then: { quickAccess.show($0) })
            } else if Self.isMovie(url) {
                opened = await importVideo(url, then: { quickAccess.show($0) })
            } else if let placingImages {
                opened = await importFile(url, then: placingImages)
            } else {
                opened = await importFile(url, then: { quickAccess.show($0) })
            }
            if opened { imported += 1 }
        }
        return imported
    }

    /// Writes the history item, at the picture's own scale, adds it to the store and hands it to `place`. False, after
    /// telling the person, if it couldn't be written.
    ///
    /// The item is held from before it is listed until `place` has shown it, and so holds it too: a release in between
    /// (even one an observer of `.added` causes) would purge it under retention "Never". If `place` doesn't show it,
    /// letting go here leaves it to that purge, like any capture shown nowhere.
    @discardableResult
    private func importImage(_ picked: ImageInput.Picked, origin: HistoryOrigin, displayName: String,
                             sourcePath: String? = nil, then place: (HistoryItem) -> Void) async -> Bool {
        let (image, scale) = picked
        let name = FileNamer.sanitize(displayName, removeIllegalCharacters: preferences[Prefs.fileNameRemoveIllegalCharacters])
        let root = history.root
        let createdAt = Date()
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<HistoryItem, any Error> in
            Result {
                // The transparency check reads every pixel, so it belongs here and not on the main actor.
                let details = HistoryWriter.Details(origin: origin, captureKind: .selection, displayName: name, savedURL: nil,
                                                    scale: scale, appName: nil, isTransparent: ImageOps.hasTransparentPixels(image),
                                                    globalRect: .zero, createdAt: createdAt, sourcePath: sourcePath)
                return try HistoryWriter.create(image, details: details, root: root)
            }
        }.value
        switch outcome {
        case .success(let item):
            history.holds.hold(item.id)
            history.add(item)
            place(item)
            history.holds.release(item.id)
            return true
        case .failure(let error):
            Log.history.error("Couldn't open the image: \(error)")
            hud.show("Couldn't open the image", symbol: "exclamationmark.triangle.fill")
            return false
        }
    }
}
