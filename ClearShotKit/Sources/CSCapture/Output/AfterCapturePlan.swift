import CSCore

/// Whether a screenshot goes on the clipboard, and why.
public enum CopyDecision: Sendable, Equatable {
    /// Not copied: it was saved, and copying wasn't asked for.
    case none
    /// Copied because the person asked: the Copy action, a "& Copy" shortcut, or ⌃ at capture time.
    case requested
    /// Copied only so the screenshot isn't lost: the save failed, or nothing that ran would have kept it.
    case fallback
}

/// Which after-capture actions run, and the rule that keeps a capture from being lost: if it ends up neither saved nor
/// shown (in a thumbnail, the editor or a pin), it is copied.
public struct AfterCapturePlan: Sendable, Equatable {
    /// Save at capture time.
    public let saves: Bool
    /// Save was asked for, but "Ask for name" moves it into the thumbnail's name field.
    public let defersSave: Bool
    public let copyRequested: Bool
    public let showsQuickAccess: Bool
    public let opensEditor: Bool
    /// Pin to the screen (screenshots only; recordings never have the action).
    public let pins: Bool

    public init(actions: Set<AfterCaptureAction>, askForName: Bool = false) {
        let wantsSave = actions.contains(.save)
        saves = wantsSave && !askForName
        defersSave = wantsSave && askForName
        copyRequested = actions.contains(.copy)
        showsQuickAccess = actions.contains(.showQuickAccess)
        opensEditor = actions.contains(.openEditor)
        pins = actions.contains(.pin)
    }

    /// A thumbnail appears when Quick Access is on, or to hold the name field.
    public var showsThumbnail: Bool { showsQuickAccess || defersSave }

    /// Something keeps the capture on screen: a thumbnail, the editor or a pin. Callers pass
    /// `shown: showsCapture && <a history item exists>` to `copy(saved:shown:)`, since each of them needs the item.
    public var showsCapture: Bool { showsThumbnail || opensEditor || pins }

    /// `saved`: a file was written. `shown`: a thumbnail, the editor or a pin is showing the capture.
    public func copy(saved: Bool, shown: Bool) -> CopyDecision {
        if copyRequested { return .requested }
        return saved || shown ? .none : .fallback
    }
}
