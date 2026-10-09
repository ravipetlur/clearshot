/// How a shortcut reads as text, such as `⇧⌘4`: the modifier glyphs in Apple's order (⌃ ⌥ ⇧ ⌘), then the key.
///
/// The key's name comes from one of two places:
/// - a fixed name for the keys that have no character of their own (function keys, arrows, Return, Space, the keypad
///   and so on), the same on every keyboard layout;
/// - the character the current keyboard layout gives that key, upper-cased. CSCore knows nothing of layouts, so the
///   caller passes the lookup in as a closure; the app builds it on `UCKeyTranslate`.
public enum ShortcutText {
    /// The text for `shortcut`: `⇧⌘4`, `⌃⌥F5`, `⌘Keypad 1`. `character` gives the layout's character for a key code, or
    /// nil for none. The result is never empty: a key with neither a fixed name nor a character shows as `Key <code>`.
    public static func string(for shortcut: ShortcutSpec, character: (Int) -> String?) -> String {
        modifierGlyphs(shortcut.carbonModifiers) + keyName(for: shortcut.carbonKeyCode, character: character)
    }

    /// The glyphs of the modifiers in `carbonModifiers`, in Apple's order: ⌃ ⌥ ⇧ ⌘. Other bits (Fn, caps lock) show nothing.
    public static func modifierGlyphs(_ carbonModifiers: Int) -> String {
        var glyphs = ""
        if carbonModifiers & ShortcutSpec.control != 0 { glyphs += "⌃" }
        if carbonModifiers & ShortcutSpec.option != 0 { glyphs += "⌥" }
        if carbonModifiers & ShortcutSpec.shift != 0 { glyphs += "⇧" }
        if carbonModifiers & ShortcutSpec.command != 0 { glyphs += "⌘" }
        return glyphs
    }

    /// The fixed name of a key that has one (`F5`, `←`, `↩`, `Space`, `Keypad 1`), nil for a key that is named by its
    /// character. A key with a fixed name always shows it, whatever the layout says.
    public static func specialKeyName(_ keyCode: Int) -> String? {
        specialKeysByCode[keyCode]?.name
    }

    private static func keyName(for keyCode: Int, character: (Int) -> String?) -> String {
        if let name = specialKeyName(keyCode) { return name }
        if let visible = visibleCharacter(character(keyCode)) { return upperCased(visible) }
        return "Key \(keyCode)"
    }

    /// `character` if it shows something, else nil. A layout can answer with an empty string, a blank or a control
    /// character (the Help key gives U+0005); none of those can name a key. Internal so that `MenuKeyEquivalent` applies
    /// the same test.
    static func visibleCharacter(_ character: String?) -> String? {
        guard let character,
              !character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control || $0.properties.isWhitespace })
        else { return nil }
        return character
    }

    /// `character` in capitals, unless that makes more of it: the capital of `ß` is `SS`, and the key still shows `ß`.
    private static func upperCased(_ character: String) -> String {
        let upper = character.uppercased()
        return upper.count == character.count ? upper : character
    }
}

/// A key and modifiers for an `NSMenuItem`: what a menu shows next to an item as its shortcut.
public struct MenuKeyEquivalent: Equatable, Sendable {
    /// The item's `keyEquivalent`: the layout's character, lower-cased, or for a special key the character AppKit uses
    /// for it (`NSF5FunctionKey`, `NSUpArrowFunctionKey`, `"\r"`, `" "`).
    public let key: String
    /// The shortcut's modifiers, as given (Carbon's mask); the caller converts them for the item's `keyEquivalentModifierMask`.
    public let carbonModifiers: Int

