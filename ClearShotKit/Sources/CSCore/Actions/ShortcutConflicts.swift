/// What happens to a shortcut just recorded for an action: it stays, or the action goes back to the shortcut it had
/// before (none if it had none) because another action already uses it, which the alert names.
public enum ShortcutResolution: Sendable, Equatable {
    case keep
    case revert(to: ShortcutSpec?, conflictsWith: ClearShotAction)
}

public enum ShortcutConflicts {
    /// Actions whose current shortcut macOS also uses, in registry order. macOS would get the key instead of ClearShot.
    /// `isTakenBySystem` checks the live, enabled system shortcuts.
    public static func actionsTakenBySystem(assignments: [ClearShotAction: ShortcutSpec],
                                            isTakenBySystem: (ShortcutSpec) -> Bool) -> [ClearShotAction] {
        ClearShotAction.allCases.filter { action in
            assignments[action].map(isTakenBySystem) ?? false
        }
    }

    /// One shortcut per action: `recorded` for `action` stays unless another action in `assignments` already uses it,
    /// the first in registry order, when `action` goes back to `previous`. `assignments` are the stored shortcuts,
    /// which may already hold `recorded` for `action` itself; a cleared shortcut (nil) always stays.
    public static func resolve(_ action: ClearShotAction, recorded: ShortcutSpec?, previous: ShortcutSpec?,
                               assignments: [ClearShotAction: ShortcutSpec]) -> ShortcutResolution {
        guard let recorded,
              let other = ClearShotAction.allCases.first(where: { $0 != action && assignments[$0] == recorded }) else {
            return .keep
        }
        return .revert(to: previous, conflictsWith: other)
    }
}
