import Foundation

/// ClearShotKit's core module: preferences, geometry, file naming, logging, permissions
/// and the action registry. Nothing in here creates windows or views.
public enum CSCore {
    /// The running app's bundle identifier, which each build sets (`PRODUCT_BUNDLE_IDENTIFIER`, from
    /// `Config/Defaults.xcconfig` or a `Config/Local.xcconfig`). Every identifier ClearShot names itself by derives
    /// from it through `identifier(_:)`: the log subsystem, the URL consent's keychain item, the project document type,
    /// the pasteboard type and the dispatch queue labels. Outside an app bundle (the package's tests), it is
    /// `fallbackBundleIdentifier`.
    public static let bundleIdentifier = bundleIdentifier(of: Bundle.main.bundleIdentifier,
                                                          bundleURL: Bundle.main.bundleURL)

    /// What `bundleIdentifier` is when the code isn't running in an app bundle.
    public static let fallbackBundleIdentifier = "com.example.clearshot"

    /// `bundleIdentifier` followed by `.suffix`: "com.example.clearshot.url-consent".
    public static func identifier(_ suffix: String) -> String {
        "\(bundleIdentifier).\(suffix)"
    }

    /// The identifier of the bundle at `bundleURL` when it is an app with one; `fallbackBundleIdentifier` otherwise
    /// (a test runner's bundle is the test tool's).
    static func bundleIdentifier(of identifier: String?, bundleURL: URL) -> String {
        guard bundleURL.pathExtension == "app", let identifier, !identifier.isEmpty else {
            return fallbackBundleIdentifier
        }
        return identifier
    }
}
