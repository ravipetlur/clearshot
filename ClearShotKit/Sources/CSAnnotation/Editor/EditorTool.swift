/// The Annotate tools and Crop & Resize, each with a default letter; Settings can change the letters.
public enum EditorTool: String, CaseIterable, Identifiable, Sendable {
    case select, rectangle, filledRectangle, ellipse, line, arrow, text, redact, spotlight, counter, pen, highlighter, crop

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .select: "Select"
        case .rectangle: "Rectangle"
        case .filledRectangle: "Filled rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .text: "Text"
        case .redact: "Redact"
        case .spotlight: "Spotlight"
        case .counter: "Counter"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .crop: "Crop & Resize"
        }
    }

    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .filledRectangle: "rectangle.fill"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .redact: "rectangle.checkered"
        case .spotlight: "flashlight.on.fill"
        case .counter: "1.circle"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .crop: "crop"
        }
    }

    /// The letter that picks the tool unless Settings › Annotate › Tool shortcuts changes it.
    public var defaultKey: Character {
        switch self {
        case .select: "v"
        case .rectangle: "r"
        case .filledRectangle: "f"
        case .ellipse: "o"
        case .line: "l"
        case .arrow: "a"
        case .text: "t"
        case .redact: "b"
        case .spotlight: "s"
        case .counter: "n"
        case .pen: "p"
        case .highlighter: "h"
        case .crop: "c"
        }
    }

    /// The tool `key` picks with these letters (Settings › Annotate › Tool shortcuts), in either case.
    public static func forKey(_ key: Character, keys: AnnotateToolKeys) -> EditorTool? {
        keys.tool(for: key)
    }
}
