import CoreGraphics
import Foundation

/// One area a redaction covers, in whole base pixels, and what goes there: its effect, or black when `image` is nil (Black
/// Out, or an effect that couldn't be made).
struct RedactionCover {
    var region: CGRect
    var image: CGImage?
}

/// A text-only redaction's effects, one per word area, with everything they were computed from (as `CachedRedaction`).
struct CachedWordRedaction {
    var object: RedactObject
    var regions: [CGRect]
    var base: CGImage
    /// What an Erase reads around each word (`RedactionInput`): another redaction changing beside it makes the words again.
    var surroundings: CGImage
    var excluded: [CGRect]
    var pixelScale: Double
    var images: [CGImage]
}

/// The fingerprint of the base's pixels under a text-only redaction's rect (`RedactionWords.fingerprint`), with the base and
/// the rect it was taken of.
struct CachedWordsPicture {
    var base: CGImage
    var rect: CGRect
    var fingerprint: UInt64?
}

extension Renderer {
    /// What a redaction draws: the areas it covers (`RedactObject.coveredAreas`) in whole base pixels, each with its effect.
    /// A redaction that covers its whole rect is one cover, as it always was; a text-only one whose words were read from
    /// these very pixels (`RedactObject.currentWords(picture:)`) is one per word, with the style applied to that area alone
    /// (any style: each is `Redaction.image` of the word's area, so a style is written once, for a rect), and the base left as
    /// it is between them. No base to compute from is black over the whole rect, the same safe answer as Black Out.
    ///
    /// `complete` is false when an effect couldn't be made; that cover is then black, and nothing of it is cached, so the
    /// next frame tries again. Empty when the redaction covers no base pixel.
    /// `redactions` are the document's, which an Erase reads around (`redactionInput`), for the whole rect or per word.
    static func redactionCovers(_ redact: RedactObject, id: UUID, base: CGImage?, redactions: [RedactionKey],
                                pixelScale: Double, cache: RenderCache?) -> (covers: [RedactionCover], complete: Bool) {
        let whole = redact.rect.standardized.integral
        guard let base else { return ([RedactionCover(region: whole, image: nil)], true) }
        let picture = redact.wordsForRect == nil ? nil : wordsPicture(redact, id: id, base: base, cache: cache)
        if redact.coversWholeRect(picture: picture) {
            if redact.style == .blackOut { return ([RedactionCover(region: whole, image: nil)], true) }
            guard let (region, image) = redactionEffect(redact, id: id, base: base, redactions: redactions, pixelScale: pixelScale,
                                                        cache: cache)
            else { return ([], true) }
            return ([RedactionCover(region: region, image: image)], image != nil)
        }
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let regions = redact.coveredAreas(baseSize: bounds.size, picture: picture).compactMap { area -> CGRect? in
            let region = area.integral.intersection(whole).intersection(bounds)
            return region.isNull || region.width < 1 || region.height < 1 ? nil : region
        }
        if redact.style == .blackOut { return (regions.map { RedactionCover(region: $0, image: nil) }, true) }
        // An Erase whose surroundings can't be made is black, as a failed effect is.
        guard let input = redactionInput(redact, id: id, base: base, redactions: redactions, pixelScale: pixelScale, cache: cache)
        else { return (regions.map { RedactionCover(region: $0, image: nil) }, false) }
        let images = wordEffects(redact, id: id, regions: regions, input: input, pixelScale: pixelScale, cache: cache)
        return (zip(regions, images).map { RedactionCover(region: $0, image: $1) }, !images.contains { $0 == nil })
    }

    /// The fingerprint of `base`'s pixels under `redact`'s rect, from `cache` while the base and the rect are the ones it was
    /// taken of.
    private static func wordsPicture(_ redact: RedactObject, id: UUID, base: CGImage, cache: RenderCache?) -> UInt64? {
        if let cached = cache?.wordsPictures[id], cached.base === base, cached.rect == redact.rect { return cached.fingerprint }
        let fingerprint = RedactionWords.fingerprint(of: base, in: redact.rect)
        cache?.wordsPictures[id] = CachedWordsPicture(base: base, rect: redact.rect, fingerprint: fingerprint)
        return fingerprint
    }

    /// The effect of `redact`'s style on each of `regions` (whole base pixels), from `cache` while nothing they are made from
    /// has changed. Each region has a seed of its own (`seed(_:for:)`), so no two words share their noise. Kept only when
    /// every one was made.
    private static func wordEffects(_ redact: RedactObject, id: UUID, regions: [CGRect], input: RedactionInput,
                                    pixelScale: Double, cache: RenderCache?) -> [CGImage?] {
        let base = input.base
        if let cached = cache?.wordRedactions[id], cached.object == redact, cached.regions == regions, cached.base === base,
           cached.surroundings === input.surroundings, cached.excluded == input.excluded, cached.pixelScale == pixelScale {
            return cached.images
        }
        let effect = cache?.effect ?? Redaction.image
        let images = regions.map { region -> CGImage? in
            var piece = redact
            piece.rect = region
            return effect(piece, region, input, pixelScale, seed(id, for: region))
        }
        let made = images.compactMap(\.self)
        cache?.wordRedactions[id] = made.count == images.count
            ? CachedWordRedaction(object: redact, regions: regions, base: base, surroundings: input.surroundings,
                                  excluded: input.excluded, pixelScale: pixelScale, images: made)
            : nil
        return images
    }

    /// The noise seed of one word area of redaction `id`: the redaction's id mixed with the area, so every area has noise of
    /// its own, and the same area always the same noise.
    static func seed(_ id: UUID, for region: CGRect) -> UUID {
        var generator = SeededGenerator(seed: id)
        var state = generator.next()
        for value in [region.minX, region.minY, region.width, region.height] {
            state ^= Double(value).bitPattern
            var mixer = SplitMix(state: state)
            state = mixer.next()
        }
        let low = state
        var mixer = SplitMix(state: state ^ generator.next())
        let high = mixer.next()
        var bytes = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        withUnsafeMutableBytes(of: &bytes) { raw in
            raw.storeBytes(of: low, toByteOffset: 0, as: UInt64.self)
            raw.storeBytes(of: high, toByteOffset: 8, as: UInt64.self)
        }
        return UUID(uuid: bytes)
    }

    /// One SplitMix64 step from a given state.
    private struct SplitMix {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
