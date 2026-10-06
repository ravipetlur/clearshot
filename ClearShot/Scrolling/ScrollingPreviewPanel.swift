import AppKit
import CSScrolling
import QuartzCore

/// The live preview of a scrolling capture: the stitched picture so far, scaled to fit across the panel, with its
/// newest end in view (the bottom of a vertical capture, the right of a horizontal one). A floating panel (corner
/// radius 10, shadow, 1 px separator border) on the overlay's dark material, child of the frame window and placed by
/// `PreviewPlacement`: beside the region, or under it once the capture turns out horizontal. It ignores the mouse.
final class ScrollingPreviewPanel {
    private static let inset: CGFloat = 8

    private let panel = OverlayChildPanel(takesKey: false)
    private let background = OverlayMaterialView(cornerRadius: 10)
    private let imageView = PreviewImageView()
    private var axis: ScrollAxis = .vertical
    private var anchor: (window: NSWindow, region: CGRect, visibleFrame: CGRect)?

    init() {
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = background
        background.addSubview(imageView)
        background.layer?.borderWidth = 1
        background.effectiveAppearance.performAsCurrentDrawingAppearance {
            background.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// Shows the panel for a capture of `region` growing along `axis`, on `window` (the frame window) within
    /// `visibleFrame`.
    func show(attachedTo window: NSWindow, region: CGRect, axis: ScrollAxis, visibleFrame: CGRect) {
        anchor = (window, region, visibleFrame)
        self.axis = axis
        place()
    }

    /// Moves the panel to the layout for `axis` (under the region for a horizontal capture).
    func setAxis(_ axis: ScrollAxis) {
        guard axis != self.axis else { return }
        self.axis = axis
        place()
    }

    func setImage(_ image: CGImage) {
        imageView.show(image)
    }

    func hide() {
        panel.detach()
        anchor = nil
    }

    private func place() {
        guard let anchor else { return }
        let frame = PreviewPlacement.frame(region: anchor.region, axis: axis, visibleFrame: anchor.visibleFrame)
        panel.attach(to: anchor.window, frame: frame)
        imageView.frame = CGRect(origin: .zero, size: frame.size).insetBy(dx: Self.inset, dy: Self.inset)
        imageView.axis = axis
    }
}

/// The preview picture, clipped to the view: as wide (vertical) or as tall (horizontal) as the view, from the start of
/// the capture while it fits, and from its newest end once it doesn't.
private final class PreviewImageView: NSView {
    private let imageLayer = CALayer()
    private var image: CGImage?
    var axis: ScrollAxis = .vertical {
        didSet { if axis != oldValue { layoutImage() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting view: set the layer before wantsLayer.
        let root = CALayer()
        root.masksToBounds = true
        root.cornerRadius = 4
        root.cornerCurve = .continuous
        layer = root
        wantsLayer = true
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        root.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutImage()
    }

    func show(_ image: CGImage) {
        self.image = image
        layoutImage()
    }

    private func layoutImage() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        imageLayer.contents = image
        guard let image, image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else {
            imageLayer.frame = .zero
            return
        }
        let size = CGSize(width: image.width, height: image.height)
        switch axis {
        case .vertical:
            let height = (size.height * bounds.width / size.width).rounded()
            // y is up: top-aligned while it fits, bottom (the newest rows) in view once it doesn't.
            let y = height <= bounds.height ? bounds.height - height : 0
            imageLayer.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
        case .horizontal:
            let width = (size.width * bounds.height / size.height).rounded()
            let x = width <= bounds.width ? 0 : bounds.width - width
            imageLayer.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }
}
