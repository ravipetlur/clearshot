import Testing
@testable import CSRecording

/// What the alert after a launch's recovery says: only what happened to the recording.
struct RecoveryNoticeTests {
    @Test func aSavedRecordingIsInTheExportLocation() {
        #expect(RecoveryNotice.title == "Recording recovered")
        #expect(RecoveryNotice.message(saved: .toExportLocation, recordedAsGIF: false)
            == "ClearShot quit unexpectedly, but your recording was recovered and saved to the export location.")
    }

    @Test func aGIFRecordingSaysItWasKeptAsAVideo() {
        #expect(RecoveryNotice.message(saved: .toExportLocation, recordedAsGIF: true)
            == "ClearShot quit unexpectedly, but your recording was recovered and saved to the export location. "
            + "It was recorded as a GIF and has been kept as a video.")
    }

    /// "Ask for name" holds the save until the thumbnail's name field is used.
    @Test func aSaveWaitingForANameSaysSo() {
        #expect(RecoveryNotice.message(saved: .waitingForName, recordedAsGIF: false)
            == "ClearShot quit unexpectedly, but your recording was recovered. Name it in its thumbnail to save it to "
            + "the export location.")
    }

    /// Never "saved" when the save failed: it is in Capture History, and the reason follows.
    @Test func aFailedSaveIsReportedWithItsReason() {
        let message = RecoveryNotice.message(saved: .failed(reason: "Couldn't save to ~/Movies/Clips"), recordedAsGIF: true)
        #expect(message == "ClearShot quit unexpectedly, but your recording was recovered to Capture History. It couldn't "
            + "be saved to the export location: Couldn't save to ~/Movies/Clips. "
            + "It was recorded as a GIF and has been kept as a video.")
        #expect(!message.contains("and saved"))
    }
}
