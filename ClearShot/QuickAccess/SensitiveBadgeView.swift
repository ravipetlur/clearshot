import AppKit
import CSCore
import CSSensitive

/// What the badge on a thumbnail shows, made from the capture's `BadgeState` (`BadgeText` has the words).
struct SensitiveBadgeContent: Equatable {
    var text: String
    var tooltip: String
    var accessibilityLabel: String
    var accessibilityHelp: String
    var isMasked: Bool

    /// Nil while the state has no badge (scanning, nothing found, dismissed). `masksAdded` is how many masks Mask All made,
    /// which the masked tooltip counts.
    init?(_ state: BadgeState, masksAdded: Int? = nil) {
        guard let text = BadgeText.label(for: state), let tooltip = BadgeText.tooltip(for: state, masksAdded: masksAdded),
              let label = BadgeText.accessibilityLabel(for: state, masksAdded: masksAdded),
              let help = BadgeText.accessibilityHelp(for: state) else {
            return nil
        }
        self.text = text
        self.tooltip = tooltip
        accessibilityLabel = label
        accessibilityHelp = help
        if case .masked = state.phase { isMasked = true } else { isMasked = false }
    }
}

/// The pill at the bottom-left of a screenshot thumbnail when its scan found possible secrets: "⚠︎ 3", then "Masked". It is
/// the dark capsule of the media badge and the overlay buttons (small white text, the warning sign in the system's orange),
/// at one fixed size and one place (`QuickAccessLayout.controls`), and a button: pressing it opens the menu
/// (`QuickAccessView`). It takes clicks only inside its own capsule and sits below the hover buttons, so it never covers one,
/// and the thumbnail's drag and swipe go on working everywhere else.
final class SensitiveBadgeView: NSButton {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    var content: SensitiveBadgeContent? {
        didSet {
            guard content != oldValue else { return }
            isHidden = content == nil
            toolTip = content?.tooltip
            setAccessibilityLabel(content?.accessibilityLabel)
            setAccessibilityHelp(content?.accessibilityHelp)
            attributedTitle = content.map(Self.title(for:)) ?? NSAttributedString()
        }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        isHidden = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.cornerCurve = .continuous
        // A click opens the menu; it must never leave keyboard focus here, where Space would press it instead of opening
        // Quick Look.
        refusesFirstResponder = true
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The thumbnail's panel never activates ClearShot, so without this the first click only brings the panel forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicks count only inside the capsule: the four corners of the view's rectangle are outside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        let local = convert(point, from: superview)
        return QuickAccessLayout.capsuleContains(local, in: bounds.size) ? self : nil
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    /// The warning sign in orange, the rest white. A masked badge says "Masked" in white alone.
    private static func title(for content: SensitiveBadgeContent) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let title = NSMutableAttributedString(string: content.text, attributes: [
            .foregroundColor: NSColor.white, .font: font, .paragraphStyle: style,
        ])
        if !content.isMasked, let sign = content.text.first {
            title.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: NSRange(location: 0, length: String(sign).utf16.count))
        }
        return title
    }
}
