import AppKit
import CSAnnotation
import CSCore

/// Where the pointer last was over the canvas, and the chip that shows the color under it.
struct ColorHover {
    /// The pointer in view points; nil while it is off the canvas or a press is under way.
    var viewPoint: NSPoint?
    /// The pointer in base pixels as it last was over the canvas, which Edit › Copy Color Under Pointer reads (the pointer
    /// is in the menu bar by then).
    var lastBase: CGPoint?
    /// The chip as last drawn, in view points, so that it is redrawn away when the pointer moves.
    var chipRect: CGRect?
}

/// Colors copied from the picture with the Select tool: Tab, ⇧Tab and ⌥Tab (and Edit's items, which have no key), and the
/// chip by the pointer that shows the color it is over. What each command reads is `ColorCopy`'s.
extension AnnotationCanvasView {
    // MARK: Commands

    /// Whether the color-copy commands apply now: the Select tool, outside Crop & Resize and text editing.
    private var colorCopyIsActive: Bool {
        editor.tool == .select && editor.crop == nil && !isEditingText
    }

    /// Tab, ⇧Tab and ⌥Tab. Returns whether the key was taken: with nothing to read (the pointer is off the picture, ⌥Tab
    /// without a selection) Tab keeps its usual job.
    func handleColorCopyKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 48, colorCopyIsActive else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let command: ColorCopy
        switch flags {
        case []: command = .underPointer
        case .shift: command = .textUnderPointer
        case .option: command = .selectionAverage
        default: return false
        }
        // A key repeat would copy again and again.
        if event.isARepeat { return true }
        return copyColor(command, pointer: livePointerBase())
    }

    @objc func copyColorUnderPointer(_ sender: Any?) { copyColor(.underPointer, pointer: colorHover.lastBase) }
    @objc func copyTextColorUnderPointer(_ sender: Any?) { copyColor(.textUnderPointer, pointer: colorHover.lastBase) }
    @objc func copyAverageColorOfSelection(_ sender: Any?) { copyColor(.selectionAverage, pointer: nil) }

    func validateColorCopy(_ action: Selector?) -> Bool? {
        switch action {
        case #selector(copyColorUnderPointer(_:)), #selector(copyTextColorUnderPointer(_:)):
            editor.crop == nil && !isEditingText && colorHover.lastBase != nil
        case #selector(copyAverageColorOfSelection(_:)):
            editor.crop == nil && !isEditingText && editor.pixelSelection != nil
        default:
            nil
        }
    }

    /// Copies what `command` reads, in the chosen format, and says so. The pixels are built first if they aren't ready, and
    /// the copy lands when they are, so the first Tab after a hover that has not finished building still works. Returns
    /// whether there was something to read.
    @discardableResult
    private func copyColor(_ command: ColorCopy, pointer: CGPoint?) -> Bool {
        let selection = editor.pixelSelection
        switch command {
        case .selectionAverage: guard selection != nil else { return false }
        case .underPointer, .textUnderPointer: guard pointer != nil else { return false }
        }
        if let pixels = editor.picturePixels {
            return copyColor(command, from: pixels, pointer: pointer, selection: selection)
        }
        Task { @MainActor [weak self] in
            guard let self, let pixels = await editor.currentPicturePixels() else { return }
            copyColor(command, from: pixels, pointer: pointer, selection: selection)
        }
        return true
    }

    @discardableResult
    private func copyColor(_ command: ColorCopy, from pixels: PicturePixels, pointer: CGPoint?, selection: CGRect?) -> Bool {
        guard let color = command.color(in: pixels, pointer: pointer, selection: selection) else { return false }
        let text = ColorCopy.text(for: color, format: editor.preferences[Prefs.annotateColorCopyFormat])
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        colorCopied?(ColorCopy.notice(copying: text))
        return true
    }

    /// The pointer in base pixels now, or nil when it is not over the canvas.
    private func livePointerBase() -> CGPoint? {
        guard let window else { return nil }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return nil }
        return basePoint(forView: point)
    }

    // MARK: Chip

    /// Tracks the pointer over the canvas, for the chip.
    func installColorHoverTracking() {
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    func colorHoverMoved(to event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        colorHover.viewPoint = point
        colorHover.lastBase = basePoint(forView: point)
        // The pixels are only built once a pointer is over the picture with the Select tool.
        if editor.tool == .select, editor.crop == nil, editor.picturePixels == nil { editor.loadPicturePixels() }
        redrawColorChip()
    }

    /// The pointer left, or a press began (a drag draws no chip): the chip goes. `lastBase` stays for the menu items.
    func colorHoverEnded() {
        guard colorHover.viewPoint != nil else { return }
        colorHover.viewPoint = nil
        redrawColorChip()
    }

    /// Draws the chip afresh: where it was and where it will be.
    private func redrawColorChip() {
        if let old = colorHover.chipRect { setNeedsDisplay(old.insetBy(dx: -2, dy: -2)) }
        colorHover.chipRect = nil
        if let chip = colorChip() {
            colorHover.chipRect = chip.rect
            setNeedsDisplay(chip.rect.insetBy(dx: -2, dy: -2))
        }
    }

    /// The chip to show now, if one: the pointer is over the picture with the Select tool, outside text editing and Crop &
    /// Resize, and the pixels are ready.
    private func colorChip() -> (rect: CGRect, text: String, color: RGBAColor)? {
        guard let point = colorHover.viewPoint, colorCopyIsActive,
              let pixels = editor.picturePixels,
              let color = pixels.color(at: basePoint(forView: point)) else { return nil }
        let text = ColorCopy.text(for: color, format: editor.preferences[Prefs.annotateColorCopyFormat])
        let zoom = max(magnification(), 0.01)
        let size = (text as NSString).size(withAttributes: [.font: chipFont(zoom)])
        let pad = 5 / zoom, swatch = 12 / zoom, gap = 5 / zoom
        let box = CGSize(width: pad + swatch + gap + size.width + pad, height: max(size.height, swatch) + pad)
        // Down and right of the pointer, flipped to the other side at the canvas's edges.
        var origin = CGPoint(x: point.x + 14 / zoom, y: point.y + 14 / zoom)
        if origin.x + box.width > bounds.maxX { origin.x = point.x - 14 / zoom - box.width }
        if origin.y + box.height > bounds.maxY { origin.y = point.y - 14 / zoom - box.height }
        return (CGRect(origin: origin, size: box), text, color)
    }

    private func chipFont(_ zoom: Double) -> NSFont {
        .monospacedDigitSystemFont(ofSize: 11 / zoom, weight: .medium)
    }

    /// Draws the chip: a swatch and the value, at a constant size on screen.
    func drawColorChip() {
        guard let chip = colorChip() else { return }
        let zoom = max(magnification(), 0.01)
        let pad = 5 / zoom, swatch = 12 / zoom, gap = 5 / zoom
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: chip.rect, xRadius: 4 / zoom, yRadius: 4 / zoom).fill()
        let swatchRect = CGRect(x: chip.rect.minX + pad, y: chip.rect.midY - swatch / 2, width: swatch, height: swatch)
        NSColor(srgbRed: chip.color.red, green: chip.color.green, blue: chip.color.blue, alpha: 1).setFill()
        let path = NSBezierPath(roundedRect: swatchRect, xRadius: 2 / zoom, yRadius: 2 / zoom)
        path.fill()
        NSColor.white.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1 / zoom
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: chipFont(zoom), .foregroundColor: NSColor.white]
        let textSize = (chip.text as NSString).size(withAttributes: attributes)
        (chip.text as NSString).draw(at: CGPoint(x: swatchRect.maxX + gap, y: chip.rect.midY - textSize.height / 2),
                                     withAttributes: attributes)
    }
}
