import Foundation
import Testing
@testable import CSSensitive

/// 13 to 19 digits, in groups of spaces or dashes if at all, that pass the Luhn check; or that are written in a card's own
/// grouping, or follow a card label, whether they pass it or not (OCR misreads a digit often enough that a real card fails).
struct CardDetectionTests {
    func cards(_ line: String) -> [String] { foundText(line, .cards) }

    @Test(arguments: [
        "4242 4242 4242 4242",
        "4242-4242-4242-4242",
        "4242424242424242",
        "4242 4242-4242 4242",
        "3782 822463 10005",
        "378282246310005",
        "4222 2222 2222 2",
    ])
    func aCardNumberThatPassesLuhnIsFound(number: String) {
        #expect(found("card \(number) exp 12/30", .cards) == [Found(.card, number)])
    }

    @Test func allCardLengthsFromThirteenToNineteenAreFound() {
        for length in 13...19 {
            let digits = Fake.cardDigits(prefix: "4", length: length)
            #expect(cards("number \(digits)") == [digits], "length \(length)")
        }
    }

    @Test func aGroupedNineteenDigitNumberIsFoundWhole() {
        let digits = Fake.cardDigits(prefix: "6212", length: 19)
        let grouped = [digits.prefix(4), digits.dropFirst(4).prefix(4), digits.dropFirst(8).prefix(4), digits.dropFirst(12).prefix(4), digits.dropFirst(16)]
            .map(String.init).joined(separator: " ")
        #expect(cards("cn \(grouped)") == [grouped])
    }

    /// A card isn't left half-hidden: where the groups beside it fit too, the longest number that passes Luhn is the finding.
    @Test func aNineteenDigitNumberWhoseFirstSixteenDigitsAlsoPassLuhnIsFoundWhole() throws {
        let sixteen = Fake.cardDigits(prefix: "6212", length: 16)
        let whole = (0...999).map { sixteen + String(format: "%03d", $0) }.first(where: Fake.luhnHolds)
        let digits = try #require(whole)
        #expect(digits.count == 19 && Fake.luhnHolds(sixteen))
        let groups = [digits.prefix(4), digits.dropFirst(4).prefix(4), digits.dropFirst(8).prefix(4), digits.dropFirst(12).prefix(4), digits.dropFirst(16)]
        let grouped = groups.map(String.init).joined(separator: " ")
        #expect(cards(grouped) == [grouped])
    }

    /// OCR reads the gap between two groups as more than one space, and some layouts do.
    @Test(arguments: [
        "4242  4242  4242  4242",
        "4242   4242 4242    4242",
        "4242 - 4242 - 4242 - 4242",
        "4242--4242--4242--4242",
        "4242 -4242- 4242 4242",
        "3782  822463  10005",
    ])
    func moreThanOneSpaceOrDashBetweenGroupsIsStillACard(number: String) {
        #expect(cards("card \(number) exp 12/30") == [number])
    }

    @Test func aGapOfSomethingElseEndsTheNumber() {
        #expect(cards("4242 4242, 4242 4242") == [])
        #expect(cards("4242 4242 / 4242 4242") == [])
        #expect(cards("4242 4242 4242 4242x") == ["4242 4242 4242 4242"])
    }

    /// 1004 4111 1111 1111 passes Luhn, and so does 4111 1111 1111 1111: neither is taken alone, both are masked.
    @Test func overlappingRunsThatPassLuhnAreMaskedTogether() {
        #expect(Fake.luhnHolds("1004411111111111") && Fake.luhnHolds("4111111111111111"))
        #expect(masked("Ref 1004 - 4111-1111-1111-1111", .cards) == "Ref ▓")
        #expect(found("Ref 1004 - 4111-1111-1111-1111", .cards) == [Found(.card, "1004 - 4111-1111-1111-1111")])
        #expect(masked("Ref 1004 4111 1111 1111 1111 ok", .cards) == "Ref ▓ ok")
    }

    /// A number that fails Luhn is a card only in a card's grouping or after a card label (below). Written run together
    /// with nothing before it, or in some other grouping, it isn't.
    @Test func aNumberThatFailsLuhnWithNoCardGroupingOrLabelIsNotACard() {
        #expect(!Fake.luhnHolds("4242424242424241") && !Fake.luhnHolds("378282246310006") && !Fake.luhnHolds("424242424242421"))
        #expect(cards("4242424242424241") == [])
        #expect(cards("378282246310006") == [])
        #expect(cards("42424 24242 42421") == [])
    }

