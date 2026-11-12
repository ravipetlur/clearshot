import Testing
@testable import CSHistory

/// What the alert says when a change reached the capture but not the file saved from it.
struct SavedFileNoticeTests {
    private static let note = "The saved file isn't masked, and dragging or copying the file still uses it."

    @Test(arguments: [
        // Done says its own words, as before.
        ("Your edits are applied to the screenshot in ClearShot", true, nil,
         "Your edits are applied to the screenshot in ClearShot, but the saved file was edited in another app, so ClearShot left it alone."),
        ("Your edits are applied to the screenshot in ClearShot", false, nil,
         "Your edits are applied to the screenshot in ClearShot, but the saved file wasn't updated"),
        // So does a change to the image.
        ("The image changed", true, nil, "The image changed, but the saved file was edited in another app, so ClearShot left it alone."),
        ("The image changed", false, nil, "The image changed, but the saved file wasn't updated"),
        // A note is one more sentence.
        ("The masks are applied to the screenshot in ClearShot", true, note,
         "The masks are applied to the screenshot in ClearShot, but the saved file was edited in another app, so ClearShot left it alone. " + note),
        ("The masks are applied to the screenshot in ClearShot", false, note,
         "The masks are applied to the screenshot in ClearShot, but the saved file wasn't updated. " + note),
    ] as [(String, Bool, String?, String)])
    func theMessageSaysWhatChangedAndWhyTheSavedFileDidNot(change: String, editedElsewhere: Bool, note: String?, message: String) {
        #expect(SavedFileNotice.message(change: change, editedElsewhere: editedElsewhere, note: note) == message)
    }
}
