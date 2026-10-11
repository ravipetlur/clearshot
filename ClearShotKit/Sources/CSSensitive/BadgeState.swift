/// How many findings a scan made, by kind: what the badge counts and its tooltip lists.
public struct FindingCounts: Equatable, Sendable {
    /// Only the kinds with a count of one or more.
    private var counts: [SensitiveKind: Int]

    public init(_ findings: [ImageFinding]) {
        var counts: [SensitiveKind: Int] = [:]
        for finding in findings { counts[finding.kind, default: 0] += 1 }
        self.counts = counts
    }

    /// `counts` as given, a kind with no findings (a count of nothing, or less) left out.
    public init(_ counts: [SensitiveKind: Int]) {
        self.counts = counts.filter { $0.value > 0 }
    }

    public subscript(kind: SensitiveKind) -> Int { counts[kind] ?? 0 }

    public var total: Int { counts.values.reduce(0, +) }

    public var isEmpty: Bool { counts.isEmpty }

    /// The kinds that have findings, each with its count, in the order Settings lists the kinds.
    public var breakdown: [(kind: SensitiveKind, count: Int)] {
        SensitiveKind.allCases.compactMap { kind in counts[kind].map { (kind: kind, count: $0) } }
    }
}

/// What the badge on a Quick Access thumbnail shows for one capture, as a state machine.
///
/// ```
/// scanning ──scan finds something──▶ found ──Mask All──▶ masked
///    │                                 ▲  │                 │
///    │                                 └──┼──Undo Mask──────┘
///    ├──scan finds nothing, or fails──▶ none
///    │                                    │     Dismiss, from found or masked
///    └────────────────────────────────────┴──────────────────────────▶ dismissed
/// ```
///
/// An event that doesn't apply to the state leaves it as it is (`apply(_:)`): a second scan result, Mask All on a masked
/// badge, anything at all once the badge is dismissed.
public struct BadgeState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The scan is running: no badge yet.
        case scanning
        /// The scan found nothing, or couldn't run: no badge.
        case none
        /// The scan found something: the badge shows the counts, with Mask All, Review in Annotate and Dismiss.
        case found(FindingCounts)
        /// Mask All was chosen: the badge says so, with Undo Mask.
        case masked(FindingCounts)
        /// The badge was dismissed for this capture.
        case dismissed
    }

    public enum Event: Equatable, Sendable {
        /// The scan ended with these counts (none: nothing sensitive in the capture).
        case scanFinished(FindingCounts)
        /// The scan couldn't be done.
        case scanFailed
        /// Mask All was chosen.
        case maskAll
        /// Undo Mask was chosen.
        case undoMask
        /// Dismiss was chosen.
        case dismiss
    }

    public private(set) var phase: Phase

    public init(phase: Phase = .scanning) {
        self.phase = phase
    }

    /// The state after `event`.
    public mutating func apply(_ event: Event) {
        switch (phase, event) {
        case (.scanning, .scanFinished(let counts)):
            phase = counts.isEmpty ? .none : .found(counts)
        case (.scanning, .scanFailed):
            phase = .none
        case (.found(let counts), .maskAll):
            phase = .masked(counts)
        case (.masked(let counts), .undoMask):
            phase = .found(counts)
        case (.found, .dismiss), (.masked, .dismiss):
            phase = .dismissed
        default:
            break
        }
    }

    /// Whether the badge is on the thumbnail.
    public var isVisible: Bool {
        switch phase {
        case .found, .masked: true
        case .scanning, .none, .dismissed: false
        }
    }

    /// What the badge counts, while it shows.
    public var counts: FindingCounts? {
        switch phase {
        case .found(let counts), .masked(let counts): counts
        case .scanning, .none, .dismissed: nil
        }
    }
}