    @Test func aTwelveDigitRunIsNotACard() {
        #expect(cards("424242424242") == [])
        #expect(cards("4242 4242 4242") == [])
    }

    @Test func tooLongARunIsNotACard() {
        #expect(cards(Fake.cardDigits(prefix: "4", length: 20)) == [])
    }

    @Test func aRunOfZerosIsNotACard() {
        #expect(cards("0000 0000 0000 0000") == [])
        #expect(cards("0000000000000") == [])
    }

    @Test func aNumberBeforeTheCardIsNotPartOfIt() {
        #expect(cards("order 12 4242 4242 4242 4242") == ["4242 4242 4242 4242"])
        #expect(cards("2026-10-09 4242 4242 4242 4242") == ["4242 4242 4242 4242"])
    }

    @Test func aGroupAfterTheCardIsLeftWhenItMakesTheNumberFailLuhn() {
        // 4242 4242 4242 4242 passes Luhn; the 17 digits with a trailing 1 do not.
        #expect(Fake.luhnHolds("4242424242424242"))
        #expect(!Fake.luhnHolds("42424242424242421"))
        #expect(cards("4242 4242 4242 4242 1") == ["4242 4242 4242 4242"])
    }

    @Test func twoCardsOnALineAreBothFound() {
        #expect(cards("4242 4242 4242 4242 / 3782 822463 10005") == ["4242 4242 4242 4242", "3782 822463 10005"])
    }

    @Test func datesPhoneNumbersAndAddressesAreNotCards() {
        #expect(cards("2026-10-09 10:45:12") == [])
        #expect(cards("202-555-0143") == [])
        #expect(cards("192.168.1.20") == [])
        #expect(cards("1,234,567,890,123") == [])
    }

    @Test func luhnChecksTheDigitsFromTheRight() {
        #expect(CardPatterns.passesLuhn([4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2]))
        #expect(!CardPatterns.passesLuhn([4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 1]))
        #expect(CardPatterns.passesLuhn([3, 7, 8, 2, 8, 2, 2, 4, 6, 3, 1, 0, 0, 0, 5]))
        #expect(CardPatterns.passesLuhn([0]))
        #expect(!CardPatterns.passesLuhn([1]))
        // Doubling an 8 or a 9 gives two digits: 16 and 18 count as 7 and 9.
        #expect(CardPatterns.passesLuhn([8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8]) == Fake.luhnHolds("80000000000000008"))
    }

    @Test func cardNumbersAreNotReportedWhenCardsAreOff() {
        #expect(found("4242 4242 4242 4242", [.contact, .keysAndTokens, .ipAddresses]).allSatisfy { $0.kind != .card })
    }

    // MARK: Without the checksum: a card's own grouping, or a card label

    /// Premise of the tests below: the number fails Luhn, so only the grouping or the label can make it a finding.
    private func failsLuhn(_ digits: String) -> Bool { !Fake.luhnHolds(digits) }

    /// The owner's smoke test: this line was left readable because the sum is 59.
    @Test func theLineFromTheSmokeTestIsMaskedWhole() {
        #expect(failsLuhn("4222222222223433"))
        #expect(!CardPatterns.passesLuhn([4, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 4, 3, 3]))
        #expect(masked("card : 4222 2222 2222 3433", .cards) == "card : ▓")
        #expect(readable("4222 2222 2222 3433", in: "card : 4222 2222 2222 3433", .cards) == "")
        #expect(masked("card : 4222 2222 2222 3433") == "card : ▓")
    }

    @Test(arguments: [
        "4222 2222 2222 3433",
        "4222-2222-2222-3433",
        "4222-2222 2222-3433",
        "4222 - 2222  2222 -- 3433",
        // 4-4-4-4-3, 19 digits
        "6212 3456 7890 1234 567",
        "6212-3456-7890-1234-567",
        // Amex 4-6-5, 15 digits
        "3782 822463 10006",
        "3782-822463-10006",
        // Diners 4-6-4, 14 digits
        "3056 930902 5905",
        "3056-930902-5905",
    ])
    func aCardGroupingIsACardWithNoLabelAndNoChecksum(number: String) {
        #expect(failsLuhn(number.filter(\.isNumber)), "\(number) passes Luhn")
        #expect(masked(number, .cards) == "▓")
        #expect(masked("paid with \(number) today", .cards) == "paid with ▓ today")
        #expect(cards("ref \(number)") == [number])
    }

