import CSTestSupport
import Foundation
import Testing
@testable import CSCore

final class LegacyShortcutMigrationTests {
    let throwaway = ThrowawayDefaults("legacy-shortcut-migration")
    let defaults: UserDefaults
    let center = NotificationCenter()
    let log = TemporaryLog()
    let store: ShortcutStore

    let area = ShortcutSpec.commandShift(KeyCode.digit4)
    let allInOne = ShortcutSpec.commandShift(KeyCode.digit5)

    init() {
        defaults = throwaway.defaults
        store = ShortcutStore(defaults: defaults, notificationCenter: center, logger: log.logger)
    }

    private func legacyKey(_ action: ClearShotAction) -> String { "KeyboardShortcuts_\(action.rawValue)" }
    private func newKey(_ action: ClearShotAction) -> String { "shortcut.\(action.rawValue)" }

    @discardableResult
    private func migrate() -> Int {
        LegacyShortcutMigration.run(defaults: defaults, store: store, logger: log.logger)
    }

    /// Stores `value` as v1.0.0's value of `action`, runs the migration, and checks it was skipped: nothing migrated,
    /// no new key, the old key gone, the action on its default, and one more line in the log, naming the action.
    private func expectSkipped(_ value: Any, for action: ClearShotAction, _ description: String,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        let linesBefore = log.lines.count
        defaults.set(value, forKey: legacyKey(action))
        #expect(migrate() == 0, "\(description): count", sourceLocation: sourceLocation)
        #expect(defaults.object(forKey: newKey(action)) == nil, "\(description): new key", sourceLocation: sourceLocation)
        #expect(defaults.object(forKey: legacyKey(action)) == nil, "\(description): old key", sourceLocation: sourceLocation)
        #expect(store.shortcut(for: action) == action.defaultShortcut, "\(description): shortcut", sourceLocation: sourceLocation)
        #expect(log.lines.count == linesBefore + 1, "\(description): log", sourceLocation: sourceLocation)
        #expect(log.lines.last?.contains("[WARN] [hotkeys]") == true, "\(description): log level", sourceLocation: sourceLocation)
        #expect(log.lines.last?.contains(action.rawValue) == true, "\(description): log names the action", sourceLocation: sourceLocation)
    }

    // MARK: The old key

    @Test func theOldKeyIsTheLibraryPrefixPlusTheActionName() {
        #expect(LegacyShortcutMigration.legacyKey(for: .allInOne) == "KeyboardShortcuts_allInOne")
        for action in ClearShotAction.allCases {
            #expect(LegacyShortcutMigration.legacyKey(for: action) == legacyKey(action))
        }
    }

    // MARK: What migrates

