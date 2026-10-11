/// What the sensitive-info button in Annotate's tool strip shows.
public enum SensitiveButtonPhase: Equatable, Sendable {
    /// Nothing is known of the picture as it is now: the editor hasn't reported one, the automatic check is off, or the scan
    /// couldn't be made. A plain button.
    case idle
    /// The automatic scan of this picture is waiting its turn or running. A plain button.
    case scanning
    /// The picture was scanned and nothing sensitive is in it. A plain button.
    case none
    /// The picture was scanned and the findings are still there, unmasked: the warning, "⚠︎ 3".
    case found(FindingCounts)
    /// No unmasked findings, and the document holds this many masks the secrets check made: the "masked" look, whose click takes
    /// them out. It comes from the document, so it shows without a scan, as soon as a capture with masks is open.
    case masked(Int)
    /// No kind of finding is switched on in Settings and there is nothing to unmask: nothing to look for, and the button is off.
    case disabled
}

/// What a click on the button does.
public enum SensitiveButtonAction: Equatable, Sendable {
    /// Scans the picture and masks every finding (one undo step).
    case mask
    /// Takes out every mask the secrets check made (one undo step).
    case unmask
}

/// What the owner of a `SensitiveButtonState` has to do about its scan after an event.
public enum SensitiveButtonEffect: Equatable, Sendable {
    /// Nothing.
    case none
    /// Stop the scan that is waiting or running, if any: it is no longer wanted.
    case cancelScan
    /// Start over: stop any earlier scan, wait `after`, then scan the picture the button has now. Each change of picture
    /// sends this again, so a run of changes (a drag, a stream of nudges) scans once, after the last one has been quiet for
    /// the delay.
    case scan(after: Duration)
}

/// The sensitive-info button in Annotate's tool strip, as a state machine over the pictures the open document has and the masks
/// of the secrets check in it: what it shows (`phase`), what a click does (`action`), and when a scan for it is wanted,
/// cancelled or started over (`apply(_:)`'s effect).
///
/// | The scan of this picture | The document's marked masks | The button | A click |
/// |---|---|---|---|
/// | has findings | none, or some | the warning, "⚠︎ 3" | masks the findings |
/// | has none | some | the masked look | takes every marked mask out |
/// | has none, or isn't known | none | plain (idle, scanning or none) | scans, then masks |
/// | isn't known | some | the masked look | takes every marked mask out |
///
/// **Two inputs.** What the scans say about the picture as it is now (`found`, or nothing found), and how many masks the
/// secrets check made the document holds (`maskCount`, which the app counts from the document). The warning shows while the
/// scan of this picture has findings: **unmasked findings take precedence**, so with both the button shows the warning and a
/// click masks the rest. Otherwise, with marked masks it shows the masked look, whether or not any scan has run (the document
/// says so, and it is right the moment a masked capture opens). Otherwise it is plain.
///
/// **Pictures.** `Picture` stands for what decides which pixels the document's picture has and where each one lies
/// (`PictureIdentity` in `CSAnnotation`, which this module doesn't depend on; any `Equatable` does here). A result is for one
/// picture and one set of kinds, and is shown only while the document is that picture and those kinds are on: a crop, a turn,
/// a resize or a redaction makes another picture, and a label drawn on it doesn't. The last few results are kept, so undoing
/// the masks, which makes the scanned picture again, shows its result without scanning, and so does redoing them or taking
/// the masks out with a click.
///
/// **When it scans.** Only while the automatic check is on (`automatic`, the master switch) and at least one kind is on, and
/// only for a picture whose result isn't known: the first picture at once, a changed one after `rescanDelay` (each change
/// starting the delay over, and going back to a known picture cancelling it), and the current one at once when a switch
/// that matters is flipped. With the master switch off the button never scans on its own and shows no warning (the masked look
/// stays, being the document's); what a click found is kept, and shows if the switch is turned on again.
///
/// **Never stale.** A warning is never shown over a picture it wasn't read from. A result that arrives for a picture the
/// document has left is dropped (the change that left it has already asked for the scan wanted now), and after the owner
/// is `.closed` every event is ignored, so a late result does nothing.
///
/// Pure: the events carry counts, never a finding's text.
public struct SensitiveButtonState<Picture: Equatable & Sendable>: Equatable, Sendable {
    /// How long the document's picture must stay as it is before it is scanned again.
    public static var rescanDelay: Duration { .milliseconds(500) }

    /// How many results are kept: the picture as scanned, the one with the masks in it, and a few more for what the person does
    /// in between.
    private static var resultsKept: Int { 4 }

    public enum Event: Equatable, Sendable {
        /// The master switch or the kinds in Settings changed (or are read again: the same values change nothing).
        case settingsChanged(automatic: Bool, kinds: SensitiveKinds)
        /// The document's picture is `Picture` now. The editor's first report is the picture it opened with.
        case pictureChanged(Picture)
        /// The document holds this many masks the secrets check made (a count below none is none).
        case masksChanged(Int)
        /// The automatic scan of `picture` for `kinds` ended with these counts (none: nothing sensitive in it).
        case scanFinished(Picture, kinds: SensitiveKinds, counts: FindingCounts)
        /// The automatic scan of `picture` for `kinds` couldn't be made.
        case scanFailed(Picture, kinds: SensitiveKinds)
        /// A click's own work ended with these counts for `picture`: its scan's findings, or, once its masks were added, nothing
        /// for the picture with the masks in it. The automatic scan for the same picture is redundant now.
        case checked(Picture, kinds: SensitiveKinds, counts: FindingCounts)
        /// The editor closed.
        case closed
    }

