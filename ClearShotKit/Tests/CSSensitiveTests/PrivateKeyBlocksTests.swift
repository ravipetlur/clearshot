import CSTestSupport
import Testing
@testable import CSSensitive

/// Where a private key's block lies among the lines a screenshot reads as: a header, the key's body and the END line, taken
/// through the soft wraps of a key pasted as one JSON or `.env` string. Pure: the lines are strings, as OCR gives them.
struct PrivateKeyBlocksTests {
    private let header = Fake.privateKeyBegin()
    private let end = Fake.privateKeyEnd()
    private let escape = "\\n"
    private func body(_ line: Int) -> String { Fake.privateKeyBody(64, line: line) }
    private let prose = ["A paragraph of ordinary prose follows the key.", "It has several words in every line."]

    private func blocks(_ lines: [String]) -> [PrivateKeyBlocks.Block] { PrivateKeyBlocks.blocks(in: lines) }
    private func block(_ header: ClosedRange<Int>, _ last: Int) -> PrivateKeyBlocks.Block {
        PrivateKeyBlocks.Block(header: header, last: last)
    }

    // MARK: A key on its own lines

    @Test func aHeaderItsBodyAndItsEndLineAreOneBlock() {
        let lines = ["Here is the key:", header, body(1), body(2), body(3), body(4), end] + prose
        #expect(blocks(lines) == [block(1...1, 6)])
        #expect(blocks(lines)[0].lines == 1...6)
    }

    @Test func bodyLinesWithoutAHeaderAreNoBlock() {
        #expect(blocks([body(1), body(2), body(3), body(4), end]).isEmpty)
        #expect(blocks(["some text", body(1), body(2)] + prose).isEmpty)
    }

    @Test func theBlockStopsAtTheFirstLineThatIsNeitherBodyNorEnd() {
        let lines = [header, body(1), body(2), "a line of prose", body(3), end]
        #expect(blocks(lines) == [block(0...0, 2)])
    }

    @Test func proseBelowTheKeyIsNotSwallowed() {
        let lines = [header, body(1), body(2), end] + prose
        #expect(blocks(lines) == [block(0...0, 3)])
    }

    @Test func aKeyWhoseEndLineIsMissingEndsWithItsBody() {
        #expect(blocks([header, body(1), body(2)] + prose) == [block(0...0, 2)])
        #expect(blocks([header, body(1), body(2)]) == [block(0...0, 2)])
    }

    @Test func aHeaderWithNoBodyIsABlockOfItsOwnLine() {
        #expect(blocks([header] + prose) == [block(0...0, 0)])
        #expect(blocks([header]) == [block(0...0, 0)])
        #expect(blocks([header, Fake.chars(64, from: "0123456789abcdef")]) == [block(0...0, 0)])
    }

    @Test func aKeyWithoutDashesIsFoundToo() {
        let lines = [Fake.privateKeyBegin("OPENSSH", dashes: ""), body(1), body(2), Fake.privateKeyEnd("OPENSSH", dashes: "")]
        #expect(blocks(lines) == [block(0...0, 3)])
    }

    @Test func eachKeyIsABlockOfItsOwn() {
        let lines = [header, body(1), end, "and another", Fake.privateKeyBegin("EC"), body(2), body(3), Fake.privateKeyEnd("EC")]
        #expect(blocks(lines) == [block(0...0, 2), block(4...4, 7)])
    }

    @Test func aHeaderInsideAProseSentenceIsNotAHeader() {
        let lines = ["how to begin private key rotation", body(1), body(2)]
        #expect(blocks(lines).isEmpty)
    }

    @Test func aBlockStartsAtTheHeaderEvenWhenTheLineHasOtherWordsBeforeIt() {
        let lines = ["private_key = " + header, body(1), body(2), end]
        #expect(blocks(lines) == [block(0...0, 3)])
    }

    // MARK: A key written on one line, wrapped by the screen

    /// `"private_key": "-----BEGIN PRIVATE KEY-----\nMIIE…\n…-----END PRIVATE KEY-----\n",`
    private var jsonKey: String {
        let lines = (1...6).map { body($0) }
        return "\"private_key\": \"" + header + escape + lines.joined(separator: escape) + escape + end + escape + "\","
    }

