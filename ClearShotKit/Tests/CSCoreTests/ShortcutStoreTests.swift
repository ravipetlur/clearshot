import CSTestSupport
import Foundation
import Testing
@testable import CSCore

final class ShortcutStoreTests {
    let throwaway = ThrowawayDefaults("shortcut-store")
    let defaults: UserDefaults
    let center = NotificationCenter()
    let store: ShortcutStore

    let fullscreen = ShortcutSpec.commandShift(KeyCode.digit3)
    let area = ShortcutSpec.commandShift(KeyCode.digit4)
    let allInOne = ShortcutSpec.commandShift(KeyCode.digit5)

    init() {
        defaults = throwaway.defaults
        store = ShortcutStore(defaults: defaults, notificationCenter: center, logger: silentLogger)
    }

    // MARK: Reading

    @Test func theDefaultComesBackWhenNothingIsStored() {
        #expect(store.shortcut(for: .captureFullscreen) == fullscreen)
        #expect(store.shortcut(for: .captureArea) == area)
        #expect(store.shortcut(for: .allInOne) == allInOne)
        #expect(store.shortcut(for: .recordScreen) == nil)
    }

    @Test func eachActionHasAKeyOfItsOwn() {
        #expect(ShortcutStore.key(for: .captureAreaAndCopy) == "shortcut.captureAreaAndCopy")
        #expect(ShortcutStore.key(for: .allInOne) == "shortcut.allInOne")
        for action in ClearShotAction.allCases {
            #expect(ShortcutStore.key(for: action) == "shortcut.\(action.rawValue)")
        }
        #expect(Set(ClearShotAction.allCases.map(ShortcutStore.key(for:))).count == ClearShotAction.allCases.count)
    }

    @Test func theChangeNotificationHasItsDocumentedName() {
        #expect(ShortcutStore.didChange == Notification.Name("ClearShotShortcutsDidChange"))
    }

    // MARK: Writing

    @Test func setThenGetRoundTrips() {
        let record = ShortcutSpec(carbonKeyCode: 15, carbonModifiers: ShortcutSpec.control | ShortcutSpec.option)
        store.set(record, for: .recordScreen)
        #expect(store.shortcut(for: .recordScreen) == record)

        // A shortcut can replace a default; the other actions keep theirs.
        let moved = ShortcutSpec.commandShift(KeyCode.digit6)
        store.set(moved, for: .captureArea)
        #expect(store.shortcut(for: .captureArea) == moved)
        #expect(store.shortcut(for: .allInOne) == allInOne)
        #expect(store.shortcut(for: .recordScreen) == record)
    }

    @Test func theStoredFormIsADictionaryInCarbonTerms() throws {
        store.set(ShortcutSpec(carbonKeyCode: 21, carbonModifiers: 768), for: .recordScreen)
        let stored = try #require(defaults.dictionary(forKey: "shortcut.recordScreen"))
        #expect(stored.count == 2)
        #expect(stored["keyCode"] as? Int == 21)
        #expect(stored["modifiers"] as? Int == 768)
        let keyCode = try #require(stored["keyCode"])
        #expect(!ShortcutStore.isBoolean(keyCode))
    }

    @Test func settingNilClearsEvenAnActionWithADefault() throws {
        store.set(nil, for: .captureArea)
        #expect(store.shortcut(for: .captureArea) == nil)
        let stored = try #require(defaults.object(forKey: "shortcut.captureArea"))
        #expect(ShortcutStore.isBoolean(stored))
        #expect(defaults.bool(forKey: "shortcut.captureArea") == false)
        // The others are not affected.
        #expect(store.shortcut(for: .allInOne) == allInOne)

        // A cleared shortcut can be set again.
        store.set(area, for: .captureArea)
        #expect(store.shortcut(for: .captureArea) == area)
    }

    @Test func resetGoesBackToTheDefault() {
        store.set(.commandShift(KeyCode.digit6), for: .captureArea)
        store.reset(.captureArea)
        #expect(store.shortcut(for: .captureArea) == area)
        #expect(defaults.object(forKey: "shortcut.captureArea") == nil)

        store.set(nil, for: .allInOne)
        store.reset(.allInOne)
        #expect(store.shortcut(for: .allInOne) == allInOne)

        // An action with no default goes back to none.
        store.set(.commandShift(KeyCode.digit6), for: .recordScreen)
        store.reset(.recordScreen)
        #expect(store.shortcut(for: .recordScreen) == nil)
        #expect(defaults.object(forKey: "shortcut.recordScreen") == nil)
    }

    @Test func resetAllGoesBackToTheDefaults() {
        store.set(nil, for: .captureArea)
        store.set(.commandShift(KeyCode.digit6), for: .allInOne)
        store.set(.commandShift(KeyCode.digit2), for: .recordScreen)
        store.set(.commandShift(KeyCode.digit2), for: .closeAllPins)

        store.resetAll()

        #expect(store.all() == [.captureFullscreen: fullscreen, .captureArea: area, .allInOne: allInOne])
        for action in ClearShotAction.allCases {
            #expect(defaults.object(forKey: ShortcutStore.key(for: action)) == nil)
        }
    }