    /// The menu form of `shortcut`, or nil for a key with none. A key with a fixed name uses its special form whatever
    /// the layout says, and has none when it has no such form (the keypad keys: a menu can't tell them from the main
    /// rows, so they show nothing rather than the main row's key). Any other key uses the character from `character`
    /// (the layout's lookup, as for `ShortcutText.string`), and has none when that shows nothing.
    public static func make(for shortcut: ShortcutSpec, character: (Int) -> String?) -> MenuKeyEquivalent? {
        let keyCode = shortcut.carbonKeyCode
        if let special = specialKeysByCode[keyCode] {
            guard let menuKey = special.menuKey else { return nil }
            return MenuKeyEquivalent(key: menuKey, carbonModifiers: shortcut.carbonModifiers)
        }
        guard let visible = ShortcutText.visibleCharacter(character(keyCode)) else { return nil }
        return MenuKeyEquivalent(key: visible.lowercased(), carbonModifiers: shortcut.carbonModifiers)
    }
}

// MARK: The keys with fixed names

/// A key that has a name of its own. CSCore doesn't import Carbon or AppKit, so the key codes and AppKit's function-key
/// characters are numbers copied from the SDK headers, each with its header name beside it.
private struct SpecialKey {
    /// A Carbon virtual key code, from `kVK_*` in HIToolbox's Events.h.
    let keyCode: Int
    /// What a shortcut shows for the key.
    let name: String
    /// The key's `keyEquivalent` in a menu: an AppKit function-key character (`NS…FunctionKey`, NSEvent.h) or a control
    /// character. Nil where a menu has no form for the key; the key then has no key equivalent at all.
    let menuKey: String?

    init(_ keyCode: Int, _ name: String, menu menuKey: String? = nil) {
        self.keyCode = keyCode
        self.name = name
        self.menuKey = menuKey
    }
}

private let specialKeysByCode: [Int: SpecialKey] = Dictionary(specialKeys.map { ($0.keyCode, $0) }, uniquingKeysWith: { first, _ in first })

