import CSSensitive
import SwiftUI

/// The sensitive-info button at the trailing end of the tool strip, a toggle: a plain "eye.slash" button while there is nothing to
/// warn of, "⚠︎ 3" on a tinted ground while the scan of the picture has unmasked findings, and a green "checkmark.shield.fill"
/// once the document holds masks the secrets check made and nothing unmasked is left. A click is Edit › Mask Sensitive Info
/// (`action`): it masks every finding as one undo step, or, in the masked look, takes the marked masks out as one undo step.
///
/// **One width in every state.** The button is `width` × `height` whatever it shows (a symbol alone, or the widest label,
/// "⚠︎ 99+", with 8 pt a side), and the tinted ground only draws in the warning state, so nothing in the strip moves when the
/// phase changes. Its words (tooltip, VoiceOver) are `SensitiveButtonText`'s: the counts by kind, as the thumbnail's badge says
/// them. The state is `AnnotateSensitiveCheck`'s.
struct SensitiveInfoButton: View {
    let check: AnnotateSensitiveCheck
    let action: () -> Void

    /// The widest label ("⚠︎ 99+" in caption type) plus 8 pt a side.
    static let width: CGFloat = 56
    static let height: CGFloat = 24

    var body: some View {
        let phase = check.state.phase
        let isEnabled = check.isEnabled
        Button(action: action) {
            face(for: phase)
                .frame(width: Self.width, height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .background(check.state.showsWarning ? Color.orange.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .help(SensitiveButtonText.tooltip(for: phase))
        .accessibilityLabel(SensitiveButtonText.accessibilityLabel(for: phase))
        .accessibilityHint(SensitiveButtonText.accessibilityHelp(for: phase))
    }

    /// A symbol alone (the eye-slash, or the green shield with a check once masked), or the label with its warning sign in the
    /// system's orange and the count in the primary colour, as on the thumbnail's badge.
    @ViewBuilder
    private func face(for phase: SensitiveButtonPhase) -> some View {
        if let label = SensitiveButtonText.label(for: phase) {
            Text("\(Text(String(label.prefix(1))).foregroundStyle(Color.orange))\(Text(String(label.dropFirst())))")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        } else if case .masked = phase {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(Color.green)
        } else {
            Image(systemName: "eye.slash")
        }
    }
}
