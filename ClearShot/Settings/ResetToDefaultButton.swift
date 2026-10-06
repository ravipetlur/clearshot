import SwiftUI

/// A shortcut row's "Reset to default" as a small button beside its field. The row's context menu has it too, but a
/// right-click on the field itself (the shortcut recorder, a tool's letter) opens the field's own text menu instead.
/// Dimmed while the row is at its default. VoiceOver names the row (`rowTitle`), so the buttons can be told apart.
struct ResetToDefaultButton: View {
    let rowTitle: String
    let isAtDefault: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .help("Reset to default")
        .accessibilityLabel("Reset \(rowTitle) to default")
        .disabled(isAtDefault)
    }
}