    /// A result: what a scan of `picture` for `kinds` found.
    private struct Scanned: Equatable, Sendable {
        var picture: Picture
        var kinds: SensitiveKinds
        var counts: FindingCounts
    }

    /// The master switch: whether the editor checks on its own.
    public private(set) var automatic: Bool
    /// The kinds switched on in Settings.
    public private(set) var kinds: SensitiveKinds
    /// The document's picture as last reported; nil until the editor has reported one.
    public private(set) var picture: Picture?
    /// How many masks the secrets check made the document holds.
    public private(set) var maskCount = 0
    /// The last results, the newest last.
    private var results: [Scanned] = []
    /// A scan is wanted: the automatic one is waiting out its delay or running.
    private var scanWanted = false
    private var isClosed = false

    public init(automatic: Bool = true, kinds: SensitiveKinds = .all) {
        self.automatic = automatic
        self.kinds = kinds
    }

    /// What the button shows now.
    public var phase: SensitiveButtonPhase {
        if let known = currentResult, !known.isEmpty { return .found(known) }
        if maskCount > 0 { return .masked(maskCount) }
        if kinds.isEmpty { return .disabled }
        if currentResult != nil { return .none }
        return scanWanted ? .scanning : .idle
    }

    /// Whether the warning shows.
    public var showsWarning: Bool {
        if case .found = phase { true } else { false }
    }

    /// What a click does: take the masks out from the masked look, otherwise scan and mask.
    public var action: SensitiveButtonAction {
        if case .masked = phase { .unmask } else { .mask }
    }

    /// Whether a click does anything: not with no kind on and nothing to unmask, and not while a Mask Sensitive Info run is under
    /// way (the command refuses a second, so the button is off meanwhile). `maskRunning` is the app's.
    public func isEnabled(maskRunning: Bool) -> Bool {
        phase != .disabled && !maskRunning
    }

    /// The state after `event`, and what the owner does about its scan.
    @discardableResult
    public mutating func apply(_ event: Event) -> SensitiveButtonEffect {
        guard !isClosed else { return .none }
        switch event {
        case .settingsChanged(let automatic, let kinds):
            guard automatic != self.automatic || kinds != self.kinds else { return .none }
            self.automatic = automatic
            self.kinds = kinds
            return reconsider(after: .zero)

        case .pictureChanged(let new):
            guard new != picture else { return .none }
            // The first picture is scanned at once; a change waits, so a run of them scans once.
            let delay: Duration = picture == nil ? .zero : Self.rescanDelay
            picture = new
            return reconsider(after: delay)

        case .masksChanged(let count):
            maskCount = max(0, count)
            return .none

        case .scanFinished(let finished, let kinds, let counts):
            guard covers(picture: finished, kinds: kinds) else { return .none }
            remember(Scanned(picture: finished, kinds: kinds, counts: counts))
            scanWanted = false
            return .none

        case .scanFailed(let failed, let kinds):
            guard covers(picture: failed, kinds: kinds) else { return .none }
            scanWanted = false
            return .none

        case .checked(let checked, let kinds, let counts):
            guard covers(picture: checked, kinds: kinds) else { return .none }
            remember(Scanned(picture: checked, kinds: kinds, counts: counts))
            return settleScan()

        case .closed:
            isClosed = true
            return settleScan()
        }
    }

    /// Whether a result for `picture` and `kinds` is for the picture the document has now with the kinds that are on.
    private func covers(picture result: Picture, kinds resultKinds: SensitiveKinds) -> Bool {
        result == picture && resultKinds == kinds
    }

    /// What the scans say about the picture as it is now with the kinds that are on, while the automatic check is on (with it off
    /// nothing rescans, so no result is shown). Nil when no scan has read it.
    private var currentResult: FindingCounts? {
        automatic ? results.first { covers(picture: $0.picture, kinds: $0.kinds) }?.counts : nil
    }

    /// Whether the picture and kinds as they are now have a result, whether or not it is shown.
    private var isCovered: Bool {
        results.contains { covers(picture: $0.picture, kinds: $0.kinds) }
    }

    /// Keeps `result` as the newest, in place of one for the same picture and kinds, and forgets the oldest past the limit.
    private mutating func remember(_ result: Scanned) {
        results.removeAll { $0.picture == result.picture && $0.kinds == result.kinds }
        results.append(result)
        if results.count > Self.resultsKept { results.removeFirst(results.count - Self.resultsKept) }
    }

    /// After the picture or the settings changed: scan the picture as it is now when the check is on, there is something to
    /// look for and its result isn't known; otherwise no scan is wanted, and one that was is cancelled.
    private mutating func reconsider(after delay: Duration) -> SensitiveButtonEffect {
        guard automatic, !kinds.isEmpty, picture != nil, !isCovered else { return settleScan() }
        scanWanted = true
        return .scan(after: delay)
    }

    /// No scan is wanted any more: cancel the one that was.
    private mutating func settleScan() -> SensitiveButtonEffect {
        defer { scanWanted = false }
        return scanWanted ? .cancelScan : .none
    }
}
