import CoreGraphics
import Foundation

/// The live preview of a scrolling capture: the capture so far, scaled down to `side` px across the axis and growing
/// along it as strips are drawn, the first frame first. Kept a row per line whatever the axis, and turned when the
/// picture is made.
struct StitchPreview: Sendable {
    /// Pixels across the axis: the side asked for, or the frames' own when they are narrower.
    let side: Int
    let axis: ScrollAxis
    /// Preview pixels per source pixel, never above 1: a preview bigger than the capture shows nothing more.
    private let scale: Double
    private var lineCount = 0
    private var pixels: [UInt8] = []

    /// A preview at most `side` px across of a capture along `axis` whose frames are `crossLength` px across.
    init(side: Int, axis: ScrollAxis, crossLength: Int) {
        self.side = min(side, crossLength)
        self.axis = axis
        scale = Double(self.side) / Double(crossLength)
    }

    /// Draws `lines` of `source` at `position` (source lines from the capture's start), and makes the preview as long
    /// as a capture `captureLength` source lines long.
    mutating func draw(_ source: StitchFrame, lines: Range<Int>, at position: Int, captureLength: Int) {
        let length = Int((Double(captureLength) * scale).rounded())
        if length != lineCount {
            pixels.removeLast(max(0, pixels.count - length * side * 4))
            pixels.append(contentsOf: repeatElement(0, count: max(0, length * side * 4 - pixels.count)))
            lineCount = length
        }
        let start = min(Int((Double(position) * scale).rounded()), lineCount)
        let end = min(Int((Double(position + lines.count) * scale).rounded()), lineCount)
        guard end > start, !lines.isEmpty else { return }
        let scaled = source.scaledLines(lines, along: axis, across: side, count: end - start)
        pixels.replaceSubrange((start * side * 4)..<(end * side * 4), with: scaled)
    }

    /// A copy of the preview as it is, or nil while it's empty.
    func image(colorSpace: CGColorSpace) -> CGImage? {
        guard lineCount > 0 else { return nil }
        let (width, height, bytes): (Int, Int, [UInt8])
        switch axis {
        case .vertical:
            (width, height, bytes) = (side, lineCount, pixels)
        case .horizontal:
            var turned = [UInt8](repeating: 0, count: pixels.count)
            pixels.withUnsafeBytes { lines in
                turned.withUnsafeMutableBytes { turned in
                    for line in 0..<lineCount {
                        for x in 0..<side {
                            turned.storeBytes(of: lines.loadUnaligned(fromByteOffset: (line * side + x) * 4, as: UInt32.self),
                                              toByteOffset: (x * lineCount + line) * 4, as: UInt32.self)
                        }
                    }
                }
            }
            (width, height, bytes) = (lineCount, side, turned)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: StitchFrame.bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
