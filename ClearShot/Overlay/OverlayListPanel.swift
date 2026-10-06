import AppKit
import CSCore

/// A list that opens from a selection toolbar's button: rows in a panel at the overlay's level, since an `NSMenu` (or
/// an alert) would open under the overlay. Lifted from All-In-One's ratio list: 10 pt corners, a checkmark (or symbol)
/// column, the accent colour under the pointer, dividers, and rows that end in a control of their owner's (the ratio
/// list's Custom fields), which can make the panel key while it is typed in; a click anywhere else leaves the keys with
/// the overlay. Its owner shows it under (or over) the button, and closes it.
final class OverlayListPanel {
    struct Row: Equatable {
        enum Kind: Equatable {
            case item, divider
        }

        let id: String
        let title: String
        /// Shown in the checkmark column instead of a checkmark.
        var symbol: String? = nil
        var isChecked = false
        var isEnabled = true
        /// A second, smaller line under the title: why the row is unavailable, say.
        var detail: String? = nil
        var kind = Kind.item
        /// A control at the row's end (the Custom W:H fields). The row isn't highlighted under the pointer; a click on it
        /// outside the control still chooses it.
        var accessory: NSView? = nil

        static func divider(id: String) -> Row {
            Row(id: id, title: "", kind: .divider)
        }

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.symbol == rhs.symbol && lhs.isChecked == rhs.isChecked
                && lhs.isEnabled == rhs.isEnabled && lhs.detail == rhs.detail && lhs.kind == rhs.kind
                && lhs.accessory === rhs.accessory
        }