    @Test func aJSONStringMigratesInEitherKeyOrder() {
        // v1.0.0's stored shape: modifiers first.
        defaults.set(#"{"carbonModifiers":768,"carbonKeyCode":21}"#, forKey: legacyKey(.recordScreen))
        defaults.set(#"{"carbonKeyCode":15,"carbonModifiers":4352}"#, forKey: legacyKey(.selfTimer))

        #expect(migrate() == 2)

        #expect(store.shortcut(for: .recordScreen) == ShortcutSpec(carbonKeyCode: 21, carbonModifiers: 768))
        #expect(store.shortcut(for: .selfTimer) == ShortcutSpec(carbonKeyCode: 15, carbonModifiers: 4352))
        #expect(defaults.object(forKey: legacyKey(.recordScreen)) == nil)
        #expect(defaults.object(forKey: legacyKey(.selfTimer)) == nil)
        #expect(log.lines.isEmpty)
    }

    @Test func aMigratedShortcutReplacesTheDefault() {
        defaults.set(#"{"carbonModifiers":768,"carbonKeyCode":23}"#, forKey: legacyKey(.captureArea))
        #expect(migrate() == 1)
        #expect(store.shortcut(for: .captureArea) == allInOne)
        #expect(defaults.dictionary(forKey: newKey(.captureArea)) as? [String: Int] == ["keyCode": 23, "modifiers": 768])
    }

    @Test func aJSONStringWithExtraFieldsStillMigrates() {
        defaults.set(#"{"carbonKeyCode":15,"carbonModifiers":768,"other":"x"}"#, forKey: legacyKey(.recordScreen))
        #expect(migrate() == 1)
        #expect(store.shortcut(for: .recordScreen) == ShortcutSpec(carbonKeyCode: 15, carbonModifiers: 768))
    }

    @Test func falseMigratesAsAnExplicitClear() throws {
        defaults.set(false, forKey: legacyKey(.captureArea))

        #expect(migrate() == 1)

        // The action has a default, but the user had cleared it.
        #expect(store.shortcut(for: .captureArea) == nil)
        let stored = try #require(defaults.object(forKey: newKey(.captureArea)))
        #expect(ShortcutStore.isBoolean(stored))
        #expect(defaults.object(forKey: legacyKey(.captureArea)) == nil)
        #expect(store.shortcut(for: .allInOne) == allInOne)
        #expect(log.lines.isEmpty)
    }

    @Test func anAbsentOldKeyLeavesNothingToMigrate() {
        let before = Set(defaults.dictionaryRepresentation().keys)
        let recorder = ChangeRecorder(center: center)

        #expect(migrate() == 0)

        #expect(Set(defaults.dictionaryRepresentation().keys) == before)
        for action in ClearShotAction.allCases {
            #expect(defaults.object(forKey: newKey(action)) == nil)
            #expect(store.shortcut(for: action) == action.defaultShortcut)
        }
        #expect(recorder.posts.isEmpty)
        #expect(log.lines.isEmpty)
    }

    // MARK: What is skipped

    /// Anything but v1.0.0's JSON text or `false` is skipped: text that isn't the JSON object, one missing a field, with
    /// a field of the wrong type or out of range, any number (UserDefaults hands back a stored false as an NSNumber, so a
    /// stored 0 must not pass for it), `true`, and any other type.
    @Test func everyOtherValueIsSkipped() {
        let values: [(value: Any, action: ClearShotAction, description: String)] = [
            ("not json at all", .recordScreen, "text"),
            ("", .recordScreen, "empty string"),
            ("{}", .selfTimer, "empty object"),
            ("[21,768]", .captureWindow, "array"),
            (#"{"carbonModifiers":768}"#, .captureArea, "missing key code"),
            (#"{"carbonKeyCode":21}"#, .captureArea, "missing modifiers"),
            (#"{"carbonKeyCode":"21","carbonModifiers":768}"#, .recordScreen, "text key code"),
            (#"{"carbonKeyCode":21.5,"carbonModifiers":768}"#, .recordScreen, "fractional key code"),
            (#"{"carbonKeyCode":true,"carbonModifiers":768}"#, .recordScreen, "boolean key code"),
            (#"{"carbonKeyCode":21,"carbonModifiers":null}"#, .recordScreen, "null modifiers"),
            (#"{"carbonKeyCode":-1,"carbonModifiers":768}"#, .recordScreen, "negative key code"),
            (#"{"carbonKeyCode":21,"carbonModifiers":99999999999}"#, .recordScreen, "huge modifiers"),
            (0, .captureArea, "number 0"),
            (21, .recordScreen, "number 21"),
            (1.5, .selfTimer, "fraction"),
            (true, .captureArea, "true"),
            (["carbonKeyCode": 21, "carbonModifiers": 768], .recordScreen, "dictionary"),
            ([21, 768], .selfTimer, "array"),
            (Data("{}".utf8), .captureWindow, "data"),
        ]
        for (value, action, description) in values {
            expectSkipped(value, for: action, description)
        }
    }

    // MARK: The new key wins

    @Test func aNewKeyAlreadySetKeepsItsValueAndTheOldKeyIsRemoved() {
        let kept = ShortcutSpec(carbonKeyCode: 15, carbonModifiers: 4352)
        store.set(kept, for: .recordScreen)
        defaults.set(#"{"carbonModifiers":768,"carbonKeyCode":21}"#, forKey: legacyKey(.recordScreen))

        // A cleared new key wins too, over an old shortcut and an old clear alike.
        store.set(nil, for: .captureArea)
        defaults.set(#"{"carbonModifiers":768,"carbonKeyCode":23}"#, forKey: legacyKey(.captureArea))
        store.set(nil, for: .allInOne)
        defaults.set(false, forKey: legacyKey(.allInOne))
        store.set(.commandShift(KeyCode.digit6), for: .selfTimer)
        defaults.set(false, forKey: legacyKey(.selfTimer))

        // The old key goes whatever it held, here beside a new key.
        store.set(kept, for: .captureWindow)
        defaults.set("junk", forKey: legacyKey(.captureWindow))

        let recorder = ChangeRecorder(center: center)
        #expect(migrate() == 0)

        #expect(store.shortcut(for: .recordScreen) == kept)
        #expect(store.shortcut(for: .captureArea) == nil)
        #expect(store.shortcut(for: .allInOne) == nil)
        #expect(store.shortcut(for: .selfTimer) == .commandShift(KeyCode.digit6))
        #expect(store.shortcut(for: .captureWindow) == kept)
        for action in [ClearShotAction.recordScreen, .captureArea, .allInOne, .selfTimer, .captureWindow] {
            #expect(defaults.object(forKey: legacyKey(action)) == nil)
        }
        // Nothing was written, so nothing was posted.
        #expect(recorder.posts.isEmpty)
    }

    // MARK: Everything at once

    @Test func everyActionMigratesAtOnce() {
        // v1.0.0's stored shape: the three defaults, each stored as JSON text with the modifiers first.
        defaults.set(#"{"carbonModifiers":768,"carbonKeyCode":20}"#, forKey: legacyKey(.captureFullscreen))
        defaults.set(#"{"carbonModifiers":768,"carbonKeyCode":21}"#, forKey: legacyKey(.captureArea))
        defaults.set(#"{"carbonModifiers":768,"carbonKeyCode":23}"#, forKey: legacyKey(.allInOne))

        // The rest: every second one cleared, the others given a shortcut of their own.
        let defaultActions: Set<ClearShotAction> = [.captureFullscreen, .captureArea, .allInOne]
        var expected: [ClearShotAction: ShortcutSpec?] = [
            .captureFullscreen: ShortcutSpec(carbonKeyCode: 20, carbonModifiers: 768),
            .captureArea: ShortcutSpec(carbonKeyCode: 21, carbonModifiers: 768),
            .allInOne: ShortcutSpec(carbonKeyCode: 23, carbonModifiers: 768),
        ]
        for (index, action) in ClearShotAction.allCases.enumerated() where !defaultActions.contains(action) {
            if index.isMultiple(of: 2) {
                defaults.set(false, forKey: legacyKey(action))
                expected[action] = .some(nil)
            } else {
                let spec = ShortcutSpec(carbonKeyCode: index, carbonModifiers: ShortcutSpec.control | ShortcutSpec.command)
                defaults.set(#"{"carbonKeyCode":\#(index),"carbonModifiers":\#(spec.carbonModifiers)}"#, forKey: legacyKey(action))
                expected[action] = spec
            }
        }

        #expect(migrate() == ClearShotAction.allCases.count)

        for action in ClearShotAction.allCases {
            #expect(store.shortcut(for: action) == expected[action]!, "\(action.rawValue)")
            #expect(defaults.object(forKey: legacyKey(action)) == nil, "\(action.rawValue): old key")
        }
        #expect(!defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("KeyboardShortcuts_") })
        #expect(log.lines.isEmpty)
    }

    @Test func theCountIsOnlyTheActionsThatMigrated() {
        defaults.set(#"{"carbonModifiers":768,"carbonKeyCode":21}"#, forKey: legacyKey(.recordScreen))   // migrates
        defaults.set(false, forKey: legacyKey(.captureArea))                                              // migrates
        defaults.set("junk", forKey: legacyKey(.selfTimer))                                               // skipped
        store.set(area, for: .captureWindow)
        defaults.set(#"{"carbonModifiers":768,"carbonKeyCode":21}"#, forKey: legacyKey(.captureWindow))  // the new key wins
        // .allInOne has no old key.

        #expect(migrate() == 2)
    }

    @Test func eachMigratedActionPostsOneChangeNotification() {
        // The migration runs before anything observes, so these are harmless; they come from writing through the store.
        let recorder = ChangeRecorder(center: center)
        defaults.set(#"{"carbonModifiers":768,"carbonKeyCode":21}"#, forKey: legacyKey(.recordScreen))
        defaults.set(false, forKey: legacyKey(.captureArea))
        defaults.set("junk", forKey: legacyKey(.selfTimer))

        migrate()

        #expect(recorder.posts.map(\.action) == ["captureArea", "recordScreen"])
    }

    @Test func onlyTheActionsOfTheAppAreTouched() {
        defaults.set(#"{"carbonModifiers":768,"carbonKeyCode":21}"#, forKey: "KeyboardShortcuts_someOtherName")
        defaults.set("kept", forKey: "shortcut")
        defaults.set(#"{"carbonModifiers":768,"carbonKeyCode":21}"#, forKey: legacyKey(.recordScreen))

        #expect(migrate() == 1)

        #expect(defaults.string(forKey: "KeyboardShortcuts_someOtherName") != nil)
        #expect(defaults.string(forKey: "shortcut") == "kept")
    }

    // MARK: Twice

    @Test func aSecondRunMigratesNothingAndChangesNothing() {
        defaults.set(#"{"carbonModifiers":768,"carbonKeyCode":21}"#, forKey: legacyKey(.recordScreen))
        defaults.set(false, forKey: legacyKey(.captureArea))
        defaults.set("junk", forKey: legacyKey(.selfTimer))
        #expect(migrate() == 2)

        let shortcuts = store.all()
        let stored = Dictionary(uniqueKeysWithValues: ClearShotAction.allCases.map { action in
            (action, defaults.object(forKey: newKey(action)).map { "\($0)" })
        })
        let recorder = ChangeRecorder(center: center)

        #expect(migrate() == 0)

        #expect(store.all() == shortcuts)
        for action in ClearShotAction.allCases {
            #expect(defaults.object(forKey: newKey(action)).map { "\($0)" } == stored[action]!, "\(action.rawValue)")
        }
        #expect(recorder.posts.isEmpty)

        // A change the user makes in between survives a second run, too.
        store.set(.commandShift(KeyCode.digit6), for: .recordScreen)
        #expect(migrate() == 0)
        #expect(store.shortcut(for: .recordScreen) == .commandShift(KeyCode.digit6))
    }
}
