import CSCore
import CSTestSupport
import Testing
@testable import CSAPI

@MainActor
struct APIPrefsTests {
    /// The API is on and hasn't asked yet, so the first command from outside asks. Neither key is a warning dialog, so
    /// Reset All Warning Dialogs (CSRecording) can't name them.
    @Test func defaultsAreAllowedAndNotAsked() {
        withThrowawayDefaults("api") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(Prefs.allowURLSchemeAPI.name == "allowURLSchemeAPI")
            #expect(Prefs.didAskAboutURLSchemeAPI.name == "didAskAboutURLSchemeAPI")
            #expect(prefs[Prefs.allowURLSchemeAPI])
            #expect(!prefs[Prefs.didAskAboutURLSchemeAPI])

            prefs[Prefs.allowURLSchemeAPI] = false
            prefs[Prefs.didAskAboutURLSchemeAPI] = true
            #expect(defaults.object(forKey: "allowURLSchemeAPI") as? Bool == false)
            #expect(defaults.object(forKey: "didAskAboutURLSchemeAPI") as? Bool == true)
        }
    }
}
