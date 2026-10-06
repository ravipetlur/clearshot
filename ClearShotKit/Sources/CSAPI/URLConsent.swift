import CSCore
import Foundation

/// Where the person's consent to run other apps' commands is kept, so that no other process can grant it: the app keeps
/// it in the Keychain, as an item only ClearShot's code signature may read; the tests keep it in memory. `UserDefaults`
/// (`Prefs.allowURLSchemeAPI`, `didAskAboutURLSchemeAPI`), which any process running as the user can write, can only
/// take the permission away.
@MainActor
public protocol ConsentStore: AnyObject {
    /// Whether the grant is there and readable; false on any failure to read it.
    var isGranted: Bool { get }
    /// Stores the grant; false when it couldn't be stored.
    func grant() -> Bool
    /// Removes the grant.
    func revoke()
}

/// One global consent for commands from other apps, decided before the URL is parsed.
public enum URLConsent {
    public enum Decision: Sendable, Equatable { case run, ask, drop }

    /// Only ClearShot's own process is trusted, by PID: the bundle ID never counts, so another ClearShot is asked like
    /// any other app. Otherwise the setting decides: off drops; on runs with the grant, and asks without it.
    public static func decide(allowsAPI: Bool, granted: Bool, sender: SenderFacts, ownPID: Int32) -> Decision {
        if sender.pid == ownPID { return .run }
        guard allowsAPI else { return .drop }
        return granted ? .run : .ask
    }

    /// `decide` with the setting from `preferences` and the grant from `store`. "Asked" (`didAskAboutURLSchemeAPI`) is
    /// never a grant: without the grant the person is asked, whatever the defaults say.
    @MainActor
    public static func decide(preferences: Preferences, store: any ConsentStore, sender: SenderFacts,
                              ownPID: Int32) -> Decision {
        // The setting first: a command dropped while it is off never reads the Keychain.
        guard sender.pid == ownPID || preferences[Prefs.allowURLSchemeAPI] else { return .drop }
        return decide(allowsAPI: preferences[Prefs.allowURLSchemeAPI], granted: store.isGranted, sender: sender,
                      ownPID: ownPID)
    }

    /// The person's answer to the prompt. Allow stores the grant and turns the setting on; Don't Allow removes the grant
    /// and turns it off. Either way they have been asked. False when Allow's grant couldn't be stored: the next command
    /// asks again.
    @MainActor
    @discardableResult
    public static func record(allowed: Bool, preferences: Preferences, store: any ConsentStore) -> Bool {
        preferences[Prefs.didAskAboutURLSchemeAPI] = true
        return setAllowed(allowed, preferences: preferences, store: store)
    }

    /// What Settings › Advanced's "Allow URL scheme API" shows: what the next command from another app meets.
    public enum Setting: Sendable, Equatable {
        /// Commands run: the setting is on and the grant is stored.
        case allowed
        /// The next command asks (`asksCaption`): the setting is on, but nothing is granted yet (a new install, or a
        /// grant that couldn't be stored or has gone).
        case asks
        /// Commands are ignored.
        case off

        /// The switch is on unless commands are ignored: a switch that read "off" while commands still asked would say
        /// the API is off when it isn't, and "Turn it off to ignore them" couldn't be done without allowing first.
        public var isOn: Bool { self != .off }
    }

    /// The switch's state from the setting and the grant together (`Setting`).
    @MainActor
    public static func setting(preferences: Preferences, store: any ConsentStore) -> Setting {
        guard preferences[Prefs.allowURLSchemeAPI] else { return .off }
        return store.isGranted ? .allowed : .asks
    }

    /// The switch's second line while it `asks`.
    public static let asksCaption = "Asks the first time an app sends a command."

    /// The switch turned on stores the grant and the setting, and counts as the answer to the prompt; turned off, it
    /// removes the grant and turns the setting off. False when the grant couldn't be stored.
    @MainActor
    @discardableResult
    public static func setAllowed(_ allowed: Bool, preferences: Preferences, store: any ConsentStore) -> Bool {
        guard allowed else {
            store.revoke()
            preferences[Prefs.allowURLSchemeAPI] = false
            return true
        }
        let stored = store.grant()
        preferences[Prefs.allowURLSchemeAPI] = true
        preferences[Prefs.didAskAboutURLSchemeAPI] = true
        return stored
    }

