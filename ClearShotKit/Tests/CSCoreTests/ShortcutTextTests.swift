import Testing
@testable import CSCore

/// The Carbon virtual key codes (Events.h) these tests use. The tests carry their own copy of the numbers, so a wrong
/// one in the source can't be hidden by the same mistake here.
private enum Key {
    static let a = 0x00 // kVK_ANSI_A
    static let digit1 = 0x12 // kVK_ANSI_1
    static let digit4 = 0x15 // kVK_ANSI_4
    static let grave = 0x32 // kVK_ANSI_Grave
    static let keypad1 = 0x53 // kVK_ANSI_Keypad1
    static let keypadEnter = 0x4C // kVK_ANSI_KeypadEnter
    static let returnKey = 0x24 // kVK_Return
    static let tab = 0x30 // kVK_Tab
    static let space = 0x31 // kVK_Space
    static let delete = 0x33 // kVK_Delete
    static let escape = 0x35 // kVK_Escape
    static let f5 = 0x60 // kVK_F5
    static let f13 = 0x69 // kVK_F13
    static let forwardDelete = 0x75 // kVK_ForwardDelete
    static let leftArrow = 0x7B // kVK_LeftArrow
    static let upArrow = 0x7E // kVK_UpArrow
    static let unknown = 999
}

/// What the US layout gives for a few keys, in the shape the app's lookup has.
private func usLayout(_ keyCode: Int) -> String? {
    [Key.a: "a", Key.digit1: "1", Key.digit4: "4", Key.grave: "`", Key.keypad1: "1"][keyCode]
}

/// Every modifier combination, as (Carbon mask, the glyphs it shows): control, option, shift, command, in Apple's order.
private let allModifierCombinations: [(mask: Int, glyphs: String)] = [
    (0, ""),
    (ShortcutSpec.command, "⌘"),
    (ShortcutSpec.shift, "⇧"),
    (ShortcutSpec.shift | ShortcutSpec.command, "⇧⌘"),
    (ShortcutSpec.option, "⌥"),
    (ShortcutSpec.option | ShortcutSpec.command, "⌥⌘"),
    (ShortcutSpec.option | ShortcutSpec.shift, "⌥⇧"),
    (ShortcutSpec.option | ShortcutSpec.shift | ShortcutSpec.command, "⌥⇧⌘"),
    (ShortcutSpec.control, "⌃"),
    (ShortcutSpec.control | ShortcutSpec.command, "⌃⌘"),
    (ShortcutSpec.control | ShortcutSpec.shift, "⌃⇧"),
    (ShortcutSpec.control | ShortcutSpec.shift | ShortcutSpec.command, "⌃⇧⌘"),
    (ShortcutSpec.control | ShortcutSpec.option, "⌃⌥"),
    (ShortcutSpec.control | ShortcutSpec.option | ShortcutSpec.command, "⌃⌥⌘"),
    (ShortcutSpec.control | ShortcutSpec.option | ShortcutSpec.shift, "⌃⌥⇧"),
    (ShortcutSpec.control | ShortcutSpec.option | ShortcutSpec.shift | ShortcutSpec.command, "⌃⌥⇧⌘"),
]

/// The fixed names of the special keys, by key code (Events.h).
private let specialKeyNames: [(code: Int, name: String)] = [
    // F1–F20 (kVK_F1 … kVK_F20: the codes are not in order)
    (0x7A, "F1"), (0x78, "F2"), (0x63, "F3"), (0x76, "F4"), (0x60, "F5"), (0x61, "F6"), (0x62, "F7"), (0x64, "F8"),
    (0x65, "F9"), (0x6D, "F10"), (0x67, "F11"), (0x6F, "F12"), (0x69, "F13"), (0x6B, "F14"), (0x71, "F15"),
    (0x6A, "F16"), (0x40, "F17"), (0x4F, "F18"), (0x50, "F19"), (0x5A, "F20"),
    // Arrows
    (0x7B, "←"), (0x7C, "→"), (0x7E, "↑"), (0x7D, "↓"),
    // Editing and navigation
    (0x24, "↩"), (0x4C, "⌅"), (0x30, "⇥"), (0x31, "Space"), (0x33, "⌫"), (0x75, "⌦"), (0x35, "⎋"),
    (0x73, "↖"), (0x77, "↘"), (0x74, "⇞"), (0x79, "⇟"),
    // Keypad digits, then operators
    (0x52, "Keypad 0"), (0x53, "Keypad 1"), (0x54, "Keypad 2"), (0x55, "Keypad 3"), (0x56, "Keypad 4"),
    (0x57, "Keypad 5"), (0x58, "Keypad 6"), (0x59, "Keypad 7"), (0x5B, "Keypad 8"), (0x5C, "Keypad 9"),
    (0x41, "Keypad ."), (0x43, "Keypad *"), (0x45, "Keypad +"), (0x47, "Keypad Clear"), (0x4B, "Keypad /"),
    (0x4E, "Keypad -"), (0x51, "Keypad ="),
]

