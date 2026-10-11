import CSCore
import CSTestSupport
import Foundation
import Testing
@testable import CSSensitive

/// The two preferences of the secrets check: the master switch and the kinds Settings left on.
struct SensitivePrefsTests {
    @MainActor @Test func theCheckIsOnForAllKindsUntilSettingsSaysOtherwise() {
        withThrowawayDefaults("sensitive-defaults") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(prefs[Prefs.sensitiveCheckEnabled])
            #expect(prefs[Prefs.sensitiveKinds] == .all)
            #expect(!prefs.hasValue(Prefs.sensitiveCheckEnabled))
            #expect(!prefs.hasValue(Prefs.sensitiveKinds))
        }
    }

    @MainActor @Test func theSwitchAndTheKindsAreRemembered() {
        withThrowawayDefaults("sensitive-roundtrip") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs[Prefs.sensitiveCheckEnabled] = false
            prefs[Prefs.sensitiveKinds] = [.contact, .cards]
            let again = Preferences(defaults: defaults)
            #expect(!again[Prefs.sensitiveCheckEnabled])
            #expect(again[Prefs.sensitiveKinds] == [.contact, .cards])
        }
    }

    @MainActor @Test func theKindsAreStoredAsTheirRawValueSoDefaultsReadShowsANumber() {
        withThrowawayDefaults("sensitive-raw") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs[Prefs.sensitiveKinds] = [.keysAndTokens, .ipAddresses]
            #expect(defaults.object(forKey: "sensitiveKinds") as? Int == SensitiveKinds([.keysAndTokens, .ipAddresses]).rawValue)
            #expect(Prefs.sensitiveKinds.name == "sensitiveKinds")
            #expect(Prefs.sensitiveCheckEnabled.name == "sensitiveCheckEnabled")
        }
    }

    @MainActor @Test func noKindsAtAllIsAValueNotAMissingOne() {
        // Every category switched off: the scan has nothing to look for. It must not fall back to all.
        withThrowawayDefaults("sensitive-none") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs[Prefs.sensitiveKinds] = []
            #expect(prefs[Prefs.sensitiveKinds].isEmpty)
            #expect(prefs.hasValue(Prefs.sensitiveKinds))
        }
    }

    @MainActor @Test func bitsThatAreNoKindAreDropped() {
        withThrowawayDefaults("sensitive-unknown") { defaults in
            let prefs = Preferences(defaults: defaults)
            defaults.set(SensitiveKinds.cards.rawValue | (1 << 20), forKey: "sensitiveKinds")
            #expect(prefs[Prefs.sensitiveKinds] == .cards)
            defaults.set(-1, forKey: "sensitiveKinds")
            #expect(prefs[Prefs.sensitiveKinds] == .all)
        }
    }

    @MainActor @Test func aValueOfTheWrongTypeFallsBackToTheDefault() {
        withThrowawayDefaults("sensitive-wrongtype") { defaults in
            let prefs = Preferences(defaults: defaults)
            defaults.set("contact", forKey: "sensitiveKinds")
            defaults.set("yes please", forKey: "sensitiveCheckEnabled")
            #expect(prefs[Prefs.sensitiveKinds] == .all)
            #expect(prefs[Prefs.sensitiveCheckEnabled])
        }
    }
}
