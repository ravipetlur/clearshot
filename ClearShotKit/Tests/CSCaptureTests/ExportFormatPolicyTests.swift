import CSCore
import Testing
@testable import CSCapture

struct ExportFormatPolicyTests {
    @Test func transparentWindowShotsAvoidJPEG() {
        // The defaults: JPEG, and a transparent window background.
        #expect(ExportFormatPolicy.format(preferred: .jpeg, isTransparent: true) == .png)
    }

    @Test func otherwiseThePreferredFormatWins() {
        #expect(ExportFormatPolicy.format(preferred: .jpeg, isTransparent: false) == .jpeg)
        #expect(ExportFormatPolicy.format(preferred: .webp, isTransparent: true) == .webp)
        #expect(ExportFormatPolicy.format(preferred: .heic, isTransparent: true) == .heic)
    }
}
