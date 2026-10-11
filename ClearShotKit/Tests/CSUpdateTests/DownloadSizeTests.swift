import Testing
import CSUpdate

/// A download that goes past the size the release lists is stopped at once, as a size mismatch, not downloaded to the end.
struct DownloadSizeTests {
    @Test func exactlyTheListedSizeIsFine() {
        #expect(!DownloadSize.exceeds(listed: 1000, received: 0))
        #expect(!DownloadSize.exceeds(listed: 1000, received: 999))
        #expect(!DownloadSize.exceeds(listed: 1000, received: 1000))
    }

    @Test func oneByteMoreIsTooMuch() {
        #expect(DownloadSize.exceeds(listed: 1000, received: 1001))
        #expect(DownloadSize.exceeds(listed: 1000, received: Int64.max))
    }

    /// The server saying up front that it will send more than listed is as bad as sending it. An unknown length is not.
    @Test func anAnnouncedLengthPastTheListedSizeIsTooMuch() {
        #expect(DownloadSize.exceeds(listed: 1000, announced: 1001))
        #expect(!DownloadSize.exceeds(listed: 1000, announced: 1000))
        #expect(!DownloadSize.exceeds(listed: 1000, announced: 0))
        // URLSession's NSURLSessionTransferSizeUnknown.
        #expect(!DownloadSize.exceeds(listed: 1000, announced: -1))
    }
}
