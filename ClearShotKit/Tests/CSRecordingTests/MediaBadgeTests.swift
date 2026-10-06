import Foundation
import Testing
@testable import CSRecording

struct MediaBadgeTests {
    private let english = Locale(identifier: "en_US")

    @Test func aVideoWithSoundShowsItsLengthSizeAndTheSpeaker() {
        let badge = MediaBadge(isGIF: false, duration: 12.6, bytes: 8_400_000, hasAudio: true, locale: english)
        #expect(badge.text == "0:12 · 8.4 MB")
        #expect(badge.showsSpeaker)
    }

    @Test func aGIFIsNamedAndNeverHasTheSpeaker() {
        let badge = MediaBadge(isGIF: true, duration: 5, bytes: 1_200_000, hasAudio: true, locale: english)
        #expect(badge.text == "GIF · 0:05 · 1.2 MB")
        #expect(!badge.showsSpeaker)
    }

    @Test func whatIsntKnownIsLeftOut() {
        #expect(MediaBadge(isGIF: false, duration: nil, bytes: 8_400_000, hasAudio: nil, locale: english).text == "8.4 MB")
        #expect(MediaBadge(isGIF: false, duration: 61, bytes: nil, hasAudio: false, locale: english).text == "1:01")
        #expect(MediaBadge(isGIF: true, duration: nil, bytes: nil, hasAudio: nil, locale: english).text == "GIF")
        // The speaker only for a video known to have sound.
        #expect(!MediaBadge(isGIF: false, duration: 1, bytes: 1, hasAudio: false, locale: english).showsSpeaker)
        #expect(!MediaBadge(isGIF: false, duration: 1, bytes: 1, hasAudio: nil, locale: english).showsSpeaker)
    }
}
