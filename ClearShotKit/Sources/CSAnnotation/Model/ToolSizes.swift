/// Tool sizes in points for the six size levels (number keys 1–6).
public enum ToolSizes {
    public static let levels = 1...6

    public static func clamped(_ level: Int) -> Int { min(max(level, 1), 6) }

    /// Shapes, lines, arrows and the pen.
    public static func lineWidth(_ level: Int) -> Double { [2, 3, 5, 8, 12, 18][clamped(level) - 1] }
    /// Text.
    public static func fontSize(_ level: Int) -> Double { [14, 18, 24, 32, 48, 72][clamped(level) - 1] }
    /// Counters.
    public static func counterDiameter(_ level: Int) -> Double { [20, 26, 32, 40, 52, 64][clamped(level) - 1] }
    /// The highlighter's marker height.
    public static func highlighterWidth(_ level: Int) -> Double { [12, 16, 22, 28, 36, 48][clamped(level) - 1] }
}
