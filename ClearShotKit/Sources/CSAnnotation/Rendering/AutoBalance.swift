import CoreGraphics
import Foundation

/// Auto-balance: the uniform margins around a picture, measured so the background can trim them and the padding looks
/// even.
public enum AutoBalance {
    /// How far a channel, alpha included, may be from the edge's reference and still count as margin, of 255.
    public static let tolerance = 8
    /// The fewest pixels the trims leave on an axis; an axis shorter than this isn't trimmed.
    public static let minimumSide = 16.0
    /// The smallest share of an axis the trims leave.
    public static let minimumFraction = 0.1

    /// The margins of `content` (the canvas as rendered, without objects or background), in whole pixels.
    ///
    /// Each edge has its own reference: the top-left pixel for the top and the left, the bottom-left for the bottom, the
    /// top-right for the right. An edge's margin is the run of whole rows (top, bottom) or columns (left, right) from that
    /// edge in which every pixel is within `tolerance` of the reference on every channel. Pixels are compared
    /// premultiplied, so transparent pixels are all alike whatever their colour. A picture whose every row matches the top
    /// reference is uniform and isn't trimmed. On each axis the two trims leave at least `minimumSide` pixels and
    /// `minimumFraction` of the axis, or are both cut back in proportion until they do. `.zero` if the picture can't be
    /// read.
    public static func trims(of content: CGImage) -> EdgeTrims {
        let width = content.width, height = content.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return .zero }
        // The pixels, premultiplied, top row first.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(content, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return .zero }

        let margins = pixels.withUnsafeBufferPointer { pixels -> (top: Int, left: Int, bottom: Int, right: Int)? in
            func offset(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }
            func matches(_ pixel: Int, _ reference: Int) -> Bool {
                for channel in 0..<4 where abs(Int(pixels[pixel + channel]) - Int(pixels[reference + channel])) > tolerance {
                    return false
                }
                return true
            }
            func rowMatches(_ y: Int, _ reference: Int) -> Bool {
                (0..<width).allSatisfy { matches(offset($0, y), reference) }
            }
            func columnMatches(_ x: Int, _ reference: Int) -> Bool {
                (0..<height).allSatisfy { matches(offset(x, $0), reference) }
            }
            var top = 0
            while top < height, rowMatches(top, offset(0, 0)) { top += 1 }
            guard top < height else { return nil }
            var bottom = 0
            while bottom < height, rowMatches(height - 1 - bottom, offset(0, height - 1)) { bottom += 1 }
            var left = 0
            while left < width, columnMatches(left, offset(0, 0)) { left += 1 }
            var right = 0
            while right < width, columnMatches(width - 1 - right, offset(width - 1, 0)) { right += 1 }
            return (top, left, bottom, right)
        }
        guard let margins else { return .zero }
        let vertical = limited(margins.top, margins.bottom, side: height)
        let horizontal = limited(margins.left, margins.right, side: width)
        return EdgeTrims(top: Double(vertical.first), left: Double(horizontal.first), bottom: Double(vertical.second),
                         right: Double(horizontal.second))
    }

    /// The two margins of an axis `side` pixels long as trims: none under `minimumSide`, else each scaled by the same
    /// share (and floored) so that at least the minimum remains.
    private static func limited(_ first: Int, _ second: Int, side: Int) -> (first: Int, second: Int) {
        guard Double(side) >= minimumSide else { return (0, 0) }
        let minimum = max(Int(minimumSide), Int((minimumFraction * Double(side)).rounded(.up)))
        let sum = first + second
        guard side - sum < minimum else { return (first, second) }
        // `sum` isn't 0 here: the minimum is never more than the side.
        let room = side - minimum
        return (first * room / sum, second * room / sum)
    }
}
