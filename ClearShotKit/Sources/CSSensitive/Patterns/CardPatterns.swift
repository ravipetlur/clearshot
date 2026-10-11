import Foundation

/// Payment card numbers: 13 to 19 digits, run together or in groups parted by spaces (no-break spaces too) and dashes,
/// one or several ("4242 4242 4242 4242", "3782  822463  10005"). A number is a card when any of these holds:
///
/// 1. it passes the Luhn check;
/// 2. it is written in a card's own grouping: 4-4-4-4, 4-4-4-4-3, 4-6-5 (Amex) or 4-6-4 (Diners), whether it passes Luhn or not;
/// 3. it follows a card label on the line ("card:", "cc#", "visa", and as code and data write one: `card_number`, `cardNumber`,
///    `"card_number": "4222…"`, `card=4222…`), in whatever grouping, whether it passes Luhn or not.
///
/// The last two exist because OCR misreads a digit often enough that a real card fails Luhn, and a mask may cover a
/// little more than a card but must never leave part of one readable. Zeros alone are a placeholder, never a card.
enum CardPatterns {
    static let digitCounts = 13...19
    /// A group of a card number is this many digits at least, except the last: cards are written in groups of 4, 5 or 6.
    /// It keeps the short numbers around a card ("order 12 4242 …", "2026-10-09 4242 …") out of it.
    private static let minimumInnerGroup = 4
    /// The sizes of the groups of a card written in a card's own grouping, in order.
    private static let cardGroupings: [[Int]] = [[4, 4, 4, 4], [4, 4, 4, 4, 3], [4, 6, 5], [4, 6, 4]]

