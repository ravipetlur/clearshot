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
    var pixelScale: Double
    var images: [CGImage]
}

extension Renderer {
    /// What a redaction draws: the areas it covers (`RedactObject.coveredAreas`) in whole base pixels, each with its effect.
    /// A redaction that covers its whole rect is one cover, as it always was; a text-only one with its words found is one
    /// per word, with the style applied to that area alone (any style: each is `Redaction.image` of the word's area, so a
    /// style is written once, for a rect), and the base left as it is between them. No base to compute from is black over
    /// the whole rect, the same safe answer as Black Out.
    ///
    /// `complete` is false when an effect couldn't be made; that cover is then black, and nothing of it is cached, so the
    /// next frame tries again. Empty when the redaction covers no base pixel.
    static func redactionCovers(_ redact: RedactObject, id: UUID, base: CGImage?, pixelScale: Double,
                                cache: RenderCache?) -> (covers: [RedactionCover], complete: Bool) {
        let whole = redact.rect.standardized.integral
        guard let base else { return ([RedactionCover(region: whole, image: nil)], true) }
        if redact.coversWholeRect {
            if redact.style == .blackOut { return ([RedactionCover(region: whole, image: nil)], true) }
            guard let (region, image) = redactionEffect(redact, id: id, base: base, pixelScale: pixelScale, cache: cache)
            else { return ([], true) }
            return ([RedactionCover(region: region, image: image)], image != nil)
        }
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let regions = redact.coveredAreas(baseSize: bounds.size).compactMap { area -> CGRect? in
            let region = area.integral.intersection(whole).intersection(bounds)
            return region.isNull || region.width < 1 || region.height < 1 ? nil : region
        }
        if redact.style == .blackOut { return (regions.map { RedactionCover(region: $0, image: nil) }, true) }
        let images = wordEffects(redact, id: id, regions: regions, base: base, pixelScale: pixelScale, cache: cache)
        return (zip(regions, images).map { RedactionCover(region: $0, image: $1) }, !images.contains { $0 == nil })
    }

    /// The effect of `redact`'s style on each of `regions` (whole base pixels), from `cache` while nothing they are made from
    /// has changed. Kept only when every one was made.
    private static func wordEffects(_ redact: RedactObject, id: UUID, regions: [CGRect], base: CGImage, pixelScale: Double,
                                    cache: RenderCache?) -> [CGImage?] {
        if let cached = cache?.wordRedactions[id], cached.object == redact, cached.regions == regions, cached.base === base,
           cached.pixelScale == pixelScale {
            return cached.images
        }
        let effect = cache?.effect ?? Redaction.image
        let images = regions.map { region -> CGImage? in
            var piece = redact
            piece.rect = region
            return effect(piece, region, base, pixelScale, id)
        }
        let made = images.compactMap(\.self)
        cache?.wordRedactions[id] = made.count == images.count
            ? CachedWordRedaction(object: redact, regions: regions, base: base, pixelScale: pixelScale, images: made)
            : nil
        return images
    }
}
