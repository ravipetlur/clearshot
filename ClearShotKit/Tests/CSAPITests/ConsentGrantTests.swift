import CSCore
import CSTestSupport
import Foundation
import Testing
@testable import CSAPI

/// A grant kept in memory; the tests never touch the real Keychain.
@MainActor
final class MemoryConsentStore: ConsentStore {
    var granted = false
    /// The Keychain refused the write.
    var failsToGrant = false

    var isGranted: Bool { granted }

    func grant() -> Bool {
        guard !failsToGrant else { return false }
        granted = true
        return true
    }

    func revoke() {
        granted = false
    }
}

/// The consent to run other apps' commands lives in a store only ClearShot can write (the Keychain), so writing
/// ClearShot's defaults (`defaults write …`) can only take permission away, never grant it. The effective permission is
/// the grant and the "Allow URL scheme API" setting together; "asked" is only a flag.
@MainActor
struct ConsentGrantTests {
    let ownPID: Int32 = 123
    let raycast = SenderFacts(pid: 500, bundleID: "com.raycast.macos", name: "Raycast", auditToken: nil)

    func withConsent(_ body: (Preferences, MemoryConsentStore) -> Void) {
        withThrowawayDefaults("consent") { defaults in
            body(Preferences(defaults: defaults), MemoryConsentStore())
        }
    }

    func decide(_ preferences: Preferences, _ store: MemoryConsentStore) -> URLConsent.Decision {
        URLConsent.decide(preferences: preferences, store: store, sender: raycast, ownPID: ownPID)
    }

    @Test func havingBeenAskedIsNoGrant() {
        withConsent { preferences, store in
            preferences[Prefs.didAskAboutURLSchemeAPI] = true
            #expect(decide(preferences, store) == .ask)
        }
    }

    @Test func theSettingOnIsNoGrant() {
        withConsent { preferences, store in
            preferences[Prefs.allowURLSchemeAPI] = true
            #expect(decide(preferences, store) == .ask)
        }
    }

    @Test func aGrantWithTheSettingOffDrops() {
        withConsent { preferences, store in
            store.granted = true
            preferences[Prefs.allowURLSchemeAPI] = false
            #expect(decide(preferences, store) == .drop)
        }
    }

    @Test func aGrantWithTheSettingOnRuns() {
        withConsent { preferences, store in
            store.granted = true
            preferences[Prefs.allowURLSchemeAPI] = true
            #expect(decide(preferences, store) == .run)
        }
    }

    /// Whatever the defaults say, nothing runs without the grant; with it, the defaults can only turn it off.
    @Test func forgedDefaultsCanOnlyTakePermissionAway() {
        withConsent { preferences, store in
            for granted in [false, true] {
                store.granted = granted
                for allows in [false, true] {
                    for didAsk in [false, true] {
                        preferences[Prefs.allowURLSchemeAPI] = allows
                        preferences[Prefs.didAskAboutURLSchemeAPI] = didAsk
                        let decision = decide(preferences, store)
                        #expect((decision == .run) == (granted && allows), "\(granted) \(allows) \(didAsk)")
                    }
                }
            }
        }
    }

    @Test func ourOwnProcessNeedsNoGrant() {
        withConsent { preferences, store in
            let us = SenderFacts(pid: ownPID, bundleID: nil, name: nil, auditToken: nil)
            preferences[Prefs.allowURLSchemeAPI] = false
            #expect(URLConsent.decide(preferences: preferences, store: store, sender: us, ownPID: ownPID) == .run)
        }
    }

    /// Allow writes the grant and turns the setting on; Don't Allow removes the grant and turns it off. Either way the
    /// person has been asked.
    @Test func allowGrantsAndDontAllowRevokes() {
        withConsent { preferences, store in
            #expect(URLConsent.record(allowed: true, preferences: preferences, store: store))
            #expect(store.granted)
            #expect(preferences[Prefs.allowURLSchemeAPI])
            #expect(preferences[Prefs.didAskAboutURLSchemeAPI])
            #expect(decide(preferences, store) == .run)

            #expect(URLConsent.record(allowed: false, preferences: preferences, store: store))
            #expect(!store.granted)
            #expect(!preferences[Prefs.allowURLSchemeAPI])
            #expect(preferences[Prefs.didAskAboutURLSchemeAPI])
            #expect(decide(preferences, store) == .drop)
        }
    }

    /// A grant the Keychain won't store isn't one: the next command asks again.
    @Test func aGrantThatCantBeStoredIsntAllowed() {
        withConsent { preferences, store in
            store.failsToGrant = true
            #expect(!URLConsent.record(allowed: true, preferences: preferences, store: store))
            #expect(decide(preferences, store) == .ask)
            #expect(URLConsent.setting(preferences: preferences, store: store) == .asks)
        }
    }

    /// Settings › Advanced's switch writes or removes the grant, and shows what the next command meets: on while
    /// commands run or ask, with "asks" until the person has allowed them; off only while they are ignored, so "Turn it
    /// off to ignore them" holds from the first launch.
    @Test func theSettingsSwitchShowsWhatTheNextCommandMeets() {
        withConsent { preferences, store in
            // On by default, but nothing is granted until the person says so: the next command asks.
            #expect(preferences[Prefs.allowURLSchemeAPI])
            #expect(URLConsent.setting(preferences: preferences, store: store) == .asks)
            #expect(URLConsent.Setting.asks.isOn)
            #expect(decide(preferences, store) == .ask)

            // Off from there ignores commands without ever asking.
            #expect(URLConsent.setAllowed(false, preferences: preferences, store: store))
            #expect(!store.granted)
            #expect(!preferences[Prefs.allowURLSchemeAPI])
            #expect(URLConsent.setting(preferences: preferences, store: store) == .off)
            #expect(!URLConsent.Setting.off.isOn)
            #expect(decide(preferences, store) == .drop)

            #expect(URLConsent.setAllowed(true, preferences: preferences, store: store))
            #expect(store.granted)
            #expect(preferences[Prefs.allowURLSchemeAPI])
            #expect(preferences[Prefs.didAskAboutURLSchemeAPI])
            #expect(URLConsent.setting(preferences: preferences, store: store) == .allowed)
            #expect(URLConsent.Setting.allowed.isOn)
            #expect(decide(preferences, store) == .run)

            // A grant lost from the Keychain asks again, and the switch says so.
            store.revoke()
            #expect(URLConsent.setting(preferences: preferences, store: store) == .asks)
            #expect(decide(preferences, store) == .ask)
            // A grant with the setting off (written in the defaults) is off.
            store.granted = true
            preferences[Prefs.allowURLSchemeAPI] = false
            #expect(URLConsent.setting(preferences: preferences, store: store) == .off)
        }
        #expect(URLConsent.asksCaption == "Asks the first time an app sends a command.")
    }
}
