import Foundation

/// Reads the first bits of an encoded file's lossless stream, after the 40 bits of header: which transform comes first.
enum StreamPeek {
    /// The bits of the stream from its first byte, least significant first.
    static func bit(_ file: Data, _ index: Int) -> Int {
        let byte = file[file.startIndex + 20 + index / 8]
        return Int((byte >> UInt8(index % 8)) & 1)
    }

    static func bits(_ file: Data, from start: Int, count: Int) -> Int {
        (0..<count).reduce(0) { $0 | bit(file, start + $1) << $1 }
    }

    /// The transform types in the order written, as far as they can be read without decoding a sub-image: the
    /// first one's type, and (for subtract green, which has no data) the one after it.
    static func firstTransforms(of file: Data) -> [Int] {
        var types: [Int] = []
        var at = 40
        while bit(file, at) == 1 {
            let type = bits(file, from: at + 1, count: 2)
            types.append(type)
            at += 3
            if type != 2 { break }  // predictor, colour and palette carry data, which ends what is read here
        }
        return types
    }

    /// The colour count of a palette transform at the head of the stream.
    static func paletteColorCount(of file: Data) -> Int? {
        guard bit(file, 40) == 1, bits(file, from: 41, count: 2) == 3 else { return nil }
        return bits(file, from: 43, count: 8) + 1
    }
}
