import Foundation

/// One-time move of the shortcuts v1.0.0 saved into `ShortcutStore`. It runs once at launch, before anything registers a
/// hot key or observes the store, and again on every launch after that, when it finds nothing.
public enum LegacyShortcutMigration {
    /// Where v1.0.0 stored each shortcut.
    public static func legacyKey(for action: ClearShotAction) -> String {
        "KeyboardShortcuts_\(action.rawValue)"
    }

    /// What v1.0.0 kept in each key: JSON text of the form `{"carbonModifiers":768,"carbonKeyCode":21}`, the keys in any order.
    private struct LegacyShortcut: Decodable {
        let carbonKeyCode: Int
        let carbonModifiers: Int
    }

    private enum Legacy {
        case shortcut(ShortcutSpec)
        case cleared
    }

    /// For each action with an old key:
    /// - JSON text with integer `carbonKeyCode` and `carbonModifiers` migrates as that shortcut;
    /// - the boolean `false` migrates as an explicit clear;
    /// - anything else (bad JSON, a missing field, a number, `true`) is skipped and logged;
    /// - if the action's new key is already set, the old value is ignored: the new key wins;
    /// - the old key is removed once it has been read, whatever it held, so a second run finds nothing to do.
    ///
    /// The result is how many actions it migrated, clears included. Each is written through `store`, so each posts
    /// `ShortcutStore.didChange`; nothing observes yet when this runs, so that is harmless. `defaults` should be the
    /// store's own, and `logger` is where skipped values are logged.
    @discardableResult
    public static func run(defaults: UserDefaults, store: ShortcutStore, logger: AppLogger = Log.hotkeys) -> Int {
        var migrated = 0
        for action in ClearShotAction.allCases {
            let oldKey = legacyKey(for: action)
            guard let old = defaults.object(forKey: oldKey) else { continue }
            // Removed once handled, so the new value is always written before the old one goes.
            defer { defaults.removeObject(forKey: oldKey) }

            guard defaults.object(forKey: ShortcutStore.key(for: action)) == nil else { continue }
            switch legacy(from: old) {
            case .shortcut(let spec)?:
                store.set(spec, for: action)
                migrated += 1
            case .cleared?:
                store.set(nil, for: action)
                migrated += 1
            case nil:
                logger.warning("Skipping the shortcut v1.0.0 saved for \(action.rawValue): \(ShortcutStore.excerpt(of: old)) is neither a shortcut nor a cleared one")
            }
        }
        return migrated
    }

    private static func legacy(from value: Any) -> Legacy? {
        if ShortcutStore.isBoolean(value) {
            return (value as? NSNumber)?.boolValue == false ? .cleared : nil
        }
        guard let text = value as? String,
              let legacy = try? JSONDecoder().decode(LegacyShortcut.self, from: Data(text.utf8)) else { return nil }
        let spec = ShortcutSpec(carbonKeyCode: legacy.carbonKeyCode, carbonModifiers: legacy.carbonModifiers)
        return ShortcutStore.isRepresentable(spec) ? .shortcut(spec) : nil
    }
}
