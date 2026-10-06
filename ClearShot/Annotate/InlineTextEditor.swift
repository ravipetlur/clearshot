import AppKit
import CSAnnotation

/// Edits a text object in place. An NSTextView sits over the object, laid out like the renderer will draw it, while the
/// canvas leaves the object itself out of the render. Typing updates the document live; the whole edit is one undo
/// step.
final class InlineTextEditor: NSObject, NSTextViewDelegate {
    let objectID: UUID
    let isNew: Bool
    let textView = NSTextView(frame: .zero)
    private unowned let canvas: AnnotationCanvasView
    /// Typing's own undo stack. The window's undo manager is the editor's, which gets one step for the whole edit when it
    /// ends; ⌘Z while typing undoes typing here, and no "Undo Typing" step is left behind for a text view that is gone.
    private let undoManager = UndoManager()

    init(objectID: UUID, isNew: Bool, canvas: AnnotationCanvasView) {
        self.objectID = objectID
        self.isNew = isNew
        self.canvas = canvas
        super.init()
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        // NSTextView sends no `textDidChange` when typing is undone or redone.
        NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedoChangedText), name: .NSUndoManagerDidUndoChange,
                                               object: undoManager)
        NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedoChangedText), name: .NSUndoManagerDidRedoChange,
                                               object: undoManager)
        textView.isVerticallyResizable = true
        textView.textContainer?.lineFragmentPadding = 0
        // The container is sized in `refresh()`, not by the frame.
        textView.textContainer?.widthTracksTextView = false
        if let text = currentText { textView.string = text.string }
        canvas.addSubview(textView)
        refresh()
        canvas.window?.makeFirstResponder(textView)
        if !isNew { textView.selectAll(nil) }
    }

    private var currentObject: AnnotationObject? {
        canvas.editor.object(objectID)
    }

    private var currentText: TextObject? {
        if case .text(let text) = currentObject?.kind { text } else { nil }
    }

    /// Matches the text view to the object: frame, font, colors and the box's padding.
    ///
    /// The text is laid out in base pixels, exactly as `TextLayout` and the renderer measure it, and the view's bounds scale
    /// that to the canvas. Laying it out at the scaled size instead would differ from the renderer (SF's tracking and
    /// optical sizes aren't proportional), and long text would wrap while typing.
    func refresh() {
        guard let object = currentObject, let text = currentText else { return }
        let document = canvas.editor.document
        let viewPerBasePixel = document.transform.scale / document.pixelScale
        let frame = TextLayout.frame(of: text)
        // Inline editing stays upright even when the picture is rotated: the box keeps its own size and sits at the
        // top-left of where the rotated or flipped object's box is.
        let origin = canvas.viewRect(fromBase: frame).origin
        textView.frame = NSRect(origin: origin, size: NSSize(width: frame.width * viewPerBasePixel, height: frame.height * viewPerBasePixel))
        textView.setBoundsSize(frame.size)
        let padding = TextLayout.padding(for: text.style, fontSize: text.fontSize)
        textView.textContainerInset = NSSize(width: padding.width, height: padding.height)
        textView.font = TextLayout.font(for: text.style, size: text.fontSize)
        let fill = text.style.hasBox ? object.style.color.contrastingTextColor : object.style.color
        textView.textColor = NSColor(cgColor: fill.cgColor)
        textView.insertionPointColor = NSColor(cgColor: fill.cgColor) ?? .textColor
        textView.drawsBackground = text.style.hasBox
        textView.backgroundColor = NSColor(cgColor: object.style.color.cgColor) ?? .clear
        textView.isHorizontallyResizable = text.width == nil
        // The renderer wraps a fixed-width text at its width less the padding on both sides.
        let containerWidth = text.width.map { max($0 - 2 * padding.width, 1) } ?? CGFloat.greatestFiniteMagnitude
        textView.textContainer?.containerSize = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
    }

    /// The edit is over: stops listening and lets go of the text view, rather than leaving that to deallocation.
    func end() {
        NotificationCenter.default.removeObserver(self)
        textView.delegate = nil
    }

    func textDidChange(_ notification: Notification) {
        let string = textView.string
        let id = objectID
        canvas.editor.updateLive { document in
            guard let index = document.objects.firstIndex(where: { $0.id == id }),
                  case .text(var text) = document.objects[index].kind else { return }
            text.string = string
            document.objects[index].kind = .text(text)
        }
        refresh()
    }

    @objc private func undoOrRedoChangedText(_ notification: Notification) {
        textDidChange(notification)
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager
    }

    /// Esc finishes editing. ⌘↩ is Done's shortcut, which finishes the text first (AppKit sends the text view `noop:` for
    /// it, so it can't be handled here).
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        canvas.endTextEditing()
        return true
    }
}
