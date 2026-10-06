import Foundation

/// A value that can live in UserDefaults. `read` returns nil for a missing or wrong-typed value,
/// and the store then falls back to the key's default.
public protocol PrefValue: Sendable {
    static func read(from defaults: UserDefaults, key: String) -> Self?
    func write(to defaults: UserDefaults, key: String)
}

/// A typed preference: its UserDefaults name and default value.
public struct PrefKey<Value: PrefValue>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// Namespace for every preference key. Each area adds its keys in `Prefs+<Area>.swift`.
public enum Prefs {}

extension Bool: PrefValue {
    public static func read(from defaults: UserDefaults, key: String) -> Bool? { defaults.object(forKey: key) as? Bool }
    public func write(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
}

extension Int: PrefValue {
    public static func read(from defaults: UserDefaults, key: String) -> Int? { defaults.object(forKey: key) as? Int }
    public func write(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
}

extension Double: PrefValue {
    public static func read(from defaults: UserDefaults, key: String) -> Double? { defaults.object(forKey: key) as? Double }
    public func write(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
}

extension String: PrefValue {
    public static func read(from defaults: UserDefaults, key: String) -> String? { defaults.object(forKey: key) as? String }
    public func write(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
}

/// File URLs are stored as plain paths so they stay readable with `defaults read`.
extension URL: PrefValue {
    public static func read(from defaults: UserDefaults, key: String) -> URL? {
        guard let path = defaults.object(forKey: key) as? String, path.hasPrefix("/") else { return nil }
        return URL(filePath: path, directoryHint: path.hasSuffix("/") ? .isDirectory : .inferFromPath)
    }

    public func write(to defaults: UserDefaults, key: String) {
        defaults.set(path(percentEncoded: false), forKey: key)
    }
}

public extension PrefValue where Self: RawRepresentable, RawValue == String {
    static func read(from defaults: UserDefaults, key: String) -> Self? {
        (defaults.object(forKey: key) as? String).flatMap(Self.init(rawValue:))
    }

    func write(to defaults: UserDefaults, key: String) {
        defaults.set(rawValue, forKey: key)
    }
}

/// A string-backed enum that can be stored inside a `Set` preference.
public protocol StringPrefEnum: RawRepresentable, Hashable, Sendable where RawValue == String {}

/// Sets of string enums are stored as sorted string arrays. Unknown members are dropped.
extension Set: PrefValue where Element: StringPrefEnum {
    public static func read(from defaults: UserDefaults, key: String) -> Set<Element>? {
        guard let raw = defaults.object(forKey: key) as? [String] else { return nil }
        return Set(raw.compactMap(Element.init(rawValue:)))
    }

    public func write(to defaults: UserDefaults, key: String) {
        defaults.set(map(\.rawValue).sorted(), forKey: key)
    }
}

/// Structured values (presets, layouts) are stored as JSON data.
public protocol JSONPrefValue: PrefValue, Codable {}

public extension JSONPrefValue {
    static func read(from defaults: UserDefaults, key: String) -> Self? {
        guard let data = defaults.object(forKey: key) as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func write(to defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: key)
    }
}

extension FileNameTemplate: PrefValue {
    public static func read(from defaults: UserDefaults, key: String) -> FileNameTemplate? {
        (defaults.object(forKey: key) as? String).map(FileNameTemplate.init(parsing:))
    }

    public func write(to defaults: UserDefaults, key: String) {
        defaults.set(stringValue, forKey: key)
    }
}
