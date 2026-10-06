import AppKit
import CSCapture
import CSCore

/// What a pin asks its manager to do: its keys, the hover close button, a middle-click and its gestures.
enum PinCommand: Equatable {
    case close, copy, annotate, saveAs
    case zoomIn, zoomOut, actualSize
    /// One step of a pinch, and whether the gesture ends with it.
    case pinch(magnification: Double, ended: Bool)
    /// A vertical scroll toward the top of the screen: trackpad points when `precise`, else wheel lines.
    case scroll(up: Double, precise: Bool)
    case nudge(PinNudge, large: Bool)
}

protocol PinViewDelegate: AnyObject {
    func pinView(_ view: PinView, perform command: PinCommand)
    func pinViewDragFiles(_ view: PinView) -> QuickAccessDragFiles?
    func pinView(_ view: PinView, dragEndedWith operation: NSDragOperation, optionHeld: Bool)
    func pinViewMenu(_ view: PinView) -> NSMenu?
}

/// One pin's content: the picture on its card, the hover close button and "Drag me" handle, the opacity readout, and
/// the pin's mouse, gesture, menu and arrow-key input. The view is the window's size; the picture sits at
/// `PinGeometry.imageRect` in it.
final class PinView: NSView, NSDraggingSource {
    weak var delegate: PinViewDelegate?

    private static let buttonSide: CGFloat = 22
    private static let buttonInset: CGFloat = 6
    private static let pillHeight: CGFloat = 26
    private static let pillBottom: CGFloat = 8
    private static let pillPadding: CGFloat = 12
    /// The smallest window that has room for the "Drag me" capsule; a smaller one gets a corner button.
    private static let pillMinimumWindow = CGSize(width: 120, height: 72)
    /// The drag image's box: the picture is fitted into it.
    private static let dragImageSide: CGFloat = 128

    private let imageView = ThumbnailView()
    private let chrome = PassthroughView()
    private let closeButton = CircleButton(symbol: "xmark", label: "Close")
    private let dragPill = PinDragHandle(look: PillButton(label: "Drag me"))
    private let dragCorner = PinDragHandle(look: CircleButton(symbol: "hand.draw", label: "Drag me"))
    private let readout = PinReadout()

    private var imagePoints: CGSize = .zero
    private var isTransparent = false
    /// The style as drawn: `PinStyle.effective` for the item.
    private var style = PinStyle(shadow: true, roundedCorners: true, border: true)
    private var isHovering = false
    /// True from the start of a "Drag me" drag until it ends: the pointer leaving the pin then isn't a hover change.
    private var isDragging = false
    private var dragOptionHeld = false
    /// Kept for the drag's lifetime: a drop target may ask for the PNG after the drag image is gone.
    private var dragProvider: DragImageProvider?
    private var readoutFade: Task<Void, Never>?

    /// The pin's zoom; the window is `PinGeometry.windowSize` for it.
    var zoom: Double = 1 {
        didSet { needsLayout = true }
    }

