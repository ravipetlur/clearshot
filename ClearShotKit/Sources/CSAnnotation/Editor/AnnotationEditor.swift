import CoreGraphics
import CSCore
import CSHistory
import Foundation
import Observation

/// Where an editor's document came from, and where Done writes it.
public enum EditorSource: Sendable {
    case history(HistoryItem)
    case project(URL)
}

/// One open Annotate document: the document and its images, the selection, the current tool and undo. Each change is
/// one undo step; a drag is one step from its start to its end. It lives in the package so its rules are tested; the
/// app's canvas, tools and windows drive it.
@MainActor
@Observable
public final class AnnotationEditor {
    public private(set) var document: AnnotationDocument
    public private(set) var images: ImageStore
    public var source: EditorSource
    public var selection: Set<UUID> = []
    /// Switching to a drawing tool drops the selection, so the color and size chosen for the next shape don't restyle the
    /// last one. The object just drawn stays selected until then, so it can still be adjusted. Switching to Crop & Resize
    /// starts a crop session; switching away from it applies the crop.
    public var tool: EditorTool = .select {
        didSet {
            guard tool != oldValue else { return }
            if oldValue == .crop {
                commitCrop()
                // A crop that couldn't be written (a live change is open) is dropped: no session outlives the mode.
                crop = nil
            }
            if tool == .crop { beginCrop(from: oldValue) }
            if tool != .select { selection = [] }
        }
    }
    /// Crop & Resize's pending crop, while the mode is on.
    public internal(set) var crop: CropSession?
    public var settings: AnnotateToolSettings {
        didSet { preferences[Prefs.annotateToolSettings] = settings }
    }
    /// The document as last applied to the capture or project (Done). It starts as the document that was opened.
    public private(set) var appliedDocument: AnnotationDocument
    /// Done is writing; the Done button is off and a second apply is refused until it finishes.
    public var isApplying = false
    /// Save or Save As is running; a second one (key repeat, a second click) is refused until it finishes.
    @ObservationIgnored public var isSaving = false
    /// The text object being edited inline; the canvas leaves it out of the render.
    public var editingTextID: UUID?
    /// Bumped when a tool's preview changes, so the canvas redraws.
    public var previewRevision = 0
    /// "Lock canvas": no panning while drawing.
    public var isCanvasLocked = false
    /// The Background panel is showing. It is the window's state, not the document's: undo never changes it.
    public internal(set) var isBackgroundPanelOpen = false
    /// The preset applied or saved last in this editor, which Update and auto-apply act on.
    public internal(set) var lastAppliedPresetID: UUID?
    /// The wallpaper captured behind a window in this document's images: kept for the editor's session, so the Captured
    /// wallpaper fill can be picked again after switching to another.
    public internal(set) var capturedWallpaper: ImageRef?
    /// What the canvas remembers between frames. The editor measures `outputBounds` with it too, so the canvas and the
    /// editor share one measurement of auto-balance.
    @ObservationIgnored public let renderCache = RenderCache()
    /// Bumped by each background apply and by Remove Background, so a picture that arrives after a newer choice is dropped.
    @ObservationIgnored var backgroundRequest = 0
    /// Word boxes in base pixels for the Smart Highlighter; nil until found.
    @ObservationIgnored public private(set) var wordBoxes: [CGRect]?
    @ObservationIgnored private var wordBoxSearch: Task<Void, Never>?
    @ObservationIgnored public let undoManager = UndoManager()
    @ObservationIgnored public let preferences: Preferences
    @ObservationIgnored private var liveSnapshot: AnnotationDocument?
    /// A slider drag opened the live change that is open. One that was already open (the text being typed) isn't the
    /// drag's to end, or to start over.
    @ObservationIgnored private var ownsSliderLiveChange = false
    /// The last coalescing change's name, selection and time; see `change(_:coalescing:_:)`.
    @ObservationIgnored private var lastCoalesced: (name: String, selection: Set<UUID>, time: Date)?
    /// The clock coalescing reads. Tests replace it to step time without waiting.
    @ObservationIgnored var now: () -> Date = { Date() }
    /// Where the editor logs. Tests replace it with one that writes no file, so they leave the app's log alone.
    @ObservationIgnored var log = Log.annotate
    /// The tool to come back to when Crop & Resize is applied or cancelled.
    @ObservationIgnored var toolBeforeCrop: EditorTool = .select

