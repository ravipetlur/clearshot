import CoreGraphics
import CSCore
import Foundation

/// Tool settings: each setter updates the remembered setting and restyles the selected objects it fits.
extension AnnotationEditor {
    /// The style for a new object: current color, `lineWidthPoints` in base pixels, and the shadow setting.
    public func newStyle(lineWidthPoints: Double) -> ObjectStyle {
        ObjectStyle(color: settings.color, lineWidth: document.pixels(fromPoints: lineWidthPoints),
                    shadow: preferences[Prefs.annotateObjectShadows])
    }

    /// `newStyle` with the remembered fill, for a rectangle or an ellipse.
    public func newShapeStyle(lineWidthPoints: Double) -> ObjectStyle {
        var style = newStyle(lineWidthPoints: lineWidthPoints)
        style.fillColor = settings.fillColor
        style.fillOpacity = settings.fillOpacity
        return style
    }

    /// Which tool's controls the property bar shows: the current tool, or with Select, the one selected object's kind.
    /// While text is being typed that is the text controls, even when a double-click under Select started the edit.
    public var styleContext: EditorTool {
        if editingTextID != nil { return .text }
        guard tool == .select, selection.count == 1, let object = selectedObjects.first else { return tool }
        return switch object.kind {
        case .rectangle: .rectangle
        case .filledRectangle: .filledRectangle
        case .ellipse: .ellipse
        case .line: .line
        case .arrow: .arrow
        case .text: .text
        case .redact: .redact
        case .spotlight: .spotlight
        case .counter: .counter
        case .stroke: .pen
        case .highlight: .highlighter
        case .image: .select
        }
    }

    /// `coalescing` for a stream of changes (the system color panel while dragging), so the whole drag is one undo step.
    public func setColor(_ color: RGBAColor, coalescing: Bool = false) {
        settings.color = color
        restyleSelection("Change Color", coalescing: coalescing) { object, _ in
            switch object.kind {
            case .redact, .spotlight, .image: break
            default: object.style.color = color
            }
        }
    }

    /// The fill color of rectangles and ellipses; nil follows the stroke's color. Picking one while there is no fill
    /// gives it a half-opaque fill, so the pick shows.
    public func setFillColor(_ color: RGBAColor?, coalescing: Bool = false) {
        settings.fillColor = color
        if settings.fillOpacity == 0, color != nil { settings.fillOpacity = 0.5 }
        let opacity = settings.fillOpacity
        restyleSelection("Change Fill", coalescing: coalescing) { object, _ in
            guard Self.takesFill(object.kind) else { return }
            object.style.fillColor = color
            if object.style.fillOpacity == 0, color != nil { object.style.fillOpacity = opacity }
        }
    }

    /// The fill opacity, 0 (no fill) to 1. A slider drag is one undo step (`sliderEditingChanged`).
    public func setFillOpacity(_ opacity: Double, coalescing: Bool = false) {
        let opacity = min(max(opacity, 0), 1)
        settings.fillOpacity = opacity
        restyleSelection("Change Fill", coalescing: coalescing) { object, _ in
            guard Self.takesFill(object.kind) else { return }
            object.style.fillOpacity = opacity
        }
    }

    /// Whether the kind takes a fill: the outlined rectangle and ellipse (a filled rectangle is already filled).
    private static func takesFill(_ kind: ObjectKind) -> Bool {
        switch kind {
        case .rectangle, .ellipse: true
        default: false
        }
    }

    /// `coalescing` for the size keys, so holding one down (key repeat) is one undo step.
    public func setSizeLevel(_ level: Int, coalescing: Bool = false) {
        let level = ToolSizes.clamped(level)
        settings.sizeLevel = level
        restyleSelection("Change Size", coalescing: coalescing) { object, document in
            switch object.kind {
            case .text(var text):
                text.fontSize = document.pixels(fromPoints: ToolSizes.fontSize(level))
                object.kind = .text(text)
            case .counter(var counter):
                counter.diameter = document.pixels(fromPoints: ToolSizes.counterDiameter(level))
                object.kind = .counter(counter)
            case .highlight(var highlight) where highlight.rects.isEmpty:
                highlight.width = document.pixels(fromPoints: ToolSizes.highlighterWidth(level))
                object.kind = .highlight(highlight)
            case .redact, .spotlight, .image, .highlight:
                break
            default:
                object.style.lineWidth = document.pixels(fromPoints: ToolSizes.lineWidth(level))
            }
        }
    }

    /// `[` and `]`.
    public func adjustSize(by step: Int, coalescing: Bool = false) {
        setSizeLevel(settings.sizeLevel + step, coalescing: coalescing)
    }

    public func setArrowStyle(_ style: ArrowStyle) {
        settings.arrowStyle = style
        restyleSelection("Change Arrow Style") { object, _ in
            guard case .arrow(var arrow) = object.kind else { return }
            arrow.style = style
            if style == .curved, arrow.control == nil {
                arrow.control = ArrowGeometry.initialControl(start: arrow.start, end: arrow.end)
            }
            object.kind = .arrow(arrow)
        }
    }

    public func setTextStyle(_ style: TextStyle) {
        settings.textStyle = style
        restyleSelection("Change Text Style") { object, _ in
            guard case .text(var text) = object.kind else { return }
            text.style = style
            object.kind = .text(text)
        }
    }

    public func setRedactStyle(_ style: RedactStyle) {
        settings.redactStyle = style
        restyleSelection("Change Redaction") { object, _ in
            guard case .redact(var redact) = object.kind else { return }
            redact.style = style
            object.kind = .redact(redact)
        }
    }

