import AppKit
import CSAnnotation
import CSCore

/// Rectangle, filled rectangle, ellipse, redact and spotlight: drag out a rect; ⇧ makes it square.
final class ShapeTool: ToolController {
    enum Kind {
        case rectangle, filledRectangle, ellipse, redact, spotlight
    }

    private unowned let editor: AnnotationEditor
    private unowned let canvas: AnnotationCanvasView
    private let kind: Kind
    private var anchor: CGPoint?
    private(set) var preview: AnnotationObject?
    /// One id while drawing, so the canvas's redaction cache reuses its slot during the drag.
    private let previewID = UUID()

    init(_ kind: Kind, editor: AnnotationEditor, canvas: AnnotationCanvasView) {
        self.kind = kind
        self.editor = editor
        self.canvas = canvas
    }

    func mouseDown(at point: CGPoint, event: NSEvent) {
        anchor = point
        preview = nil
    }

    func mouseDragged(to point: CGPoint, event: NSEvent) {
        guard let anchor else { return }
        preview = object(in: ShapeConstraints.rect(from: anchor, to: point, square: event.modifierFlags.contains(.shift)))
        editor.previewRevision += 1
    }

    func mouseUp(at point: CGPoint, event: NSEvent) {
        defer {
            anchor = nil
            preview = nil
            editor.previewRevision += 1
        }
        // The release can land past the last drag event, so the shape is made from the release point.
        guard let anchor else { return }
        var drawn = object(in: ShapeConstraints.rect(from: anchor, to: point, square: event.modifierFlags.contains(.shift)))
        guard let rect = ObjectGeometry.rect(of: drawn.kind),
              min(rect.width, rect.height) >= 3 * canvas.basePixelsPerScreenPoint else { return }
        drawn.id = UUID()
        editor.add(drawn, actionName: actionName)
    }

    private var actionName: String {
        switch kind {
        case .rectangle, .filledRectangle: "Add Rectangle"
        case .ellipse: "Add Ellipse"
        case .redact: "Add Redaction"
        case .spotlight: "Add Spotlight"
        }
    }

    private func object(in rect: CGRect) -> AnnotationObject {
        let settings = editor.settings
        let style = editor.newStyle(lineWidthPoints: ToolSizes.lineWidth(settings.sizeLevel))
        let kind: ObjectKind = switch self.kind {
        case .rectangle: .rectangle(rect)
        case .filledRectangle: .filledRectangle(rect)
        case .ellipse: .ellipse(rect)
        case .redact: .redact(RedactObject(rect: rect, style: settings.redactStyle, intensity: settings.redactIntensity))
        case .spotlight: .spotlight(SpotlightObject(rect: rect, shape: settings.spotlightShape, opacity: settings.spotlightOpacity))
        }
        return AnnotationObject(id: previewID, kind: kind, style: style)
    }
}

/// Line and arrow: drag from start to end; ⇧ snaps to 45°; ⌥ reverses an arrow, or with "Invert arrows" on, doesn't.
final class LineTool: ToolController {
    private unowned let editor: AnnotationEditor
    private unowned let canvas: AnnotationCanvasView
    private let isArrow: Bool
    private var start: CGPoint?
    private(set) var preview: AnnotationObject?

    init(arrow: Bool, editor: AnnotationEditor, canvas: AnnotationCanvasView) {
        isArrow = arrow
        self.editor = editor
        self.canvas = canvas
    }

    func mouseDown(at point: CGPoint, event: NSEvent) {
        start = point
        preview = nil
    }

    func mouseDragged(to point: CGPoint, event: NSEvent) {
        guard let start else { return }
        preview = object(from: start, to: point, event: event)
        editor.previewRevision += 1
    }

    func mouseUp(at point: CGPoint, event: NSEvent) {
        defer {
            start = nil
            preview = nil
            editor.previewRevision += 1
        }
        // The release can land past the last drag event, so the line is made from the release point.
        guard let start, hypot(point.x - start.x, point.y - start.y) >= 3 * canvas.basePixelsPerScreenPoint else { return }
        editor.add(object(from: start, to: point, event: event), actionName: isArrow ? "Add Arrow" : "Add Line")
    }

    private func object(from start: CGPoint, to point: CGPoint, event: NSEvent) -> AnnotationObject {
        let end = event.modifierFlags.contains(.shift) ? ShapeConstraints.snapped(point, from: start) : point
        let inverted = editor.preferences[Prefs.annotateInvertArrows] != event.modifierFlags.contains(.option)
        let style = editor.newStyle(lineWidthPoints: ToolSizes.lineWidth(editor.settings.sizeLevel))
        let kind: ObjectKind
        if isArrow {
            let (tail, head) = inverted ? (end, start) : (start, end)
            let arrowStyle = editor.settings.arrowStyle
            kind = .arrow(ArrowShape(start: tail, end: head,
                                     control: arrowStyle == .curved ? ArrowGeometry.initialControl(start: tail, end: head) : nil,
                                     style: arrowStyle))
        } else {
            kind = .line(start: start, end: end)
        }
        return AnnotationObject(kind: kind, style: style)
    }
}

