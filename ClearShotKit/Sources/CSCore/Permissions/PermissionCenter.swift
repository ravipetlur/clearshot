import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

@MainActor
public final class PermissionCenter {
    public init() {}

    /// Screen Recording and Accessibility can't tell "denied" from "never asked", so both report `.notDetermined` until granted.
    public func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .microphone:
            Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .notDetermined
        }
    }

    @discardableResult
    public func request(_ permission: Permission) async -> PermissionStatus {
        Log.permissions.info("Requesting \(permission.rawValue)")
        switch permission {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
            return status(of: .screenRecording)
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .accessibility:
            // The literal key avoids touching the C global `kAXTrustedCheckOptionPrompt` under strict concurrency.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .notDetermined
        }
    }

    public func openSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}
