import CoreGraphics
import CSSensitive

/// The words a text-only redaction covers (`RedactObject.textOnly`), as text recognition found them in the picture under
/// its rect. They are stored in the document, so a render never runs recognition: an export, a reopened document and every
/// frame draw the same.
public struct RedactionWords: Codable, Equatable, Sendable {
    /// The redaction's rect when they were found. Once the rect is moved or resized they no longer apply, and the redaction
    /// covers its whole rect until they are found again.
    public var rect: CGRect
    /// Each word's box, in base pixels, as recognition placed it (no margin). Empty when no text was found.
    public var boxes: [CGRect]
    /// Whether the text reads down the base: the picture was turned a quarter when it was read, so the words, upright on
    /// screen, lie on their side in the base. The margins (`MaskGeometry`) go the text's way.
    public var runVertically: Bool

    public init(rect: CGRect, boxes: [CGRect], runVertically: Bool = false) {
        self.rect = rect
        self.boxes = boxes
        self.runVertically = runVertically
    }

    private enum CodingKeys: String, CodingKey {
        case rect, boxes, runVertically
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rect = try container.decode(CGRect.self, forKey: .rect)
        boxes = try container.decodeIfPresent([CGRect].self, forKey: .boxes) ?? []
        runVertically = try container.decodeIfPresent(Bool.self, forKey: .runVertically) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rect, forKey: .rect)
        try container.encode(boxes, forKey: .boxes)
        if runVertically { try container.encode(true, forKey: .runVertically) }
    }
}

extension RedactObject {
    /// The words found for the rect as it is now, or nil: not text-only, not found yet, or found for an earlier rect.
    public var currentWords: RedactionWords? {
        guard textOnly, let words, words.rect == rect else { return nil }
        return words
    }

    /// A text-only redaction whose words are still to be found for the rect as it is now.
    public var needsWords: Bool { textOnly && currentWords == nil }

    /// Whether the style covers the whole rect: not text-only; or text-only with its words still to be found, or with none
    /// found. **Fail safe:** the text is never shown while recognition runs.
    public var coversWholeRect: Bool { currentWords.map(\.boxes.isEmpty) ?? true }

    /// The areas the style covers, in base pixels (fractions kept), on a base `baseSize` pixels across: the whole rect
    /// (`coversWholeRect`), or each word's box with the sensitive-info masks' margin (`MaskGeometry.maskRect`: more for
    /// taller text, the wide one along the text), cut to the rect. Should no box reach into the rect, the whole rect.
    public func coveredAreas(baseSize: CGSize) -> [CGRect] {
        let whole = rect.standardized
        guard let words = currentWords, !words.boxes.isEmpty else { return [whole] }
        let areas = words.boxes.compactMap { box -> CGRect? in
            let area = MaskGeometry.maskRect(for: box, imageSize: baseSize, textRunsVertically: words.runVertically)
                .intersection(whole)
            return area.isNull || area.isEmpty ? nil : area
        }
        return areas.isEmpty ? [whole] : areas
    }

    /// Whether this redaction hides at least what `earlier` (the same redaction, before a change) hid, given the same style
    /// and strength: covering its whole rect, a rect that contains the earlier one; covering only words, exactly the earlier
    /// words over the same rect.
    func coversAtLeast(_ earlier: RedactObject) -> Bool {
        if coversWholeRect { return rect.standardized.contains(earlier.rect.standardized) }
        return !earlier.coversWholeRect && rect == earlier.rect && currentWords == earlier.currentWords
    }
}
