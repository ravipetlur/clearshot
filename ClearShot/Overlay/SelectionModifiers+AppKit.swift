import AppKit
import CSCapture

extension SelectionModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: SelectionModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self = modifiers
    }
}
