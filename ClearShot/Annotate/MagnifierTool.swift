import AppKit
import CSAnnotation

/// The magnifier: drag out the area to magnify (⇧ makes it square); its callout appears beside it at 3×. A click
/// magnifies a small square around the point.
final class MagnifierTool: ToolController {
    private unowned let editor: AnnotationEditor
    private unowned let canvas: AnnotationCanvasView
    private var anchor: CGPoint?
    private(set) var preview: AnnotationObject?
    /// One id while dragging, so the preview is one object throughout.
    private let previewID = UUID()

    init(editor: AnnotationEditor, canvas: AnnotationCanvasView) {
        self.editor = editor
        self.canvas = canvas
    }

    func mouseDown(at point: CGPoint, event: NSEvent) {
        anchor = point
        preview = nil
    }

    func mouseDragged(to point: CGPoint, event: NSEvent) {
        guard let anchor else { return }
        preview = editor.newMagnifier(source: source(from: anchor, to: point, event: event), id: previewID)
        editor.previewRevision += 1
    }

    func mouseUp(at point: CGPoint, event: NSEvent) {
        defer {
            anchor = nil
            preview = nil
            editor.previewRevision += 1
        }
        // The release can land past the last drag event, so the source is made from the release point.
        guard let anchor else { return }
        editor.add(editor.newMagnifier(source: source(from: anchor, to: point, event: event)), actionName: "Add Magnifier")
    }

    /// The dragged rect; a click or a tiny drag takes a square of 40 points around the press.
    private func source(from anchor: CGPoint, to point: CGPoint, event: NSEvent) -> CGRect {
        let rect = ShapeConstraints.rect(from: anchor, to: point, square: event.modifierFlags.contains(.shift))
        guard min(rect.width, rect.height) < 3 * canvas.basePixelsPerScreenPoint else { return rect }
        let side = editor.document.pixels(fromPoints: 40)
        return CGRect(x: anchor.x - side / 2, y: anchor.y - side / 2, width: side, height: side)
    }
}
