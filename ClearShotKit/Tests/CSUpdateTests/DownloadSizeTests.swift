import Testing
import CSUpdate

/// A download that goes past the size the release lists is stopped at once, as a size mismatch, not downloaded to the end.
struct DownloadSizeTests {
    enum Count: Sendable { case received, announced }

    /// Up to exactly the listed size is fine; one byte more is too much. The server saying up front that it will send
    /// more than listed is as bad as sending it; an unknown length (-1, URLSession's NSURLSessionTransferSizeUnknown) is
    /// not.
    @Test(arguments: [
        (.received, 0, false), (.received, 999, false), (.received, 1000, false), (.received, 1001, true),
        (.received, Int64.max, true),
        (.announced, 1001, true), (.announced, 1000, false), (.announced, 0, false), (.announced, -1, false),
    ] as [(Count, Int64, Bool)])
    func moreThanTheListedSizeIsTooMuch(count: Count, bytes: Int64, exceeds: Bool) {
        switch count {
        case .received: #expect(DownloadSize.exceeds(listed: 1000, received: bytes) == exceeds)
        case .announced: #expect(DownloadSize.exceeds(listed: 1000, announced: bytes) == exceeds)
        }
    }
}
