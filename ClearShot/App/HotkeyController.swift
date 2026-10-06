import CSCore
import KeyboardShortcuts

extension KeyboardShortcuts.Shortcut {
    nonisolated init(spec: ShortcutSpec) {
        self.init(carbonKeyCode: spec.carbonKeyCode, carbonModifiers: spec.carbonModifiers)
    }
}

extension KeyboardShortcuts.Name {
    /// One name per action, created once so the initial shortcut is registered exactly once.
    static let byAction: [ClearShotAction: KeyboardShortcuts.Name] = Dictionary(
        uniqueKeysWithValues: ClearShotAction.allCases.map { action in
            (action, KeyboardShortcuts.Name(action.rawValue, initial: action.defaultShortcut.map(KeyboardShortcuts.Shortcut.init(spec:))))
        }
    )

    static func `for`(_ action: ClearShotAction) -> KeyboardShortcuts.Name {
        byAction[action]!
    }
}

final class HotkeyController {
    func register(_ handler: @escaping (ClearShotAction) -> Void) {
        for action in ClearShotAction.allCases {
            KeyboardShortcuts.onKeyDown(for: .for(action)) {
                Log.hotkeys.info("Hotkey: \(action.rawValue)")
                handler(action)
            }
        }
    }

    /// The actions with a shortcut that isn't registered: macOS refuses a hotkey another app has already taken, and the
    /// shortcut never fires while it's refused. KeyboardShortcuts drops a shortcut whose registration fails, so it
    /// isn't enabled; read after `register`.
    static func actionsWithUnregisteredShortcuts() -> [ClearShotAction] {
        guard KeyboardShortcuts.isEnabled else { return [] }
        return ClearShotAction.allCases.filter { action in
            KeyboardShortcuts.getShortcut(for: .for(action)) != nil && !KeyboardShortcuts.isEnabled(for: .for(action))
        }
    }
}
