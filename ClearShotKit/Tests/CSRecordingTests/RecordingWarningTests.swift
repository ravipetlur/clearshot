import Testing
@testable import CSRecording

struct RecordingWarningTests {
    /// Each warning's buttons, the default button first.
    @Test func theButtonsComeInTheirOrderTheDefaultFirst() {
        let expected: [(RecordingWarning, [String])] = [
            (.microphoneMuted, ["Continue", "Stop"]),
            (.microphoneDisconnected, ["Continue Without Audio", "Stop"]),
            // Information only: the stream restarts without system audio before the recording begins.
            (.systemAudioFailed, ["OK"]),
            (.lowDiskBefore, ["Record Anyway", "Cancel"]),
            (.diskFull, ["OK"]),
            (.startFailed, ["OK"]),
            (.streamStopped, ["OK"]),
        ]
        for (warning, buttons) in expected { #expect(warning.buttons == buttons, "\(warning)") }
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
