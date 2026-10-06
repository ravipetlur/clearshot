/// The file an edit writes: an MP4, except an edit that copies the video as stored (a trim, Mute, a remix) from a codec
/// MP4 can't carry, such as ProRes, which stays a QuickTime movie. `replaceMedia` gives the working copy the file's
/// extension.
public enum VideoContainer: String, Sendable, Equatable {
    case mp4, mov

    public var fileExtension: String { rawValue }

    /// The video codecs an MP4 is known to carry, by their format's four-character code: H.264 ('avc1'), HEVC ('hvc1',
    /// and 'hev1' with its parameter sets in the stream) and MPEG-4 video ('mp4v'). Any other stays in QuickTime, which
    /// carries whatever AVFoundation reads; so a codec left out costs only the extension, never the edit.
    static let mp4VideoCodecTypes: Set<UInt32> = [0x6176_6331, 0x6876_6331, 0x6865_7631, 0x6D70_3476]

    /// Whether an MP4 can carry video stored as `videoCodecType` (a format's media subtype).
    public static func mp4Carries(videoCodecType: UInt32) -> Bool {
        mp4VideoCodecTypes.contains(videoCodecType)
    }

    /// The file a plan on `path` writes from video stored as `videoCodecType`: a re-encode writes H.264 or HEVC, so an
    /// MP4; a path that copies the video keeps a codec MP4 can't carry in QuickTime. A codec that wasn't read (nil) is
    /// taken to be one MP4 carries.
    static func forEdit(path: VideoEditPlan.Path, videoCodecType: UInt32?) -> VideoContainer {
        guard path != .reencode, let videoCodecType, !mp4Carries(videoCodecType: videoCodecType) else { return .mp4 }
        return .mov
    }
}
