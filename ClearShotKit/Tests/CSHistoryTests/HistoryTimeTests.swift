import Foundation
import Testing
@testable import CSHistory

struct HistoryTimeTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let locale = Locale(identifier: "en_US")

    func label(secondsAgo: TimeInterval) -> String {
        HistoryTime.label(for: now.addingTimeInterval(-secondsAgo), now: now, locale: locale)
    }

    @Test(arguments: [
        // Under a minute is just now, and so is a date in the future.
        (0, "Just now"),
        (59.9, "Just now"),
        (-30, "Just now"),
        // Older dates use the relative formatter.
        (60, "1 minute ago"),
        (59 * 60, "59 minutes ago"),
        (3 * 3_600, "3 hours ago"),
        (26 * 3_600, "1 day ago"),
        (8 * 86_400, "1 week ago"),
    ] as [(TimeInterval, String)])
    func theLabelSaysHowLongAgo(secondsAgo: TimeInterval, text: String) {
        #expect(label(secondsAgo: secondsAgo) == text)
    }
}
