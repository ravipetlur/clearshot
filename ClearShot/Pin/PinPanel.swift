import AppKit
import CSCapture
import CSCore

/// The borderless window behind one pin: above an always-on-top editor, on every Space and over full-screen apps. It
/// never activates ClearShot and never takes key by being shown, but a click makes it key, so its ⌘ shortcuts and
/// arrows reach it while the app in front stays active.
final class PinPanel: NSPanel {
    /// ⌘C, ⌘W, ⌘E, ⌘S and the zoom keys.
    var onCommand: ((PinCommand) -> Void)?
    /// A locked pin never becomes key, so typing stays with the app in front.
    var isLocked = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PinGeometry.minimumSide, height: PinGeometry.minimumSide),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: WindowLevels.pin)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        // ClearShot is almost never the active app, so the hover buttons' help would otherwise never show.
        allowsToolTipsWhenApplicationIsInactive = true
    }

    override var canBecomeKey: Bool { !isLocked }
    override var canBecomeMain: Bool { false }

    /// A click on a hover button makes the panel key without giving its view focus; the arrows need it.
    override func becomeKey() {
        super.becomeKey()
        makeFirstResponder(contentView)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Exactly ⌘ (⌘⇧ also for "+", which needs ⇧ on most layouts); ⌘⇧C and the like are someone else's. Caps Lock,
        // fn and numeric-pad bits are ignored.
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard let key = event.charactersIgnoringModifiers?.lowercased(), let command = Self.command(for: key, modifiers),
              let onCommand else {
            return super.performKeyEquivalent(with: event)
        }
        onCommand(command)
        return true
    }

    private static func command(for key: String, _ modifiers: NSEvent.ModifierFlags) -> PinCommand? {
        if key == "+", modifiers == [.command, .shift] { return .zoomIn }
        guard modifiers == .command else { return nil }
        return switch key {
        case "c": .copy
        case "w": .close
        case "e": .annotate
        case "s": .saveAs
        case "+", "=": .zoomIn
        case "-": .zoomOut
        case "0": .actualSize
        default: nil
        }
    }
}
