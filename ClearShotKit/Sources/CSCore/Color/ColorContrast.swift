import Foundation

/// How readable one color is on another, by the two measures in use: WCAG 2's contrast ratio and APCA's lightness contrast.
/// Both read opaque sRGB colors (`SRGBColor`); alpha plays no part, so a translucent color is composited first by the caller.
public enum ColorContrast {
    // MARK: WCAG 2

    /// WCAG 2's relative luminance: 0 for black, 1 for white. The components are linearized with sRGB's own threshold
    /// (0.04045), which WCAG 2.2 notes in place of the older 0.03928; no 8-bit color comes out different.
    public static func relativeLuminance(of color: some SRGBColor) -> Double {
        0.2126 * linearSRGB(color.red) + 0.7152 * linearSRGB(color.green) + 0.0722 * linearSRGB(color.blue)
    }

    /// WCAG 2's contrast ratio of two colors, from 1 (the same luminance) to 21 (black and white). It is symmetric: which
    /// one is the text doesn't matter. 4.5 is the AA threshold for body text, 3 for large text, 7 for AAA.
    public static func wcagRatio(_ first: some SRGBColor, _ second: some SRGBColor) -> Double {
        let a = relativeLuminance(of: first), b = relativeLuminance(of: second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    // MARK: APCA

    /// APCA-W3 0.0.98G-4g's constants.
    private enum APCA {
        static let mainTRC = 2.4
        static let redCoefficient = 0.212_672_9, greenCoefficient = 0.715_152_2, blueCoefficient = 0.072_175_0
        static let normalBackground = 0.56, normalText = 0.57, reverseText = 0.62, reverseBackground = 0.65
        static let blackThreshold = 0.022, blackClamp = 1.414
        static let scaleBlackOnWhite = 1.14, scaleWhiteOnBlack = 1.14
        static let lowBlackOnWhiteOffset = 0.027, lowWhiteOnBlackOffset = 0.027
        static let deltaYMinimum = 0.0005, lowClip = 0.1
    }

    /// APCA's screen luminance Y of an sRGB color (a plain 2.4 power curve, as APCA defines it), before the soft clamp.
    static func apcaLuminance(of color: some SRGBColor) -> Double {
        func channel(_ value: Double) -> Double { pow(min(max(value, 0), 1), APCA.mainTRC) }
        return APCA.redCoefficient * channel(color.red) + APCA.greenCoefficient * channel(color.green)
            + APCA.blueCoefficient * channel(color.blue)
    }

    /// APCA's lightness contrast Lc of `text` on `background` (APCA-W3 0.0.98G-4g). Unlike WCAG's ratio it is signed and
    /// not symmetric: positive for dark text on a light background (black on white is about 106), negative for light text on
    /// a dark one (white on black is about -108), and 0 when the two are too close to matter (APCA clips anything under
    /// about 7.3 to 0). Readers compare its magnitude: 75 for body text, 60 for content text, 45 for headlines, 30 for spot
    /// text.
    public static func apcaContrast(text: some SRGBColor, background: some SRGBColor) -> Double {
        func softClamp(_ y: Double) -> Double {
            y > APCA.blackThreshold ? y : y + pow(APCA.blackThreshold - y, APCA.blackClamp)
        }
        let textY = softClamp(apcaLuminance(of: text))
        let backgroundY = softClamp(apcaLuminance(of: background))
        guard abs(backgroundY - textY) >= APCA.deltaYMinimum else { return 0 }
        let output: Double
        if backgroundY > textY {
            // Dark text on a light background.
            let contrast = (pow(backgroundY, APCA.normalBackground) - pow(textY, APCA.normalText)) * APCA.scaleBlackOnWhite
            output = contrast < APCA.lowClip ? 0 : contrast - APCA.lowBlackOnWhiteOffset
        } else {
            // Light text on a dark background.
            let contrast = (pow(backgroundY, APCA.reverseBackground) - pow(textY, APCA.reverseText)) * APCA.scaleWhiteOnBlack
            output = contrast > -APCA.lowClip ? 0 : contrast + APCA.lowWhiteOnBlackOffset
        }
        return output * 100
    }
}