    private static let digits = NSRegularExpression.fixed(#"[0-9]+"#)

    /// A card label, then what may sit between it and the number, and then, not part of the match, the number's first digit.
    ///
    /// - The label is `card`, `credit card`, `debit card`, `cc`, `visa`, `mastercard` or `amex`, optionally with `no`,
    ///   `num` or `number` after it; the words may be parted by spaces, `_` or `-`, or joined in camel case or run together
    ///   (`card number`, `card_no`, `credit-card`, `cardNumber`, `ccnum`). It is a word of its own: no letter or digit before
    ///   it (a `_` or `-` is fine: `user_card`), unless camel case starts a new word there (`userCard`), and none after.
    /// - Between label and number there is either any run of spaces with the marks `:`, `#`, `-`, `.` and `no.` among them
    ///   ("card : 4222…", the shapes of a label in a screenshot's text), or up to 4 characters of space, quote, `:`, `=`, `#`,
    ///   `-`, `.` and `(`, and a `no.`, `no` or `number` among them (`"card_number": "4222…`, `card=4222…`, `card (4222…`).
    /// - A space is a space, a tab or a no-break space (U+00A0), as text copied from a page or a table has them.
    ///
    /// Linear: every part takes what it matches and nothing else can (a space is taken by one part, each loop turn takes
    /// a mark, the other parts are bounded), so a line is read in time proportional to its length however many spaces, marks
    /// or label words it holds.
    private static let label = NSRegularExpression.fixed(
        // Where a label may start: after anything that isn't a letter or digit, or at a lower-to-upper camel case step.
        #"(?:(?<![\p{L}\p{N}])|(?-i:(?<=[a-z])(?=[A-Z])))"#
            // The label's words, and a `no`, `num` or `number` after them.
            + #"(?:card|credit[\#(spaces)_\-]*card|debit[\#(spaces)_\-]*card|cc|visa|mastercard|amex)(?:[\#(spaces)_\-]*(?:number|num|no))?"#
            // The label ends at the end of a word.
            + #"(?![\p{L}\p{N}])"#
            + #"(?:"#
            // Any run of spaces, with the marks `:` `#` `-` `.` and `no.` among them.
            + #"[\#(spaces)]*(?:(?:no\.|[:#.\-])[\#(spaces)]*)*"#
            + #"|"#
            // Up to four of the characters of the filler, a `no.`, `no` or `number`, and up to four more.
            + #"[\#(spaces)\"':=#.\-(]{0,4}(?:(?:no\.?|number)[\#(spaces)\"':=#.\-(]{0,4})?"#
            + #")(?=[0-9])"#,
        caseInsensitive: true)

    /// The characters of a space, for inside a character class of `label`: a space, a tab and a no-break space.
    private static let spaces = #" \t\x{00A0}"#

    static func spans(in line: String) -> [Range<String.Index>] {
        // Runs of digits, chained where spaces, no-break spaces and dashes are all that part a run from the next.
        var chains: [[Range<String.Index>]] = []
        for group in digits.ranges(in: line) {
            if let previous = chains.last?.last, joins(previous, group, in: line) {
                chains[chains.count - 1].append(group)
            } else {
                chains.append([group])
            }
        }
        guard !chains.isEmpty else { return [] }
        // The digits a card label leads to. A label is letters, so the group after it always starts a chain.
        let afterLabel = Set(label.ranges(in: line).map(\.upperBound))
        return chains.flatMap { chain in
            cards(in: chain, of: line) + labelled(chain, after: afterLabel, of: line)
        }
    }

    /// Whether nothing but spaces, no-break spaces (U+00A0, which text copied from a page has between groups) and dashes
    /// (at least one) lies between two runs of digits. A tab doesn't part groups, or the columns of a table would join.
    private static func joins(_ earlier: Range<String.Index>, _ later: Range<String.Index>, in line: String) -> Bool {
        let gap = line[earlier.upperBound..<later.lowerBound]
        return !gap.isEmpty && gap.allSatisfy { $0 == " " || $0 == "\u{00A0}" || $0 == "-" }
    }

    /// The cards in a chain of groups: every run of whole groups that has a card's digit count and passes Luhn or is
    /// written in a card's grouping. Runs that overlap are one number as far as masking goes ("1004 - 4111-1111-1111-1111":
    /// both "1004 4111 1111 1111" and "4111 1111 1111 1111" pass; "1234 4222 2222 2222 3433": both its first four groups
    /// and its last four are in a card's grouping), and are made one finding by the merge, so none of a card is left
    /// readable. A chain of four-digit groups is therefore masked whole, however long, over-masking what isn't a card.
    private static func cards(in chain: [Range<String.Index>], of line: String) -> [Range<String.Index>] {
        let counts = chain.map { line[$0].count }
        var found: [Range<String.Index>] = []
        for start in chain.indices {
            var total = 0
            for end in start..<chain.count {
                total += counts[end]
                if total > digitCounts.upperBound { break }
                if digitCounts.contains(total), isCard(chain[start...end], counts: counts[start...end], in: line) {
                    found.append(chain[start].lowerBound..<chain[end].upperBound)
                }
                // Another group after this one makes it an inner group.
                if counts[end] < minimumInnerGroup { break }
            }
        }
        return found
    }

    /// The number a card label leads to: from the chain's first group, which must be the one right after a label, as many
    /// whole groups as make 13 to 19 digits, in any grouping and the most there are. The most, so that a number OCR has
    /// split oddly isn't left half-readable ("6212 345678 9012345 67" is 19 digits, not 17); it may take in a group that
    /// is something else ("card 4242424242424242 12 30" masks the 12), which over-masks a little.
    private static func labelled(_ chain: [Range<String.Index>], after labelEnds: Set<String.Index>, of line: String) -> [Range<String.Index>] {
        guard let first = chain.first, labelEnds.contains(first.lowerBound) else { return [] }
        var total = 0
        var last: Range<String.Index>?
        for group in chain {
            total += line[group].count
            if total > digitCounts.upperBound { break }
            if digitCounts.contains(total) { last = group }
        }
        guard let last else { return [] }
        let number = first.lowerBound..<last.upperBound
        return hasNonZeroDigit(line[number]) ? [number] : []
    }

    private static func isCard(_ groups: ArraySlice<Range<String.Index>>, counts: ArraySlice<Int>, in line: String) -> Bool {
        let digits = groups.flatMap { line[$0].compactMap(\.wholeNumberValue) }
        // Zeros alone pass Luhn, and are a placeholder.
        guard digits.contains(where: { $0 != 0 }) else { return false }
        return passesLuhn(digits) || cardGroupings.contains(Array(counts))
    }

    private static func hasNonZeroDigit(_ text: Substring) -> Bool {
        text.contains { ($0.wholeNumberValue ?? 0) != 0 }
    }

    /// The Luhn check: from the right, double every second digit (taking 9 off a result over 9), and the sum is a
    /// multiple of 10.
    static func passesLuhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (position, digit) in digits.reversed().enumerated() {
            if position.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }
}
