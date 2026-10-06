import CoreGraphics
import CSCore

/// What All-In-One runs.
public enum AllInOneCommand: String, CaseIterable, Sendable {
    case captureArea, captureAndCopy, fullscreen, selfTimer, text, scrolling, record

    public var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureAndCopy: "Capture Area & Copy"
        case .fullscreen: "Capture Fullscreen"
        case .selfTimer: "Self-Timer"
        case .text: "Capture Text"
        case .scrolling: "Scrolling Capture"
        case .record: "Record Screen"
        }
    }

    /// Whether running it on the area saves that area for the next All-In-One (`allInOneLastArea`).
    public var remembersArea: Bool { self != .fullscreen }

    /// Whether running it on the area also sets Capture Previous Area's area (`lastCaptureArea`).
    public var updatesLastCaptureArea: Bool {
        switch self {
        case .captureArea, .captureAndCopy, .selfTimer: true
        default: false
        }
    }
}

/// The mode buttons of All-In-One's toolbar, in order.
public enum AllInOneButton: CaseIterable, Sendable {
    case area, fullscreen, window, scrolling, selfTimer, text, record

    public var hoverLabel: String {
        switch self {
        case .area: "Capture Area (A)"
        case .fullscreen: "Capture Fullscreen (F)"
        case .window: "Capture Window (Space/W)"
        case .scrolling: "Scrolling Capture (S)"
        case .selfTimer: "Self-Timer (T)"
        case .text: "Capture Text (O)"
        case .record: "Record Screen (R)"
        }
    }

    /// The matching `ClearShotAction`'s symbol.
    public var symbolName: String {
        switch self {
        case .area: "rectangle.dashed"
        case .fullscreen: "display"
        case .window: "macwindow"
        case .scrolling: "arrow.up.and.down.text.horizontal"
        case .selfTimer: "timer"
        case .text: "text.viewfinder"
        case .record: "record.circle"
        }
    }

    /// The key that does the same.
    var key: AllInOneKey {
        switch self {
        case .area: .character("a")
        case .fullscreen: .character("f")
        case .window: .character("w")
        case .scrolling: .character("s")
        case .selfTimer: .character("t")
        case .text: .character("o")
        case .record: .character("r")
        }
    }
}

/// A key press as All-In-One reads it. Letters are `charactersIgnoringModifiers`, so they follow the keyboard layout.
public enum AllInOneKey: Equatable, Sendable {
    case character(String), escape, returnKey, space, arrow(ArrowKey), other
}

public enum AllInOneKeyResult: Equatable, Sendable {
    /// Close the overlay and run the command.
    case run(AllInOneCommand)
    case cancel
    /// The mode or the selection changed: redraw.
    case changed
    case ignored
}

/// All-In-One's rules: area or window mode, the adjustable selection, its ratio and the fullscreen toggle, and which
/// key or button runs what.
public struct AllInOneController: Sendable {
    public enum Mode: Sendable, Equatable {
        case area, window
    }

    public private(set) var mode: Mode = .area
    /// The area selection. Window mode keeps it, hidden.
    public private(set) var selection: AdjustableSelection
    public private(set) var ratio: SelectionRatio

    private let layout: DisplayLayout?
    /// Toggle fullscreen, with the selection it replaced with the display frame, to bring back on the next toggle.
    private var fullscreen = FullscreenToggle()

    public init(displays: [DisplayInfo], snapLines: [UInt32: SnapLines] = [:], ratio: SelectionRatio = .freeform) {
        layout = displays.isEmpty ? nil : DisplayLayout(displays: displays)
        selection = AdjustableSelection(displays: displays, snapLines: snapLines, aspectRatio: ratio.aspect)
        self.ratio = ratio
    }

    /// In area mode with an adjustable selection (`AdjustableSelection.isAdjustable`): what A, Return, T, O and S need.
    public var hasSelection: Bool {
        mode == .area && selection.isAdjustable
    }

    /// The selection fills its display.
    public var isFullscreenSelection: Bool {
        guard let rect = selection.rect, let display = selection.display else { return false }
        return rect == display.frame
    }

