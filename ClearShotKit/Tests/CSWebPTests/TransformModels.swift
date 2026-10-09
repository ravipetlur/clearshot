import Foundation

/// The transforms as a decoder undoes them, and the predictors as the RFC prints them, written separately from the
/// encoder's so that the tests do not lean on its own copies (RFC 9649, section 3.5). They work pixel by pixel on the
/// reconstructed values, the way a decoder has to: the encoder computes residuals from the original pixels, and the
/// two agree only if the transforms are right.
enum TransformModels {
    // MARK: Pixels as channels

    /// A, R, G, B of an ARGB word.
    static func channels(_ argb: UInt32) -> [Int] {
        [Int(argb >> 24), Int((argb >> 16) & 0xFF), Int((argb >> 8) & 0xFF), Int(argb & 0xFF)]
    }

    static func pixel(_ channels: [Int]) -> UInt32 {
        UInt32(channels[0]) << 24 | UInt32(channels[1]) << 16 | UInt32(channels[2]) << 8 | UInt32(channels[3])
    }

    /// Adds two pixels channel by channel, modulo 256: `PredictorTransformOutput`, and the colour table's
    /// subtraction coding read the other way.
    static func add(_ a: UInt32, _ b: UInt32) -> UInt32 {
        pixel(zip(channels(a), channels(b)).map { ($0 + $1) & 0xFF })
    }

    // MARK: Predictors (section 3.5.1, Table 2)

    static func average2(_ a: Int, _ b: Int) -> Int { (a + b) / 2 }

    static func clamp(_ a: Int) -> Int { a < 0 ? 0 : a > 255 ? 255 : a }

    /// `Select`, as printed: the Manhattan distances of the estimate to L and to T.
    static func select(_ l: UInt32, _ t: UInt32, _ tl: UInt32) -> UInt32 {
        let L = channels(l), T = channels(t), TL = channels(tl)
        let p = (0..<4).map { L[$0] + T[$0] - TL[$0] }
        let pL = (0..<4).reduce(0) { $0 + abs(p[$1] - L[$1]) }
        let pT = (0..<4).reduce(0) { $0 + abs(p[$1] - T[$1]) }
        return pL < pT ? l : t
    }

    /// The predicted value of mode 0 through 13 from the four neighbours.
    static func predict(mode: Int, l: UInt32, t: UInt32, tl: UInt32, tr: UInt32) -> UInt32 {
        func each(_ a: UInt32, _ b: UInt32, _ f: (Int, Int) -> Int) -> UInt32 {
            pixel(zip(channels(a), channels(b)).map { f($0, $1) })
        }
        func avg(_ a: UInt32, _ b: UInt32) -> UInt32 { each(a, b, average2) }
        func clampAddSubtractHalf(_ a: UInt32, _ b: UInt32) -> UInt32 { each(a, b) { clamp($0 + ($0 - $1) / 2) } }
        switch mode {
        case 0: return 0xFF00_0000
        case 1: return l
        case 2: return t
        case 3: return tr
        case 4: return tl
        case 5: return avg(avg(l, tr), t)
        case 6: return avg(l, tl)
        case 7: return avg(l, t)
        case 8: return avg(tl, t)
        case 9: return avg(t, tr)
        case 10: return avg(avg(l, tl), avg(t, tr))
        case 11: return select(l, t, tl)
        case 12:
            let L = channels(l), T = channels(t), TL = channels(tl)
            return pixel((0..<4).map { clamp(L[$0] + T[$0] - TL[$0]) })
        case 13: return clampAddSubtractHalf(avg(l, t), tl)
        default: preconditionFailure("modes are 0 through 13")
        }
    }

    // MARK: Inverse transforms