    public init(document: AnnotationDocument, images: ImageStore, source: EditorSource, preferences: Preferences) {
        self.document = document
        self.appliedDocument = document
        self.images = images
        self.source = source
        self.preferences = preferences
        settings = preferences[Prefs.annotateToolSettings]
        // A picture missing from the store (a damaged package) is no captured wallpaper: picking it would draw nothing.
        if let background = document.background, case .windowWallpaper = background.style.fill, let picture = background.image,
           images[picture] != nil {
            capturedWallpaper = picture
        }
    }

    /// Edits not yet applied to the capture or project. Undoing back to the applied state leaves none.
    public var hasUnappliedChanges: Bool { document != appliedDocument }

    public var title: String {
        switch source {
        case .history(let item): item.displayName
        case .project(let url): url.deletingPathExtension().lastPathComponent
        }
    }

    // MARK: Changing the document

    /// What a recorded change is to: objects, which auto-expand the canvas, or the canvas and the picture (crop, image
    /// operations, revert, fill), which never do.
    private enum ChangeKind {
        case objects, canvas
    }

    /// One undoable change to objects (add, move, resize, paste, restyle, duplicate, delete). With "Automatically expand
    /// canvas" on, the canvas grows in the same step to hold the objects it added or changed. A crop being edited follows
    /// that growth if the person hasn't cropped yet (`syncCropSessionToCanvas`).
    ///
    /// A `coalescing` change made within a second of the previous coalescing change with the same name and the same
    /// selection is applied but registers no undo of its own: the earlier registration already restores the state from
    /// before the first one. That makes a stream of changes (the system color panel while dragging) one undo step. Any
    /// other recorded change, undo or redo ends the run, and so does a different selection, so one undo never reverts two
    /// objects' changes.
    public func change(_ actionName: String, coalescing: Bool = false, _ body: (inout AnnotationDocument) -> Void) {
        commit(actionName, kind: .objects, coalescing: coalescing, body)
    }

    /// One undoable change to the canvas or the picture: a crop, an image operation, Revert to Original, the fill. It never
    /// auto-expands, so a crop may cut through objects. Coalesces like `change`.
    public func changeCanvas(_ actionName: String, coalescing: Bool = false, _ body: (inout AnnotationDocument) -> Void) {
        commit(actionName, kind: .canvas, coalescing: coalescing, body)
    }

    private func commit(_ actionName: String, kind: ChangeKind, coalescing: Bool, _ body: (inout AnnotationDocument) -> Void) {
        let before = document
        body(&document)
        if kind == .objects {
            expandCanvasIfNeeded(since: before)
            syncCropSessionToCanvas()
        }
        guard document != before else { return }
        let time = now()
        if coalescing, let last = lastCoalesced, last.name == actionName, last.selection == selection,
           time.timeIntervalSince(last.time) < 1 {
            lastCoalesced = (actionName, selection, time)
            return
        }
        recordUndo(restoring: before, actionName)
        if coalescing { lastCoalesced = (actionName, selection, time) }
    }

    /// Auto-expand canvas, when it is on: grows the canvas to hold the objects added or changed since `before`. Not
    /// with a background: what lies past the canvas shows in the padding, and past the frame is cut.
    private func expandCanvasIfNeeded(since before: AnnotationDocument) {
        guard preferences[Prefs.annotateAutoExpandCanvas], document.background == nil else { return }
        let expanded = document.expandedToFit(since: before)
        if expanded != document { document = expanded }
    }

    /// A drag-style change is open: edits go straight to the document and are recorded as one step at its end.
    public var isInLiveChange: Bool { liveSnapshot != nil }

    /// Starts a drag-style change; everything until `endLiveChange` becomes one undo step.
    public func beginLiveChange() {
        liveSnapshot = document
    }

    public func updateLive(_ body: (inout AnnotationDocument) -> Void) {
        body(&document)
    }

    /// Ends a drag-style change as one undo step. It is an object change: the canvas grows to hold what it moved, then.
    /// Crop & Resize picked while the change was open (C pressed mid-drag) gets its session now, on that canvas.
    public func endLiveChange(_ actionName: String) {
        guard let before = liveSnapshot else { return }
        liveSnapshot = nil
        expandCanvasIfNeeded(since: before)
        syncCropSessionToCanvas()
        if document != before { recordUndo(restoring: before, actionName) }
        ensureCropSession()
    }

