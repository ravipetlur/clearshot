import Testing
@testable import CSHistory

/// What the alert says when a change reached the capture but not the file saved from it.
struct SavedFileNoticeTests {
    @Test func doneSaysItsOwnWordsAsBefore() {
        let change = "Your edits are applied to the screenshot in ClearShot"
        #expect(SavedFileNotice.message(change: change, editedElsewhere: true)
                == "Your edits are applied to the screenshot in ClearShot, but the saved file was edited in another app, so ClearShot left it alone.")
        #expect(SavedFileNotice.message(change: change, editedElsewhere: false)
                == "Your edits are applied to the screenshot in ClearShot, but the saved file wasn't updated")
    }

    @Test func anImageChangeSaysItsOwnWordsAsBefore() {
        #expect(SavedFileNotice.message(change: "The image changed", editedElsewhere: true)
                == "The image changed, but the saved file was edited in another app, so ClearShot left it alone.")
        #expect(SavedFileNotice.message(change: "The image changed", editedElsewhere: false)
                == "The image changed, but the saved file wasn't updated")
    }

    @Test func aNoteIsOneMoreSentence() {
        let note = "The saved file isn't masked, and dragging or copying the file still uses it."
        let change = "The masks are applied to the screenshot in ClearShot"
        #expect(SavedFileNotice.message(change: change, editedElsewhere: true, note: note)
                == "The masks are applied to the screenshot in ClearShot, but the saved file was edited in another app, so ClearShot left it alone. \(note)")
        #expect(SavedFileNotice.message(change: change, editedElsewhere: false, note: note)
                == "The masks are applied to the screenshot in ClearShot, but the saved file wasn't updated. \(note)")
    }

    @Test func noNoteAddsNothing() {
        #expect(SavedFileNotice.message(change: "X", editedElsewhere: false, note: nil)
                == SavedFileNotice.message(change: "X", editedElsewhere: false))
    }
}
