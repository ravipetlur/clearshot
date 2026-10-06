import AppKit
import CSAnnotation

/// Crop & Resize:
/// - drag a handle to resize the crop (a fixed ratio holds), drag inside it to move it, or drag outside it for a new one;
/// - edges snap to the picture's and the objects' edges within 8 points, and holding ⌘ turns snapping off;
/// - dragging past the picture expands the canvas.
///
/// Points arrive in base pixels; the crop is in output pixels.
final class CropTool: ToolController {
    private unowned let editor: AnnotationEditor
    private unowned let canvas: AnnotationCanvasView
    private var drag = Drag.none
    /// Where the press began, in output pixels. Until the pointer has moved 3 screen points from it the press is a click,
    /// which changes nothing.
    private var pressed = CGPoint.zero
    private var moved = false
    /// Snapping's targets, found once when the press begins: objects don't change during a drag.
    private var snapTargets = CropGeometry.SnapTargets.empty

    private enum Drag {
        case none
        /// `offset` keeps the handle where it sat relative to the pointer, so it doesn't jump to it.
        case handle(Handle, start: CGRect, offset: CGVector)
        case move(start: CGRect, from: CGPoint)
        case new(anchor: CGPoint)
    }

    init(editor: AnnotationEditor, canvas: AnnotationCanvasView) {
        self.editor = editor
        self.canvas = canvas
    }

    var cursor: NSCursor { .crosshair }

    /// Output pixels per point on screen at the current zoom.
    private var pixelsPerScreenPoint: Double {
        editor.document.pixelScale / max(canvas.magnification(), 0.01)
    }

    private func output(_ point: CGPoint) -> CGPoint {
        editor.document.transform.toOutput(point)
    }

    func mouseDown(at point: CGPoint, event: NSEvent) {
        guard let rect = editor.crop?.rect else { return }
        let pointer = output(point)
        pressed = pointer
        moved = false
        snapTargets = CropGeometry.snapTargets(for: editor.document)
        let tolerance = 6 * pixelsPerScreenPoint
        let grabbed = CropGeometry.handles.first { handle in
            let spot = ObjectGeometry.point(of: handle, in: rect)
            return hypot(spot.x - pointer.x, spot.y - pointer.y) <= tolerance
        }
        if let grabbed {
            let spot = ObjectGeometry.point(of: grabbed, in: rect)
            drag = .handle(grabbed, start: rect, offset: CGVector(dx: spot.x - pointer.x, dy: spot.y - pointer.y))
        } else if rect.contains(pointer) {
            drag = .move(start: rect, from: pointer)
        } else {
            drag = .new(anchor: pointer)
        }
    }

    func mouseDragged(to point: CGPoint, event: NSEvent) {
        update(to: point, event: event, final: false)
    }

    func mouseUp(at point: CGPoint, event: NSEvent) {
        update(to: point, event: event, final: true)
        drag = .none
        moved = false
    }

    private func update(to point: CGPoint, event: NSEvent, final: Bool) {
        guard editor.crop != nil else { return }
        if case .none = drag { return }
        let pointer = output(point)
        if !moved {
            // A press released without moving this far is a click: no move, no snap, no rounding, nothing recorded.
            guard hypot(pointer.x - pressed.x, pointer.y - pressed.y) >= 3 * pixelsPerScreenPoint else { return }
            moved = true
        }
        let targets = event.modifierFlags.contains(.command) ? CropGeometry.SnapTargets.empty : snapTargets
        let threshold = 8 * pixelsPerScreenPoint
        let aspect = editor.cropAspect
        let rect: CGRect
        switch drag {
        case .none:
            return
        case .handle(let handle, let start, let offset):
            let target = CropGeometry.snapped(CGPoint(x: pointer.x + offset.dx, y: pointer.y + offset.dy), to: targets, threshold: threshold)
            rect = CropGeometry.dragging(handle, of: start, to: target, aspect: aspect)
        case .move(let start, let from):
            rect = CropGeometry.snappedMove(start.offsetBy(dx: pointer.x - from.x, dy: pointer.y - from.y), to: targets,
                                            threshold: threshold)
        case .new(let anchor):
            // A click outside the crop, with no drag, keeps the crop (the dead zone above).
            let target = CropGeometry.snapped(pointer, to: targets, threshold: threshold)
            rect = CropGeometry.dragging(.corner(.bottomRight), of: CGRect(origin: anchor, size: .zero), to: target, aspect: aspect)
        }
        editor.updateCrop(rect, final: final)
    }
}
