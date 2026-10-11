import Testing
import CSUpdate

struct OfferWindowPolicyTests {
    let v120 = VersionNumber("1.2.0")!
    let v121 = VersionNumber("1.2.1")!

    /// (`#expect` can't wrap a mutating call, so the answer is read first.)
    func shows(_ policy: inout OfferWindowPolicy, _ version: VersionNumber, manual: Bool) -> Bool {
        policy.shouldShowWindow(for: version, manual: manual)
    }

    @Test func aBackgroundCheckShowsTheWindowOncePerVersion() {
        var policy = OfferWindowPolicy()
        #expect(shows(&policy, v120, manual: false))
        #expect(!shows(&policy, v120, manual: false))
        #expect(!shows(&policy, v120, manual: false))
    }

    @Test func aNewerVersionShowsItsOwnWindow() {
        var policy = OfferWindowPolicy()
        #expect(shows(&policy, v120, manual: false))
        #expect(shows(&policy, v121, manual: false))
        #expect(!shows(&policy, v121, manual: false))
        // The older one has had its turn too.
        #expect(!shows(&policy, v120, manual: false))
    }

    @Test func aManualCheckAlwaysShowsTheWindow() {
        var policy = OfferWindowPolicy()
        #expect(shows(&policy, v120, manual: true))
        #expect(shows(&policy, v120, manual: true))
        #expect(shows(&policy, v120, manual: true))
    }

    @Test func aManualOfferCountsAsShownForLaterBackgroundChecks() {
        var policy = OfferWindowPolicy()
        #expect(shows(&policy, v120, manual: true))
        #expect(!shows(&policy, v120, manual: false))
    }

    @Test func aBackgroundOfferDoesNotStopALaterManualOne() {
        var policy = OfferWindowPolicy()
        #expect(shows(&policy, v120, manual: false))
        #expect(shows(&policy, v120, manual: true))
    }

    /// A new launch has a new policy, so the same version is shown again.
    @Test func aNewLaunchStartsAgain() {
        var first = OfferWindowPolicy()
        #expect(shows(&first, v120, manual: false))
        var second = OfferWindowPolicy()
        #expect(shows(&second, v120, manual: false))
    }
}