struct ShortcutTextTests {
    // MARK: Modifier glyphs

    @Test func everyModifierCombinationShowsItsGlyphsInApplesOrder() {
        #expect(allModifierCombinations.count == 16)
        for (mask, glyphs) in allModifierCombinations {
            #expect(ShortcutText.modifierGlyphs(mask) == glyphs, "mask \(mask)")
        }
    }

    @Test func bitsThatAreNotModifiersShowNothing() {
        // Caps lock (alphaLock, 1024), the right-shift bit and Fn (1 << 17) are not part of a ClearShot shortcut.
        let extras = 1024 | 0x2000 | (1 << 17)
        #expect(ShortcutText.modifierGlyphs(extras) == "")
        #expect(ShortcutText.modifierGlyphs(extras | ShortcutSpec.command) == "⌘")
    }

    // MARK: The whole text

    @Test func commandShift4ReadsAsItDoesInTheNotices() {
        let text = ShortcutText.string(for: .commandShift(Key.digit4)) { _ in "4" }
        #expect(text == "⇧⌘4")
        #expect(ShortcutText.string(for: .commandShift(Key.digit4), character: usLayout) == "⇧⌘4")
    }

    @Test func allFourModifiersAndALetter() {
        let all = ShortcutSpec(carbonKeyCode: Key.a, carbonModifiers: 256 | 512 | 2048 | 4096)
        #expect(ShortcutText.string(for: all, character: usLayout) == "⌃⌥⇧⌘A")
    }

    @Test func everyModifierCombinationPrecedesTheKey() {
        for (mask, glyphs) in allModifierCombinations {
            let spec = ShortcutSpec(carbonKeyCode: Key.digit4, carbonModifiers: mask)
            #expect(ShortcutText.string(for: spec, character: usLayout) == glyphs + "4", "mask \(mask)")
        }
    }

    @Test func aCharacterKeyUsesTheLayoutsCharacterUpperCased() {
        let command = ShortcutSpec(carbonKeyCode: Key.a, carbonModifiers: ShortcutSpec.command)
        #expect(ShortcutText.string(for: command) { _ in "a" } == "⌘A")
        #expect(ShortcutText.string(for: command) { _ in "é" } == "⌘É")
        // No case to change.
        #expect(ShortcutText.string(for: command) { _ in "`" } == "⌘`")
        #expect(ShortcutText.string(for: command) { _ in "4" } == "⌘4")
        // The layout is asked about the shortcut's own key code.
        let grave = ShortcutSpec(carbonKeyCode: Key.grave, carbonModifiers: ShortcutSpec.command)
        #expect(ShortcutText.string(for: grave, character: usLayout) == "⌘`")
    }

    @Test func aLetterWhoseCapitalIsTwoLettersStaysAsItIs() {
        // "ß".uppercased() is "SS"; the key's name stays the one letter the key shows.
        let command = ShortcutSpec(carbonKeyCode: Key.a, carbonModifiers: ShortcutSpec.command)
        #expect(ShortcutText.string(for: command) { _ in "ß" } == "⌘ß")
    }

    // MARK: Special keys

    @Test func specialKeysHaveTheirFixedNames() {
        for (code, name) in specialKeyNames {
            #expect(ShortcutText.specialKeyName(code) == name, "key code \(code)")
        }
    }

    @Test func noTwoSpecialKeysShareAName() {
        let names = (0..<256).compactMap { ShortcutText.specialKeyName($0) }
        #expect(names.count == specialKeyNames.count)
        #expect(Set(names).count == names.count)
    }

    @Test func aCharacterKeyHasNoSpecialName() {
        for code in [Key.a, Key.digit1, Key.digit4, Key.grave, Key.unknown, -1] {
            #expect(ShortcutText.specialKeyName(code) == nil, "key code \(code)")
        }
    }

    @Test func specialKeysIgnoreTheLayout() {
        let command = ShortcutSpec.command
        for (code, name) in [(Key.f5, "F5"), (Key.f13, "F13"), (Key.leftArrow, "←"), (Key.escape, "⎋")] {
            let spec = ShortcutSpec(carbonKeyCode: code, carbonModifiers: command)
            #expect(ShortcutText.string(for: spec) { _ in "x" } == "⌘" + name)
            #expect(ShortcutText.string(for: spec) { _ in nil } == "⌘" + name)
        }
    }

