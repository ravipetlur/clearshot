import AppKit
import CSRecording
import SwiftUI

/// Settings' live preview of Highlight Clicks: a box saying "Click here to preview" that draws the recording's own ring
/// (`ClickRippleLayer`) at each click inside it, left or right, in `style`. The pane gives it 280 × 120 pt.
struct ClickPreview: NSViewRepresentable {
    var style: ClickRippleStyle

    func makeNSView(context: Context) -> ClickPreviewView {
        ClickPreviewView(style: style)
    }

    func updateNSView(_ view: ClickPreviewView, context: Context) {
        view.style = style
    }
}

/// The box and its label, drawn; the rings in a layer above them, clipped to the box.
final class ClickPreviewView: NSView {
    private static let label = "Click here to preview"
    private static let cornerRadius: CGFloat = 8

    var style: ClickRippleStyle
    private let ringLayer = CALayer()
    /// By mouse button number, as the recording's overlay keeps them.
    private var rings = ClickRings<Int>()

    init(style: ClickRippleStyle) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        ringLayer.masksToBounds = true
        ringLayer.cornerRadius = Self.cornerRadius
        ringLayer.cornerCurve = .continuous
        layer?.addSublayer(ringLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { false }

    /// A click in Settings while another app is in front still draws its ring.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ringLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        ringLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.cornerRadius,
                               yRadius: Self.cornerRadius)
        NSColor.quaternaryLabelColor.setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.lineWidth = 1
        box.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = Self.label as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                  withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { press(event) }
    override func mouseUp(with event: NSEvent) { release(event) }
    override func rightMouseDown(with event: NSEvent) { press(event) }
    override func rightMouseUp(with event: NSEvent) { release(event) }

    /// No context menu: a right click is a click to preview.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    private func press(_ event: NSEvent) {
        rings.press(event.buttonNumber, at: convert(event.locationInWindow, from: nil), style: style, in: ringLayer)
    }

    private func release(_ event: NSEvent) {
        rings.release(event.buttonNumber, style: style)
    }
}
