import Foundation

/// The RIFF file around a lossless stream and the stream's own header (RFC 9649, sections 2 and 3).
enum Container {
    /// The first byte of every lossless stream.
    static let signature: UInt8 = 0x2F
    /// The largest side the format's 14-bit size fields can describe (they hold `side - 1`).
    static let formatMaxSide = 1 << 14

    /// Writes the lossless header: the signature byte, `width - 1` and `height - 1` in 14 bits each, the
    /// `alpha_is_used` hint (1 bit) and the version, which is 0 (3 bits).
    static func writeHeader(width: Int, height: Int, alphaIsUsed: Bool, to writer: BitWriter) {
        precondition((1...formatMaxSide).contains(width) && (1...formatMaxSide).contains(height))
        writer.write(UInt32(signature), bits: 8)
        writer.write(UInt32(width - 1), bits: 14)
        writer.write(UInt32(height - 1), bits: 14)
        writer.write(alphaIsUsed ? 1 : 0, bits: 1)
        writer.write(0, bits: 3)
    }

    /// A whole file: `RIFF`, the size of everything after that field, `WEBP`, then one `VP8L` chunk holding
    /// `payload`. A chunk's size field leaves out its own header and the pad byte; a payload of odd length is followed
    /// by a zero byte so the chunk, and so the file, ends on an even length.
    static func riffFile(payload: [UInt8]) -> Data {
        let padding = payload.count & 1
        let riffSize = 4 + 8 + payload.count + padding
        precondition(riffSize <= Int(UInt32.max), "the file is larger than a RIFF container can describe")

        var file = Data()
        file.reserveCapacity(8 + riffSize)
        file.append(contentsOf: Array("RIFF".utf8))
        file.append(littleEndian: UInt32(riffSize))
        file.append(contentsOf: Array("WEBP".utf8))
        file.append(contentsOf: Array("VP8L".utf8))
        file.append(littleEndian: UInt32(payload.count))
        file.append(contentsOf: payload)
        if padding == 1 { file.append(0) }
        return file
    }
}

extension Data {
    fileprivate mutating func append(littleEndian value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(8 * $0)) })
    }
}
