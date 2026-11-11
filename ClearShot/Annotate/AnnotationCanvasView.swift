import AppKit
import CSAnnotation
import CSCore
import Observation

/// What went wrong with an image the person tried to add, for the HUD.
enum ImageProblem {
    /// The file or data was an image type, but didn't decode (an SVG, a damaged file).
    case unreadable
    /// The picture was read but couldn't be placed.
    case notAdded
}

/// The Annotate canvas. It draws the document through the one renderer, with the current tool's preview and the
/// selection on top, and sends mouse and keys to the tool. Its frame is what the document renders (the background's
/// frame, or the canvas without one) in points at 100%; the enclosing scroll view zooms it.
final class AnnotationCanvasView: NSView, NSMenuItemValidation {
    let editor: AnnotationEditor
    private(set) var tool: ToolController!
    private var currentTool: EditorTool?
    /// The scroll view's magnification, for handle sizes and hit tolerances.
    var magnification: () -> Double = { 1 }
    /// ⌘C with nothing selected copies the finished image; the window controller supplies it.
    var copyWholeImage: (() -> Void)?
    /// Makes the controller for a tool.
    lazy var toolFactory: (EditorTool) -> ToolController = { [unowned self] tool in ToolFactory.make(tool, canvas: self) }
    private(set) lazy var selectTool = SelectTool(editor: editor, canvas: self)
    /// The controller that got the mouse-down of the drag in progress, which gets the rest of it. It is the select tool
    /// when the press landed on a handle of the selected object while a drawing tool was active.
    private var routedTool: ToolController?
    /// The inline editor over the text being edited, if any.
    private var textEditor: InlineTextEditor?
    /// A press that only finished text editing: its drag and release do nothing, so the Text tool doesn't start new text
    /// where the person clicked away.
    private var pressEndedTextEditing = false
    private var spaceHeld = false
    private var panAnchor: (mouse: NSPoint, origin: NSPoint)?
    /// Z is held: a click zooms 2× on the point and a drag zooms to the rect. A tap that touched no mouse picks the tool
    /// Z is set to (if any), on the key-up.
    private var zHeld = false
    private var zUsed = false
    /// The rect (in view points) a Z-drag is zooming to, from where it began to where the mouse is.
    private var zoomDrag: (start: NSPoint, current: NSPoint)?
    /// Fits the canvas in the window (the canvas controller supplies it). Entering and leaving Crop & Resize change what the
    /// canvas shows, and so do adding and removing the background.
    var fitToWindow: (() -> Void)?
    /// Shows or hides the Background panel: its letter (Settings › Annotate › Tool shortcuts) was pressed. The window
    /// controller supplies it, through the canvas controller.
    var toggleBackgroundPanel: (() -> Void)?
    /// The crop viewport the canvas last showed, to notice it change.
    private var shownViewport: CGRect?
    /// Whether the document had a background when the canvas last showed it outside Crop & Resize, to notice it come or go.
    private var shownHasBackground: Bool
    /// The origin, in output pixels, of what the frame last showed outside Crop & Resize (the background's frame, or the
    /// canvas); nil in the mode.
    private var shownOrigin: CGPoint?
    /// An image is being dragged over the canvas: the drop zones show, and `dropEdge` is the one under the pointer.
    private var isDraggingImage = false
    private var dropEdge: RectEdge?
    /// Tells the person an image couldn't be read or added; set where the canvas is made, from the window controller.
    var imageProblem: ((ImageProblem) -> Void)?

