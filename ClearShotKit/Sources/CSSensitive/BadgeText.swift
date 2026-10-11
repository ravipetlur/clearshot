/// What the badge on a Quick Access thumbnail says, as plain text: the pill, its tooltip, what VoiceOver reads, and the one
/// line a scan leaves in the log.
///
/// Pure. Every string here is made of counts and the names of kinds: never a finding's text, which nothing keeps.
public enum BadgeText {
    /// The pill: "⚠︎ 3" while findings wait (the count stops at "99+", so the pill stays one size), "Masked" once Mask All has
    /// run. Nil while there is no badge.
    public static func label(for state: BadgeState) -> String? {
        switch state.phase {
        case .found(let counts): "\u{26A0}\u{FE0E} \(counts.total > 99 ? "99+" : String(counts.total))"
        case .masked: "Masked"
        case .scanning, .none, .dismissed: nil
        }
    }

    /// The tooltip: "3 possible secrets: 2 contact details, 1 key or token", with "Masked" in front once they are masked.
    ///
    /// Once masked, it counts the masks that were added (`masksAdded`; the findings' number when nil), not the findings: a
    /// finding that lies on no pixel of the capture itself (text in a background's frame) has no mask. When there are fewer
    /// masks than findings it says "Masked 2 of 3 possible secrets", without the kinds, which count the findings.
    public static func tooltip(for state: BadgeState, masksAdded: Int? = nil) -> String? {
        switch state.phase {
        case .found(let counts):
            return sentence(counts)
        case .masked(let counts):
            guard let masksAdded, masksAdded != counts.total else { return "Masked " + sentence(counts) }
            return "Masked \(masksAdded) of \(counts.total) possible secrets"
        case .scanning, .none, .dismissed:
            return nil
        }
    }

    /// What VoiceOver reads for the pill: the tooltip's words.
    public static func accessibilityLabel(for state: BadgeState, masksAdded: Int? = nil) -> String? {
        tooltip(for: state, masksAdded: masksAdded)
    }

    /// What VoiceOver says the pill does: it opens the menu whose first command depends on the state.
    public static func accessibilityHelp(for state: BadgeState) -> String? {
        switch state.phase {
        case .found: "Opens a menu with Mask All, Review in Annotate and Dismiss"
        case .masked: "Opens a menu with Undo Mask, Review in Annotate and Dismiss"
        case .scanning, .none, .dismissed: nil
        }
    }

    /// The scan's result for the log: "3 findings (Contact details 2, Keys and tokens 1)", by the kinds' names in
    /// Settings, or "no findings".
    public static func logSummary(for counts: FindingCounts) -> String {
        guard !counts.isEmpty else { return "no findings" }
        let kinds = counts.breakdown.map { "\($0.kind.title) \($0.count)" }.joined(separator: ", ")
        return "\(counts.total) \(counts.total == 1 ? "finding" : "findings") (\(kinds))"
    }

    /// How long a scan took, for the log: seconds with two decimals ("1.23"). One helper for every line that says it, so the
    /// Quick Access check and Annotate's command read alike.
    public static func seconds(_ duration: Duration) -> String {
        let parts = duration.components
        let hundredths = Int(max(0, (Double(parts.seconds) + Double(parts.attoseconds) / 1e18) * 100).rounded())
        let fraction = hundredths % 100
        return "\(hundredths / 100).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    /// "3 possible secrets: 2 contact details, 1 key or token".
    private static func sentence(_ counts: FindingCounts) -> String {
        let secrets = counts.total == 1 ? "1 possible secret" : "\(counts.total) possible secrets"
        let kinds = counts.breakdown.map { "\($0.count) \(noun(for: $0.kind, count: $0.count))" }.joined(separator: ", ")
        return "\(secrets): \(kinds)"
    }

    private static func noun(for kind: SensitiveKind, count: Int) -> String {
        let one = count == 1
        return switch kind {
        case .contact: one ? "contact detail" : "contact details"
        case .keyOrToken: one ? "key or token" : "keys or tokens"
        case .card: one ? "card number" : "card numbers"
        case .ipAddress: one ? "IP address" : "IP addresses"
        }
    }
}