private let specialKeys: [SpecialKey] = [
    // Function keys. The key codes are not in order; AppKit's characters are (NSF1FunctionKey is 0xF704, and so on).
    SpecialKey(0x7A, "F1", menu: "\u{F704}"), // kVK_F1, NSF1FunctionKey
    SpecialKey(0x78, "F2", menu: "\u{F705}"), // kVK_F2, NSF2FunctionKey
    SpecialKey(0x63, "F3", menu: "\u{F706}"), // kVK_F3, NSF3FunctionKey
    SpecialKey(0x76, "F4", menu: "\u{F707}"), // kVK_F4, NSF4FunctionKey
    SpecialKey(0x60, "F5", menu: "\u{F708}"), // kVK_F5, NSF5FunctionKey
    SpecialKey(0x61, "F6", menu: "\u{F709}"), // kVK_F6, NSF6FunctionKey
    SpecialKey(0x62, "F7", menu: "\u{F70A}"), // kVK_F7, NSF7FunctionKey
    SpecialKey(0x64, "F8", menu: "\u{F70B}"), // kVK_F8, NSF8FunctionKey
    SpecialKey(0x65, "F9", menu: "\u{F70C}"), // kVK_F9, NSF9FunctionKey
    SpecialKey(0x6D, "F10", menu: "\u{F70D}"), // kVK_F10, NSF10FunctionKey
    SpecialKey(0x67, "F11", menu: "\u{F70E}"), // kVK_F11, NSF11FunctionKey
    SpecialKey(0x6F, "F12", menu: "\u{F70F}"), // kVK_F12, NSF12FunctionKey
    SpecialKey(0x69, "F13", menu: "\u{F710}"), // kVK_F13, NSF13FunctionKey
    SpecialKey(0x6B, "F14", menu: "\u{F711}"), // kVK_F14, NSF14FunctionKey
    SpecialKey(0x71, "F15", menu: "\u{F712}"), // kVK_F15, NSF15FunctionKey
    SpecialKey(0x6A, "F16", menu: "\u{F713}"), // kVK_F16, NSF16FunctionKey
    SpecialKey(0x40, "F17", menu: "\u{F714}"), // kVK_F17, NSF17FunctionKey
    SpecialKey(0x4F, "F18", menu: "\u{F715}"), // kVK_F18, NSF18FunctionKey
    SpecialKey(0x50, "F19", menu: "\u{F716}"), // kVK_F19, NSF19FunctionKey
    SpecialKey(0x5A, "F20", menu: "\u{F717}"), // kVK_F20, NSF20FunctionKey

    // Arrows
    SpecialKey(0x7B, "←", menu: "\u{F702}"), // kVK_LeftArrow, NSLeftArrowFunctionKey
    SpecialKey(0x7C, "→", menu: "\u{F703}"), // kVK_RightArrow, NSRightArrowFunctionKey
    SpecialKey(0x7E, "↑", menu: "\u{F700}"), // kVK_UpArrow, NSUpArrowFunctionKey
    SpecialKey(0x7D, "↓", menu: "\u{F701}"), // kVK_DownArrow, NSDownArrowFunctionKey

    // Editing keys. Keypad Enter has no menu form (its character is a control character, and Return's would stand for it).
    SpecialKey(0x24, "↩", menu: "\r"), // kVK_Return
    SpecialKey(0x4C, "⌅"), // kVK_ANSI_KeypadEnter
    SpecialKey(0x30, "⇥", menu: "\t"), // kVK_Tab
    SpecialKey(0x31, "Space", menu: " "), // kVK_Space
    SpecialKey(0x33, "⌫", menu: "\u{8}"), // kVK_Delete: backspace
    SpecialKey(0x75, "⌦", menu: "\u{F728}"), // kVK_ForwardDelete, NSDeleteFunctionKey
    SpecialKey(0x35, "⎋", menu: "\u{1B}"), // kVK_Escape

    // Navigation keys
    SpecialKey(0x73, "↖", menu: "\u{F729}"), // kVK_Home, NSHomeFunctionKey
    SpecialKey(0x77, "↘", menu: "\u{F72B}"), // kVK_End, NSEndFunctionKey
    SpecialKey(0x74, "⇞", menu: "\u{F72C}"), // kVK_PageUp, NSPageUpFunctionKey
    SpecialKey(0x79, "⇟", menu: "\u{F72D}"), // kVK_PageDown, NSPageDownFunctionKey

    // Keypad digits and operators, named so that they differ from the same characters on the main rows. A menu has no
    // way to tell them apart, so they have no menu form: a keypad shortcut shows no key in the menu.
    SpecialKey(0x52, "Keypad 0"), // kVK_ANSI_Keypad0
    SpecialKey(0x53, "Keypad 1"), // kVK_ANSI_Keypad1
    SpecialKey(0x54, "Keypad 2"), // kVK_ANSI_Keypad2
    SpecialKey(0x55, "Keypad 3"), // kVK_ANSI_Keypad3
    SpecialKey(0x56, "Keypad 4"), // kVK_ANSI_Keypad4
    SpecialKey(0x57, "Keypad 5"), // kVK_ANSI_Keypad5
    SpecialKey(0x58, "Keypad 6"), // kVK_ANSI_Keypad6
    SpecialKey(0x59, "Keypad 7"), // kVK_ANSI_Keypad7
    SpecialKey(0x5B, "Keypad 8"), // kVK_ANSI_Keypad8
    SpecialKey(0x5C, "Keypad 9"), // kVK_ANSI_Keypad9
    SpecialKey(0x41, "Keypad ."), // kVK_ANSI_KeypadDecimal
    SpecialKey(0x43, "Keypad *"), // kVK_ANSI_KeypadMultiply
    SpecialKey(0x45, "Keypad +"), // kVK_ANSI_KeypadPlus
    SpecialKey(0x47, "Keypad Clear"), // kVK_ANSI_KeypadClear
    SpecialKey(0x4B, "Keypad /"), // kVK_ANSI_KeypadDivide
    SpecialKey(0x4E, "Keypad -"), // kVK_ANSI_KeypadMinus
    SpecialKey(0x51, "Keypad ="), // kVK_ANSI_KeypadEquals
]
