import Testing
import CSUpdate

/// Each install is an attempt, with its own tag. What an attempt reports comes back with its tag, and the flow takes it
/// only while that attempt is the one running: a late failure or progress report from an old attempt can't touch a new
/// attempt, or a check the person started after cancelling.
struct InstallFlowAttemptTests {
    typealias Event = InstallFlow.Event
    let release = InstallFlowTests.release

    /// (`#expect` can't wrap a mutating call, so the answer is read first.)
    func take(_ event: Event, _ flow: inout InstallFlow) -> Bool {
        flow.handle(event)
    }

    func flow(after events: Event...) -> InstallFlow {
        var flow = InstallFlow()
        for event in events {
            let accepted = flow.handle(event)
            #expect(accepted, "\(event)")
        }
        return flow
    }

    /// (`#expect` can't wrap a mutating call.)
    func send(_ event: Event, from attempt: InstallAttempt, to flow: inout InstallFlow) -> Bool {
        flow.handle(event, from: attempt)
    }

    @Test func theFlowHasNoAttemptUntilADownloadStarts() {
        #expect(InstallFlow().attempt == nil)
        #expect(flow(after: .checkStarted, .updateFound(release)).attempt == nil)
        let started = flow(after: .checkStarted, .updateFound(release), .downloadStarted)
        #expect(started.attempt != nil)
    }

    @Test func everyDownloadStartIsANewAttempt() throws {
        var flow = flow(after: .checkStarted, .updateFound(release), .downloadStarted)
        var seen: Set<InstallAttempt> = [try #require(flow.attempt)]
        for _ in 0..<3 {
            #expect(take(.failure(.downloadFailed), &flow))
            #expect(take(.retry, &flow))
            #expect(take(.downloadStarted, &flow))
            seen.insert(try #require(flow.attempt))
        }
        #expect(seen.count == 4)
    }

    @Test func anAttemptsEventsAreAcceptedWhileItRuns() throws {
        var flow = flow(after: .checkStarted, .updateFound(release), .downloadStarted)
        let attempt = try #require(flow.attempt)
        #expect(send(.downloadProgress(0.5), from: attempt, to: &flow))
        #expect(send(.downloadFinished, from: attempt, to: &flow))
        for step in VerifyStep.allCases where step != .gatekeeperApp {
            #expect(send(.stepPassed(step), from: attempt, to: &flow))
        }
        #expect(send(.installStarted, from: attempt, to: &flow))
        #expect(flow.attempt == attempt)
        #expect(send(.failure(.relaunchFailed), from: attempt, to: &flow))
        #expect(flow.state == .failed(.relaunchFailed))
    }

    @Test func aTaggedEventStillFollowsTheStateTable() throws {
        var flow = flow(after: .checkStarted, .updateFound(release), .downloadStarted)
        let attempt = try #require(flow.attempt)
        let before = flow
        #expect(!send(.installStarted, from: attempt, to: &flow))
        #expect(!send(.stepPassed(.checksum), from: attempt, to: &flow))
        #expect(flow == before)
    }

    @Test func anAttemptEndsWhenItCancelsFailsOrIsHandedOff() {
        var cancelled = flow(after: .checkStarted, .updateFound(release), .downloadStarted)
        #expect(take(.cancel, &cancelled))
        #expect(cancelled.attempt == nil)
        var failed = flow(after: .checkStarted, .updateFound(release), .downloadStarted)
        #expect(take(.failure(.downloadFailed), &failed))
        #expect(failed.attempt == nil)
        #expect(take(.retry, &failed))
        #expect(failed.attempt == nil)
        var handedOff = flow(after: .checkStarted, .updateFound(release), .downloadStarted, .downloadFinished)
        for step in VerifyStep.allCases where step != .gatekeeperApp { #expect(take(.stepPassed(step), &handedOff)) }
        #expect(handedOff.attempt != nil)
        #expect(take(.handOff, &handedOff))
        #expect(handedOff.attempt == nil)
    }

    @Test func aLateFailureFromAnOldAttemptCannotTouchANewOne() throws {
        var flow = flow(after: .checkStarted, .updateFound(release), .downloadStarted)
        let old = try #require(flow.attempt)
        #expect(take(.cancel, &flow))
        #expect(take(.retry, &flow))
        #expect(take(.downloadStarted, &flow))
        let new = try #require(flow.attempt)
        #expect(new != old)
        let before = flow
        #expect(!send(.failure(.downloadFailed), from: old, to: &flow))
        #expect(!send(.downloadProgress(0.9), from: old, to: &flow))
        #expect(!send(.downloadFinished, from: old, to: &flow))
        #expect(flow == before)
        #expect(flow.state == .downloading(progress: 0))
        // The new attempt's own report still lands.
        #expect(send(.downloadProgress(0.1), from: new, to: &flow))
    }

    @Test func aLateFailureFromACancelledAttemptCannotTouchACheck() throws {
        var flow = flow(after: .checkStarted, .updateFound(release), .downloadStarted)
        let old = try #require(flow.attempt)
        #expect(take(.cancel, &flow))
        #expect(take(.retry, &flow))
        #expect(take(.checkStarted, &flow))
        #expect(flow.state == .checking)
        let before = flow
        // A failure while checking is a legal event for a check, but not one that comes from an install attempt.
        #expect(!send(.failure(.downloadFailed), from: old, to: &flow))
        #expect(flow == before)
        #expect(flow.state == .checking)
    }

    @Test func aLateFailureAfterAFailureAndANewCheckIsRejected() throws {
        var flow = flow(after: .checkStarted, .updateFound(release), .downloadStarted)
        let old = try #require(flow.attempt)
        #expect(take(.failure(.downloadFailed), &flow))
        #expect(take(.checkStarted, &flow))
        let before = flow
        #expect(!send(.failure(.checksumMismatch), from: old, to: &flow))
        #expect(flow == before)
    }

    @Test func eventsFromAnAttemptAreRejectedOnceItHasEnded() throws {
        var flow = flow(after: .checkStarted, .updateFound(release), .downloadStarted)
        let attempt = try #require(flow.attempt)
        #expect(take(.cancel, &flow))
        let before = flow
        #expect(!send(.failure(.downloadFailed), from: attempt, to: &flow))
        #expect(flow == before)
    }

    @Test func untaggedEventsKeepWorkingAsBefore() {
        var flow = flow(after: .checkStarted, .updateFound(release), .downloadStarted)
        #expect(take(.downloadProgress(0.3), &flow))
        #expect(take(.failure(.downloadFailed), &flow))
        #expect(flow.state == .failed(.downloadFailed))
    }
}
