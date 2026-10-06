import Testing
@testable import CSRecording

struct RecordingWarningTests {
    /// Each warning's title, message and buttons, the default button first.
    @Test func stringsAreTheDecidedOnes() {
        let expected: [(RecordingWarning, String, String, [String])] = [
            (.microphoneMuted, "Microphone is muted",
             "The microphone seems to be muted. Keep recording?", ["Continue", "Stop"]),
            (.microphoneDisconnected, "Microphone Disconnected",
             "The microphone was disconnected. Keep recording without it, or stop?",
             ["Continue Without Audio", "Stop"]),
            // Information only: the stream restarts without system audio before the recording begins.
            (.systemAudioFailed, "Audio Recording Failed",
             "Unable to capture system audio. The recording continues without it.", ["OK"]),
            (.lowDiskBefore, "Your free disk space is low.",
             "The recording could stop partway through, and the file could be lost.", ["Record Anyway", "Cancel"]),
            (.diskFull, "The disk is almost full, so the recording stopped.",
             "ClearShot stopped it so the file wouldn't be lost. Free up disk space before the next recording.",
             ["OK"]),
            (.startFailed, "Screen recording couldn't start.",
             "Protected (DRM) video playing in another app can cause this. If it keeps happening, restart your Mac.",
             ["OK"]),
            (.streamStopped, "Screen Recording stopped unexpectedly.", "Screen recording ran into an error.", ["OK"]),
        ]
        for (warning, title, message, buttons) in expected {
            #expect(warning.title == title)
            #expect(warning.message == message)
            #expect(warning.buttons == buttons)
        }
    }

    /// Ten minutes at 30 Mbit/s is 2.25 GB.
    @Test func diskWarnsBelowTwoGigabytesOrTenMinutes() {
        #expect(DiskSpaceRule.warnBelow == 2_000_000_000)
        #expect(DiskSpaceRule.warnMinutes == 10)
        let rate = 30_000_000
        #expect(DiskSpaceRule.warnsBeforeRecording(available: 2_200_000_000, plannedBitsPerSecond: rate))
        #expect(!DiskSpaceRule.warnsBeforeRecording(available: 2_400_000_000, plannedBitsPerSecond: rate))
        #expect(DiskSpaceRule.warnsBeforeRecording(available: 1_900_000_000, plannedBitsPerSecond: rate))
        #expect(DiskSpaceRule.warnsBeforeRecording(available: 1_900_000_000, plannedBitsPerSecond: 1_000_000))
        #expect(!DiskSpaceRule.warnsBeforeRecording(available: 2_100_000_000, plannedBitsPerSecond: 1_000_000))
    }

    @Test func diskStopsBelowOneGigabyte() {
        #expect(DiskSpaceRule.stopBelow == 1_000_000_000)
        #expect(DiskSpaceRule.stopsRecording(available: 999_999_999))
        #expect(!DiskSpaceRule.stopsRecording(available: 1_000_000_000))
        #expect(!DiskSpaceRule.stopsRecording(available: 50_000_000_000))
    }

    /// Merging writes a second copy of the recording, so it needs the file's size and 100 MB to spare.
    @Test func mergingNeedsTheFileSizeAndAHundredMegabytes() {
        #expect(DiskSpaceRule.mergeHeadroom == 100_000_000)
        #expect(DiskSpaceRule.allowsMerge(available: 600_000_000, fileBytes: 500_000_000))
        #expect(!DiskSpaceRule.allowsMerge(available: 599_999_999, fileBytes: 500_000_000))
        // Unknown free space doesn't stop the merge.
        #expect(DiskSpaceRule.allowsMerge(available: nil, fileBytes: 500_000_000))
    }
}
