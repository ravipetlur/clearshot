import Foundation
import Testing
import CSUpdate

/// The line in Settings › About: "Last checked: <relative time>".
struct LastCheckedTextTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let english = Locale(identifier: "en_US")

    func text(_ ago: TimeInterval?) -> String {
        LastChecked.text(lastCheck: ago.map { now.addingTimeInterval(-$0) }, now: now, locale: english)
    }

    @Test func neverCheckedSaysNever() {
        #expect(text(nil) == "Last checked: never")
    }

    @Test func underAMinuteIsJustNow() {
        #expect(text(0) == "Last checked: just now")
        #expect(text(10) == "Last checked: just now")
        #expect(text(59) == "Last checked: just now")
    }

    /// A last check in the future (the clock moved back) reads as just now until the center corrects it.
    @Test func aCheckInTheFutureIsJustNow() {
        #expect(LastChecked.text(lastCheck: now.addingTimeInterval(3600), now: now, locale: english) == "Last checked: just now")
    }

    @Test func minutesHoursAndDaysAreSpelledOut() {
        #expect(text(5 * 60) == "Last checked: 5 minutes ago")
        #expect(text(2 * 3600) == "Last checked: 2 hours ago")
        #expect(text(86_400) == "Last checked: yesterday")
        #expect(text(3 * 86_400) == "Last checked: 3 days ago")
    }

    @Test func aMinuteIsOneMinute() {
        #expect(text(60) == "Last checked: 1 minute ago")
    }
}
