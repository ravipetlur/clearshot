import Testing
@testable import CSSensitive

/// What holds across the kinds: the filter, the order and the overlap rule, the tolerance for OCR's confusions.
struct SensitiveDetectorTests {
    @Test func anEmptyLineHasNothing() {
        #expect(found("") == [])
        #expect(found("   ") == [])
        #expect(found("just words and 12 numbers") == [])
    }

    // MARK: The kinds filter

    @Test func noKindsFindNothing() {
        #expect(found("jane@example.com 10.0.0.5 4242 4242 4242 4242 \(Fake.github())", []) == [])
    }

    @Test func aKindThatIsOffIsNotReported() {
        let line = "jane@example.com \(Fake.github()) 4242 4242 4242 4242 10.0.0.5"
        // The digits of the card number are a phone number to the system's detector, so contact details are not just the email.
        #expect(found(line, .contact).contains(Found(.contact, "jane@example.com")))
        #expect(found(line, .contact).allSatisfy { $0.kind == .contact })
        #expect(found(line, .keysAndTokens).map(\.kind) == [.keyOrToken])
        #expect(found(line, .cards).map(\.kind) == [.card])
        #expect(found(line, .ipAddresses).map(\.kind) == [.ipAddress])
        #expect(found(line, [.keysAndTokens, .ipAddresses]).map(\.kind) == [.keyOrToken, .ipAddress])
    }

    @Test func aTokenIsNotReportedWhenOnlyContactDetailsAreAsked() {
        #expect(found("deploy with \(Fake.github())", .contact) == [])
        #expect(found("deploy with \(Fake.github())", .keysAndTokens).count == 1)
    }

    @Test func aKindThatIsOffDoesNotHideTheOnesThatAreOn() {
        // Without keys and tokens on, the password's value is not a secret, but the address in it is still an address.
        #expect(found("password: jane@example.com", .contact) == [Found(.contact, "jane@example.com")])
    }

    // MARK: Order and ranges

