import Foundation

/// macOS's own keyboard shortcuts as `ShortcutSpec`s, converted from what `CopySymbolicHotKeys` returns. The app reads
/// that table (it needs Carbon) and passes the entries here, so the conversion can be tested without the system.
///
/// An entry is a dictionary of three keys:
/// - `kHISymbolicHotKeyCode`: the key code;
/// - `kHISymbolicHotKeyModifiers`: the modifiers, as **Carbon** masks (⌘ 256, ⇧ 512, ⌥ 2048, ⌃ 4096), not `NSEvent` flags;
/// - `kHISymbolicHotKeyEnabled`: a Core Foundation boolean, true for a shortcut that is switched on.
public enum SystemShortcutTable {
    private static let codeKey = "kHISymbolicHotKeyCode"
    private static let modifiersKey = "kHISymbolicHotKeyModifiers"
    private static let enabledKey = "kHISymbolicHotKeyEnabled"

    /// The key code the system lists for a shortcut that has no key assigned.
    private static let noKey = 65535

    /// The four modifier bits a ClearShot shortcut can have. The system sets others on some entries, such as 0x20000
    /// (Carbon's Fn bit) on arrow and function keys; they are not part of a shortcut here and are dropped.
    private static let modifierMask = ShortcutSpec.command | ShortcutSpec.shift | ShortcutSpec.option | ShortcutSpec.control

    /// The shortcuts of the enabled `entries`, in order, with only the four modifier bits kept.
    ///
    /// An entry is skipped when:
    /// - it is not enabled, or its flag is missing or not a boolean;
    /// - its key code or modifiers are missing or not whole numbers;
    /// - its key code is 65535 (no key assigned), or one a hot key can't take.
    public static func enabledShortcuts(from entries: [[String: Any]]) -> [ShortcutSpec] {
        entries.compactMap { entry in
            guard let enabled = entry[enabledKey], ShortcutStore.isBoolean(enabled), (enabled as? NSNumber)?.boolValue == true,
                  let keyCode = ShortcutStore.integer(entry[codeKey]), keyCode != noKey,
                  let modifiers = ShortcutStore.integer(entry[modifiersKey]) else { return nil }
            let spec = ShortcutSpec(carbonKeyCode: keyCode, carbonModifiers: modifiers & modifierMask)
            return ShortcutStore.isRepresentable(spec) ? spec : nil
        }
    }
}
