import AppKit
import CSCapture
import QuartzCore

/// Everything one display's overlay draws. Rects and points arrive in this view's coordinates (y up).
struct OverlayRenderState {
    var selection: CGRect?
    var windowHighlight: CGRect?
    var cursor: CGPoint?
    var showsCrosshair = false
    var magnifierImage: CGImage?
    var label: String?
    var labelAnchor: CGPoint?
    var prompt: String?
    /// The selection's resize handles (All-In-One): their centres.
    var handles: [CGPoint] = []
}

final class OverlayView: NSView {
    weak var session: OverlaySession?

    private let snapshotLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let windowLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let labelBackground = CALayer()
    private let labelLayer = CATextLayer()
    private let promptBackground = CALayer()
    private let promptLayer = CATextLayer()
    private let magnifierLayer = CALayer()
    private let magnifierGrid = CAShapeLayer()
    private var dims = true
    /// A ⌃-click that AppKit routed to rightMouseDown(with:) is under way.
    private var controlClickInProgress = false
    private static let magnifierSide: CGFloat = 128
    static let handleDiameter: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting view: set the layer before wantsLayer; nothing is drawn with draw(_:).
        let root = CALayer()
        layer = root
        wantsLayer = true

        snapshotLayer.contentsGravity = .resize
        snapshotLayer.isHidden = true

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor

        selectionLayer.fillColor = nil
        selectionLayer.strokeColor = NSColor.controlAccentColor.cgColor
        selectionLayer.lineWidth = 1

        windowLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        windowLayer.strokeColor = NSColor.controlAccentColor.cgColor
        windowLayer.lineWidth = 2

        handleLayer.fillColor = NSColor.white.cgColor
        handleLayer.strokeColor = NSColor.controlAccentColor.cgColor
        handleLayer.lineWidth = 1

        crosshairLayer.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        crosshairLayer.lineWidth = 1
        crosshairLayer.shadowColor = NSColor.black.cgColor
        crosshairLayer.shadowOpacity = 0.6
        crosshairLayer.shadowRadius = 1
        crosshairLayer.shadowOffset = .zero

        for (background, text) in [(labelBackground, labelLayer), (promptBackground, promptLayer)] {
            background.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
            background.cornerRadius = 6
            background.cornerCurve = .continuous
            background.isHidden = true
            text.foregroundColor = NSColor.white.cgColor
            text.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            text.fontSize = 12
            text.alignmentMode = .center
            background.addSublayer(text)
        }

        magnifierLayer.magnificationFilter = .nearest
        magnifierLayer.cornerRadius = 10
        magnifierLayer.cornerCurve = .continuous
        magnifierLayer.masksToBounds = true
        magnifierLayer.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        magnifierLayer.borderWidth = 1
        magnifierLayer.isHidden = true
        magnifierGrid.strokeColor = NSColor.black.withAlphaComponent(0.15).cgColor
        magnifierGrid.lineWidth = 0.5
        magnifierGrid.fillColor = nil
        magnifierLayer.addSublayer(magnifierGrid)

