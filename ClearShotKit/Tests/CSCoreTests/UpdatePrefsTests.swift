import CSTestSupport
import Foundation
import Testing
@testable import CSCore

/// The updater's three preferences: whether to check daily, when the last check was, and the version to skip.
@MainActor
final class UpdatePrefsTests {
    let throwaway = ThrowawayDefaults("update-prefs")
    let defaults: UserDefaults
    let prefs: Preferences

    init() {
        defaults = throwaway.defaults
        prefs = Preferences(defaults: defaults)
    }

    @Test func checkingAutomaticallyIsOnByDefault() {
        #expect(prefs[Prefs.updateCheckAutomatically] == true)
        #expect(prefs.hasValue(Prefs.updateCheckAutomatically) == false)
    }

    @Test func thereIsNoLastCheckOrSkippedVersionAtFirst() {
        #expect(prefs[Prefs.updateLastCheck] == nil)
        #expect(prefs[Prefs.updateSkippedVersion] == nil)
        #expect(prefs.hasValue(Prefs.updateLastCheck) == false)
        #expect(prefs.hasValue(Prefs.updateSkippedVersion) == false)
    }

    @Test func theKeysAreNamedForTheirSettings() {
        #expect(Prefs.updateCheckAutomatically.name == "updateCheckAutomatically")
        #expect(Prefs.updateLastCheck.name == "updateLastCheck")
        #expect(Prefs.updateSkippedVersion.name == "updateSkippedVersion")
    }

    @Test func theSettingRoundTrips() {
        prefs[Prefs.updateCheckAutomatically] = false
        #expect(prefs[Prefs.updateCheckAutomatically] == false)
        #expect(defaults.object(forKey: "updateCheckAutomatically") as? Bool == false)
        prefs[Prefs.updateCheckAutomatically] = true
        #expect(prefs[Prefs.updateCheckAutomatically] == true)
    }

    @Test func theLastCheckRoundTripsAsAnExactDate() {
        let when = Date(timeIntervalSince1970: 1_800_000_123.5)
        prefs[Prefs.updateLastCheck] = when
        #expect(prefs[Prefs.updateLastCheck] == when)
        // A plain date in the defaults, which `defaults read` prints.
        #expect(defaults.object(forKey: "updateLastCheck") as? Date == when)
    }

    @Test func theSkippedVersionRoundTripsAsText() {
        prefs[Prefs.updateSkippedVersion] = "1.2.1"
        #expect(prefs[Prefs.updateSkippedVersion] == "1.2.1")
        #expect(defaults.object(forKey: "updateSkippedVersion") as? String == "1.2.1")
    }

    @Test func settingNothingRemovesTheValue() {
        prefs[Prefs.updateLastCheck] = Date()
        prefs[Prefs.updateSkippedVersion] = "1.2.1"
        prefs[Prefs.updateLastCheck] = nil
        prefs[Prefs.updateSkippedVersion] = nil
        #expect(prefs[Prefs.updateLastCheck] == nil)
        #expect(prefs[Prefs.updateSkippedVersion] == nil)
        #expect(defaults.object(forKey: "updateLastCheck") == nil)
        #expect(defaults.object(forKey: "updateSkippedVersion") == nil)
    }

    /// Anything else in the defaults, which only another process could put there, reads as if nothing were stored.
    @Test func aValueOfTheWrongTypeCountsAsNone() {
        defaults.set("yesterday", forKey: "updateLastCheck")
        defaults.set(42, forKey: "updateSkippedVersion")
        defaults.set("yes", forKey: "updateCheckAutomatically")
        #expect(prefs[Prefs.updateLastCheck] == nil)
        #expect(prefs[Prefs.updateSkippedVersion] == nil)
        #expect(prefs[Prefs.updateCheckAutomatically] == true)
    }

    @Test func resettingBringsBackTheDefaults() {
        prefs[Prefs.updateCheckAutomatically] = false
        prefs[Prefs.updateLastCheck] = Date()
        prefs.reset(Prefs.updateCheckAutomatically)
        prefs.reset(Prefs.updateLastCheck)
        #expect(prefs[Prefs.updateCheckAutomatically] == true)
        #expect(prefs[Prefs.updateLastCheck] == nil)
    }

    // MARK: Optional keys

    /// An optional key has no value as its default, which `PrefKey.optional` says by its name.
    @Test func anOptionalKeyDefaultsToNone() {
        let key = PrefKey<String?>.optional("someOptional")
        #expect(key.name == "someOptional")
        #expect(key.defaultValue == nil)
        #expect(prefs[key] == nil)
        prefs[key] = "x"
        #expect(prefs[key] == "x")
        prefs[key] = nil
        #expect(prefs[key] == nil)
        #expect(!prefs.hasValue(key))
    }

    /// Why an optional key's default has to be none: setting none removes the key, and a removed key reads as its
    /// default, so a key made with another default can never be set to none.
    @Test func settingNoneOnAKeyWithAnotherDefaultReadsAsThatDefault() {
        let key = PrefKey<String?>("someOptional", default: "fallback")
        prefs[key] = "x"
        prefs[key] = nil
        #expect(prefs[key] == "fallback")
    }
}
