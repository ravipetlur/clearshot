import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation

/// A rendered test page: text drawn with CoreText (Helvetica 26 pt, black on white unless asked otherwise) and QR codes
/// made by `CIQRCodeGenerator`. Positions are in image pixels from the top left.
final class OCRPage {
    let width: Int
    let height: Int
    private let context: CGContext

    static let white = CGColor(gray: 1, alpha: 1)
    static let black = CGColor(gray: 0, alpha: 1)

    init(width: Int, height: Int, background: CGColor = OCRPage.white) {
        self.width = width
        self.height = height
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Draws `string` with its top (the font's ascent) at `top` and its left edge at `x`.
    func text(_ string: String, x: Int, top: Int, size: CGFloat = 26, font name: String = "Helvetica",
              color: CGColor = OCRPage.black) {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        context.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(height - top) - CTFontGetAscent(font))
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    /// Draws a QR code of `payload` with its top-left corner at (`x`, `top`), each module `module` px square.
    func qrCode(_ payload: String, x: Int, top: Int, module: CGFloat = 8) {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(payload.utf8)
        generator.correctionLevel = "M"
        let code = generator.outputImage!.samplingNearest().transformed(by: CGAffineTransform(scaleX: module, y: module))
        let image = CIContext().createCGImage(code, from: code.extent)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: x, y: height - top - image.height, width: image.width, height: image.height))
    }

    /// How wide `string` is when drawn by `text(_:x:top:size:)`.
    static func width(of string: String, size: CGFloat = 26, font name: String = "Helvetica") -> CGFloat {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let attributed = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
    }

    /// Distinct everyday words: a line made of them has no word twice, so a word read twice shows.
    static let vocabulary = """
        apple banana cherry dragon eagle falcon garden harbor island jungle kettle lemon marble needle orange pepper \
        quartz river silver tiger umbrella velvet walnut yellow zebra anchor bridge candle desert engine forest glacier \
        hammer jacket ladder magnet nickel oyster pillow rocket saddle tunnel violin window basket castle dolphin \
        feather guitar helmet lantern meadow napkin pencil rabbit spider teapot wizard bottle carpet donkey finger \
        gravel hollow mirror parrot puzzle shadow turtle
        """.split(separator: " ").map(String.init)

    /// "Row `number`" followed by vocabulary words (starting at `first`, wrapping round) until the line is about `width`
    /// px wide. Returns the line and its words after "Row `number`".
    static func row(_ number: Int, first: Int, width: CGFloat) -> (line: String, words: [String]) {
        var words: [String] = []
        var line = "Row \(number)"
        while words.count < vocabulary.count {
            let word = vocabulary[(first + words.count) % vocabulary.count]
            guard OCRPage.width(of: line + " " + word) <= width else { break }
            line += " " + word
            words.append(word)
        }
        return (line, words)
    }

    func image() -> CGImage {
        context.makeImage()!
    }

    /// How many single-character edits turn `a` into `b`.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(previous[j] + (x == y ? 0 : 1), previous[j + 1] + 1, current[j] + 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// The numbers in `lines`' text, in order: one for each line with a number in it.
    static func numbers(in lines: [String]) -> [Int] {
        lines.compactMap { line in
            line.firstMatch(of: /\d+/).flatMap { Int($0.output) }
        }
    }
}