    /// Selects a remembered area when it still resolves on a connected display (`SavedArea.resolved`), fitted to the
    /// ratio.
    @discardableResult
    public mutating func restore(_ area: SavedArea) -> Bool {
        guard let layout, let resolved = area.resolved(in: layout),
              selection.setRect(resolved.rect, onDisplay: resolved.display.id) else { return false }
        selection.fitToAspectRatio()
        return true
    }

    // MARK: Mouse: area mode only (in window mode the app's click captures the hovered window)

    public mutating func mouseDown(at point: CGPoint, modifiers: SelectionModifiers) {
        guard mode == .area else { return }
        selection.mouseDown(at: point, modifiers: modifiers)
    }

    public mutating func mouseDragged(to point: CGPoint, modifiers: SelectionModifiers) {
        guard mode == .area else { return }
        selection.mouseDragged(to: point, modifiers: modifiers)
    }

    public mutating func mouseUp(at point: CGPoint, modifiers: SelectionModifiers) {
        guard mode == .area else { return }
        selection.mouseUp(at: point, modifiers: modifiers)
    }

    // MARK: Keys and buttons

    /// What a key press does. `point` is the pointer, for Space while dragging.
    public mutating func key(_ key: AllInOneKey, modifiers: SelectionModifiers, at point: CGPoint) -> AllInOneKeyResult {
        switch key {
        case .escape:
            return .cancel
        case .returnKey:
            return hasSelection ? .run(.captureArea) : .ignored
        case .space:
            if selection.phase == .dragging {
                selection.spaceDown(at: point)
                return .ignored
            }
            return toggleMode()
        case .arrow(let arrow):
            guard mode == .area, selection.phase == .adjusting else { return .ignored }
            selection.arrow(arrow, modifiers: modifiers)
            return .changed
        case .character(let characters):
            return letter(characters.lowercased(), modifiers: modifiers)
        case .other:
            return .ignored
        }
    }

    public mutating func keyUp(_ key: AllInOneKey, at point: CGPoint) {
        if key == .space { selection.spaceUp(at: point) }
    }

    /// A toolbar button does what its key does.
    public mutating func press(_ button: AllInOneButton) -> AllInOneKeyResult {
        key(button.key, modifiers: [], at: .zero)
    }

    private mutating func letter(_ letter: String, modifiers: SelectionModifiers) -> AllInOneKeyResult {
        if modifiers.contains(.command) {
            // ⌘C copies the selection, or in window mode the hovered window; no other ⌘ letter is All-In-One's.
            guard letter == "c", modifiers.isDisjoint(with: [.control, .option]) else { return .ignored }
            return hasSelection || mode == .window ? .run(.captureAndCopy) : .ignored
        }
        switch letter {
        case "a": return hasSelection ? .run(.captureArea) : .ignored
        case "f": return .run(.fullscreen)
        case "w": return toggleMode()
        case "t": return hasSelection ? .run(.selfTimer) : .ignored
        case "o": return hasSelection ? .run(.text) : .ignored
        case "s": return hasSelection ? .run(.scrolling) : .ignored
        case "r": return .run(.record)
        default: return .ignored
        }
    }

    /// Area ⇄ window mode. Not while the mouse is down: the drag's mouse-up would then never reach the selection. Back in
    /// area mode the selection is fitted to the ratio, which may have changed while it was hidden.
    private mutating func toggleMode() -> AllInOneKeyResult {
        switch selection.phase {
        case .dragging, .moving, .resizing: return .ignored
        default: break
        }
        mode = mode == .area ? .window : .area
        if mode == .area { selection.fitToAspectRatio() }
        return .changed
    }

    // MARK: Toolbar

    /// Fills the selection's display, or, when it already does, brings back the selection it replaced there.
    public mutating func toggleFullscreenSelection() {
        guard mode == .area else { return }
        fullscreen.toggle(&selection)
    }

    /// Locks drags, resizes and typed sizes to `ratio`, and reshapes the selection to it (in window mode, once the area
    /// comes back).
    public mutating func setRatio(_ ratio: SelectionRatio) {
        self.ratio = ratio
        selection.aspectRatio = ratio.aspect
        if hasSelection { selection.fitToAspectRatio() }
    }

    /// A size typed in the toolbar; see `SelectionController.setSize`.
    @discardableResult
    public mutating func setSize(width: CGFloat?, height: CGFloat?) -> Bool {
        guard mode == .area else { return false }
        return selection.setSize(width: width, height: height)
    }
}
