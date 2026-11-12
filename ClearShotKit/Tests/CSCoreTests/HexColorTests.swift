import CoreGraphics
import Testing
@testable import CSCore

struct HexColorTests {
    /// Six hex digits, with or without the hash, read back as upper-case hex; anything else is no colour; a gray colour
    /// converts too.
    @Test func parsesSixDigitHexAndRejectsTheRest() throws {
        let color = try #require(HexColor.cgColor(from: "#1E1E1E"))
        #expect(HexColor.hex(from: color) == "#1E1E1E")
        #expect(HexColor.hex(from: try #require(HexColor.cgColor(from: "2bb5c9"))) == "#2BB5C9")
        #expect(HexColor.cgColor(from: "#12") == nil)
        #expect(HexColor.cgColor(from: "zzzzzz") == nil)
        #expect(HexColor.hex(from: CGColor(gray: 1, alpha: 1)) == "#FFFFFF")
    }
}