    init(editor: AnnotationEditor) {
        self.editor = editor
        shownHasBackground = editor.document.background != nil
        super.init(frame: .zero)
        syncTool()
        updateFrameSize()
        observeEditor()
        registerForDraggedTypes([.fileURL] + ImageInput.dataTypes)
        selectTool.onEditText = { [unowned self] id in beginEditingText(id, isNew: false) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isEditingText: Bool { textEditor != nil }
    /// The text view over the text being edited, which holds the keyboard for as long as the edit lasts.
    var inlineTextView: NSTextView? { textEditor?.textView }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Redraws whenever the editor's document, selection, tool or preview changes.
    private func observeEditor() {
        withObservationTracking {
            _ = editor.document
            _ = editor.selection
            _ = editor.editingTextID
            _ = editor.tool
            _ = editor.previewRevision
            _ = editor.crop
            _ = editor.pixelSelection
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.editorDidChange()
                self?.observeEditor()
            }
        }
    }

    private func editorDidChange() {
        syncTool()
        updateFrameSize()
        var refit = false
        let viewport = editor.crop?.viewport
        if viewport != shownViewport {
            shownViewport = viewport
            // Entering or leaving Crop & Resize, or its view growing: show the whole new area.
            refit = true
        }
        // A background added or removed (Crop & Resize shows the content alone, and leaving it refits anyway): show the
        // whole frame, or the canvas. Its sliders don't refit: `updateFrameSize` keeps the content still as the frame grows.
        let hasBackground = editor.document.background != nil
        if viewport == nil, hasBackground != shownHasBackground {
            shownHasBackground = hasBackground
            refit = true
        }
        if refit { fitToWindow?() }
        textEditor?.refresh()
        needsDisplay = true
    }

    func syncTool() {
        guard currentTool != editor.tool else { return }
        // Switching tools finishes an inline edit. This sits after the guard: the canvas syncs on every document change,
        // and each keystroke changes the document.
        endTextEditing()
        // Switching to Crop & Resize under a text edit started no crop (a live change was open); the edit has ended now.
        editor.ensureCropSession()
        currentTool = editor.tool
        tool = toolFactory(editor.tool)
        window?.invalidateCursorRects(for: self)
    }

    /// Rebuilds the current tool's controller (after `toolFactory` changes).
    func reloadTool() {
        currentTool = nil
        syncTool()
    }

    /// Sizes the view to what it shows. Outside Crop & Resize, a frame whose origin has moved (auto-expand or a combine to
    /// the left or top, the background's padding or alignment, or the undo of one) scrolls by as much from where it was, so
    /// the picture stays where it was on screen instead of jumping by the growth; a frame smaller than the window stays
    /// centred. The scroll position is read before the frame changes, which may already move it. Entering or leaving the
    /// mode, and adding or removing the background, refit the zoom instead (`editorDidChange`).
    private func updateFrameSize() {
        let shown = displayRect
        let scale = editor.document.pixelScale
        let size = NSSize(width: shown.width / scale, height: shown.height / scale)
        let origin = editor.crop == nil ? shown.origin : nil
        let scrolledTo = enclosingScrollView?.contentView.bounds.origin
        if frame.size != size { setFrameSize(size) }
        if let origin, let last = shownOrigin, origin != last, let scrolledTo {
            enclosingScrollView?.scroll(keepingContentFrom: scrolledTo,
                                        shiftedBy: CGVector(dx: (last.x - origin.x) / scale, dy: (last.y - origin.y) / scale))
        }
        shownOrigin = origin
    }

    // MARK: Coordinates

    /// The output pixels the view shows: what the document renders (`AnnotationEditor.outputBounds`: the background's
    /// frame, or the canvas without one), or in Crop & Resize the crop viewport, which reaches past the canvas so the crop
    /// can be dragged outward. Measuring the frame may render the content once for auto-balance (`renderCache` keeps it),
    /// so a function that converts many points reads this once and passes it on.
    var displayRect: CGRect {
        editor.crop?.viewport ?? editor.outputBounds
    }

    private func outputPoint(_ viewPoint: NSPoint, shown: CGRect) -> CGPoint {
        let scale = editor.document.pixelScale
        return CGPoint(x: viewPoint.x * scale + shown.minX, y: viewPoint.y * scale + shown.minY)
    }

    private func outputPoint(_ viewPoint: NSPoint) -> CGPoint {
        outputPoint(viewPoint, shown: displayRect)
    }

    func basePoint(for event: NSEvent) -> CGPoint {
        editor.document.transform.toBase(outputPoint(convert(event.locationInWindow, from: nil)))
    }

    func viewPoint(fromBase point: CGPoint) -> NSPoint {
        viewPoint(fromBase: point, shown: displayRect)
    }

    /// A point in base pixels, in view points, with `shown` the `displayRect` read once by the caller.
    private func viewPoint(fromBase point: CGPoint, shown: CGRect) -> NSPoint {
        let document = editor.document
        let output = document.transform.toOutput(point)
        return NSPoint(x: (output.x - shown.minX) / document.pixelScale, y: (output.y - shown.minY) / document.pixelScale)
    }

    /// A rect in output pixels, in view points, with `shown` the `displayRect` read once by the caller.
    private func viewRect(fromOutput rect: CGRect, shown: CGRect) -> CGRect {
        let scale = editor.document.pixelScale
        return CGRect(x: (rect.minX - shown.minX) / scale, y: (rect.minY - shown.minY) / scale,
                      width: rect.width / scale, height: rect.height / scale)
    }

    /// The part of what the view shows that is on screen, in output pixels.
    var visibleOutputRect: CGRect {
        let visible = visibleRect
        let shown = displayRect
        let start = outputPoint(NSPoint(x: visible.minX, y: visible.minY), shown: shown)
        let end = outputPoint(NSPoint(x: visible.maxX, y: visible.maxY), shown: shown)
        return CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y)
    }

