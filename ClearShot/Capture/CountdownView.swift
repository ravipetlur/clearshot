import SwiftUI

@Observable
final class CountdownModel {
    var remaining: Int
    var cancelled = false

    init(remaining: Int) {
        self.remaining = remaining
    }
}

struct CountdownView: View {
    @Bindable var model: CountdownModel

    var body: some View {
        VStack(spacing: 12) {
            Text("\(model.remaining)")
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
            Button("Cancel") { model.cancelled = true }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
