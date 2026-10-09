/// Writes values into a byte stream least-significant bit first, the bit order of a WebP lossless stream (RFC 9649,
/// section 3.2): a value's lowest bit goes first, into the lowest free bit of the current byte.
///
/// A class so that one writer can be passed down through the helpers that each write a part of the stream.
final class BitWriter {
    private var output: [UInt8] = []
    /// Bits written but not yet moved to `output`: always fewer than 8 between calls.
    private var pending: UInt64 = 0
    private var pendingCount = 0

    init(reservingBytes capacity: Int = 0) {
        output.reserveCapacity(capacity)
    }

    /// How many bits have been written.
    var bitCount: Int { output.count * 8 + pendingCount }

    /// Appends the low `bits` bits of `value`, lowest bit first. `bits` is 0 through 32. A value wider than `bits` is
    /// a caller bug and stops the program in every build (a `precondition`, not a mask): quietly keeping the low bits
    /// would write a field the caller did not mean, and letting the high bits through would corrupt the fields after
    /// it.
    func write(_ value: UInt32, bits: Int) {
        precondition(bits >= 0 && bits <= 32, "a write is 0 to 32 bits")
        precondition(bits == 32 || value >> UInt32(bits) == 0, "the value does not fit in \(bits) bits")
        guard bits > 0 else { return }
        pending |= UInt64(value) << UInt64(pendingCount)
        pendingCount += bits
        while pendingCount >= 8 {
            output.append(UInt8(truncatingIfNeeded: pending))
            pending >>= 8
            pendingCount -= 8
        }
    }

    /// Writes all of `other`'s bits, first written first, after the bits written so far (which need not end on a byte
    /// boundary). `other` is left as it was.
    func append(_ other: BitWriter) {
        var remaining = other.bitCount
        for byte in other.bytes() {
            let count = min(8, remaining)
            write(UInt32(byte) & ((1 << UInt32(count)) - 1), bits: count)
            remaining -= count
        }
    }

    /// The bytes written so far, the last one padded with zero bits. Writing can continue afterwards. This copies the
    /// stream when a partial byte is pending; `finish()` does not.
    func bytes() -> [UInt8] {
        pendingCount > 0 ? output + [UInt8(truncatingIfNeeded: pending)] : output
    }

    /// Ends the stream: the last byte padded with zero bits, and the bytes handed over without a copy. The writer is
    /// empty afterwards.
    func finish() -> [UInt8] {
        if pendingCount > 0 { output.append(UInt8(truncatingIfNeeded: pending)) }
        pending = 0
        pendingCount = 0
        var finished: [UInt8] = []
        swap(&finished, &output)
        return finished
    }
}
