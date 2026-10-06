import AppKit
import CSCore

/// One button of a selection toolbar. `id` names it in `SelectionToolbarAction.pressed`; `title`, when set, shows beside
/// the symbol; `hoverLabel` shows over the toolbar while the pointer is on the button.
struct SelectionToolbarButton: Equatable {
    let id: String
    let symbol: String
    var title: String? = nil
    let hoverLabel: String
    var isProminent = false
    var isOn = false
    var isEnabled = true
}

/// What a selection toolbar shows, left to right.
enum SelectionToolbarItem: Equatable {
    case button(SelectionToolbarButton)
    /// The W × H fields, in whole points.
    case sizeFields(width: Int, height: Int)
    /// A button its owner opens a list from (the ratio list); a click reports `.pressed(id:)`.
    case menuButton(id: String, title: String?, symbol: String, hoverLabel: String)
    /// A line of text: a size, or a warning, with a smaller second line under it (what to do about the warning).
    case message(String, isWarning: Bool, detail: String? = nil)
    /// A level meter, 0…1: the microphone's (`AudioLevel.meterLevel`).
    case meter(id: String, level: Double)
    case divider
}

enum SelectionToolbarAction: Equatable {
    case pressed(id: String)
    /// A size typed in a field: only the side that was edited.
    case sizeCommitted(width: Int?, height: Int?)
    /// No field edits any more, so the overlay can take the keys back.
    case editingEnded
}

/// A selection's toolbar: a dark material capsule of buttons, size fields and messages in a child panel of the overlay,
/// placed by `ToolbarPlacement` (or at a frame its owner chose), with each button's label drawn over the toolbar on
/// hover.
///
/// It is AppKit in panels at the overlay's level because menus, tooltips and the HUD all sit under the overlay, and its
/// hover tracking has to work while ClearShot isn't the active app. A click on a button leaves the keys with the
/// overlay; a click in a size field makes the toolbar key until editing ends (`isEditing`). Made with `takesKey` false
/// (a recording's control bar) it never becomes key at all, so Return and Esc never reach it; its buttons still take
/// clicks.
final class SelectionToolbar: NSObject, NSTextFieldDelegate {
    static let padding: CGFloat = 8
    static let spacing: CGFloat = 4
    static let buttonSide: CGFloat = 28

    /// Where `show` put the toolbar: anchored to a selection by `ToolbarPlacement`, or at a frame its owner chose.
    private enum Placement {
        case selection(CGRect)
        case frame(CGRect)
    }

    private let onAction: (SelectionToolbarAction) -> Void
    private let panel: OverlayChildPanel
    private let capsule = OverlayMaterialView(cornerRadius: nil)
    private let hoverLabel = HoverLabel()
    private var items: [SelectionToolbarItem] = []
    private var itemViews: [NSView] = []
    private var widthField: NumberField?
    private var heightField: NumberField?
    /// The window, placement and visible frame of the last `show`, to place the toolbar again when its items change.
    private var anchor: (window: NSWindow, placement: Placement, visibleFrame: CGRect)?
    private weak var hoveredButton: ToolbarButtonView?
    /// Set while the toolbar ends editing on its own (hiding): the field then reports nothing.
    private var isQuiet = false

    /// Which side of the selection the toolbar went to on the last `show`.
    private(set) var side: ToolbarPlacement.Side = .below

    /// A click or Tab put a size field up for editing (the toolbar now has the keys).
    var onEditingBegan: (() -> Void)?

    /// Keys that reach the toolbar while it is key and no field edits (the scrolling capture's control bar takes Return
    /// and Esc); returns whether it used the key.
    var onKeyDown: ((NSEvent) -> Bool)? {
        get { panel.onKeyDown }
        set { panel.onKeyDown = newValue }
    }

    /// False hides the hover label and shows none (while a list from the toolbar is open over it).
    var showsHoverLabels = true {
        didSet {
            guard showsHoverLabels != oldValue else { return }
            if showsHoverLabels, let hoveredButton { showHoverLabel(for: hoveredButton) } else { hoverLabel.hide() }
        }
    }

