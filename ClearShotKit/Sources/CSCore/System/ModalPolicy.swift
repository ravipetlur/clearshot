/// One policy for app-modal alerts and panels around captures: no app-modal session overlaps a capture or a recording,
/// in either direction. A modal session under a recording's frame leaves its control bar dead (Stop, Pause, Restart,
/// Delete), and an overlay opened over a modal alert can't take events.
///
/// The capture flow says where it is (`FlowState`), each site says what kind of question it has (`Kind`), and `decide`
/// says what to do. `refusesCapture` is the other direction.
public enum ModalPolicy {
    /// Where the capture flow is.
    public enum FlowState: Sendable, Equatable {
        /// No capture, recording or recording's tail is under way.
        case idle
        /// A capture or a recording is under way (`CaptureFlow.isCapturing`): its overlay, countdown, frame or routing
        /// may be on screen.
        case capturing
        /// Not capturing, but not idle either: a recording's tail runs (the merge and its question, the GIF conversion and
        /// its Stop question, routing), or Capture Text presents its result.
        case finishing
    }

    /// What a site wants to show.
    public enum Kind: Sendable, Equatable {
        /// An alert ClearShot raises by itself, or one that reports earlier work: a failed save, Mute's or a replace's
        /// outcome, a drop on the desktop cover, a recovered recording, the trim flow's late actions.
        case report
        /// A question the person triggers from a non-activating surface (a Quick Access thumbnail or its menu, a pin, a
        /// hotkey, the status menu), or a panel it opens. `undoable` when its "yes" can be undone or restored.
        case question(undoable: Bool)
        /// A question in a document window (Annotate, the Video Editor, History, Settings), as a sheet on it: the person
        /// brought ClearShot forward to work there.
        case inDocumentWindow
    }

    public enum Decision: Sendable, Equatable {
        /// Show it now.
        case ask
        /// Don't ask; go on as if the answer were yes (it can be undone).
        case skip
        /// Don't ask and don't do it; say `refusal`.
        case refuse
        /// Show it once the flow is idle.
        case wait
    }

    /// What a refused question says in the HUD: what is on screen that it waits for.
    public enum Refusal: Sendable, Equatable {
        /// An overlay, Ready, a capture or a scrolling capture is under way.
        case capture
        /// A recording or its countdown is on screen.
        case recording
        /// An app-modal alert or panel is up; it comes forward.
        case appModal

        public var text: String {
            switch self {
            case .capture: "Finish the capture first"
            case .recording: "Finish the recording first"
            case .appModal: "Close the open dialog first"
            }
        }

        public var symbol: String {
            switch self {
            case .capture: "camera.viewfinder"
            case .recording: "record.circle"
            case .appModal: "macwindow"
            }
        }
    }

    /// What to do with a `kind` of modal UI while the flow is at `flow`:
    /// - a report waits until nothing is under way;
    /// - a question while an app-modal alert or panel is up (`appModalIsUp`) is refused, so none stacks on another;
    /// - a question during a capture is skipped when its "yes" can be undone, and refused otherwise;
    /// - a document window's question is always asked, on its window (a sheet isn't app-modal).
    public static func decide(_ kind: Kind, flow: FlowState, appModalIsUp: Bool = false) -> Decision {
        switch kind {
        case .report:
            flow == .idle ? .ask : .wait
        case .question(let undoable):
            appModalIsUp ? .refuse : flow != .capturing ? .ask : undoable ? .skip : .refuse
        case .inDocumentWindow:
            .ask
        }
    }

    /// What a refused question says: the open dialog first, since it is what has to close; then a recording or its
    /// countdown on screen; otherwise the capture under way.
    public static func refusal(appModalIsUp: Bool, recordingOnScreen: Bool) -> Refusal {
        appModalIsUp ? .appModal : recordingOnScreen ? .recording : .capture
    }

    /// "Close this recording?": Restore Last Capture brings a closed recording back, except under retention Never,
    /// which deletes it.
    public static func closingRecording(retention: HistoryRetention) -> Kind {
        .question(undoable: retention != .never)
    }

    /// The other direction: a capture doesn't start while one runs, while a recording's tail is in a modal moment (its
    /// question, an alert, or routing, which may show one), or while any app-modal alert or panel is up.
    public static func refusesCapture(isRunning: Bool, tailIsModal: Bool, appModalIsUp: Bool) -> Bool {
        isRunning || tailIsModal || appModalIsUp
    }
}
