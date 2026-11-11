import AppKit
import CSAnnotation

/// A tool's handling of the mouse on the canvas. Points are in base pixels.
protocol ToolController: AnyObject {
    func mouseDown(at point: CGPoint, event: NSEvent)
    func mouseDragged(to point: CGPoint, event: NSEvent)
    func mouseUp(at point: CGPoint, event: NSEvent)
    /// An object being drawn, shown on the canvas until mouse-up.
    var preview: AnnotationObject? { get }
    /// The select tool's rubber band, in base pixels.
    var marquee: CGRect? { get }
    var cursor: NSCursor { get }
}

extension ToolController {
    var preview: AnnotationObject? { nil }
    var marquee: CGRect? { nil }
    var cursor: NSCursor { .crosshair }
}

/// Select, move, resize, duplicate (⌥-drag) and rubber-band selection.
final class SelectTool: ToolController {
    private unowned let editor: AnnotationEditor
    private unowned let canvas: AnnotationCanvasView
    /// Double-click on a text object: the canvas opens the inline editor.
    var onEditText: ((UUID) -> Void)?
    private(set) var marquee: CGRect?
    private var drag = Drag.none
    private var duplicated = false
    /// Where the press on a pixel selection's handle began, until it has moved: a release with it still set was a click.
    private var handleDown: CGPoint?
    /// The mouse has moved since a move drag began; an ⌥-click that never moves leaves no copy behind.
    private var moved = false
    /// What was selected when ⌥ made the copies, which become the selection while they are dragged.
    private var selectionBeforeDuplicating: Set<UUID> = []

    private enum Drag {
        case none
        /// `offset` is where the handle sat relative to the mouse-down, so the handle keeps its distance from the
        /// cursor instead of jumping to it.
        case handle(original: AnnotationObject, handle: Handle, offset: CGVector)
        case move(originals: [UUID: AnnotationObject], start: CGPoint)
        case marquee(start: CGPoint, kept: Set<UUID>)
        /// ⌥-drag on empty canvas: the rubber band is a pixel selection, not a pick of objects.
        case pixelMarquee(start: CGPoint)
        case pixelHandle(Handle)
        case pixelMove(original: CGRect, start: CGPoint)
    }

    init(editor: AnnotationEditor, canvas: AnnotationCanvasView) {
        self.editor = editor
        self.canvas = canvas
    }

    var cursor: NSCursor { .arrow }

    /// The handle of the one selected object under `point`. The canvas also asks, to let a press on a handle reach this
    /// tool while a drawing tool is active.
    func handle(at point: CGPoint) -> Handle? {
        guard editor.selection.count == 1, let id = editor.selection.first, let object = editor.object(id) else { return nil }
        let tolerance = 5 * canvas.basePixelsPerScreenPoint * 1.6
        return ObjectGeometry.handles(of: object).first { handle in
            let spot = ObjectGeometry.handlePoint(handle, of: object)
            return hypot(spot.x - point.x, spot.y - point.y) <= tolerance
        }
    }

    /// The handle of the pixel selection under `point`, corners before edges.
    private func pixelHandle(at point: CGPoint) -> Handle? {
        guard let rect = editor.pixelSelection else { return nil }
        let tolerance = 6 * canvas.basePixelsPerScreenPoint
        return CropGeometry.handles.first { handle in
            let spot = ObjectGeometry.point(of: handle, in: rect)
            return hypot(spot.x - point.x, spot.y - point.y) <= tolerance
        }
    }

