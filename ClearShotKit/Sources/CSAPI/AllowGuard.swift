import CoreGraphics
import Foundation

/// A window on screen as `CGWindowListCopyWindowInfo` describes it: its owner and its bounds in CG's global coordinates.
public struct ScreenWindow: Sendable, Equatable {
    public let ownerPID: Int32
    public let frame: CGRect
    public let alpha: Double

    public init(ownerPID: Int32, frame: CGRect, alpha: Double) {
        self.ownerPID = ownerPID
        self.frame = frame
        self.alpha = alpha
    }
}

/// When the consent alert's Allow button may be clicked (a guard against clickjacking): only once the alert has been
/// ready, key and uncovered, for `delay` without a break. Any break disables it at once, and the delay starts again
/// when the alert is ready again; so does a click refused because Allow was covered, or a click on the alert while
/// Allow is still disabled.
public struct AllowArming: Sendable {
    /// Allow's own delay (`URLConsent.buttons`).
    public static let defaultDelay = URLConsent.buttons.first(where: \.allows)?.enabledAfter ?? 1.5

    public let delay: TimeInterval
    public private(set) var isEnabled = false
    /// Since when the alert has been ready without a break; nil while it isn't.
    private var readySince: Date?

    public init(delay: TimeInterval = defaultDelay) {
        self.delay = delay
    }

    /// The alert as it is `now`: `ready` when it is key and nothing of another app's covers it. Returns whether Allow is
    /// enabled.
    public mutating func observe(ready: Bool, at now: Date) -> Bool {
        guard ready else {
            readySince = nil
            isEnabled = false
            return false
        }
        let since = readySince ?? now
        readySince = since
        isEnabled = now.timeIntervalSince(since) >= delay
        return isEnabled
    }

    /// A click on Allow, judged on the alert as it is `now` (`ready`: key, visible, nothing of another app's over it),
    /// never on the last check: it counts only when the alert is ready now and has been for the delay. Otherwise it is
    /// refused, Allow is disabled, and the delay starts again.
    public mutating func click(ready: Bool, at now: Date) -> Bool {
        guard observe(ready: ready, at: now) else {
            restart()
            return false
        }
        return true
    }

    /// Disables Allow and starts the delay again from the next ready moment.
    public mutating func restart() {
        readySince = nil
        isEnabled = false
    }
}

public enum AllowGuard {
    /// Whether a window of another process above the alert covers `target` (the same coordinates as the windows'): any
    /// that isn't fully transparent and overlaps it by more than an edge. ClearShot's own windows (its HUD) don't count.
    public static func isCovered(_ target: CGRect, by windowsAbove: [ScreenWindow], ownPID: Int32) -> Bool {
        windowsAbove.contains { window in
            guard window.ownerPID != ownPID, window.alpha > 0 else { return false }
            let overlap = window.frame.intersection(target)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
    }
}