    /// The groups must be exactly a card's, in order; anything else with no label and no Luhn is left alone.
    @Test(arguments: [
        "4222 222 2222 3433",  // 4-3-4-4
        "4222 2222 2222 343",  // 4-4-4-3, 15 digits
        "42222 22222 22223",   // 5-5-5
        "3782 82246 310006",   // 4-5-6: Amex's groups the other way round
    ])
    func someOtherGroupingThatFailsLuhnIsNotACard(number: String) {
        #expect(failsLuhn(number.filter(\.isNumber)), "\(number) passes Luhn")
        #expect(cards(number) == [])
        #expect(masked("ref \(number)", .cards) == "ref \(number)")
    }

    @Test func aCardGroupingNeedsExactlyThoseGroupsNotJustTheirTotal() {
        // 14 digits as 4-6-4 is Diners; as 4-4-6 it is not.
        #expect(failsLuhn("30569309025905"))
        #expect(cards("3056 9309 025905") == [])
        // 15 digits as 4-6-5 is Amex; as 5-6-4 it is not.
        #expect(failsLuhn("378282246310006"))
        #expect(cards("37828 224631 0006") == [])
    }

    @Test(arguments: [
        ("card", "Card"), ("card no", "Card No"), ("card number", "Card Number"), ("credit card", "Credit Card"),
        ("debit card", "Debit Card"), ("cc", "CC"), ("cc#", "CC#"), ("visa", "Visa"), ("mastercard", "MasterCard"), ("amex", "AMEX"),
    ])
    func everyCardLabelMakesTheNumberAfterItACard(label: String, shouted: String) {
        for spelled in [label, shouted, label.uppercased()] {
            #expect(masked("\(spelled) 4222222222223433", .cards) == "\(spelled) ▓", "\(spelled)")
            #expect(masked("\(spelled): 4222222222223433", .cards) == "\(spelled): ▓", "\(spelled):")
        }
    }

    @Test(arguments: [
        "Card number: ", "card number:", "card : ", "card#", "Card #: ", "card no. ", "Card No.: ", "card no: ", "card no.", "card - ",
        "card-", "card. ", "cc# ", "cc:", "CC - ", "visa ", "Visa:", "visa-", "mastercard# ", "amex no. ", "credit card number: ",
        "Debit Card No. ", "card    ", "card  :  ",
    ])
    func theLabelMayBeFollowedBySpacesAndPunctuation(label: String) {
        let number = "4222222222223433"
        #expect(failsLuhn(number))
        #expect(masked("\(label)\(number)", .cards) == "\(label)▓", "\(label)")
        #expect(readable(number, in: "\(label)\(number)", .cards) == "")
    }

    /// After a label the grouping is anything at all: groups of any size, or none.
    @Test(arguments: [
        "4222222222223433",
        "4222 2222 2222 343",
        "4222 2222 2222 3",
        "4222-2222-2222-3433",
        "4222 22 2222 2222 3433",
        "42 22 22 22 22 22 22 34 33",
        "4222222222 223433",
        "4222222222223 433",
        "4222 2222 2222 3433 567",
        "4222222222223433567",
    ])
    func aLabelMakesAnyGroupingOfThirteenToNineteenDigitsACard(number: String) {
        #expect(failsLuhn(number.filter(\.isNumber)), "\(number) passes Luhn")
        #expect(masked("card \(number)", .cards) == "card ▓", "\(number)")
        #expect(masked("CC# \(number) exp 12/30", .cards) == "CC# ▓ exp 12/30", "\(number)")
    }

    @Test func theLabelsFromTheSmokeTestAndTheSpecAreMasked() {
        #expect(masked("Card number: 4222222222223433", .cards) == "Card number: ▓")
        #expect(masked("CC# 4222 2222 2222 343", .cards) == "CC# ▓")
        #expect(failsLuhn("4111111111111112") && failsLuhn("422222222222343"))
        #expect(masked("visa 4111111111111112", .cards) == "visa ▓")
    }

