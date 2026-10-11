/// What the sensitive-info button in Annotate's tool strip says: its label while findings wait, its tooltip, what VoiceOver
/// reads, what it says a click does, and the title of the Edit menu's item that does the same.
///
/// Pure, and worded as the thumbnail's badge words the same findings (`BadgeText`). Every string here is made of counts and
/// the names of kinds: never a finding's text, which nothing keeps.
public enum SensitiveButtonText {
    /// What sits on the button: "⚠︎ 3" while findings wait (the count stops at "99+", so the button stays one width). Nil
    /// for every other phase: the button then shows its symbol alone.
    public static func label(for phase: SensitiveButtonPhase) -> String? {
        guard case .found(let counts) = phase else { return nil }
        return BadgeText.label(for: BadgeState(phase: .found(counts)))
    }

    /// The tooltip: the counts by kind ("3 possible secrets: 2 contact details, 1 key or token") while findings wait; the number
    /// of masks and what a click does ("3 possible secrets masked: click to unmask") in the masked look; and for the plain phases
    /// what the button is or why it is off.
    public static func tooltip(for phase: SensitiveButtonPhase) -> String {
        switch phase {
        case .found(let counts):
            BadgeText.tooltip(for: BadgeState(phase: .found(counts))) ?? MaskCommandText.commandName
        case .masked(let masks):
            "\(masks == 1 ? "1 possible secret" : "\(masks) possible secrets") masked: click to unmask"
        case .idle:
            MaskCommandText.commandName
        case .scanning:
            MaskCommandText.checking
        case .none:
            "No possible secrets found"
        case .disabled:
            "\(MaskCommandText.commandName) is off: no kind is switched on in Settings › Quick Access"
        }
    }

    /// What VoiceOver reads: the tooltip's words.
    public static func accessibilityLabel(for phase: SensitiveButtonPhase) -> String {
        tooltip(for: phase)
    }

    /// What VoiceOver says a click does.
    public static func accessibilityHelp(for phase: SensitiveButtonPhase) -> String {
        switch phase {
        case .found:
            "Masks every possible secret in the picture, as one undo step"
        case .idle, .scanning, .none:
            "Looks for sensitive info in the picture and masks it, as one undo step"
        case .masked:
            "Takes out the masks the sensitive-info check added, as one undo step"
        case .disabled:
            "Switch on a kind of sensitive info in Settings › Quick Access to use it"
        }
    }

    /// The Edit menu's item while no editor answers it (a History or Settings window is in front, or the last editor closed): the
    /// item is disabled then, and says "Mask Sensitive Info", never "Unmask".
    public static let menuTitleWithNoEditor = MaskCommandText.commandName

    /// The Edit menu's item, which does what a click does: "Unmask Sensitive Info" in the masked look, otherwise "Mask Sensitive
    /// Info".
    public static func menuTitle(for phase: SensitiveButtonPhase) -> String {
        if case .masked = phase { MaskCommandText.unmaskCommandName } else { MaskCommandText.commandName }
    }
}
