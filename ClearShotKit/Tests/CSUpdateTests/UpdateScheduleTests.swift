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

    // MARK: Automatic off

    @Test func automaticOffNeverSchedulesACheck() {
        #expect(next(lastCheck: nil, automatic: false) == nil)
        #expect(next(lastCheck: now.addingTimeInterval(-hour), automatic: false) == nil)
        #expect(next(lastCheck: now.addingTimeInterval(-3 * day), automatic: false) == nil)
        #expect(next(lastCheck: now.addingTimeInterval(day), automatic: false) == nil)
    }

    // MARK: The first check

    @Test func theFirstCheckFollowsTheLaunchNotTheClock() {
        let freshLaunch = now
        #expect(next(lastCheck: nil, launch: freshLaunch) == now.addingTimeInterval(5 * minute))
        let earlier = now.addingTimeInterval(-2 * hour)
        #expect(next(lastCheck: nil, launch: earlier) == earlier.addingTimeInterval(5 * minute))
    }

    // MARK: A recent, stale or future last check

    /// Seconds from "now", for the table below; the app launched an hour before now.
    static let oneHour: TimeInterval = 3600
    static let oneDay: TimeInterval = 86_400
    /// Five minutes after the launch.
    static let firstCheck: TimeInterval = -oneHour + 5 * 60

    /// A recent check (an hour ago, just now, almost a day ago) is followed a day after it. A stale one (a day and a
    /// second ago, 90 days ago) starts over five minutes after launch; exactly a day old isn't older than a day, so the
    /// next check is the last check plus a day, which is now. A last check in the future (the clock moved back, by a
    /// second, three hours or 400 days) counts as now: the next check is a day from now.
    @Test(arguments: [
        // (the last check, the next check: seconds from now)
        (-oneHour, -oneHour + oneDay), (0, oneDay), (-(oneDay - 30), 30),
        (-oneDay - 1, firstCheck), (-90 * oneDay, firstCheck), (-oneDay, 0),
        (3 * oneHour, oneDay), (400 * oneDay, oneDay), (1, oneDay),
    ] as [(TimeInterval, TimeInterval)])
    func theNextCheckFollowsTheLastOne(lastCheck: TimeInterval, nextCheck: TimeInterval) {
        #expect(next(lastCheck: now.addingTimeInterval(lastCheck)) == now.addingTimeInterval(nextCheck))
    }

    @Test func theLaunchTimeDoesNotMatterWhenTheLastCheckIsRecent() {
        let last = now.addingTimeInterval(-hour)
        #expect(next(lastCheck: last, launch: now) == last.addingTimeInterval(day))
        #expect(next(lastCheck: last, launch: now.addingTimeInterval(-10 * day)) == last.addingTimeInterval(day))
    }

    // MARK: No drift

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
    /// schedule has one fixed answer from then on instead of one that moves each time it's asked. A last check now or
    /// earlier is kept, and no last check stays none.
    @Test(arguments: [
        // (the stored last check, the corrected one: seconds from now)
        (3 * oneHour, 0), (1, 0), (400 * oneDay, 0),
        (0, 0), (-1, -1), (-oneHour, -oneHour), (-90 * oneDay, -90 * oneDay),
        (nil, nil),
    ] as [(TimeInterval?, TimeInterval?)])
    func aLastCheckInTheFutureIsReplacedByNow(stored: TimeInterval?, corrected: TimeInterval?) {
        #expect(UpdateSchedule.correctedLastCheck(stored: stored.map(now.addingTimeInterval), now: now)
            == corrected.map(now.addingTimeInterval))
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
