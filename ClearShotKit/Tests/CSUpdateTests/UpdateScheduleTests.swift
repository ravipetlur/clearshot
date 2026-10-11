import Foundation
import Testing
import CSUpdate

struct UpdateScheduleTests {
    let minute: TimeInterval = 60
    let hour: TimeInterval = 3600
    let day: TimeInterval = 86_400

    /// Fixed instants, so the arithmetic is exact: the app launched an hour before "now".
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var launch: Date { now.addingTimeInterval(-3600) }

    func next(lastCheck: Date?, launch: Date? = nil, now: Date? = nil, automatic: Bool = true) -> Date? {
        UpdateSchedule.nextCheck(lastCheck: lastCheck, launch: launch ?? self.launch, now: now ?? self.now, automatic: automatic)
    }

    // MARK: The constants

    @Test func theDelaysAreFiveMinutesAndADay() {
        #expect(UpdateSchedule.firstCheckDelay == 5 * 60)
        #expect(UpdateSchedule.interval == 24 * 3600)
    }

    // MARK: Automatic off

    @Test func automaticOffNeverSchedulesACheck() {
        #expect(next(lastCheck: nil, automatic: false) == nil)
        #expect(next(lastCheck: now.addingTimeInterval(-hour), automatic: false) == nil)
        #expect(next(lastCheck: now.addingTimeInterval(-3 * day), automatic: false) == nil)
        #expect(next(lastCheck: now.addingTimeInterval(day), automatic: false) == nil)
    }

    // MARK: The first check

    @Test func withoutALastCheckTheFirstCheckIsFiveMinutesAfterLaunch() {
        #expect(next(lastCheck: nil) == launch.addingTimeInterval(5 * minute))
    }

    @Test func theFirstCheckFollowsTheLaunchNotTheClock() {
        let freshLaunch = now
        #expect(next(lastCheck: nil, launch: freshLaunch) == now.addingTimeInterval(5 * minute))
        let earlier = now.addingTimeInterval(-2 * hour)
        #expect(next(lastCheck: nil, launch: earlier) == earlier.addingTimeInterval(5 * minute))
    }

    /// A date at or before `now` means "due". The schedule doesn't move it forward, so a long-running app that missed
    /// its slot (asleep, say) checks as soon as it looks.
    @Test func aFirstCheckInThePastIsDueNotPushedOut() throws {
        let due = try #require(next(lastCheck: nil, launch: now.addingTimeInterval(-2 * hour)))
        #expect(due < now)
    }

    // MARK: A recent check

    @Test func aRecentCheckIsFollowedADayLater() {
        let last = now.addingTimeInterval(-hour)
        #expect(next(lastCheck: last) == last.addingTimeInterval(day))
    }

    @Test func aCheckJustNowIsFollowedADayLater() {
        #expect(next(lastCheck: now) == now.addingTimeInterval(day))
    }

    @Test func aCheckAlmostADayAgoIsDueInAMoment() {
        let last = now.addingTimeInterval(-(day - 30))
        #expect(next(lastCheck: last) == now.addingTimeInterval(30))
    }

    @Test func theLaunchTimeDoesNotMatterWhenTheLastCheckIsRecent() {
        let last = now.addingTimeInterval(-hour)
        #expect(next(lastCheck: last, launch: now) == last.addingTimeInterval(day))
        #expect(next(lastCheck: last, launch: now.addingTimeInterval(-10 * day)) == last.addingTimeInterval(day))
    }

    // MARK: A stale check

    @Test func aStaleCheckStartsOverFiveMinutesAfterLaunch() {
        let last = now.addingTimeInterval(-day - 1)
        #expect(next(lastCheck: last) == launch.addingTimeInterval(5 * minute))
    }

    @Test func aVeryOldCheckStartsOverFiveMinutesAfterLaunch() {
        let last = now.addingTimeInterval(-90 * day)
        #expect(next(lastCheck: last) == launch.addingTimeInterval(5 * minute))
    }

    /// Exactly a day old isn't older than a day: the next check is the last check plus a day, which is now.
    @Test func aCheckExactlyADayOldIsDueNow() {
        let last = now.addingTimeInterval(-day)
        #expect(next(lastCheck: last) == now)
    }

    // MARK: The clock moved back

    @Test func aLastCheckInTheFutureCountsAsNow() {
        let last = now.addingTimeInterval(3 * hour)
        #expect(next(lastCheck: last) == now.addingTimeInterval(day))
    }

    @Test func aLastCheckFarInTheFutureStillWaitsOnlyADay() {
        let last = now.addingTimeInterval(400 * day)
        #expect(next(lastCheck: last) == now.addingTimeInterval(day))
    }

    @Test func aLastCheckASecondInTheFutureCountsAsNow() {
        #expect(next(lastCheck: now.addingTimeInterval(1)) == now.addingTimeInterval(day))
    }

    // MARK: No drift