        /// The same row apart from its checkmark and whether it is enabled, so its view can be kept.
        func hasSameShape(as other: Row) -> Bool {
            var other = other
            other.isChecked = isChecked
            other.isEnabled = isEnabled
            return self == other
        }
    }

    static let padding: CGFloat = 4
    static let rowHeight: CGFloat = 24
    static let dividerHeight: CGFloat = 9
    /// A row's detail wraps at this width.
    static let detailWidth: CGFloat = 240

    private let onChoose: (String) -> Void
    private let panel = OverlayChildPanel(takesKey: true)
    private let material = OverlayMaterialView(cornerRadius: 10)
    private var rows: [Row] = []
    private var rowViews: [NSView] = []

    /// A control in a row stopped editing because the list closed, so the overlay can take the keys back.
    var onEditingEnded: (() -> Void)?

    /// `onChoose` gets the id of an enabled row clicked (or pressed through accessibility).
    init(onChoose: @escaping (String) -> Void) {
        self.onChoose = onChoose
        panel.hasShadow = true
        panel.contentView = material
        material.onPointerInside = { NSCursor.arrow.set() }
    }

    /// Shows `rows`, top to bottom, keeping the views of rows whose only change is their checkmark or availability.
    func update(_ rows: [Row]) {
        guard rows != self.rows else { return }
        let sameShape = rows.count == self.rows.count && zip(rows, self.rows).allSatisfy { $0.hasSameShape(as: $1) }
        self.rows = rows
        if sameShape {
            for (row, view) in zip(rows, rowViews) {
                guard let view = view as? ListRowView else { continue }
                view.isChecked = row.isChecked
                view.isEnabled = row.isEnabled
            }
        } else {
            rebuild()
        }
    }

    var isOpen: Bool {
        panel.parent != nil
    }

    /// A control in a row is being typed in (the panel has the keys).
    var isEditing: Bool {
        guard isOpen, let editor = panel.firstResponder as? NSTextView else { return false }
        return editor.isFieldEditor
    }

    /// The list's frame in global points; `.zero` while closed.
    var frame: CGRect {
        isOpen ? panel.frame : .zero
    }

    /// Shows the list under `toolbar` and centred on `button` (the toolbar item it opens from, in global points), on the
    /// overlay the toolbar is attached to; over the toolbar instead when that sits above the selection or there is no
    /// room below. Kept within the toolbar's visible frame. Call again to follow the toolbar when it moves.
    func show(under button: CGRect, toolbar: SelectionToolbar) {
        guard let window = toolbar.parentWindow else {
            close()
            return
        }
        let frame = Self.placedFrame(size: size, button: button, toolbar: toolbar.frame, side: toolbar.side,
                                     visibleFrame: toolbar.visibleFrame)
        panel.attach(to: window, frame: frame)
    }

    /// Closes the list. A control being edited stops without applying; with `reportingEditingEnded` the list then says
    /// so (`onEditingEnded`), so the overlay takes the keys back.
    func close(reportingEditingEnded: Bool = true) {
        guard isOpen else { return }
        let wasEditing = isEditing
        if wasEditing { panel.makeFirstResponder(nil) }
        // A hidden panel gets no mouse-exited events: forget the highlight.
        rowViews.forEach { ($0 as? ListRowView)?.endHover() }
        panel.detach()
        if wasEditing, reportingEditingEnded { onEditingEnded?() }
    }

    /// Puts `control` (in a row's accessory) up for typing: the panel becomes key without activating ClearShot.
    func beginEditing(_ control: NSView) {
        guard isOpen else { return }
        panel.makeKey()
        panel.makeFirstResponder(control)
    }

    /// Makes `control` (in a row's accessory) the one typed in next, as Tab does.
    func moveEditing(to control: NSView) {
        panel.makeFirstResponder(control)
    }

    // MARK: Layout

    private func rebuild() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = rows.map { row -> NSView in
            guard row.kind == .item else { return DividerView() }
            let view = ListRowView(row: row)
            let id = row.id
            view.onClick = { [weak self] in self?.onChoose(id) }
            return view
        }
        rowViews.forEach(material.addSubview)
        layoutRows()
    }

    private var size: CGSize {
        let width = rowViews.compactMap { ($0 as? ListRowView)?.intrinsicContentSize.width }.max() ?? 0
        let height = rowViews.map(Self.height(of:)).reduce(0, +)
        return CGSize(width: ceil(width + Self.padding * 2), height: ceil(height + Self.padding * 2))
    }

    private static func height(of view: NSView) -> CGFloat {
        (view as? ListRowView)?.rowHeight ?? dividerHeight
    }

    private func layoutRows() {
        let size = self.size
        let rowWidth = size.width - Self.padding * 2
        var top = size.height - Self.padding
        for view in rowViews {
            let height = Self.height(of: view)
            top -= height
            if view is DividerView {
                view.frame = CGRect(x: Self.padding + 8, y: top + 4, width: rowWidth - 16, height: 1)
            } else {
                view.frame = CGRect(x: Self.padding, y: top, width: rowWidth, height: height)
            }
        }
        if isOpen {
            // The rows changed while the list is up: grow or shrink it from its top edge.
            var frame = panel.frame
            frame.origin.y = frame.maxY - size.height
            frame.size = size
            panel.setFrame(frame, display: true)
        }
    }

    /// Under the toolbar and centred on the button; over it instead when the toolbar sits above the selection or there
    /// is no room below. Kept within the visible frame.
    private static func placedFrame(size: CGSize, button: CGRect, toolbar: CGRect, side: ToolbarPlacement.Side,
                                    visibleFrame: CGRect) -> CGRect {
        let gap = SelectionToolbar.spacing
        let margin = ToolbarPlacement.margin
        let below = toolbar.minY - gap - size.height
        let above = toolbar.maxY + gap
        let fitsBelow = below >= visibleFrame.minY + margin
        let fitsAbove = above + size.height <= visibleFrame.maxY - margin
        let goesAbove = side == .above ? fitsAbove || !fitsBelow : fitsAbove && !fitsBelow
        let y = min(max(goesAbove ? above : below, visibleFrame.minY + margin), visibleFrame.maxY - margin - size.height)
        let x = min(max(button.midX - size.width / 2, visibleFrame.minX + margin), visibleFrame.maxX - margin - size.width)
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }
}