    /// A number after a label that has fewer than 13 digits, or more than 19, is not a card.
    @Test func aLabelledRunOutsideThirteenToNineteenDigitsIsNotACard() {
        #expect(cards("card 422222222222") == [])
        #expect(cards("card 4222 2222 2222") == [])
        #expect(cards("card 42222222222234331234") == [])
        #expect(cards("Card number: 123456") == [])
    }

    @Test func aLabelledRunThatIsAllZerosIsNotACard() {
        #expect(cards("card 0000 0000 0000 0000") == [])
        #expect(cards("card: 0000000000000000") == [])
        #expect(cards("visa 0000-0000-0000-0000-000") == [])
    }

    /// The number has to follow the label directly: only the few characters allowed (see the tests on the label's
    /// surroundings below) may part them, and the label is a word of its own.
    @Test(arguments: [
        "card is 4222222222223433",
        "card, 4222222222223433",
        "card; 4222222222223433",
        "card] 4222222222223433",
        "card/4222222222223433",
        "discard 4222222222223433",
        "Discard 4222222222223433",
        "DISCARD: 4222222222223433",
        "discardNumber: 4222222222223433",
        "cards 4222222222223433",
        "cardholder: 4222222222223433",
        "card_numbers: 4222222222223433",
        "card_x: 4222222222223433",
        "cc4222222222223433",
        "Order 4222222222223433",
        "Order no. 4222222222223433",
        "ref: 4222222222223433",
        "ccc 4222222222223433",
        "visas 4222222222223433",
        "Televisa 4222222222223433",
        "4222222222223433 card",
    ])
    func aNumberNotRightAfterALabelIsNotACard(line: String) {
        #expect(failsLuhn("4222222222223433"))
        #expect(cards(line) == [], "\(line)")
        #expect(masked(line, .cards) == line)
    }

    @Test func aRunOfThirteenDigitsWithNoLabelIsNotACard() {
        #expect(failsLuhn("1234567890123"))
        #expect(cards("Order 1234567890123") == [])
        #expect(cards("Order 4222222222223433") == [])
        #expect(masked("Order 4222222222223433", .cards) == "Order 4222222222223433")
    }

    @Test func allZerosInACardGroupingAreAPlaceholderNotACard() {
        #expect(cards("0000 0000 0000 0000") == [])
        #expect(cards("0000-0000-0000-0000") == [])
        #expect(cards("0000 000000 00000") == [])
        #expect(cards("0000 0000 0000 0000 000") == [])
        #expect(masked("0000 0000 0000 0000", .cards) == "0000 0000 0000 0000")
        // One digit that isn't zero is a number.
        #expect(cards("0000 0000 0000 0001") == ["0000 0000 0000 0001"])
    }

    /// The short groups of a date part it from the card, as before: the card's grouping is the groups of the card.
    @Test func aDateBeforeACardGroupingIsNotPartOfIt() {
        #expect(masked("2026-10-09 4222 2222 2222 3433", .cards) == "2026-10-09 ▓")
        #expect(masked("order 12 4222 2222 2222 3433", .cards) == "order 12 ▓")
        #expect(cards("2026-10-09 10:45:12") == [])
        #expect(cards("2026-10-09 4222 2222 22") == [])
    }

    /// A 4-4-4-4 inside a longer chain of groups is a card's grouping wherever it sits, and the card candidates that
    /// overlap are one finding: the whole chain of four-digit groups is masked, never half of it.
    @Test func aCardGroupingInsideALongerChainOfGroupsIsMaskedWithTheChain() {
        #expect(masked("1234 4222 2222 2222 3433", .cards) == "▓")
        #expect(masked("4222 2222 2222 3433 1234", .cards) == "▓")
        #expect(masked("1234 5678 4222 2222 2222 3433", .cards) == "▓")
        #expect(readable("1234 4222 2222 2222 3433", in: "id 1234 4222 2222 2222 3433.", .cards) == "")
        #expect(masked("id 1234 4222 2222 2222 3433 end", .cards) == "id ▓ end")
        // Groups that aren't a card's don't join it: the card is masked, the rest is left.
        #expect(masked("4222 2222 2222 3433 12", .cards) == "▓ 12")
        #expect(masked("12 4222 2222 2222 3433", .cards) == "12 ▓")
        #expect(masked("4222 2222 2222 3433, 1234", .cards) == "▓, 1234")
    }

