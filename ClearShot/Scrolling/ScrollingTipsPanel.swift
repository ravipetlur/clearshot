import AppKit

/// The scrolling capture's tips: how to select and scroll, and what to do about seams, with "Got it". A child panel of
/// the overlay at its level (an alert or popover would open under it), 360 pt wide, centred on the overlay's display,
/// on the overlay's dark material with the floating-panel border and shadow. It leaves the keys with the overlay. One
/// is up at a time; it opens on the first scrolling capture and from Ready's Help button.
enum ScrollingTipsPanel {
    private static let width: CGFloat = 360
    private static let padding: CGFloat = 16
    private static let symbolWidth: CGFloat = 20

    private static let tips: [(symbol: String, text: String)] = [
        ("crop", "Select only the part that scrolls — leave out toolbars, sidebars and the scroll bar; a fixed header or "
            + "footer is fine, it appears once."),
        ("tortoise", "Scroll slowly and steadily — the preview grows as you go; if ClearShot says to slow down, scroll back "
            + "a little and carry on."),
        ("arrow.down", "Pick one direction — scroll down or to the right; the first movement sets the direction, or use "
            + "Auto-Scroll."),
    ]
    private static let seams = "If the result has seams: avoid areas with animations or videos, scroll straight, don't "
        + "scroll too fast, and start at the top (scrolling up first is ignored)."

    /// The panel on screen and what to run when it closes.
    private static var current: (panel: OverlayChildPanel, onClose: () -> Void)?

    static var isShown: Bool {
        current != nil
    }

    /// The point (AppKit global points) is over the tips: the overlay shows the arrow there, as over its toolbar.
    static func contains(_ point: CGPoint) -> Bool {
        current?.panel.frame.contains(point) == true
    }

    /// Opens the tips over `window` (an overlay window), unless they are up already. `onClose` runs when they close,
    /// whether by "Got it", Esc on the overlay or the overlay closing (`close`).
    static func show(over window: NSWindow, onClose: @escaping () -> Void) {
        guard current == nil else { return }
        let content = makeContent()
        let size = CGSize(width: width, height: ceil(content.fittingSize.height))
        content.frame = CGRect(origin: .zero, size: size)
        let panel = OverlayChildPanel(takesKey: false)
        panel.hasShadow = true
        panel.contentView = content
        let frame = CGRect(x: (window.frame.midX - size.width / 2).rounded(),
                           y: (window.frame.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        current = (panel, onClose)
        panel.attach(to: window, frame: frame)
    }

    /// Closes the tips, if they are up, and runs their `onClose`.
    static func close() {
        guard let current else { return }
        self.current = nil
        current.panel.detach()
        current.onClose()
    }

    // MARK: Content

    private static func makeContent() -> NSView {
        let material = OverlayMaterialView(cornerRadius: 10)
        material.onPointerInside = { NSCursor.arrow.set() }
        material.layer?.borderWidth = 1
        material.effectiveAppearance.performAsCurrentDrawingAppearance {
            material.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        let textWidth = width - padding * 2

        let title = NSTextField(labelWithString: "Scrolling capture tips")
        title.font = .preferredFont(forTextStyle: .headline)
        let rows = tips.map { tipRow(symbol: $0.symbol, text: $0.text, width: textWidth) }
        let seamsLabel = label(NSAttributedString(string: seams, attributes: [
            .font: NSFont.preferredFont(forTextStyle: .callout), .foregroundColor: NSColor.secondaryLabelColor,
        ]), width: textWidth)
        let gotIt = PressButton(title: "Got it") { close() }
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.setViews([gotIt], in: .trailing)

        let stack = NSStackView(views: [title] + rows + [seamsLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(stack)
        NSLayoutConstraint.activate([
            material.widthAnchor.constraint(equalToConstant: width),
            stack.topAnchor.constraint(equalTo: material.topAnchor, constant: padding),
            stack.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -padding),
            stack.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -padding),
            buttonRow.widthAnchor.constraint(equalToConstant: textWidth),
        ])
        return material
    }

    /// A symbol, then the tip with its lead (up to the dash) in semibold.
    private static func tipRow(symbol: String, text: String, width: CGFloat) -> NSView {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: body, .foregroundColor: NSColor.labelColor])
        if let dash = text.range(of: " — ") {
            attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: body.pointSize, weight: .semibold),
                                    range: NSRange(text.startIndex..<dash.lowerBound, in: text))
        }
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .body)
        image.contentTintColor = .controlAccentColor
        image.widthAnchor.constraint(equalToConstant: symbolWidth).isActive = true
        let row = NSStackView(views: [image, label(attributed, width: width - symbolWidth - 8)])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        return row
    }

    private static func label(_ text: NSAttributedString, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = width
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }
}

/// A push button that works on the first click in a panel that isn't key (the overlay keeps the keys).
private final class PressButton: NSButton {
    private var onPress: (() -> Void)?

    convenience init(title: String, onPress: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        self.onPress = onPress
        target = self
        action = #selector(press)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func press() {
        onPress?()
    }
}
