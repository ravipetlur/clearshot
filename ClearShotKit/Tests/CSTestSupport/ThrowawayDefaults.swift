import Foundation

/// A `UserDefaults` suite of a test's own, gone when the test is done. Every test that needs preferences makes them with
/// this, so none can leave files behind.
///
/// The suite is named by a path in a temporary folder of its own (CFPreferences keeps a suite named by an absolute path in
/// that path plus `.plist`), so it never reaches the user's ~/Library/Preferences. There, a test suite's file can't be
/// cleaned up reliably: after `removePersistentDomain` the preferences daemon writes the emptied domain out again on its
/// own schedule, up to a minute later and after the test process has quit. Here the domain is removed and its folder
/// deleted, so a late write has nowhere to go.
///
/// It cleans up when it is released, so hold it for as long as its defaults are used: as a test suite's stored property,
/// or through `withThrowawayDefaults` inside one test. (A local that is only read from once may be released straight
/// after that read.)
public final class ThrowawayDefaults {
    /// The suite's name: `<temporary folder>/test.clearshot.<label>`, the folder being this suite's alone.
    public let name: String
    public let defaults: UserDefaults
    private let folder: URL

    public init(_ label: String) {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "clearshot-test-defaults-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        name = folder.appending(path: "test.clearshot.\(label)").path
        defaults = UserDefaults(suiteName: name)!
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(at: folder)
    }

    /// The file the preferences daemon keeps the suite named `name` in.
    public static func file(for name: String) -> URL {
        URL(filePath: name + ".plist")
    }
}

/// Runs `body` with a throwaway suite (`ThrowawayDefaults`) labelled `label`, which is gone when it returns.
public func withThrowawayDefaults<Result>(_ label: String, _ body: (UserDefaults) throws -> Result) rethrows -> Result {
    let throwaway = ThrowawayDefaults(label)
    return try withExtendedLifetime(throwaway) { try body(throwaway.defaults) }
}