/// One row of an overlay list: a checkmark (or a symbol) column, a title, an optional detail line under it and an
/// optional accessory at the end, highlighted with the accent colour under the pointer when it is enabled and has no
/// accessory.
private final class ListRowView: NSView {
    var onClick: (() -> Void)?
    var isChecked: Bool {
        didSet { markView.isHidden = symbol == nil && !isChecked }
    }
    var isEnabled: Bool {
        didSet {
            markView.alphaValue = isEnabled ? 1 : 0.35
            titleField.alphaValue = isEnabled ? 1 : 0.35
            updateBackground()
        }
    }

    private let symbol: String?
    private let markView = NSImageView()
    private let titleField: NSTextField
    private let detailField: NSTextField?
    private let accessory: NSView?
    private var isHovered = false {
        didSet { updateBackground() }
    }
    private static let markWidth: CGFloat = 16
    private static let detailGap: CGFloat = 1

    init(row: OverlayListPanel.Row) {
        symbol = row.symbol
        accessory = row.accessory
        isChecked = row.isChecked
        isEnabled = row.isEnabled
        titleField = NSTextField(labelWithString: row.title)
        detailField = row.detail.map(NSTextField.init(wrappingLabelWithString:))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        markView.image = NSImage(systemSymbolName: row.symbol ?? "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        markView.contentTintColor = .white
        markView.imageScaling = .scaleNone
        markView.isHidden = symbol == nil && !isChecked
        titleField.textColor = .white
        titleField.font = .preferredFont(forTextStyle: .body)
        [markView, titleField].forEach(addSubview)
        if let detailField {
            detailField.font = .preferredFont(forTextStyle: .caption1)
            detailField.textColor = .secondaryLabelColor
            detailField.preferredMaxLayoutWidth = OverlayListPanel.detailWidth
            addSubview(detailField)
        }
        if let accessory { addSubview(accessory) }
        markView.alphaValue = isEnabled ? 1 : 0.35
        titleField.alphaValue = isEnabled ? 1 : 0.35
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.title)
        if let detail = row.detail { setAccessibilityHelp(detail) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The title's line, plus the detail's lines under it.
    var rowHeight: CGFloat {
        guard let detailField else { return OverlayListPanel.rowHeight }
        return OverlayListPanel.rowHeight + Self.detailGap + ceil(detailField.fittingSize.height) + 4
    }

    override var intrinsicContentSize: NSSize {
        let textX = 8 + Self.markWidth + 4
        var width = textX + titleField.intrinsicContentSize.width + 8
        if let accessory { width += 12 + accessory.fittingSize.width }
        if let detailField { width = max(width, textX + ceil(detailField.fittingSize.width) + 8) }
        return NSSize(width: ceil(width), height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        // The title's line is the top `rowHeight` of the row; the detail goes under it.
        let lineY = bounds.maxY - OverlayListPanel.rowHeight
        let mark = markView.intrinsicContentSize
        markView.frame = CGRect(x: 8 + ((Self.markWidth - mark.width) / 2).rounded(),
                                y: lineY + ((OverlayListPanel.rowHeight - mark.height) / 2).rounded(), width: mark.width,
                                height: mark.height)
        var titleEnd = bounds.maxX - 8
        if let accessory {
            let size = accessory.fittingSize
            accessory.frame = CGRect(x: bounds.maxX - 8 - size.width,
                                     y: lineY + ((OverlayListPanel.rowHeight - size.height) / 2).rounded(),
                                     width: size.width, height: size.height)
            titleEnd = accessory.frame.minX - 8
        }
        // The title has the rest of the line, so its last glyph is never clipped.
        let textX = 8 + Self.markWidth + 4
        let title = titleField.intrinsicContentSize
        titleField.frame = CGRect(x: textX, y: lineY + ((OverlayListPanel.rowHeight - title.height) / 2).rounded(),
                                  width: max(titleEnd - textX, ceil(title.width)), height: title.height)
        if let detailField {
            let size = detailField.fittingSize
            detailField.frame = CGRect(x: textX, y: lineY - Self.detailGap - ceil(size.height),
                                       width: ceil(size.width), height: ceil(size.height))
        }
    }

    private func updateBackground() {
        let color: NSColor = isHovered && isEnabled && accessory == nil ? .controlAccentColor : .clear
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    func endHover() {
        isHovered = false
    }

    /// Taken here, so the mouse-up comes here too.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }
}
