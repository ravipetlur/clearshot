import CoreGraphics
import CoreText
import Foundation
import Vision

/// Whether Vision's text recognition runs on this Mac, for the tests that read rendered pages with it. On a hosted CI
/// runner (a virtual Mac, which has no Neural Engine) every recognition throws `VisionError.unknownError`, whatever the
/// image, while Vision's image registration still works there. Those tests are skipped where it can't run:
///
///     @Test(.enabled("…") { await VisionTextRecognition.available })
///
/// The probe reads a rendered word with the requests `TextRecognizer` reads every tile with (accurate text recognition
/// with language correction and automatic language detection, and QR detection, in one perform). Recognition counts as
/// unavailable only when Vision throws: a wrong reading still counts as available, so the tests run and catch it.
public enum VisionTextRecognition {
    /// The probe's verdict, worked out once per test process. The first recognition after a rebuild loads Vision's
    /// models, which can take about half a minute; the probe takes that wait instead of the first test.
    public static var available: Bool {
        get async { await probe.value }
    }

    private static let probe = Task.detached(priority: .userInitiated) { await run() }

    private static func run() async -> Bool {
        // A word that can't be drawn says nothing about Vision: the tests run.
        guard let image = renderedWord("Probe") else { return true }
        do {
            _ = try await ImageRequestHandler(image).perform(textRequest(), qrRequest())
            return true
        } catch {
            // Which of the two requests fails, for the log of the run that skips the tests.
            let text = await outcome { _ = try await ImageRequestHandler(image).perform(textRequest()) }
            let qr = await outcome { _ = try await ImageRequestHandler(image).perform(qrRequest()) }
            print("Vision text recognition isn't available on this Mac: \(error). Text recognition alone: \(text); "
                + "QR detection alone: \(qr).")
            return false
        }
    }

    /// As `TextRecognizer` sets it up, with automatic language detection (what the tests use).
    private static func textRequest() -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        return request
    }

    private static func qrRequest() -> DetectBarcodesRequest {
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr]
        return request
    }

    private static func outcome(_ perform: () async throws -> Void) async -> String {
        do {
            try await perform()
            return "works"
        } catch {
            return "throws \(error)"
        }
    }

    /// `word` in black 72 pt Helvetica on white, 480 × 160 pixels.
    static func renderedWord(_ word: String) -> CGImage? {
        let (width, height) = (480, 160)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes = [kCTFontAttributeName as String: CTFontCreateWithName("Helvetica" as CFString, 72, nil),
                          kCTForegroundColorAttributeName as String: CGColor(gray: 0, alpha: 1)] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, word as CFString, attributes) else { return nil }
        context.textPosition = CGPoint(x: 40, y: 54)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        return context.makeImage()
    }
}
