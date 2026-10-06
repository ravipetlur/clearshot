import CoreGraphics
import Foundation
import Vision

/// Proposes how far the content moved between two frames. Only a candidate: the stitcher verifies it by exact line
/// matching before using it.
public protocol OffsetEstimator: Sendable {
    /// Content movement from `previous` to `current` along `axis`, within `band` (lines), in pixels; positive = scrolled down/right.
    func estimate(from previous: StitchFrame, to current: StitchFrame, band: Range<Int>, axis: ScrollAxis) -> Int?
}

/// Never proposes anything: the stitcher searches every offset.
public struct NoOffsetEstimate: OffsetEstimator {
    public init() {}

    public func estimate(from previous: StitchFrame, to current: StitchFrame, band: Range<Int>, axis: ScrollAxis) -> Int? {
        nil
    }
}

/// Vision's translational image registration on the band of both frames, scaled down so its longer side is at most
/// `maximumSide`, or `longBandSide` for a band longer than `longBand` lines. Measured unreliable on its own (a third of
/// the offsets wrong on scrolled text, nearly all with a sticky header, and its confidence is always 1.0, so it isn't
/// read), but right often enough to settle periodic content.
public struct VisionOffsetEstimator: OffsetEstimator {
    public let maximumSide: Int
    /// Bands longer than this many lines are read at `longBandSide`: scaled to 800 px, 2 400-line bands under a
    /// floating button were misread on 11 of 90 moves at a random pace, and at 1 600 px on 1, for 67 ms an ask instead
    /// of 35.
    public let longBand: Int
    public let longBandSide: Int

    public init(maximumSide: Int = 800, longBand: Int = 1600, longBandSide: Int = 1600) {
        self.maximumSide = maximumSide
        self.longBand = longBand
        self.longBandSide = longBandSide
    }

    /// The longer side a band of `lines` lines is read at.
    func side(forBand lines: Int) -> Int {
        lines > longBand ? max(maximumSide, longBandSide) : maximumSide
    }

    public func estimate(from previous: StitchFrame, to current: StitchFrame, band: Range<Int>, axis: ScrollAxis) -> Int? {
        guard !band.isEmpty, previous.width == current.width, previous.height == current.height else { return nil }
        let cross = current.crossLength(along: axis)
        let scale = min(1, Double(side(forBand: band.count)) / Double(max(band.count, cross)))
        let lines = max(1, Int((Double(band.count) * scale).rounded()))
        let across = max(1, Int((Double(cross) * scale).rounded()))
        // Both pictures are laid out a row per line, so the movement is vertical in them whatever the axis.
        guard let reference = Self.image(previous.scaledLines(band, along: axis, across: across, count: lines),
                                         width: across, height: lines, colorSpace: previous.colorSpace),
              let floating = Self.image(current.scaledLines(band, along: axis, across: across, count: lines),
                                        width: across, height: lines, colorSpace: current.colorSpace)
        else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: floating)
        do {
            try VNImageRequestHandler(cgImage: reference).perform([request])
        } catch {
            return nil
        }
        guard let alignment = request.results?.first else { return nil }
        // The transform moves the floating (current) picture onto the reference, y up: content that scrolled up by o
        // lines needs ty = −o.
        let moved = -Double(alignment.alignmentTransform.ty) * Double(band.count) / Double(lines)
        guard moved.isFinite else { return nil }
        return Int(moved.rounded())
    }

    private static func image(_ pixels: [UInt8], width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: StitchFrame.bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