    func mouseDown(at point: CGPoint, event: NSEvent) {
        let tolerance = 5 * canvas.basePixelsPerScreenPoint
        let flags = event.modifierFlags
        duplicated = false
        moved = false
        // A handle of the one selected object.
        if let handle = handle(at: point), let id = editor.selection.first, let object = editor.object(id) {
            if handle == .control, event.clickCount == 2 {
                // Double-clicking an arrow's bend handle straightens it.
                editor.straightenArrow(id)
                return
            }
            let spot = ObjectGeometry.handlePoint(handle, of: object)
            editor.beginLiveChange()
            drag = .handle(original: object, handle: handle, offset: CGVector(dx: spot.x - point.x, dy: spot.y - point.y))
            return
        }
        // The pixel selection's handles.
        if let handle = pixelHandle(at: point) {
            drag = .pixelHandle(handle)
            handleDown = point
            return
        }
        let hit = editor.document.visualOrder.reversed().first { ObjectGeometry.hitTest($0, at: point, tolerance: tolerance) }
        guard let hit else {
            // ⌘-click on empty picture: the flat-colour region under it becomes the pixel selection (a click on an object
            // keeps its meaning, above).
            if flags.contains(.command), !flags.contains(.option), !flags.contains(.shift), editor.crop == nil {
                editor.selection = []
                let editor = editor
                Task { await editor.selectFlatRegion(at: point) }
                return
            }
            // On empty canvas: inside the pixel selection a drag moves it; ⌥-drag makes a new one (the plain drag is the
            // rubber band, which keeps its meaning: a band that catches no object leaves a pixel selection too, see mouseUp);
            // a click elsewhere clears it.
            if let rect = editor.pixelSelection, rect.contains(point), !flags.contains(.option) {
                drag = .pixelMove(original: rect, start: point)
                return
            }
            if flags.contains(.option) {
                editor.selection = []
                editor.clearPixelSelection()
                marquee = CGRect(origin: point, size: .zero)
                drag = .pixelMarquee(start: point)
                editor.loadPicturePixels()   // for the fit preview while dragging
                return
            }
            editor.clearPixelSelection()
            let kept = flags.contains(.shift) ? editor.selection : []
            editor.selection = kept
            marquee = CGRect(origin: point, size: .zero)
            drag = .marquee(start: point, kept: kept)
            return
        }
        if event.clickCount == 2, case .text = hit.kind {
            onEditText?(hit.id)
            return
        }
        if flags.contains(.shift) {
            if editor.selection.contains(hit.id) {
                editor.selection.remove(hit.id)
                return
            }
            editor.selection.insert(hit.id)
        } else if !editor.selection.contains(hit.id) {
            editor.selection = [hit.id]
        }
        editor.beginLiveChange()
        if flags.contains(.option) {
            // ⌥-drag duplicates: drag copies, leave the originals.
            // A copy of one of the secrets check's masks is the person's own: not marked (`copied`).
            let copies = editor.selectedObjects.map { $0.copied() }
            editor.updateLive { $0.objects.append(contentsOf: copies) }
            selectionBeforeDuplicating = editor.selection
            editor.selection = Set(copies.map(\.id))
            duplicated = true
        }
        // A corrupt document with two objects of one id must not crash the tool: the first one wins.
        drag = .move(originals: Dictionary(editor.selectedObjects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                     start: point)
    }

    func mouseDragged(to point: CGPoint, event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .handle(let original, let handle, let offset):
            let target = CGPoint(x: point.x + offset.dx, y: point.y + offset.dy)
            let updated = ObjectGeometry.dragging(handle, of: original, to: target, constrained: shift)
            editor.updateLive { document in
                if let index = document.objects.firstIndex(where: { $0.id == original.id }) { document.objects[index] = updated }
            }
        case .move(let originals, let start):
            var delta = CGVector(dx: point.x - start.x, dy: point.y - start.y)
            if shift { delta = ShapeConstraints.axisLocked(delta) }
            if delta.dx != 0 || delta.dy != 0 { moved = true }
            editor.updateLive { document in
                for index in document.objects.indices {
                    if let original = originals[document.objects[index].id] {
                        document.objects[index] = ObjectGeometry.translated(original, by: delta)
                    }
                }
            }
        case .marquee(let start, let kept):
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            marquee = rect
            let inside = editor.document.objects.filter { ObjectGeometry.bounds(of: $0).intersects(rect) }.map(\.id)
            editor.selection = kept.union(inside)
        case .pixelMarquee(let start):
            marquee = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            // The outline the drag would fit to (⌥A applies it), when it is cheap enough to work out.
            editor.showFitPreview(of: PixelSelection.between(start, point, in: editor.document.baseSize))
        case .pixelHandle(let handle):
            guard let rect = editor.pixelSelection else { break }
            if let down = handleDown, hypot(point.x - down.x, point.y - down.y) <= 3 * canvas.basePixelsPerScreenPoint { break }
            handleDown = nil
            editor.selectPixels(PixelSelection.dragging(handle, of: rect, to: point, in: editor.document.baseSize))
        case .pixelMove(let original, let start):
            editor.selectPixels(PixelSelection.nudged(original, by: CGVector(dx: point.x - start.x, dy: point.y - start.y),
                                                      in: editor.document.baseSize))
        case .none:
            break
        }
    }

    func mouseUp(at point: CGPoint, event: NSEvent) {
        switch drag {
        case .handle: editor.endLiveChange("Resize")
        case .move:
            if duplicated, !moved {
                // ⌥-click without dragging: drop the copies the mouse-down made, and select the originals again.
                editor.cancelLiveChange()
                editor.selection = selectionBeforeDuplicating
            } else {
                editor.endLiveChange(duplicated ? "Duplicate" : "Move")
            }
        case .marquee:
            // A band that caught no object stays as a pixel selection (a click is not a band).
            if let band = marquee, editor.selection.isEmpty, band.width + band.height > 6 * canvas.basePixelsPerScreenPoint {
                editor.selectPixels(PixelSelection.between(band.origin, CGPoint(x: band.maxX, y: band.maxY), in: editor.document.baseSize))
            }
            marquee = nil
        case .pixelMarquee(let start):
            if hypot(point.x - start.x, point.y - start.y) > 3 * canvas.basePixelsPerScreenPoint {
                editor.selectPixels(PixelSelection.between(start, point, in: editor.document.baseSize))
            }
            editor.showFitPreview(of: nil)
            marquee = nil
        case .pixelHandle(let handle):
            // A click on an edge's handle, without a drag, fits that edge alone to the content.
            if handleDown != nil, case .edge(let edge) = handle {
                let editor = editor
                Task { await editor.fitPixelSelectionToContent(edges: [edge]) }
            }
            handleDown = nil
        case .pixelMove: break
        case .none: break
        }
        drag = .none
    }
}