    /// A locked pin shows no hover controls or readout (its window ignores the mouse). Unlocked, the controls come back
    /// at once if the pointer is over the pin: a window that ignored the mouse gets no `mouseEntered` for it.
    var isLocked = false {
        didSet {
            guard isLocked != oldValue else { return }
            if isLocked {
                setHovering(false)
                hideReadout()
            } else {
                setHovering(isPointerInside)
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        // Zoomed out, the picture is drawn from mipmaps rather than every few pixels.
        imageView.layer?.minificationFilter = .trilinear
        addSubview(imageView)
        addSubview(chrome)
        addSubview(readout)
        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))
        for handle in [dragPill, dragCorner] {
            handle.onDragStart = { [weak self] mouseDown, dragged in self?.beginFileDrag(from: mouseDown, dragged: dragged) }
        }
        chrome.addSubview(closeButton)
        chrome.addSubview(dragPill)
        chrome.addSubview(dragCorner)
        chrome.isHidden = true
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    /// The panel never activates ClearShot, so without this the first click would only bring it forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Configuration

    /// Shows `image`, `imagePoints` in size at 100%. The layer shares the image; nothing is copied.
    func setPicture(_ image: CGImage, imagePoints: CGSize) {
        imageView.image = image
        self.imagePoints = imagePoints
        needsLayout = true
    }

    /// `style` is what is drawn (`PinStyle.effective`). A transparent picture's window is filled with black at 1% so its
    /// whole frame takes clicks and hover; an opaque one sits on a card that fills a window larger than the picture.
    func apply(_ style: PinStyle, isTransparent: Bool) {
        self.style = style
        self.isTransparent = isTransparent
        applyStyle()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        imageView.frame = PinGeometry.imageRect(imagePoints: imagePoints, zoom: zoom)
        chrome.frame = bounds
        layoutChrome()
        layoutReadout()
    }

    private func layoutChrome() {
        let side = Self.buttonSide, inset = Self.buttonInset
        closeButton.frame = NSRect(x: inset, y: bounds.maxY - inset - side, width: side, height: side)
        let roomy = bounds.width >= Self.pillMinimumWindow.width && bounds.height >= Self.pillMinimumWindow.height
        dragPill.isHidden = !roomy
        dragCorner.isHidden = roomy
        if roomy {
            let width = (dragPill.look.attributedTitle.size().width + 2 * Self.pillPadding).rounded(.up)
            dragPill.frame = NSRect(x: (bounds.midX - width / 2).rounded(), y: Self.pillBottom, width: width,
                                    height: Self.pillHeight)
        } else {
            dragCorner.frame = NSRect(x: bounds.maxX - inset - side, y: inset, width: side, height: side)
        }
    }

    private func layoutReadout() {
        let size = readout.preferredSize
        readout.frame = NSRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(),
                               width: size.width, height: size.height)
    }

    // MARK: Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isTransparent ? NSColor.black.withAlphaComponent(0.01) : .windowBackgroundColor).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
        layer?.borderWidth = style.border ? 1 : 0
        layer?.cornerRadius = style.roundedCorners ? PinGeometry.cornerRadius : 0
    }

    // MARK: Opacity readout

    /// Shows `text` ("60%") in the middle of the pin, fading out 0.8 s after the last call.
    func showReadout(_ text: String) {
        readout.text = text
        layoutReadout()
        // A zero-length animation replaces a fade still in flight, so it can't drive the readout back to 0.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            readout.animator().alphaValue = 1
        }
        readoutFade?.cancel()
        readoutFade = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                self.readout.animator().alphaValue = 0
            }
        }
    }

    /// Takes the readout away at once, cancelling its fade.
    private func hideReadout() {
        readoutFade?.cancel()
        readoutFade = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            readout.animator().alphaValue = 0
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways,
                                                              .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }

    /// After `resetHover` with the pointer still over the pin (a capture started under it), no `mouseEntered` comes until
    /// the pointer leaves and returns; the hover controls come back with the next movement instead.
    override func mouseMoved(with event: NSEvent) {
        guard !isDragging else { return }
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        // A drag-out leaves the pin on purpose; hover is settled when the drag ends.
        guard !isDragging else { return }
        setHovering(false)
    }

    private func setHovering(_ hovering: Bool) {
        let hovering = hovering && !isLocked
        guard hovering != isHovering else { return }
        isHovering = hovering
        chrome.isHidden = !hovering
    }

    /// Forgets the hover and takes the readout away at once: a pin ordered out from under the pointer gets no
    /// `mouseExited`, and a capture about to start must show neither.
    func resetHover() {
        setHovering(false)
        hideReadout()
    }

    private var isPointerInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    @objc private func closePressed(_ sender: Any?) {
        delegate?.pinView(self, perform: .close)
    }

    // MARK: Mouse and gestures

    /// The body moves the pin. `performDrag` runs its own loop until the mouse goes up, so no `mouseDragged` follows.
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        window?.performDrag(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        delegate?.pinView(self, perform: .close)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        isLocked ? nil : delegate?.pinViewMenu(self)
    }

    override func magnify(with event: NSEvent) {
        let ended = !event.phase.isDisjoint(with: [.ended, .cancelled])
        delegate?.pinView(self, perform: .pinch(magnification: Double(event.magnification), ended: ended))
    }

    override func scrollWheel(with event: NSEvent) {
        // Momentum after the fingers lift, and mostly sideways scrolls, leave the opacity alone.
        guard event.momentumPhase.isEmpty, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return }
        let up = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        delegate?.pinView(self, perform: .scroll(up: Double(up), precise: event.hasPreciseScrollingDeltas))
    }

    override func keyDown(with event: NSEvent) {
        let direction: PinNudge? = switch event.keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
        guard let direction else { return super.keyDown(with: event) }
        delegate?.pinView(self, perform: .nudge(direction, large: event.modifierFlags.contains(.shift)))
    }

    // MARK: Drag me

    /// Starts a file drag of the capture: its file, and the PNG for targets that take only an image. The drag image is
    /// the picture fitted into 128 × 128 pt under the pointer.
    private func beginFileDrag(from mouseDown: NSEvent, dragged: NSEvent) {
        guard let image = imageView.image, let files = delegate?.pinViewDragFiles(self) else { return }
        dragOptionHeld = dragged.modifierFlags.contains(.option)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(files.file.absoluteString, forType: .fileURL)
        dragProvider = files.png.map(DragImageProvider.init(pngURL:))
        if let dragProvider { pasteboardItem.setDataProvider(dragProvider, forTypes: [.png]) }
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let shown = CGSize(width: imagePoints.width * zoom, height: imagePoints.height * zoom)
        let fit = min(1, Self.dragImageSide / max(shown.width, shown.height, 1))
        let size = CGSize(width: max(1, shown.width * fit), height: max(1, shown.height * fit))
        let maxPixel = Int((max(size.width, size.height) * (window?.backingScaleFactor ?? 2)).rounded(.up))
        let point = convert(mouseDown.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width,
                                     height: size.height),
                              contents: NSImage(cgImage: ImageOps.thumbnail(image, maxPixel: maxPixel), size: size))
        isDragging = true
        beginDraggingSession(with: [item], event: mouseDown, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy, never move: dropping into Finder must leave the saved file where it is.
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        // The pointer may have left while mouseExited was ignored; settle hover now, before the delegate can close us.
        if !isPointerInside { setHovering(false) }
        delegate?.pinView(self, dragEndedWith: operation,
                          optionHeld: dragOptionHeld || NSEvent.modifierFlags.contains(.option))
    }
}