    /// With `takesKey` false the toolbar is never key, even for a size field (so it should have none).
    init(takesKey: Bool = true, onAction: @escaping (SelectionToolbarAction) -> Void) {
        self.onAction = onAction
        panel = OverlayChildPanel(takesKey: takesKey)
        super.init()
        panel.hasShadow = true
        panel.contentView = capsule
        capsule.onPointerInside = { NSCursor.arrow.set() }
    }

    // MARK: Showing

    /// Shows `items`, rebuilding only what changed. A field being edited keeps its text.
    func update(_ items: [SelectionToolbarItem]) {
        guard items != self.items else { return }
        let sameShape = items.count == self.items.count && zip(items, self.items).allSatisfy { $0.hasSameShape(as: $1) }
        self.items = items
        if sameShape {
            for (item, view) in zip(items, itemViews) { configure(view, with: item) }
        } else {
            rebuild()
        }
        layoutItems()
        if panel.parent != nil { place() }
    }

    /// Attaches the toolbar to `window` (the overlay of the selection's display) and places it by `ToolbarPlacement`
    /// within `visibleFrame`.
    func show(attachedTo window: NSWindow, anchoredTo selection: CGRect, visibleFrame: CGRect) {
        anchor = (window, .selection(selection), visibleFrame)
        place()
    }

    /// Attaches the toolbar to `window` at `frame` (global points), which its owner worked out from `fittingSize`
    /// (`RecordingControlsPlacement`). When its items change it keeps the frame's origin; the owner places it again.
    func show(attachedTo window: NSWindow, frame: CGRect) {
        anchor = (window, .frame(frame), window.screen?.visibleFrame ?? window.frame)
        place()
    }

    /// Hides the toolbar and its hover label and detaches them from the overlay. A field being edited goes back to the
    /// value it showed, without reporting anything.
    func hide() {
        if isEditing {
            isQuiet = true
            panel.makeFirstResponder(nil)
            isQuiet = false
        }
        anchor = nil
        hoveredButton = nil
        hoverLabel.hide()
        // Hidden panels get no mouse-exited events: forget the hover and press states.
        itemViews.forEach { ($0 as? ToolbarButtonView)?.endHover() }
        panel.detach()
    }

    /// A size field is being edited (the toolbar then has the keys).
    var isEditing: Bool {
        widthField?.currentEditor() != nil || heightField?.currentEditor() != nil
    }

    /// Ends editing in a size field, committing a valid typed size.
    func endEditing() {
        guard isEditing else { return }
        panel.makeFirstResponder(nil)
    }

    /// Makes the shown toolbar key without activating ClearShot, so the keys come to `onKeyDown`.
    func makeKey() {
        guard panel.parent != nil else { return }
        panel.makeKey()
    }

    /// The toolbar's frame in global points; `.zero` while hidden.
    var frame: CGRect {
        panel.parent == nil ? .zero : panel.frame
    }

    /// The overlay window it is attached to.
    var parentWindow: NSWindow? {
        panel.parent
    }

    /// The visible frame it was placed in.
    var visibleFrame: CGRect {
        anchor?.visibleFrame ?? .zero
    }

