import Testing
@testable import CSSensitive

/// Emails (our own pattern) and phone numbers (the system's data detector, kept at 7 digits or more).
struct ContactDetectionTests {
    // MARK: Email

    @Test func anEmailAddressIsFound() {
        #expect(found("write to jane@example.com today") == [Found(.contact, "jane@example.com")])
    }

    @Test(arguments: [
        "first.last+tag@mail.example.com",
        "jane_doe-99@sub.example.com",
        "J.Doe%list@example.test",
        "x@host.example",
        "josé@example.com",
    ])
    func addressShapesAreFound(address: String) {
        #expect(found("mail \(address) now") == [Found(.contact, address)])
    }

    /// RFC 5322's atext: letters, digits and `!#$%&'*+/=?^_`{|}~-`, with dots. These are found whole.
    @Test(arguments: [
        "o'brien@example.com", "jane!doe@example.com", "{a}@example.test", "x#y$z%w*u@example.com",
        "a`b@example.com", "a-b_c.d@example.com", "~tilde@example.test", "a+b@example.com", "a^b@example.com",
    ])
    func anAddressWithAnyCharacterOfAnAtomIsFoundWhole(address: String) {
        #expect(found("mail \(address) now") == [Found(.contact, address)])
        #expect(masked("mail \(address) now") == "mail ▓ now")
    }

    /// `? & = / |` are atext too, and a local part may hold them anywhere: a mailing list's bounce address, a forwarder's
    /// rewritten one, `tom&jerry@`. Each `@` reads its local part back to a space, another `@` or a character that isn't
    /// atext. (Round 2 found these whole.)
    @Test(arguments: [
        "a+b=c@example.test", "a/b@example.com", "a?b^c|d~e@example.com", "x#y$z%w&v*u@example.com",
        "tom&jerry@example.com", "sales/support@example.com", "a=b@example.com",
        "list-bounces+jane=example.org@lists.example.com", "SRS0=HHH=TT=example.org=jane@forwarder.example.com",
    ])
    func anAddressWithTheCharactersThatPartAChainInItIsFoundWhole(address: String) {
        #expect(found("mail \(address) now") == [Found(.contact, address)])
        #expect(masked("mail \(address) now") == "mail ▓ now")
    }

    @Test func aBounceAddressInAHeaderIsFoundWhole() {
        #expect(masked("Return-Path: <list-bounces+jane=example.org@lists.example.com>", .contact) == "Return-Path: <▓>")
        #expect(masked("From: SRS0=HHH=TT=example.org=jane@forwarder.example.com", .contact) == "From: ▓")
    }

    @Test func aLocalPartLongerThanTheStandardAllowsIsFoundWhole() {
        let address = String(repeating: "a", count: 140) + "@example.com"
        #expect(found("mail \(address) now", .contact) == [Found(.contact, address)])
    }

    /// A label glued to an address is read as part of its local part: more than the address is masked, none of it is left.
    @Test func aLabelGluedToAnAddressIsMaskedWithIt() {
        #expect(found("mail name=jane@example.com now", .contact) == [Found(.contact, "name=jane@example.com")])
        #expect(found("//git@github.test") == [Found(.contact, "git@github.test")])
    }

    // MARK: Addresses written one after another (round 1 found them all)

    /// Each address is found from its own `@`, back to the `@` before it, so the masks of a chain overlap and join: every
    /// address is masked whole (and what parts them with it).
    @Test(arguments: [
        ("mailto:jane@example.com?cc=john@example.com", ["jane@example.com", "john@example.com"]),
        ("mailto:jane@example.com?cc=john@example.com&bcc=ann@example.com", ["jane@example.com", "john@example.com", "ann@example.com"]),
        ("https://example.com/share?from=jane@example.com&to=john@example.com", ["jane@example.com", "john@example.com"]),
        ("?from=a@x.example&to=b@example.com", ["a@x.example", "b@example.com"]),
        ("a@x.example|b@example.com", ["a@x.example", "b@example.com"]),
        ("a@x.example&b@example.com", ["a@x.example", "b@example.com"]),
        ("a@x.example/b@example.com", ["a@x.example", "b@example.com"]),
        ("jane@example.com=john@example.com", ["jane@example.com", "john@example.com"]),
        ("jane@example.com?john@example.com", ["jane@example.com", "john@example.com"]),
        ("a@x.example|b@x.example|c@x.example", ["a@x.example", "b@x.example", "c@x.example"]),
        ("a@x.example?cc=b@x.example&bcc=c@x.example", ["a@x.example", "b@x.example", "c@x.example"]),
    ])
    func addressesWrittenOneAfterAnotherAreAllMaskedWhole(line: String, addresses: [String]) {
        for address in addresses {
            #expect(readable(address, in: line, .contact) == "", "\(address): \(masked(line, .contact))")
            #expect(readable(address, in: line) == "", "\(address): \(masked(line))")
        }
    }

