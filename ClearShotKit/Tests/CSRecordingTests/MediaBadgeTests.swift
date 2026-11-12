import Foundation
import Testing
@testable import CSRecording

struct MediaBadgeTests {
    private let english = Locale(identifier: "en_US")

    /// A video with sound shows its length, size and the speaker; a GIF is named and never has the speaker; what
    /// isn't known is left out; and the speaker shows only for a video known to have sound.
    @Test func theBadgeShowsWhatIsKnown() {
        let rows: [(isGIF: Bool, duration: Double?, bytes: Int64?, hasAudio: Bool?, text: String, speaker: Bool)] = [
            (false, 12.6, 8_400_000, true, "0:12 · 8.4 MB", true),
            (true, 5, 1_200_000, true, "GIF · 0:05 · 1.2 MB", false),
            (false, nil, 8_400_000, nil, "8.4 MB", false),
            (false, 61, nil, false, "1:01", false),
            (true, nil, nil, nil, "GIF", false),
        ]
        for row in rows {
            let badge = MediaBadge(isGIF: row.isGIF, duration: row.duration, bytes: row.bytes, hasAudio: row.hasAudio,
                                   locale: english)
            #expect(badge.text == row.text)
            #expect(badge.showsSpeaker == row.speaker, "\(row.text)")
        }
        #expect(!MediaBadge(isGIF: false, duration: 1, bytes: 1, hasAudio: false, locale: english).showsSpeaker)
        #expect(!MediaBadge(isGIF: false, duration: 1, bytes: 1, hasAudio: nil, locale: english).showsSpeaker)
    }
}
