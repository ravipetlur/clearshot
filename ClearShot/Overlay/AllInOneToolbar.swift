import AppKit
import CSCapture
import CSCore

enum AllInOneToolbarAction: Equatable {
    case button(AllInOneButton)
    /// A typed size: only the side that was edited.
    case size(width: Int?, height: Int?)
    case ratio(SelectionRatio)
    case toggleFullscreen
    /// No field edits any more, so the overlay can take the keys back.
    case editingEnded
}

/// All-In-One's toolbar: the seven mode buttons, W × H, the aspect ratio and Toggle fullscreen on a `SelectionToolbar`,
/// and the ratio list the ratio button opens.
final class AllInOneToolbar {
    private static let ratioID = "ratio"
    private static let toggleFullscreenID = "toggleFullscreen"

    private let onAction: (AllInOneToolbarAction) -> Void
    private lazy var toolbar = SelectionToolbar { [weak self] action in self?.toolbarAction(action) }
    private lazy var ratioList = RatioList { [weak self] action in self?.ratioListAction(action) }

    init(onAction: @escaping (AllInOneToolbarAction) -> Void) {
        self.onAction = onAction
        // A size field taking the keys closes the list; the overlay doesn't take them back.
        toolbar.onEditingBegan = { [weak self] in
            guard let self, self.ratioList.isOpen else { return }
            self.ratioList.close(reportingEditingEnded: false)
            self.toolbar.showsHoverLabels = true
        }
    }

    /// Shows the controller's selection size, ratio and fullscreen state.
    func update(for controller: AllInOneController) {
        let size = controller.selection.rect?.size ?? .zero
        let ratio = controller.ratio
        let isFullscreen = controller.isFullscreenSelection
        var items = AllInOneButton.allCases.map { button in
            SelectionToolbarItem.button(SelectionToolbarButton(id: Self.id(of: button), symbol: button.symbolName,
                                                               hoverLabel: button.hoverLabel))
        }
        items += [
            .divider,
            .sizeFields(width: Int(size.width.rounded()), height: Int(size.height.rounded())),
            .menuButton(id: Self.ratioID, title: ratio == .freeform ? nil : ratio.title, symbol: "aspectratio",
                        hoverLabel: "Aspect ratio"),
            .button(SelectionToolbarButton(id: Self.toggleFullscreenID,
                                           symbol: isFullscreen ? "arrow.down.right.and.arrow.up.left"
                                                                : "arrow.up.left.and.arrow.down.right",
                                           hoverLabel: "Toggle fullscreen", isOn: isFullscreen)),
        ]
        toolbar.update(items)
        ratioList.current = ratio
    }

    /// Places the toolbar for `selection` on the overlay `window` of its display, and the ratio list with it if open.
    func show(attachedTo window: NSWindow, selection: CGRect, visibleFrame: CGRect) {
        toolbar.show(attachedTo: window, anchoredTo: selection, visibleFrame: visibleFrame)
        if ratioList.isOpen { placeRatioList() }
    }

    /// Hides the toolbar, its hover label and the ratio list, ending any editing without reporting it.
    func hide() {
        ratioList.close(reportingEditingEnded: false)
        toolbar.showsHoverLabels = true
        toolbar.hide()
    }

    /// A size field or a custom-ratio field is being edited (the toolbar or the list then has the keys).
    var isEditing: Bool {
        toolbar.isEditing || ratioList.isEditing
    }

    /// The point is over the toolbar or the ratio list.
    func contains(_ point: CGPoint) -> Bool {
        toolbar.frame.contains(point) || ratioList.frame.contains(point)
    }

    /// A click on the overlay: ends editing in a size field (committing a typed size) and closes the ratio list. Returns
    /// whether either was under way, in which case the click does nothing else.
    @discardableResult
    func endInteraction() -> Bool {
        let wasEditing = toolbar.isEditing
        toolbar.endEditing()
        let closedList = closeRatioList()
        return wasEditing || closedList
    }

    /// Closes the ratio list (Esc, a click outside it). Returns whether it was open.
    @discardableResult
    func closeRatioList() -> Bool {
        guard ratioList.isOpen else { return false }
        ratioList.close(reportingEditingEnded: true)
        toolbar.showsHoverLabels = true
        return true
    }

    // MARK: Actions

    private static func id(of button: AllInOneButton) -> String {
        "mode.\(button)"
    }

    private func toolbarAction(_ action: SelectionToolbarAction) {
        switch action {
        case .pressed(id: Self.ratioID):
            if !closeRatioList() { openRatioList() }
        case .pressed(let id):
            closeRatioList()
            if id == Self.toggleFullscreenID {
                onAction(.toggleFullscreen)
            } else if let button = AllInOneButton.allCases.first(where: { Self.id(of: $0) == id }) {
                onAction(.button(button))
            }
        case let .sizeCommitted(width, height):
            onAction(.size(width: width, height: height))
        case .editingEnded:
            if !isEditing { onAction(.editingEnded) }
        }
    }

    private func ratioListAction(_ action: RatioList.Action) {
        switch action {
        case .choose(let ratio):
            closeRatioList()
            onAction(.ratio(ratio))
        case .editingEnded:
            if !isEditing { onAction(.editingEnded) }
        }
    }

