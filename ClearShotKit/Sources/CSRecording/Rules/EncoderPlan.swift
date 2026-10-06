import CoreGraphics

public enum VideoCodec: String, Sendable, Codable {
    case h264, hevc
}

/// How a recording is encoded: its size, codec, frame rate and bitrate. The only home of the encoder ceilings.
///
/// The ceilings were measured on an Apple Silicon Mac with a hardware `VTCompressionSession`: H.264 manages about 450
/// Mpx/s and fails outright above 4096 pixels a side (−12903); HEVC manages about 760 Mpx/s. So a 6K display at native
/// resolution (6720 × 3780) can't be recorded at 60 fps by either; HEVC does 25 with headroom.
///
/// With hardware encoding on, the plan `requiresHardware`, and the writer must ask for it
/// (`kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder`): without that, `AVAssetWriter` silently
/// falls back to software H.264 above 4096 pixels, which shows up as dropped frames rather than an error.
public struct EncoderPlan: Sendable, Equatable {
    /// A recording to keep, or the intermediate video a GIF is converted from when the recording stops.
    public enum Purpose: Sendable, Equatable {
        case video
        /// The width is fitted to `maxWidth` (nil keeps the recorded pixels) instead of the maximum resolution.
        case gifIntermediate(maxWidth: Int?)
    }

    // Measured on an Apple Silicon Mac (hardware VTCompressionSession).
    public static let h264MaxSide = 4096
    public static let h264PixelsPerSecond = 450_000_000.0
    public static let hevcPixelsPerSecond = 760_000_000.0
    /// The share of a measured rate a plan uses, leaving room for real content and the rest of the system.
    public static let headroom = 0.85
    /// Players slow down GIF frames shorter than 2/100 s.
    public static let gifMaximumFramesPerSecond = 50

    // Planner picks. VideoToolbox's own default bitrates were tiny on screen content.
    public static let h264BitsPerPixel = 0.08
    public static let hevcBitsPerPixel = 0.05
    /// An intermediate is converted again, so it keeps more detail.
    public static let intermediateBitsPerPixel = 0.25
    public static let minimumBitRate = 1_000_000

    public let codec: VideoCodec
    /// Even, as the encoders need.
    public let width: Int
    public let height: Int
    /// The rate the encoder can keep up with: `requestedFramesPerSecond` or less.
    public let framesPerSecond: Int
    /// The rate asked for, after a GIF intermediate's own limit (50).
    public let requestedFramesPerSecond: Int
    /// Bits per second.
    public let averageBitRate: Int
    /// Seconds between keyframes.
    public let keyFrameInterval: Double
    public let requiresHardware: Bool

    /// The plan for recording a region of `regionPoints` on a display of `scale` pixels per point.
    ///
    /// The size is the region in points with "Scale Retina videos to 1x" on, else its pixels; then fitted, never
    /// upscaled, to the maximum resolution's longer side (a GIF intermediate: to its maximum width); then each side
    /// floored to even. With hardware encoding, H.264 is used when both sides are at most 4096 and the pixel rate is
    /// within the headroom of H.264's; otherwise HEVC, at the rate its headroom allows. Without, software H.264 at the
    /// rate asked for.
    public static func make(regionPoints: CGSize, scale: CGFloat, scaleRetinaTo1x: Bool, maxResolution: RecordingMaxResolution,
                            framesPerSecond: Int, hardwareEncoding: Bool, purpose: Purpose = .video) -> EncoderPlan {
        let pixelsPerPoint = scaleRetinaTo1x ? 1 : Double(scale)
        var size = (width: Double(regionPoints.width) * pixelsPerPoint, height: Double(regionPoints.height) * pixelsPerPoint)
        var requested = max(1, framesPerSecond)
        switch purpose {
        case .video:
            size = fitted(size, longSide: maxResolution.longSide)
        case let .gifIntermediate(maxWidth):
            if let maxWidth, size.width > Double(maxWidth) {
                size = (Double(maxWidth), size.height * Double(maxWidth) / size.width)
            }
            requested = min(requested, gifMaximumFramesPerSecond)
        }
        let width = even(size.width)
        let height = even(size.height)

        let codec: VideoCodec
        let framesPerSecond: Int
        if !hardwareEncoding {
            (codec, framesPerSecond) = (.h264, requested)
        } else if codecRule(width: width, height: height, framesPerSecond: Double(requested)) == .h264 {
            (codec, framesPerSecond) = (.h264, requested)
        } else {
            let ceiling = Int((headroom * hevcPixelsPerSecond / Double(width * height)).rounded(.down))
            (codec, framesPerSecond) = (.hevc, max(1, min(requested, ceiling)))
        }

        let bitsPerPixel = switch (purpose, codec) {
        case (.gifIntermediate, _): intermediateBitsPerPixel
        case (.video, .h264): h264BitsPerPixel
        case (.video, .hevc): hevcBitsPerPixel
        }
        let bitRate = (bitsPerPixel * Double(width) * Double(height) * Double(framesPerSecond)).rounded()
        let keyFrameInterval: Double = if case .gifIntermediate = purpose { 1 } else { 2 }
        return EncoderPlan(codec: codec, width: width, height: height, framesPerSecond: framesPerSecond,
                           requestedFramesPerSecond: requested, averageBitRate: max(minimumBitRate, Int(bitRate)),
                           keyFrameInterval: keyFrameInterval, requiresHardware: hardwareEncoding)
    }

    /// Whether the encoder can't keep up with the rate asked for.
    public var isFrameRateCapped: Bool { framesPerSecond < requestedFramesPerSecond }

    /// What Ready's toolbar says when the rate is capped, e.g. "6720 × 3780 · 25 fps"; nil when it isn't.
    public var readyNote: String? {
        isFrameRateCapped ? "\(width) × \(height) · \(framesPerSecond) fps" : nil
    }

    // MARK: The rules VideoEditPlan shares

    /// H.264 when both sides are at most 4096 and the pixel rate is within the headroom of H.264's, else HEVC.
    static func codecRule(width: Int, height: Int, framesPerSecond: Double) -> VideoCodec {
        let fits = width <= h264MaxSide && height <= h264MaxSide
            && Double(width) * Double(height) * framesPerSecond <= headroom * h264PixelsPerSecond
        return fits ? .h264 : .hevc
    }

    /// `size` with its longer side fitted to `longSide`, keeping the aspect ratio; never upscaled.
    static func fitted(_ size: (width: Double, height: Double), longSide: Int?) -> (width: Double, height: Double) {
        let longer = max(size.width, size.height)
        guard let longSide, longer > Double(longSide) else { return size }
        let factor = Double(longSide) / longer
        return (size.width * factor, size.height * factor)
    }

    /// Floored to an even number of pixels, at least 2. The tolerance keeps a side computed as 1079.9999… at 1080.
    static func even(_ side: Double) -> Int {
        max(2, Int(((side + 0.000_001) / 2).rounded(.down)) * 2)
    }
}