    public func setRedactIntensity(_ intensity: Int, coalescing: Bool = false) {
        let intensity = min(max(intensity, 1), 10)
        settings.redactIntensity = intensity
        restyleSelection("Change Intensity", coalescing: coalescing) { object, _ in
            guard case .redact(var redact) = object.kind else { return }
            redact.intensity = intensity
            object.kind = .redact(redact)
        }
    }

    /// `[` and `]` with the redact tool or a redaction selected.
    public func adjustIntensity(by step: Int, coalescing: Bool = false) {
        setRedactIntensity(settings.redactIntensity + step, coalescing: coalescing)
    }

    public func setSpotlightShape(_ shape: SpotlightShape) {
        settings.spotlightShape = shape
        restyleSelection("Change Spotlight") { object, _ in
            guard case .spotlight(var spotlight) = object.kind else { return }
            spotlight.shape = shape
            object.kind = .spotlight(spotlight)
        }
    }

    public func setSpotlightOpacity(_ opacity: Double) {
        settings.spotlightOpacity = opacity
        restyleSelection("Change Spotlight") { object, _ in
            guard case .spotlight(var spotlight) = object.kind else { return }
            spotlight.opacity = opacity
            object.kind = .spotlight(spotlight)
        }
    }

    public func setCounterStyle(_ style: CounterStyle) {
        settings.counterStyle = style
        restyleSelection("Change Counter Style") { object, _ in
            guard case .counter(var counter) = object.kind else { return }
            counter.style = style
            object.kind = .counter(counter)
        }
    }

    /// The first counter's number (0 allowed); later counters continue from the highest.
    public func setCounterStart(_ start: Int) {
        settings.counterStart = max(0, start)
    }

    public func setHighlightOpacity(_ opacity: Double) {
        settings.highlightOpacity = opacity
        restyleSelection("Change Highlight") { object, _ in
            guard case .highlight(var highlight) = object.kind else { return }
            highlight.opacity = opacity
            object.kind = .highlight(highlight)
        }
    }

    public func setSmartHighlighter(_ on: Bool) {
        settings.smartHighlighter = on
    }

    /// "Draw shadow on objects": the setting for new objects, and the selected ones.
    public func setShadows(_ on: Bool) {
        preferences[Prefs.annotateObjectShadows] = on
        restyleSelection(on ? "Add Shadow" : "Remove Shadow") { object, _ in
            switch object.kind {
            case .redact, .spotlight, .highlight: break
            default: object.style.shadow = on
            }
        }
    }

    /// Smooth drawing, a setting shared with Settings › Annotate.
    public func setSmoothDrawing(_ on: Bool) {
        preferences[Prefs.annotateSmoothDrawing] = on
        restyleSelection("Change Smoothing") { object, _ in
            guard case .stroke(var stroke) = object.kind else { return }
            stroke.smoothed = on
            object.kind = .stroke(stroke)
        }
    }

    /// Selecting one object shows its look in the property bar, without changing anything.
    public func adoptStyle(of object: AnnotationObject) {
        var adopted = settings
        switch object.kind {
        case .redact, .spotlight, .image: break
        default: adopted.color = object.style.color
        }
        func nearestLevel(_ pixels: Double, _ sizes: (Int) -> Double) -> Int {
            ToolSizes.levels.min { abs(document.pixels(fromPoints: sizes($0)) - pixels) < abs(document.pixels(fromPoints: sizes($1)) - pixels) } ?? 3
        }
        switch object.kind {
        case .text(let text):
            adopted.sizeLevel = nearestLevel(text.fontSize, ToolSizes.fontSize)
            adopted.textStyle = text.style
        case .counter(let counter):
            adopted.sizeLevel = nearestLevel(counter.diameter, ToolSizes.counterDiameter)
            adopted.counterStyle = counter.style
        case .arrow(let arrow):
            adopted.sizeLevel = nearestLevel(object.style.lineWidth, ToolSizes.lineWidth)
            adopted.arrowStyle = arrow.style
        case .redact(let redact):
            adopted.redactStyle = redact.style
            adopted.redactIntensity = redact.intensity
        case .spotlight(let spotlight):
            adopted.spotlightShape = spotlight.shape
            adopted.spotlightOpacity = spotlight.opacity
        case .highlight(let highlight):
            adopted.highlightOpacity = highlight.opacity
        case .image:
            break
        case .rectangle, .ellipse:
            adopted.sizeLevel = nearestLevel(object.style.lineWidth, ToolSizes.lineWidth)
            adopted.fillColor = object.style.fillColor
            adopted.fillOpacity = object.style.fillOpacity
        default:
            adopted.sizeLevel = nearestLevel(object.style.lineWidth, ToolSizes.lineWidth)
        }
        if adopted != settings { settings = adopted }
    }

    /// Restyles what the person is working on:
    /// - the text being typed, if any: just an edit to the document, since the edit's own live change records it;
    /// - otherwise the selection, as one undo step per call (or per run of calls, when `coalescing`), or, during a live
    ///   change (a slider drag), just an edit to the document: the live change records the whole drag as one step when it
    ///   ends.
    private func restyleSelection(_ actionName: String, coalescing: Bool = false,
                                  _ body: (inout AnnotationObject, AnnotationDocument) -> Void) {
        let current = document
        if let editing = editingTextID {
            updateLive { document in
                if let index = document.objects.firstIndex(where: { $0.id == editing }) { body(&document.objects[index], current) }
            }
            return
        }
        guard !selection.isEmpty else { return }
        let ids = selection
        func edit(_ document: inout AnnotationDocument) {
            for index in document.objects.indices where ids.contains(document.objects[index].id) {
                body(&document.objects[index], current)
            }
        }
        if isInLiveChange {
            updateLive(edit)
        } else {
            change(actionName, coalescing: coalescing, edit)
        }
    }
}
