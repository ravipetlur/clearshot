import Testing
@testable import CSCapture

struct CaptureErrorTests {
    /// A failed save or folder suggests another export location and nothing else: where the capture went instead (the
    /// clipboard, a temporary file) is the router's note to say, not the error's.
    @Test func aSaveFailureSuggestsOnlyAnotherLocation() {
        for error in [CaptureError.cannotSave("/Volumes/Gone/Shot.png"), .cannotCreateFolder("/Volumes/Gone")] {
            #expect(error.recoverySuggestion == "Choose another export location in Settings › General.")
        }
    }
}
