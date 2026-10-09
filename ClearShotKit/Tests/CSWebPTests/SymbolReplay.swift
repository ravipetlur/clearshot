import Foundation
@testable import CSWebP

/// A model of the decoder's pixel loop (RFC 9649, section 3.7.2.3) that replays the encoder's symbol stream: a literal
/// is a pixel, a cache index is the colour held in that slot, and a copy duplicates pixels one at a time from
/// `distance` back (so it may overlap its own output). Every pixel produced, however it was produced, goes into the
/// colour cache. It is not a bitstream decoder; ImageIO remains the gate for the written bits. Its tables and hash come
/// from `SpecTables`, not from the encoder.
enum SymbolReplay {
    enum Failure: Error, CustomStringConvertible {
        case cacheIndexOutOfRange(symbol: Int, index: Int)
        case lengthOutOfRange(symbol: Int, length: Int)
        case distanceBeyondTheStart(symbol: Int, position: Int, distance: Int)
        case distanceCodeOutOfRange(symbol: Int, code: Int)
        case copyPastTheEnd(symbol: Int, position: Int, length: Int)
        case tooFewPixels(produced: Int, expected: Int)

        var description: String {
            switch self {
            case .cacheIndexOutOfRange(let symbol, let index): "symbol \(symbol): cache index \(index) out of range"
            case .lengthOutOfRange(let symbol, let length): "symbol \(symbol): copy length \(length) is not 1 to 4096"
            case .distanceBeyondTheStart(let symbol, let position, let distance):
                "symbol \(symbol): at pixel \(position) a distance of \(distance) reaches before the first pixel"
            case .distanceCodeOutOfRange(let symbol, let code): "symbol \(symbol): distance code \(code) out of range"
            case .copyPastTheEnd(let symbol, let position, let length):
                "symbol \(symbol): a copy of \(length) from pixel \(position) runs past the end"
            case .tooFewPixels(let produced, let expected): "the stream makes \(produced) pixels, expected \(expected)"
            }
        }
    }

    /// The pixels the symbols describe for an image `width` pixels wide and `count` pixels in all, with a colour cache
    /// of `cacheBits` bits (0 for none).
    static func pixels(
        of symbols: [EntropyImageWriter.Symbol], width: Int, count: Int, cacheBits: Int
    ) throws -> [UInt32] {
        var pixels: [UInt32] = []
        pixels.reserveCapacity(count)
        let cacheSize = cacheBits > 0 ? 1 << cacheBits : 0
        var cache = [UInt32](repeating: 0, count: cacheSize)
        func produce(_ argb: UInt32) {
            pixels.append(argb)
            if cacheBits > 0 { cache[SpecTables.cacheIndex(argb, bits: cacheBits)] = argb }
        }
        for (number, symbol) in symbols.enumerated() {
            switch symbol.form {
            case .literal(let argb):
                produce(argb)
            case .cacheIndex(let index):
                guard (0..<cacheSize).contains(index) else {
                    throw Failure.cacheIndexOutOfRange(symbol: number, index: index)
                }
                produce(cache[index])
            case .backref(let length, let distanceCode):
                guard (1...4096).contains(length) else {
                    throw Failure.lengthOutOfRange(symbol: number, length: length)
                }
                guard (1...1_048_576).contains(distanceCode) else {
                    throw Failure.distanceCodeOutOfRange(symbol: number, code: distanceCode)
                }
                let distance = SpecTables.distance(forCode: distanceCode, width: width)
                guard distance <= pixels.count else {
                    throw Failure.distanceBeyondTheStart(symbol: number, position: pixels.count, distance: distance)
                }
                guard pixels.count + length <= count else {
                    throw Failure.copyPastTheEnd(symbol: number, position: pixels.count, length: length)
                }
                for _ in 0..<length { produce(pixels[pixels.count - distance]) }
            }
        }
        guard pixels.count == count else { throw Failure.tooFewPixels(produced: pixels.count, expected: count) }
        return pixels
    }
}

extension RGBAImage {
    /// The pixels as the encoder sees them before any coding: ARGB words, row by row, with the colour of a fully
    /// transparent pixel zeroed (the encoder does not keep it).
    var argbPixels: [UInt32] {
        (0..<(width * height)).map { index in
            let alpha = UInt32(rgba[index * 4 + 3])
            if alpha == 0 { return 0 }
            return alpha << 24 | UInt32(rgba[index * 4]) << 16 | UInt32(rgba[index * 4 + 1]) << 8
                | UInt32(rgba[index * 4 + 2])
        }
    }
}
