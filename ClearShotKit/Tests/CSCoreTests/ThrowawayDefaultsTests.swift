import CSTestSupport
import Foundation
import Testing

/// Test preferences must leave nothing in the user's ~/Library/Preferences.
struct ThrowawayDefaultsTests {
    @Test func aThrowawaySuiteLeavesNothingBehind() {
        var throwaway: ThrowawayDefaults? = ThrowawayDefaults("selftest")
        let name = throwaway?.name ?? ""
        throwaway?.defaults.set(42, forKey: "answer")
        throwaway?.defaults.set("a value", forKey: "text")
        let file = ThrowawayDefaults.file(for: name)
        #expect(FileManager.default.fileExists(atPath: file.path), "the daemon keeps the suite in its own file")
        #expect(file.lastPathComponent == "test.clearshot.selftest.plist")
        // Never in the user's preferences, where the daemon would write the emptied domain out again later.
        let preferences = URL.libraryDirectory.appending(path: "Preferences", directoryHint: .isDirectory)
        #expect(!file.path.hasPrefix(preferences.path))
        throwaway = nil
        #expect(!FileManager.default.fileExists(atPath: file.path), "\(file.path) is left behind")
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path), "its folder is left behind")
    }

    @Test func withThrowawayDefaultsCleansUpWhenItReturns() {
        // A label of this test's own, to find the suite's file by: the closure is handed only the defaults.
        let label = "selftest-\(UUID().uuidString)"
        let temporary = FileManager.default.temporaryDirectory
        func suiteFiles() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [])
                .filter { $0.hasPrefix("clearshot-test-defaults-") }
                .map { temporary.appending(path: "\($0)/test.clearshot.\(label).plist").path }
                .filter { FileManager.default.fileExists(atPath: $0) }
        }
        withThrowawayDefaults(label) { defaults in
            defaults.set(42, forKey: "answer")
            #expect(defaults.integer(forKey: "answer") == 42)
            #expect(suiteFiles().count == 1)
        }
        #expect(suiteFiles().isEmpty)
    }
}