    @Test func repeatedCallsAtTheSameNowAgree() {
        for last in [nil, now.addingTimeInterval(-hour), now.addingTimeInterval(-2 * day), now.addingTimeInterval(2 * hour)] {
            let first = next(lastCheck: last)
            for _ in 0..<5 { #expect(next(lastCheck: last) == first) }
        }
    }

    /// The time of the next check comes from the last check, not from when it's asked: asking again later doesn't push
    /// it out.
    @Test func askingLaterDoesNotMoveTheNextCheck() {
        let last = now.addingTimeInterval(-hour)
        let expected = last.addingTimeInterval(day)
        for later in stride(from: 0.0, through: 22 * hour, by: hour) {
            #expect(next(lastCheck: last, now: now.addingTimeInterval(later)) == expected)
        }
    }

    @Test func aFirstCheckDoesNotMoveEitherAsTimePasses() {
        let expected = launch.addingTimeInterval(5 * minute)
        for later in stride(from: 0.0, through: 6 * hour, by: hour) {
            #expect(next(lastCheck: nil, now: now.addingTimeInterval(later)) == expected)
        }
    }

    /// The app checks when a check is due and records the time of the check: the next one is then a day after it.
    @Test func eachCheckMakesTheNextOneADayLater() throws {
        var clock = now
        var last: Date? = nil
        for _ in 0..<4 {
            let due = try #require(next(lastCheck: last, now: clock))
            clock = max(due, clock)
            last = clock
            #expect(next(lastCheck: last, now: clock) == clock.addingTimeInterval(day))
        }
    }

    // MARK: Correcting the stored last check

    /// A last check later than `now` means the clock moved back. The app overwrites the stored value with `now`, so the
    /// schedule has one fixed answer from then on instead of one that moves each time it's asked.
    @Test func aLastCheckInTheFutureIsReplacedByNow() {
        #expect(UpdateSchedule.correctedLastCheck(stored: now.addingTimeInterval(3 * hour), now: now) == now)
        #expect(UpdateSchedule.correctedLastCheck(stored: now.addingTimeInterval(1), now: now) == now)
        #expect(UpdateSchedule.correctedLastCheck(stored: now.addingTimeInterval(400 * day), now: now) == now)
    }

    @Test func aLastCheckNowOrEarlierIsKept() {
        for last in [now, now.addingTimeInterval(-1), now.addingTimeInterval(-hour), now.addingTimeInterval(-90 * day)] {
            #expect(UpdateSchedule.correctedLastCheck(stored: last, now: now) == last)
        }
    }

    @Test func noLastCheckStaysNone() {
        #expect(UpdateSchedule.correctedLastCheck(stored: nil, now: now) == nil)
    }

    /// Without the correction, asking later gives a later answer (the last check counts as the moment of asking). With
    /// it, the answer is the same at every later time.
    @Test func afterTheCorrectionTheNextCheckStopsMoving() throws {
        let stored = now.addingTimeInterval(5 * hour)
        let corrected = UpdateSchedule.correctedLastCheck(stored: stored, now: now)
        let expected = now.addingTimeInterval(day)
        for later in stride(from: 0.0, through: 20 * hour, by: hour) {
            let again = UpdateSchedule.correctedLastCheck(stored: corrected, now: now.addingTimeInterval(later))
            #expect(again == corrected)
            #expect(next(lastCheck: again, now: now.addingTimeInterval(later)) == expected)
        }
        // The uncorrected value drifts: that is the problem the correction solves.
        #expect(next(lastCheck: stored, now: now.addingTimeInterval(hour)) != next(lastCheck: stored))
    }

    // MARK: Whether a background check may start

    static let release = InstallFlowTests.release

    /// Every place the flow can be, in one list.
    static var allStates: [InstallFlow.State] {
        var states: [InstallFlow.State] = [
            .idle, .checking, .available(release), .downloading(progress: 0), .downloading(progress: 0.5),
            .installing, .failed(.network), .failed(.installFailed), .cancelled, .upToDate, .handedOff(release),
        ]
        states += VerifyStep.allCases.map { .verifying(step: $0) }
        return states
    }

    @Test func aBackgroundCheckMayStartWhenNothingIsRunning() {
        let resting: [InstallFlow.State] = [
            .idle, .upToDate, .available(Self.release), .failed(.network), .failed(.installFailed), .cancelled,
        ]
        for state in resting {
            #expect(UpdateSchedule.backgroundCheckMayStart(state: state, offerWindowOpen: false), "\(state)")
        }
    }

    @Test func noBackgroundCheckWhileACheckADownloadAVerificationOrAnInstallRuns() {
        var running: [InstallFlow.State] = [.checking, .downloading(progress: 0), .downloading(progress: 0.7), .installing]
        running += VerifyStep.allCases.map { .verifying(step: $0) }
        for state in running {
            #expect(!UpdateSchedule.backgroundCheckMayStart(state: state, offerWindowOpen: false), "\(state)")
        }
    }

    @Test func noBackgroundCheckWhileTheOfferWindowIsOpen() {
        for state in Self.allStates {
            #expect(!UpdateSchedule.backgroundCheckMayStart(state: state, offerWindowOpen: true), "\(state)")
        }
    }
}
