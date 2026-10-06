/// The Video Editor's Quality: a bitrate from bits per pixel, or the source's own.
public enum VideoQuality: String, CaseIterable, Sendable {
    case low, medium, high, original

    /// Bits per pixel per frame, or nil to keep the source's bits per pixel.
    var bitsPerPixel: Double? {
        switch self {
        case .low: 0.03
        case .medium: 0.06
        case .high: 0.10
        case .original: nil
        }
    }
}

/// What the editor knows about the video it opened.
public struct VideoSourceInfo: Sendable, Equatable {
    /// Seconds.
    public var duration: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var framesPerSecond: Double
    /// Bits per second.
    public var videoBitRate: Double
    /// Nil for a codec ClearShot doesn't write.
    public var codec: VideoCodec?
    /// The video's format as stored, its four-character code ('avc1', 'apcn' for ProRes 422…), which decides whether an
    /// edit that copies it can be an MP4 (`VideoContainer`); nil when it wasn't read.
    public var videoCodecType: UInt32?
    /// One entry per audio track: its channel count. A recording's tracks are the system audio's, then the
    /// microphone's.
    public var audioChannelCounts: [Int]
    /// The size it is shown at, its rotation applied: a phone stores a portrait video on its side, so 1920 × 1080
    /// pixels show 1080 × 1920. The pixel size is what an edit encodes; this is for sizing a window. The pixel size
    /// unless given.
    public var displayWidth: Int
    public var displayHeight: Int

    public init(duration: Double, pixelWidth: Int, pixelHeight: Int, framesPerSecond: Double, videoBitRate: Double,
                codec: VideoCodec?, videoCodecType: UInt32? = nil, audioChannelCounts: [Int], displayWidth: Int? = nil,
                displayHeight: Int? = nil) {
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.framesPerSecond = framesPerSecond
        self.videoBitRate = videoBitRate
        self.codec = codec
        self.videoCodecType = videoCodecType
        self.audioChannelCounts = audioChannelCounts
        self.displayWidth = displayWidth ?? pixelWidth
        self.displayHeight = displayHeight ?? pixelHeight
    }
}

/// The changes the editor, Mute Audio… or a merge asks for.
public struct VideoEdit: Sendable, Equatable {
    public var trim: TrimRange?
    public var quality: VideoQuality = .original
    /// Only a resolution below the source's changes anything; video is never upscaled.
    public var resolution: RecordingMaxResolution = .original
    public var mute = false
    public var mono = false
    /// The overall volume, 1 = 100%, applied on top of `trackVolumes`.
    public var volume = 1.0
    /// When set, every audio track is merged into one, each at its volume. Positional, like
    /// `VideoSourceInfo.audioChannelCounts`: the system audio's track, then the microphone's. A missing entry is 1.
    public var trackVolumes: [Double]? = nil

    public init() {}
}

/// How an edit is carried out: the cheapest path that gives the result.
public struct VideoEditPlan: Sendable, Equatable {
    public enum Path: Sendable, Equatable {
        /// The edit changes nothing.
        case nothing
        /// A trim and/or dropping the audio: the samples are copied as they are (frame-accurate).
        case passthrough
        /// The audio is mixed again (mono, volume, merged tracks); the video is copied.
        case audioRemix
        /// The video is encoded again, at a new size or bitrate.
        case reencode
    }

    /// Bitrates of the audio a remix or re-encode writes, which the estimate also assumes for copied audio.
    static let stereoAudioBitRate = 192_000.0
    static let monoAudioBitRate = 128_000.0
    /// The frame rate a re-encode assumes for a file that reports none (a nominal rate of 0), in its bitrate and codec
    /// maths and in the encoder's settings, so no plan has 0 bit/s.
    public static let fallbackFramesPerSecond = 30.0

    public let path: Path
    /// The part kept, or nil for the whole video.
    public let timeRange: TrimRange?
    public let outputWidth: Int
    public let outputHeight: Int
    /// The codec written: the encoder's for a re-encode, else the source's (H.264 when it is neither).
    public let codec: VideoCodec
    /// The re-encode's bitrate; nil when the video is copied.
    public let videoBitRate: Int?
    public let includesAudio: Bool
    /// 1 with Mono; otherwise the source's widest track's count, which a merged track takes, while separate tracks each
    /// keep their own count (a mono microphone track is never upmixed); 0 without audio.
    public let audioChannels: Int
    /// Each source audio track's volume, the overall volume included; empty without audio. Positional, in the source's
    /// track order: for a recording, the system audio's track, then the microphone's.
    public let trackVolumes: [Double]
    /// Every source audio track is mixed into one written track: when the edit asks for it (`VideoEdit.trackVolumes`),
    /// and whenever a remix or re-encode writes the audio of a file with more than the two separate tracks the exporter
    /// writes (a recording's system audio and microphone). A passthrough copies the tracks as they are.
    public let mergesTracks: Bool
    /// The file it writes: an MP4, unless it copies video MP4 can't carry (`VideoContainer.forEdit`). Name the
    /// destination with its `fileExtension`.
    public let container: VideoContainer
    public let estimatedBytes: Int64

