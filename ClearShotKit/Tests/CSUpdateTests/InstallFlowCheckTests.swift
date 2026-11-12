import Testing
import CSUpdate

/// A check that fails must not lose an offer that was standing, and never leaves the flow in the failed state: the
/// failure is shown once, by the caller, and the flow settles.
struct InstallFlowCheckTests {
    let release = InstallFlowTests.release

    /// (`#expect` can't wrap a mutating call, so the answer is read first.)
    func settle(_ flow: inout InstallFlow, _ failure: UpdateFailure) -> Bool {
        flow.settleAfterFailedCheck(failure)
    }

    func flow(after events: InstallFlow.Event...) -> InstallFlow {
        var flow = InstallFlow()
        for event in events {
            let accepted = flow.handle(event)
            #expect(accepted, "\(event)")
        }
        return flow
    }

    /// With nothing on offer (no check before, or one that found the app up to date), a failed check goes back to idle.
    @Test(arguments: [
        ([InstallFlow.Event.checkStarted], UpdateFailure.network),
        ([.checkStarted, .noUpdateFound, .checkStarted], .rateLimited),
    ])
    func aFailedCheckWithNothingOnOfferGoesBackToIdle(events: [InstallFlow.Event], failure: UpdateFailure) {
        var flow = InstallFlow()
        for event in events {
            let accepted = flow.handle(event)
            #expect(accepted, "\(event)")
        }
        #expect(settle(&flow, failure))
        #expect(flow.state == .idle)
        #expect(flow.release == nil)
    }

    /// The offer that was standing is kept, or offered again after a failed install or a cancel.
    @Test(arguments: [
        ([InstallFlow.Event.checkStarted, .updateFound(InstallFlowTests.release), .checkStarted], UpdateFailure.serverError),
        ([.checkStarted, .updateFound(InstallFlowTests.release), .downloadStarted, .failure(.downloadFailed), .checkStarted],
         .network),
        ([.checkStarted, .updateFound(InstallFlowTests.release), .downloadStarted, .cancel, .checkStarted], .network),
    ])
    func aFailedCheckKeepsTheOfferThatWasStanding(events: [InstallFlow.Event], failure: UpdateFailure) {
        var flow = InstallFlow()
        for event in events {
            let accepted = flow.handle(event)
            #expect(accepted, "\(event)")
        }
        #expect(settle(&flow, failure))
        #expect(flow.state == .available(release))
        #expect(flow.release == release)
    }

    /// Only a check that is running can fail: anything else is a late result, and changes nothing.
    @Test func settlingWhenNoCheckIsRunningIsRejectedAndChangesNothing() {
        let flows: [InstallFlow] = [
            InstallFlow(),
            flow(after: .checkStarted, .noUpdateFound),
            flow(after: .checkStarted, .updateFound(release)),
            flow(after: .checkStarted, .updateFound(release), .downloadStarted),
            flow(after: .checkStarted, .updateFound(release), .downloadStarted, .downloadFinished),
            flow(after: .checkStarted, .updateFound(release), .downloadStarted, .failure(.downloadFailed)),
            flow(after: .checkStarted, .updateFound(release), .downloadStarted, .cancel),
        ]
        for original in flows {
            var trial = original
            #expect(!settle(&trial, .network), "\(original.state)")
            #expect(trial == original)
        }
    }
}