    /// Drops a drag-style change, putting the document back. Crop & Resize picked meanwhile gets its session now.
    public func cancelLiveChange() {
        if let before = liveSnapshot { document = before }
        liveSnapshot = nil
        ensureCropSession()
    }

    /// The `onEditingChanged` of a slider that restyles the document: the whole drag is one undo step, named
    /// `actionName`. It joins a live change that is already open (the text being typed) instead of starting its own, and
    /// leaves that one open at the end.
    public func sliderEditingChanged(_ began: Bool, actionName: String) {
        if began {
            guard !isInLiveChange else { return }
            beginLiveChange()
            ownsSliderLiveChange = true
        } else if ownsSliderLiveChange {
            ownsSliderLiveChange = false
            endLiveChange(actionName)
        }
    }

    /// Runs `body` as one undo step of its own, apart from whatever was recorded before it in the same run loop event (the
    /// text edit that ends as an image is dropped). With no undo group open `body` runs at once. Otherwise the open group is
    /// the event's: the undo manager joins everything recorded in one event into one step, and closing that group by hand
    /// makes it raise when the event ends ("endUndoGrouping called with no matching begin"). So `body` waits for the group
    /// to close, and runs on the next turn of the main queue, when what it records starts a group of its own.
    public func asOneUndoStep(_ body: @escaping @MainActor () -> Void) {
        guard undoManager.groupingLevel > 0 else {
            // Explicit even though the manager would open a group itself: the step is then the same whatever `groupsByEvent` is.
            undoManager.beginUndoGrouping()
            body()
            undoManager.endUndoGrouping()
            return
        }
        final class Token: @unchecked Sendable { var observer: NSObjectProtocol? }
        let token = Token()
        token.observer = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidCloseUndoGroup, object: undoManager,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let observer = token.observer { NotificationCenter.default.removeObserver(observer) }
                token.observer = nil
                // The group has closed, but the manager is still in the middle of closing it.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.asOneUndoStep(body) } }
            }
        }
    }

    /// Records `snapshot` (the document that was written, which may be older than the current one if the person kept
    /// drawing during the write) as the applied state.
    public func markApplied(_ snapshot: AnnotationDocument) {
        appliedDocument = snapshot
    }

    public func addImage(_ image: CGImage, for ref: ImageRef) {
        images.set(image, for: ref)
    }

    /// Starts finding word boxes in the base image, once, in the background.
    public func loadWordBoxesIfNeeded() {
        guard wordBoxes == nil, wordBoxSearch == nil, let base = images[document.base] else { return }
        wordBoxSearch = Task { [weak self] in
            let boxes = await WordBoxDetector.wordBoxes(in: base)
            self?.wordBoxes = boxes
        }
    }

    /// Every undo registration goes through here (undo and redo included, via `restore`), so each one ends a run of
    /// coalescing changes.
    private func recordUndo(restoring snapshot: AnnotationDocument, _ actionName: String) {
        lastCoalesced = nil
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated { editor.restore(snapshot, actionName) }
        }
        undoManager.setActionName(actionName)
    }

    private func restore(_ snapshot: AnnotationDocument, _ actionName: String) {
        let current = document
        document = snapshot
        selection = selection.filter { id in snapshot.objects.contains { $0.id == id } }
        recordUndo(restoring: current, actionName)
        // A crop being edited starts over from the restored canvas.
        resetCropSession()
    }

    // MARK: Objects

    public func object(_ id: UUID) -> AnnotationObject? {
        document.objects.first { $0.id == id }
    }

    public var selectedObjects: [AnnotationObject] {
        document.objects.filter { selection.contains($0.id) }
    }

    /// Adds a new object and selects it.
    public func add(_ object: AnnotationObject, actionName: String) {
        change(actionName) { $0.objects.append(object) }
        selection = [object.id]
    }

    public func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        change("Delete") { $0.objects.removeAll { ids.contains($0.id) } }
        selection = []
    }

    /// A direction on screen (`delta` in points, y down) as a vector in base pixels. After Rotate or Flip the base axes
    /// differ from the screen's, so it goes through the document transform, which already includes its scale.
    public func baseVector(fromPoints delta: CGVector) -> CGVector {
        let scale = document.pixelScale
        let transform = document.transform
        let moved = transform.toBase(CGPoint(x: delta.dx * scale, y: delta.dy * scale))
        let origin = transform.toBase(.zero)
        return CGVector(dx: moved.x - origin.x, dy: moved.y - origin.y)
    }

    /// ⌘D: copies of the selection, offset a little, selected.
    public func duplicateSelection() {
        let offset = baseVector(fromPoints: CGVector(dx: 10, dy: 10))
        let copies = selectedObjects.map { object in
            var copy = ObjectGeometry.translated(object, by: offset)
            copy.id = UUID()
            return copy
        }
        guard !copies.isEmpty else { return }
        change("Duplicate") { $0.objects.append(contentsOf: copies) }
        selection = Set(copies.map(\.id))
    }

    /// Arrow keys: moves the selection by `points` (one or ten). Holding a key down repeats it; the run of moves is one
    /// undo step.
    public func nudgeSelection(by delta: CGVector) {
        guard !selection.isEmpty else { return }
        let move = baseVector(fromPoints: delta)
        let ids = selection
        change("Move", coalescing: true) { document in
            for index in document.objects.indices where ids.contains(document.objects[index].id) {
                document.objects[index] = ObjectGeometry.translated(document.objects[index], by: move)
            }
        }
    }

    /// The ratios between two documents' pixels per point that a paste will scale by. Beyond them the source scale is a bad
    /// number (the pasteboard is any app's to write), not a document, and the objects keep their size.
    static let pasteScaleLimits = (1.0 / 64)...64.0

    /// Pastes objects as new copies, offset 10 points so they don't sit exactly on the originals, moved into the canvas
    /// as far as they fit, and selected. One undo step.
    /// - `sourceScale` is the base pixels per point of the document they were copied from (its `pixels(fromPoints: 1)`).
    ///   Objects from a document at another scale are resized to look the same size here: a 2× capture's arrow pasted into
    ///   a 1× one is half as many pixels. Nil keeps their size, and so does one that makes the ratio less
    ///   than 1/64 or more than 64.
    /// - `pasted` are the bitmaps of pasted image objects, by name, from another editor. Each one an object uses joins this
    ///   document's images under a new name, held to 16 383 pixels a side as an inserted picture is (the object's rect, not
    ///   its bitmap, sets its size). An image object whose bitmap is in neither place, or can't be held to that, is left out.
    /// - An object with a number that isn't finite, after scaling, is left out too: these come from the pasteboard.
    ///
    /// Ignored while a live change is open (⌘V during a drag): the paste would join the drag's undo step.
    public func paste(_ objects: [AnnotationObject], sourceScale: Double? = nil, images pasted: [ImageRef: CGImage] = [:]) {
        guard !isInLiveChange else { return }
        let ratio = sourceScale.map { document.pixels(fromPoints: 1) / $0 } ?? 1
        let factor = Self.pasteScaleLimits.contains(ratio) ? ratio : 1
        let offset = baseVector(fromPoints: CGVector(dx: 10, dy: 10))
        var renamed: [ImageRef: ImageRef] = [:]
        let copies = objects.compactMap { object -> AnnotationObject? in
            var copy = ObjectGeometry.translated(ObjectScaling.scaled(object, by: factor), by: offset)
            guard copy.isFinite else { return nil }
            if case .image(var picture) = copy.kind, images[picture.image] == nil {
                if renamed[picture.image] == nil {
                    guard let bitmap = pasted[picture.image].flatMap({ ImagePlacement.limited($0) }) else { return nil }
                    let fresh = ImageRef(name: "images/\(UUID().uuidString).png")
                    addImage(bitmap, for: fresh)
                    renamed[picture.image] = fresh
                }
                picture.image = renamed[picture.image] ?? picture.image
                copy.kind = .image(picture)
            }
            copy.id = UUID()
            return copy
        }
        guard !copies.isEmpty else { return }
        let placed = document.clampedIntoCanvas(copies)
        change("Paste") { $0.objects.append(contentsOf: placed) }
        selection = Set(placed.map(\.id))
    }
}