    /// Base pixels covered by one point on screen at the current zoom.
    var basePixelsPerScreenPoint: Double {
        editor.document.pixelScale / max(magnification(), 0.01) / max(editor.document.transform.scale, 0.0001)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawCheckerboard(in: context)
        var document = editor.document
        if let preview = tool.preview { document.objects.append(preview) }
        let shown = displayRect
        // While cropping, the whole viewport renders, filled as an expanded canvas would be, and without the background:
        // the crop is of the content alone. The overlay then dims what the crop leaves out.
        if editor.crop != nil {
            document.canvasRect = shown
            document.background = nil
        }
        context.saveGState()
        context.scaleBy(x: 1 / document.pixelScale, y: 1 / document.pixelScale)
        context.translateBy(x: -shown.minX, y: -shown.minY)
        // The spotlight's dimming fill covers the whole plane; keep it, and everything else, inside the picture.
        context.clip(to: shown)
        // The editor's cache: the frame `displayRect` measured is the one drawn, from the same auto-balance measurement.
        Renderer.draw(document, images: editor.images, in: context, cache: editor.renderCache,
                      hiding: editor.editingTextID.map { [$0] } ?? [], deviceScale: Double(window?.backingScaleFactor ?? 1),
                      useObjectCache: true)
        context.restoreGState()
        drawSelection(in: context, shown: shown)
        drawPixelSelection(in: context, shown: shown)
        drawZoomDrag(in: context)
        if let crop = editor.crop { drawCrop(crop, in: context, shown: shown) }
        if isDraggingImage { drawDropZones(in: context) }
    }

    /// Crop & Resize's overlay: everything outside the crop dimmed, thirds lines, a white border and eight handles.
    private func drawCrop(_ crop: CropSession, in context: CGContext, shown: CGRect) {
        let zoom = max(magnification(), 0.01)
        let rect = viewRect(fromOutput: crop.rect, shown: shown)
        context.saveGState()
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addRect(rect)
        context.addPath(outside)
        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(1 / zoom)
        for third in 1...2 {
            let x = rect.minX + rect.width * Double(third) / 3
            let y = rect.minY + rect.height * Double(third) / 3
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.strokePath()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5 / zoom)
        context.stroke(rect)
        let size = 8 / zoom
        context.setLineWidth(1 / zoom)
        for handle in CropGeometry.handles {
            let center = ObjectGeometry.point(of: handle, in: rect)
            let square = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(square)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.stroke(square)
        }
        context.restoreGState()
    }

