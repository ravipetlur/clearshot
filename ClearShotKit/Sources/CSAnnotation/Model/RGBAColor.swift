import CoreGraphics
import Foundation

/// An sRGB color with alpha, as stored in documents and preferences.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// "#RGB", "#RRGGBB" or "#RRGGBBAA", with or without "#", in any case. Each digit of "#RGB" doubles ("#F80" is
    /// "#FF8800"). A color that names no alpha (3 or 6 digits) gets `defaultAlpha`.
    public init?(hex: String, defaultAlpha: Double = 1) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 3 || digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count == 3 { digits = digits.flatMap { [$0, $0] }.map(String.init).joined() }
        guard let value = UInt64(digits, radix: 16) else { return nil }
        func channel(_ shift: UInt64) -> Double { Double((value >> shift) & 0xFF) / 255 }
        if digits.count == 6 {
            self.init(red: channel(16), green: channel(8), blue: channel(0), alpha: defaultAlpha)
        } else {
            self.init(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
        }
    }

    /// The color converted to sRGB, or nil if it can't be converted.
    public init?(_ color: CGColor) {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 4 else { return nil }
        self.init(red: components[0], green: components[1], blue: components[2], alpha: components[3])
    }

    /// "#RRGGBB", plus "AA" when the color isn't fully opaque.
    public var hex: String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return alpha < 1 ? rgb + String(format: "%02X", byte(alpha)) : rgb
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public func withAlpha(_ alpha: Double) -> RGBAColor {
        var copy = self
        copy.alpha = alpha
        return copy
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Black or white text for this background (counters, text boxes). A luminance threshold of 0.32, tuned for the
    /// palette: Yellow, Orange, Green, Teal and White get black; Red, Pink, Blue, Indigo, Purple, Brown, Gray and
    /// Black get white.
    public var contrastingTextColor: RGBAColor {
        luminance > 0.32 ? .black : .white
    }

    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
}
