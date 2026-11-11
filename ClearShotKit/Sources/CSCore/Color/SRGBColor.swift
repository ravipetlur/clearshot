import Foundation

/// A color given by its sRGB components, each 0...1 (gamma-encoded, as in "#RRGGBB"). The formats (`ColorFormat`) and the
/// contrast measures (`ColorContrast`) read colors through this, so any color type with these three numbers can use them:
/// Annotate's `RGBAColor` conforms. Alpha plays no part in either.
public protocol SRGBColor {
    var red: Double { get }
    var green: Double { get }
    var blue: Double { get }
}

extension SRGBColor {
    /// The three components as whole bytes, 0...255, clamped and rounded as "#RRGGBB" writes them.
    var bytes: (red: Int, green: Int, blue: Int) {
        func byte(_ value: Double) -> Int { Int((min(max(value.isFinite ? value : 0, 0), 1) * 255).rounded()) }
        return (byte(red), byte(green), byte(blue))
    }
}

/// sRGB's transfer function: a gamma-encoded component (0...1) to linear light.
func linearSRGB(_ component: Double) -> Double {
    component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
}
