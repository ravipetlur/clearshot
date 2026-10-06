import Foundation
import Testing
@testable import CSCore

@Test func bundleIdentifierComesFromTheAppBundle() {
    let app = URL(filePath: "/Applications/ClearShot.app")
    #expect(CSCore.bundleIdentifier(of: "test.clearshot.app", bundleURL: app) == "test.clearshot.app")
    // Not an app (a test runner, a command-line tool), or an app without one: the fallback.
    #expect(CSCore.bundleIdentifier(of: "com.apple.dt.xctest.tool", bundleURL: URL(filePath: "/usr/bin"))
        == CSCore.fallbackBundleIdentifier)
    #expect(CSCore.bundleIdentifier(of: nil, bundleURL: app) == CSCore.fallbackBundleIdentifier)
    #expect(CSCore.bundleIdentifier(of: "", bundleURL: app) == CSCore.fallbackBundleIdentifier)
}

@Test func testsRunOnTheFallbackIdentifier() {
    #expect(CSCore.bundleIdentifier == CSCore.fallbackBundleIdentifier)
    #expect(CSCore.identifier("url-consent") == "\(CSCore.fallbackBundleIdentifier).url-consent")
    #expect(Log.subsystem == CSCore.bundleIdentifier)
}
