import Foundation

public enum SystemSettingsLinks {
    public static let keyboard = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    public static func privacy(_ permission: Permission) -> URL {
        let anchor = switch permission {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}
