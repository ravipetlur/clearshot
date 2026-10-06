/// GIF's variable-length LZW (GIF89a §22, appendix F), as giflib writes it: a clear code first; codes grow from the
/// minimum size + 1 bits up to 12 as the table fills, the size checked after each code against the next free one; a
/// clear code and a fresh table once 4 095 codes are taken; the end code last.
///
/// The loop runs over every pixel written, with raw pointers and `while`, so it stays quick in unoptimised builds.
struct GIFLZW {
    private static let maximumCode = 4095
    private static let hashSize = 1 << 13

    /// Code → (prefix << 8 | index) for the entries made since the last clear; −1 when free.
    private var keys = [Int32](repeating: -1, count: hashSize)
    private var codes = [UInt16](repeating: 0, count: hashSize)
    /// The packed bytes before they're cut into sub-blocks.
    private var packed: [UInt8] = []

    /// The memory its tables and buffer take.
    var bufferedBytes: Int {
        keys.capacity * 4 + codes.capacity * 2 + packed.capacity
    }

    /// Appends the code stream for `indices` (each below 2^`minimumCodeSize`), in data sub-blocks of at most 255 bytes
    /// each after its length byte, then the block terminator, to `output`. `minimumCodeSize` is 2…8.
    mutating func encode(_ indices: UnsafeBufferPointer<UInt8>, minimumCodeSize: Int, into output: inout [UInt8]) {
        precondition((2...8).contains(minimumCodeSize), "GIF's minimum code size is 2 to 8")
        // At most one code a pixel, plus the clears, the first clear and the end, of at most 12 bits each.
        let capacity = (indices.count + indices.count / 3_000 + 4) * 12 / 8 + 8
        if packed.count < capacity { packed = [UInt8](repeating: 0, count: capacity) }
        let length = keys.withUnsafeMutableBufferPointer { keyBuffer in
            codes.withUnsafeMutableBufferPointer { codeBuffer in
                packed.withUnsafeMutableBufferPointer { packedBuffer in
                    Self.pack(indices, minimumCodeSize: minimumCodeSize, keys: keyBuffer.baseAddress!,
                              codes: codeBuffer.baseAddress!, into: packedBuffer.baseAddress!)
                }
            }
        }
        // Sub-blocks: a length byte, then up to 255 bytes; the terminator last.
        output.reserveCapacity(output.count + length + length / 255 + 2)
        packed.withUnsafeBufferPointer { packed in
            var offset = 0
            while offset < length {
                let count = min(255, length - offset)
                output.append(UInt8(count))
                output.append(contentsOf: UnsafeBufferPointer(rebasing: packed[offset..<(offset + count)]))
                offset += count
            }
        }
        output.append(0)
    }

    /// The code stream for `indices`, packed least significant bit first into `out`; returns its length in bytes.
    private static func pack(_ indices: UnsafeBufferPointer<UInt8>, minimumCodeSize: Int, keys: UnsafeMutablePointer<Int32>,
                             codes: UnsafeMutablePointer<UInt16>, into out: UnsafeMutablePointer<UInt8>) -> Int {
        let clear = 1 << minimumCodeSize
        let end = clear + 1
        let mask = hashSize - 1
        var codeSize = minimumCodeSize + 1
        var next = end + 1
        var bits: UInt64 = 0
        var bitCount = 0
        var length = 0

        func emit(_ code: Int) {
            bits |= UInt64(code) << UInt64(bitCount)
            bitCount += codeSize
            while bitCount >= 8 {
                out[length] = UInt8(truncatingIfNeeded: bits)
                length += 1
                bits >>= 8
                bitCount -= 8
            }
            if next >= 1 << codeSize, codeSize < 12 { codeSize += 1 }
        }
        func clearTable() {
            keys.update(repeating: -1, count: hashSize)
        }

        clearTable()
        emit(clear)
        if let base = indices.baseAddress, indices.count > 0 {
            var prefix = Int(base[0])
            var i = 1
            while i < indices.count {
                let index = Int(base[i])
                i += 1
                let key = prefix << 8 | index
                var slot = (key &* 0x9E37_79B1) >> 7 & mask
                var found = -1
                while true {
                    let stored = Int(keys[slot])
                    if stored == key {
                        found = Int(codes[slot])
                        break
                    }
                    if stored < 0 { break }
                    slot = (slot + 1) & mask
                }
                if found >= 0 {
                    prefix = found
                    continue
                }
                emit(prefix)
                if next >= maximumCode {
                    emit(clear)
                    clearTable()
                    next = end + 1
                    codeSize = minimumCodeSize + 1
                } else {
                    // `slot` is the free one the search stopped at.
                    keys[slot] = Int32(key)
                    codes[slot] = UInt16(next)
                    next += 1
                }
                prefix = index
            }
            emit(prefix)
        }
        emit(end)
        if bitCount > 0 {
            out[length] = UInt8(truncatingIfNeeded: bits)
            length += 1
        }
        return length
    }
}
