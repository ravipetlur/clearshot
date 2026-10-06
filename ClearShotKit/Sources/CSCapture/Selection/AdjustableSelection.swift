import CoreGraphics
import CSCore

/// An area selection that stays adjustable after the drag, across every display (All-In-One, scrolling capture).
///
/// It holds one `SelectionController(confirmsOnMouseUp: false)` for the display the latest mouse-down was on. A
/// mouse-down on another display starts a new selection there; the old one is kept until that drag becomes a real
/// selection, so a stray click on another display keeps the selection. Points and rects are AppKit global points.
public struct AdjustableSelection: Sendable {
    /// The display the selection is on; nil with no selection.
    public private(set) var displayID: UInt32?

    private let layout: DisplayLayout?
    private let snapLines: [UInt32: SnapLines]
    private var controller: SelectionController?
    /// The selection a drag on another display would replace, with its display: back if that drag is a stray click.
    private var replaced: (controller: SelectionController, displayID: UInt32)?

    public init(displays: [DisplayInfo], snapLines: [UInt32: SnapLines] = [:], aspectRatio: CGFloat? = nil) {
        layout = displays.isEmpty ? nil : DisplayLayout(displays: displays)
        self.snapLines = snapLines
        self.aspectRatio = aspectRatio
    }

    public var display: DisplayInfo? {
        displayID.flatMap { layout?.display(id: $0) }
    }

    /// The selection's phase, `.idle` with no selection.
    public var phase: SelectionController.Phase {
        controller?.phase ?? .idle
    }

    /// The selected rect: non-empty, in any phase but idle and cancelled.
    public var rect: CGRect? {
        guard let controller, controller.phase != .idle, controller.phase != .cancelled, !controller.rect.isEmpty else {
            return nil
        }
        return controller.rect
    }

    /// A selection exists that is being adjusted or can be: adjusting, moving or resizing, with a rect at least
    /// `SelectionController.minimumSize` on each side. A drag moved with Space counts only once it is that big; moving an
    /// existing selection always does.
    public var isAdjustable: Bool {
        switch phase {
        case .adjusting, .moving, .resizing:
            guard let rect else { return false }
            return rect.width >= SelectionController.minimumSize && rect.height >= SelectionController.minimumSize
        default:
            return false
        }
    }

    /// The modifier keys held as the selection's drag began; `[]` with no selection or one that was set without a drag's.
    public var startModifiers: SelectionModifiers {
        controller?.startModifiers ?? []
    }

    /// Width ÷ height that drags, resizes and typed sizes keep; nil is freeform.
    public var aspectRatio: CGFloat? {
        didSet {
            controller?.aspectRatio = aspectRatio
            replaced?.controller.aspectRatio = aspectRatio
        }
    }

    // MARK: Mouse and keys

    /// A mouse-down on the selection's display, or on one of its handles where it meets the next display, goes to the
    /// selection; one on another display starts a new selection there.
    public mutating func mouseDown(at point: CGPoint, modifiers: SelectionModifiers) {
        if let controller, controller.handle(at: point) != nil {
            self.controller?.mouseDown(at: point, modifiers: modifiers)
            return
        }
        guard let target = layout?.display(containingMouse: point) else { return }
        if let controller, let displayID, displayID != target.id {
            replaced = rect == nil ? nil : (controller, displayID)
            self.controller = nil
        }
        if controller == nil {
            controller = makeController(on: target)
            displayID = target.id
        }
        controller?.mouseDown(at: point, modifiers: modifiers)
    }

    public mutating func mouseDragged(to point: CGPoint, modifiers: SelectionModifiers) {
        controller?.mouseDragged(to: point, modifiers: modifiers)
    }

    public mutating func mouseUp(at point: CGPoint, modifiers: SelectionModifiers) {
        controller?.mouseUp(at: point, modifiers: modifiers)
        defer { replaced = nil }
        guard controller?.phase == .idle else { return }
        // Too small to be a selection: the one it would have replaced stays, or there is none.
        controller = replaced?.controller
        displayID = replaced?.displayID
    }

    /// Space while dragging moves the selection until it is released.
    public mutating func spaceDown(at point: CGPoint) {
        controller?.spaceDown(at: point)
    }

    public mutating func spaceUp(at point: CGPoint) {
        controller?.spaceUp(at: point)
    }

    public mutating func arrow(_ key: ArrowKey, modifiers: SelectionModifiers) {
        controller?.arrow(key, modifiers: modifiers)
    }

    // MARK: Set, typed and fitted

    /// Selects `rect` on display `id`, ready for adjusting: a remembered area or the display frame with no start
    /// modifiers, or a selection dragged out elsewhere with its drag's (see `SelectionController.setRect`). Refused
    /// while the mouse is down, for a display that isn't connected, or for a rect that is less than
    /// `SelectionController.minimumSize` on that display; the current selection then stays.
    @discardableResult
    public mutating func setRect(_ rect: CGRect, onDisplay id: UInt32, startModifiers: SelectionModifiers = []) -> Bool {
        guard phase == .idle || phase == .adjusting, let target = layout?.display(id: id) else { return false }
        var candidate = makeController(on: target)
        guard candidate.setRect(rect, startModifiers: startModifiers) else { return false }
        controller = candidate
        displayID = id
        replaced = nil
        return true
    }

    @discardableResult
    public mutating func setSize(width: CGFloat?, height: CGFloat?) -> Bool {
        controller?.setSize(width: width, height: height) ?? false
    }

    public mutating func fitToAspectRatio() {
        controller?.fitToAspectRatio()
    }

    public func handle(at point: CGPoint) -> SelectionHandle? {
        controller?.handle(at: point)
    }

    private func makeController(on display: DisplayInfo) -> SelectionController {
        var controller = SelectionController(bounds: display.frame, confirmsOnMouseUp: false,
                                             snapLines: snapLines[display.id] ?? SnapLines())
        controller.aspectRatio = aspectRatio
        return controller
    }
}
