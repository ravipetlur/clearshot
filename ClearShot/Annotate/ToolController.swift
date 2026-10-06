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

    func mouseDown(at point: CGPoint, event: NSEvent) {
        let tolerance = 5 * canvas.basePixelsPerScreenPoint
        let flags = event.modifierFlags
        duplicated = false
        moved = false
        // A handle of the one selected object.
        if let handle = handle(at: point), let id = editor.selection.first, let object = editor.object(id) {
            let spot = ObjectGeometry.handlePoint(handle, of: object)
            editor.beginLiveChange()
            drag = .handle(original: object, handle: handle, offset: CGVector(dx: spot.x - point.x, dy: spot.y - point.y))
            return
        }
        let hit = editor.document.visualOrder.reversed().first { ObjectGeometry.hitTest($0, at: point, tolerance: tolerance) }
        guard let hit else {
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
            let copies = editor.selectedObjects.map { object -> AnnotationObject in
                var copy = object
                copy.id = UUID()
                return copy
            }
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
        case .marquee: marquee = nil
        case .none: break
        }
        drag = .none
    }
}
