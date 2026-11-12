import Testing
import CSUpdate

struct VersionNumberTests {
    func version(_ text: String) throws -> VersionNumber {
        try #require(VersionNumber(text))
    }

    // MARK: Parsing

    @Test(arguments: [
        ("1.2.3", "1.2.3"), ("v1.2.3", "1.2.3"), ("0.0.0", "0.0.0"), ("0.0.1", "0.0.1"),
        ("10.20.30", "10.20.30"), ("v0.1.0", "0.1.0"), ("1.10.0", "1.10.0"), ("v100.0.7", "100.0.7"),
    ])
    func parsesThreeNumbersWithAnOptionalLeadingV(text: String, printed: String) throws {
        #expect(try version(text).description == printed)
    }

    @Test(arguments: [
        "", "v", "1", "1.2", "v1.2", "1.2.3.4", "v1.2.3.4",
        "1.2.3-beta", "1.2.3-beta.1", "1.2.3+build5", "1.2.3rc1", "1.2.x",
        "01.2.3", "1.02.3", "1.2.03", "00.0.0",
        "1..3", "1.2.", ".1.2", "...", "v.1.2",
        "-1.2.3", "1.-2.3", "1.2.-3", "+1.2.3",
        " 1.2.3", "1.2.3 ", "1.2.3\n", "1. 2.3",
        "V1.2.3", "vv1.2.3", "ver1.2.3", "1,2,3",
        "١.٢.٣",
        "99999999999999999999.0.0",
    ])
    func rejectsAnythingElse(text: String) {
        #expect(VersionNumber(text) == nil)
    }

    // MARK: Comparing

    /// Numerically, not as text, with the major outweighing the minor outweighing the patch; a leading v doesn't change
    /// the value (or its hash).
    @Test(arguments: [
        // (the higher, the lower; equal when they are the same version)
        ("1.10.0", "1.9.9"), ("1.0.10", "1.0.9"), ("10.0.0", "9.99.99"), ("2.0.0", "1.99.99"),
        ("1.2.4", "1.2.3"), ("1.3.0", "1.2.3"), ("2.0.0", "1.2.3"),
        ("2.0.0", "1.9.9"), ("1.2.0", "1.1.99"), ("0.0.1", "0.0.0"),
        ("v1.2.3", "1.2.3"),
    ])
    func comparesNumericallyNotAsText(higher: String, lower: String) throws {
        let (a, b) = (try version(higher), try version(lower))
        if a.description == b.description {
            #expect(a == b)
            #expect(!(a < b) && !(a > b))
            #expect(a.hashValue == b.hashValue)
        } else {
            #expect(a > b)
            #expect(b < a)
            #expect(a != b)
        }
    }

    @Test func sortsAList() throws {
        let shuffled = try ["1.10.0", "1.2.0", "v1.9.9", "0.9.0", "1.2.10", "1.2.9"].map(version)
        #expect(shuffled.sorted().map(\.description) == ["0.9.0", "1.2.0", "1.2.9", "1.2.10", "1.9.9", "1.10.0"])
    }
}