    @Test func findingsAreSortedByPositionWhateverTheKind() {
        let token = Fake.github()
        let line = "\(token) 10.0.0.5 jane@example.com 4242 4242 4242 4242"
        #expect(found(line) == [
            Found(.keyOrToken, token),
            Found(.ipAddress, "10.0.0.5"),
            Found(.contact, "jane@example.com"),
            Found(.card, "4242 4242 4242 4242"),
        ])
    }

    @Test func theRangesIndexTheLineTheyWereFoundIn() {
        let line = "🙂 ‹é› jane@example.com, 日本語 10.0.0.5"
        let findings = SensitiveDetector.findings(in: line, kinds: .all)
        #expect(findings.map { String(line[$0.range]) } == ["jane@example.com", "10.0.0.5"])
        // They don't overlap, and run in order.
        for (earlier, later) in zip(findings, findings.dropFirst()) {
            #expect(earlier.range.upperBound <= later.range.lowerBound)
        }
    }

    // MARK: Overlaps

    @Test func anEmailInsideAPasswordLineIsOneKeyFindingOverTheValue() {
        #expect(found("password: jane@example.com") == [Found(.keyOrToken, "jane@example.com")])
    }

    @Test func aPasswordLineBesideAnEmailKeepsBothApart() {
        #expect(found("jane@example.com password: hunter2") == [
            Found(.contact, "jane@example.com"),
            Found(.keyOrToken, "hunter2"),
        ])
    }

    @Test func theMoreSpecificKindWinsWhereOneSpanHoldsAnother() {
        #expect(found("token=10.0.0.5") == [Found(.keyOrToken, "10.0.0.5")])
        // The labelled value runs to the space, past the address in it.
        #expect(found("use the password: 10.0.0.5:8080 ok") == [Found(.keyOrToken, "10.0.0.5:8080")])
    }

    @Test func spansThatOverlapPartlyMergeIntoTheirUnion() {
        // The password's value is `4242`, the first group; the card is the four groups. One finding covers them all.
        #expect(found("use the password: 4242 4242 4242 4242") == [Found(.keyOrToken, "4242 4242 4242 4242")])
        // At the start of a line the value is the rest of the line, which is the card number: the same span.
        #expect(found("password: 4242 4242 4242 4242") == [Found(.keyOrToken, "4242 4242 4242 4242")])
    }

    @Test func aCardNumberTheDataDetectorAlsoReadsAsAPhoneNumberIsOneCard() {
        #expect(found("4242 4242 4242 4242") == [Found(.card, "4242 4242 4242 4242")])
        #expect(found("4242424242424242") == [Found(.card, "4242424242424242")])
    }

    @Test func aTokenWithADigitRunInItIsOneKeyFinding() {
        let token = "gh" + "p_" + "1234567890" + Fake.chars(26)
        #expect(found("use \(token) now") == [Found(.keyOrToken, token)])
    }

    // MARK: Character boundaries

    /// A span that ends inside a Character (a letter and the accent that follows it, a digit and its emoji selector) is
    /// taken to the Character's edge, on both ends, so a range is always a range of whole Characters.
    private func assertWholeCharacters(_ line: String, _ kinds: SensitiveKinds, _ expected: Found, sourceLocation: SourceLocation = #_sourceLocation) {
        let findings = SensitiveDetector.findings(in: line, kinds: kinds)
        #expect(findings.map { Found($0.kind, String(line[$0.range])) } == [expected], sourceLocation: sourceLocation)
        for finding in findings {
            for bound in [finding.range.lowerBound, finding.range.upperBound] {
                #expect(bound == line.endIndex || line.indices.contains(bound), "an edge inside a Character", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func anIPv6AddressFollowedByAnAccentTakesTheWholeCharacter() {
        assertWholeCharacters("fe80::1\u{301}", .ipAddresses, Found(.ipAddress, "fe80::1\u{301}"))
        assertWholeCharacters("at fe80::1\u{301} up", .ipAddresses, Found(.ipAddress, "fe80::1\u{301}"))
    }

    @Test func aCardNumberFollowedByAnEmojiSelectorTakesTheWholeCharacter() {
        let card = "4242 4242 4242 4242"
        assertWholeCharacters(card + "\u{FE0F}", .cards, Found(.card, card + "\u{FE0F}"))
        assertWholeCharacters("card " + card + "\u{FE0F} ok", .cards, Found(.card, card + "\u{FE0F}"))
    }

    @Test func aKeyFileNameFollowedByAnAccentTakesTheWholeCharacter() {
        assertWholeCharacters("key.pem\u{301}", .keysAndTokens, Found(.keyOrToken, "key.pem\u{301}"))
    }

    /// The colon and the accent after it are one Character, and the password the pattern finds starts at the accent.
    @Test func aSpanThatStartsInsideACharacterStartsAtItsEdge() throws {
        let line = "x://a:\u{301}bc@host.example.com"
        let passwordStart = try #require(line.unicodeScalars.firstIndex(of: "\u{301}"))
        #expect(!line.indices.contains(passwordStart), "the accent starts no Character of its own")
        let findings = SensitiveDetector.findings(in: line, kinds: .keysAndTokens)
        #expect(findings.map { String(line[$0.range]) } == [":\u{301}bc"])
        for finding in findings {
            #expect(line.indices.contains(finding.range.lowerBound))
            #expect(finding.range.upperBound == line.endIndex || line.indices.contains(finding.range.upperBound))
        }
        #expect(masked(line, .keysAndTokens) == "x://a▓@host.example.com")
    }

    @Test func spansThatMeetInsideACharacterBecomeOne() {
        // Two spans that touch inside one Character both take it, so they overlap there and merge.
        let line = "x\u{301}y"
        let start = line.startIndex
        let inside = line.unicodeScalars.index(after: line.unicodeScalars.startIndex)
        let first = TextFinding(kind: .contact, range: start..<inside)
        let second = TextFinding(kind: .ipAddress, range: inside..<line.endIndex)
        let aligned = [first, second].map { SensitiveDetector.alignedToCharacters($0, in: line) }
        #expect(SensitiveDetector.merged(aligned).map(\.kind) == [.ipAddress])
        #expect(SensitiveDetector.merged(aligned).map { String(line[$0.range]) } == [line])
    }

    // MARK: Long lines

    /// Nothing may take longer than a second on a line of 20 000 characters, whatever it holds; the patterns read a line in
    /// time proportional to its length. Each of these made one of them quadratic.
    static let longLineUnits: [String] = {
        let units: [String] = [
            "a", "-", "—", "1 ", "a.", "a@", "1.", "a:", "1-", "ab12", "x://a:", "token=", "id_rsa.", "eyJ", "sk-", "Bearer ",
            ":a@b.test", "a@b.test|", "a=@b.test", "x://a:b@c.test", "a@b.c:d@e.ff", "x://a:b@", "passphrase=", "&", "'", "@a.", "://",
            "password: ", "a=&b=", "aB3dE5fG7hJ9kL1m\\n", "202-555-0143...", "12 13 ", "a@b.test?c=", "a=b&c/d|e?f@", "a@b.test@",
            "**password:** x ", "password1_a_b_c_d_e_f_g=", "pwd: ab ", "x password: \"a\"b ", "token=\"a\",",
            // A URL password may hold `/`: it runs to the last `@` of the run of text, which is read once.
            "x://a:b/", "x://a:b/c@", "x://a:/@", "x://a:/@/@", "x://:/", "x://a:/b/c/d", "x://a:b/c@d.test/", "/@", "@/", ":/@",
            "x://a:b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u/v/w/x/y/z@", "x://a:@/@/@/@/@/@/@/@/@/@/@/@/@/@/",
            // Card labels, card groupings and the long chains of digit groups they work on.
            "1 card ", "1 card:", "1 card no. ", "1 cc# ", "card - 1 ", "card 1 ", "visa 4222 ", "4222 ", "4222-", "4222 2222 2222 3433 ",
            "card 4222222222223433 ", "card: 4222 2222 2222 3433 / ", "3782 822463 10006 ", "1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 ",
            "cc 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 ", "1 card no.:#-. ", "1 credit  ", "1 card_number\": \"", "1 cardNumber ", "1 card=", "1 card (\"'", "1 credit_credit_card ", "1 card_card_card_", "1 CardCardCard", "1 userCardNumber:", "1 cc-no-no-no ", "1 visa_number_number ", "1 card = = = = = ", "1 aCard1 ", "1 card\t\t", "1 card\u{00A0}\u{00A0}", "1 card\t:\u{00A0}", "1 credit\t\u{00A0}card ", "1 card=\t\t\t", "4222\u{00A0}", "1\u{00A0}", "card: 4222\u{00A0}2222\u{00A0}2222\u{00A0}3433 ", "4222\u{00A0}-\u{00A0}", "1\u{00A0}2\u{00A0}3\u{00A0}4\u{00A0}5\u{00A0}",
        ]
        let keys: [String] = [
            parts("-----", "BEGIN PRIVATE", " KEY----- "), parts("-----", "BEGIN PRIVATE", " KEY----- aB3dE5fG7hJ9kL1mN2pQ4rS6 "),
            parts("-----", "END PRIVATE", " KEY----- "),
        ]
        let padded: [String] = [
            "202-555-0143" + String(repeating: ".", count: 60) + " ", String(repeating: "a", count: 200) + "@b.test ",
            String(repeating: " ", count: 100) + "pwd=x ", "# " + String(repeating: " ", count: 60),
            "1 card" + String(repeating: " ", count: 100) + "x ", "1 card" + String(repeating: " :", count: 60) + " x ",
            "card" + String(repeating: " ", count: 60) + "4222 ", "1 card" + String(repeating: "_", count: 100) + "x ", "1 card" + String(repeating: "-", count: 100) + "x ",
            "1 card" + String(repeating: " _", count: 60) + "x ", "1 card" + String(repeating: "=", count: 100) + "x ", "1 card" + String(repeating: "\"", count: 100) + "4222 ",
            "1 credit" + String(repeating: " ", count: 100) + "x ", "1 card" + String(repeating: "\t", count: 100) + "x ",
            "1 card" + String(repeating: "\u{00A0}", count: 100) + "x ", "1 card" + String(repeating: "\t\u{00A0}", count: 60) + "4222 ", "1 card" + String(repeating: " number", count: 30) + " ",
        ]
        return units + keys + padded
    }()

    @Test(arguments: longLineUnits)
    func aVeryLongLineIsReadInLinearTime(unit: String) {
        let line = String(repeating: unit, count: 20_000 / unit.count)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = SensitiveDetector.findings(in: line, kinds: .all) }
        #expect(elapsed < .seconds(1), "\(unit.debugDescription) x \(line.count) took \(elapsed)")
    }

    // MARK: The merge itself

    /// Findings over `text` for the character offsets given, in the order given.
    private func spans(_ text: String, _ spans: [(SensitiveKind, Range<Int>)]) -> [TextFinding] {
        spans.map { kind, offsets in
            let start = text.index(text.startIndex, offsetBy: offsets.lowerBound)
            let end = text.index(text.startIndex, offsetBy: offsets.upperBound)
            return TextFinding(kind: kind, range: start..<end)
        }
    }

    @Test func spansThatOnlyTouchAreNotMerged() {
        let text = String(repeating: "x", count: 20)
        let input = spans(text, [(.contact, 5..<10), (.ipAddress, 0..<5)])
        let merged = SensitiveDetector.merged(input)
        #expect(merged == spans(text, [(.ipAddress, 0..<5), (.contact, 5..<10)]))
    }

    @Test func spansThatShareACharacterAreMergedIntoTheirUnionAndTheMostSpecificKind() {
        let text = String(repeating: "x", count: 20)
        let merged = SensitiveDetector.merged(spans(text, [(.contact, 4..<12), (.card, 0..<5), (.keyOrToken, 11..<15)]))
        #expect(merged == spans(text, [(.keyOrToken, 0..<15)]))
    }

    @Test func aSpanInsideAnotherTakesTheKindOfTheMoreSpecific() {
        let text = String(repeating: "x", count: 20)
        #expect(SensitiveDetector.merged(spans(text, [(.keyOrToken, 2..<12), (.contact, 4..<8)])) == spans(text, [(.keyOrToken, 2..<12)]))
        #expect(SensitiveDetector.merged(spans(text, [(.contact, 2..<12), (.card, 4..<8)])) == spans(text, [(.card, 2..<12)]))
        #expect(SensitiveDetector.merged(spans(text, [(.ipAddress, 2..<12), (.card, 4..<8)])) == spans(text, [(.card, 2..<12)]))
        #expect(SensitiveDetector.merged(spans(text, [(.contact, 2..<12), (.ipAddress, 4..<8)])) == spans(text, [(.ipAddress, 2..<12)]))
    }

    @Test func twoSpansOverTheSameTextAreOneOfTheMoreSpecificKind() {
        let text = String(repeating: "x", count: 20)
        #expect(SensitiveDetector.merged(spans(text, [(.contact, 3..<9), (.card, 3..<9)])) == spans(text, [(.card, 3..<9)]))
    }

    @Test func nothingMergesToNothing() {
        #expect(SensitiveDetector.merged([]) == [])
    }

    // MARK: OCR noise

    /// The body of a GitHub token is any letter or digit, so an `O` read for a `0`, an `l` for a `1` or an `I` for an `l` is
    /// still the token, and the whole token is found.
    @Test func aTokenWithTheCommonOCRConfusionsInItsBodyIsStillFound() {
        let clean = Fake.github()
        #expect(clean.contains("0") && clean.contains("1"))
        let noisy = [
            clean.replacingFirst("0", with: "O"),
            clean.replacingFirst("1", with: "l"),
            clean.replacingFirst("1", with: "I"),
            clean.replacingFirst("0", with: "O").replacingFirst("1", with: "l"),
        ]
        for token in noisy {
            #expect(token != clean)
            #expect(found("token \(token) end") == [Found(.keyOrToken, token)])
        }
    }

    @Test func anAWSKeyWithAnOForAZeroIsStillFound() {
        let clean = Fake.aws()
        #expect(clean.contains("0"))
        let noisy = clean.replacingFirst("0", with: "O")
        #expect(noisy != clean)
        #expect(found(noisy) == [Found(.keyOrToken, noisy)])
    }
}

extension String {
    /// The string with the first `target` replaced.
    func replacingFirst(_ target: Character, with replacement: Character) -> String {
        guard let index = firstIndex(of: target) else { return self }
        var copy = self
        copy.replaceSubrange(index...index, with: String(replacement))
        return copy
    }
}
