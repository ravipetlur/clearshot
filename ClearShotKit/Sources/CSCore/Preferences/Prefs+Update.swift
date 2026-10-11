import Foundation

/// A date is kept as a plain date, which `defaults read` prints.
extension Date: PrefValue {
    public static func read(from defaults: UserDefaults, key: String) -> Date? { defaults.object(forKey: key) as? Date }
    public func write(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
}

/// A preference that may have no value: setting nil removes the key, and a missing or wrong-typed value reads as the key's
/// default. So an optional key's default has to be nil: with any other, setting nil would read back as that default.
/// Make optional keys with `PrefKey.optional`, which has no other default to give.
extension Optional: PrefValue where Wrapped: PrefValue {
    public static func read(from defaults: UserDefaults, key: String) -> Wrapped?? {
        Wrapped.read(from: defaults, key: key).map { Optional($0) }
    }

    public func write(to defaults: UserDefaults, key: String) {
        if let value = self {
            value.write(to: defaults, key: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

public extension PrefKey {
    /// A key whose value may be none, and is none until set (see the `Optional` conformance above).
    static func optional<Wrapped: PrefValue>(_ name: String) -> PrefKey where Value == Wrapped? {
        PrefKey(name, default: nil)
    }
}

public extension Prefs {
    // Updates (Settings › About); the updater is inert unless the build names an update repository.
    /// Check for a new version daily in the background. A manual check works either way.
    static let updateCheckAutomatically = PrefKey("updateCheckAutomatically", default: true)
    /// When the last check was made, a failed one included; none until the first.
    static let updateLastCheck = PrefKey<Date?>.optional("updateLastCheck")
    /// The version the person chose not to be offered (`X.Y.Z`); a newer one is offered again.
    static let updateSkippedVersion = PrefKey<String?>.optional("updateSkippedVersion")
}
