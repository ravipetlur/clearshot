import Testing
@testable import CSSensitive

/// What the scanner uses to take a private key's header over its body, to the END line: the body's lines are base64 and
/// nothing else, so they can't be told from a long word on their own, and are never findings without a header.
struct PrivateKeyBlockTests {
    // MARK: Body lines

    @Test(arguments: [64, 70, 16, 100, 20])
    func aLineOfBase64IsABodyLine(count: Int) {
        #expect(SensitiveDetector.isPrivateKeyBodyLine(Fake.privateKeyBody(count)))
    }

    @Test(arguments: ["=", "=="])
    func aLastLineMayEndInPadding(padding: String) {
        #expect(SensitiveDetector.isPrivateKeyBodyLine(Fake.privateKeyBody(30) + padding))
    }

    @Test func aBodyLineNeedsSixteenCharacters() {
        #expect(!SensitiveDetector.isPrivateKeyBodyLine(Fake.privateKeyBody(15)))
        #expect(!SensitiveDetector.isPrivateKeyBodyLine(Fake.privateKeyBody(13) + "=="))
        #expect(SensitiveDetector.isPrivateKeyBodyLine(Fake.privateKeyBody(16)))
    }

    @Test func aHexDigestIsNotABodyLine() {
        let hex = "0123456789abcdef"
        #expect(!SensitiveDetector.isPrivateKeyBodyLine(Fake.chars(40, from: hex)))
        #expect(!SensitiveDetector.isPrivateKeyBodyLine(Fake.chars(64, from: hex)))
        #expect(!SensitiveDetector.isPrivateKeyBodyLine(Fake.chars(32, from: hex.uppercased())))
    }

    @Test(arguments: [
        parts("123e4567-e89b-12d3-a456-", "426614174000"),
        "This is a normal sentence about nothing at all",
        parts("ssh-", "rsa ", "AAAAB3NzaC1yc2EAAAADAQABAAABAQC", "7vbqajDhA0Hr+r/8wvJb5LoSaJZ+Q=="),
        "",
        " ",
        "aB3dE5fG7hJ9kL1m N2pQ4rS6tU8vW0xYz",
        " aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xYz",
        "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xYz ",
        "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8-vW0xYz",
        "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8_vW0xYz",
        "aB3dE5fG7hJ9kL1m=N2pQ4rS6tU8vW0xYz",
        "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xYz===",
        "=aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xYz",
        "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xYé",
    ])
    func otherLinesAreNotBodyLines(line: String) {
        #expect(!SensitiveDetector.isPrivateKeyBodyLine(line))
    }

    // MARK: End lines

    @Test(arguments: ["RSA", "", "OPENSSH", "EC", "ENCRYPTED"])
    func aPrivateKeyEndLineIsOne(kind: String) {
        #expect(SensitiveDetector.isPrivateKeyEndLine(Fake.privateKeyEnd(kind)))
    }

    @Test(arguments: ["-----", "---", "-", "", "——", "–––––"])
    func theDashesOfAnEndLineAreOptional(dashes: String) {
        #expect(SensitiveDetector.isPrivateKeyEndLine(Fake.privateKeyEnd("OPENSSH", dashes: dashes)))
    }

    @Test func aPGPEndLineIsOne() {
        #expect(SensitiveDetector.isPrivateKeyEndLine(parts("-----", "END PGP ", "PRIVATE KEY", " BLOCK-----")))
    }

    @Test(arguments: [
        parts("-----", "END CERTIFICATE-----"),
        parts("-----", "END PUBLIC", " KEY-----"),
        "END",
        parts("the END of the ", "PRIVATE", " KEY"),
        parts("-----", "END RSA ", "PRIVATE", " KEY----- and then some"),
        parts("see -----", "END RSA ", "PRIVATE", " KEY-----"),
        parts("end ", "private", " key"),
        "",
    ])
    func otherLinesAreNotEndLines(line: String) {
        #expect(!SensitiveDetector.isPrivateKeyEndLine(line))
    }

    @Test func aBeginLineIsNotAnEndLine() {
        #expect(!SensitiveDetector.isPrivateKeyEndLine(Fake.privateKeyBegin()))
    }