    @Test func addressesPartedByCommasAndSemicolonsAreMaskedApart() {
        #expect(masked("jane@example.com,john@example.com;ann@example.com", .contact) == "▓,▓;▓")
    }

    // MARK: An address after a port (round 1 found it)

    /// What follows a port reads as a URL password too (`3000?email=jane`), and a password never hides an address: the
    /// address is masked whole with contact details alone and with every kind.
    @Test(arguments: [
        "http://localhost:3000?email=jane@example.com",
        "https://h.example.com:8443?u=jane@example.com",
        "https://example.com:8443#contact=jane@example.com",
        "http://localhost:3000?next=/a&email=jane@example.com",
    ])
    func anAddressAfterAPortIsMaskedWhole(line: String) {
        #expect(readable("jane@example.com", in: line, .contact) == "", "\(masked(line, .contact))")
        #expect(readable("jane@example.com", in: line) == "", "\(masked(line))")
    }

    // MARK: Accents, internationalised domains and underscores

    @Test(arguments: [
        "jose\u{301}@example.com", "jose\u{301}.garcia@example.com", "jane@exa\u{301}mple.com", "jane@example.co\u{301}m",
        "jane@xn--bcher-kva.example", "jane@example.xn--p1ai", "jane@my_host.example.com", "jane@a-b.example.com", "jane@bücher.example",
        "jane@例え.example", "jane@пример.test",
    ])
    func accentedAndInternationalisedAddressesAreFoundWhole(address: String) {
        #expect(masked("mail \(address) now", .contact) == "mail ▓ now")
    }

    /// A quote or the slashes of a URL before an address are not part of it.
    @Test func quotesAndSlashesBeforeAnAddressAreNotPartOfIt() {
        #expect(found("'jane@example.com'") == [Found(.contact, "jane@example.com")])
        #expect(found("ssh://git@github.test/org/repo") == [Found(.contact, "git@github.test")])
        #expect(found("`jane@example.com`") == [Found(.contact, "jane@example.com")])
    }

    @Test(arguments: ["jane@example.com.", "<jane@example.com>", "(jane@example.com)", "\"jane@example.com\"", "jane@example.com,", "mailto:jane@example.com"])
    func punctuationAroundAnAddressIsNotPartOfIt(text: String) {
        #expect(foundText(text) == ["jane@example.com"])
    }

    @Test func everyAddressOnALineIsFound() {
        #expect(foundText("to a@example.com, cc b@example.test") == ["a@example.com", "b@example.test"])
    }

    @Test(arguments: [
        "jane@example",
        "jane@example.c",
        "@example.com",
        "jane at example.com",
        "jane@.com",
        "jane@-example.com1",
        "user@localhost",
        "no address here",
    ])
    func textThatIsNotAnAddressIsNotFound(text: String) {
        #expect(found(text, .contact) == [])
    }

    @Test func anAddressAfterAnEmojiIsFoundAtTheRightPlace() {
        let line = "🙂👍🏽 mail jane@example.com 🙂"
        let findings = SensitiveDetector.findings(in: line, kinds: .contact)
        #expect(findings.map { String(line[$0.range]) } == ["jane@example.com"])
    }

    // MARK: Phone

    @Test(arguments: [
        "+1 202 555 0143",
        "(202) 555-0143",
        "202-555-0143",
        "+1 (202) 555-0143",
        "555-0100",
        "+44 20 7946 0958",
    ])
    func aPhoneNumberIsFound(number: String) {
        #expect(found("call \(number) now") == [Found(.contact, number)])
    }

