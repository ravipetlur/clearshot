import CoreGraphics

/// Where a manual check was asked from, and so where its answer appears. A background check has no source: it says
/// nothing unless it finds an update.
public enum CheckSource: String, Equatable, Hashable, Sendable, CaseIterable {
    /// The menu bar's "Check for Updates…": the answer is a popover under ClearShot's status icon.
    case statusMenu
    /// Settings › About's Check Now: the answer is a line under the button.
    case settings

    /// What the log calls it.
    public var logName: String {
        switch self {
        case .statusMenu: "status menu"
        case .settings: "settings"
        }
    }

    /// The source whose surface the answer goes to. A check from the status menu answers under the icon; when the icon
    /// can't be pointed at (hidden, or in the menu bar's overflow) it answers in Settings › About instead, which opens
    /// for it. Never a floating message with nothing to hold it.
    public func answering(anchorIsUsable: Bool) -> CheckSource {
        switch self {
        case .statusMenu: anchorIsUsable ? .statusMenu : .settings
        case .settings: .settings
        }
    }
}

/// Whether the status icon is somewhere a popover can hang from.
public enum StatusIconAnchor {
    /// True when the item is shown and its button's window has its middle on a screen. The menu bar's overflow (a full
    /// menu bar, or the notch) leaves a status item's window off every screen, and a hidden item has none to point at.
    /// All frames are in screen coordinates.
    public static func isUsable(itemIsVisible: Bool, buttonFrame: CGRect?, screenFrames: [CGRect]) -> Bool {
        guard itemIsVisible, let buttonFrame, !buttonFrame.isNull, !buttonFrame.isEmpty else { return false }
        let middle = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        return screenFrames.contains { $0.contains(middle) }
    }
}
