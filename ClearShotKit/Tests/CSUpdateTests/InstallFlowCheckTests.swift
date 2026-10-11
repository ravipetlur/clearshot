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

    @Test func aFailedCheckWithNothingOnOfferGoesBackToIdle() {
        var flow = flow(after: .checkStarted)
        #expect(settle(&flow, .network))
        #expect(flow.state == .idle)
        #expect(flow.release == nil)
    }

    @Test func aFailedCheckAfterUpToDateGoesBackToIdle() {
        var flow = flow(after: .checkStarted, .noUpdateFound, .checkStarted)
        #expect(settle(&flow, .rateLimited))
        #expect(flow.state == .idle)
        #expect(flow.release == nil)
    }

    @Test func aFailedCheckKeepsTheOfferThatWasStanding() {
        var flow = flow(after: .checkStarted, .updateFound(release), .checkStarted)
        #expect(settle(&flow, .serverError))
        #expect(flow.state == .available(release))
        #expect(flow.release == release)
    }

    @Test func aFailedCheckAfterAFailedInstallOffersTheReleaseAgain() {
        var flow = flow(after: .checkStarted, .updateFound(release), .downloadStarted, .failure(.downloadFailed), .checkStarted)
        #expect(settle(&flow, .network))
        #expect(flow.state == .available(release))
    }

    @Test func aFailedCheckAfterACancelOffersTheReleaseAgain() {
        var flow = flow(after: .checkStarted, .updateFound(release), .downloadStarted, .cancel, .checkStarted)
        #expect(settle(&flow, .network))
        #expect(flow.state == .available(release))
    }

    @Test func settlingNeverLeavesTheFailedState() {
        for failure in [UpdateFailure.network, .rateLimited, .serverError] {
            var flow = flow(after: .checkStarted, .updateFound(release), .checkStarted)
            #expect(settle(&flow, failure))
            if case .failed = flow.state { Issue.record("still failed after \(failure)") }
        }
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

struct UpdateFailureErrorTests {
    /// The installer throws a failure, and the update center reads it back.
    @Test func aFailureCanBeThrownAndCaught() {
        func throwing() throws { throw UpdateFailure.checksumMismatch }
        do {
            try throwing()
            Issue.record("did not throw")
        } catch let failure as UpdateFailure {
            #expect(failure == .checksumMismatch)
        } catch {
            Issue.record("a different error: \(error)")
        }
    }
}
