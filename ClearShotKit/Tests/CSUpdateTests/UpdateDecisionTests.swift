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

    /// Only a strictly newer release is offered, compared numerically (1.10 is after 1.9): never the same version or a
    /// downgrade, and nothing when there is no release. The skipped version isn't offered, nor is a release older than
    /// it: a skip means "this one and anything before it", so if the skipped release is pulled and an older one becomes
    /// the latest, a newer one has already been declined. A newer one than the skipped one is offered, and a skip older
    /// than the running version changes nothing.
    @Test(arguments: [
        // (current, latest, skipped, offered)
        ("1.1.0", "1.2.0", nil, true),
        ("1.1.0", "1.1.0", nil, false),
        ("1.2.0", "1.1.0", nil, false),
        ("1.10.0", "1.9.9", nil, false),
        ("1.9.9", "1.10.0", nil, true),
        ("1.1.0", nil, nil, false),
        ("1.1.0", nil, "1.2.0", false),
        ("1.1.0", "1.2.0", "1.2.0", false),
        ("1.1.0", "1.3.0", "1.2.0", true),
        ("1.1.0", "1.2.0", "1.0.5", true),
        ("1.1.0", "1.2.0", "1.3.0", false),
        ("1.3.0", "1.3.0", "1.3.0", false),
    ] as [(String, String?, String?, Bool)])
    func offersOnlyANewerReleaseThatWasNotSkipped(current: String, latest: String?, skipped: String?, offered: Bool) throws {
        let latestRelease = try latest.map(release)
        let offer = UpdateDecision.offer(current: try version(current), latest: latestRelease, skipped: try skipped.map(version))
        #expect(offer == (offered ? latestRelease : nil))
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
