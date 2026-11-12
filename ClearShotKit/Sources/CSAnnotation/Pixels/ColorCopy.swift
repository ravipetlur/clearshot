import CoreGraphics
import CSCore

/// The three ways the Select tool copies a color from the picture, and what each reads.
public enum ColorCopy: Equatable, Sendable, CaseIterable {
    /// The color of the pixel under the pointer (Tab).
    case underPointer
    /// The darkest color in a square around the pointer, which is the color of text there (⇧Tab).
    case textUnderPointer
    /// The average color of the pixel selection (⌥Tab).
    case selectionAverage

    /// How far across, in pixels of the picture as shown, the square `textUnderPointer` reads is.
    public static let textSide = 20

    /// The color this command reads, from the pointer (base pixels) and the pixel selection (base pixels). Nil when it has
    /// nothing to read: the pointer is off the picture (or unknown), or `selectionAverage` has no selection.
    public func color(in pixels: PicturePixels, pointer: CGPoint?, selection: CGRect?) -> RGBAColor? {
        switch self {
        case .underPointer:
            return pointer.flatMap { pixels.color(at: $0) }
        case .textUnderPointer:
            return pointer.flatMap { pixels.darkest(around: $0, side: Self.textSide) }
        case .selectionAverage:
            return selection.flatMap { pixels.average(in: $0) }
        }
    }

    /// The text that goes on the pasteboard: `color` in `format`.
    public static func text(for color: RGBAColor, format: ColorFormat) -> String {
        format.string(for: color)
    }

    /// What the HUD says once `text` is copied: "Copied #1E90FF".
    public static func notice(copying text: String) -> String {
        "Copied \(text)"
    }
}
