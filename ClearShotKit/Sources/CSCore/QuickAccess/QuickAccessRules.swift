import Foundation

/// The ⌥ variants and the auto-close outcome for a thumbnail, and what Restore brings back.
public enum QuickAccessRules {
    /// Copy closes the thumbnail; ⌥-Copy keeps it open.
    public static func closesAfterCopy(optionHeld: Bool) -> Bool {
        !optionHeld
    }

    /// A finished drag closes the thumbnail when "Close after dragging" is on; ⌥ does the opposite.
    public static func closesAfterDrag(closeAfterDragging: Bool, optionHeld: Bool) -> Bool {
        closeAfterDragging != optionHeld
    }

    /// Save asks where to save when the "Save button" setting says to (`askByDefault`); ⌥ does the opposite.
    public static func saveAsksForLocation(optionHeld: Bool, askByDefault: Bool) -> Bool {
        askByDefault != optionHeld
    }

    /// What the Save button says: "Show in Finder" once the capture is saved, else "Save As…" when Save asks where, else
    /// "Save". `compact` (Copy and Save sharing a row, each half as wide: 54 pt on the small size) shortens the long ones to
    /// "Finder" and "Save…", which fit it in the pill's 12 pt semibold type (37.4 and 39.0 pt; "Show in Finder" is 86.6 and
    /// "Save As…" 57.2).
    public static func saveButtonTitle(isSaved: Bool, asksForLocation: Bool, compact: Bool) -> String {
        if isSaved { return compact ? "Finder" : "Show in Finder" }
        if asksForLocation { return compact ? "Save\u{2026}" : "Save As\u{2026}" }
        return "Save"
    }

    /// Whether a thumbnail's auto-close countdown runs: not while the pointer is over it, the stack is hidden, Quick
    /// Look shows it, or anything holds it (a Save panel, the print dialog, an alert, the Resize dialog).
    public static func clockRuns(hovering: Bool, hidden: Bool, previewing: Bool, holds: Int) -> Bool {
        !hovering && !hidden && !previewing && holds == 0
    }

    public enum AutoCloseOutcome: Sendable, Equatable {
        case keepOpen, close, saveAndClose
    }

    /// What happens when the auto-close timer runs out. A thumbnail waiting for a name stays open.
    public static func autoCloseOutcome(action: AutoCloseAction, isSaved: Bool, isNaming: Bool) -> AutoCloseOutcome {
        if isNaming { return .keepOpen }
        if action == .saveAndClose, !isSaved { return .saveAndClose }
        return .close
    }

    /// Whether what a thumbnail shows is on disk outside history: saved, or opened from a file and unchanged since,
    /// since that file is what it shows. Once an opened file is edited (a rotate, an annotation, Replace, Mute) the
    /// edit is only in history. Auto-close's "Save and close" saves what isn't, and "Close this recording?" asks about
    /// it.
    public static func isOnDisk(isSaved: Bool, isOpenedFile: Bool, isChangedSinceOpening: Bool) -> Bool {
        isSaved || (isOpenedFile && !isChangedSinceOpening)
    }

    /// Whether closing a thumbnail by hand (Close, ⌘W, a swipe) asks "Close this recording?" first: only for a video or
    /// GIF that isn't on disk (`isOnDisk`), while the question is on (`Prefs.confirmCloseRecording`). Auto-close and
    /// Close All never ask it.
    public static func asksBeforeClosing(isVideoOrGIF: Bool, isSaved: Bool, isOpenedFile: Bool, isChangedSinceOpening: Bool,
                                         askSetting: Bool) -> Bool {
        isVideoOrGIF && askSetting
            && !isOnDisk(isSaved: isSaved, isOpenedFile: isOpenedFile, isChangedSinceOpening: isChangedSinceOpening)
    }

    /// The item Restore Last Capture brings back: the most recently closed thumbnail whose item is still in history and
    /// not on screen; else the newest history item not on screen; nil when every item is on screen.
    public static func itemToRestore(closedOldestFirst: [UUID], historyNewestFirst: [UUID], shown: Set<UUID>) -> UUID? {
        let inHistory = Set(historyNewestFirst)
        return closedOldestFirst.last { inHistory.contains($0) && !shown.contains($0) }
            ?? historyNewestFirst.first { !shown.contains($0) }
    }
}
