import Foundation
import Testing
import CSUpdate

/// The update window's Return key: it installs only once the window has been key for a moment, so a Return meant for
/// the app the person was typing in can't install an update. A click on the button works at once. Time is measured on a
/// monotonic clock, so a change of the wall clock can't leave Return disabled (or enable it early).
struct DefaultActionArmingTests {
    let start = ContinuousClock.now

    func at(_ seconds: TimeInterval) -> ContinuousClock.Instant { start.advanced(by: .seconds(seconds)) }

    /// (`#expect` can't wrap a mutating call, so the answer is read first.)
    func observe(_ arming: inout DefaultActionArming, key: Bool, at seconds: TimeInterval) -> Bool {
        arming.observe(isKey: key, at: at(seconds))
    }

    @Test func theDelayIsOneAndAHalfSeconds() {
        #expect(DefaultActionArming.defaultDelay == 1.5)
        #expect(DefaultActionArming().delay == 1.5)
    }

    @Test func itStartsDisabled() {
        let arming = DefaultActionArming()
        #expect(!arming.isEnabled)
    }

    @Test func aWindowThatIsNotKeyNeverEnablesIt() {
        var arming = DefaultActionArming()
        for seconds in stride(from: 0.0, through: 10, by: 0.5) {
            #expect(!observe(&arming, key: false, at: seconds))
        }
        #expect(!arming.isEnabled)
    }

    @Test func itIsEnabledOnceTheWindowHasBeenKeyForTheDelay() {
        var arming = DefaultActionArming()
        #expect(!observe(&arming, key: true, at: 0))
        #expect(!observe(&arming, key: true, at: 0.5))
        #expect(!observe(&arming, key: true, at: 1.49))
        #expect(observe(&arming, key: true, at: 1.5))
        #expect(observe(&arming, key: true, at: 30))
        #expect(arming.isEnabled)
    }

    @Test func losingKeyDisablesItAndTheDelayStartsAgain() {
        var arming = DefaultActionArming()
        #expect(!observe(&arming, key: true, at: 0))
        #expect(observe(&arming, key: true, at: 2))
        #expect(!observe(&arming, key: false, at: 3))
        #expect(!arming.isEnabled)
        // Key again at 4: the wait is counted from there, not from 0.
        #expect(!observe(&arming, key: true, at: 4))
        #expect(!observe(&arming, key: true, at: 5.4))
        #expect(observe(&arming, key: true, at: 5.5))
    }

    /// Looking again and again doesn't move the start of the wait.
    @Test func repeatedLooksDoNotPushTheWaitOut() {
        var arming = DefaultActionArming()
        for seconds in stride(from: 0.0, to: 1.5, by: 0.1) {
            #expect(!observe(&arming, key: true, at: seconds))
        }
        #expect(observe(&arming, key: true, at: 1.5))
    }

    @Test func restartDisablesItAtOnce() {
        var arming = DefaultActionArming()
        #expect(!observe(&arming, key: true, at: 0))
        #expect(observe(&arming, key: true, at: 2))
        arming.restart()
        #expect(!arming.isEnabled)
        #expect(!observe(&arming, key: true, at: 2.1))
        #expect(observe(&arming, key: true, at: 3.6))
    }

    /// An observation dated before the wait began (which a monotonic clock doesn't produce) never enables it.
    @Test func anEarlierInstantKeepsItDisabled() {
        var arming = DefaultActionArming()
        #expect(!observe(&arming, key: true, at: 100))
        #expect(!observe(&arming, key: true, at: 50))
    }

    @Test func aDifferentDelayIsUsed() {
        var arming = DefaultActionArming(delay: 0.25)
        #expect(!observe(&arming, key: true, at: 0))
        #expect(!observe(&arming, key: true, at: 0.24))
        #expect(observe(&arming, key: true, at: 0.25))
    }
}
