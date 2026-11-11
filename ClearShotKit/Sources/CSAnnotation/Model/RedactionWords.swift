import CoreGraphics
import CSSensitive

/// The words a text-only redaction covers (`RedactObject.textOnly`), as text recognition found them in the picture under
/// its rect. They are stored in the document, so a render never runs recognition: an export, a reopened document and every
/// frame draw the same.
///
/// They apply only to the pixels they were read from: `picture` is a fingerprint of the base's pixels under the rect
/// (`RedactionWords.fingerprint`). The same rect over other pixels (the redaction in another document, a base that changed
/// under it) has other words, so there the redaction covers its whole rect until they are read again. Turns, flips, crops,
/// resizes and the canvas change no base pixel, and the boxes are in base pixels, so the words keep applying through them.
public struct RedactionWords: Codable, Equatable, Sendable {
    /// The redaction's rect when they were found. Once the rect is moved or resized they no longer apply, and the redaction
    /// covers its whole rect until they are found again.
    public var rect: CGRect
    /// Each word's box, in base pixels, as recognition placed it (no margin). Empty when no text was found.
    public var boxes: [CGRect]
    /// Whether the text reads down the base: the picture was turned a quarter when it was read, so the words, upright on
    /// screen, lie on their side in the base. The margins (`MaskGeometry`) go the text's way.
    public var runVertically: Bool
    /// The fingerprint of the base's pixels under `rect` when they were read (`fingerprint(of:in:)`). Nil matches no
    /// picture.
    public var picture: UInt64?

    public init(rect: CGRect, boxes: [CGRect], runVertically: Bool = false, picture: UInt64?) {
        self.rect = rect
        self.boxes = boxes
        self.runVertically = runVertically
        self.picture = picture
    }

    private enum CodingKeys: String, CodingKey {
        case rect, boxes, runVertically, picture
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rect = try container.decode(CGRect.self, forKey: .rect)
        boxes = try container.decodeIfPresent([CGRect].self, forKey: .boxes) ?? []
        runVertically = try container.decodeIfPresent(Bool.self, forKey: .runVertically) ?? false
        picture = try container.decodeIfPresent(UInt64.self, forKey: .picture)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rect, forKey: .rect)
        try container.encode(boxes, forKey: .boxes)
        if runVertically { try container.encode(true, forKey: .runVertically) }
        try container.encodeIfPresent(picture, forKey: .picture)
    }

    /// A fingerprint of `base`'s pixels under `rect` (base pixels, rounded out to whole pixels and cut to the base): FNV-1a
    /// over the area and its pixels drawn as 8-bit sRGB. The same pixels give the same number in any run. Nil when the rect
    /// covers no base pixel or a bitmap can't be made.
    public static func fingerprint(of base: CGImage, in rect: CGRect) -> UInt64? {
        let region = rect.standardized.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !region.isNull, region.width >= 1, region.height >= 1, let crop = base.cropping(to: region),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = crop.width, height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        let area = [Int64(region.minX), Int64(region.minY), Int64(width), Int64(height)]
        area.withUnsafeBytes { $0.forEach(mix) }
        bytes.forEach(mix)
        return hash
    }
}

extension RedactObject {
    /// The words found for the rect as it is now, whatever pixels they were read from, or nil: not text-only, not found yet,
    /// or found for an earlier rect. Whether they apply to a picture is `currentWords(picture:)`'s to say.
    var wordsForRect: RedactionWords? {
        guard textOnly, let words, words.rect == rect else { return nil }
        return words
    }

    /// The words that apply over the base whose fingerprint under the rect is `picture` (`RedactionWords.fingerprint`):
    /// found for the rect as it is now, from those very pixels. Nil otherwise.
    public func currentWords(picture: UInt64?) -> RedactionWords? {
        guard let words = wordsForRect, let picture, words.picture == picture else { return nil }
        return words
    }

    /// A text-only redaction whose words are still to be found for the rect as it is now, over the base whose fingerprint
    /// under the rect is `picture`.
    public func needsWords(picture: UInt64?) -> Bool { textOnly && currentWords(picture: picture) == nil }

    /// Whether the style covers the whole rect over the base whose fingerprint under the rect is `picture`: not text-only;
    /// or text-only with its words still to be found, found for another rect or other pixels, or none found. **Fail safe:**
    /// the text is never shown while recognition runs, nor where the words were read from other pixels.
    public func coversWholeRect(picture: UInt64?) -> Bool {
        currentWords(picture: picture).map(\.boxes.isEmpty) ?? true
    }

    /// The areas the style covers, in base pixels (fractions kept), on a base `baseSize` pixels across whose fingerprint
    /// under the rect is `picture`: the whole rect (`coversWholeRect`), or each word's box with the sensitive-info masks'
    /// margin (`MaskGeometry.maskRect`: more for taller text, the wide one along the text), cut to the rect. Should no box
    /// reach into the rect, the whole rect.
    public func coveredAreas(baseSize: CGSize, picture: UInt64?) -> [CGRect] {
        let whole = rect.standardized
        guard let words = currentWords(picture: picture), !words.boxes.isEmpty else { return [whole] }
        let areas = words.boxes.compactMap { box -> CGRect? in
            let area = MaskGeometry.maskRect(for: box, imageSize: baseSize, textRunsVertically: words.runVertically)
                .intersection(whole)
            return area.isNull || area.isEmpty ? nil : area
        }
        return areas.isEmpty ? [whole] : areas
    }

    /// Whether the redaction may cover less than its whole rect: text-only, with words for the rect as it is now.
    var mayCoverOnlyWords: Bool { wordsForRect.map { !$0.boxes.isEmpty } ?? false }

    /// Whether this redaction hides at least what `earlier` (the same redaction, before a change) hid, given the same style
    /// and strength: when it covers its whole rect, a rect that contains the earlier one; when it may cover only words,
    /// exactly the earlier words over the same rect.
    func coversAtLeast(_ earlier: RedactObject) -> Bool {
        if !mayCoverOnlyWords { return rect.standardized.contains(earlier.rect.standardized) }
        return earlier.mayCoverOnlyWords && rect == earlier.rect && words == earlier.words
    }
}
