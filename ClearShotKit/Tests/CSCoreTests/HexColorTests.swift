import CoreGraphics
import Testing
@testable import CSCore

struct HexColorTests {
    @Test func parsesSixDigitHexWithOrWithoutHash() {
        let color = HexColor.cgColor(from: "#1E1E1E")
        #expect(color != nil)
        #expect(HexColor.hex(from: color!) == "#1E1E1E")
        #expect(HexColor.hex(from: HexColor.cgColor(from: "2bb5c9")!) == "#2BB5C9")
    }

    @Test func rejectsMalformedValues() {
        #expect(HexColor.cgColor(from: "#12") == nil)
        #expect(HexColor.cgColor(from: "zzzzzz") == nil)
    }

    @Test func grayColorsConvertToHex() {
        #expect(HexColor.hex(from: CGColor(gray: 1, alpha: 1)) == "#FFFFFF")
    }
}