/// The "Drag me" handle: it looks like a hover button but takes the mouse itself, starting a file drag once the pointer
/// has moved 4 pt. A click does nothing, and never reaches the pin below to move it.
private final class PinDragHandle: NSView {
    /// The mouse-down and the drag that moved far enough.
    var onDragStart: ((_ mouseDown: NSEvent, _ dragged: NSEvent) -> Void)?
    /// The button it looks like; it never gets the mouse.
    let look: NSButton
    private var mouseDownEvent: NSEvent?

    init(look: NSButton) {
        self.look = look
        super.init(frame: .zero)
        look.setAccessibilityElement(false)
        addSubview(look)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Drag me")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        look.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        let from = start.locationInWindow, to = event.locationInWindow
        guard hypot(to.x - from.x, to.y - from.y) >= 4 else { return }
        mouseDownEvent = nil
        onDragStart?(start, event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }
}

/// The opacity readout: white digits on a dark capsule. Clicks pass through.
private final class PinReadout: NSView {
    private static let padding = CGSize(width: 12, height: 4)
    /// The headline style with digits of one width, so the capsule doesn't wobble as the value changes.
    private static let font: NSFont = {
        let headline = NSFont.preferredFont(forTextStyle: .headline)
        let descriptor = headline.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: descriptor, size: 0) ?? headline
    }()

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.cornerCurve = .continuous
        label.font = Self.font
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    var preferredSize: CGSize {
        let text = label.fittingSize
        return CGSize(width: (text.width + 2 * Self.padding.width).rounded(.up),
                      height: (text.height + 2 * Self.padding.height).rounded(.up))
    }

    override func layout() {
        super.layout()
        let text = label.fittingSize
        label.frame = NSRect(x: 0, y: ((bounds.height - text.height) / 2).rounded(), width: bounds.width, height: text.height)
        layer?.cornerRadius = bounds.height / 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