    @Test func aNumberAtTheEndOfALineKeepsNoTrailingSpace() {
        #expect(found("Phone: 202-555-0143 ") == [Found(.contact, "202-555-0143")])
    }

    @Test(arguments: [
        "2026-10-09",
        "10/09/2026",
        "12 Oct 2026",
        "10:45:12",
        "08:30 - 09:45",
        "Oct 9, 2026 10:45",
        "v1.2.3",
        "Version 1.2.3 (2026-10-09 10:45:12)",
        "123456",
        "ID 98 76 54",
    ])
    func datesTimesVersionsAndShortCodesAreNotPhoneNumbers(text: String) {
        #expect(found(text, .contact) == [])
    }

    /// The data detector reads `+1 555 01` as a phone number, with 6 digits; fewer than 7 is not enough for us.
    @Test func aMatchOfFewerThanSevenDigitsIsDropped() {
        #expect(found("+1 555 01", .contact) == [])
    }

    @Test func aPhoneNumberAndAnAddressOnOneLineAreBothFound() {
        #expect(found("jane@example.com 202-555-0143") == [
            Found(.contact, "jane@example.com"),
            Found(.contact, "202-555-0143"),
        ])
    }

    // MARK: Phone: what the data detector reads as a number and isn't

    /// Rows of short numbers are tables and counters.
    @Test(arguments: [
        "12 13 14 15 16 17 18",
        "9 10 11 12 13 14 15 16",
        "98 87 76 65 54 43",
        "Scores: 12 13 14 15 16 17 18 19",
        "1  2  3  4  5  6  7  8  9 10",
    ])
    func aRowOfShortNumbersIsNotAPhoneNumber(row: String) {
        #expect(found(row, .contact) == [])
    }

    /// ...unless it starts the way a number with a country or trunk prefix does.
    @Test(arguments: ["01 23 45 67 89", "+33 1 23 45 67 89", "01 02 03 04 05 06 07", "+1 2 3 4 5 6 7 8"])
    func aRowThatStartsWithAPlusOrAZeroIsAPhoneNumber(number: String) {
        #expect(found("tel \(number) ok", .contact) == [Found(.contact, number)])
    }

    @Test func aRowWithGroupsOfThreeDigitsIsAPhoneNumber() {
        #expect(found("tel 202 555 0143 99 98", .contact).count == 1)
    }

    /// The detector reads the digits of a coordinate as a number, without its sign.
    @Test(arguments: ["-122.4194", "37.7749, -122.4194", "lat -122.4194 lon", "at -33.8688, -151.2093"])
    func aSignedDecimalIsNotAPhoneNumber(text: String) {
        #expect(found(text, .contact) == [])
    }

    @Test func aDottedPhoneNumberWithoutASignIsStillOne() {
        #expect(found("call 555.0100 now", .contact) == [Found(.contact, "555.0100")])
        #expect(found("call 1.555.0100 now", .contact) == [Found(.contact, "1.555.0100")])
    }

    // MARK: Phone: long lines

    /// A long line is read in windows, and only the windows with at least 7 digits are read at all.
    @Test func aNumberAtTheEndOfAVeryLongLineOfTextIsFound() {
        let line = String(repeating: "text ", count: 3_000) + "call 202-555-0143"
        #expect(found(line, .contact) == [Found(.contact, "202-555-0143")])
    }

    @Test func aNumberAtTheStartOfAVeryLongLineOfTextIsFound() {
        let line = "call 202-555-0143 " + String(repeating: "text ", count: 3_000)
        #expect(found(line, .contact) == [Found(.contact, "202-555-0143")])
    }

    /// Wherever the number sits against the edge of a window, it is found whole.
    @Test(arguments: Array(100...200))
    func aNumberAcrossAWindowEdgeIsFoundWhole(padding: Int) {
        let line = String(repeating: "x", count: padding) + " 202-555-0143 " + String(repeating: "y", count: 300)
        #expect(found(line, .contact) == [Found(.contact, "202-555-0143")])
    }

    @Test func aLineWithFewerThanSevenDigitsHasNoPhoneNumber() {
        #expect(ContactPatterns.phoneNumbers(in: "+1 555 01 and 123456 and no more") == [])
        #expect(ContactPatterns.phoneNumbers(in: String(repeating: "word ", count: 5_000)) == [])
    }

    // MARK: Phone: a number at the edge of a window

    /// `line`: 'x's, with each number at its offset, between spaces.
    private func line(length: Int, _ numbers: [(at: Int, text: String)]) -> String {
        var characters = Array(repeating: Character("x"), count: length)
        for (position, text) in numbers {
            characters[position - 1] = " "
            for (offset, character) in text.enumerated() { characters[position + offset] = character }
            characters[position + text.count] = " "
        }
        return String(characters)
    }

    /// Windows start at 0, 120, 240, 360 and 480 and are 160 long. A number across the end of one is seen whole by the next, and
    /// what the one saw of it (`202-555-01`, with `43` left readable) is not a finding.
    @Test func aNumberAcrossTheEndOfAWindowIsFoundWholeOrNotAtAll() {
        let numbers = [(10, "202-555-0101"), (150, "202-555-0102"), (270, "202-555-0103")]
        let text = line(length: 600, numbers)
        #expect(found(text, .contact).map(\.text) == numbers.map(\.1))
    }

    /// Three windows with digits are read; a fourth only when the third ended inside a number. A number across the end of the
    /// fourth is held back like any other, and with no window left to read, the next one is read for it alone: it is found
    /// whole. Numbers past it are beyond the windows read.
    @Test func aNumberAcrossTheEndOfTheLastWindowReadIsFoundWhole() {
        let numbers = [(10, "202-555-0101"), (150, "202-555-0102"), (270, "202-555-0103"), (390, "202-555-0104"), (510, "202-555-0105"), (600, "202-555-0106")]
        let text = line(length: 700, numbers)
        #expect(found(text, .contact).map(\.text) == ["202-555-0101", "202-555-0102", "202-555-0103", "202-555-0104", "202-555-0105"])
    }

    // MARK: Phone: a number followed by padding (round 2 found these)

    /// Padding after a number: glued to it, or after a space. (The data detector reads no number glued to `·`, `-`, `=`, `─`
    /// or `•`, whatever the window: it takes them for part of a word. After a space it does.)
    static let paddings: [(pad: String, before: String)] = [
        (".", ""), (" ", ""), ("_", ""), ("|", ""), ("…", ""), ("·", " "), ("-", " "), ("=", " "), ("─", " "),
    ]

    /// Only a number that ends within 3 characters of a window's end (`+44 20 7946 ` and then the edge) may go on in the next
    /// window. One followed by a long run of dots or spaces ends there, and is found.
    @Test(arguments: paddings)
    func aNumberFollowedByALongRunOfPaddingIsFound(pad: String, before: String) {
        let line = "Tel 202-555-0143" + before + String(repeating: pad, count: 150) + " open daily"
        #expect(readable("202-555-0143", in: line, .contact) == "", "\(masked(line, .contact))")
    }

    /// The data detector reads no number glued to dashes, but a window that cuts the dashes off reads one (the number ends at
    /// the window's end, 160, or the window cuts it after `202-555-01`, at 161), and no later window reads one that covers
    /// it: what that window held back is never dropped, and is reported with the digits that go on past the window's end.
    /// Elsewhere no window reads a number, and it is not found at all; never partly.
    @Test(arguments: ["·", "-", "=", "─"])
    func aNumberThatOnlyAWindowReadsIsMaskedWithTheDigitsPastItsEnd(pad: String) {
        let number = "202-555-0143"
        for end in 155...171 {
            let line = String(repeating: "x", count: end - number.count - 1) + " " + number + String(repeating: pad, count: 40) + " open daily"
            let readableNow = readable(number, in: line, .contact)
            if end == 160 || end == 161 {
                #expect(readableNow == "", "ends at \(end): \(masked(line, .contact))")
            } else {
                #expect(readableNow == "" || readableNow == number, "ends at \(end): \(masked(line, .contact))")
            }
        }
    }

    // MARK: Phone: a number whose last group is glued to an unusual character

    /// The data detector stops a number grouped by spaces one group early when that group is glued to a character it doesn't
    /// expect (`0958•`, `78·`, `0143x`): every number it reports takes in the digit groups that go on after it.
    @Test(arguments: [
        ("Tel +44 20 7946 0958•Mon-Fri", "+44 20 7946 0958"),
        ("Tel 06 12 34 56 78·", "06 12 34 56 78"),
        ("Tel +44 20 7946 0958#2", "+44 20 7946 0958"),
        ("Tel +44 20 7946 0958-ish", "+44 20 7946 0958"),
        ("Tel +1 202 555 0143x", "+1 202 555 0143"),
    ])
    func aNumberWhoseLastGroupIsGluedToAnUnusualCharacterIsMaskedWhole(line: String, number: String) {
        #expect(masked(line, .contact) == line.replacingOccurrences(of: number, with: "▓"))
        #expect(readable(number, in: line) == "", "\(masked(line))")
    }

    @Test(arguments: ["→", "=", "─", "&", "+", "%", "€", "•", "·", "-", "#", "x", ";", ":", "!", "?", "\"", "…"])
    func aSpaceGroupedNumberGluedToTheNextWordIsMaskedWhole(glue: String) {
        for number in ["+1 202 555 0143", "+44 20 7946 0958", "06 12 34 56 78"] {
            let line = "Call " + number + glue + "or email us"
            #expect(masked(line, .contact) == line.replacingOccurrences(of: number, with: "▓"))
        }
    }

    /// What follows a number and isn't a digit group of it stays as it is: a comma isn't a separator, an extension is what the
    /// data detector reads it as, and the next number is a number of its own.
    @Test func whatFollowsANumberAndIsNotPartOfItStaysOutOfIt() {
        #expect(found("Call +1 202 555 0143, or email us", .contact) == [Found(.contact, "+1 202 555 0143")])
        #expect(found("Tel +44 20 7946 0958 (office)", .contact) == [Found(.contact, "+44 20 7946 0958")])
        #expect(found("Tel +1 202 555 0143 x123", .contact) == [Found(.contact, "+1 202 555 0143 x123")])
        #expect(found("Tel 202-555-0143 ext. 12", .contact) == [Found(.contact, "202-555-0143 ext. 12")])
        #expect(found("Tel 202-555-0143 / 415-555-0102", .contact) == [Found(.contact, "202-555-0143"), Found(.contact, "415-555-0102")])
    }

    /// A full stop and a space part the groups of a number like any other separator, so a number written `+1 202 555. 0143` is
    /// masked whole and not up to the full stop, with its last group readable.
    @Test(arguments: [
        ("Tel +1 202 555. 0143", "+1 202 555. 0143"),
        ("Tel +1 202 555. 0143 open daily", "+1 202 555. 0143"),
        ("Tel 202-555. 0143", "202-555. 0143"),
        ("Tel +44 20 7946. 0958 (office)", "+44 20 7946. 0958"),
        ("Tel 06 12 34 56. 78", "06 12 34 56. 78"),
    ])
    func aNumberWithAFullStopAndASpaceBetweenGroupsIsMaskedWhole(line: String, number: String) {
        #expect(found(line, .contact) == [Found(.contact, number)])
        #expect(masked(line, .contact) == line.replacingOccurrences(of: number, with: "▓"))
    }

    /// The price of that: a number at the end of a sentence takes the digit that starts the next one (`202-555-0143. 5 rings`).
    /// The number itself is masked whole, and the words after it are not.
    @Test(arguments: ["Call 202-555-0143. 5 rings", "Call +1 202 555 0143. 5 rings", "Tel 06 12 34 56 78. 9 am"])
    func aNumberEndingASentenceIsMaskedWholeAndMayTakeTheDigitThatFollowsIt(line: String) {
        let number = String(line.dropFirst(5).prefix { $0 != "." })
        #expect(readable(number, in: line, .contact) == "", "\(masked(line, .contact))")
        let after = line.drop { $0 != "." }.drop { !$0.isLetter }
        #expect(masked(line, .contact).hasSuffix(after), "\(masked(line, .contact))")
    }

    /// What `continued` takes after a number stops where the next number starts: it is never continued into it, with or without
    /// a full stop and a space between.
    @Test(arguments: [
        ("Tel 202-555-0143. 415-555-0102", ["202-555-0143", "415-555-0102"]),
        ("Tel +1 202 555 0143. 415 555 0102 tail", ["+1 202 555 0143", "415 555 0102"]),
        ("Tel 202-555-0143 / 415-555-0102", ["202-555-0143", "415-555-0102"]),
    ])
    func aNumberIsNotContinuedIntoTheNextNumber(line: String, numbers: [String]) {
        #expect(found(line, .contact) == numbers.map { Found(.contact, $0) })
    }

    /// And it stops after 40 characters, however many groups follow (the stops are part of the forty): a number followed by a
    /// long run of `. 1` takes some of it, not all.
    @Test(arguments: [". 1", " 1.", ". 1."])
    func aNumberIsContinuedForFortyCharactersAtMost(group: String) {
        let number = "202-555-0143"
        let line = "Tel " + number + String(repeating: group, count: 40) + " end"
        let foundText = found(line, .contact).map(\.text)
        #expect(foundText.count == 1 && foundText[0].hasPrefix(number), "\(foundText)")
        let taken = (foundText.first?.count ?? 0) - number.count
        #expect(taken <= 40 + ContactPatterns.maximumCutGap, "\(taken) characters taken")
        #expect(masked(line, .contact).hasSuffix(" end") && masked(line, .contact).count > 30, "\(masked(line, .contact))")
    }

    // MARK: Phone: a number in the fourth window (round 3 found it)

    /// `numbers` placed in a filler with digits (so every window is read), each ending at its offset with a space before and
    /// after it, and `dots` dots before the space after the first.
    private func lineWithDigits(_ numbers: [(text: String, end: Int)], dotsAfterFirst dots: Int) -> String {
        var characters = Array(String(repeating: "a1b2c3d4 ", count: 120).prefix(900))
        for (index, number) in numbers.enumerated() {
            let start = number.end - number.text.count
            characters[start - 1] = " "
            for (offset, character) in number.text.enumerated() { characters[start + offset] = character }
            let padding = index == 0 ? dots : 0
            for offset in 0..<padding { characters[number.end + offset] = "." }
            characters[number.end + padding] = " "
        }
        return String(characters)
    }

    /// The third window (240 to 400) ends a few characters after a number followed by dots: nothing is held back, but a
    /// number ends in the overlap with the fourth window, so the fourth is read, and the number in it is found.
    @Test func aNumberInTheFourthWindowIsFoundAfterOneNearTheEndOfTheThird() {
        let line = lineWithDigits([("202-555-0101", 395), ("415-555-0102", 431)], dotsAfterFirst: 4)
        let expected = line.replacingOccurrences(of: "202-555-0101", with: "▓").replacingOccurrences(of: "415-555-0102", with: "▓")
        #expect(masked(line, .contact) == expected)
    }

    /// Wherever the third window reads the first number (in its overlap with the fourth, or cut by its end), the fourth is
    /// read. (A first number cut so early that the data detector reads nothing of it, `202-555-0` and the edge at 403, is the
    /// accepted miss past the window budget, and marks nothing.)
    @Test(arguments: [0, 2, 4, 10, 40])
    func aNumberInTheFourthWindowIsFoundWhereverTheFirstEndsNearTheThirdsEnd(dots: Int) {
        for firstEnd in [362, 380, 390, 395, 399, 400, 401, 402] {
            for secondEnd in stride(from: firstEnd + dots + 16, through: 515, by: 13) {
                let line = lineWithDigits([("202-555-0101", firstEnd), ("415-555-0102", secondEnd)], dotsAfterFirst: dots)
                #expect(readable("202-555-0101", in: line, .contact) == "", "first ends \(firstEnd), \(dots) dots, second ends \(secondEnd)")
                #expect(readable("415-555-0102", in: line, .contact) == "", "first ends \(firstEnd), \(dots) dots, second ends \(secondEnd)")
            }
        }
    }

    /// A match may go on past the end of its window only if it ends there, or a separator away: 3 spaces or punctuation
    /// marks at most. With more after it, or a letter, it ended where it does.
    @Test func aMatchMayGoOnPastItsWindowOnlyWithinThreeCharactersOfTheEnd() {
        func mayGoOn(_ line: String, gap: Int) -> Bool {
            let number = line.startIndex..<line.index(line.startIndex, offsetBy: 12)
            let window = line.startIndex..<line.index(line.startIndex, offsetBy: 12 + gap)
            return ContactPatterns.mayGoOn(number, pastTheEndOf: window, in: line)
        }
        let dotted = "202-555-0143" + String(repeating: ".", count: 10)
        #expect([0, 1, 2, 3].allSatisfy { mayGoOn(dotted, gap: $0) })
        #expect(![4, 5, 10].contains { mayGoOn(dotted, gap: $0) })
        #expect(mayGoOn("202-555-0143 - 7", gap: 3))
        #expect(!mayGoOn("202-555-0143 ab", gap: 2))
        #expect(!mayGoOn("202-555-0143 12", gap: 2))
    }

    @Test func aNumberInADotLeaderLineOrAPaddedTableRowIsFound() {
        let leaders = "Front desk 202-555-0143 " + String(repeating: ".", count: 140) + " ext 12 open daily"
        #expect(readable("202-555-0143", in: leaders, .contact) == "", "\(masked(leaders, .contact))")
        let table = "| Front desk | 202-555-0143 |" + String(repeating: " ", count: 130) + "| open daily 9-5 |"
        #expect(readable("202-555-0143", in: table, .contact) == "", "\(masked(table, .contact))")
        let underscores = "Phone 202-555-0143" + String(repeating: "_", count: 29) + " Fax"
        #expect(readable("202-555-0143", in: String(repeating: "x", count: 130) + underscores, .contact) == "")
    }

    /// Wherever a number and the padding after it sit against the end of the first window (160), whatever the padding and
    /// however long, the number is masked whole: it is either read whole, or held back and read whole by the next window.
    @Test(arguments: paddings)
    func aNumberFollowedByPaddingIsMaskedWholeWhereverTheWindowEnds(pad: String, before: String) {
        let number = "202-555-0143"
        for padding in [0, 1, 2, 3, 4, 5, 29, 60, 200] {
            for end in 145...175 {
                let line = "Tel " + String(repeating: "x", count: end - number.count - 5) + " " + number + before
                    + String(repeating: pad, count: padding) + " open daily"
                #expect(readable(number, in: line, .contact) == "", "ends at \(end), \(padding) of \(pad.debugDescription): \(masked(line, .contact))")
            }
        }
    }

    /// A row of numbers across the end of a window: the part of it one window saw is five groups, and not a row.
    @Test(arguments: Array(128...158))
    func aRowOfShortNumbersAcrossTheEndOfAWindowIsNoFinding(start: Int) {
        let row = (12...29).map(String.init).joined(separator: " ")
        let text = String(repeating: "x", count: start - 1) + " " + row + " " + String(repeating: "x", count: 200)
        #expect(found(text, .contact) == [])
    }

    /// Windows end at 160, 280, 400 and 520. Where only spaces or punctuation lie between what a window read of a number and its end,
    /// the number may go on in the next window: a window that read "+44 20 7946 " must not mask it and leave "0958" readable.
    /// The first three windows are read whatever they hold, so a number across the end of the first or second is whole; across
    /// the end of the third, whole if the one more window is read; across the end of that, it is not masked at all.
    @Test(arguments: ["+1 202 555 0143", "+44 20 7946 0958", "020 7946 0958", "+91 98765 43210", "+33 1 23 45 67 89", "01 23 45 67 89", "06 12 34 56 78", "202-555-0143"])
    func aNumberAcrossTheEndOfAWindowIsMaskedWholeOrNotAtAll(number: String) {
        let filler = String(repeating: "a1b2c3d4 ", count: 80)
        for edge in [160, 280, 400, 520] {
            for position in (edge - number.count - 3)...(edge + 3) {
                var characters = Array(filler.prefix(700))
                characters[position - 1] = " "
                for (offset, character) in number.enumerated() { characters[position + offset] = character }
                characters[position + number.count] = " "
                let text = String(characters)
                let numberRange = text.index(text.startIndex, offsetBy: position)..<text.index(text.startIndex, offsetBy: position + number.count)
                let findings = SensitiveDetector.findings(in: text, kinds: .contact)
                let covered = text[numberRange].indices.count { index in findings.contains { $0.range.contains(index) } }
                #expect(covered == 0 || covered == number.count, "\(number) at \(position) (ends \(position + number.count)): \(covered) of \(number.count) masked")
                if edge <= 280 { #expect(covered == number.count, "\(number) at \(position) is across the end of a window that is followed by one that is read") }
            }
        }
    }
}
