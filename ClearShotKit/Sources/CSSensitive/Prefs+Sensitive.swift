import CSCore
import Foundation

public extension Prefs {
    // The secrets check (Settings › Quick Access › Sensitive info).
    /// The master switch: whether a screenshot's thumbnail is scanned for sensitive text, and whether an Annotate editor checks its
    /// picture on its own (the tool strip's sensitive-info button). A click on that button, or Edit › Mask Sensitive Info, scans
    /// either way.
    static let sensitiveCheckEnabled = PrefKey("sensitiveCheckEnabled", default: true)
    /// Which kinds of finding a scan looks for, stored as the kinds' raw value (a number `defaults read` shows).
    static let sensitiveKinds = PrefKey("sensitiveKinds", default: SensitiveKinds.all)
}

/// Stored as the set's raw value. Bits that are no kind (a value from a later version, or one written by hand) are
/// dropped, so a stored number can never name a kind the scanner doesn't know. A set with no kind is a value of its own:
/// every category switched off, which `Preferences` must not turn back into the default.
extension SensitiveKinds: PrefValue {
    public static func read(from defaults: UserDefaults, key: String) -> SensitiveKinds? {
        guard let raw = defaults.object(forKey: key) as? Int else { return nil }
        // A negative number is no combination of kinds; read as a set of bits it would claim every one of them.
        guard raw >= 0 else { return nil }
        return SensitiveKinds(rawValue: raw).intersection(.all)
    }

    public func write(to defaults: UserDefaults, key: String) {
        defaults.set(rawValue, forKey: key)
    }
}