    @Test func spaceIsNamedNotShownAsABlank() {
        let spec = ShortcutSpec(carbonKeyCode: Key.space, carbonModifiers: ShortcutSpec.control | ShortcutSpec.option)
        #expect(ShortcutText.string(for: spec) { _ in " " } == "⌃⌥Space")
    }

    @Test func aKeypadKeyDiffersFromTheSameDigitOnTheMainRow() {
        let keypad = ShortcutSpec(carbonKeyCode: Key.keypad1, carbonModifiers: ShortcutSpec.command)
        let mainRow = ShortcutSpec(carbonKeyCode: Key.digit1, carbonModifiers: ShortcutSpec.command)
        #expect(ShortcutText.string(for: keypad, character: usLayout) == "⌘Keypad 1")
        #expect(ShortcutText.string(for: mainRow, character: usLayout) == "⌘1")
        // Keypad Enter is not Return.
        #expect(ShortcutText.string(for: ShortcutSpec(carbonKeyCode: Key.keypadEnter, carbonModifiers: 0)) { _ in "\u{3}" } == "⌅")
        #expect(ShortcutText.string(for: ShortcutSpec(carbonKeyCode: Key.returnKey, carbonModifiers: 0)) { _ in "\r" } == "↩")
    }

    // MARK: The fallback

    @Test func anUnknownKeyWithoutACharacterReadsAsKeyAndItsCode() {
        let spec = ShortcutSpec(carbonKeyCode: Key.unknown, carbonModifiers: ShortcutSpec.command | ShortcutSpec.shift)
        #expect(ShortcutText.string(for: spec) { _ in nil } == "⇧⌘Key 999")
        #expect(ShortcutText.string(for: ShortcutSpec(carbonKeyCode: Key.unknown, carbonModifiers: 0)) { _ in nil } == "Key 999")
    }

    @Test func anEmptyCharacterFallsBackToo() {
        let spec = ShortcutSpec(carbonKeyCode: Key.unknown, carbonModifiers: 0)
        #expect(ShortcutText.string(for: spec) { _ in "" } == "Key 999")
    }

    @Test func aCharacterThatShowsNothingFallsBackToo() {
        // A layout can give a blank or a control character (the Help key gives U+0005) for a key; showing it would
        // leave the key part of the text empty.
        let spec = ShortcutSpec(carbonKeyCode: Key.unknown, carbonModifiers: 0)
        for character in [" ", "  ", "\t", "\n", "\u{5}", "\u{7F}", " \u{5}"] {
            #expect(ShortcutText.string(for: spec) { _ in character } == "Key 999", "U+\(character.unicodeScalars.first!.value)")
        }
    }

    @Test func theTextIsNeverEmpty() {
        let characters: [String?] = [nil, "", " ", "\u{5}", "a", "ß", "`"]
        for code in -1...300 {
            for (mask, _) in allModifierCombinations {
                for character in characters {
                    let text = ShortcutText.string(for: ShortcutSpec(carbonKeyCode: code, carbonModifiers: mask)) { _ in character }
                    #expect(!text.isEmpty)
                    #expect(text != ShortcutText.modifierGlyphs(mask), "key code \(code), character \(String(describing: character))")
                }
            }
        }
    }
}

struct MenuKeyEquivalentTests {
    private func key(_ code: Int, _ modifiers: Int = ShortcutSpec.command, character: String? = nil) -> MenuKeyEquivalent? {
        MenuKeyEquivalent.make(for: ShortcutSpec(carbonKeyCode: code, carbonModifiers: modifiers)) { _ in character }
    }

    @Test func aLetterIsLowerCased() {
        #expect(key(Key.a, character: "A")?.key == "a")
        #expect(key(Key.a, character: "a")?.key == "a")
        #expect(key(Key.a, character: "É")?.key == "é")
        #expect(MenuKeyEquivalent.make(for: .commandShift(Key.digit4), character: usLayout)?.key == "4")
        #expect(MenuKeyEquivalent.make(for: .commandShift(Key.grave), character: usLayout)?.key == "`")
    }

    @Test func theLayoutIsAskedAboutTheShortcutsOwnKeyCode() {
        let spec = ShortcutSpec(carbonKeyCode: Key.a, carbonModifiers: ShortcutSpec.command)
        #expect(MenuKeyEquivalent.make(for: spec, character: usLayout)?.key == "a")
        #expect(MenuKeyEquivalent.make(for: ShortcutSpec(carbonKeyCode: Key.digit1, carbonModifiers: 0), character: usLayout)?.key == "1")
    }

