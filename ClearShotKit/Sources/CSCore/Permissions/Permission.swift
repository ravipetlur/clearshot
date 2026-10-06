import Foundation

public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case screenRecording, microphone, accessibility

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        }
    }

    public var reason: String {
        switch self {
        case .screenRecording: "Needed for every screenshot and recording."
        case .microphone: "Records your voice in screen recordings."
        case .accessibility: "Scrolls the page for you in scrolling captures."
        }
    }

    /// Only Screen Recording is asked for during onboarding; the rest are asked for when first used.
    public var isRequired: Bool { self == .screenRecording }

    public var settingsURL: URL { SystemSettingsLinks.privacy(self) }
}

public enum PermissionStatus: Sendable, Equatable {
    case granted, denied, notDetermined
}