    /// Where the button or menu button `id` is on screen.
    func screenFrame(ofItem id: String) -> CGRect? {
        guard panel.parent != nil,
              let view = itemViews.first(where: { ($0 as? ToolbarButtonView)?.button.id == id }) else { return nil }
        return panel.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func place() {
        guard let anchor else { return }
        let frame: CGRect
        switch anchor.placement {
        case .selection(let selection):
            let placement = ToolbarPlacement.frame(size: fittingSize, anchoredTo: selection, visibleFrame: anchor.visibleFrame)
            side = placement.side
            frame = placement.frame
        case .frame(let given):
            frame = CGRect(origin: given.origin, size: fittingSize)
            // Hover labels go over a toolbar in the lower half of the screen and under one in the upper half.
            side = frame.midY > anchor.visibleFrame.midY ? .above : .below
        }
        panel.attach(to: anchor.window, frame: frame)
        // The toolbar may have moved out from under the pointer (Toggle fullscreen, typed sizes, arrows).
        if let hoveredButton {
            if hoveredButton.containsPointer {
                showHoverLabel(for: hoveredButton)
            } else {
                hoveredButton.endHover()
                hoverEnded(hoveredButton)
            }
        }
    }

    /// The size the items need: what a toolbar placed at a frame (`show(attachedTo:frame:)`) is given.
    var fittingSize: CGSize {
        let widths = itemViews.map(\.intrinsicContentSize.width)
        let content = widths.reduce(0, +) + Self.spacing * CGFloat(max(widths.count - 1, 0))
        return CGSize(width: ceil(content + Self.padding * 2), height: Self.buttonSide + Self.padding * 2)
    }

    // MARK: Items

    private func rebuild() {
        itemViews.forEach { $0.removeFromSuperview() }
        hoveredButton = nil
        hoverLabel.hide()
        widthField = nil
        heightField = nil
        itemViews = items.map(makeView)
        itemViews.forEach(capsule.addSubview)
    }

    private func makeView(for item: SelectionToolbarItem) -> NSView {
        let view: NSView
        switch item {
        case .button, .menuButton:
            let button = ToolbarButtonView()
            button.onPress = { [weak self, weak button] in
                guard let self, let button else { return }
                self.pressed(button)
            }
            button.onHoverChange = { [weak self, weak button] inside in
                guard let self, let button else { return }
                if inside { self.hoverBegan(button) } else { self.hoverEnded(button) }
            }
            view = button
        case .sizeFields:
            let fields = SizeFieldsView()
            for field in [fields.widthField, fields.heightField] {
                field.delegate = self
                field.onFocus = { [weak self] in self?.onEditingBegan?() }
            }
            widthField = fields.widthField
            heightField = fields.heightField
            view = fields
        case .message:
            view = MessageView()
        case .meter:
            view = MeterView()
        case .divider:
            view = DividerView()
        }
        configure(view, with: item)
        return view
    }

    private func configure(_ view: NSView, with item: SelectionToolbarItem) {
        switch item {
        case .button(let button):
            (view as? ToolbarButtonView)?.button = button
        case let .menuButton(id, title, symbol, hoverLabel):
            (view as? ToolbarButtonView)?.button = SelectionToolbarButton(id: id, symbol: symbol, title: title,
                                                                         hoverLabel: hoverLabel)
        case let .sizeFields(width, height):
            widthField?.shownValue = width
            heightField?.shownValue = height
        case let .message(text, isWarning, detail):
            (view as? MessageView)?.show(text, isWarning: isWarning, detail: detail)
        case let .meter(_, level):
            (view as? MeterView)?.level = level
        case .divider:
            break
        }
    }

    private func layoutItems() {
        let height = Self.buttonSide + Self.padding * 2
        var x = Self.padding
        for view in itemViews {
            let size = view.intrinsicContentSize
            view.frame = CGRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + Self.spacing
        }
    }

    // MARK: Buttons and hover labels

    private func pressed(_ button: ToolbarButtonView) {
        // A typed size counts before the button acts on the selection.
        endEditing()
        onAction(.pressed(id: button.button.id))
    }

    private func hoverBegan(_ button: ToolbarButtonView) {
        hoveredButton = button
        showHoverLabel(for: button)
    }

    private func hoverEnded(_ button: ToolbarButtonView) {
        guard hoveredButton === button else { return }
        hoveredButton = nil
        hoverLabel.hide()
    }

    /// The label 4 pt over the toolbar, or under it when the toolbar sits above the selection, centred on the button.
    private func showHoverLabel(for button: ToolbarButtonView) {
        guard showsHoverLabels, let window = panel.parent, let anchor else { return }
        let buttonFrame = panel.convertToScreen(button.convert(button.bounds, to: nil))
        hoverLabel.show(button.button.hoverLabel, over: buttonFrame, toolbar: panel.frame, below: side == .above,
                        visibleFrame: anchor.visibleFrame, attachedTo: window)
    }

    // MARK: Size fields

    /// Return commits and ends editing, Tab commits and moves to the other field, Esc puts the field back and ends
    /// editing. The field editor's Esc arrives as `cancelOperation:`.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? NumberField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            panel.makeFirstResponder(nil)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            panel.makeFirstResponder(field === widthField ? heightField : widthField)
        case #selector(NSResponder.cancelOperation(_:)):
            textView.string = field.shownText
            panel.makeFirstResponder(nil)
        default:
            return false
        }
        return true
    }

    /// An empty or out-of-range value ends editing too; `controlTextDidEndEditing` puts the field back.
    func control(_ control: NSControl, didFailToFormatString string: String, errorDescription error: String?) -> Bool {
        true
    }

    /// Leaving the field (Return, Tab, a click elsewhere) commits a valid new value, only for the side edited; then the
    /// field shows the size the selection got.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NumberField else { return }
        if !isQuiet, let value = (field.objectValue as? NSNumber)?.intValue, value != field.shownValue {
            onAction(field === widthField ? .sizeCommitted(width: value, height: nil)
                                          : .sizeCommitted(width: nil, height: value))
        }
        field.showValue()
        guard !isQuiet else { return }
        // After Tab or a click in the other field, that field is editing once this event is done.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.parent != nil, !self.isEditing else { return }
            self.onAction(.editingEnded)
        }
    }
}

