import Foundation

/// Why an image could not be encoded.
public enum WebPEncodeError: Error, Equatable {
    /// A side is outside 1 through `WebPLosslessEncoder.maxSide`.
    case invalidDimensions(width: Int, height: Int)
    /// The pixel buffer is not `width * height * 4` bytes.
    case bufferSizeMismatch(expected: Int, actual: Int)
}

/// A lossless WebP (VP8L) encoder, written from RFC 9649.
public enum WebPLosslessEncoder {
    /// The longest side the encoder writes. The format's 14-bit size fields reach 16 384, but macOS (ImageIO) does not
    /// decode a side that long, and a file the system can't open is of no use, so 16 383 is the limit.
    public static let maxSide = 16383

    /// How the pixels are turned into symbols. The public `encode` always uses `.backReferences(cacheBits: nil)`; the
    /// other forms let the tests compare against pixels written out one by one, and exercise every cache size.
    enum PixelCoding: Equatable {
        /// Every pixel written out in full, with no copies and no colour cache.
        case literalsOnly
        /// Copies of earlier pixels, and a colour cache of `cacheBits` bits (0 for none; 1 through 11), or, for nil,
        /// of the size the encoder estimates to be the cheapest.
        case backReferences(cacheBits: Int?)
    }

    /// Which transforms go before the pixels are coded. The public `encode` always lets the encoder choose; the
    /// other forms let the tests put every transform through ImageIO on every kind of image.
    enum Transforms: Equatable {
        /// The encoder's choice: the palette transform alone when the image has at most 256 colours; otherwise
        /// subtract green and then the predictor, or no transform, whichever codes the whole image in fewer bits
        /// (see `encode`), and no transform on a tie.
        case automatic
        /// No transform at all.
        case none
        /// The palette transform alone. The image must have 256 colours or fewer.
        case palette
        case subtractGreen
        case predictor
        /// Subtract green, then the predictor, in the order the stream lists them.
        case subtractGreenAndPredictor
    }

    /// Encodes un-premultiplied sRGB RGBA8 pixels (4 bytes per pixel, rows top to bottom, no padding) as a complete
    /// `.webp` file that decodes back to the same pixels. The colour of a fully transparent pixel is not kept: it is
    /// written as black, which is invisible.
    public static func encode(rgba: [UInt8], width: Int, height: Int) throws -> Data {
        try encode(rgba: rgba, width: width, height: height, coding: .backReferences(cacheBits: nil),
                   transforms: .automatic)
    }

    static func encode(
        rgba: [UInt8], width: Int, height: Int, coding: PixelCoding = .backReferences(cacheBits: nil),
        transforms: Transforms = .automatic
    ) throws -> Data {
        guard (1...maxSide).contains(width), (1...maxSide).contains(height) else {
            throw WebPEncodeError.invalidDimensions(width: width, height: height)
        }
        let expected = width * height * 4
        guard rgba.count == expected else {
            throw WebPEncodeError.bufferSizeMismatch(expected: expected, actual: rgba.count)
        }

        // Pack to the format's ARGB order, noting whether any pixel is not fully opaque.
        var pixels = [UInt32](repeating: 0, count: width * height)
        let alphaIsUsed = pack(rgba, into: &pixels)

        let writer = BitWriter(reservingBytes: 1 << 10)
        Container.writeHeader(width: width, height: height, alphaIsUsed: alphaIsUsed, to: writer)

        // The transforms, in the order they are listed in the stream. A decoder undoes them last first, so each is
        // applied here to what the one before left. A transform is a 1 bit, its 2-bit type and its data; a 0 bit ends
        // the list. Each is used at most once.
        let palette = transforms == .palette || transforms == .automatic ? PaletteTransform(pixels: pixels) : nil
        precondition(transforms != .palette || palette != nil, "the palette transform needs 256 colours or fewer")
        // What the main image is made of is `pixels`, `width` across, as they stand after the last transform, and `main`,
        // which counts and costs the symbols they make: the symbols themselves are made again, from these pixels, as the
        // image is written.
        let main: BackwardReferences.Coded
        var mainWidth = width
        if let palette {
            writer.write(1, bits: 1)
            writer.write(3, bits: 2)  // colour indexing
            writer.write(UInt32(palette.colors.count - 1), bits: 8)
            EntropyImageWriter.writeSubImage(palette.subtractionCodedColors, width: palette.colors.count, to: writer)
            pixels = palette.packed(pixels: pixels, width: width, height: height)
            mainWidth = PaletteTransform.packedWidth(forWidth: width, widthBits: palette.widthBits)
            main = codedImage(pixels, width: mainWidth, coding: coding)
        } else if transforms == .automatic {
            // More than 256 colours. Subtract green and the predictor pay for smooth content (photographs, gradients,
            // anti-aliased edges) and cost for hard-edged flat content with repeated shapes, which is better matched as
            // it is, and a single photograph in a flat screenshot is enough to swing the whole image, where a sample of
            // rows could miss it. So both ways are coded in full, each with its own copies and colour cache, and
            // costed as `write` will spend them, the predictor's with its transform fields and tile image added. The
            // cheaper is written, no transform on a tie.
            //
            // Neither way's symbols are kept: at 8 bytes a pixel they would be most of the memory the encoder uses on a
            // large capture. Each is counted as it is generated, and the winner's are generated again as they are
            // written, which gives the same ones. The transforms work in place, so the unchanged pixels are coded
            // first, and made again from `rgba` if they turn out to be the winner.
            let asIs = codedImage(pixels, width: width, coding: coding)
            let predictorFields = BitWriter()
            applyTransforms(subtractGreen: true, predictor: true, to: &pixels, width: width, height: height,
                            writingTo: predictorFields)
            let predicted = codedImage(pixels, width: width, coding: coding)
            if predictorFields.bitCount + predicted.bits < asIs.bits {
                writer.append(predictorFields)
                main = predicted
            } else {
                _ = pack(rgba, into: &pixels)
                main = asIs
            }
        } else {
            applyTransforms(subtractGreen: [.subtractGreen, .subtractGreenAndPredictor].contains(transforms),
                            predictor: [.predictor, .subtractGreenAndPredictor].contains(transforms),
                            to: &pixels, width: width, height: height, writingTo: writer)
            main = codedImage(pixels, width: width, coding: coding)
        }
        writer.write(0, bits: 1)  // no more transforms

        EntropyImageWriter.write(main, pixels: pixels, width: mainWidth, kind: .spatiallyCoded, to: writer)
        return Container.riffFile(payload: writer.finish())
    }

