import CSAnnotation
import SwiftUI

/// The property bar's controls for a pixel selection: Pad grows it on every side (⇧ for 10 pixels), and Fit trims it to its
/// content (⌥A).
struct PixelSelectionPad: View {
    @Bindable var editor: AnnotationEditor

    var body: some View {
        HStack(spacing: 6) {
            Text("Pad").foregroundStyle(.secondary)
            Button { pad(by: -1) } label: { Image(systemName: "minus") }
                .help("Shrink the selection by 1 pixel on every side (⇧ for 10)")
            Button { pad(by: 1) } label: { Image(systemName: "plus") }
                .help("Grow the selection by 1 pixel on every side (⇧ for 10)")
            Button("Fit") { Task { await editor.fitPixelSelectionToContent() } }
                .help("Fit the selection to its content (⌥A)")
        }
    }

    private func pad(by amount: Double) {
        let step = NSEvent.modifierFlags.contains(.shift) ? 10.0 : 1.0
        editor.growPixelSelection(by: amount * step)
    }
}
