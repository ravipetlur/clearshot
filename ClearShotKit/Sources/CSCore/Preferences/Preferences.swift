import Foundation
import Observation

/// The single preferences store. Views observe it; any change re-renders the views that read it.
@MainActor
@Observable
public final class Preferences {
    @ObservationIgnored public let defaults: UserDefaults
    /// Bumped on every write so Observation sees a change for any key.
    private var revision = 0

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public subscript<Value: PrefValue>(key: PrefKey<Value>) -> Value {
        get {
            _ = revision
            return Value.read(from: defaults, key: key.name) ?? key.defaultValue
        }
        set {
            newValue.write(to: defaults, key: key.name)
            revision &+= 1
        }
    }

    public func reset<Value: PrefValue>(_ key: PrefKey<Value>) {
        defaults.removeObject(forKey: key.name)
        revision &+= 1
    }

    public func hasValue<Value: PrefValue>(_ key: PrefKey<Value>) -> Bool {
        _ = revision
        return defaults.object(forKey: key.name) != nil
    }
}