    @Test(arguments: Array(24...120))
    func aKeyWrappedAtAnyWidthIsOneBlockToItsLastLine(width: Int) throws {
        let key = TextWrapping.words(of: jsonKey, width: width)
        let lines = key + prose
        let first = try #require(key.firstIndex { $0.contains("BEGIN") })
        let lastOfHeader = try #require(key.firstIndex { $0.contains("KEY-----") })
        #expect(blocks(lines) == [block(first...lastOfHeader, key.count - 1)], "width \(width): \(key)")
    }

    @Test(arguments: Array(24...120))
    func aKeyWrappedAtAnyWidthLeavesTheProseBelowAlone(width: Int) {
        let key = TextWrapping.words(of: jsonKey, width: width)
        let result = blocks(key + prose + key + prose)
        #expect(result.count == 2, "width \(width)")
        #expect(result.allSatisfy { $0.last < key.count + prose.count + key.count }, "width \(width)")
        #expect(result.first.map { $0.last == key.count - 1 } == true, "width \(width)")
    }

    @Test func aLineEndingInABackslashContinuesOntoTheNextLine() {
        // The backslash and the n of an escape on two lines, in the header's line, a body line and before the END marker.
        let lines = ["\"private_key\": \"" + header + "\\",
                     "n" + body(1) + "\\",
                     "n" + body(2) + "\\",
                     "n" + end + escape + "\","]
        #expect(blocks(lines) == [block(0...0, 3)])
    }

    @Test func aBackslashAtTheEndOfALineDoesNotCarryTheBlockOnPastProse() {
        let lines = [header, body(1) + "\\", "Ordinary words follow here."]
        #expect(blocks(lines) == [block(0...0, 1)])
    }

