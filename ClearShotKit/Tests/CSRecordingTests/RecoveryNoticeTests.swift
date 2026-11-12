import Testing
@testable import CSRecording

/// What the alert after a launch's recovery says: only what happened to the recording.
struct RecoveryNoticeTests {
    @Test func theMessageSaysWhatHappenedToTheRecording() {
        #expect(RecoveryNotice.title == "Recording recovered")
        let gifNote = "It was recorded as a GIF and has been kept as a video."
        let rows: [(saved: RecoveryNotice.Saved, gif: Bool, message: String)] = [
            (.toExportLocation, false,
             "ClearShot quit unexpectedly, but your recording was recovered and saved to the export location."),
            (.toExportLocation, true,
             "ClearShot quit unexpectedly, but your recording was recovered and saved to the export location. "
                + gifNote),
            // "Ask for name" holds the save until the thumbnail's name field is used.
            (.waitingForName, false,
             "ClearShot quit unexpectedly, but your recording was recovered. Name it in its thumbnail to save it to "
                + "the export location."),
            // Never "saved" when the save failed: it is in Capture History, and the reason follows.
            (.failed(reason: "Couldn't save to ~/Movies/Clips"), true,
             "ClearShot quit unexpectedly, but your recording was recovered to Capture History. It couldn't "
                + "be saved to the export location: Couldn't save to ~/Movies/Clips. " + gifNote),
        ]
        for row in rows {
            #expect(RecoveryNotice.message(saved: row.saved, recordedAsGIF: row.gif) == row.message)
        }
        #expect(!RecoveryNotice.message(saved: .failed(reason: "Couldn't save"), recordedAsGIF: false).contains("and saved"))
    }
}
