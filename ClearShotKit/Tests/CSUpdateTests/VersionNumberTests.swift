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

    @Test func exposesItsThreeParts() throws {
        let parsed = try version("v4.5.6")
        #expect(parsed.major == 4)
        #expect(parsed.minor == 5)
        #expect(parsed.patch == 6)
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

    @Test func comparesNumericallyNotAsText() throws {
        #expect(try version("1.10.0") > version("1.9.9"))
        #expect(try version("1.0.10") > version("1.0.9"))
        #expect(try version("10.0.0") > version("9.99.99"))
        #expect(try version("2.0.0") > version("1.99.99"))
        #expect(try version("1.2.3") < version("1.2.4"))
        #expect(try version("1.2.3") < version("1.3.0"))
        #expect(try version("1.2.3") < version("2.0.0"))
    }

    @Test func majorOutweighsMinorOutweighsPatch() throws {
        #expect(try version("2.0.0") > version("1.9.9"))
        #expect(try version("1.2.0") > version("1.1.99"))
        #expect(try version("0.0.1") > version("0.0.0"))
    }

    @Test func aLeadingVDoesNotChangeTheValue() throws {
        #expect(try version("v1.2.3") == version("1.2.3"))
        #expect(try !(version("v1.2.3") < version("1.2.3")))
        #expect(try !(version("v1.2.3") > version("1.2.3")))
        #expect(try version("v1.2.3").hashValue == version("1.2.3").hashValue)
    }

    @Test func sortsAList() throws {
        let shuffled = try ["1.10.0", "1.2.0", "v1.9.9", "0.9.0", "1.2.10", "1.2.9"].map(version)
        #expect(shuffled.sorted().map(\.description) == ["0.9.0", "1.2.0", "1.2.9", "1.2.10", "1.9.9", "1.10.0"])
    }

    @Test func worksAsASetMember() throws {
        let skipped: Set<VersionNumber> = try [version("1.2.0"), version("v1.2.0"), version("1.3.0")]
        #expect(skipped.count == 2)
        #expect(try skipped.contains(version("1.3.0")))
    }
}