    /// The consent alert's text; `command` is `APIRequest.commandName(of:)`, shown shortened. The sender is named as
    /// `describe` names it, and the message says plainly that Allow lets every app in, not just this one, and lets them
    /// open files too (`filepath`).
    public static func prompt(command: String, sender: SenderFacts) -> (title: String, message: String) {
        ("Another app wants to control ClearShot",
         "ClearShot received a command from \(describe(sender)): \(APIRequest.shortened(command)). "
             + "Do you want to let other apps control ClearShot? "
             + "Allowing lets any app on this Mac run ClearShot commands, capture your screen and open your image and "
             + "video files.")
    }

    public static let allowButton = "Allow", dontAllowButton = "Don't Allow"

    /// One of the consent alert's buttons (`buttons`).
    public struct Button: Sendable, Equatable {
        public let title: String
        /// Choosing it allows other apps to control ClearShot.
        public let allows: Bool
        /// The default button, which Return and Esc both choose. Any other can only be clicked: it has no key
        /// equivalent and is never focused from the keyboard.
        public let isDefault: Bool
        /// Seconds the alert must be key and uncovered before it is enabled (`AllowArming`), so neither a click already
        /// on its way nor one through a window drawn over the alert can land on it.
        public let enabledAfter: TimeInterval
    }

    /// The consent alert's buttons, in the order the alert adds them (the first is rightmost). Opening a URL activates
    /// ClearShot, so the alert can take the keys while the person types elsewhere: Don't Allow is the default, and
    /// Allow takes a deliberate click, 1.5 s after the alert appears at the earliest.
    public static let buttons = [
        Button(title: dontAllowButton, allows: false, isDefault: true, enabledAfter: 0),
        Button(title: allowButton, allows: true, isDefault: false, enabledAfter: 1.5),
    ]

    /// Whether choosing the button at `index` of `buttons` allows; any other answer allows nothing.
    public static func allows(choosing index: Int) -> Bool {
        buttons.indices.contains(index) && buttons[index].allows
    }

    /// The HUD for commands dropped while the setting is off, once per launch.
    public static let offNotice = "URL commands are off (Settings › Advanced)"

    /// The HUD as a command captures with no on-screen choice (`APICommand.capturesWithoutChoice`), naming the sender as
    /// `describe` does.
    public static func captureNotice(sender: SenderFacts) -> String {
        let who = switch identity(of: sender) {
        case let .verified(label): label
        case .unverified: "An unverified app"
        case .unknown: "Another app"
        }
        return "\(who) is capturing your screen with ClearShot"
    }

    /// Whether `command` shows `captureNotice` as it runs: it takes the picture with no on-screen choice by the person,
    /// and ClearShot didn't send it itself (by PID, as `decide` trusts).
    public static func showsCaptureNotice(for command: APICommand, sender: SenderFacts, ownPID: Int32) -> Bool {
        command.capturesWithoutChoice && sender.pid != ownPID
    }

    /// Who sent a command, for the prompt and the log:
    /// - its verified signature, the signed identifier always shown: "Raycast (com.raycast.macos, team SY64MV22J9)",
    ///   "Terminal (com.apple.Terminal, Apple)"; without a signed name, the identifier alone, "com.apple.osascript
    ///   (Apple)";
    /// - "an unverified app" when something named it but its own signature didn't verify (a parent app found by walking
    ///   up, a name and bundle ID it gave itself, a development or ad-hoc signature);
    /// - "an external app" when nothing is known (it has exited, or a second ClearShot forwarded the command).
    ///
    /// Every part is sanitised (`SenderText`).
    public static func describe(_ sender: SenderFacts) -> String {
        switch identity(of: sender) {
        case let .verified(label): label
        case .unverified: "an unverified app"
        case .unknown: "an external app"
        }
    }

    private enum Identity {
        case verified(String), unverified, unknown
    }