    /// Packs RGBA bytes into the format's ARGB order, over `pixels` (one for every 4 bytes), and returns whether any
    /// pixel is not fully opaque. The colour of a fully transparent pixel is not kept: it is written as 0.
    private static func pack(_ rgba: [UInt8], into pixels: inout [UInt32]) -> Bool {
        var alphaIsUsed = false
        for pixel in 0..<pixels.count {
            let alpha = rgba[pixel * 4 + 3]
            if alpha == 255 {
                pixels[pixel] = 0xFF00_0000 | UInt32(rgba[pixel * 4]) << 16 | UInt32(rgba[pixel * 4 + 1]) << 8
                    | UInt32(rgba[pixel * 4 + 2])
                continue
            }
            alphaIsUsed = true
            if alpha == 0 {
                pixels[pixel] = 0
                continue
            }
            pixels[pixel] = UInt32(alpha) << 24 | UInt32(rgba[pixel * 4]) << 16 | UInt32(rgba[pixel * 4 + 1]) << 8
                | UInt32(rgba[pixel * 4 + 2])
        }
        return alphaIsUsed
    }

    /// Applies subtract green and the predictor, as asked, to `pixels` in place, and writes what the stream holds for
    /// them to `writer`: each transform's 1 bit and 2-bit type, and for the predictor its 3-bit size field and the
    /// tile image of modes.
    private static func applyTransforms(
        subtractGreen: Bool, predictor: Bool, to pixels: inout [UInt32], width: Int, height: Int,
        writingTo writer: BitWriter
    ) {
        if subtractGreen {
            writer.write(1, bits: 1)
            writer.write(2, bits: 2)  // subtract green: no data
            SubtractGreenTransform.apply(to: &pixels)
        }
        if predictor {
            writer.write(1, bits: 1)
            writer.write(0, bits: 2)  // predictor
            let sizeBits = PredictorTransform.sizeBits
            writer.write(UInt32(sizeBits - 2), bits: 3)
            let modes = PredictorTransform.chooseModes(pixels: pixels, width: width, height: height, sizeBits: sizeBits)
            EntropyImageWriter.writeSubImage(
                PredictorTransform.modeImage(modes: modes),
                width: PredictorTransform.tileCount(width: width, height: height, sizeBits: sizeBits).across,
                to: writer)
            PredictorTransform.replaceWithResiduals(&pixels, width: width, height: height, sizeBits: sizeBits,
                                                    modes: modes)
        }
    }

    /// The pixels of the main image (`width` across, after any transform) costed as `coding` says: counted and costed as
    /// the spatially coded image `write` makes of them, without keeping their symbols.
    private static func codedImage(_ pixels: [UInt32], width: Int, coding: PixelCoding) -> BackwardReferences.Coded {
        switch coding {
        case .literalsOnly:
            return BackwardReferences.coded(pixels: pixels, width: width, matches: [], cacheBits: 0)
        case .backReferences(let forcedCacheBits?):
            precondition(forcedCacheBits == 0 || (1...ColorCache.maxBits).contains(forcedCacheBits))
            return BackwardReferences.coded(
                pixels: pixels, width: width, matches: BackwardReferences.findMatches(pixels: pixels, width: width),
                cacheBits: forcedCacheBits)
        case .backReferences(nil):
            return BackwardReferences.codedWithBestCache(pixels: pixels, width: width)
        }
    }
}
