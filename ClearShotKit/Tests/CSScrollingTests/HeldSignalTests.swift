import Testing
@testable import CSScrolling

/// The bounded wait the stitch tests make for an estimator to be reached (`HeldSignal`): it answers instead of hanging
/// when the stitching queue never gets there.
@Suite(.timeLimit(.minutes(10)))
struct HeldSignalTests {
    @Test func aSignalAlreadyGivenAnswersTrueAtOnce() async {
        let signal = HeldSignal()
        signal.give()
        #expect(await signal.wait(timeout: .seconds(30)))
    }

    @Test func aSignalGivenWhileWaitingAnswersTrue() async {
        let signal = HeldSignal()
        let waiting = Task { await signal.wait(timeout: .seconds(300)) }
        try? await Task.sleep(for: .milliseconds(50))
        signal.give()
        #expect(await waiting.value)
    }

    @Test func aSignalNeverGivenAnswersFalseAtTheTimeout() async {
        let signal = HeldSignal()
        let start = ContinuousClock.now
        #expect(await signal.wait(timeout: .milliseconds(100)) == false)
        #expect(ContinuousClock.now - start >= .milliseconds(100))
    }

    @Test func aCancelledWaitAnswersFalseWithoutWaitingForTheTimeout() async {
        let signal = HeldSignal()
        let waiting = Task { await signal.wait(timeout: .seconds(900)) }
        try? await Task.sleep(for: .milliseconds(50))
        let cancelled = ContinuousClock.now
        waiting.cancel()
        // A whole-suite run can keep the cooperative pool saturated for minutes, so the sleep above and the cancel can
        // both be scheduled very late, and the answer after the cancel can be too. The wait therefore gets a timeout far
        // beyond any of that, and the check is the time from the cancel to the answer: it must be well under the
        // timeout. A wait that ignored the cancellation would run the full 900 seconds, which this bound and the
        // suite's time limit both catch.
        #expect(await waiting.value == false)
        #expect(ContinuousClock.now - cancelled < .seconds(240))
    }

    @Test func aSignalGivenBeforeAZeroTimeoutIsStillSeen() async {
        let signal = HeldSignal()
        signal.give()
        // A zero timeout has already passed, and the condition is checked before the deadline.
        #expect(await signal.wait(timeout: .zero))
    }
}
