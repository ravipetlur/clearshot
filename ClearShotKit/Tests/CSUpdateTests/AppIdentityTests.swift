import Testing
import CSUpdate

/// Whether the app inside the downloaded image is the app that was offered: this app's bundle identifier, and the
/// offered version, which is newer than the running one.
struct AppIdentityTests {
    let running = VersionNumber("1.1.0")!
    let offered = VersionNumber("1.2.0")!
    let identifier = "com.example.clearshot"

    func mismatch(
        identifier found: String? = "com.example.clearshot", version: String? = "1.2.0", offered: VersionNumber? = nil,
        running: VersionNumber? = nil
    ) -> UpdateFailure? {
        AppIdentity.mismatch(bundleIdentifier: found, shortVersion: version, expectedIdentifier: identifier,
                             offered: offered ?? self.offered, running: running ?? self.running)
    }

    @Test func theOfferedAppPasses() {
        #expect(mismatch() == nil)
    }

    @Test func aDifferentIdentifierIsRejected() {
        #expect(mismatch(identifier: "com.example.other") == .appIdentifierMismatch)
        #expect(mismatch(identifier: "com.example.clearshot.helper") == .appIdentifierMismatch)
        #expect(mismatch(identifier: "COM.EXAMPLE.CLEARSHOT") == .appIdentifierMismatch)
        #expect(mismatch(identifier: " com.example.clearshot") == .appIdentifierMismatch)
    }

    @Test func aMissingOrEmptyIdentifierIsRejected() {
        #expect(mismatch(identifier: nil) == .appIdentifierMismatch)
        #expect(mismatch(identifier: "") == .appIdentifierMismatch)
    }

    /// Without an identifier of its own the running app has nothing to compare with, so nothing passes.
    @Test func anEmptyExpectedIdentifierPassesNothing() {
        #expect(AppIdentity.mismatch(bundleIdentifier: "", shortVersion: "1.2.0", expectedIdentifier: "",
                                     offered: offered, running: running) == .appIdentifierMismatch)
    }

    @Test func aDifferentVersionIsRejected() {
        #expect(mismatch(version: "1.2.1") == .appVersionMismatch)
        #expect(mismatch(version: "1.1.0") == .appVersionMismatch)
        #expect(mismatch(version: "1.10.0") == .appVersionMismatch)
    }

    @Test func aMissingOrMalformedVersionIsRejected() {
        for text in [nil, "", "1.2", "1.2.0.0", "1.2.0-beta.1", "v1.2.0", " 1.2.0", "1.2.0 ", "1.02.0", "one"] {
            #expect(mismatch(version: text) == .appVersionMismatch, "\(text ?? "nil")")
        }
    }

    /// The release was offered because it is newer than the running app. An app that isn't (or an offer that isn't) is
    /// never installed: no downgrade, no reinstalling the same version.
    @Test func theOfferedVersionMustBeNewerThanTheRunningOne() {
        #expect(mismatch(version: "1.1.0", offered: VersionNumber("1.1.0")!) == .appVersionMismatch)
        #expect(mismatch(version: "1.0.0", offered: VersionNumber("1.0.0")!) == .appVersionMismatch)
    }

    @Test func theIdentifierIsCheckedBeforeTheVersion() {
        #expect(mismatch(identifier: "com.example.other", version: "9.9.9") == .appIdentifierMismatch)
    }

    @Test func aNewerMajorOrMinorVersionPasses() {
        #expect(mismatch(version: "2.0.0", offered: VersionNumber("2.0.0")!) == nil)
        #expect(mismatch(version: "1.10.0", offered: VersionNumber("1.10.0")!, running: VersionNumber("1.9.9")!) == nil)
    }
}
