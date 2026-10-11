/// What Annotate's Mask Sensitive Info command says: its name, the message while it works, the one it ends with, and the
/// line it leaves in the log.
///
/// Pure. Every string here is made of counts and the names of kinds: never a finding's text, which nothing keeps.
public enum MaskCommandText {
    /// The Edit menu's title, and the name of the undo step ("Undo Mask Sensitive Info").
    public static let commandName = "Mask Sensitive Info"

    /// The Edit menu's title once the capture has masks to take out (the sensitive-info button's second click), and the name of
    /// the undo step ("Undo Unmask Sensitive Info").
    public static let unmaskCommandName = "Unmask Sensitive Info"

    /// While the scan runs. A big image is read in several pieces and can take seconds; the result replaces this.
    public static let checking = "Checking for sensitive info…"

    /// The result: how many masks were added, or that there was nothing to mask. A count of the masks actually added, not
    /// of the findings: a finding that lies on no pixel of the picture itself gets no mask.
    public static func result(masksAdded: Int) -> String {
        switch masksAdded {
        case ..<1: "Nothing sensitive found"
        case 1: "Masked 1 item"
        default: "Masked \(masksAdded) items"
        }
    }

    /// The result of taking the masks out: how many were removed.
    public static func unmaskResult(masksRemoved: Int) -> String {
        switch masksRemoved {
        case ..<1: "Nothing to unmask"
        case 1: "Unmasked 1 item"
        default: "Unmasked \(masksRemoved) items"
        }
    }

    /// What taking the masks out leaves in the log: "3 masks taken out". A count only.
    public static func unmaskLogSummary(masksRemoved: Int) -> String {
        "\(masksRemoved) \(masksRemoved == 1 ? "mask" : "masks") taken out"
    }

    /// What is said when the masked picture replaced the copy of the capture that was on the clipboard: it is the one confirmation
    /// of that the person gets (the copy itself says nothing). Mask All adds it to its message, and Annotate's Done says it
    /// alone, after masks were added in the editor.
    public static let clipboardUpdated = "Clipboard updated"

    /// What Mask All on a Quick Access thumbnail says when it is done: the count as Annotate words it ("Masked 3 items"), and
    /// " · Clipboard updated" when the masked picture replaced the copy of the capture that was on the clipboard.
    public static func maskAllConfirmation(masksAdded: Int, clipboardUpdated updated: Bool) -> String {
        result(masksAdded: masksAdded) + (updated ? " · " + clipboardUpdated : "")
    }

    /// The image couldn't be rendered or read.
    public static let couldntCheck = "Couldn't check this image for sensitive info"

    /// The scan finished while the person was in the middle of an edit (a crop, a drag, text being typed), which the masks
    /// mustn't be added under; nothing was added.
    public static let editInProgress = "Nothing masked: finish your edit, then try again."

    /// Taking the masks out was refused while the person was in the middle of an edit (a crop, a drag, text being typed), which
    /// the removal mustn't be made under; nothing was removed.
    public static let unmaskEditInProgress = "Nothing unmasked: finish your edit, then try again."

    /// What a run leaves in the log: "3 findings (Contact details 2, Keys and tokens 1), 2 masks added". Counts by kind and
    /// the number of masks, so a finding that got no mask shows as the difference.
    public static func logSummary(findings: FindingCounts, masksAdded: Int) -> String {
        "\(BadgeText.logSummary(for: findings)), \(masksAdded) \(masksAdded == 1 ? "mask" : "masks") added"
    }
}
