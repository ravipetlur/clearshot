import Testing
import CSUpdate

/// When the app's folder isn't writable the install ends in a hand-off: every check passed, the disk image stays mounted
/// and the person drags the app to Applications. It is no error, can't be cancelled, and is left only by dismissing.
struct InstallFlowHandOffTests {
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

    /// The flow at the last verify step, where a hand-off or the install begins.
    func lastStep() -> InstallFlow {
        var events: [Event] = [.checkStarted, .updateFound(release), .downloadStarted, .downloadFinished]
        for step in VerifyStep.allCases where step != .gatekeeperApp { events.append(.stepPassed(step)) }
        var flow = InstallFlow()
        for event in events {
            let accepted = flow.handle(event)
            #expect(accepted, "\(event)")
        }
        return flow
    }

    @Test func aHandOffComesFromTheLastVerifyStep() {
        var flow = lastStep()
        #expect(flow.state == .verifying(step: .gatekeeperApp))
        let accepted = flow.handle(.handOff)
        #expect(accepted)
        #expect(flow.state == .handedOff(release))
        #expect(flow.release == release)
    }

    @Test func aHandOffIsNotCancellable() {
        var flow = lastStep()
        #expect(take(.handOff, &flow))
        #expect(!flow.canCancel)
        let before = flow
        let cancelled = flow.handle(.cancel)
        #expect(!cancelled)
        #expect(flow == before)
    }

    @Test func aHandOffIsRejectedFromEveryOtherPlace() {
        var others: [InstallFlow] = [
            InstallFlow(),
            flow(after: .checkStarted),
            flow(after: .checkStarted, .updateFound(release)),
            flow(after: .checkStarted, .updateFound(release), .downloadStarted),
            flow(after: .checkStarted, .updateFound(release), .downloadStarted, .cancel),
            flow(after: .checkStarted, .updateFound(release), .downloadStarted, .failure(.downloadFailed)),
        ]
        var early = flow(after: .checkStarted, .updateFound(release), .downloadStarted, .downloadFinished)
        for step in VerifyStep.allCases where step != .gatekeeperApp {
            others.append(early)
            #expect(take(.stepPassed(step), &early))
        }
        var installing = lastStep()
        #expect(take(.installStarted, &installing))
        others.append(installing)
        for start in others {
            var trial = start
            let accepted = trial.handle(.handOff)
            #expect(!accepted, "\(start.state)")
            #expect(trial == start)
        }
    }

    /// The hand-off is left with `dismiss` and nothing else: the image stays mounted for the person, and a new check or a
    /// retry would start over under it.
    @Test func aHandOffIsLeftOnlyByDismissing() {
        var handedOff = lastStep()
        #expect(take(.handOff, &handedOff))
        let others: [Event] = [
            .checkStarted, .updateFound(release), .noUpdateFound, .downloadStarted, .downloadProgress(0.5),
            .downloadFinished, .stepPassed(.gatekeeperApp), .installStarted, .failure(.installFailed), .cancel, .retry,
            .handOff,
        ]
        for event in others {
            var trial = handedOff
            let accepted = trial.handle(event)
            #expect(!accepted, "\(event)")
            #expect(trial == handedOff, "\(event)")
        }
        var dismissed = handedOff
        let accepted = dismissed.handle(.dismiss)
        #expect(accepted)
        #expect(dismissed.state == .idle)
        #expect(dismissed.release == nil)
        #expect(dismissed.attempt == nil)
    }

    @Test func noBackgroundCheckStartsUnderAHandOff() {
        #expect(!UpdateSchedule.backgroundCheckMayStart(state: .handedOff(release), offerWindowOpen: false))
        #expect(!UpdateSchedule.backgroundCheckMayStart(state: .handedOff(release), offerWindowOpen: true))
    }
}
