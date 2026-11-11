import AppKit
import CSAnnotation

/// The ruler under the Select tool. With nothing selected, holding ← or → shows the picture's width through the cursor,
/// from the nearest edge on the left to the nearest on the right; ↑ or ↓ show the height. ⇧ held too measures the outer size
/// (`PixelSampler.rulerSpan`), and the scroll wheel sets the tolerance. It follows the mouse while the key is held and goes
/// with the key; a click imprints it as a ruler annotation.
@MainActor
final class RulerController {
    private unowned let canvas: AnnotationCanvasView
    private unowned let editor: AnnotationEditor
    /// The arrow keys held, in the order they went down: the last one sets the axis.
    private var heldKeys: [UInt16] = []
    private var outer = false
    /// The measurement as the mouse and the picture last had it.
    private var measurement: RulerMeasurement?
    private var scrolled = 0.0
    /// A click imprinted the measurement: the arrow keys still down do nothing (they would nudge the new ruler) until released.
    private var imprinted = false

    init(canvas: AnnotationCanvasView, editor: AnnotationEditor) {
        self.canvas = canvas
        self.editor = editor
    }

    /// Whether a measurement is being made: an arrow key is held and nothing says otherwise.
    var isMeasuring: Bool { !heldKeys.isEmpty && !imprinted && canMeasure }

    private var canMeasure: Bool {
        editor.tool == .select && editor.selection.isEmpty && editor.pixelSelection == nil && editor.crop == nil
            && !canvas.isEditingText
    }

    private var axis: RulerAxis? {
        switch heldKeys.last {
        case 123, 124: .horizontal
        case 125, 126: .vertical
        default: nil
        }
    }

    // MARK: Keys

    /// Takes an arrow key going down when it starts or continues a measurement. Returns whether it did.
    func keyDown(_ event: NSEvent) -> Bool {
        guard (123...126).contains(event.keyCode) else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // A key still down after a click is the click's: it must not nudge the ruler just made.
        if imprinted, heldKeys.contains(event.keyCode) { return true }
        guard flags.isSubset(of: [.shift]), canMeasure else { return false }
        if !heldKeys.contains(event.keyCode) { heldKeys.append(event.keyCode) }
        outer = flags.contains(.shift)
        editor.loadPicturePixels()
        update()
        return true
    }

    /// Takes an arrow key coming up when it was one of the held ones.
    func keyUp(_ event: NSEvent) -> Bool {
        guard let index = heldKeys.firstIndex(of: event.keyCode) else { return false }
        heldKeys.remove(at: index)
        if heldKeys.isEmpty { stop() } else { update() }
        return true
    }

    /// ⇧ going down or up while measuring switches between the inner and the outer size.
    func flagsChanged(_ event: NSEvent) {
        guard !heldKeys.isEmpty else { return }
        outer = event.modifierFlags.contains(.shift)
        update()
    }

    /// The canvas lost the keyboard: the key-up would go elsewhere.
    func stop() {
        heldKeys = []
        measurement = nil
        scrolled = 0
        imprinted = false
        canvas.needsDisplay = true
    }

    // MARK: Mouse

    func mouseMoved() {
        guard !heldKeys.isEmpty else { return }
        update()
    }

    /// The scroll wheel sets the tolerance while measuring. Returns whether it was used.
    func scroll(_ event: NSEvent) -> Bool {
        guard isMeasuring else { return false }
        scrolled += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 6 : event.scrollingDeltaY
        let steps = Int(scrolled)
        guard steps != 0 else { return true }
        scrolled -= Double(steps)
        editor.settings.rulerTolerance = RulerGeometry.clampedTolerance(editor.settings.rulerTolerance + steps)
        update()
        return true
    }

    /// A click while measuring imprints the measurement as a ruler annotation.
    func imprint() {
        guard let object = preview else { return }
        measurement = nil
        imprinted = true
        editor.add(object, actionName: "Add Ruler")
        canvas.needsDisplay = true
    }

    // MARK: Measuring

    private func update() {
        guard isMeasuring, let axis else {
            measurement = nil
            canvas.needsDisplay = true
            return
        }
        guard let pixels = editor.picturePixels else {
            // The picture's pixels are being built: measure when they are ready.
            measurement = nil
            Task { [weak self] in
                _ = await self?.editor.currentPicturePixels()
                self?.update()
            }
            canvas.needsDisplay = true
            return
        }
        guard let window = canvas.window else { return }
        let point = canvas.basePoint(forWindowPoint: window.mouseLocationOutsideOfEventStream)
        measurement = pixels.measure(through: point, axis: axis, outer: outer, tolerance: editor.settings.rulerTolerance)
        canvas.needsDisplay = true
    }

    // MARK: Drawing

    /// The measurement as a ruler, for the canvas to draw with the document (it is labeled like the imprinted one).
    var preview: AnnotationObject? {
        guard isMeasuring, let measurement else { return nil }
        let style = editor.newStyle(lineWidthPoints: ToolSizes.lineWidth(editor.settings.sizeLevel))
        return AnnotationObject(kind: .ruler(RulerObject(start: measurement.start, end: measurement.end)), style: style)
    }

    /// The tolerance (and which size is shown) in a small badge at the end of the measurement.
    func drawHint() {
        guard isMeasuring, let measurement else { return }
        let zoom = max(canvas.magnification(), 0.01)
        let text = "tolerance \(editor.settings.rulerTolerance)" + (outer ? " · outer" : "")
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10 / zoom, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        let pad = 4 / zoom
        let anchor = canvas.viewPoint(fromBase: measurement.end)
        var origin = CGPoint(x: anchor.x + 8 / zoom, y: anchor.y + 8 / zoom)
        let bounds = canvas.bounds
        origin.x = min(max(origin.x, bounds.minX), max(bounds.maxX - size.width - 2 * pad, bounds.minX))
        origin.y = min(max(origin.y, bounds.minY), max(bounds.maxY - size.height - pad, bounds.minY))
        let badge = CGRect(x: origin.x, y: origin.y, width: size.width + 2 * pad, height: size.height + pad)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3 / zoom, yRadius: 3 / zoom).fill()
        string.draw(at: CGPoint(x: badge.minX + pad, y: badge.minY + pad / 2))
    }
}