    @Test func allListsEveryActionThatHasAShortcut() {
        #expect(store.all() == [.captureFullscreen: fullscreen, .captureArea: area, .allInOne: allInOne])

        // A cleared action drops out, even though it has a default.
        store.set(nil, for: .captureArea)
        #expect(store.all() == [.captureFullscreen: fullscreen, .allInOne: allInOne])

        // An action with no default appears once it has a shortcut, and only then.
        let record = ShortcutSpec.commandShift(KeyCode.digit2)
        store.set(record, for: .recordScreen)
        #expect(store.all() == [.captureFullscreen: fullscreen, .allInOne: allInOne, .recordScreen: record])
        store.set(nil, for: .recordScreen)
        #expect(store.all()[.recordScreen] == nil)
    }

    // MARK: Malformed values

    @Test func aMalformedStoredValueCountsAsAbsent() {
        let malformed: [Any] = [
            "⇧⌘4",
            #"{"keyCode":21,"modifiers":768}"#,
            7,
            0,
            1,
            true,
            [21, 768],
            [String: Any](),
            ["keyCode": 21],
            ["modifiers": 768],
            ["keyCode": "21", "modifiers": 768],
            ["keyCode": 21, "modifiers": "768"],
            ["keyCode": 21.5, "modifiers": 768],
            ["keyCode": 21, "modifiers": 768.0],
            ["keyCode": true, "modifiers": 768],
            ["keyCode": 21, "modifiers": false],
            ["carbonKeyCode": 21, "carbonModifiers": 768],
            ["keyCode": -1, "modifiers": 768],
            ["keyCode": 21, "modifiers": -256],
            ["keyCode": Int(UInt32.max) + 1, "modifiers": 768],
        ]
        for value in malformed {
            defaults.set(value, forKey: "shortcut.captureArea")
            defaults.set(value, forKey: "shortcut.recordScreen")
            #expect(store.shortcut(for: .captureArea) == area, "stored \(value) for an action with a default")
            #expect(store.shortcut(for: .recordScreen) == nil, "stored \(value) for an action with none")
        }
    }

    @Test func aMalformedValueIsLeftInPlaceUntilTheActionIsWritten() {
        defaults.set("junk", forKey: "shortcut.captureArea")
        #expect(store.shortcut(for: .captureArea) == area)
        #expect(defaults.string(forKey: "shortcut.captureArea") == "junk")

        store.set(.commandShift(KeyCode.digit6), for: .captureArea)
        #expect(store.shortcut(for: .captureArea) == .commandShift(KeyCode.digit6))
    }

    @Test func aMalformedValueIsLoggedOncePerKey() {
        let log = TemporaryLog()
        let store = ShortcutStore(defaults: defaults, notificationCenter: center, logger: log.logger)

        // Nothing is logged for stored values that are fine, cleared or absent.
        store.set(.commandShift(KeyCode.digit6), for: .captureWindow)
        store.set(nil, for: .selfTimer)
        _ = store.all()
        #expect(log.lines.isEmpty)

        defaults.set("junk", forKey: "shortcut.captureArea")
        defaults.set(5, forKey: "shortcut.recordScreen")
        for _ in 0..<3 {
            _ = store.shortcut(for: .captureArea)
            _ = store.all()
        }
        _ = store.shortcut(for: .recordScreen)
        _ = store.shortcut(for: .recordScreen)

        #expect(log.lines.count == 2)
        #expect(log.lines.filter { $0.contains("captureArea") }.count == 1)
        #expect(log.lines.filter { $0.contains("recordScreen") }.count == 1)
        #expect(log.lines.allSatisfy { $0.contains("[WARN] [hotkeys]") })
    }

    // MARK: Change notifications

    @Test func everyWritePostsOneChangeNotificationNamingTheAction() {
        let recorder = ChangeRecorder(center: center)
        let spec = ShortcutSpec.commandShift(KeyCode.digit6)

        store.set(spec, for: .recordScreen)
        #expect(recorder.posts.map(\.action) == ["recordScreen"])

        store.set(nil, for: .captureArea)
        #expect(recorder.posts.map(\.action) == ["recordScreen", "captureArea"])

        store.reset(.recordScreen)
        #expect(recorder.posts.map(\.action) == ["recordScreen", "captureArea", "recordScreen"])

        // Each of those carries the action and nothing else.
        #expect(recorder.posts.allSatisfy { $0.userInfoCount == 1 })
    }

    @Test func resetAllPostsOneNotificationWithoutAnAction() {
        let recorder = ChangeRecorder(center: center)
        store.set(.commandShift(KeyCode.digit6), for: .recordScreen)
        store.resetAll()
        // The first post names its action; the second, for "all", has no user info at all.
        #expect(recorder.posts.map(\.action) == ["recordScreen", nil])
        #expect(recorder.posts.map(\.userInfoCount) == [1, 0])
    }

    @Test func aWriteThatChangesNothingStillPostsOnce() {
        let recorder = ChangeRecorder(center: center)
        store.reset(.recordScreen)
        store.resetAll()
        store.set(area, for: .captureArea)
        #expect(recorder.posts.map(\.action) == ["recordScreen", nil, "captureArea"])
    }

    @Test func theNotificationComesAfterTheWrite() {
        let store = self.store
        let recorder = ChangeRecorder(center: center, probe: { store.shortcut(for: .recordScreen) })
        let spec = ShortcutSpec.commandShift(KeyCode.digit6)

        store.set(spec, for: .recordScreen)
        store.set(nil, for: .recordScreen)
        store.reset(.recordScreen)
        #expect(recorder.posts.map(\.seen) == [spec, nil, nil])
    }

    @Test func readingPostsNothing() {
        let recorder = ChangeRecorder(center: center)
        _ = store.shortcut(for: .captureArea)
        _ = store.all()
        #expect(recorder.posts.isEmpty)
    }
}
