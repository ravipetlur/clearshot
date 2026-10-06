import CSCore
import SwiftUI

/// Width and height in pixels, with proportions kept unless the person turns that off ("Resize…"). The fields are plain
/// text parsed on every keystroke, so Return resizes to exactly what is showing.
struct ResizeView: View {
    let original: CGSize
    let onResize: (Int, Int) -> Void
    let onCancel: () -> Void
    @State private var widthText: String
    @State private var heightText: String
    @State private var keepProportions = true

    init(original: CGSize, onResize: @escaping (Int, Int) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.onResize = onResize
        self.onCancel = onCancel
        _widthText = State(initialValue: String(Int(original.width)))
        _heightText = State(initialValue: String(Int(original.height)))
    }

    private var width: Int? { Int(widthText.trimmingCharacters(in: .whitespaces)) }
    private var height: Int? { Int(heightText.trimmingCharacters(in: .whitespaces)) }

    private var canResize: Bool {
        guard let width, let height else { return false }
        return ResizeDimensions.isValid(width: width, height: height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                TextField("Width", text: $widthText)
                TextField("Height", text: $heightText)
                Toggle("Keep proportions", isOn: $keepProportions)
            }
            Text("Original size: \(Int(original.width)) × \(Int(original.height)) pixels")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Resize") {
                    guard let width, let height else { return }
                    onResize(width, height)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canResize)
            }
        }
        .padding(20)
        .frame(width: 320)
        // Only the side the person didn't type is recomputed; isProportional stops the two fields chasing each
        // other's rounding. A side that doesn't parse counts as not proportional.
        .onChange(of: widthText) {
            guard keepProportions, let width else { return }
            if let height, ResizeDimensions.isProportional(width: width, height: height, original: original) { return }
            heightText = String(ResizeDimensions.height(forWidth: width, original: original))
        }
        .onChange(of: heightText) {
            guard keepProportions, let height else { return }
            if let width, ResizeDimensions.isProportional(width: width, height: height, original: original) { return }
            widthText = String(ResizeDimensions.width(forHeight: height, original: original))
        }
        .onChange(of: keepProportions) {
            guard keepProportions, let width else { return }
            heightText = String(ResizeDimensions.height(forWidth: width, original: original))
        }
    }
}
