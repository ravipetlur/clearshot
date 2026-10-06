import Foundation

/// What the Background panel offers and accepts, kept here so its rules are tested.
extension BackgroundFill {
    /// The colours the panel offers as swatches, in its order. Any other colour fill is the custom colour.
    public static let colorSwatches: [RGBAColor] = ["#FFFFFF", "#F2F2F7", "#C7C7CC", "#8E8E93", "#3A3A3C", "#000000",
                                                    "#E8F0FE", "#FFF4E5"].map { RGBAColor(hex: $0)! }

    /// Whether the fill is a colour other than the swatches (one of them at another opacity counts): the panel's custom
    /// colour swatch shows it, selected.
    public var isCustomColor: Bool {
        guard case .color(let color) = self else { return false }
        return !Self.colorSwatches.contains(color)
    }
}

extension BackgroundStyle {
    /// A value typed into one of the panel's number fields (padding, inset, shadow, corners): the number `text` holds,
    /// rounded to a whole number and clamped to `range`, so a number too large to read as anything but infinity is the
    /// largest. Nil for text that isn't a number, which leaves the value as it was.
    public static func typedValue(_ text: String, in range: ClosedRange<Double>) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), !value.isNaN else { return nil }
        return min(max(value.rounded(), range.lowerBound), range.upperBound)
    }
}