/// The pen: a freehand stroke, smoothed when "Smooth drawing" is on. A click leaves a dot.
final class PenTool: ToolController {
    private unowned let editor: AnnotationEditor
    private unowned let canvas: AnnotationCanvasView
    private var points: [CGPoint] = []
    private(set) var preview: AnnotationObject?

    init(editor: AnnotationEditor, canvas: AnnotationCanvasView) {
        self.editor = editor
        self.canvas = canvas
    }

    func mouseDown(at point: CGPoint, event: NSEvent) {
        points = [point]
        update()
    }

    func mouseDragged(to point: CGPoint, event: NSEvent) {
        points.append(point)
        update()
    }

    func mouseUp(at point: CGPoint, event: NSEvent) {
        defer {
            points = []
            preview = nil
            editor.previewRevision += 1
        }
        guard var object = preview, case .stroke(var stroke) = object.kind else { return }
        // The release can land past the last drag event.
        if points.last != point { points.append(point) }
        stroke.points = StrokeSmoothing.simplified(points, minimumDistance: canvas.basePixelsPerScreenPoint)
        object.kind = .stroke(stroke)
        editor.add(object, actionName: "Draw")
    }

    private func update() {
        let smoothed = editor.preferences[Prefs.annotateSmoothDrawing]
        preview = AnnotationObject(kind: .stroke(StrokeObject(points: points, smoothed: smoothed)),
                                   style: editor.newStyle(lineWidthPoints: ToolSizes.lineWidth(editor.settings.sizeLevel)))
        editor.previewRevision += 1
    }
}

/// The highlighter. With Smart Highlighter on, a stroke over text snaps to the words it crosses; holding ⌘ keeps it
/// freehand.
final class HighlighterTool: ToolController {
    private unowned let editor: AnnotationEditor
    private unowned let canvas: AnnotationCanvasView
    private var points: [CGPoint] = []
    private(set) var preview: AnnotationObject?

    init(editor: AnnotationEditor, canvas: AnnotationCanvasView) {
        self.editor = editor
        self.canvas = canvas
        editor.loadWordBoxesIfNeeded()
    }

    private var width: Double {
        editor.document.pixels(fromPoints: ToolSizes.highlighterWidth(editor.settings.sizeLevel))
    }

    func mouseDown(at point: CGPoint, event: NSEvent) {
        points = [point]
        update()
    }

    func mouseDragged(to point: CGPoint, event: NSEvent) {
        points.append(point)
        update()
    }

    func mouseUp(at point: CGPoint, event: NSEvent) {
        defer {
            points = []
            preview = nil
            editor.previewRevision += 1
        }
        guard var object = preview, case .highlight(var highlight) = object.kind else { return }
        // The release can land past the last drag event.
        if points.last != point { points.append(point) }
        let simplified = StrokeSmoothing.simplified(points, minimumDistance: canvas.basePixelsPerScreenPoint)
        let snapping = editor.settings.smartHighlighter && !event.modifierFlags.contains(.command)
        let rects = snapping ? HighlightSnapping.rects(along: simplified, width: width, words: editor.wordBoxes ?? []) : []
        highlight.points = rects.isEmpty ? simplified : []
        highlight.rects = rects
        object.kind = .highlight(highlight)
        editor.add(object, actionName: "Highlight")
    }

    private func update() {
        let style = editor.newStyle(lineWidthPoints: 1)
        preview = AnnotationObject(kind: .highlight(HighlightObject(points: points, rects: [], width: width,
                                                                    opacity: editor.settings.highlightOpacity)),
                                   style: ObjectStyle(color: style.color, lineWidth: style.lineWidth, shadow: false))
        editor.previewRevision += 1
    }
}

/// Counters: each click places the next number.
final class CounterTool: ToolController {
    private unowned let editor: AnnotationEditor

    init(editor: AnnotationEditor) {
        self.editor = editor
    }

    func mouseDown(at point: CGPoint, event: NSEvent) {}
    func mouseDragged(to point: CGPoint, event: NSEvent) {}

    func mouseUp(at point: CGPoint, event: NSEvent) {
        let settings = editor.settings
        let counter = CounterObject(center: point, value: editor.document.nextCounterValue(start: settings.counterStart),
                                    style: settings.counterStyle,
                                    diameter: editor.document.pixels(fromPoints: ToolSizes.counterDiameter(settings.sizeLevel)))
        editor.add(AnnotationObject(kind: .counter(counter), style: editor.newStyle(lineWidthPoints: 1)), actionName: "Add Counter")
    }
}
