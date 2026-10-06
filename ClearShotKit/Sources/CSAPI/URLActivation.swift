import Foundation

/// Opening a URL activates ClearShot, so a command that captures or selects on screen would see the app that sent it
/// inactive (a window shot with grey traffic lights). Before such a command the activation goes back to the app that
/// had it, when ClearShot is active only because of the URL. This says when.
public enum URLActivation {
    /// How long before a URL arrived ClearShot may have become active and still count as activated by it: LaunchServices
    /// activates it about as it delivers the URL, a moment before or after.
    public static let leeway: TimeInterval = 1

    /// ClearShot's key window, if it has one.
    public enum KeyWindow: Sendable, Equatable {
        case none
        /// A window that activates ClearShot: Annotate, the Video Editor, History, Settings, an alert.
        case document
        /// A panel that takes keys without activating ClearShot: the capture overlay, its toolbar, the countdown, a pin,
        /// a thumbnail.
        case panel
    }

    /// True when ClearShot is active only because of the URL that arrived at `receivedAt`:
    /// - with no key window of its own;
    /// - or with a document window that became key because the URL activated the app (ClearShot became active as the URL
    ///   arrived or since, `activeSince`). Not knowing when it became active, the window is the person's.
    ///
    /// Never with a key panel: it took the keys without activating ClearShot, before the URL came, so the person is using
    /// it (Esc still cancels an overlay or a countdown).
    public static func handsBack(isActive: Bool, keyWindow: KeyWindow, activeSince: Date?, receivedAt: Date) -> Bool {
        guard isActive else { return false }
        switch keyWindow {
        case .none:
            return true
        case .panel:
            return false
        case .document:
            guard let activeSince else { return false }
            return activeSince >= receivedAt.addingTimeInterval(-leeway)
        }
    }
}