    @Test func aBodyLineMayHaveEscapesQuotesAndCommas() {
        // A key written as a JSON array of lines, and one with an empty line between two escapes.
        #expect(blocks([header, "\"" + body(1) + "\",", "\"" + body(2) + "\",", "\"" + end + "\""]) == [block(0...0, 3)])
        #expect(blocks([header, "'" + body(1) + "'", body(2) + escape + escape + body(3), end]) == [block(0...0, 3)])
        #expect(blocks([header, escape + body(1) + escape, body(2) + escape, end + escape]) == [block(0...0, 3)])
        // As a line of hex digits, with escapes between short pieces, still not a body line.
        #expect(blocks([header, Fake.chars(40, from: "0123456789abcdef") + escape + Fake.chars(40, from: "0123456789abcdef")])
                == [block(0...0, 0)])
    }

    // MARK: What OCR gets wrong

    @Test func aBackslashReadAsABarIsStillTheStartOfAnEscape() {
        // Vision reads a rendered backslash as "|" about as often as it reads it.
        let lines = ["\"" + header + "|n" + Fake.privateKeyBody(30, line: 1), body(2) + "|n" + body(3), body(4) + "|",
                     "n" + Fake.privateKeyBody(20, line: 5) + "|n", Fake.privateKeyBody(10, line: 6) + "|n" + end + "|n\","]
        #expect(blocks(lines) == [block(0...0, 4)])
        #expect(blocks([header, body(1) + "|n" + body(2), end + "|n"]) == [block(0...0, 2)])
        // Bars through a line that are not escapes are not key material (a mistake or two is one; see below).
        #expect(blocks([header, body(1) + "|" + body(2) + "|" + body(3) + "|" + body(4), end]) == [block(0...0, 0)])
    }

    @Test func aBodyLineReadWithAMistakeOrTwoIsStillABodyLine() {
        // A character Vision took for a symbol ("†" for a letter), or a space it put inside a long run of the key.
        func mistaken(_ line: String, _ characters: String) -> String {
            var read = Array(line)
            for (offset, character) in characters.enumerated() { read[5 + 7 * offset] = character }
            return String(read)
        }
        let one = mistaken(body(2), "†"), two = mistaken(body(2), "†\u{0410}")
        #expect(blocks([header, body(1), one, body(3), end]) == [block(0...0, 4)])
        #expect(blocks([header, body(1), two, body(3), end]) == [block(0...0, 4)])
        let spaced = String(body(2).prefix(30)) + " " + String(body(2).dropFirst(30))
        #expect(blocks([header, body(1), spaced, body(3), end]) == [block(0...0, 4)])
        // Three mistakes in a line, two spaces in it, or a space with too little on one side, make it an ordinary line.
        #expect(blocks([header, body(1), mistaken(body(2), "†§¶"), body(3), end]) == [block(0...0, 1)])
        #expect(blocks([header, body(1), String(body(2).prefix(20)) + " " + String(body(2).dropFirst(20).prefix(20)) + " " + String(body(2).suffix(20)), end])
                == [block(0...0, 1)])
        #expect(blocks([header, body(1), "to " + body(2), end]) == [block(0...0, 1)])
        // A line of words, or a short one with a mistake in it, never is.
        #expect(blocks([header, body(1), "this is a line of ordinary words", end]) == [block(0...0, 1)])
        #expect(blocks([header, body(1), "Ab3dE5†G7hJ9kL1", body(3)]) == [block(0...0, 1)])
    }

    @Test func twoLongWordsOfPlainLettersAreNotKeyMaterial() {
        // Under a key whose END marker isn't read, ordinary words that are each 8 characters or more, with a space between them,
        // would pass for a body line with a space in it. A line with a digit, a "+" or a "/", or a capital inside a word, is key.
        for prose in ["Additional information", "Further reading", "internationalization guidelines", "Documentation overview here",
                      "approximately everything", "Information.", "internationalization."] {
            #expect(blocks([header, body(1), prose]) == [block(0...0, 1)], "\(prose)")
            #expect(blocks([header, body(1), prose, "Further reading"]) == [block(0...0, 1)], "\(prose)")
        }
        // A wrapped body with a stray character, or a space, still is: it has key's capitals and digits in it.
        let stray = String(body(2).prefix(20)) + "†" + String(body(2).dropFirst(21))
        let spaced = String(body(2).prefix(30)) + " " + String(body(2).dropFirst(30))
        #expect(blocks([header, body(1), stray, "Additional information"]) == [block(0...0, 2)])
        #expect(blocks([header, body(1), spaced, "Further reading"]) == [block(0...0, 2)])
        // A key piece that has only lower case letters and one capital inside a word is a key's too.
        #expect(blocks([header, body(1), "abcdefgh ijkLmnopq", "Further reading"]) == [block(0...0, 2)])
    }

    @Test func anEndLineWithAMistakeBeforeTheMarkerIsStillTheEndLine() {
        let tail = Fake.privateKeyBody(12, line: 3)
        #expect(blocks([header, body(1), tail + "†" + end] + prose) == [block(0...0, 2)])
        #expect(blocks([header, body(1), tail + "†§¶" + end] + prose) == [block(0...0, 1)])
    }

    @Test func aDashRunTheWrapBrokeAfterTheHeaderIsStillTheHeader() {
        #expect(blocks(["\"-----BEGIN RSA PRIVATE KEY--", "---" + escape + body(1), body(2), end]) == [block(0...0, 3)])
        // Only straight after the header: dashes in front of a body line further down make it no body line.
        #expect(blocks([header, body(1), "---" + body(2), end]) == [block(0...0, 1)])
    }

    @Test func anEndLineWithMoreOnItIsStillTheEndLine() {
        // The last of the key is glued to the marker, and the JSON goes on after it.
        let tail = Fake.privateKeyBody(12, line: 3)
        #expect(blocks([header, body(1), tail + escape + end + escape + "\", \"client_email\": \"a@example.com\"}"] + prose)
                == [block(0...0, 2)])
        // Its backslash dropped by OCR, or its closing quote read as letters.
        #expect(blocks([header, body(1), tail + "n" + end + "In\","] + prose) == [block(0...0, 2)])
        // Words before the marker make it a sentence about one.
        #expect(blocks([header, body(1), "see " + end + " for the rest"] + prose) == [block(0...0, 1)])
        #expect(blocks([header, body(1), tail + " " + end] + prose) == [block(0...0, 1)])
    }

    // MARK: Headers and END markers split across lines

    @Test func aHeaderSplitAcrossTwoLinesIsFoundOnTheJoinedPair() {
        let lines = ["-----BEGIN PRIVATE", "KEY-----", body(1), body(2), end]
        #expect(blocks(lines) == [block(0...1, 4)])
    }

    @Test func aHeaderSplitAcrossThreeLinesIsFound() {
        #expect(blocks(["-----BEGIN", "RSA PRIVATE", "KEY-----" + escape + body(1), body(2), end]) == [block(0...2, 4)])
        #expect(blocks(["x = \"-----BEGIN", "RSA", "PRIVATE", "KEY-----" + escape, body(2), end]) == [block(0...3, 5)])
    }

    @Test func aHeaderSplitInsideAWordIsFound() {
        #expect(blocks(["-----BEGIN PRIVATE K", "EY-----", body(1), end]) == [block(0...1, 3)])
        #expect(blocks(["-----BEG", "IN PRIVATE KEY-----", body(1), end]) == [block(0...1, 3)])
        #expect(blocks(["-----B", "EGIN PRIVATE KEY-----", body(1), end]) == [block(0...1, 3)])
        #expect(blocks(["-----BEGI", "N PRIVATE KEY-----", body(1), end]) == [block(0...1, 3)])
    }

    @Test func aHeaderWhoseDashesAreOnTheLineBeforeTakesThemIn() {
        #expect(blocks(["-----", "BEGIN PRIVATE KEY-----", body(1), end]) == [block(0...1, 3)])
    }

    @Test func aHeaderSplitOnTheFirstLineOfAKeyKeepsItsBody() {
        let lines = ["\"private_key\": \"-----BEGIN PRIVATE", "KEY-----" + escape + body(1) + escape + body(2),
                     body(3) + escape + body(4), end + escape + "\","]
        #expect(blocks(lines) == [block(0...1, 3)])
    }

    @Test func anEndMarkerSplitAcrossTwoLinesEndsTheBlock() {
        #expect(blocks([header, body(1), body(2), "-----END RSA PRIVATE", "KEY-----"] + prose) == [block(0...0, 4)])
        #expect(blocks([header, body(1), body(2), "-----", "END PRIVATE KEY-----"] + prose) == [block(0...0, 4)])
        #expect(blocks([header, body(1), body(2), "-----END", "PRIVATE KEY-----"] + prose) == [block(0...0, 4)])
        #expect(blocks([header, body(1), body(2), "-----END PRIVATE K", "EY-----"] + prose) == [block(0...0, 4)])
    }

    @Test func anEndMarkerSplitAcrossManyLinesEndsTheBlock() {
        #expect(blocks([header, body(1), "-----END", "RSA", "PRIVATE", "KEY-----"] + prose) == [block(0...0, 5)])
    }

    @Test func anEndMarkerAfterEscapedBodyIsSplitToo() {
        let lines = ["\"" + header + escape + body(1) + escape + body(2) + escape + "-----END",
                     "PRIVATE KEY-----" + escape + "\","]
        #expect(blocks(lines) == [block(0...0, 1)])
        let more = [header, body(1) + escape + "-----", "END PRIVATE KEY-----" + escape + "\""]
        #expect(blocks(more + prose) == [block(0...0, 2)])
    }

    @Test func aShortLastLineOfBodyStraightAboveTheEndLineIsPartOfTheKey() {
        // A key's last line is as long as what is left: "Zg==" is the last of the key.
        #expect(blocks([header, body(1), body(2), "Zg==", end] + prose) == [block(0...0, 4)])
        #expect(blocks([header, body(1), "Ab3dE5", "-----END PRIVATE", "KEY-----"] + prose) == [block(0...0, 4)])
        // With no END line below it, a short line is only a short line.
        #expect(blocks([header, body(1), "Zg==", "words follow here"]) == [block(0...0, 1)])
        #expect(blocks([header, body(1), "Zg=="]) == [block(0...0, 1)])
    }

    // MARK: A whole key on one line

    @Test func aKeyWhoseEndIsOnTheHeadersLineIsThatLineAlone() {
        let line = "\"private_key\": \"" + header + escape + body(1) + escape + body(2) + escape + end + escape + "\""
        #expect(blocks([line, body(3), body(4)] + prose) == [block(0...0, 0)])
        #expect(blocks([line] + prose) == [block(0...0, 0)])
    }

    @Test func aSplitHeaderWithItsEndOnTheSecondLineIsThoseTwoLines() {
        let lines = ["x = \"-----BEGIN PRIVATE", "KEY-----" + escape + body(1) + escape + end + escape + "\"", body(2)]
        #expect(blocks(lines) == [block(0...1, 1)])
    }
}
