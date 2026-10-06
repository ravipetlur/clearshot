import CSCore

/// An audio input, as Ready's microphone list shows it.
public struct MicrophoneDeviceInfo: Sendable, Equatable, Identifiable {
    /// The device's unique ID, as `Prefs.recordingMicrophoneID` stores it.
    public let id: String
    public let name: String
    /// The Mac's own microphone (transport type built-in).
    public let isBuiltIn: Bool

    public init(id: String, name: String, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
    }
}

/// Which microphone a recording uses. ClearShot never picks one by itself: the default is "Do Not Record Microphone"
/// (""), and a saved device that is gone or unusable records no microphone.
public enum MicrophoneChoice {
    public static let lidClosedReason = "The built-in microphone doesn't work while the MacBook's lid is closed."

    /// Why `device` can't record now, or nil when it can. The built-in microphone is unavailable with the lid closed.
    public static func unavailableReason(_ device: MicrophoneDeviceInfo, lidClosed: Bool) -> String? {
        device.isBuiltIn && lidClosed ? lidClosedReason : nil
    }

    /// The saved device when it is present and usable. Nil for "" (Do Not Record Microphone), a missing device, or the
    /// built-in mic with the lid closed.
    public static func usable(savedID: String, devices: [MicrophoneDeviceInfo], lidClosed: Bool) -> MicrophoneDeviceInfo? {
        guard !savedID.isEmpty, let device = devices.first(where: { $0.id == savedID }),
              unavailableReason(device, lidClosed: lidClosed) == nil else { return nil }
        return device
    }

    /// Why the chosen microphone won't record as a recording starts, for the notice that says so; nil when it records,
    /// or nothing was chosen, or the chosen device was already gone when Ready opened (a saved device that isn't
    /// connected records nothing, quietly). `devices` and `lidClosed` are as the recording starts; `lidClosedInReady`
    /// is the lid as Ready opened; `permission` is the microphone permission as the recording starts; `session` is what
    /// became of Ready's warm session; `lostInReady` says the chosen device went away while Ready was up. Access granted
    /// after Ready left the session closed for want of it is told as such, never as a session that couldn't be opened;
    /// a lid closed as Ready opened, which kept the built-in microphone closed, stays the reason after it opens.
    public static func startIssue(savedID: String, devices: [MicrophoneDeviceInfo], lidClosed: Bool,
                                  lidClosedInReady: Bool = false, permission: PermissionStatus,
                                  session: MicrophoneSessionState, lostInReady: Bool) -> MicrophoneStartIssue? {
        guard !savedID.isEmpty else { return nil }
        let device = devices.first { $0.id == savedID }
        if let device, unavailableReason(device, lidClosed: lidClosed) == nil, permission == .granted, session == .open {
            return nil
        }
        if lostInReady { return .disconnected }
        guard let device else { return nil }
        if unavailableReason(device, lidClosed: lidClosed || lidClosedInReady) != nil { return .lidClosed }
        switch permission {
        case .notDetermined: return .noAccessYet
        case .denied: return .noAccess
        case .granted: return session == .failed ? .couldNotOpen : .grantedLate
        }
    }
}

/// What became of Ready's warm session of the chosen microphone, as a recording starts.
public enum MicrophoneSessionState: Sendable, Equatable {
    /// Handed over to the recording, running or still starting.
    case open
    /// It wouldn't open or start.
    case failed
    /// Ready never opened it: the device wasn't usable, or the permission wasn't granted, when it would have.
    case notOpened
}

/// Why a chosen microphone doesn't record: the lid, the permission, a device that wouldn't open or went away. The
/// recording goes on without it and its notice says so: an OK, except for the lid, which asks whether to go on.
public enum MicrophoneStartIssue: Sendable, Equatable {
    case lidClosed
    /// Unplugged (or failed) while Ready was up, or after it handed the microphone over and before the recording took it.
    case disconnected
    /// The microphone permission hasn't been answered: it is asked for once nothing records.
    case noAccessYet
    case noAccess
    case couldNotOpen
    /// The permission was granted after Ready had left the microphone closed for want of it; the next recording uses it.
    case grantedLate

    public static let unavailable = "The microphone isn't available, so this recording has no microphone audio."

    public var title: String {
        self == .lidClosed ? MicrophoneChoice.lidClosedReason : Self.unavailable
    }

    /// Why, as a short line without a full stop (Ready's message slot shows the permission ones).
    public var reason: String {
        switch self {
        case .lidClosed: MicrophoneChoice.lidClosedReason
        case .disconnected: "The microphone was disconnected"
        case .noAccessYet: "ClearShot doesn't have microphone access yet"
        case .noAccess: "ClearShot isn't allowed to use the microphone"
        case .couldNotOpen: "The microphone couldn't be opened"
        case .grantedLate: "Microphone access came after this recording was set up"
        }
    }

    /// The notice's message: the reason, under the title (with what happens next when access came late); none for the
    /// lid, whose title is its reason.
    public var message: String? {
        switch self {
        case .lidClosed: nil
        case .grantedLate: reason + "; the next recording will use it."
        default: reason + "."
        }
    }

    /// The default first.
    public var buttons: [String] {
        self == .lidClosed ? ["Continue Without Audio", "Stop"] : ["OK"]
    }
}
