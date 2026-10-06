import AppKit
import CSAnnotation

/// Text: click empty canvas to type new text, or click existing text to edit it.
final class TextTool: ToolController {
    private unowned let editor: AnnotationEditor
    private unowned let canvas: AnnotationCanvasView

    init(editor: AnnotationEditor, canvas: AnnotationCanvasView) {
        self.editor = editor
        self.canvas = canvas
    }

    var cursor: NSCursor { .iBeam }

    func mouseDown(at point: CGPoint, event: NSEvent) {}
    func mouseDragged(to point: CGPoint, event: NSEvent) {}

    func mouseUp(at point: CGPoint, event: NSEvent) {
        // Whatever edit is still open ends before this click opens a live change of its own.
        canvas.endTextEditing()
        let tolerance = 4 * canvas.basePixelsPerScreenPoint
        if let hit = editor.document.visualOrder.reversed().first(where: { object in
            if case .text = object.kind { ObjectGeometry.hitTest(object, at: point, tolerance: tolerance) } else { false }
        }) {
            canvas.beginEditingText(hit.id, isNew: false)
            return
        }
        let settings = editor.settings
        let fontSize = editor.document.pixels(fromPoints: ToolSizes.fontSize(settings.sizeLevel))
        // Put the first line's middle under the pointer.
        let text = TextObject(origin: CGPoint(x: point.x, y: point.y - fontSize * 0.6), string: "", style: settings.textStyle,
                              fontSize: fontSize)
        let object = AnnotationObject(kind: .text(text), style: editor.newStyle(lineWidthPoints: 1))
        editor.beginLiveChange()
        editor.updateLive { $0.objects.append(object) }
        canvas.beginEditingText(object.id, isNew: true)
    }
}
