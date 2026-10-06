import SwiftUI

/// The shared HUD toast: a material capsule with an SF Symbol and one line of text.
struct HUDView: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
            .fixedSize()
    }
}
