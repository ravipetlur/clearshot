import Foundation
import Testing
import CSUpdate

/// The line in Settings › About: "Last checked: <relative time>".
struct LastCheckedTextTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let english = Locale(identifier: "en_US")

    /// Never; under a minute is just now; then minutes, hours and days, spelled out, with a minute as one minute.
    @Test(arguments: [
        (nil, "never"), (0, "just now"), (10, "just now"), (59, "just now"), (60, "1 minute ago"),
        (5 * 60, "5 minutes ago"), (2 * 3600, "2 hours ago"), (86_400, "yesterday"), (3 * 86_400, "3 days ago"),
    ] as [(TimeInterval?, String)])
    func theTimeSinceTheLastCheckIsSpelledOut(ago: TimeInterval?, when: String) {
        let text = LastChecked.text(lastCheck: ago.map { now.addingTimeInterval(-$0) }, now: now, locale: english)
        #expect(text == "Last checked: \(when)")
    }

    /// A last check in the future (the clock moved back) reads as just now until the center corrects it.
    @Test func aCheckInTheFutureIsJustNow() {
        #expect(LastChecked.text(lastCheck: now.addingTimeInterval(3600), now: now, locale: english) == "Last checked: just now")
    }
}
