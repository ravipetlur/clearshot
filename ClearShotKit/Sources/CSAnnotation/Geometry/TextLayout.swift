import AppKit
import CoreText

/// Fonts, attributes and measured sizes for text objects. The renderer and the inline editor both use it, so what is
/// typed is laid out the way it renders.
public enum TextLayout {
    public static func font(for style: TextStyle, size: Double) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        let design: NSFontDescriptor.SystemDesign? = switch style {
        case .rounded, .roundedBox: .rounded
        case .mono, .monoBox: .monospaced
        case .standard, .outline, .box: nil
        }
        guard let design, let descriptor = base.fontDescriptor.withDesign(design),
              let font = NSFont(descriptor: descriptor, size: size) else { return base }
        return font
    }

    /// Space between a box style's edge and its text.
    public static func padding(for style: TextStyle, fontSize: Double) -> CGSize {
        style.hasBox ? CGSize(width: (fontSize * 0.45).rounded(), height: (fontSize * 0.25).rounded()) : .zero
    }

    /// Core Text attributes: the font, the fill (white or black inside boxes) and the outline style's contrasting
    /// stroke.
    public static func attributes(for text: TextObject, color: RGBAColor) -> [NSAttributedString.Key: Any] {
        let fill = text.style.hasBox ? color.contrastingTextColor : color
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: text.style, size: text.fontSize),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill.cgColor,
        ]
        if text.style == .outline {
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color.contrastingTextColor.cgColor
            // Negative widths fill and stroke; the value is a percentage of the font size.
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -4.0
        }
        return attributes
    }

    /// The laid-out text's size (without padding). Trailing newlines and spaces count, so the box grows as soon as
    /// Return or Space is pressed in the editor.
    public static func textSize(of text: TextObject) -> CGSize {
        let padding = padding(for: text.style, fontSize: text.fontSize)
        var string = text.string.isEmpty ? " " : text.string
        // Core Text gives a trailing newline no empty line; a zero-width space after it does.
        if string.last?.isNewline == true {
            string += "\u{200B}"
        }
        let maxWidth = text.width.map { max($0 - 2 * padding.width, 1) } ?? .greatestFiniteMagnitude
        var size = suggestedSize(of: string, for: text, maxWidth: maxWidth)
        if text.width == nil, text.string.last == " " {
            // Core Text also drops trailing spaces from the width, and even a zero-width space doesn't bring them
            // back. Measure past them with a visible mark and take the mark's own advance off again. (Unwrapped text
            // only: nothing wraps, so the mark can't change the height.)
            let mark = "|"
            size.width = suggestedSize(of: string + mark, for: text, maxWidth: maxWidth).width
                - suggestedSize(of: mark, for: text, maxWidth: maxWidth).width
        }
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private static func suggestedSize(of string: String, for text: TextObject, maxWidth: Double) -> CGSize {
        let attributed = NSAttributedString(string: string, attributes: attributes(for: text, color: .black))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        return CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                            CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
    }

    /// The whole box: text plus padding, with its top-left at `origin`. A set width is kept exactly.
    public static func frame(of text: TextObject) -> CGRect {
        let padding = padding(for: text.style, fontSize: text.fontSize)
        let size = textSize(of: text)
        return CGRect(x: text.origin.x, y: text.origin.y,
                      width: text.width ?? (size.width + 2 * padding.width),
                      height: size.height + 2 * padding.height)
    }
}
