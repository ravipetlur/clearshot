/// The subtract-green transform (RFC 9649, section 3.5.3): the green of each pixel is taken from its red and its blue,
/// modulo 256. The transform carries no data; a decoder adds the green back. It helps where the three channels move
/// together, as they do in grey and in most photographs.
enum SubtractGreenTransform {
    /// `argb` with its green taken from its red and its blue (alpha and green are kept).
    @inline(__always)
    static func apply(_ argb: UInt32) -> UInt32 {
        let green = (argb >> 8) & 0xFF
        // Only the low byte of each difference is kept, so a borrow into the byte above does not matter.
        let red = ((argb >> 16) &- green) & 0xFF
        let blue = (argb &- green) & 0xFF
        return argb & 0xFF00_FF00 | red << 16 | blue
    }

    /// Applies the transform to every pixel, in place.
    static func apply(to pixels: inout [UInt32]) {
        pixels.withUnsafeMutableBufferPointer { buffer in
            for index in buffer.indices { buffer[index] = apply(buffer[index]) }
        }
    }
}