    @Test func twoCardsInTheirGroupingOnALineAreBothFound() {
        #expect(cards("4222 2222 2222 3433 / 3782 822463 10006") == ["4222 2222 2222 3433", "3782 822463 10006"])
        #expect(masked("a 4222-2222-2222-3433, b card: 4111111111111112", .cards) == "a ▓, b card: ▓")
    }

    /// Where the label's number is longer than the nineteen digits a card has, the digits that make a card are masked.
    @Test func aLabelledNumberIsMaskedToItsLongestRunOfThirteenToNineteenDigits() {
        // The 19 digits include the group that may be an expiry month: a mask covers a little more rather than leave
        // part of a number readable.
        #expect(masked("card 4242424242424242 12 30", .cards) == "card ▓ 30")
        #expect(masked("card 4222 2222 2222 3433 1", .cards) == "card ▓")
        #expect(masked("card 4222222222223433 exp 12/30", .cards) == "card ▓ exp 12/30")
    }

    @Test func aCardThatPassesLuhnAndTheOneThatFailsAreBothMaskedWhenAnyKindIsOn() {
        #expect(masked("card : 4222 2222 2222 3433", .all) == "card : ▓")
        #expect(masked("card : 4242 4242 4242 4242", .all) == "card : ▓")
    }

    @Test func aCardThatFailsLuhnIsNotReportedWhenCardsAreOff() {
        #expect(found("card : 4222 2222 2222 3433", [.contact, .keysAndTokens, .ipAddresses]).allSatisfy { $0.kind != .card })
        #expect(masked("4222 2222 2222 3433", [.keysAndTokens, .ipAddresses]) == "4222 2222 2222 3433")
    }

    /// Luhn-passing numbers stay a card as before, in every shape they were, whether or not a label or grouping helps.
    @Test func aNumberThatPassesLuhnIsStillACardWithNoLabelAndNoCardGrouping() {
        #expect(cards("4222 2222 2222 2") == ["4222 2222 2222 2"])
        #expect(cards("378282246310005") == ["378282246310005"])
        #expect(cards("order 4242424242424242") == ["4242424242424242"])
    }

    // MARK: A label in code and data: joined words, quotes, `=`, `(`

    /// A Luhn-failing number written run together after a label as source and data write it.
    @Test func aLabelInJSONOrCodeFindsTheNumberAfterItsQuotesAndSigns() {
        let number = "4222222222223433"
        #expect(failsLuhn(number))
        #expect(masked("\"card_number\": \"4222222222223433\"", .cards) == "\"card_number\": \"▓\"")
        #expect(masked("card=4222222222223433", .cards) == "card=▓")
        #expect(masked("cardNumber: '4222222222223433'", .cards) == "cardNumber: '▓'")
        #expect(masked("card (4222222222223433", .cards) == "card (▓")
        #expect(masked("card (4222222222223433)", .cards) == "card (▓)")
        for line in ["\"card_number\": \"4222222222223433\"", "card=4222222222223433", "cardNumber: '4222222222223433'", "card (4222222222223433"] {
            #expect(readable(number, in: line, .cards) == "", "\(line)")
            #expect(masked(line, .all) == line.replacingOccurrences(of: number, with: "▓"), "\(line)")
        }
    }

    /// The words of a label may be joined by `_` or `-`, run together, or in camel case, in any case; and a word of the
    /// code before it doesn't matter.
    @Test(arguments: [
        "card_number", "card-no", "cardNumber", "credit_card", "cc_number", "ccnum",
        "CARD_NUMBER", "Card-Number", "card_no", "card-number", "cardno", "cardnum", "card_num", "cardnumber",
        "credit-card", "creditCard", "creditcard", "CreditCard", "credit_card_number", "creditCardNumber", "credit card",
        "debit_card", "debit-card", "debitCard", "debit_card_no",
        "cc_num", "cc-no", "ccNumber", "CC_NUM", "cc number",
        "visa_number", "visa-no", "amex_number", "amexNo", "mastercard_number", "masterCard", "MasterCardNo",
        "user_card_number", "user-card", "userCardNumber", "paymentCard", "my_cc",
    ])
    func theWordsOfALabelMayBeJoinedBySeparatorsOrCamelCase(label: String) {
        let number = "4222222222223433"
        let lines = ["\(label): \(number)", "\(label)=\(number)", "\"\(label)\": \"\(number)\"", "\(label) (\(number)", "\(label) \(number)"]
        for line in lines {
            #expect(masked(line, .cards) == line.replacingOccurrences(of: number, with: "▓"), "\(line)")
        }
    }

