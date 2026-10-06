import Foundation

public struct NamedColor: Hashable, Sendable, Identifiable {
    public let name: String
    public let color: RGBAColor
    public var id: String { name }

    init(_ name: String, _ hex: String) {
        self.name = name
        color = RGBAColor(hex: hex)!
    }
}

/// The Annotate palette: ClearShot's own named colors.
public enum ColorPalette {
    public static let standard: [NamedColor] = [
        NamedColor("Red", "#FF3B30"),
        NamedColor("Orange", "#FF9500"),
        NamedColor("Yellow", "#FFCC00"),
        NamedColor("Green", "#34C759"),
        NamedColor("Teal", "#30B0C7"),
        NamedColor("Blue", "#007AFF"),
        NamedColor("Indigo", "#5856D6"),
        NamedColor("Purple", "#AF52DE"),
        NamedColor("Pink", "#FF2D55"),
        NamedColor("Brown", "#A2845E"),
        NamedColor("Gray", "#8E8E93"),
        NamedColor("Black", "#000000"),
        NamedColor("White", "#FFFFFF"),
    ]

    public static var defaultColor: RGBAColor { standard[0].color }

    /// The palette name nearest to `color`, or its hex code when no palette color is close (color-name labels).
    public static func name(for color: RGBAColor) -> String {
        let nearest = standard.min { distance($0.color, color) < distance($1.color, color) }!
        return distance(nearest.color, color) < 0.002 ? nearest.name : color.hex
    }

    static func distance(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        pow(a.red - b.red, 2) + pow(a.green - b.green, 2) + pow(a.blue - b.blue, 2)
    }
}
