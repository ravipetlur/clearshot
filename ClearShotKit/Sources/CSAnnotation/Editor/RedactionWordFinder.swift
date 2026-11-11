import CoreGraphics
import CSOCR
import Foundation

/// Finds the words under a text-only redaction (`RedactObject.textOnly`) with on-device text recognition, at the accurate
/// level: it runs once per redaction and rect, not per frame, so it can take its time.
enum RedactionWordFinder {
    /// The picture the words are read from: the document's picture as it is shown (turned, flipped, resized, on its canvas),
    /// with no object on it. Not even the redactions: the text-only redaction itself, still covering its whole rect, would
    /// hide the words, and text under another redaction is covered by that one anyway. Nil when it can't be rendered. Slow
    /// for a large picture: call it off the main actor.
    static func picture(of document: AnnotationDocument, images: ImageStore) -> PictureRender? {
        Renderer.renderReduced(textPicture(of: document), images: images)
    }

    /// The document reduced to the picture the words are read from (`picture(of:images:)`).
    static func textPicture(of document: AnnotationDocument) -> AnnotationDocument {
        var reduced = document
        reduced.objects = []
        reduced.background = nil
        return reduced
    }

    /// The words inside `rect` (base pixels) of `picture`: the part of the picture under the rect is read, and each word's
    /// box taken back to base pixels. `base` is the base image `picture` was rendered from: the words carry the fingerprint of
    /// its pixels under the rect (`RedactionWords.picture`), so they apply to those pixels only. Nil when recognition failed
    /// or was cancelled; no words is an empty list.
    static func words(in rect: CGRect, of picture: PictureRender, base: CGImage,
                      options: TextRecognitionOptions) async -> RedactionWords? {
        let fingerprint = RedactionWords.fingerprint(of: base, in: rect)
        let toBase = picture.mapping.toBase
        // A quarter turn takes the picture's x axis (the way the text reads on screen) to the base's y axis.
        let runVertically = abs(toBase.b) > abs(toBase.a)
        let bounds = CGRect(x: 0, y: 0, width: picture.image.width, height: picture.image.height)
        let shown = rect.standardized.applying(toBase.inverted()).integral.intersection(bounds)
        guard !shown.isNull, shown.width >= 1, shown.height >= 1, let crop = picture.image.cropping(to: shown) else {
            return RedactionWords(rect: rect, boxes: [], runVertically: runVertically, picture: fingerprint)
        }
        let result: OCRResult
        do {
            result = try await TextRecognizer.recognize(crop, options: options, marking: wordRanges)
        } catch {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let boxes = result.lines.flatMap(boxes(of:)).map { box in
            box.offsetBy(dx: shown.minX, dy: shown.minY).applying(toBase).standardized
        }
        return RedactionWords(rect: rect, boxes: boxes, runVertically: runVertically, picture: fingerprint)
    }

    /// Each run of non-blank characters in a line: a word, for recognition to box (`TextRecognizer.Marking`).
    static let wordRanges: TextRecognizer.Marking = { line in
        var ranges: [(range: Range<String.Index>, tag: Int)] = []
        var start: String.Index?
        var index = line.startIndex
        while index < line.endIndex {
            if line[index].isWhitespace {
                if let first = start { ranges.append((first..<index, 0)) }
                start = nil
            } else if start == nil {
                start = index
            }
            index = line.index(after: index)
        }
        if let first = start { ranges.append((first..<line.endIndex, 0)) }
        return ranges
    }

    /// A line's word boxes, in the read image's pixels. A word recognition gave no box for would go uncovered, so a line with
    /// fewer boxes than words is covered whole as well.
    static func boxes(of line: OCRLine) -> [CGRect] {
        let words = line.text.split(whereSeparator: \.isWhitespace).count
        let marks = line.marks.map(\.box).filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        return marks.count >= words ? marks : marks + [line.box]
    }
}