    /// The plan for `edit` on `source`. A re-encode is sized by EncoderPlan's rule (the long side fitted to the
    /// resolution, each side floored to even) and takes its codec rule; its bitrate is the source's bits per pixel at
    /// Original quality (at least `EncoderPlan.minimumBitRate`, since some files report no data rate), else the quality's
    /// bits per pixel at the source's frame rate (`fallbackFramesPerSecond` when it reports none). Audio edits apply on
    /// every path that writes audio.
    public static func make(edit: VideoEdit, source: VideoSourceInfo) -> VideoEditPlan {
        let hasAudio = !source.audioChannelCounts.isEmpty
        let includesAudio = hasAudio && !edit.mute
        let widest = source.audioChannelCounts.max() ?? 0
        let trackCount = source.audioChannelCounts.count
        let mergeRequested = includesAudio && edit.trackVolumes != nil && trackCount > 1
        let trackVolumes: [Double] = !includesAudio ? [] : (0..<trackCount).map { index in
            let own = edit.trackVolumes.flatMap { index < $0.count ? $0[index] : nil } ?? 1
            return own * edit.volume
        }
        let remixes = includesAudio && ((edit.mono && widest > 1) || mergeRequested || trackVolumes.contains { $0 != 1 })

        let sourceLongSide = max(source.pixelWidth, source.pixelHeight)
        let longSide = edit.resolution.longSide.flatMap { $0 < sourceLongSide ? $0 : nil }
        let reencodes = edit.quality != .original || longSide != nil
        let trims = edit.trim.map { $0.start > 0.001 || $0.end < source.duration - 0.001 } ?? false
        let path: Path = if reencodes { .reencode }
            else if remixes { .audioRemix }
            else if trims || (edit.mute && hasAudio) { .passthrough }
            else { .nothing }
        let rewritesAudio = includesAudio && (path == .audioRemix || path == .reencode)
        let mergesTracks = mergeRequested || (rewritesAudio && trackCount > 2)

        return plan(path: path, source: source, timeRange: trims ? edit.trim : nil, longSide: longSide,
                    quality: edit.quality, includesAudio: includesAudio,
                    audioChannels: includesAudio ? (edit.mono ? 1 : widest) : 0, trackVolumes: trackVolumes,
                    mergesTracks: mergesTracks)
    }

    /// Mute Audio…: the whole video copied without its audio.
    public static func mute(_ source: VideoSourceInfo) -> VideoEditPlan {
        plan(path: .passthrough, source: source, timeRange: nil, longSide: nil, quality: .original, includesAudio: false,
             audioChannels: 0, trackVolumes: [], mergesTracks: false)
    }

    /// The resolutions the editor offers for `source`: Original, then those below the source's long side.
    public static func resolutions(for source: VideoSourceInfo) -> [RecordingMaxResolution] {
        let longSide = max(source.pixelWidth, source.pixelHeight)
        return RecordingMaxResolution.allCases.filter { resolution in
            resolution.longSide.map { $0 < longSide } ?? true
        }
    }

    private static func plan(path: Path, source: VideoSourceInfo, timeRange: TrimRange?, longSide: Int?,
                             quality: VideoQuality, includesAudio: Bool, audioChannels: Int, trackVolumes: [Double],
                             mergesTracks: Bool) -> VideoEditPlan {
        var (width, height) = (source.pixelWidth, source.pixelHeight)
        var codec = source.codec ?? .h264
        var videoBitRate: Int?
        if path == .reencode {
            let fitted = EncoderPlan.fitted((Double(width), Double(height)), longSide: longSide)
            (width, height) = (EncoderPlan.even(fitted.width), EncoderPlan.even(fitted.height))
            let framesPerSecond = source.framesPerSecond > 0 ? source.framesPerSecond : fallbackFramesPerSecond
            codec = EncoderPlan.codecRule(width: width, height: height, framesPerSecond: framesPerSecond)
            let pixels = Double(width) * Double(height)
            let rate = if let bitsPerPixel = quality.bitsPerPixel {
                bitsPerPixel * pixels * framesPerSecond
            } else {
                max(Double(EncoderPlan.minimumBitRate),
                    source.videoBitRate * pixels / (Double(source.pixelWidth) * Double(source.pixelHeight)))
            }
            videoBitRate = Int(rate.rounded())
        }

        let channelsPerTrack = mergesTracks ? [audioChannels] : source.audioChannelCounts.map { audioChannels == 1 ? 1 : $0 }
        let audioBitRates = includesAudio ? channelsPerTrack.map { $0 > 1 ? stereoAudioBitRate : monoAudioBitRate } : []
        let duration = timeRange.map { $0.end - $0.start } ?? source.duration
        let estimatedBytes = FileSizeEstimate.bytes(videoBitRate: videoBitRate.map(Double.init) ?? source.videoBitRate,
                                                    audioBitRates: audioBitRates, duration: duration)
        return VideoEditPlan(path: path, timeRange: timeRange, outputWidth: width, outputHeight: height, codec: codec,
                             videoBitRate: videoBitRate, includesAudio: includesAudio, audioChannels: audioChannels,
                             trackVolumes: trackVolumes, mergesTracks: mergesTracks,
                             container: VideoContainer.forEdit(path: path, videoCodecType: source.videoCodecType),
                             estimatedBytes: estimatedBytes)
    }
}
