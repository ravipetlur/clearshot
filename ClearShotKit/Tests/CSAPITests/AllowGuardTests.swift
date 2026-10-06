import CoreGraphics
import Foundation
import Testing
@testable import CSAPI

/// Clickjacking: another app can read the alert's place on screen and draw a decoy over Allow, letting the person's
/// clicks through. Allow is enabled only once the alert has been key and uncovered for 1.5 s without a break, and a
/// click on it is refused while another app's window covers it.
struct AllowGuardTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// Feeds `arming` what the alert was like at each moment; returns whether Allow was enabled after each.
    func run(_ arming: inout AllowArming, _ moments: [(ready: Bool, at: TimeInterval)]) -> [Bool] {
        moments.map { arming.observe(ready: $0.ready, at: at($0.at)) }
    }

    @Test func allowIsEnabledAfterTheDelayKeyAndUncovered() {
        var arming = AllowArming(delay: 1.5)
        let before = arming.isEnabled
        #expect(!before)
        let enabled = run(&arming, [(true, 0), (true, 1.49), (true, 1.5), (true, 9)])
        #expect(enabled == [false, false, true, true])
        let after = arming.isEnabled
        #expect(after)
    }

    /// Losing key, being hidden or covered: Allow is disabled at once, and the delay starts again when it is ready again.
    @Test func anyBreakStartsTheDelayAgain() {
        var arming = AllowArming(delay: 1.5)
        let enabled = run(&arming, [(true, 0), (true, 1.0), (false, 1.2), (true, 1.3), (true, 2.7), (true, 2.8),
                                    (false, 3), (true, 3.1)])
        #expect(enabled == [false, false, false, false, false, true, false, false])
        let after = arming.isEnabled
        #expect(!after)
    }

    /// A refused click (Allow covered), or a click on the alert while Allow is still disabled, starts the delay again: a
    /// stream of clicks can't run past it.
    @Test func aRefusedOrEarlyClickStartsTheDelayAgain() {
        var arming = AllowArming(delay: 1.5)
        let first = run(&arming, [(true, 0), (true, 1.5)])
        #expect(first == [false, true])
        arming.restart()
        let restarted = arming.isEnabled
        #expect(!restarted)
        let then = run(&arming, [(true, 1.6), (true, 3.0), (true, 3.1)])
        #expect(then == [false, false, true])
    }

    /// A click is judged on the alert as it is at that moment (key, visible, nothing over it, the delay run), never on
    /// the last poll. Armed a moment ago but covered now: refused, and the delay starts again.
    @Test func aClickIsJudgedOnTheAlertAsItIsThen() {
        var arming = AllowArming(delay: 1.5)
        let armed = run(&arming, [(true, 0), (true, 1.5)])
        #expect(armed == [false, true])
        let coveredClick = arming.click(ready: false, at: at(1.55))
        #expect(!coveredClick)
        let afterRefusal = arming.isEnabled
        #expect(!afterRefusal)
        let again = run(&arming, [(true, 1.6), (true, 3.0), (true, 3.1)])
        #expect(again == [false, false, true])
        let clearClick = arming.click(ready: true, at: at(3.2))
        #expect(clearClick)
        // A click before the delay has run is refused too, and restarts it.
        var early = AllowArming(delay: 1.5)
        _ = run(&early, [(true, 0)])
        let tooSoon = early.click(ready: true, at: at(1.0))
        #expect(!tooSoon)
        let restarted = run(&early, [(true, 1.6), (true, 3.0), (true, 3.1)])
        #expect(restarted == [false, false, true])
    }

    @Test func theDelayIsAllowsOwn() {
        let allow = URLConsent.buttons.first(where: \.allows)
        #expect(allow?.enabledAfter == 1.5)
        #expect(AllowArming().delay == 1.5)
    }

    /// Covered: a window of another process above the alert, not fully transparent, overlapping the target (both in the
    /// same coordinates). ClearShot's own windows (its HUD) and windows that only touch an edge don't count.
    @Test func allowIsCoveredOnlyByAnotherAppsWindowOverIt() {
        let own: Int32 = 123
        let allow = CGRect(x: 600, y: 400, width: 80, height: 24)
        func covered(_ windows: [ScreenWindow]) -> Bool {
            AllowGuard.isCovered(allow, by: windows, ownPID: own)
        }
        #expect(!covered([]))
        #expect(covered([ScreenWindow(ownerPID: 500, frame: CGRect(x: 0, y: 0, width: 3360, height: 1890), alpha: 1)]))
        #expect(covered([ScreenWindow(ownerPID: 500, frame: CGRect(x: 670, y: 420, width: 5, height: 5), alpha: 0.01)]))
        // Ours, or invisible, or elsewhere, or only touching.
        #expect(!covered([ScreenWindow(ownerPID: own, frame: allow, alpha: 1)]))
        #expect(!covered([ScreenWindow(ownerPID: 500, frame: allow, alpha: 0)]))
        #expect(!covered([ScreenWindow(ownerPID: 500, frame: CGRect(x: 0, y: 0, width: 100, height: 100), alpha: 1)]))
        #expect(!covered([ScreenWindow(ownerPID: 500, frame: CGRect(x: 680, y: 400, width: 50, height: 24), alpha: 1)]))
        #expect(!covered([ScreenWindow(ownerPID: 500, frame: CGRect(x: 600, y: 424, width: 80, height: 10), alpha: 1)]))
        // One covering window among harmless ones is enough.
        #expect(covered([ScreenWindow(ownerPID: own, frame: allow, alpha: 1),
                         ScreenWindow(ownerPID: 501, frame: CGRect(x: 650, y: 410, width: 100, height: 100), alpha: 1)]))
    }
}
