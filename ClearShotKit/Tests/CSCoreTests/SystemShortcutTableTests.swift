import Foundation
import Testing
@testable import CSCore

/// What `CopySymbolicHotKeys` returned on macOS 27 (measured): dictionaries of exactly these three keys, the key code and
/// the modifiers as numbers, and the enabled flag as a Core Foundation boolean. The modifiers are Carbon's, not NSEvent's.
struct SystemShortcutTableTests {
    private static let codeKey = "kHISymbolicHotKeyCode"
    private static let modifiersKey = "kHISymbolicHotKeyModifiers"
    private static let enabledKey = "kHISymbolicHotKeyEnabled"

    /// An entry shaped like the system's. A nil `code`, `modifiers` or `enabled` leaves that key out.
    private func entry(code: Int?, modifiers: Int?, enabled: Any? = NSNumber(value: true)) -> [String: Any] {
        var entry: [String: Any] = [:]
        if let code { entry[Self.codeKey] = NSNumber(value: code) }
        if let modifiers { entry[Self.modifiersKey] = NSNumber(value: modifiers) }
        if let enabled { entry[Self.enabledKey] = enabled }
        return entry
    }

    /// ⇧⌘4 as the system lists it: key code 21, modifiers 768.
    private var shiftCommand4: [String: Any] { entry(code: 21, modifiers: 768) }

    // MARK: What is kept

    @Test func anEmptyTableGivesNothing() {
        #expect(SystemShortcutTable.enabledShortcuts(from: []).isEmpty)
    }

    @Test func theFixtureHasTheRealShape() throws {
        // The enabled flag is a Core Foundation boolean, which is what the table tells apart from a number.
        let flag = try #require(shiftCommand4[Self.enabledKey])
        #expect(ShortcutStore.isBoolean(flag))
        #expect(!ShortcutStore.isBoolean(NSNumber(value: 1)))
        #expect(shiftCommand4.count == 3)
    }

    @Test func anEnabledEntryIsKeptWithItsCarbonModifiers() {
        let shortcuts = SystemShortcutTable.enabledShortcuts(from: [shiftCommand4])
        #expect(shortcuts == [ShortcutSpec(carbonKeyCode: 21, carbonModifiers: 768)])
        #expect(shortcuts == [.commandShift(KeyCode.digit4)])
    }

    @Test func aDisabledEntryIsDropped() {
        let disabled = entry(code: 20, modifiers: 768, enabled: NSNumber(value: false))
        #expect(SystemShortcutTable.enabledShortcuts(from: [disabled]).isEmpty)
        // Order and the other entries are not affected.
        let shortcuts = SystemShortcutTable.enabledShortcuts(from: [disabled, shiftCommand4, entry(code: 23, modifiers: 768)])
        #expect(shortcuts == [.commandShift(KeyCode.digit4), .commandShift(KeyCode.digit5)])
    }

    @Test func swiftAndCoreFoundationBooleansBothCount() {
        let swiftTrue = entry(code: 21, modifiers: 768, enabled: true)
        let cfTrue = entry(code: 20, modifiers: 768, enabled: kCFBooleanTrue as Any)
        let swiftFalse = entry(code: 23, modifiers: 768, enabled: false)
        let cfFalse = entry(code: 22, modifiers: 768, enabled: kCFBooleanFalse as Any)
        let shortcuts = SystemShortcutTable.enabledShortcuts(from: [swiftTrue, cfTrue, swiftFalse, cfFalse])
        #expect(shortcuts == [.commandShift(21), .commandShift(20)])
    }

    // MARK: The modifiers

    @Test func carbonModifiersConvert() {
        let cases: [(modifiers: Int, expected: Int)] = [
            (256, ShortcutSpec.command),
            (512, ShortcutSpec.shift),
            (2048, ShortcutSpec.option),
            (4096, ShortcutSpec.control),
            (256 | 512 | 2048 | 4096, 6912),
            (0, 0),
        ]
        for (modifiers, expected) in cases {
            let shortcuts = SystemShortcutTable.enabledShortcuts(from: [entry(code: 21, modifiers: modifiers)])
            #expect(shortcuts == [ShortcutSpec(carbonKeyCode: 21, carbonModifiers: expected)], "modifiers \(modifiers)")
        }
    }

