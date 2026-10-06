import AppKit
import CSCore
import QuartzCore

/// The frame around a region being captured live (Scrolling Capture, a recording): one borderless panel over the
/// region's display, above everything and click-through, so the person works in the apps below. It dims the display
/// outside the region (when asked), can dim the region too (a paused recording), draws a 1 pt accent frame around the
/// region (unless asked not to: a whole display) and can show a prompt centred in the region. The capture's control bar
/// and panels are its children. Like every ClearShot window it is left out of the region's stream.
final class RegionFrameWindow: DisplayOverlayPanel {
    private let frameView: FrameView

    /// `region` in AppKit global points, on `display`. `prompt` is the text `showsPrompt` shows.
    init(display: DisplayInfo, region: CGRect, dims: Bool, drawsFrame: Bool = true, prompt: String? = nil) {
        let local = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        frameView = FrameView(frame: CGRect(origin: .zero, size: display.frame.size), region: local, dims: dims,
                              drawsFrame: drawsFrame, prompt: prompt)
        super.init(display: display, level: .screenSaver)
        contentView = frameView
    }

    /// The prompt, centred in the region.
    var showsPrompt: Bool {
        get { frameView.showsPrompt }
        set { frameView.showsPrompt = newValue }
    }

    /// The region dimmed as the rest of the display is (a paused recording).
    var dimsRegion: Bool {
        get { frameView.dimsRegion }
        set { frameView.dimsRegion = newValue }
    }
}

/// The dimming, the frame and the prompt, as layers (y up, window coordinates).
private final class FrameView: NSView {
    private static let dimColor = NSColor.black.withAlphaComponent(0.4).cgColor

    private let dimLayer = CAShapeLayer()
    private let regionDimLayer = CAShapeLayer()
    private let frameLayer = CAShapeLayer()
    private let promptBackground = CALayer()
    private let promptLayer = CATextLayer()

    var showsPrompt = false {
        didSet {
            guard showsPrompt != oldValue else { return }
            withoutAnimation { promptBackground.isHidden = !showsPrompt }
        }
    }

    var dimsRegion = false {
        didSet {
            guard dimsRegion != oldValue else { return }
            withoutAnimation { regionDimLayer.isHidden = !dimsRegion }
        }
    }

    init(frame: CGRect, region: CGRect, dims: Bool, drawsFrame: Bool, prompt: String?) {
        super.init(frame: frame)
        // Layer-hosting view: set the layer before wantsLayer; nothing is drawn with draw(_:).
        let root = CALayer()
        layer = root
        wantsLayer = true

        let dimPath = CGMutablePath()
        if dims {
            dimPath.addRect(CGRect(origin: .zero, size: frame.size))
            dimPath.addRect(region)
        }
        dimLayer.path = dimPath
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = Self.dimColor
        dimLayer.frame = bounds

        regionDimLayer.path = CGPath(rect: region, transform: nil)
        regionDimLayer.fillColor = Self.dimColor
        regionDimLayer.frame = bounds
        regionDimLayer.isHidden = true

        // Half a point out, so the 1 pt line lies just outside the region, as the selection's does on the overlay.
        frameLayer.path = CGPath(rect: region.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        frameLayer.fillColor = nil
        frameLayer.strokeColor = NSColor.controlAccentColor.cgColor
        frameLayer.lineWidth = 1
        frameLayer.frame = bounds
        frameLayer.isHidden = !drawsFrame

        // The overlay's label look: white monospaced-digit text on a dark rounded rectangle.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let text = prompt ?? ""
        let size = (text as NSString).size(withAttributes: [.font: font])
        let padded = CGSize(width: ceil(size.width) + 16, height: ceil(size.height) + 8)
        promptBackground.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        promptBackground.cornerRadius = 6
        promptBackground.cornerCurve = .continuous
        promptBackground.frame = CGRect(x: (region.midX - padded.width / 2).rounded(),
                                        y: (region.midY - padded.height / 2).rounded(), width: padded.width,
                                        height: padded.height)
        promptBackground.isHidden = true
        promptLayer.string = text
        promptLayer.font = font
        promptLayer.fontSize = 12
        promptLayer.foregroundColor = NSColor.white.cgColor
        promptLayer.alignmentMode = .center
        promptLayer.frame = CGRect(x: 0, y: 4, width: padded.width, height: ceil(size.height))
        promptBackground.addSublayer(promptLayer)

        [dimLayer, regionDimLayer, frameLayer, promptBackground].forEach(root.addSublayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Both, so the prompt's text is sharp from the first time it shows.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        promptLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        promptLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    private func withoutAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}