    /// Up to four characters of space, quote, `:`, `=`, `#`, `-`, `.` and `(` may come between the label and the number, and a
    /// `no.`, `no` or `number` among them (up to four more on each side of it).
    @Test(arguments: [
        "=", " = ", ":", ": ", " : ", ":=", "\": \"", "': '", "(", " (", "((", "= \"", "=\"'", "#", " #", "#:", " # ", "-", " - ", ".", ". ",
        "\"", "'", " ' ", ":'(\"",
        " no. ", " no ", " no: ", " number ", " number: ", " number = \"", " no. = \"", ": no. ", "= number ", " (no. ",
    ])
    func upToFourCharactersOfSpaceQuoteAndSignMayPartALabelFromItsNumber(gap: String) {
        let number = "4222222222223433"
        #expect(masked("card\(gap)\(number)", .cards) == "card\(gap)▓", "\(gap.debugDescription)")
        #expect(masked("visa\(gap)\(number)", .cards) == "visa\(gap)▓", "\(gap.debugDescription)")
        #expect(masked("ref cc\(gap)\(number) x", .cards) == "ref cc\(gap)▓ x", "\(gap.debugDescription)")
    }

    /// More than that, or anything else, between them is not a label's number.
    @Test(arguments: [
        "=====", "\"\"\"\"\"", "(((((", "'''''", "  =  \"", "= = = =  ", " \" ' \" ' ",
        ",", ";", ")", "]", "/", "\\", "|", "@", "$", "*", "+", "!", "?", "<", ">", "&", "%", "~", "x", "_", "=,", " is ",
        " no. is ", " nonsense ", " numbers ", " no.= = = = =",
    ])
    func moreOrOtherCharactersBetweenALabelAndANumberAreNotACardLabel(gap: String) {
        let line = "card\(gap)4222222222223433"
        #expect(cards(line) == [], "\(gap.debugDescription)")
        #expect(masked(line, .cards) == line, "\(gap.debugDescription)")
    }

    @Test func aLabelWithQuotesAndSignsStillNeedsTheDigitCountAndSomethingBesidesZeros() {
        #expect(cards("\"card_number\": \"123456\"") == [])
        #expect(cards("card=422222222222") == [])
        #expect(cards("cardNumber: '42222222222234331234'") == [])
        #expect(cards("\"card_number\": \"0000000000000000\"") == [])
        #expect(cards("cardNumber: 0000 0000 0000 0000") == [])
    }

    @Test func theNumberAfterAJoinedLabelTakesAnyGroupingAndTheLongestRun() {
        #expect(masked("\"card_number\": \"4222 2222 2222 343\"", .cards) == "\"card_number\": \"▓\"")
        #expect(masked("cc_num=4222-2222-2222-3433", .cards) == "cc_num=▓")
        #expect(masked("cardNumber: '4222222222 223433' exp", .cards) == "cardNumber: '▓' exp")
    }

    /// A label inside another word is not a label: a letter or digit before it makes it part of that word (camel case
    /// aside), and one after it does too.
    @Test(arguments: [
        "discard=4222222222223433", "discard_number: 4222222222223433", "scc: 4222222222223433", "SCARD: 4222222222223433",
        "ccard: 4222222222223433", "cardigan: 4222222222223433", "visage: 4222222222223433", "amexx: 4222222222223433",
        "cardnumbers: 4222222222223433", "card_nom: 4222222222223433", "7card: 4222222222223433", "1cc=4222222222223433",
        "recc=4222222222223433", "abccard: 4222222222223433", "scard_number: 4222222222223433",
    ])
    func aLabelInsideAnotherWordIsNotALabel(line: String) {
        #expect(failsLuhn("4222222222223433"))
        #expect(cards(line) == [], "\(line)")
        #expect(masked(line, .cards) == line, "\(line)")
    }

