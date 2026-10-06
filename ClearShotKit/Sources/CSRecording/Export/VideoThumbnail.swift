import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// What a video file is, and its first frame as a thumbnail.
public enum VideoThumbnail {
    /// The file's duration, pixel size, nominal frame rate, estimated video data rate, codec (and the four-character code
    /// it is stored as), each audio track's channel count in file order, and the size it is shown at (its rotation
    /// applied). Throws `VideoFileError.noVideoTrack`
    /// without video, `.unreadable` when it doesn't open.
    @concurrent
    public static func info(of url: URL) async throws -> VideoSourceInfo {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw VideoFileError.noVideoTrack }
            let (size, frameRate, dataRate, formats) = try await video.load(.naturalSize, .nominalFrameRate, .estimatedDataRate,
                                                                            .formatDescriptions)
            let transform = try await video.load(.preferredTransform)
            var channelCounts: [Int] = []
            for track in try await asset.loadTracks(withMediaType: .audio) {
                channelCounts.append(try await channelCount(of: track))
            }
            // The rotation a phone puts on a portrait video turns the stored size into the shown one.
            let shown = CGRect(origin: .zero, size: size).applying(transform).size
            return VideoSourceInfo(duration: duration.seconds, pixelWidth: Int(size.width.rounded()),
                                   pixelHeight: Int(size.height.rounded()), framesPerSecond: Double(frameRate),
                                   videoBitRate: Double(dataRate), codec: formats.first.flatMap(codec(of:)),
                                   videoCodecType: formats.first?.mediaSubType.rawValue,
                                   audioChannelCounts: channelCounts, displayWidth: Int(abs(shown.width).rounded()),
                                   displayHeight: Int(abs(shown.height).rounded()))
        } catch let error as VideoFileError {
            throw error
        } catch {
            throw VideoFileError.unreadable(error.localizedDescription)
        }
    }

    /// The frame shown at `seconds` (the first frame by default; a trimmed GIF's is its trim's start), at most
    /// `maximumPixel` on its longer side, with the track's transform applied (8–21 ms for the first frame, measured).
    /// Throws `VideoFileError.noVideoTrack` without video, `.unreadable` when it doesn't decode.
    @concurrent
    public static func image(of url: URL, at seconds: Double = 0, maximumPixel: Int = 640) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        do {
            guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw VideoFileError.noVideoTrack }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: maximumPixel, height: maximumPixel)
            generator.appliesPreferredTrackTransform = true
            // The frame at that time, not the nearest keyframe.
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image
        } catch let error as VideoFileError {
            throw error
        } catch {
            throw VideoFileError.unreadable(error.localizedDescription)
        }
    }

    /// An audio track's channel count (2 when its format doesn't say).
    static func channelCount(of track: AVAssetTrack) async throws -> Int {
        let formats = try await track.load(.formatDescriptions)
        return formats.first?.audioStreamBasicDescription.map { Int($0.mChannelsPerFrame) } ?? 2
    }

    /// HEVC with its parameter sets in the stream, as some other apps write it ('hev1').
    private static let hevcInBand: FourCharCode = 0x6865_7631

    private static func codec(of format: CMFormatDescription) -> VideoCodec? {
        switch format.mediaSubType.rawValue {
        case kCMVideoCodecType_H264: .h264
        case kCMVideoCodecType_HEVC, hevcInBand: .hevc
        default: nil
        }
    }
}
