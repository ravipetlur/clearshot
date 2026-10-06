import AVFoundation
import Foundation
import VideoToolbox

/// One AAC track of a recording.
public struct AudioTrackSettings: Sendable, Equatable {
    public var channels: Int
    /// Bits per second.
    public var bitRate: Int

    public init(channels: Int, bitRate: Int) {
        self.channels = channels
        self.bitRate = bitRate
    }
}

/// What a `RecordingWriter` writes. The audio tracks, when present, are written in the order system audio, then
/// microphone, the order every positional audio-track list (`VideoSourceInfo.audioChannelCounts`,
/// `VideoEdit.trackVolumes`) assumes.
public struct RecordingWriterConfiguration: Sendable, Equatable {
    /// Either way the writer's inputs are real-time (see `RealTimeMediaInput`); the mode says what happens to a sample
    /// the writer isn't ready for.
    public enum AppendMode: Sendable, Equatable {
        /// It is dropped and counted, so the delivering queue never blocks.
        case realTime
        /// The queue waits until the writer takes it, so no sample is lost however fast they come (tests only: it
        /// blocks the queue). Feed samples in timestamp order, video and audio interleaved, as a stream would.
        case waitWhenBusy
    }

    public var fileURL: URL
    public var plan: EncoderPlan
    public var systemAudio: AudioTrackSettings?
    public var microphone: AudioTrackSettings?
    /// Seconds between movie fragments: what an interrupted recording can be recovered to.
    public var fragmentInterval: Double = 1
    public var appendMode: AppendMode = .realTime

    public init(fileURL: URL, plan: EncoderPlan, systemAudio: AudioTrackSettings?, microphone: AudioTrackSettings?) {
        self.fileURL = fileURL
        self.plan = plan
        self.systemAudio = systemAudio
        self.microphone = microphone
    }
}

/// The output settings ClearShot's writers use: the recording writer and the exporters' re-encode.
enum RecordingWriterSettings {
    static let audioSampleRate = 48_000

    /// The encoder for a recording: the plan's codec, size, bitrate, frame rate and keyframe interval; no frame
    /// reordering (with it the first frame lands 0.0667 s late); hardware required when the plan says so, else
    /// disabled.
    static func video(_ plan: EncoderPlan) -> [String: Any] {
        var settings = video(codec: plan.codec, width: plan.width, height: plan.height, bitRate: plan.averageBitRate,
                             framesPerSecond: Double(plan.framesPerSecond), keyFrameInterval: plan.keyFrameInterval)
        settings[AVVideoEncoderSpecificationKey] = plan.requiresHardware
            ? [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
            : [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
        return settings
    }

    /// An encoder at `width` × `height`, tagged Rec. 709 throughout (the SDK has no sRGB transfer constant). Without an
    /// encoder specification VideoToolbox picks hardware when it can.
    static func video(codec: VideoCodec, width: Int, height: Int, bitRate: Int, framesPerSecond: Double,
                      keyFrameInterval: Double) -> [String: Any] {
        [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalDurationKey: keyFrameInterval,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    /// AAC at 48 kHz.
    static func audio(_ track: AudioTrackSettings) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: track.channels,
            AVEncoderBitRateKey: track.bitRate,
        ]
    }

    /// Interleaved 32-bit float PCM at 48 kHz, what the exporters decode audio to.
    static func pcm(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }
}

/// `AVAssetWriterInput.expectsMediaDataInRealTime`, reached through a protocol so the build stays warning-free: Swift
/// marks it deprecated in macOS 27 ("use the input receiver's appendImmediately(...) method instead"), but the
/// receivers alone don't make a writer real-time. Measured with synthetic media, a writer without it:
/// - stops taking video for good after about 35 frames whenever frames arrive with any pause between them (1 ms, or
///   the 33 ms of 30 fps), even with audio interleaved, so it can't record live at all;
/// - refuses audio after about 3.5 s of a still screen (no frames), and video after about 1 s without audio buffers.
///
/// With it none of this happens, so the recording writer sets it in both append modes. `RecordingWriterTests` pins the
/// last two.
protocol RealTimeMediaInput: AnyObject {
    var expectsMediaDataInRealTime: Bool { get set }
}

extension AVAssetWriterInput: RealTimeMediaInput {}