    /// A label starts at the start of a word, after `_` or `-`, or where camel case starts a new one.
    @Test func aLabelStartsAtAWordOrACamelCaseHump() {
        #expect(masked("userCardNumber: 4222222222223433", .cards) == "userCardNumber: ▓")
        #expect(masked("billing_card = 4222222222223433", .cards) == "billing_card = ▓")
        #expect(masked("billing-cc=4222222222223433", .cards) == "billing-cc=▓")
    }

    @Test func aLabelledNumberInCodeIsMaskedWhateverTheOtherKindsAre() {
        #expect(found("cardNumber: '4222222222223433'", [.cards]).map(\.text) == ["4222222222223433"])
        #expect(found("card=4222222222223433", [.keysAndTokens, .ipAddresses]).allSatisfy { $0.kind != .card })
    }

    // MARK: A tab or a no-break space is a space

    /// Text copied from a page or a table has tabs and no-break spaces (U+00A0) where a typed line has spaces.
    @Test func aTabOrANoBreakSpaceBetweenALabelAndItsNumberIsASpace() {
        #expect(failsLuhn("4222222222223433"))
        #expect(masked("card:\t4222222222223433", .cards) == "card:\t▓")
        #expect(masked("card\u{00A0}4222 2222 2222 3433", .cards) == "card\u{00A0}▓")
        #expect(readable("4222222222223433", in: "card:\t4222222222223433", .cards) == "")
        #expect(readable("4222 2222 2222 3433", in: "card\u{00A0}4222 2222 2222 3433", .cards) == "")
    }

    /// In every place a space may part a label from its number, and the words of a label.
    @Test(arguments: [
        "\t", "\u{00A0}", ":\t", ":\u{00A0}", "\t:\t", "\u{00A0}:\u{00A0}", "\t\t\t\t\t\t", "\u{00A0}\u{00A0}\u{00A0}\u{00A0}\u{00A0}\u{00A0}",
        " \t#\u{00A0}", "\t-\t", "\u{00A0}no.\u{00A0}", "\tno\t", "\u{00A0}number:\t",
        "=\t", "\t=\t", "\":\t\"", "':\u{00A0}'", "\u{00A0}(", "\t(", "=\u{00A0}\"", "\t\t\t\t", "\u{00A0}\u{00A0}\u{00A0}\u{00A0}",
        "\tnumber = \"", "\u{00A0}no.\t=\t\"",
    ])
    func aTabOrANoBreakSpaceMayPartALabelFromItsNumber(gap: String) {
        let number = "4222222222223433"
        #expect(masked("card\(gap)\(number)", .cards) == "card\(gap)▓", "\(gap.debugDescription)")
        #expect(masked("cc\(gap)\(number) x", .cards) == "cc\(gap)▓ x", "\(gap.debugDescription)")
        #expect(masked("credit_card\(gap)\(number)", .cards) == "credit_card\(gap)▓", "\(gap.debugDescription)")
    }

    @Test(arguments: ["card\tnumber", "card\u{00A0}number", "credit\tcard", "credit\u{00A0}card", "debit\u{00A0}\u{00A0}card no", "credit \tcard\u{00A0}number", "cc\tno"])
    func aTabOrANoBreakSpaceMayPartTheWordsOfALabel(label: String) {
        let number = "4222222222223433"
        #expect(masked("\(label): \(number)", .cards) == "\(label): ▓", "\(label.debugDescription)")
        #expect(masked("\(label)\t\(number)", .cards) == "\(label)\t▓", "\(label.debugDescription)")
    }

    /// The same count applies: four characters of the filler, a tab or a no-break space counting as one each.
    @Test func fiveCharactersOfTheFillerAreStillTooMany() {
        #expect(cards("card=\t\t\t\t4222222222223433") == [])
        #expect(cards("card=\u{00A0}\u{00A0}\u{00A0}\u{00A0}4222222222223433") == [])
        #expect(cards("card\"\t\u{00A0}\t\"=4222222222223433") == [])
        #expect(masked("card=\t\t\t4222222222223433", .cards) == "card=\t\t\t▓")
    }

    /// A line break is not the space of a label's line.
    @Test(arguments: ["card:\n4222222222223433", "card:\r4222222222223433", "card:\u{000B}4222222222223433", "card:\u{000C}4222222222223433"])
    func aLineBreakDoesNotPartALabelFromItsNumber(line: String) {
        #expect(cards(line) == [], "\(line.debugDescription)")
    }

