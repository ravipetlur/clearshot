import Foundation
import Testing
@testable import CSHistory

struct HistoryTimeTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let locale = Locale(identifier: "en_US")

    func label(secondsAgo: TimeInterval) -> String {
        HistoryTime.label(for: now.addingTimeInterval(-secondsAgo), now: now, locale: locale)
    }

    @Test func underAMinuteIsJustNow() {
        #expect(label(secondsAgo: 0) == "Just now")
        #expect(label(secondsAgo: 59.9) == "Just now")
    }

    @Test func aDateInTheFutureIsJustNow() {
        #expect(label(secondsAgo: -30) == "Just now")
    }

    @Test func olderDatesUseTheRelativeFormatter() {
        #expect(label(secondsAgo: 60) == "1 minute ago")
        #expect(label(secondsAgo: 59 * 60) == "59 minutes ago")
        #expect(label(secondsAgo: 3 * 3_600) == "3 hours ago")
        #expect(label(secondsAgo: 26 * 3_600) == "1 day ago")
        #expect(label(secondsAgo: 8 * 86_400) == "1 week ago")
    }
}