private extension SelectionToolbarItem {
    /// The same kind of item (and the same button id), so its view can be reconfigured instead of rebuilt.
    func hasSameShape(as other: SelectionToolbarItem) -> Bool {
        switch (self, other) {
        case let (.button(a), .button(b)): a.id == b.id
        case let (.menuButton(a, _, _, _), .menuButton(b, _, _, _)): a == b
        case let (.meter(a, _), .meter(b, _)): a == b
        case (.sizeFields, .sizeFields), (.message, .message), (.divider, .divider): true
        default: false
        }
    }
}

// MARK: - Panels and material

/// A borderless, non-activating panel at the overlay's level, shown as a child of the overlay window. With `takesKey` a
/// click in a text field makes it key (`becomesKeyOnlyIfNeeded`), while a click on anything else leaves the keys with
/// the overlay.
final class OverlayChildPanel: NSPanel {
    private let takesKey: Bool
    /// Keys that reach the panel itself (no field edits); returns whether it used the key.
    var onKeyDown: ((NSEvent) -> Bool)?

    init(takesKey: Bool) {
        self.takesKey = takesKey
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { takesKey }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    /// Without an initial first responder AppKit makes the first text field first responder when the panel first goes
    /// on screen, which would start editing a field nobody clicked. The content view never takes it.
    override var contentView: NSView? {
        didSet { initialFirstResponder = contentView }
    }

    /// Shows the panel at `frame` as a child of `window`, moving it from another window if it was one's child.
    func attach(to window: NSWindow, frame: CGRect) {
        let resized = frame.size != self.frame.size
        if frame != self.frame { setFrame(frame, display: isVisible) }
        if parent !== window {
            parent?.removeChildWindow(self)
            collectionBehavior = window.collectionBehavior
            window.addChildWindow(self, ordered: .above)
        }
        if !isVisible { orderFrontRegardless() }
        if resized, hasShadow { invalidateShadow() }
    }

    /// Hides the panel and stops it being a child.
    func detach() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// The selection toolbar's look: HUD material that stays dark in light mode, in a capsule (`cornerRadius` nil) or a
/// rounded rectangle. It shows the arrow cursor while the pointer is over it, as the overlay below sets its own.
final class OverlayMaterialView: NSVisualEffectView {
    private let cornerRadius: CGFloat?
    var onPointerInside: (() -> Void)?

    init(cornerRadius: CGFloat?) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = cornerRadius ?? bounds.height / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways,
                                                              .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onPointerInside?() }
    override func mouseMoved(with event: NSEvent) { onPointerInside?() }
}

// MARK: - Item views

/// A toolbar button: a white 15 pt symbol (and an optional title) on the dark capsule, with hover, press, on and
/// prominent states drawn behind it. It never makes its panel key. ⌃-click, which AppKit sends as a secondary click,
/// presses it like any click (⌃ on the Area button adds Copy).
private final class ToolbarButtonView: NSView {
    var onPress: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var button = SelectionToolbarButton(id: "", symbol: "circle", hoverLabel: "") {
        didSet { if button != oldValue { apply() } }
    }

    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { updateBackground() } }
    private var isPressed = false { didSet { updateBackground() } }
    private var isControlClick = false
    private static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        imageView.contentTintColor = .white
        imageView.imageScaling = .scaleNone
        titleField.textColor = .white
        titleField.font = .preferredFont(forTextStyle: .body)
        addSubview(imageView)
        addSubview(titleField)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        let side = SelectionToolbar.buttonSide
        guard button.title != nil else { return NSSize(width: side, height: side) }
        let width = 8 + imageView.intrinsicContentSize.width + 4 + titleField.intrinsicContentSize.width + 8
        return NSSize(width: ceil(max(width, side)), height: side)
    }

    /// The pointer left without the button hearing it (the toolbar moved or hid).
    func endHover() {
        isHovered = false
        isPressed = false
    }

    /// The pointer is over the button now, whatever the last tracking event said.
    var containsPointer: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func layout() {
        super.layout()
        let image = imageView.intrinsicContentSize
        if button.title == nil {
            imageView.frame = CGRect(x: ((bounds.width - image.width) / 2).rounded(),
                                     y: ((bounds.height - image.height) / 2).rounded(), width: image.width,
                                     height: image.height)
        } else {
            imageView.frame = CGRect(x: 8, y: ((bounds.height - image.height) / 2).rounded(), width: image.width,
                                     height: image.height)
            // The title reaches into the trailing padding a little, so its last glyph is never clipped.
            let title = titleField.intrinsicContentSize
            let titleX = imageView.frame.maxX + 4
            titleField.frame = CGRect(x: titleX, y: ((bounds.height - title.height) / 2).rounded(),
                                      width: max(bounds.maxX - 6 - titleX, title.width), height: title.height)
        }
    }

    private func apply() {
        imageView.image = NSImage(systemSymbolName: button.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(Self.symbolConfiguration)
        titleField.stringValue = button.title ?? ""
        titleField.isHidden = button.title == nil
        alphaValue = button.isEnabled ? 1 : 0.35
        setAccessibilityLabel(button.hoverLabel)
        invalidateIntrinsicContentSize()
        needsLayout = true
        updateBackground()
    }

    private func updateBackground() {
        let color: NSColor
        if button.isProminent {
            let accent = NSColor.controlAccentColor
            color = isPressed ? accent.withSystemEffect(.pressed) : isHovered ? accent.withSystemEffect(.rollover) : accent
        } else if isPressed {
            color = .white.withAlphaComponent(0.25)
        } else if button.isOn {
            color = .white.withAlphaComponent(0.2)
        } else if isHovered {
            color = .white.withAlphaComponent(0.12)
        } else {
            color = .clear
        }
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard button.isEnabled else { return }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard button.isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        isControlClick = false
        guard button.isEnabled, wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func rightMouseDown(with event: NSEvent) {
        isControlClick = event.type == .leftMouseDown || (event.modifierFlags.contains(.control) && event.buttonNumber == 0)
        if isControlClick { mouseDown(with: event) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if isControlClick { mouseDragged(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isControlClick else { return }
        isControlClick = false
        mouseUp(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard button.isEnabled else { return false }
        onPress?()
        return true
    }
}

/// W and H fields with "×" between them.
private final class SizeFieldsView: NSView {
    static let fieldWidth: CGFloat = 52
    let widthField = NumberField(range: 4...99_999, width: SizeFieldsView.fieldWidth)
    let heightField = NumberField(range: 4...99_999, width: SizeFieldsView.fieldWidth)
    private let times = NSTextField(labelWithString: "×")

    init() {
        super.init(frame: .zero)
        times.textColor = .secondaryLabelColor
        times.font = .preferredFont(forTextStyle: .body)
        widthField.setAccessibilityLabel("Width")
        heightField.setAccessibilityLabel("Height")
        [widthField, times, heightField].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        let spacing = SelectionToolbar.spacing
        return NSSize(width: Self.fieldWidth * 2 + times.intrinsicContentSize.width + spacing * 2,
                      height: SelectionToolbar.buttonSide)
    }

    override func layout() {
        super.layout()
        let spacing = SelectionToolbar.spacing
        let field = widthField.intrinsicContentSize
        let fieldY = ((bounds.height - field.height) / 2).rounded()
        widthField.frame = CGRect(x: 0, y: fieldY, width: Self.fieldWidth, height: field.height)
        let times = self.times.intrinsicContentSize
        self.times.frame = CGRect(x: widthField.frame.maxX + spacing, y: ((bounds.height - times.height) / 2).rounded(),
                                  width: times.width, height: times.height)
        heightField.frame = CGRect(x: self.times.frame.maxX + spacing, y: fieldY, width: Self.fieldWidth,
                                   height: field.height)
    }
}

/// A line of text in the toolbar: monospaced digits, yellow for a warning; with a detail, a second, smaller line under
/// it, the two centred together.
private final class MessageView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        let body = NSFont.preferredFont(forTextStyle: .body)
        label.font = .monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular)
        detailLabel.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isHidden = true
        addSubview(label)
        addSubview(detailLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ text: String, isWarning: Bool, detail: String?) {
        label.stringValue = text
        label.textColor = isWarning ? .systemYellow : .white
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let width = max(label.intrinsicContentSize.width, detailLabel.isHidden ? 0 : detailLabel.intrinsicContentSize.width)
        let lines = label.intrinsicContentSize.height + (detailLabel.isHidden ? 0 : detailLabel.intrinsicContentSize.height)
        return NSSize(width: ceil(width) + SelectionToolbar.padding * 2, height: max(SelectionToolbar.buttonSide, ceil(lines)))
    }

    override func layout() {
        super.layout()
        // The labels reach into the trailing padding a little, so their last glyphs are never clipped.
        let width = bounds.width - SelectionToolbar.padding - 6
        let size = label.intrinsicContentSize
        guard !detailLabel.isHidden else {
            label.frame = CGRect(x: SelectionToolbar.padding, y: ((bounds.height - size.height) / 2).rounded(),
                                 width: width, height: size.height)
            return
        }
        let detailSize = detailLabel.intrinsicContentSize
        let bottom = ((bounds.height - size.height - detailSize.height) / 2).rounded()
        detailLabel.frame = CGRect(x: SelectionToolbar.padding, y: bottom, width: width, height: detailSize.height)
        label.frame = CGRect(x: SelectionToolbar.padding, y: bottom + detailSize.height, width: width, height: size.height)
    }
}

/// A level meter, 4 × 18 pt: a dim track filled from the bottom up to the level, green at −60 dB turning red at 0 dB,
/// so the top of the fill shows how loud it is.
private final class MeterView: NSView {
    var level = 0.0 {
        didSet {
            guard level != oldValue else { return }
            setAccessibilityValue(Int((level * 100).rounded()))
            needsDisplay = true
        }
    }

    private static let gradient = NSGradient(colors: [.systemGreen, .systemGreen, .systemYellow, .systemRed])

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Microphone level")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 4, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        NSColor.white.withAlphaComponent(0.2).setFill()
        track.fill()
        let filled = (bounds.height * min(max(level, 0), 1)).rounded()
        guard filled > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: filled).clip()
        Self.gradient?.draw(in: bounds, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A 1 pt separator-coloured line between groups of items.
final class DividerView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

// MARK: - Number fields

/// A small field for a whole number in `range`: digits only, monospaced, centred, its text selected when a click starts
/// editing. `shownValue` is what it shows while not being edited; editing that ends without a valid new value goes back
/// to it.
final class NumberField: NSTextField {
    var shownValue: Int? {
        didSet { if currentEditor() == nil { showValue() } }
    }
    /// A click or Tab started editing it.
    var onFocus: (() -> Void)?

    init(range: ClosedRange<Int>, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        formatter = DigitsFormatter(range: range)
        let body = NSFont.preferredFont(forTextStyle: .body)
        font = .monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular)
        alignment = .center
        bezelStyle = .roundedBezel
        isBezeled = true
        lineBreakMode = .byClipping
        usesSingleLineMode = true
        cell?.isScrollable = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var shownText: String {
        shownValue.map(String.init) ?? ""
    }

    /// What is typed now, nil when it is empty or outside the range.
    var typedValue: Int? {
        let text = currentEditor()?.string ?? stringValue
        return (formatter as? NumberFormatter)?.number(from: text)?.intValue
    }

    func showValue() {
        stringValue = shownText
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    /// The panel is non-activating: without this the first click would only make it key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let wasEditing = currentEditor() != nil
        super.mouseDown(with: event)
        // The field editor tracks the click until the mouse-up; then the whole value is selected, ready to retype.
        if !wasEditing { currentEditor()?.selectAll(nil) }
    }
}

/// Accepts only digits, at most as many as the range's upper bound has, and parses whole numbers in the range. It is
/// never changed after `init`; `NumberFormatter` is `@unchecked Sendable`, which a subclass has to restate.
private nonisolated final class DigitsFormatter: NumberFormatter, @unchecked Sendable {
    private let maximumDigits: Int

    init(range: ClosedRange<Int>) {
        maximumDigits = String(range.upperBound).count
        super.init()
        numberStyle = .none
        allowsFloats = false
        usesGroupingSeparator = false
        minimum = NSNumber(value: range.lowerBound)
        maximum = NSNumber(value: range.upperBound)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func isPartialStringValid(_ partialString: String,
                                       newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                       errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        partialString.count <= maximumDigits && partialString.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

// MARK: - Hover label

/// A button's label over the toolbar: a small dark capsule with white caption text (the overlay labels' look), in a
/// child panel of the overlay that ignores the mouse.
private final class HoverLabel {
    private let panel = OverlayChildPanel(takesKey: false)
    private let background = NSView()
    private let label = NSTextField(labelWithString: "")
    private static let gap: CGFloat = 4

    init() {
        panel.ignoresMouseEvents = true
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        background.layer?.cornerCurve = .continuous
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .white
        background.addSubview(label)
        panel.contentView = background
    }

    /// Shows `text` centred on `button`, 4 pt over `toolbar` (under it when `below`), within `visibleFrame`.
    func show(_ text: String, over button: CGRect, toolbar: CGRect, below: Bool, visibleFrame: CGRect,
              attachedTo window: NSWindow) {
        label.stringValue = text
        let textSize = label.intrinsicContentSize
        let size = CGSize(width: ceil(textSize.width) + 16, height: ceil(textSize.height) + 8)
        let margin = ToolbarPlacement.margin
        let x = min(max(button.midX - size.width / 2, visibleFrame.minX + margin), visibleFrame.maxX - margin - size.width)
        let y = below ? toolbar.minY - Self.gap - size.height : toolbar.maxY + Self.gap
        let frame = CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
        label.frame = CGRect(x: 8, y: 4, width: size.width - 14, height: ceil(textSize.height))
        background.layer?.cornerRadius = size.height / 2
        panel.attach(to: window, frame: frame)
    }

    func hide() {
        panel.detach()
    }
}
