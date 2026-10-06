import CSCapture
import CSCore
import CSTestSupport
import Testing
@testable import CSRecording

@MainActor
struct RecordingPrefsTests {
    @Test func defaultsAreTheDecidedOnes() {
        withThrowawayDefaults("recording") { defaults in
            let prefs = Preferences(defaults: defaults)
            let on: [PrefKey<Bool>] = [
                Prefs.recordingShowControls, Prefs.recordingShowTimeInMenuBar, Prefs.recordingDimScreen,
                Prefs.recordingCountdown, Prefs.recordingDoNotDisturb, Prefs.recordingKeepDisplayAwake,
                Prefs.recordingRememberSelection, Prefs.recordingShowCursor, Prefs.recordingHighlightClicks,
                Prefs.clickHighlightAnimates, Prefs.recordingScaleRetinaTo1x, Prefs.recordingHardwareEncoding,
                Prefs.gifOptimize, Prefs.confirmDeleteRecording, Prefs.confirmRestartRecording,
            ]
            for key in on { #expect(prefs[key], "\(key.name)") }
            let off: [PrefKey<Bool>] = [Prefs.recordingSystemAudio, Prefs.recordingMono, Prefs.stopRecordingHintShown]
            for key in off { #expect(!prefs[key], "\(key.name)") }

            #expect(prefs[Prefs.recordingControlsPosition] == .belowArea)
            #expect(prefs[Prefs.clickHighlightSize] == .medium)
            #expect(prefs[Prefs.clickHighlightColor] == .accent)
            #expect(prefs[Prefs.clickHighlightStyle] == .outline)
            #expect(prefs[Prefs.recordingFrameRate] == 60)
            #expect(prefs[Prefs.gifFrameRate] == 60)
            #expect(prefs[Prefs.gifQuality] == 100)
            #expect(prefs[Prefs.recordingMaxResolution] == .original)
            #expect(prefs[Prefs.gifMaxSize] == .width800)
            #expect(prefs[Prefs.recordingMicrophoneID] == "")
            #expect(prefs[Prefs.recordingAudioTracks] == .single)
            #expect(prefs[Prefs.recordingMergeMicVolume] == 1.0)
            #expect(prefs[Prefs.recordingMergeSystemVolume] == 1.0)
            #expect(prefs[Prefs.recordingLastArea] == .none)
            #expect(prefs[Prefs.recordingRatio] == .freeform)
            #expect(prefs[Prefs.recordingLastMode] == .video)

            // The enums are stored by their raw values, and read back.
            prefs[Prefs.recordingControlsPosition] = .topOfScreen
            prefs[Prefs.recordingMaxResolution] = .res1080p
            prefs[Prefs.recordingLastMode] = .gif
            #expect(defaults.string(forKey: "recordingControlsPosition") == "topOfScreen")
            #expect(prefs[Prefs.recordingMaxResolution] == .res1080p)
            #expect(prefs[Prefs.recordingLastMode] == .gif)
        }
    }

    @Test func frameRateChoicesAreTheDecidedOnes() {
        #expect(Prefs.recordingFrameRateChoices == [60, 50, 30, 25, 24, 15])
        #expect(Prefs.gifFrameRateChoices == [60, 50, 30, 25, 20, 15, 10])
    }

    @Test func warningDialogsListBothConfirmations() {
        #expect(Prefs.recordingWarningDialogs.map(\.name) == ["confirmDeleteRecording", "confirmRestartRecording"])
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

    @Test func maximumResolutionsAndPositionsHaveTheirTitlesAndSides() {
        #expect(RecordingMaxResolution.allCases.map(\.title) == ["Original", "4K", "1440p", "1080p", "720p", "480p"])
        #expect(RecordingMaxResolution.allCases.map(\.longSide) == [nil, 3840, 2560, 1920, 1280, 854])
        #expect(RecordingControlsPosition.allCases.map(\.title)
            == ["Below the recording area", "Top of the screen", "Bottom of the screen"])
    }
}
