import Testing
@testable import CSCore

/// An sRGB color for the tests, from bytes.
struct TestColor: SRGBColor {
    var red: Double, green: Double, blue: Double

    init(_ red: Int, _ green: Int, _ blue: Int) {
        self.red = Double(red) / 255
        self.green = Double(green) / 255
        self.blue = Double(blue) / 255
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

struct ColorFormatTests {
    private let dodgerBlue = TestColor(30, 144, 255)

    @Test func writesEachFormat() {
        #expect(ColorFormat.hex.string(for: dodgerBlue) == "#1E90FF")
        #expect(ColorFormat.hexWithoutHash.string(for: dodgerBlue) == "1E90FF")
        #expect(ColorFormat.rgb.string(for: dodgerBlue) == "rgb(30, 144, 255)")
        #expect(ColorFormat.hsl.string(for: dodgerBlue) == "hsl(210, 100%, 56%)")
        #expect(ColorFormat.oklch.string(for: dodgerBlue) == "oklch(65.2% 0.19 253.2)")
    }

    /// CSS Color 4's own conversions of the primaries.
    @Test func oklchMatchesTheReferenceValues() {
        #expect(ColorFormat.oklch.string(for: TestColor(255, 0, 0)) == "oklch(62.8% 0.258 29.2)")
        #expect(ColorFormat.oklch.string(for: TestColor(0, 255, 0)) == "oklch(86.6% 0.295 142.5)")
        #expect(ColorFormat.oklch.string(for: TestColor(0, 0, 255)) == "oklch(45.2% 0.313 264.1)")
    }

    @Test func graysHaveNoHue() {
        #expect(ColorFormat.oklch.string(for: TestColor(255, 255, 255)) == "oklch(100% 0 0)")
        #expect(ColorFormat.oklch.string(for: TestColor(0, 0, 0)) == "oklch(0% 0 0)")
        #expect(ColorFormat.oklch.string(for: TestColor(119, 119, 119)) == "oklch(56.9% 0 0)")
        #expect(ColorFormat.hsl.string(for: TestColor(119, 119, 119)) == "hsl(0, 0%, 47%)")
    }

    @Test func hslCoversEveryHueSector() {
        #expect(ColorFormat.hsl.string(for: TestColor(255, 0, 0)) == "hsl(0, 100%, 50%)")
        #expect(ColorFormat.hsl.string(for: TestColor(255, 255, 0)) == "hsl(60, 100%, 50%)")
        #expect(ColorFormat.hsl.string(for: TestColor(0, 255, 0)) == "hsl(120, 100%, 50%)")
        #expect(ColorFormat.hsl.string(for: TestColor(0, 255, 255)) == "hsl(180, 100%, 50%)")
        #expect(ColorFormat.hsl.string(for: TestColor(0, 0, 255)) == "hsl(240, 100%, 50%)")
        #expect(ColorFormat.hsl.string(for: TestColor(255, 0, 255)) == "hsl(300, 100%, 50%)")
        // Just short of red, from the other side: rounds to 0, never 360.
        #expect(ColorFormat.hsl.string(for: TestColor(255, 0, 1)) == "hsl(0, 100%, 50%)")
    }

    /// Every format reads the color rounded to whole bytes, so they agree, and out-of-range components are clamped.
    @Test func roundsAndClampsComponents() {
        let color = TestColor(red: 0.5, green: -0.2, blue: 1.4)
        #expect(ColorFormat.hex.string(for: color) == "#8000FF")
        #expect(ColorFormat.rgb.string(for: color) == "rgb(128, 0, 255)")
    }

    @Test func formatsHaveTitlesAndStableRawValues() {
        #expect(ColorFormat.allCases.map(\.title) == ["HEX", "HEX without #", "RGB", "HSL", "OKLCH"])
        #expect(ColorFormat.allCases.map(\.rawValue) == ["hex", "hexWithoutHash", "rgb", "hsl", "oklch"])
    }

    @Test func numbersDropTrailingZeros() {
        #expect(ColorFormat.number(62.80, decimals: 1) == "62.8")
        #expect(ColorFormat.number(100.0, decimals: 1) == "100")
        #expect(ColorFormat.number(0.190, decimals: 3) == "0.19")
        #expect(ColorFormat.number(-0.0001, decimals: 3) == "0")
    }
}
