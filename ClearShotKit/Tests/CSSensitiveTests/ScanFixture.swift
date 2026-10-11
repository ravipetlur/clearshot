import CoreGraphics
import CoreText
import Foundation

/// A page rendered for the scanner's tests: text drawn with CoreText, black on white, positions and sizes in pixels with a top-left
/// origin. `Drawn` knows where each stretch of a line it drew is, from CoreText's own offsets, so a test can check a box against
/// the pixels the text is on.
///
/// Whether the text is drawn with font smoothing is the page's own, `smoothing`, and not the Mac's: a Mac whose "font smoothing"
/// default is off would otherwise draw every page of every run unsmoothed (and one with it on, smoothed), and a test run on both
/// would be two different tests. The tests that read the pixels back (`inkBox(in:)`) run with it on and off.
final class ScanFixture {
    let width: Int
    let height: Int
    private let context: CGContext

    init(width: Int, height: Int, smoothing: Bool = true) {
        self.width = width
        self.height = height
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setAllowsFontSmoothing(smoothing)
        context.setShouldSmoothFonts(smoothing)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// A line drawn on the page.
    struct Drawn {
        let text: String
        let x: CGFloat
        let top: CGFloat
        fileprivate let line: CTLine
        let ascent: CGFloat
        let descent: CGFloat

        /// The line's box: from the top of its tallest letters to the foot of its lowest.
        var rect: CGRect {
            CGRect(x: x, y: top, width: CTLineGetTypographicBounds(line, nil, nil, nil), height: ascent + descent)
        }

        /// Where the first `span` of the line is, by CoreText's offsets for its first and last characters.
        func rect(of span: String) -> CGRect {
            guard let range = text.range(of: span) else { preconditionFailure("\(span) is not in the line") }
            let characters = NSRange(range, in: text)
            let start = CTLineGetOffsetForStringIndex(line, characters.location, nil)
            let end = CTLineGetOffsetForStringIndex(line, characters.location + characters.length, nil)
            return CGRect(x: x + start, y: top, width: end - start, height: ascent + descent)
        }
    }

    /// Draws `string` black, its top at `top` and its left edge at `x`, in the system font (or the fixed-width one), `size`
    /// pixels.
    @discardableResult
    func text(_ string: String, x: CGFloat, top: CGFloat, size: CGFloat, monospaced: Bool = false) -> Drawn {
        let font = CTFontCreateUIFontForLanguage(monospaced ? .userFixedPitch : .system, size, nil)!
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        context.textPosition = CGPoint(x: x, y: CGFloat(height) - top - ascent)
        CTLineDraw(line, context)
        return Drawn(text: string, x: x, top: top, line: line, ascent: ascent, descent: descent)
    }

    func image() -> CGImage {
        context.makeImage()!
    }

    /// The smallest rectangle (pixels, top-left origin) holding every pixel of `region` that isn't pure white, the faint ones at
    /// the edges of the letters included: where the text's ink is. Nil when the region has none.
    func inkBox(in region: CGRect) -> CGRect? {
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let area = region.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !area.isNull, !area.isEmpty else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                // Row 0 of a bitmap context's memory is the top of the picture.
                let index = y * context.bytesPerRow + x * 4
                guard bytes[index] < 255 || bytes[index + 1] < 255 || bytes[index + 2] < 255 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
