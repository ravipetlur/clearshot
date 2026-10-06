import Foundation

/// What a video's or GIF's badge says in Quick Access and History: "GIF" for a GIF, its length (`ElapsedText`) and its
/// working copy's size in the file style ("12.3 MB"), joined by " · ", leaving out whatever isn't known; and the
/// speaker, only for a video known to have sound (a GIF never has any).
public struct MediaBadge: Sendable, Equatable {
    public var text: String
    public var showsSpeaker: Bool

    /// `duration` in seconds and `bytes` (the working copy's size) are nil when unknown. `locale` formats the size.
    public init(isGIF: Bool, duration: Double?, bytes: Int64?, hasAudio: Bool?, locale: Locale = .autoupdatingCurrent) {
        var parts: [String] = []
        if isGIF { parts.append("GIF") }
        if let duration { parts.append(ElapsedText.string(seconds: duration)) }
        if let bytes { parts.append(bytes.formatted(ByteCountFormatStyle(style: .file, locale: locale))) }
        text = parts.joined(separator: " · ")
        showsSpeaker = !isGIF && hasAudio == true
    }
}
