import Testing
@testable import CSCore

/// WCAG 2's ratio and APCA's Lc against published reference pairs.
struct ColorContrastTests {
    private let black = TestColor(0, 0, 0)
    private let white = TestColor(255, 255, 255)

    private func close(_ value: Double, _ expected: Double, within tolerance: Double = 0.01) -> Bool {
        abs(value - expected) <= tolerance
    }

    @Test func relativeLuminanceRunsFromBlackToWhite() {
        #expect(ColorContrast.relativeLuminance(of: black) == 0)
        #expect(close(ColorContrast.relativeLuminance(of: white), 1, within: 1e-9))
        #expect(close(ColorContrast.relativeLuminance(of: TestColor(255, 0, 0)), 0.2126, within: 1e-9))
    }

    @Test func wcagRatioOfReferencePairs() {
        #expect(close(ColorContrast.wcagRatio(black, white), 21, within: 1e-9))
        #expect(close(ColorContrast.wcagRatio(white, white), 1, within: 1e-9))
        // #777 on white: just under AA's 4.5.
        #expect(close(ColorContrast.wcagRatio(TestColor(0x77, 0x77, 0x77), white), 4.48))
        // #767676 is the lightest gray that passes AA on white.
        #expect(close(ColorContrast.wcagRatio(TestColor(0x76, 0x76, 0x76), white), 4.54))
        // Pure red on white.
        #expect(close(ColorContrast.wcagRatio(TestColor(255, 0, 0), white), 4.0))
    }

    @Test func wcagRatioIsSymmetric() {
        let gray = TestColor(0x77, 0x77, 0x77)
        #expect(ColorContrast.wcagRatio(gray, white) == ColorContrast.wcagRatio(white, gray))
    }

    /// The values APCA-W3 0.0.98G-4g's own calculator gives.
    @Test func apcaOfReferencePairs() {
        #expect(close(ColorContrast.apcaContrast(text: black, background: white), 106.04))
        #expect(close(ColorContrast.apcaContrast(text: white, background: black), -107.88))
        #expect(close(ColorContrast.apcaContrast(text: TestColor(0x88, 0x88, 0x88), background: white), 63.06))
        #expect(close(ColorContrast.apcaContrast(text: white, background: TestColor(0x88, 0x88, 0x88)), -68.54))
        #expect(close(ColorContrast.apcaContrast(text: TestColor(0x11, 0x22, 0x33), background: TestColor(0xDD, 0xEE, 0xFF)), 91.67))
    }

    @Test func apcaIsZeroForColorsTooCloseToMatter() {
        #expect(ColorContrast.apcaContrast(text: white, background: white) == 0)
        #expect(ColorContrast.apcaContrast(text: TestColor(0xF0, 0xF0, 0xF0), background: white) == 0)
        #expect(close(ColorContrast.apcaContrast(text: TestColor(0xEE, 0xEE, 0xEE), background: white), 7.57))
    }
}