    // MARK: Ratio list

    private func openRatioList() {
        toolbar.showsHoverLabels = false
        placeRatioList()
    }

    private func placeRatioList() {
        guard let button = toolbar.screenFrame(ofItem: Self.ratioID) else {
            closeRatioList()
            return
        }
        ratioList.show(under: button, toolbar: toolbar)
    }
}

/// The aspect-ratio list on an `OverlayListPanel`: Freeform, the presets, Custom W:H and Swap, with the current ratio
/// checked. A click on a row chooses it; Return in a Custom field applies the two fields; Esc in one closes the list.
/// All-In-One's toolbar and a recording's Ready toolbar each have one.
final class RatioList: NSObject, NSTextFieldDelegate {
    enum Action {
        case choose(SelectionRatio)
        /// A Custom field stopped editing because the list closed, so the overlay can take the keys back.
        case editingEnded
    }

    private static let customID = "custom"
    private static let swapID = "swap"
    private static let choices = [SelectionRatio.freeform] + SelectionRatio.presets

    private let onAction: (Action) -> Void
    private lazy var panel = OverlayListPanel { [weak self] id in self?.chose(id) }
    private let customWidth = RatioList.makeCustomField(placeholder: "W", label: "Custom ratio width")
    private let customHeight = RatioList.makeCustomField(placeholder: "H", label: "Custom ratio height")
    private var customFields: NSView!

    var current: SelectionRatio = .freeform {
        didSet { if current != oldValue { showRows() } }
    }

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        super.init()
        customWidth.delegate = self
        customHeight.delegate = self
        customFields = makeCustomFields()
        panel.onEditingEnded = { [weak self] in self?.onAction(.editingEnded) }
        showRows()
    }

    var isOpen: Bool {
        panel.isOpen
    }

    var isEditing: Bool {
        customWidth.currentEditor() != nil || customHeight.currentEditor() != nil
    }

    var frame: CGRect {
        panel.frame
    }

    /// Under (or over) `toolbar`, centred on the ratio button at `button` (`OverlayListPanel.show(under:toolbar:)`).
    func show(under button: CGRect, toolbar: SelectionToolbar) {
        panel.show(under: button, toolbar: toolbar)
    }

    /// Closes the list. A Custom field being edited stops without applying; with `reportingEditingEnded` the list then
    /// says so, so the overlay takes the keys back.
    func close(reportingEditingEnded: Bool) {
        panel.close(reportingEditingEnded: reportingEditingEnded)
    }

    // MARK: Rows

    private func showRows() {
        var rows = Self.choices.enumerated().map { index, ratio in
            OverlayListPanel.Row(id: "ratio.\(index)", title: ratio.title, isChecked: ratio == current)
        }
        var isCustom = false
        if case let .custom(width, height) = current {
            isCustom = true
            customWidth.shownValue = width
            customHeight.shownValue = height
        }
        rows.append(OverlayListPanel.Row(id: Self.customID, title: "Custom", isChecked: isCustom, accessory: customFields))
        rows.append(.divider(id: "divider"))
        rows.append(OverlayListPanel.Row(id: Self.swapID, title: "Swap", symbol: "arrow.left.arrow.right",
                                         isEnabled: current != .freeform))
        panel.update(rows)
    }

    private func chose(_ id: String) {
        switch id {
        case Self.customID:
            applyCustom()
        case Self.swapID:
            guard current != .freeform else { return }
            onAction(.choose(current.swapped()))
        default:
            guard let index = Int(id.dropFirst("ratio.".count)), Self.choices.indices.contains(index) else { return }
            onAction(.choose(Self.choices[index]))
        }
    }

    private static func makeCustomField(placeholder: String, label: String) -> NumberField {
        let field = NumberField(range: 1...100, width: 36)
        field.controlSize = .small
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        field.placeholderString = placeholder
        field.setAccessibilityLabel(label)
        return field
    }

    private func makeCustomFields() -> NSView {
        let colon = NSTextField(labelWithString: ":")
        colon.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [customWidth, colon, customHeight])
        stack.orientation = .horizontal
        stack.spacing = 4
        customWidth.widthAnchor.constraint(equalToConstant: 36).isActive = true
        customHeight.widthAnchor.constraint(equalToConstant: 36).isActive = true
        return stack
    }

    /// Return in a Custom field, or a click on the row: chooses W:H when both fields hold 1…100, otherwise puts the
    /// first field that doesn't up for typing.
    private func applyCustom() {
        guard let width = customWidth.typedValue, let height = customHeight.typedValue else {
            panel.beginEditing(customWidth.typedValue == nil ? customWidth : customHeight)
            return
        }
        onAction(.choose(.custom(width: width, height: height)))
    }

    // MARK: Custom fields

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            applyCustom()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            panel.moveEditing(to: control === customWidth ? customHeight : customWidth)
        case #selector(NSResponder.cancelOperation(_:)):
            close(reportingEditingEnded: true)
        default:
            return false
        }
        return true
    }

    /// An empty or out-of-range value leaves the field empty.
    func control(_ control: NSControl, didFailToFormatString string: String, errorDescription error: String?) -> Bool {
        true
    }
}
