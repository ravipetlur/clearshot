import Foundation

/// How a color is written as text when it is copied from a picture. Every format writes the color's sRGB value, opaque:
/// alpha is left out. HEX, RGB and HSL are written from the color rounded to whole bytes, so the three always name the same
/// color; OKLCH is computed from those bytes too.
public enum ColorFormat: String, CaseIterable, Sendable, Identifiable, PrefValue {
    /// "#1E90FF"
    case hex
    /// "1E90FF"
    case hexWithoutHash
    /// "rgb(30, 144, 255)"
    case rgb
    /// "hsl(210, 100%, 56%)"
    case hsl
    /// "oklch(65.2% 0.19 253.2)": lightness as a percentage, chroma, and hue in degrees, as CSS Color 4 writes it.
    case oklch

    public var id: String { rawValue }

    /// The name a menu or a settings picker shows.
    public var title: String {
        switch self {
        case .hex: "HEX"
        case .hexWithoutHash: "HEX without #"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .oklch: "OKLCH"
        }
    }

    /// `color` written in this format.
    public func string(for color: some SRGBColor) -> String {
        let bytes = color.bytes
        switch self {
        case .hex:
            return String(format: "#%02X%02X%02X", bytes.red, bytes.green, bytes.blue)
        case .hexWithoutHash:
            return String(format: "%02X%02X%02X", bytes.red, bytes.green, bytes.blue)
        case .rgb:
            return "rgb(\(bytes.red), \(bytes.green), \(bytes.blue))"
        case .hsl:
            let hsl = Self.hsl(bytes)
            return "hsl(\(hsl.hue), \(hsl.saturation)%, \(hsl.lightness)%)"
        case .oklch:
            let lch = Self.oklch(bytes)
            return "oklch(\(Self.number(lch.lightness * 100, decimals: 1))% \(Self.number(lch.chroma, decimals: 3)) "
                + "\(Self.number(lch.hue, decimals: 1)))"
        }
    }

    // MARK: Conversions

    /// Hue in whole degrees (0..<360), saturation and lightness in whole percent. A gray has hue 0 and saturation 0.
    static func hsl(_ bytes: (red: Int, green: Int, blue: Int)) -> (hue: Int, saturation: Int, lightness: Int) {
        let r = Double(bytes.red) / 255, g = Double(bytes.green) / 255, b = Double(bytes.blue) / 255
        let high = max(r, g, b), low = min(r, g, b)
        let lightness = (high + low) / 2
        let delta = high - low
        guard delta > 0 else { return (0, 0, Int((lightness * 100).rounded())) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch high {
        case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g: hue = (b - r) / delta + 2
        default: hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        let degrees = Int(hue.rounded()) % 360
        return (degrees, Int((saturation * 100).rounded()), Int((lightness * 100).rounded()))
    }

    /// Oklab's lightness (0...1), chroma and hue in degrees (0..<360), from Björn Ottosson's sRGB matrices. A color whose
    /// chroma would be written as 0 has hue 0, so a gray never shows a hue picked out of rounding noise.
    static func oklch(_ bytes: (red: Int, green: Int, blue: Int)) -> (lightness: Double, chroma: Double, hue: Double) {
        let r = linearSRGB(Double(bytes.red) / 255), g = linearSRGB(Double(bytes.green) / 255), b = linearSRGB(Double(bytes.blue) / 255)
        let l = cbrt(0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b)
        let m = cbrt(0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b)
        let s = cbrt(0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b)
        let lightness = 0.210_454_255_3 * l + 0.793_617_785_0 * m - 0.004_072_046_8 * s
        let a = 1.977_998_495_1 * l - 2.428_592_205_0 * m + 0.450_593_709_9 * s
        let bb = 0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766_0 * s
        let chroma = (a * a + bb * bb).squareRoot()
        guard chroma >= 0.0005 else { return (lightness, 0, 0) }
        var hue = atan2(bb, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        // Written to one decimal, 359.95 and above would read "360".
        if hue >= 359.95 { hue = 0 }
        return (lightness, chroma, hue)
    }

    /// `value` with at most `decimals` decimals, trailing zeros dropped ("62.8", "0.258", "100", "0"), never "-0".
    static func number(_ value: Double, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}
