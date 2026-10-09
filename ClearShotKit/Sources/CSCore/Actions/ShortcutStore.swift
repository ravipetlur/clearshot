import Foundation
import Synchronization

/// Where each action's global shortcut is kept: one `UserDefaults` key per action, `shortcut.<action raw value>`.
///
/// What a key holds:
/// - a dictionary `{keyCode: Int, modifiers: Int}` in Carbon terms (the numbers of `ShortcutSpec`), readable with `defaults read`;
/// - the boolean `false`, a shortcut the user cleared, which holds even for an action with a default;
/// - nothing, which means the action's default (for most actions, none).
///
/// A value of any other shape counts as nothing and is logged once. So does a key code or modifier mask that a Carbon
/// hot key can't take (negative, or over 32 bits).
///
/// Every write posts `didChange` once, after the write. Registration and the status menu follow it; nothing polls.
public final class ShortcutStore: @unchecked Sendable { // UserDefaults and NotificationCenter are thread-safe, and `reported` is behind a lock.
    /// Posted once after every write. `userInfo["action"]` is the changed action's raw value; after `resetAll()` the key
    /// is absent, which means "all".
    public static let didChange = Notification.Name("ClearShotShortcutsDidChange")

    private static let actionField = "action"
    private static let keyCodeField = "keyCode"
    private static let modifiersField = "modifiers"

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let logger: AppLogger
    /// The keys whose malformed value has been logged, so each is logged once however often it is read. A store lives
    /// as long as the app, so that is once per key per process.
    private let reported = Mutex<Set<String>>([])

    /// `logger` is where a malformed value is logged; the default is the app's hot-key log.
    public init(defaults: UserDefaults, notificationCenter: NotificationCenter = .default, logger: AppLogger = Log.hotkeys) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.logger = logger
    }

    public static func key(for action: ClearShotAction) -> String {
        "shortcut.\(action.rawValue)"
    }

    /// The stored shortcut; nil when it was cleared; the action's default when nothing (usable) is stored.
    public func shortcut(for action: ClearShotAction) -> ShortcutSpec? {
        let key = Self.key(for: action)
        guard let value = defaults.object(forKey: key) else { return action.defaultShortcut }
        if Self.isBoolean(value) {
            // A stored false is a clear; a stored true means nothing.
            if (value as? NSNumber)?.boolValue == false { return nil }
        } else if let spec = Self.spec(from: value) {
            return spec
        }
        reportMalformed(value, key: key)
        return action.defaultShortcut
    }

    /// Stores `shortcut`, or a clear for nil.
    public func set(_ shortcut: ShortcutSpec?, for action: ClearShotAction) {
        let key = Self.key(for: action)
        if let shortcut {
            defaults.set([Self.keyCodeField: shortcut.carbonKeyCode, Self.modifiersField: shortcut.carbonModifiers], forKey: key)
        } else {
            defaults.set(false, forKey: key)
        }
        post(action)
    }

    /// Goes back to the action's default.
    public func reset(_ action: ClearShotAction) {
        defaults.removeObject(forKey: Self.key(for: action))
        post(action)
    }

    /// Every action goes back to its default.
    public func resetAll() {
        for action in ClearShotAction.allCases {
            defaults.removeObject(forKey: Self.key(for: action))
        }
        post(nil)
    }

    /// Every action that has a shortcut now: not the cleared ones, nor those with no default and none set.
    public func all() -> [ClearShotAction: ShortcutSpec] {
        Dictionary(uniqueKeysWithValues: ClearShotAction.allCases.compactMap { action in
            shortcut(for: action).map { (action, $0) }
        })
    }

    // MARK: Shared with other files

    // These are internal, not private, so that other files read values by the same rules: `LegacyShortcutMigration` for old
    // values, `SystemShortcutTable` for the system's, `HotkeyRegistry` for the store's own posts.

    /// True when `value` is a real boolean. `UserDefaults` hands back a stored `false` as an `NSNumber`, and a stored
    /// integer 0 is one too, so only the Core Foundation type tells them apart.
    static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// Whether a Carbon hot key can take `spec`: both numbers fit the 32 bits `RegisterEventHotKey` takes.
    static func isRepresentable(_ spec: ShortcutSpec) -> Bool {
        UInt32(exactly: spec.carbonKeyCode) != nil && UInt32(exactly: spec.carbonModifiers) != nil
    }

    /// `value` as an integer, nil for anything else: text, a fraction, a boolean (which would pass for 0 or 1). Internal
    /// so that `SystemShortcutTable` reads the system's numbers by the same rules.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBoolean(number), !CFNumberIsFloatType(number as CFNumber) else { return nil }
        return number.intValue
    }

    /// The start of `value` as text, for a log line.
    static func excerpt(of value: Any) -> String {
        String(String(describing: value).prefix(80))
    }

    /// The action a `didChange` post names, nil when it names none: `resetAll()` leaves the key out, which means every
    /// action. Internal so that `HotkeyRegistry` reads a post by the key the store writes it with.
    static func changedAction(in notification: Notification) -> ClearShotAction? {
        (notification.userInfo?[actionField] as? String).flatMap(ClearShotAction.init(rawValue:))
    }

    // MARK: Private

    /// The shortcut a stored dictionary holds, nil unless it has an integer `keyCode` and `modifiers`.
    private static func spec(from value: Any) -> ShortcutSpec? {
        guard let fields = value as? [String: Any],
              let keyCode = integer(fields[keyCodeField]),
              let modifiers = integer(fields[modifiersField]) else { return nil }
        let spec = ShortcutSpec(carbonKeyCode: keyCode, carbonModifiers: modifiers)
        return isRepresentable(spec) ? spec : nil
    }

    private func post(_ action: ClearShotAction?) {
        let userInfo = action.map { [Self.actionField: $0.rawValue] }
        notificationCenter.post(name: Self.didChange, object: self, userInfo: userInfo)
    }

    private func reportMalformed(_ value: Any, key: String) {
        guard reported.withLock({ $0.insert(key).inserted }) else { return }
        logger.warning("Ignoring the malformed value of \(key): \(Self.excerpt(of: value)); the action keeps its default")
    }
}
