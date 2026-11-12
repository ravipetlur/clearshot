import CSCapture
import CSCore
import CSTestSupport
import Testing
@testable import CSRecording

@MainActor
struct RecordingPrefsTests {
    @Test func theEnumsAreStoredByTheirRawValues() {
        withThrowawayDefaults("recording") { defaults in
            let prefs = Preferences(defaults: defaults)
            // The enums are stored by their raw values, and read back.
            prefs[Prefs.recordingControlsPosition] = .topOfScreen
            prefs[Prefs.recordingMaxResolution] = .res1080p
            prefs[Prefs.recordingLastMode] = .gif
            #expect(defaults.string(forKey: "recordingControlsPosition") == "topOfScreen")
            #expect(prefs[Prefs.recordingMaxResolution] == .res1080p)
            #expect(prefs[Prefs.recordingLastMode] == .gif)
        }
    }

    @Test func resettingAllWarningDialogsBringsBackCSCoresAndTheRecordingsConfirmations() {
        #expect(Prefs.allWarningDialogs.map(\.name) == ["confirmCloseAllOverlays", "confirmHistoryDelete",
                                                        "confirmCloseRecording", "confirmDeleteRecording",
                                                        "confirmRestartRecording"])
        withThrowawayDefaults("recording-warnings") { defaults in
            let prefs = Preferences(defaults: defaults)
            for key in Prefs.allWarningDialogs { prefs[key] = false }
            Prefs.allWarningDialogs.forEach { prefs.reset($0) }
            for key in Prefs.allWarningDialogs { #expect(prefs[key], "\(key.name)") }
        }
    }
}
