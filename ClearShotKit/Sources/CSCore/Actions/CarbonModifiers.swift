/// Converts between Carbon's modifier mask (what `ShortcutSpec` and `RegisterEventHotKey` use) and the flags of an
/// `NSEvent`. CSCore doesn't import AppKit, so the flags are plain numbers; only the four modifiers a shortcut can have
/// are converted, and every other bit (caps lock, Fn, the numeric pad, the device-dependent ones) is dropped.
public enum CarbonModifiers {
    // NSEvent.ModifierFlags raw values, from NSEvent.h.
    private static let eventShift: UInt = 1 << 17 // NSEventModifierFlagShift
    private static let eventControl: UInt = 1 << 18 // NSEventModifierFlagControl
    private static let eventOption: UInt = 1 << 19 // NSEventModifierFlagOption
    private static let eventCommand: UInt = 1 << 20 // NSEventModifierFlagCommand

    /// The Carbon mask for the `NSEvent` flags `eventFlags` (`NSEvent.modifierFlags.rawValue`).
    public static func from(eventFlags: UInt) -> Int {
        var carbon = 0
        if eventFlags & eventCommand != 0 { carbon |= ShortcutSpec.command }
        if eventFlags & eventShift != 0 { carbon |= ShortcutSpec.shift }
        if eventFlags & eventOption != 0 { carbon |= ShortcutSpec.option }
        if eventFlags & eventControl != 0 { carbon |= ShortcutSpec.control }
        return carbon
    }

    /// The `NSEvent` flags (a raw value for `NSEvent.ModifierFlags`) for the Carbon mask `carbon`.
    public static func eventFlags(from carbon: Int) -> UInt {
        var flags: UInt = 0
        if carbon & ShortcutSpec.command != 0 { flags |= eventCommand }
        if carbon & ShortcutSpec.shift != 0 { flags |= eventShift }
        if carbon & ShortcutSpec.option != 0 { flags |= eventOption }
        if carbon & ShortcutSpec.control != 0 { flags |= eventControl }
        return flags
    }
}
