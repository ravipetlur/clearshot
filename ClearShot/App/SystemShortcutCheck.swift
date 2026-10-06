import CSCore
import KeyboardShortcuts

/// Which ClearShot hotkeys macOS currently takes for itself (for example its own ⇧⌘4), read live.
enum SystemShortcutCheck {
    static func actionsTakenBySystem() -> [ClearShotAction] {
        var assignments: [ClearShotAction: ShortcutSpec] = [:]
        for action in ClearShotAction.allCases {
            if let shortcut = KeyboardShortcuts.getShortcut(for: .for(action)) {
                assignments[action] = ShortcutSpec(carbonKeyCode: shortcut.carbonKeyCode, carbonModifiers: shortcut.carbonModifiers)
            }
        }
        return ShortcutConflicts.actionsTakenBySystem(assignments: assignments) {
            KeyboardShortcuts.Shortcut(spec: $0).isTakenBySystem
        }
    }

    /// "⇧⌘4 (Capture Area), ⇧⌘5 (All-In-One)"
    static func describe(_ actions: [ClearShotAction]) -> String {
        actions.map { action in
            let keys = KeyboardShortcuts.getShortcut(for: .for(action)).map { "\($0)" } ?? ""
            return "\(keys) (\(action.title))"
        }.joined(separator: ", ")
    }
}