    /// What a decoder makes of the residual image of a predictor transform: pixels added to their predictions in
    /// scan-line order, from the pixels already rebuilt. `modes` is the tile image, a mode in each pixel's green.
    static func inversePredictor(
        residuals: [UInt32], width: Int, height: Int, sizeBits: Int, modeImage: [UInt32]
    ) -> [UInt32] {
        let tilesAcross = (width + (1 << sizeBits) - 1) >> sizeBits
        var out = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let prediction: UInt32
                if x == 0 && y == 0 {
                    prediction = 0xFF00_0000
                } else if y == 0 {
                    prediction = out[x - 1]  // the top row: L
                } else if x == 0 {
                    prediction = out[(y - 1) * width]  // the leftmost column: T
                } else {
                    let mode = Int((modeImage[(y >> sizeBits) * tilesAcross + (x >> sizeBits)] >> 8) & 0xFF)
                    let tr = x == width - 1 ? out[y * width] : out[(y - 1) * width + x + 1]
                    prediction = predict(mode: mode, l: out[y * width + x - 1], t: out[(y - 1) * width + x],
                                         tl: out[(y - 1) * width + x - 1], tr: tr)
                }
                out[y * width + x] = add(residuals[y * width + x], prediction)
            }
        }
        return out
    }

    /// The residual image of a predictor transform, made the plain way: a new array, each pixel less its prediction
    /// from the original neighbours (the rules for the edges as in the RFC). The encoder does this in place.
    static func forwardPredictor(
        pixels: [UInt32], width: Int, height: Int, sizeBits: Int, modeImage: [UInt32]
    ) -> [UInt32] {
        let tilesAcross = (width + (1 << sizeBits) - 1) >> sizeBits
        var out = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let prediction: UInt32
                if x == 0 && y == 0 {
                    prediction = 0xFF00_0000
                } else if y == 0 {
                    prediction = pixels[x - 1]
                } else if x == 0 {
                    prediction = pixels[(y - 1) * width]
                } else {
                    let mode = Int((modeImage[(y >> sizeBits) * tilesAcross + (x >> sizeBits)] >> 8) & 0xFF)
                    let tr = x == width - 1 ? pixels[y * width] : pixels[(y - 1) * width + x + 1]
                    prediction = predict(mode: mode, l: pixels[y * width + x - 1], t: pixels[(y - 1) * width + x],
                                         tl: pixels[(y - 1) * width + x - 1], tr: tr)
                }
                let a = channels(pixels[y * width + x]), p = channels(prediction)
                out[y * width + x] = pixel((0..<4).map { (a[$0] - p[$0]) & 0xFF })
            }
        }
        return out
    }

    /// `AddGreenToBlueAndRed` (section 3.5.3).
    static func inverseSubtractGreen(_ pixels: [UInt32]) -> [UInt32] {
        pixels.map { argb in
            let green = (argb >> 8) & 0xFF
            let red = (((argb >> 16) & 0xFF) + green) & 0xFF
            let blue = ((argb & 0xFF) + green) & 0xFF
            return argb & 0xFF00_FF00 | red << 16 | blue
        }
    }

    /// The colour table after the decoder adds each entry to the one before (section 3.5.4).
    static func undoSubtractionCoding(_ table: [UInt32]) -> [UInt32] {
        var previous: UInt32 = 0
        return table.map { entry in
            previous = add(entry, previous)
            return previous
        }
    }

    /// The pixels the decoder makes of a colour-indexed image: the index is in the green channel, several to a pixel
    /// when `widthBits` is above 0 (the first in the least significant bits), and an index past the table is
    /// transparent black.
    static func unpackPalette(
        packed: [UInt32], width: Int, height: Int, widthBits: Int, colors: [UInt32]
    ) -> [UInt32] {
        let packedWidth = (width + (1 << widthBits) - 1) >> widthBits
        let bitsPerIndex = 8 >> widthBits
        var out = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let green = Int((packed[y * packedWidth + (x >> widthBits)] >> 8) & 0xFF)
                let index = (green >> (bitsPerIndex * (x & ((1 << widthBits) - 1)))) & ((1 << bitsPerIndex) - 1)
                out[y * width + x] = index < colors.count ? colors[index] : 0
            }
        }
        return out
    }
}