    // MARK: A no-break space parts the groups of a number like a space

    /// Text copied from a page has no-break spaces (U+00A0) between the groups of a number. A tab does not part them: it
    /// would join the columns of a table.
    @Test func aNoBreakSpaceBetweenGroupsIsASpaceAfterALabel() {
        #expect(failsLuhn("4222222222223433"))
        #expect(masked("card: 4222\u{00A0}2222\u{00A0}2222\u{00A0}3433", .cards) == "card: ▓")
        #expect(readable("4222\u{00A0}2222\u{00A0}2222\u{00A0}3433", in: "card: 4222\u{00A0}2222\u{00A0}2222\u{00A0}3433", .cards) == "")
        #expect(masked("card\u{00A0}4222\u{00A0}2222\u{00A0}2222\u{00A0}343", .cards) == "card\u{00A0}▓")
        #expect(masked("\"card_number\": \"4222\u{00A0}22\u{00A0}2222\u{00A0}2222\u{00A0}3433\"", .cards) == "\"card_number\": \"▓\"")
    }

    @Test(arguments: [
        "4222\u{00A0}2222\u{00A0}2222\u{00A0}3433",
        "4222\u{00A0}2222 2222-3433",
        "4222 \u{00A0}2222\u{00A0}\u{00A0}2222 \u{00A0} 3433",
        "4222\u{00A0}-\u{00A0}2222\u{00A0}-\u{00A0}2222\u{00A0}-\u{00A0}3433",
        "6212\u{00A0}3456\u{00A0}7890\u{00A0}1234\u{00A0}567",
        "3782\u{00A0}822463\u{00A0}10006",
        "3056\u{00A0}930902\u{00A0}5905",
    ])
    func aNoBreakSpaceBetweenGroupsMakesACardGroupingWithNoLabelAndNoChecksum(number: String) {
        #expect(failsLuhn(number.filter { $0.isASCII && $0.isNumber }), "\(number.debugDescription) passes Luhn")
        #expect(masked(number, .cards) == "▓", "\(number.debugDescription)")
        #expect(masked("paid with \(number) today", .cards) == "paid with ▓ today", "\(number.debugDescription)")
    }

    @Test func aNoBreakSpaceBetweenGroupsStillKeepsTheCardRules() {
        // A number that passes Luhn, with no grouping and no label: a card, as with spaces.
        #expect(Fake.luhnHolds("4222222222222"))
        #expect(masked("4222\u{00A0}2222\u{00A0}2222\u{00A0}2", .cards) == "▓")
        // Short groups before a card are not part of it, whatever parts them.
        #expect(masked("2026\u{00A0}10\u{00A0}09 4222\u{00A0}2222\u{00A0}2222\u{00A0}3433", .cards) == "2026\u{00A0}10\u{00A0}09 ▓")
        #expect(masked("order\u{00A0}12\u{00A0}4222 2222 2222 3433", .cards) == "order\u{00A0}12\u{00A0}▓")
        // Zeros, and other groupings that fail Luhn with no label, are not cards.
        #expect(cards("0000\u{00A0}0000\u{00A0}0000\u{00A0}0000") == [])
        #expect(cards("card: 0000\u{00A0}0000\u{00A0}0000\u{00A0}0000") == [])
        #expect(cards("4222\u{00A0}222\u{00A0}2222\u{00A0}3433") == [])
        #expect(cards("4222\u{00A0}2222\u{00A0}2222\u{00A0}343") == [])
        // A longer chain is one finding, as with spaces.
        #expect(masked("1234\u{00A0}4222\u{00A0}2222\u{00A0}2222\u{00A0}3433", .cards) == "▓")
    }

    @Test func aTabBetweenGroupsStillPartsThemSoTheColumnsOfATableDoNotJoin() {
        #expect(cards("4222\t2222\t2222\t3433") == [])
        #expect(cards("card: 4222\t2222\t2222\t3433") == [])
        #expect(cards("4242\t4242\t4242\t4242") == [])
        #expect(masked("2026\t4222\t2222\t2222\t3433", .cards) == "2026\t4222\t2222\t2222\t3433")
    }
}
