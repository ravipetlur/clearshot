import CoreGraphics
import CSCore
import CSTestSupport
import Foundation
import Testing
@testable import CSOCR

struct TextOutputTests {
    private func line(_ text: String, row: Int) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: 20, y: 20 + 40 * row, width: 400, height: 30))
    }

    @Test func qrPayloadsWinOverRecognizedText() {
        let result = OCRResult(lines: [line("Scan me", row: 0), line("to visit", row: 1)],
                               qrPayloads: ["https://clearshot.test/qr", "WIFI:S:Home;T:WPA;;\n"])
        // One payload per line whatever the line-break setting; the whole text is trimmed.
        #expect(TextOutput.text(for: result, keepLineBreaks: false) == "https://clearshot.test/qr\nWIFI:S:Home;T:WPA;;")
        #expect(TextOutput.text(for: result, keepLineBreaks: true) == "https://clearshot.test/qr\nWIFI:S:Home;T:WPA;;")
    }

    @Test func withoutQRTheAssembledTextIsUsed() {
        let result = OCRResult(lines: [line("  More infor-", row: 0), line("mation here  ", row: 1)])
        #expect(TextOutput.text(for: result, keepLineBreaks: true) == "More infor-\nmation here")
        #expect(TextOutput.text(for: result, keepLineBreaks: false) == "More information here")
        #expect(TextOutput.text(for: OCRResult(), keepLineBreaks: true).isEmpty)
    }

    @Test func aWholeURLIsALink() {
        #expect(TextOutput.singleLink(in: "  https://example.com/a?b=1 ") == URL(string: "https://example.com/a?b=1"))
        #expect(TextOutput.singleLink(in: "http://example.com/docs\n") == URL(string: "http://example.com/docs"))
    }

    @Test func aBareDomainIsALink() {
        let link = TextOutput.singleLink(in: "example.com")
        #expect(link?.scheme == "http")
        #expect(link?.host() == "example.com")
    }

    @Test func aURLInsideASentenceIsNotALink() {
        #expect(TextOutput.singleLink(in: "See https://example.com for more") == nil)
        #expect(TextOutput.singleLink(in: "Docs: https://example.com/docs") == nil)
    }

    @Test func twoURLsAreNotALink() {
        #expect(TextOutput.singleLink(in: "https://example.com https://example.org") == nil)
        #expect(TextOutput.singleLink(in: "https://example.com\nhttps://example.org") == nil)
    }

    @Test func anEmailAddressIsNotALink() {
        #expect(TextOutput.singleLink(in: "someone@example.com") == nil)
        #expect(TextOutput.singleLink(in: "mailto:someone@example.com") == nil)
        #expect(TextOutput.singleLink(in: "") == nil)
        #expect(TextOutput.singleLink(in: "Just some words") == nil)
    }

    @Test func aLinkIsOfferedOnlyWithDetectLinksOnAndNoCaptureUnderWay() {
        let url = "https://example.com/a"
        #expect(TextOutput.linkToOffer(in: url, detectsLinks: true, isCapturing: false) == URL(string: url))
        #expect(TextOutput.linkToOffer(in: url, detectsLinks: false, isCapturing: false) == nil)
        // A capture's overlay sits above alerts: the prompt would open under it.
        #expect(TextOutput.linkToOffer(in: url, detectsLinks: true, isCapturing: true) == nil)
        #expect(TextOutput.linkToOffer(in: "See \(url) for more", detectsLinks: true, isCapturing: false) == nil)
    }

    @MainActor @Test func prefsDefaults() {
        withThrowawayDefaults("ocr") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(prefs[Prefs.textRecognitionKeepLineBreaks])
            #expect(prefs[Prefs.textRecognitionAutoDetectLanguage])
            #expect(prefs[Prefs.textRecognitionPrimaryLanguage] == "en-US")
            #expect(prefs[Prefs.textRecognitionDetectLinks])
            #expect(TextRecognitionOptions(preferences: prefs) == TextRecognitionOptions(automaticallyDetectsLanguage: true, primaryLanguage: "en-US"))

            prefs[Prefs.textRecognitionAutoDetectLanguage] = false
            prefs[Prefs.textRecognitionPrimaryLanguage] = "ja-JP"
            #expect(TextRecognitionOptions(preferences: prefs) == TextRecognitionOptions(automaticallyDetectsLanguage: false, primaryLanguage: "ja-JP"))
        }
    }
}
