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

    @Test(arguments: [
        // A whole URL is a link, and so is a bare domain.
        ("  https://example.com/a?b=1 ", "https://example.com/a?b=1"),
        ("http://example.com/docs\n", "http://example.com/docs"),
        ("example.com", "http://example.com"),
        // A URL inside a sentence is not.
        ("See https://example.com for more", nil),
        ("Docs: https://example.com/docs", nil),
        // Nor are two URLs.
        ("https://example.com https://example.org", nil),
        ("https://example.com\nhttps://example.org", nil),
        // Nor an email address, or text with no link.
        ("someone@example.com", nil),
        ("mailto:someone@example.com", nil),
        ("", nil),
        ("Just some words", nil),
    ] as [(String, String?)])
    func onlyTextThatIsOneWholeWebAddressIsALink(text: String, link: String?) {
        #expect(TextOutput.singleLink(in: text)?.absoluteString == link)
    }

    @Test func aLinkIsOfferedOnlyWithDetectLinksOnAndNoCaptureUnderWay() {
        let url = "https://example.com/a"
        #expect(TextOutput.linkToOffer(in: url, detectsLinks: true, isCapturing: false) == URL(string: url))
        #expect(TextOutput.linkToOffer(in: url, detectsLinks: false, isCapturing: false) == nil)
        // A capture's overlay sits above alerts: the prompt would open under it.
        #expect(TextOutput.linkToOffer(in: url, detectsLinks: true, isCapturing: true) == nil)
        #expect(TextOutput.linkToOffer(in: "See \(url) for more", detectsLinks: true, isCapturing: false) == nil)
    }

    @MainActor @Test func theOptionsComeFromThePreferences() {
        withThrowawayDefaults("ocr") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(TextRecognitionOptions(preferences: prefs) == TextRecognitionOptions(automaticallyDetectsLanguage: true, primaryLanguage: "en-US"))

            prefs[Prefs.textRecognitionAutoDetectLanguage] = false
            prefs[Prefs.textRecognitionPrimaryLanguage] = "ja-JP"
            #expect(TextRecognitionOptions(preferences: prefs) == TextRecognitionOptions(automaticallyDetectsLanguage: false, primaryLanguage: "ja-JP"))
        }
    }
}