    @Test func theFnBitOnAnArrowEntryIsIgnored() {
        // The system lists arrow and function-key shortcuts with Carbon's Fn bit (0x20000) set; ClearShot's never have Fn.
        let fn = 0x20000
        let controlLeft = entry(code: 123, modifiers: fn | 4096)
        let up = entry(code: 126, modifiers: fn)
        let shortcuts = SystemShortcutTable.enabledShortcuts(from: [controlLeft, up])
        #expect(shortcuts == [ShortcutSpec(carbonKeyCode: 123, carbonModifiers: ShortcutSpec.control),
                              ShortcutSpec(carbonKeyCode: 126, carbonModifiers: 0)])
    }

    @Test func otherBitsAreIgnoredToo() {
        // Caps lock (alphaLock, 1024), the right-hand modifier bits and anything higher are not part of a shortcut.
        let extras = 1024 | 0x2000 | 0x4000 | 0x8000 | 0x20000 | 0x800000
        let shortcuts = SystemShortcutTable.enabledShortcuts(from: [entry(code: 21, modifiers: 768 | extras)])
        #expect(shortcuts == [.commandShift(21)])
    }

    // MARK: What is skipped

    @Test func anEntryWithNoKeyAssignedIsSkipped() {
        // 65535 is how the system says no key is assigned.
        #expect(SystemShortcutTable.enabledShortcuts(from: [entry(code: 65535, modifiers: 768)]).isEmpty)
        #expect(SystemShortcutTable.enabledShortcuts(from: [entry(code: 65535, modifiers: 0)]).isEmpty)
        // 65534 is a key code like any other.
        #expect(SystemShortcutTable.enabledShortcuts(from: [entry(code: 65534, modifiers: 768)]).count == 1)
    }

    @Test func anEntryWithAKeyMissingIsSkipped() {
        let entries = [
            entry(code: nil, modifiers: 768),
            entry(code: 21, modifiers: nil),
            entry(code: 21, modifiers: 768, enabled: nil),
            entry(code: nil, modifiers: nil, enabled: nil),
            [:],
        ]
        #expect(SystemShortcutTable.enabledShortcuts(from: entries).isEmpty)
        // The good entry among them is the only one that comes through.
        #expect(SystemShortcutTable.enabledShortcuts(from: entries + [shiftCommand4]) == [.commandShift(21)])
    }

    @Test func anEnabledFlagThatIsNotABooleanIsSkipped() {
        let flags: [Any] = [1, 0, NSNumber(value: 1), NSNumber(value: 0), 1.0, "YES", "true", "1", NSNull(), [true]]
        for flag in flags {
            let entries = [entry(code: 21, modifiers: 768, enabled: flag)]
            #expect(SystemShortcutTable.enabledShortcuts(from: entries).isEmpty, "flag \(flag)")
        }
    }

    @Test func aKeyCodeOrModifiersThatIsNotAWholeNumberIsSkipped() {
        let entries: [[String: Any]] = [
            [Self.codeKey: "21", Self.modifiersKey: NSNumber(value: 768), Self.enabledKey: NSNumber(value: true)],
            [Self.codeKey: NSNumber(value: 21), Self.modifiersKey: "768", Self.enabledKey: NSNumber(value: true)],
            [Self.codeKey: NSNumber(value: 21.5), Self.modifiersKey: NSNumber(value: 768), Self.enabledKey: NSNumber(value: true)],
            [Self.codeKey: NSNumber(value: true), Self.modifiersKey: NSNumber(value: 768), Self.enabledKey: NSNumber(value: true)],
            [Self.codeKey: NSNumber(value: 21), Self.modifiersKey: NSNumber(value: true), Self.enabledKey: NSNumber(value: true)],
            [Self.codeKey: NSNumber(value: -5), Self.modifiersKey: NSNumber(value: 768), Self.enabledKey: NSNumber(value: true)],
            [Self.codeKey: NSNumber(value: 1 << 40), Self.modifiersKey: NSNumber(value: 768), Self.enabledKey: NSNumber(value: true)],
        ]
        #expect(SystemShortcutTable.enabledShortcuts(from: entries).isEmpty)
    }

    @Test func entriesKeepTheirOrderAndAreNotMerged() {
        let controlLeft = entry(code: 123, modifiers: 0x20000 | 4096)
        let entries = [controlLeft, shiftCommand4, entry(code: 20, modifiers: 768), shiftCommand4]
        let shortcuts = SystemShortcutTable.enabledShortcuts(from: entries)
        #expect(shortcuts == [ShortcutSpec(carbonKeyCode: 123, carbonModifiers: ShortcutSpec.control),
                              .commandShift(21), .commandShift(20), .commandShift(21)])
    }

    // MARK: In use

    @Test func theConflictCheckFindsTheActionsThatAreTaken() {
        // As in the app: macOS's own ⇧⌘4 (enabled) and ⇧⌘3 (switched off).
        let table = SystemShortcutTable.enabledShortcuts(from: [shiftCommand4, entry(code: 20, modifiers: 768, enabled: NSNumber(value: false))])
        let assignments: [ClearShotAction: ShortcutSpec] = [
            .captureFullscreen: .commandShift(KeyCode.digit3),
            .captureArea: .commandShift(KeyCode.digit4),
            .allInOne: .commandShift(KeyCode.digit5),
        ]
        let taken = ShortcutConflicts.actionsTakenBySystem(assignments: assignments) { table.contains($0) }
        #expect(taken == [.captureArea])
    }
}
