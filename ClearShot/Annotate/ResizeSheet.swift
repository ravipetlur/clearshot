import CSAnnotation
import SwiftUI

/// Resize: the canvas's new size in pixels, proportions kept by default, and 25–200% presets. Annotations scale with
/// the picture and stay editable, so there is no flatten warning.
///
/// Like the Quick Access Resize dialog, the fields are plain text parsed on every keystroke, so Resize and Return use
/// exactly what is showing. `limit` is the largest size the editor can give (`AnnotationEditor.resizeLimit`). A size over it
/// is brought within it, by one factor for both sides when the proportions are kept (`fitted`), and the text shows the
/// result.
struct ResizeSheet: View {
    let original: CGSize
    let limitWidth: Int
    let limitHeight: Int
    let onResize: (Int, Int) -> Void
    let onCancel: () -> Void
    @State private var widthText: String
    @State private var heightText: String
    @State private var keepsProportions = true
    /// The pair this view last wrote into the fields itself. The `onChange` that follows such a write sees that pair and
    /// stops, so the two fields don't chase each other's rounding.
    @State private var derived: Pair?

    struct Pair: Equatable {
        var width: Int
        var height: Int
    }

    init(size: CGSize, limit: CGSize, onResize: @escaping (Int, Int) -> Void, onCancel: @escaping () -> Void) {
        let limitWidth = Self.whole(limit.width), limitHeight = Self.whole(limit.height)
        original = size
        self.limitWidth = limitWidth
        self.limitHeight = limitHeight
        self.onResize = onResize
        self.onCancel = onCancel
        let start = Self.fitted(width: size.width, height: size.height, limitWidth: limitWidth, limitHeight: limitHeight)
        _widthText = State(initialValue: String(start.width))
        _heightText = State(initialValue: String(start.height))
    }

    // MARK: Sizes

    /// `value` as a whole number of pixels, within 1…16 383; what isn't a number is the largest.
    private static func whole(_ value: Double) -> Int {
        guard !value.isNaN else { return Int(AnnotationDocument.maximumOutputSide) }
        return Int(min(max(value.rounded(), 1), AnnotationDocument.maximumOutputSide))
    }

    /// A requested `width` × `height` (not yet within any limit, and not rounded) as whole pixels within the limits: both
    /// sides scaled by the one factor that makes them fit, so the proportions asked for hold. A request that already fits
    /// is only rounded. Typing, the lock's other field and the percent presets all come through here.
    static func fitted(width: Double, height: Double, limitWidth: Int, limitHeight: Int) -> Pair {
        var factor = 1.0
        if width > 0 { factor = min(factor, Double(limitWidth) / width) }
        if height > 0 { factor = min(factor, Double(limitHeight) / height) }
        return Pair(width: whole(width * factor), height: whole(height * factor))
    }

    /// The pixels a field's text says: nil for text that isn't a whole number. Digits too many for an `Int` are far past any
    /// limit, so they count as the largest.
    private static func pixels(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let value = Int(trimmed) { return value }
        return !trimmed.isEmpty && trimmed.allSatisfy({ ("0"..."9").contains($0) }) ? .max : nil
    }

    private var width: Int? { Self.pixels(widthText) }
    private var height: Int? { Self.pixels(heightText) }

    private var canResize: Bool {
        guard let width, let height else { return false }
        return width >= 1 && height >= 1
    }

    /// Puts `pair` in the fields, leaving a field that already says it as typed.
    private func show(_ pair: Pair) {
        derived = pair
        if width != pair.width { widthText = String(pair.width) }
        if height != pair.height { heightText = String(pair.height) }
    }

    /// The pair the fields hold now, if both are numbers and it is the one this view just wrote.
    private var isOwnWrite: Bool {
        guard let width, let height else { return false }
        return Pair(width: width, height: height) == derived
    }

    /// A width was typed, or `force`d by Keep proportions being turned on, which starts from the width.
    private func widthChanged(force: Bool = false) {
        guard let typed = width, typed >= 1, force || !isOwnWrite else { return }
        if keepsProportions, original.width > 0 {
            show(Self.fitted(width: Double(typed), height: Double(typed) * original.height / original.width,
                             limitWidth: limitWidth, limitHeight: limitHeight))
        } else if typed > limitWidth {
            widthText = String(limitWidth)
        }
    }

    private func heightChanged() {
        guard let typed = height, typed >= 1, !isOwnWrite else { return }
        if keepsProportions, original.height > 0 {
            show(Self.fitted(width: Double(typed) * original.width / original.height, height: Double(typed),
                             limitWidth: limitWidth, limitHeight: limitHeight))
        } else if typed > limitHeight {
            heightText = String(limitHeight)
        }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resize image").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Width")
                    TextField("Width", text: $widthText)
                        .labelsHidden()
                        .frame(width: 80)
                    Text("px").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Height")
                    TextField("Height", text: $heightText)
                        .labelsHidden()
                        .frame(width: 80)
                    Text("px").foregroundStyle(.secondary)
                }
            }
            Toggle("Keep proportions", isOn: $keepsProportions)
            HStack(spacing: 8) {
                ForEach([25.0, 50, 75, 200], id: \.self) { percent in
                    Button("\(Int(percent))%") {
                        show(Self.fitted(width: original.width * percent / 100, height: original.height * percent / 100,
                                         limitWidth: limitWidth, limitHeight: limitHeight))
                    }
                }
            }
            Text("Annotations are resized with the image and stay editable.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Resize") {
                    guard let width, let height else { return }
                    onResize(min(width, limitWidth), min(height, limitHeight))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canResize)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onChange(of: widthText) { widthChanged() }
        .onChange(of: heightText) { heightChanged() }
        .onChange(of: keepsProportions) {
            if keepsProportions { widthChanged(force: true) }
        }
    }
}