    @Test func functionKeysUseAppKitsFunctionKeyCharacters() {
        // NSF1FunctionKey is 0xF704 and the others follow in order, F20 being 0xF717. The key codes are not in order.
        let codeByName = Dictionary(uniqueKeysWithValues: specialKeyNames.map { ($0.name, $0.code) })
        for number in 1...20 {
            let expected = Unicode.Scalar(0xF704 + UInt32(number - 1)).map(String.init)
            #expect(key(codeByName["F\(number)"] ?? -1)?.key == expected, "F\(number)")
        }
        #expect(key(Key.f5)?.key == "\u{F708}") // NSF5FunctionKey
    }

    @Test func arrowsUseAppKitsArrowCharacters() {
        #expect(key(Key.upArrow)?.key == "\u{F700}") // NSUpArrowFunctionKey
        #expect(key(0x7D)?.key == "\u{F701}") // kVK_DownArrow, NSDownArrowFunctionKey
        #expect(key(Key.leftArrow)?.key == "\u{F702}") // NSLeftArrowFunctionKey
        #expect(key(0x7C)?.key == "\u{F703}") // kVK_RightArrow, NSRightArrowFunctionKey
    }

    @Test func returnTabAndSpaceUseTheirControlCharacters() {
        #expect(key(Key.returnKey)?.key == "\r")
        #expect(key(Key.tab)?.key == "\t")
        #expect(key(Key.space)?.key == " ")
    }

    @Test func deleteKeysAndEscape() {
        #expect(key(Key.forwardDelete)?.key == "\u{F728}") // NSDeleteFunctionKey: AppKit's name for forward delete
        #expect(key(Key.delete)?.key == "\u{8}") // backspace
        #expect(key(Key.escape)?.key == "\u{1B}")
    }

    @Test func navigationKeysUseAppKitsCharacters() {
        #expect(key(0x73)?.key == "\u{F729}") // kVK_Home, NSHomeFunctionKey
        #expect(key(0x77)?.key == "\u{F72B}") // kVK_End, NSEndFunctionKey
        #expect(key(0x74)?.key == "\u{F72C}") // kVK_PageUp, NSPageUpFunctionKey
        #expect(key(0x79)?.key == "\u{F72D}") // kVK_PageDown, NSPageDownFunctionKey
    }

    @Test func aSpecialKeyIgnoresTheLayout() {
        #expect(key(Key.f5, character: "x")?.key == "\u{F708}")
        #expect(key(Key.space, character: "x")?.key == " ")
        #expect(key(Key.escape, character: nil)?.key == "\u{1B}")
    }

    @Test func aKeyWithNoCharacterAndNoSpecialFormHasNoEquivalent() {
        #expect(key(Key.unknown) == nil)
        #expect(key(Key.unknown, character: "") == nil)
        #expect(key(Key.unknown, character: " ") == nil)
        #expect(key(Key.unknown, character: "\u{5}") == nil)
        // Keypad Enter's character is a control character, which a menu item can't show.
        #expect(key(Key.keypadEnter, character: "\u{3}") == nil)
    }

    @Test func aKeypadKeyHasNoEquivalentWhateverTheLayoutSays() {
        // A menu can't tell the keypad's 1 from the main row's, so a keypad shortcut shows no key in the menu rather
        // than a key that the main row would trigger.
        let keypadCodes = specialKeyNames.filter { $0.name.hasPrefix("Keypad") }.map(\.code) + [Key.keypadEnter]
        #expect(keypadCodes.count == 18) // 10 digits, 7 operators (Clear among them) and Enter
        for code in keypadCodes {
            for character in [nil, "1", "+", "\u{3}"] {
                #expect(key(code, character: character) == nil, "key code \(code), character \(String(describing: character))")
            }
        }
        // The main row's 1 still has one.
        #expect(key(Key.digit1, character: "1")?.key == "1")
    }

    @Test func theModifiersPassThrough() {
        #expect(key(Key.a, 768, character: "a") == MenuKeyEquivalent(key: "a", carbonModifiers: 768))
        #expect(key(Key.a, 0, character: "a")?.carbonModifiers == 0)
        #expect(key(Key.f5, 256 | 512 | 2048 | 4096)?.carbonModifiers == 6912)
        #expect(MenuKeyEquivalent.make(for: .commandShift(Key.digit4), character: usLayout)?.carbonModifiers == 768)
    }
}