    // MARK: A key written on one line: lines joined by a literal \n

    /// `\n` as the two characters a JSON or `.env` file has.
    private let escape = "\\n"

    @Test func segmentsJoinedByAnEscapedNewlineAreABodyLine() {
        let a = Fake.privateKeyBody(30, line: 1), b = Fake.privateKeyBody(30, line: 2)
        #expect(SensitiveDetector.isPrivateKeyBodyLine(a + escape + b))
        #expect(SensitiveDetector.isPrivateKeyBodyLine(a + escape + b + escape))
        #expect(SensitiveDetector.isPrivateKeyBodyLine(escape + a + escape + b))
        #expect(SensitiveDetector.isPrivateKeyBodyLine(escape + a + escape))
        #expect(SensitiveDetector.isPrivateKeyBodyLine(a + escape + b + "=="))
        #expect(SensitiveDetector.isPrivateKeyBodyLine(a + "=" + escape + b + "=="))
        #expect(SensitiveDetector.isPrivateKeyBodyLine(a + escape))
    }

    @Test func manyShortSegmentsAddUp() {
        #expect(SensitiveDetector.isPrivateKeyBodyLine(["aB3dE", "5fG7h", "J9kL1", "mN2pQ"].joined(separator: escape)))
        #expect(!SensitiveDetector.isPrivateKeyBodyLine(["aB3dE", "5fG7h"].joined(separator: escape)))
    }

    @Test(arguments: [
        "\\n",
        "\\n\\n",
        "aB3dE5fG7hJ9kL1m\\n\\nN2pQ4rS6tU8vW0xYz",
        "aB3dE5fG7hJ9kL1m\\n N2pQ4rS6tU8vW0xYz",
        "aB3dE5fG7hJ9kL1m\\tN2pQ4rS6tU8vW0xYz",
        "aB3dE5fG7hJ9kL1m\\N2pQ4rS6tU8vW0xYz",
        "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xYz\\",
        "aB3dE5fG7hJ9kL1m==\\n==N2pQ4rS6tU8vW0xYz",
        "aB3dE5fG7hJ9kL1m\\n\\naB3dE5fG7hJ9kL1m",
        "0123456789abcdef\\n0123456789abcdef",
        "aB3dE\\n5fG7h",
    ])
    func otherLinesWithAnEscapedNewlineAreNotBodyLines(line: String) {
        #expect(!SensitiveDetector.isPrivateKeyBodyLine(line))
    }

    /// The last line of a wrapped JSON key has base64 before the END marker, and a quote, a comma or a brace after it.
    @Test(arguments: [
        parts("aB3dE5fG7hJ9kL1m", "\\n", "-----", "END PRIVATE", " KEY-----", "\\n"),
        parts("aB3dE5fG7hJ9kL1m\\nN2pQ4rS6tU8vW0xYz==", "\\n", "-----", "END RSA ", "PRIVATE KEY", "-----\\n\","),
        parts("-----", "END PRIVATE", " KEY-----", "\\n"),
        parts("-----", "END PRIVATE", " KEY-----", "\\n\"}"),
        parts("\\n-----", "END PRIVATE", " KEY-----", "\\n\"]"),
        parts("-----", "END PRIVATE", " KEY-----\\n\","),
    ])
    func theLastLineOfAWrappedKeyIsAnEndLine(line: String) {
        #expect(SensitiveDetector.isPrivateKeyEndLine(line))
    }

    @Test(arguments: [
        parts("see aB3dE5fG7hJ9kL1m\\n-----", "END PRIVATE", " KEY-----"),
        parts("aB3dE5fG7hJ9kL1m -----", "END PRIVATE", " KEY-----"),
        parts("aB3d E5fG\\n-----", "END PRIVATE", " KEY-----"),
        parts("-----", "END PRIVATE", " KEY-----\\n and more"),
        parts("-----", "BEGIN PRIVATE", " KEY-----\\n"),
    ])
    func otherLinesAreNotEndLinesForAWrappedKey(line: String) {
        #expect(!SensitiveDetector.isPrivateKeyEndLine(line))
    }
}
