import Carbon.HIToolbox
import CSCore

/// Which ClearShot hotkeys macOS currently takes for itself (for example its own ⇧⌘4), read live.
enum SystemShortcutCheck {
    /// Whether a failed read has been logged: the check runs every second while a window shows it, so once is enough.
    private static var readFailureLogged = false

    static func actionsTakenBySystem() -> [ClearShotAction] {
        let system = Set(systemShortcuts())
        return ShortcutConflicts.actionsTakenBySystem(assignments: ShortcutStore.app.all()) { system.contains($0) }
    }

    /// "⇧⌘4 (Capture Area), ⇧⌘5 (All-In-One)"
    static func describe(_ actions: [ClearShotAction]) -> String {
        actions.map { action in
            let keys = ShortcutStore.app.shortcut(for: action).map { ShortcutText.string(for: $0) } ?? ""
            return "\(keys) (\(action.title))"
        }.joined(separator: ", ")
    }

    /// The shortcuts macOS has switched on, from its table of symbolic hot keys; none when it can't be read.
    private static func systemShortcuts() -> [ShortcutSpec] {
        var table: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&table)
        guard status == noErr, let entries = table?.takeRetainedValue() as? [[String: Any]] else {
            if !readFailureLogged {
                readFailureLogged = true
                Log.hotkeys.warning("Couldn't read macOS's keyboard shortcuts (status \(status)); none is reported as taken")
            }
            return []
        }
        return SystemShortcutTable.enabledShortcuts(from: entries)
    }
}