    /// Transparent areas show a checkerboard. It is drawn under the whole canvas; opaque pixels cover it.
    private func drawCheckerboard(in context: CGContext) {
        let square: CGFloat = 8
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)
        context.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
        var y: CGFloat = 0
        var row = 0
        while y < bounds.height {
            var x: CGFloat = row.isMultiple(of: 2) ? 0 : square
            while x < bounds.width {
                context.fill(CGRect(x: x, y: y, width: square, height: square))
                x += square * 2
            }
            y += square
            row += 1
        }
    }

    private func drawSelection(in context: CGContext, shown: CGRect) {
        let zoom = max(magnification(), 0.01)
        let accent = NSColor.controlAccentColor.cgColor
        context.saveGState()
        context.setStrokeColor(accent)
        context.setLineWidth(1 / zoom)
        for object in editor.selectedObjects {
            context.addRect(viewRect(fromBase: ObjectGeometry.bounds(of: object), shown: shown))
        }
        context.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom])
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        if editor.selection.count == 1, let object = editor.selectedObjects.first {
            let size = 8 / zoom
            for handle in ObjectGeometry.handles(of: object) {
                let center = viewPoint(fromBase: ObjectGeometry.handlePoint(handle, of: object), shown: shown)
                let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
                context.setFillColor(NSColor.white.cgColor)
                context.setStrokeColor(accent)
                switch handle {
                case .start, .end, .control:
                    context.fillEllipse(in: rect)
                    context.strokeEllipse(in: rect)
                default:
                    context.fill(rect)
                    context.stroke(rect)
                }
            }
        }
        if let marquee = tool.marquee {
            let rect = viewRect(fromBase: marquee, shown: shown)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
            context.fill(rect)
            context.setStrokeColor(accent)
            context.stroke(rect)
        }
        context.restoreGState()
    }

    /// The pixel selection: a tint, a white and accent border, eight handles and its size as "W × H" beside it.
    private func drawPixelSelection(in context: CGContext, shown: CGRect) {
        guard let selection = editor.pixelSelection, editor.crop == nil else { return }
        let zoom = max(magnification(), 0.01)
        let accent = NSColor.controlAccentColor
        let rect = viewRect(fromBase: selection, shown: shown)
        context.saveGState()
        context.setFillColor(accent.withAlphaComponent(0.12).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2 / zoom)
        context.stroke(rect)
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(1 / zoom)
        context.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom])
        context.stroke(rect)
        context.setLineDash(phase: 0, lengths: [])
        if editor.tool == .select {
            let size = 8 / zoom
            for handle in CropGeometry.handles {
                let center = viewPoint(fromBase: ObjectGeometry.point(of: handle, in: selection), shown: shown)
                let square = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
                context.setFillColor(NSColor.white.cgColor)
                context.fill(square)
                context.setStrokeColor(accent.cgColor)
                context.stroke(square)
            }
        }
        context.restoreGState()
        if let text = editor.pixelSelectionSizeText {
            drawBadge(text, near: rect, zoom: zoom)
        }
    }

    /// A small label under `rect` (above it when there is no room), drawn at a constant size on screen.
    private func drawBadge(_ text: String, near rect: CGRect, zoom: Double) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11 / zoom, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let pad = 4 / zoom
        let box = CGSize(width: size.width + 2 * pad, height: size.height + pad)
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 4 / zoom)
        if origin.y + box.height > bounds.maxY { origin.y = rect.minY - box.height - 4 / zoom }
        origin.x = min(max(origin.x, bounds.minX), max(bounds.maxX - box.width, bounds.minX))
        let badge = CGRect(origin: origin, size: box)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3 / zoom, yRadius: 3 / zoom).fill()
        string.draw(at: CGPoint(x: badge.minX + pad, y: badge.minY + pad / 2))
    }

    /// The rect a Z-drag is zooming to.
    private func drawZoomDrag(in context: CGContext) {
        guard let drag = zoomDrag else { return }
        let zoom = max(magnification(), 0.01)
        let rect = CGRect(x: min(drag.start.x, drag.current.x), y: min(drag.start.y, drag.current.y),
                          width: abs(drag.current.x - drag.start.x), height: abs(drag.current.y - drag.start.y))
        context.saveGState()
        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1 / zoom)
        context.stroke(rect)
        context.restoreGState()
    }

    /// The bounds, in view points, of a rectangle in base pixels: after Rotate or Flip, of its transformed corners.
    func viewRect(fromBase rect: CGRect) -> CGRect {
        viewRect(fromBase: rect, shown: displayRect)
    }

    /// `viewRect(fromBase:)` with `shown` the `displayRect` read once by the caller.
    private func viewRect(fromBase rect: CGRect, shown: CGRect) -> CGRect {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            .map { viewPoint(fromBase: $0, shown: shown) }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    // MARK: Mouse

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: spaceHeld && !editor.isCanvasLocked ? .openHand : zHeld ? .crosshair : tool.cursor)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressEndedTextEditing = false
        if textEditor != nil {
            // A click outside the text being edited finishes it; with the text tool it doesn't start another one.
            endTextEditing()
            if editor.tool == .text {
                pressEndedTextEditing = true
                return
            }
        }
        if spaceHeld, beginPan(event) { return }
        if zHeld {
            zUsed = true
            let start = convert(event.locationInWindow, from: nil)
            zoomDrag = (start, start)
            return
        }
        let point = basePoint(for: event)
        // The just-drawn object's handles are shown under a drawing tool too, and still work. Not while cropping: objects stay
        // out of the way of the crop's handles. Not under the pen or highlighter either: freehand writing starts each stroke
        // next to the last one, which stays selected, so a press there must draw. Strokes are resized with the Select tool.
        var controller: ToolController = tool
        let isFreehand = editor.tool == .pen || editor.tool == .highlighter
        if tool !== selectTool, editor.crop == nil, !isFreehand, selectTool.handle(at: point) != nil { controller = selectTool }
        routedTool = controller
        controller.mouseDown(at: point, event: event)
        needsDisplay = true
    }

    /// Starts a pan (Space held, or the right button) unless the canvas is locked.
    private func beginPan(_ event: NSEvent) -> Bool {
        guard !editor.isCanvasLocked, let clip = enclosingScrollView?.contentView else { return false }
        panAnchor = (event.locationInWindow, clip.bounds.origin)
        NSCursor.closedHand.set()
        return true
    }

    private func continuePan(_ event: NSEvent) -> Bool {
        guard let anchor = panAnchor, let scroll = enclosingScrollView else { return false }
        let zoom = max(scroll.magnification, 0.01)
        let origin = NSPoint(x: anchor.origin.x - (event.locationInWindow.x - anchor.mouse.x) / zoom,
                             y: anchor.origin.y + (event.locationInWindow.y - anchor.mouse.y) / zoom)
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }

    private func endPan() -> Bool {
        guard panAnchor != nil else { return false }
        panAnchor = nil
        window?.invalidateCursorRects(for: self)
        return true
    }

    /// The right button pans, whatever the tool.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        endTextEditing()
        _ = beginPan(event)
    }

    override func rightMouseDragged(with event: NSEvent) { _ = continuePan(event) }
    override func rightMouseUp(with event: NSEvent) { _ = endPan() }

    override func mouseDragged(with event: NSEvent) {
        if continuePan(event) { return }
        if var drag = zoomDrag {
            drag.current = convert(event.locationInWindow, from: nil)
            zoomDrag = drag
            needsDisplay = true
            return
        }
        guard !pressEndedTextEditing else { return }
        (routedTool ?? tool).mouseDragged(to: basePoint(for: event), event: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if endPan() { return }
        if let drag = zoomDrag {
            zoomDrag = nil
            needsDisplay = true
            finishZoomDrag(drag)
            return
        }
        if pressEndedTextEditing {
            pressEndedTextEditing = false
            return
        }
        let controller: ToolController = routedTool ?? tool
        routedTool = nil
        controller.mouseUp(at: basePoint(for: event), event: event)
        needsDisplay = true
    }

    // MARK: Zoom

    /// A Z-click zooms 2× on the point; a Z-drag zooms to the rect it drew.
    private func finishZoomDrag(_ drag: (start: NSPoint, current: NSPoint)) {
        guard let scroll = enclosingScrollView else { return }
        let limits = Double(scroll.minMagnification)...Double(scroll.maxMagnification)
        let target: ZoomTarget? = if ZoomGeometry.isClick(from: drag.start, to: drag.current) {
            ZoomGeometry.zooming(at: drag.start, from: Double(scroll.magnification), limits: limits)
        } else {
            ZoomGeometry.fitting(CGRect(x: drag.start.x, y: drag.start.y, width: drag.current.x - drag.start.x,
                                        height: drag.current.y - drag.start.y),
                                 in: scroll.contentSize, limits: limits)
        }
        if let target { zoom(to: target) }
    }

    private func zoom(to target: ZoomTarget) {
        enclosingScrollView?.setMagnification(CGFloat(target.magnification), centeredAt: target.center)
    }

    /// View › Zoom to Selection (⌘2): the pixel selection fills the window.
    func zoomToPixelSelection() {
        guard let selection = editor.pixelSelection, let scroll = enclosingScrollView else { return }
        let limits = Double(scroll.minMagnification)...Double(scroll.maxMagnification)
        if let target = ZoomGeometry.fitting(viewRect(fromBase: selection), in: scroll.contentSize, limits: limits) { zoom(to: target) }
    }

    // MARK: Text editing

    /// Starts editing a text object inline. A new object (from the text tool) is already inside a live change.
    func beginEditingText(_ id: UUID, isNew: Bool) {
        endTextEditing()
        if !isNew { editor.beginLiveChange() }
        editor.selection = []
        editor.editingTextID = id
        // The property bar shows the text's own color, size and style (the selection that would have adopted them is empty).
        if let object = editor.object(id) { editor.adoptStyle(of: object) }
        textEditor = InlineTextEditor(objectID: id, isNew: isNew, canvas: self)
    }

    /// Finishes inline editing: an edit becomes one undo step, and text left empty disappears (a new one without a trace).
    func endTextEditing() {
        guard let inline = textEditor else { return }
        textEditor = nil
        inline.end()
        inline.textView.removeFromSuperview()
        editor.editingTextID = nil
        let id = inline.objectID
        let isEmpty: Bool = if case .text(let text) = editor.object(id)?.kind {
            text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            true
        }
        if isEmpty, inline.isNew {
            editor.cancelLiveChange()
        } else if isEmpty {
            editor.updateLive { $0.objects.removeAll { $0.id == id } }
            editor.endLiveChange("Delete Text")
        } else {
            editor.endLiveChange(inline.isNew ? "Add Text" : "Edit Text")
            // Only under the tools that keep a selection: switching to a drawing tool has just cleared it, and the next
            // color or size would restyle this text.
            if editor.tool == .text || editor.tool == .select { editor.selection = [id] }
        }
        window?.makeFirstResponder(self)
    }

    /// Finishes whatever is in progress before an output, a close or a quit: the inline text edit, and a pending crop,
    /// which is applied as leaving the mode would.
    func finishEditing() {
        endTextEditing()
        editor.applyCrop()
    }

    // MARK: Adding images

    /// Where `addImages` puts a batch of pictures.
    enum ImageDestination {
        /// In the middle of what's visible (⌘V, Add Image).
        case visibleMiddle
        /// Centred on a point, in output pixels (a drop).
        case point(CGPoint)
        /// Beside the canvas on an edge (a drop on a zone), or at the point when that side has no room left.
        case beside(RectEdge, otherwise: CGPoint)
    }

    /// Each further picture of a batch sits this many canvas points down and to the right of the one before.
    private static let stackStep = 20.0

    /// Adds a picture as an image object. When it can't be added the person is told, unless that is their own state: Crop &
    /// Resize owns the canvas, and a change in progress (text being typed) can't be interrupted.
    @discardableResult
    func addImage(_ picked: ImageInput.Picked, _ insertion: ImageInsertion) -> Bool {
        if editor.insertImage(picked.image, scale: picked.scale, insertion) { return true }
        if editor.crop == nil, !editor.isInLiveChange { imageProblem?(.notAdded) }
        return false
    }

    /// Adds each picture as an image object, in order. A batch is stacked: each picture placed at a point (the drop point, or
    /// the middle of what's visible) sits `stackStep` points down and to the right of the one placed there before it; ones
    /// combined beside the canvas don't count. Pictures that couldn't be read are reported at once, and ones that couldn't be
    /// placed as they fail. After one is combined beside the canvas the canvas is fitted to the window, so the new picture
    /// shows even when the zone was a scrolled edge.
    ///
    /// The whole batch is one undo step, apart from what the caller has just done (the text edit a drop ended): see
    /// `AnnotationEditor.asOneUndoStep`. When that edit's group is still open the inserts follow once it has closed, a
    /// moment later; if a crop or a change in progress is there by then, nothing is inserted (and nothing said: it is the
    /// person's own state). Returns whether there is anything to insert.
    @discardableResult
    func addImages(_ pictures: ImageInput.Pictures, to destination: ImageDestination) -> Bool {
        if pictures.unreadable > 0 { imageProblem?(.unreadable) }
        let images = pictures.images
        guard !images.isEmpty else { return false }
        let visible = visibleOutputRect
        editor.asOneUndoStep { [weak self] in
            guard let self, editor.crop == nil, !editor.isInLiveChange else { return }
            var stacked = 0
            var combined = false
            for picked in images {
                let result = addBatchImage(picked, stacked: stacked, to: destination, visible: visible)
                if result.combined { combined = true } else if result.added { stacked += 1 }
            }
            if combined {
                // The frame follows the document a moment later; the fit needs it now.
                updateFrameSize()
                fitToWindow?()
            }
        }
        return true
    }

    /// One picture of a batch, with `stacked` pictures already placed at a point before it. Whether it was added, and
    /// whether it went beside the canvas, which grew.
    private func addBatchImage(_ picked: ImageInput.Picked, stacked: Int, to destination: ImageDestination,
                               visible: CGRect) -> (added: Bool, combined: Bool) {
        let shift = Double(stacked) * Self.stackStep * editor.document.pixelScale
        func shifted(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + shift, y: point.y + shift) }
        switch destination {
        case .visibleMiddle:
            return (addImage(picked, .centered(visible: visible.offsetBy(dx: shift, dy: shift))), false)
        case .point(let point):
            return (addImage(picked, .at(shifted(point))), false)
        case .beside(let edge, let point):
            if editor.insertImage(picked.image, scale: picked.scale, .beside(edge)) { return (true, true) }
            return (addImage(picked, .at(shifted(point))), false)
        }
    }

    /// The visible part of the canvas, where the drop zones go, in view points.
    private var dropArea: CGRect {
        visibleRect.intersection(bounds)
    }

    /// How deep the drop zones are: 64 points on screen, but no more than a quarter of the visible canvas.
    private var dropZoneThickness: Double {
        let area = dropArea
        return min(64 / max(magnification(), 0.01), min(area.width, area.height) * 0.25)
    }

    /// The drop zone under the pointer, if any.
    private func zone(under sender: any NSDraggingInfo) -> RectEdge? {
        CombineLayout.edge(at: convert(sender.draggingLocation, from: nil), in: dropArea, thickness: dropZoneThickness)
    }

    /// Images from Finder or another app, but not while cropping (images stay out of Crop & Resize), not under the Resize
    /// sheet, and not the editor's own picture dragged from its bottom bar.
    private func acceptsDrop(_ sender: any NSDraggingInfo) -> Bool {
        guard editor.crop == nil, window?.attachedSheet == nil, (sender.draggingSource as? NSView)?.window !== window else { return false }
        return ImageInput.hasImage(sender.draggingPasteboard)
    }

    private func endDrop() {
        guard isDraggingImage else { return }
        isDraggingImage = false
        dropEdge = nil
        needsDisplay = true
    }

    /// Decides once whether the drag carries an image this canvas takes; the rest of the drag only follows the pointer.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop(sender) else { return [] }
        isDraggingImage = true
        dropEdge = zone(under: sender)
        needsDisplay = true
        return .copy
    }

    /// Redraws only when the pointer moves to another zone, or out of all of them.
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isDraggingImage else { return [] }
        let edge = zone(under: sender)
        if edge != dropEdge {
            dropEdge = edge
            needsDisplay = true
        }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        endDrop()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        endDrop()
    }

    /// A drop on a zone combines the images beside the canvas on that side; anywhere else, or when that side has no room
    /// left, they go at the drop point. Pictures that can't be read or placed are reported.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { endDrop() }
        guard isDraggingImage else { return false }
        let pictures = ImageInput.pictures(from: sender.draggingPasteboard)
        // Text being typed holds a change open, and no image can be added under one.
        if !pictures.images.isEmpty { endTextEditing() }
        let point = convert(sender.draggingLocation, from: nil)
        let dropPoint = outputPoint(point)
        let destination: ImageDestination = CombineLayout.edge(at: point, in: dropArea, thickness: dropZoneThickness)
            .map { .beside($0, otherwise: dropPoint) } ?? .point(dropPoint)
        return addImages(pictures, to: destination)
    }

    /// The four drop zones, the one under the pointer stronger.
    private func drawDropZones(in context: CGContext) {
        let zoom = max(magnification(), 0.01)
        context.saveGState()
        for zone in CombineLayout.dropZones(in: dropArea, thickness: dropZoneThickness) {
            let rect = zone.rect.insetBy(dx: 4 / zoom, dy: 4 / zoom)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
            let radius = min(6 / zoom, rect.width / 2, rect.height / 2)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let hovered = zone.edge == dropEdge
            context.addPath(path)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(hovered ? 0.35 : 0.12).cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth((hovered ? 2 : 1) / zoom)
            context.strokePath()
        }
        context.restoreGState()
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 6, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            // Z held zooms with the mouse; a tap (no click, no drag) is the letter's own tool, on the key-up.
            if !event.isARepeat {
                zHeld = true
                zUsed = false
                window?.invalidateCursorRects(for: self)
            }
            return
        }
        if event.keyCode == 49 {
            // Space pans while held.
            if !event.isARepeat {
                spaceHeld = true
                window?.invalidateCursorRects(for: self)
            }
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if editor.crop != nil, flags.isEmpty {
            // Return (or Enter) applies the crop, Esc cancels it.
            switch event.keyCode {
            case 36, 76:
                editor.applyCrop()
                return
            case 53:
                editor.cancelCrop()
                return
            default:
                break
            }
        }
        // ⌘-arrows resize the pixel selection's right and bottom edges (⇧⌘ by 10).
        if editor.pixelSelection != nil, editor.crop == nil, flags.contains(.command), flags.isSubset(of: [.command, .shift]),
           let arrow = Self.arrowVector(for: event.keyCode, step: flags.contains(.shift) ? 10 : 1) {
            editor.resizePixelSelection(by: arrow)
            return
        }
        guard flags.isEmpty || flags == .shift else { return super.keyDown(with: event) }
        let step: Double = flags == .shift ? 10 : 1
        // `[` grows the pixel selection by a pixel on every side and `]` shrinks it (⇧ for 10). Under the Select tool only:
        // the other tools use the same keys for size.
        if editor.pixelSelection != nil, editor.crop == nil, editor.tool == .select,
           let character = event.charactersIgnoringModifiers?.first, "[{]}".contains(character) {
            editor.growPixelSelection(by: "[{".contains(character) ? step : -step)
            return
        }
        switch event.keyCode {
        case 51, 117: editor.deleteSelection()
        case 53:
            editor.selection = []
            editor.clearPixelSelection()
        case 123, 124, 125, 126:
            // An object selected moves with the arrows; with none, the pixel selection does (1 pixel, ⇧ 10).
            let arrow = Self.arrowVector(for: event.keyCode, step: step)!
            if editor.selection.isEmpty, editor.crop == nil { editor.nudgePixelSelection(by: arrow) } else { editor.nudgeSelection(by: arrow) }
        default:
            guard flags.isEmpty, let character = event.charactersIgnoringModifiers?.lowercased().first,
                  handleKey(character) else { return super.keyDown(with: event) }
        }
    }

    /// The arrow key's direction as a vector of `step`, or nil for another key.
    private static func arrowVector(for keyCode: UInt16, step: Double) -> CGVector? {
        switch keyCode {
        case 123: CGVector(dx: -step, dy: 0)
        case 124: CGVector(dx: step, dy: 0)
        case 125: CGVector(dx: 0, dy: step)
        case 126: CGVector(dx: 0, dy: -step)
        default: nil
        }
    }

    /// Tool letters and the Background panel's letter, sizes 1–6, and `[` `]` for size, or redaction intensity when
    /// redacting. The size keys coalesce, so holding one down (key repeat) restyles in one undo step.
    func handleKey(_ character: Character) -> Bool {
        switch editor.preferences[Prefs.annotateToolKeys].target(for: character) {
        case .backgroundPanel:
            toggleBackgroundPanel?()
            return true
        case .tool(let tool):
            editor.tool = tool
            return true
        case nil:
            break
        }
        // A selected image has no size, so its digits set its opacity (1–9 = 10%–90%, 0 = 100%).
        if editor.handleImageOpacityKey(character) { return true }
        if let level = character.wholeNumberValue, ToolSizes.levels.contains(level) {
            editor.setSizeLevel(level, coalescing: true)
            return true
        }
        guard character == "[" || character == "]" else { return false }
        let step = character == "]" ? 1 : -1
        if editor.styleContext == .redact {
            editor.adjustIntensity(by: step, coalescing: true)
        } else {
            editor.adjustSize(by: step, coalescing: true)
        }
        return true
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 6 {
            let tapped = zHeld && !zUsed
            endZHold()
            // A tap of Z is the tool letter it has been given (Z has none unless Settings gave it one).
            if tapped { _ = handleKey("z") }
            return
        }
        guard event.keyCode == 49 else { return super.keyUp(with: event) }
        endSpaceHold()
    }

    /// Z is no longer held (also when the canvas loses the keyboard mid-hold).
    private func endZHold() {
        guard zHeld else { return }
        zHeld = false
        zoomDrag = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Space is no longer held. Also called when the canvas or its window loses the keyboard, where the key-up would
    /// go elsewhere and leave the next click panning.
    func endSpaceHold() {
        guard spaceHeld else { return }
        spaceHeld = false
        window?.invalidateCursorRects(for: self)
    }

    override func resignFirstResponder() -> Bool {
        endSpaceHold()
        endZHold()
        return super.resignFirstResponder()
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) {
        let objects = editor.selectedObjects
        guard !objects.isEmpty else { copyWholeImage?(); return }
        ObjectClipboard.write(objects, document: editor.document, images: editor.images)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        editor.deleteSelection()
    }

    /// ClearShot objects when the pasteboard has them; otherwise an image, as an image object. Neither can be added
    /// while Crop & Resize is on (`editor.crop != nil`): the crop owns the canvas.
    @objc func paste(_ sender: Any?) {
        guard editor.crop == nil else { return }
        if let contents = ObjectClipboard.read() {
            editor.paste(contents.objects, sourceScale: contents.sourceScale, images: contents.images)
        } else {
            addImages(ImageInput.pictures(from: .general), to: .visibleMiddle)
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        guard editor.crop == nil else { return }
        editor.selection = Set(editor.document.objects.map(\.id))
    }

    @objc func delete(_ sender: Any?) {
        editor.deleteSelection()
    }

    /// Edit › Duplicate (⌘D).
    @objc func duplicate(_ sender: Any?) {
        guard editor.crop == nil else { return }
        editor.duplicateSelection()
    }

    /// Edit › Reroll Hand-drawn Style (⇧⌘R): draws the selected hand-drawn shapes again, differently.
    @objc func rerollHandDrawn(_ sender: Any?) {
        guard editor.crop == nil else { return }
        editor.rerollHandDrawn()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(rerollHandDrawn(_:)): editor.crop == nil && editor.canRerollHandDrawn
        case #selector(copy(_:)): true
        case #selector(cut(_:)), #selector(delete(_:)): !editor.selection.isEmpty
        case #selector(duplicate(_:)): editor.crop == nil && !editor.selection.isEmpty
        case #selector(paste(_:)): editor.crop == nil && (ObjectClipboard.hasObjects || ImageInput.hasImage(.general))
        case #selector(selectAll(_:)): editor.crop == nil
        default: true
        }
    }
}
