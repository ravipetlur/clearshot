import CoreGraphics
import Foundation

/// Which bottom corner the thumbnails stack in.
public enum QuickAccessPosition: String, CaseIterable, Sendable, Identifiable, PrefValue {
    case left, right

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        }
    }
}

public enum QuickAccessSize: String, CaseIterable, Sendable, Identifiable, PrefValue {
    case small, medium, large

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// The thumbnail's width in points.
    public var width: CGFloat {
        switch self {
        case .small: 168
        case .medium: 216
        case .large: 280
        }
    }
}

/// What the auto-close timer does when it runs out.
public enum AutoCloseAction: String, CaseIterable, Sendable, Identifiable, PrefValue {
    case close, saveAndClose

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .close: "Close"
        case .saveAndClose: "Save and close"
        }
    }
}

/// How long closed captures stay in history.
public enum HistoryRetention: String, CaseIterable, Sendable, Identifiable, PrefValue {
    case never, oneDay, threeDays, oneWeek, oneMonth

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .never: "Never"
        case .oneDay: "1 day"
        case .threeDays: "3 days"
        case .oneWeek: "1 week"
        case .oneMonth: "1 month"
        }
    }

    private var duration: TimeInterval {
        let day: TimeInterval = 86_400
        return switch self {
        case .never: 0
        case .oneDay: day
        case .threeDays: 3 * day
        case .oneWeek: 7 * day
        case .oneMonth: 30 * day
        }
    }

    /// Items created before this are removed. With `never`, that is everything not on screen.
    public func cutoff(now: Date) -> Date {
        now.addingTimeInterval(-duration)
    }
}

public extension Prefs {
    /// Auto-close intervals offered in Settings, in seconds: 5 s up to 10 minutes.
    static let autoCloseIntervalChoices = [5, 10, 15, 30, 60, 120, 300, 600]

    // Quick Access pane
    static let quickAccessPosition = PrefKey("quickAccessPosition", default: QuickAccessPosition.left)
    static let quickAccessSize = PrefKey("quickAccessSize", default: QuickAccessSize.medium)
    static let quickAccessMoveToActiveScreen = PrefKey("quickAccessMoveToActiveScreen", default: true)
    static let quickAccessAutoClose = PrefKey("quickAccessAutoClose", default: true)
    static let quickAccessAutoCloseSeconds = PrefKey("quickAccessAutoCloseSeconds", default: 15)
    static let quickAccessAutoCloseAction = PrefKey("quickAccessAutoCloseAction", default: AutoCloseAction.close)
    static let quickAccessCloseAfterDragging = PrefKey("quickAccessCloseAfterDragging", default: true)
    /// The thumbnail's Save button (and ⌘S) asks where to save instead of saving to the export location.
    static let quickAccessSaveAsksForLocation = PrefKey("quickAccessSaveAsksForLocation", default: false)

    // Warning dialogs. "Reset All Warning Dialogs" resets every key in `warningDialogs`.
    static let confirmCloseAllOverlays = PrefKey("confirmCloseAllOverlays", default: true)
    /// Deleting from the History window asks first.
    static let confirmHistoryDelete = PrefKey("confirmHistoryDelete", default: true)
    /// Closing an unsaved video's or GIF's thumbnail by hand asks first: "Close this recording?".
    static let confirmCloseRecording = PrefKey("confirmCloseRecording", default: true)
    static let warningDialogs: [PrefKey<Bool>] = [confirmCloseAllOverlays, confirmHistoryDelete, confirmCloseRecording]

    // History
    static let historyRetention = PrefKey("historyRetention", default: HistoryRetention.oneMonth)
}
