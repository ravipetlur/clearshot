import CoreGraphics

/// The direction a scrolling capture grows in: down (vertical) or to the right (horizontal).
public enum ScrollAxis: Sendable, Equatable {
    case vertical, horizontal
}

/// One frame of a scrolling capture, as the region stream delivers it: 32-bit BGRA, premultiplied first,
/// little-endian (`kCVPixelFormatType_32BGRA`), rows from the top.
public struct StitchFrame: Sendable {
    public let width: Int, height: Int, bytesPerRow: Int
    public let pixels: [UInt8]
    public let colorSpace: CGColorSpace

    public init(width: Int, height: Int, bytesPerRow: Int, pixels: [UInt8], colorSpace: CGColorSpace) {
        precondition(width > 0 && height > 0 && bytesPerRow >= width * 4 && pixels.count >= bytesPerRow * height,
                     "A \(width) × \(height) frame needs \(bytesPerRow) ≥ \(width * 4) bytes a row and \(bytesPerRow * height) bytes")
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
        self.colorSpace = colorSpace
    }
}

// Lines: rows of a vertical capture, columns of a horizontal one.
extension StitchFrame {
    /// The frames' layout, said to Core Graphics: 32 bits little-endian with premultiplied alpha first, i.e. BGRA bytes.
    static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    /// How many lines the frame has along `axis`.
    func length(along axis: ScrollAxis) -> Int {
        axis == .vertical ? height : width
    }

    /// How long each line is (pixels across `axis`).
    func crossLength(along axis: ScrollAxis) -> Int {
        axis == .vertical ? width : height
    }

    /// A copy of just `lines`, as a frame of its own with tight rows.
    func lines(_ lines: Range<Int>, along axis: ScrollAxis) -> StitchFrame {
        let (width, height) = axis == .vertical ? (self.width, lines.count) : (lines.count, self.height)
        var copy = [UInt8](repeating: 0, count: width * height * 4)
        copy.withUnsafeMutableBytes { copy in
            copyLines(lines, along: axis, into: copy.baseAddress!, bytesPerRow: width * 4, at: 0)
        }
        return StitchFrame(width: width, height: height, bytesPerRow: width * 4, pixels: copy, colorSpace: colorSpace)
    }

    /// Copies `lines` into a bitmap of the same layout (BGRA, lines along `axis`, as wide across), the first one going
    /// to line `position` there.
    func copyLines(_ lines: Range<Int>, along axis: ScrollAxis, into destination: UnsafeMutableRawPointer,
                   bytesPerRow destinationBytesPerRow: Int, at position: Int) {
        guard !lines.isEmpty else { return }
        precondition(lines.lowerBound >= 0 && lines.upperBound <= length(along: axis))
        pixels.withUnsafeBytes { source in
            switch axis {
            case .vertical:
                for (offset, y) in lines.enumerated() {
                    (destination + (position + offset) * destinationBytesPerRow)
                        .copyMemory(from: source.baseAddress! + y * bytesPerRow, byteCount: width * 4)
                }
            case .horizontal:
                for y in 0..<height {
                    (destination + y * destinationBytesPerRow + position * 4)
                        .copyMemory(from: source.baseAddress! + y * bytesPerRow + lines.lowerBound * 4, byteCount: lines.count * 4)
                }
            }
        }
    }

    /// `lines` scaled by area averaging to `across` pixels across and `count` lines, laid out a row per line whatever
    /// the axis (so a horizontal capture comes out turned a quarter): BGRA, `across × 4` bytes a row. Each output pixel
    /// averages at most 4 × 4 evenly spread pixels of its box, which is plenty for a thumbnail.
    func scaledLines(_ lines: Range<Int>, along axis: ScrollAxis, across: Int, count: Int) -> [UInt8] {
        precondition(!lines.isEmpty && across > 0 && count > 0)
        let lineBoxes = Self.boxes(splitting: lines.count, into: count)
        let crossBoxes = Self.boxes(splitting: crossLength(along: axis), into: across)
        // Byte steps between neighbouring pixels along a line and between neighbouring lines.
        let (pixelStep, lineStep) = axis == .vertical ? (4, bytesPerRow) : (bytesPerRow, 4)
        var scaled = [UInt8](repeating: 0, count: across * count * 4)
        pixels.withUnsafeBytes { source in
            scaled.withUnsafeMutableBytes { scaled in
                for (outLine, lineBox) in lineBoxes.enumerated() {
                    for (outPixel, crossBox) in crossBoxes.enumerated() {
                        var sums = (0, 0, 0, 0)
                        var samples = 0
                        for line in Self.samples(of: lineBox) {
                            let lineStart = (lines.lowerBound + line) * lineStep
                            for pixel in Self.samples(of: crossBox) {
                                let at = lineStart + pixel * pixelStep
                                sums.0 += Int(source[at])
                                sums.1 += Int(source[at + 1])
                                sums.2 += Int(source[at + 2])
                                sums.3 += Int(source[at + 3])
                                samples += 1
                            }
                        }
                        let at = (outLine * across + outPixel) * 4
                        scaled[at] = UInt8((sums.0 + samples / 2) / samples)
                        scaled[at + 1] = UInt8((sums.1 + samples / 2) / samples)
                        scaled[at + 2] = UInt8((sums.2 + samples / 2) / samples)
                        scaled[at + 3] = UInt8((sums.3 + samples / 2) / samples)
                    }
                }
            }
        }
        return scaled
    }

    /// `length` source pixels split into `parts` consecutive boxes, each at least one pixel.
    private static func boxes(splitting length: Int, into parts: Int) -> [Range<Int>] {
        (0..<parts).map { part in
            let start = min(part * length / parts, length - 1)
            return start..<max((part + 1) * length / parts, start + 1)
        }
    }

    /// At most 4 pixels of `box`, evenly spread.
    private static func samples(of box: Range<Int>) -> StrideTo<Int> {
        stride(from: box.lowerBound, to: box.upperBound, by: (box.count + 3) / 4)
    }

    /// The positions across the lines (columns of a vertical capture, rows of a horizontal one) where this frame and
    /// `other` have the same pixel on every line of `lines`: what stayed put, in place, along the whole band (a sticky
    /// sidebar, the paper either side of the text).
    func unchangedAcross(_ other: StitchFrame, along axis: ScrollAxis, lines: Range<Int>) -> [Bool] {
        precondition(width == other.width && height == other.height)
        let cross = crossLength(along: axis)
        var unchanged = [Bool](repeating: true, count: cross)
        var remaining = cross
        // Byte steps between neighbouring pixels along a line and between neighbouring lines.
        let (pixelStep, lineStep) = axis == .vertical ? (4, bytesPerRow) : (bytesPerRow, 4)
        let (otherPixelStep, otherLineStep) = axis == .vertical ? (4, other.bytesPerRow) : (other.bytesPerRow, 4)
        pixels.withUnsafeBytes { mine in
            other.pixels.withUnsafeBytes { theirs in
                for line in lines where remaining > 0 {
                    for position in 0..<cross where unchanged[position] {
                        let a = mine.loadUnaligned(fromByteOffset: line * lineStep + position * pixelStep, as: UInt32.self)
                        let b = theirs.loadUnaligned(fromByteOffset: line * otherLineStep + position * otherPixelStep,
                                                     as: UInt32.self)
                        if a != b {
                            unchanged[position] = false
                            remaining -= 1
                        }
                    }
                }
            }
        }
        return unchanged
    }
}