        [snapshotLayer, dimLayer, windowLayer, selectionLayer, handleLayer, crosshairLayer, labelBackground, promptBackground,
         magnifierLayer].forEach(root.addSublayer)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        [labelLayer, promptLayer].forEach { $0.contentsScale = scale }
    }

    func configure(snapshot: CGImage?, dim: Bool) {
        dims = dim
        setSnapshot(snapshot)
    }

    func setSnapshot(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapshotLayer.contents = image
        snapshotLayer.isHidden = image == nil
        snapshotLayer.frame = bounds
        CATransaction.commit()
    }

    func render(_ state: OverlayRenderState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let dimPath = CGMutablePath()
        if dims { dimPath.addRect(bounds) }
        if let selection = state.selection, dims { dimPath.addRect(selection) }
        dimLayer.path = dimPath
        dimLayer.frame = bounds

        selectionLayer.path = state.selection.map { CGPath(rect: $0.insetBy(dx: -0.5, dy: -0.5), transform: nil) }
        windowLayer.path = state.windowHighlight.map { CGPath(roundedRect: $0, cornerWidth: 8, cornerHeight: 8, transform: nil) }
        let handles = CGMutablePath()
        let diameter = Self.handleDiameter
        for center in state.handles {
            handles.addEllipse(in: CGRect(origin: center, size: .zero).insetBy(dx: -diameter / 2, dy: -diameter / 2))
        }
        handleLayer.path = handles

        let cross = CGMutablePath()
        if state.showsCrosshair, let cursor = state.cursor {
            cross.move(to: CGPoint(x: bounds.minX, y: cursor.y.rounded() + 0.5))
            cross.addLine(to: CGPoint(x: bounds.maxX, y: cursor.y.rounded() + 0.5))
            cross.move(to: CGPoint(x: cursor.x.rounded() + 0.5, y: bounds.minY))
            cross.addLine(to: CGPoint(x: cursor.x.rounded() + 0.5, y: bounds.maxY))
        }
        crosshairLayer.path = cross

        place(text: state.label, in: labelBackground, textLayer: labelLayer, near: state.labelAnchor)
        place(text: state.prompt, in: promptBackground, textLayer: promptLayer,
              near: CGPoint(x: bounds.midX, y: bounds.maxY - 80), centered: true)

        if let image = state.magnifierImage, let cursor = state.cursor {
            magnifierLayer.isHidden = false
            magnifierLayer.contents = image
            let side = Self.magnifierSide
            var origin = CGPoint(x: cursor.x + 24, y: cursor.y - 24 - side)
            if origin.x + side > bounds.maxX { origin.x = cursor.x - 24 - side }
            if origin.y < bounds.minY { origin.y = cursor.y + 24 }
            magnifierLayer.frame = CGRect(origin: origin, size: CGSize(width: side, height: side))
            magnifierGrid.frame = magnifierLayer.bounds
            magnifierGrid.path = Self.gridPath(side: side, cells: CGFloat(Magnifier.gridSize))
        } else {
            magnifierLayer.isHidden = true
        }
    }

    private func place(text: String?, in background: CALayer, textLayer: CATextLayer, near anchor: CGPoint?, centered: Bool = false) {
        guard let text, let anchor else {
            background.isHidden = true
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        let size = (text as NSString).size(withAttributes: attributes)
        let padded = CGSize(width: ceil(size.width) + 16, height: ceil(size.height) + 8)
        var origin = centered ? CGPoint(x: anchor.x - padded.width / 2, y: anchor.y) : CGPoint(x: anchor.x + 8, y: anchor.y - padded.height - 8)
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - padded.width - 8)
        origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - padded.height - 8)
        background.isHidden = false
        background.frame = CGRect(origin: origin, size: padded)
        textLayer.string = text
        textLayer.frame = CGRect(x: 0, y: 4, width: padded.width, height: ceil(size.height))
    }

    private static func gridPath(side: CGFloat, cells: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let step = side / cells
        for index in 1..<Int(cells) {
            let offset = CGFloat(index) * step
            path.move(to: CGPoint(x: offset, y: 0)); path.addLine(to: CGPoint(x: offset, y: side))
            path.move(to: CGPoint(x: 0, y: offset)); path.addLine(to: CGPoint(x: side, y: offset))
        }
        let center = (cells / 2).rounded(.down) * step
        path.addRect(CGRect(x: center, y: center, width: step, height: step))
        return path
    }

    // MARK: Events → session (global AppKit points)

    override func mouseMoved(with event: NSEvent) { session?.mouseMoved(to: NSEvent.mouseLocation, flags: event.modifierFlags) }
    override func mouseDown(with event: NSEvent) { session?.mouseDown(at: NSEvent.mouseLocation, flags: event.modifierFlags) }
    override func mouseDragged(with event: NSEvent) { session?.mouseDragged(to: NSEvent.mouseLocation, flags: event.modifierFlags) }
    override func mouseUp(with event: NSEvent) {
        controlClickInProgress = false
        session?.mouseUp(at: NSEvent.mouseLocation, flags: event.modifierFlags)
    }

    // AppKit treats ⌃-click as a secondary click and calls rightMouseDown(with:) with the original left-button event. ⌃
    // at capture time adds Copy, so that click selects like any other, and its drag and release continue the selection
    // whichever methods they arrive in. Only the real right button cancels.
    override func rightMouseDown(with event: NSEvent) {
        let isControlClick = event.type == .leftMouseDown || (event.modifierFlags.contains(.control) && event.buttonNumber == 0)
        guard isControlClick else {
            session?.cancel()
            return
        }
        controlClickInProgress = true
        session?.mouseDown(at: NSEvent.mouseLocation, flags: event.modifierFlags)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard controlClickInProgress || event.type == .leftMouseDragged else { return }
        session?.mouseDragged(to: NSEvent.mouseLocation, flags: event.modifierFlags)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard controlClickInProgress || event.type == .leftMouseUp else { return }
        controlClickInProgress = false
        session?.mouseUp(at: NSEvent.mouseLocation, flags: event.modifierFlags)
    }

    // In All-In-One, ⌘C arrives here before keyDown(with:), since the main menu's Edit › Copy has it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let session, session.isAllInOne, session.allInOneKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) { session?.keyDown(event) }
    override func keyUp(with event: NSEvent) { session?.keyUp(event) }
    override func flagsChanged(with event: NSEvent) { session?.flagsChanged(event.modifierFlags) }
}
