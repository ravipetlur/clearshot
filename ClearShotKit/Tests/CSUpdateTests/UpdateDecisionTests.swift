import Foundation
import Testing
import CSUpdate

struct UpdateDecisionTests {
    func version(_ text: String) throws -> VersionNumber {
        try #require(VersionNumber(text))
    }

    func release(_ text: String) throws -> ReleaseInfo {
        let version = try version(text)
        let base = "https://example.com/app/releases/download/v\(version)/ClearShot-\(version).dmg"
        return ReleaseInfo(
            version: version,
            notes: "Notes for \(version).",
            pageURL: URL(string: "https://example.com/app/releases/tag/v\(version)")!,
            dmg: .init(name: "ClearShot-\(version).dmg", size: 1000, url: URL(string: base)!),
            checksum: .init(name: "ClearShot-\(version).dmg.sha256", size: 86, url: URL(string: base + ".sha256")!))
    }

    @Test func offersAStrictlyNewerRelease() throws {
        let latest = try release("1.2.0")
        #expect(UpdateDecision.offer(current: try version("1.1.0"), latest: latest, skipped: nil) == latest)
    }

    @Test func offersNothingForTheSameVersion() throws {
        #expect(UpdateDecision.offer(current: try version("1.1.0"), latest: try release("1.1.0"), skipped: nil) == nil)
    }

    @Test func neverOffersADowngrade() throws {
        #expect(UpdateDecision.offer(current: try version("1.2.0"), latest: try release("1.1.0"), skipped: nil) == nil)
        #expect(UpdateDecision.offer(current: try version("1.10.0"), latest: try release("1.9.9"), skipped: nil) == nil)
    }

    @Test func comparesNumericallyAcrossTenAndNine() throws {
        let latest = try release("1.10.0")
        #expect(UpdateDecision.offer(current: try version("1.9.9"), latest: latest, skipped: nil) == latest)
    }

    @Test func offersNothingWhenThereIsNoRelease() throws {
        #expect(UpdateDecision.offer(current: try version("1.1.0"), latest: nil, skipped: nil) == nil)
        #expect(UpdateDecision.offer(current: try version("1.1.0"), latest: nil, skipped: try version("1.2.0")) == nil)
    }

    @Test func doesNotOfferTheSkippedVersion() throws {
        #expect(UpdateDecision.offer(current: try version("1.1.0"), latest: try release("1.2.0"), skipped: try version("1.2.0")) == nil)
    }

    @Test func offersAVersionNewerThanTheSkippedOne() throws {
        let latest = try release("1.3.0")
        #expect(UpdateDecision.offer(current: try version("1.1.0"), latest: latest, skipped: try version("1.2.0")) == latest)
    }

    @Test func aSkipOlderThanTheRunningVersionChangesNothing() throws {
        let latest = try release("1.2.0")
        #expect(UpdateDecision.offer(current: try version("1.1.0"), latest: latest, skipped: try version("1.0.5")) == latest)
    }

    /// A skip means "this one and anything before it": if the skipped release is pulled and an older one becomes the
    /// latest, a newer one has already been declined, so the older one isn't offered either.
    @Test func aReleaseOlderThanTheSkippedOneIsNotOffered() throws {
        #expect(UpdateDecision.offer(current: try version("1.1.0"), latest: try release("1.2.0"), skipped: try version("1.3.0")) == nil)
    }

    @Test func skippingTheRunningVersionOffersNothing() throws {
        #expect(UpdateDecision.offer(current: try version("1.3.0"), latest: try release("1.3.0"), skipped: try version("1.3.0")) == nil)
    }

    // MARK: What counts as the current version

    /// After an update is installed but before the app has restarted into it, the version on disk is newer than the one
    /// running. A later check must not offer what is already installed, so it counts as the current version.
    @Test func theInstalledVersionCountsAsCurrentOnceItIsNewer() throws {
        #expect(UpdateDecision.currentVersion(running: try version("1.2.0"), installed: try version("1.2.1")) == (try version("1.2.1")))
        #expect(UpdateDecision.currentVersion(running: try version("1.2.0"), installed: nil) == (try version("1.2.0")))
        #expect(UpdateDecision.currentVersion(running: try version("1.2.1"), installed: try version("1.2.0")) == (try version("1.2.1")))
        #expect(UpdateDecision.currentVersion(running: try version("1.2.0"), installed: try version("1.2.0")) == (try version("1.2.0")))
        #expect(UpdateDecision.currentVersion(running: try version("1.9.9"), installed: try version("1.10.0")) == (try version("1.10.0")))
    }

    @Test func aReleaseAlreadyInstalledIsNotOfferedAgain() throws {
        let latest = try release("1.2.1")
        let current = UpdateDecision.currentVersion(running: try version("1.2.0"), installed: try version("1.2.1"))
        #expect(UpdateDecision.offer(current: current, latest: latest, skipped: nil) == nil)
        // A newer one still is.
        #expect(UpdateDecision.offer(current: current, latest: try release("1.3.0"), skipped: nil) != nil)
    }
}