    private static func identity(of sender: SenderFacts) -> Identity {
        guard let verified = sender.verified else {
            return SenderText.name(sender.name) == nil ? .unknown : .unverified
        }
        // The signed identifier always shows, beside a signed name when there is one.
        let identifier = SenderText.code(verified.identifier)
        let signer = switch verified.signer {
        case .apple: "Apple"
        case let .team(team): "team \(SenderText.code(team))"
        }
        guard let name = SenderText.name(verified.name) else { return .verified("\(identifier) (\(signer))") }
        return .verified("\(name) (\(identifier), \(signer))")
    }
}

/// The modal gate's refusals that apps without consent see. Their command asks the gate before the prompt; refused
/// during a capture, a recording or an open app-modal dialog, the gate says so in a HUD and brings the dialog forward.
/// Each sender gets that at most once per `interval`; its other refusals are only logged, so an app can't flood the
/// screen with HUDs or keep pulling a dialog to the front.
public struct RefusalNotices: Sendable {
    public static let interval: TimeInterval = 10

    /// When a refusal last showed, by sender as the prompt names it (`URLConsent.describe`).
    private var lastShown: [String: Date] = [:]

    public init() {}

    /// Whether a refusal for `sender` may show at `now`: none has shown for it in the last `interval`. Senders are told
    /// apart as the prompt names them: an app by its verified signature, whichever process sends (a script's `open` is
    /// a new process each time), and every unverified or unknown sender as one.
    public func mayShow(for sender: SenderFacts, at now: Date) -> Bool {
        lastShown[URLConsent.describe(sender)].map { now.timeIntervalSince($0) >= Self.interval } ?? true
    }

    /// A refusal for `sender` showed at `now`. Senders whose interval has passed are forgotten.
    public mutating func shown(for sender: SenderFacts, at now: Date) {
        lastShown = lastShown.filter { now.timeIntervalSince($0.value) < Self.interval }
        lastShown[URLConsent.describe(sender)] = now
    }

    /// How many senders are remembered (tests).
    var trackedSenders: Int { lastShown.count }
}

/// Commands that arrive while the consent prompt is up. They wait for its answer and run in arrival order, or are
/// dropped with it.
public struct ConsentQueue: Sendable {
    /// The most commands that wait besides the one that raised the prompt.
    public static let limit = 8

    public private(set) var isAsking = false
    private var first: ReceivedURL?
    private var waiting: [ReceivedURL] = []

    public init() {}

    /// The prompt is up for `first`. Called while already asking, it waits like `add`.
    public mutating func begin(_ first: ReceivedURL) {
        guard !isAsking else {
            _ = add(first)
            return
        }
        isAsking = true
        self.first = first
    }

    /// Keeps `received` until the answer; false when `limit` already wait, and it is dropped.
    public mutating func add(_ received: ReceivedURL) -> Bool {
        guard waiting.count < Self.limit else { return false }
        waiting.append(received)
        return true
    }

    /// What became of a command that needs the prompt (`arrive`).
    public enum Arrival: Sendable, Equatable {
        /// The prompt begins for it: show it now.
        case asks
        /// The prompt is up; it waits for the answer.
        case waits
        /// The prompt is up and `limit` commands already wait: it is dropped.
        case dropped
        /// The modal gate refused the prompt: it is dropped, and the next command asks again.
        case refused
    }

    /// The commands the answer decides: the first, then the waiting ones in arrival order (for the log when they are
    /// dropped).
    public var pending: [ReceivedURL] {
        [first].compactMap(\.self) + waiting
    }

    /// A command that needs the prompt arrives. While the prompt is up it waits, or is dropped when `limit` already
    /// wait. Otherwise the modal gate is asked first (`gateAllows`, called only then), and the prompt begins only if it
    /// allows; refused, the queue is left as it was.
    public mutating func arrive(_ received: ReceivedURL, gateAllows: () -> Bool) -> Arrival {
        if isAsking { return add(received) ? .waits : .dropped }
        guard gateAllows() else { return .refused }
        begin(received)
        return .asks
    }

    /// Allowed: the first command, then the waiting ones in arrival order. Not allowed: none. Either way the queue is
    /// empty again and not asking (also when the prompt was refused before it showed).
    public mutating func answer(allowed: Bool) -> [ReceivedURL] {
        let commands = [first].compactMap(\.self) + waiting
        isAsking = false
        first = nil
        waiting = []
        return allowed ? commands : []
    }
}
