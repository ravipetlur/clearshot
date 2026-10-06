import CoreGraphics

/// Arithmetic for the Resize… dialog, in pixels.
public enum ResizeDimensions {
    /// The largest side every format ClearShot writes can encode: libwebp's limit (the ImageIO formats go higher).
    public static let maxPixels = 16_383

    public static func height(forWidth width: Int, original: CGSize) -> Int {
        guard original.width > 0 else { return max(1, width) }
        return clampedSide(Double(width) * original.height / original.width)
    }

    public static func width(forHeight height: Int, original: CGSize) -> Int {
        guard original.height > 0 else { return max(1, height) }
        return clampedSide(Double(height) * original.width / original.height)
    }

    /// Rounds a computed side to an Int of at least 1. Absurdly large values are capped (far above `maxPixels`, so
    /// `isValid` still rejects them) instead of trapping in the Int conversion.
    private static func clampedSide(_ value: Double) -> Int {
        max(1, Int(min(value, Double(Int32.max)).rounded()))
    }

    /// Whether the pair already keeps the original's proportions, allowing for rounding in either direction. The
    /// dialog uses this to avoid recomputing a side the person just typed.
    public static func isProportional(width: Int, height: Int, original: CGSize) -> Bool {
        Self.height(forWidth: width, original: original) == height || Self.width(forHeight: height, original: original) == width
    }

    public static func isValid(width: Int, height: Int) -> Bool {
        (1...maxPixels).contains(width) && (1...maxPixels).contains(height)
    }
}
