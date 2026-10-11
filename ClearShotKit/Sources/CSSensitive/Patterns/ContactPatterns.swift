import Foundation

/// Email addresses and phone numbers.
enum ContactPatterns {
    static func spans(in line: String) -> [Range<String.Index>] {
        emailAddresses(in: line) + phoneNumbers(in: line)
    }

    // MARK: Email

    /// What an address's local part is made of, after RFC 5322's atext: letters, marks and digits (of any script) and
    /// ``!#$%&'*+/=?^_`{|}~-``, and dots. (Too many characters is better than too few here: a local part that stopped early
    /// would leave the rest of the address readable.)
    private static func isLocalPartCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return scalar.isASCII && ".!#$%&'*+/=?^_`{|}~-".unicodeScalars.contains(scalar)
        }
    }

    /// What a run of local-part characters may start with that isn't part of the address: a quote around it, and the
    /// slashes of a URL (`ssh://git@host`).
    private static let notStartingAnAddress: Set<Unicode.Scalar> = ["'", "`", "/"]

    /// The `@` and the domain of an address: labels of letters, digits, marks, `_` and hyphens, then a dot and a top-level
    /// domain of two letters or more, or an internationalised one (`xn--p1ai`). The address ends at the top-level domain, so
    /// the full stop of a sentence and the brackets and quotes around an address are not in it. The `@` has a character that
    /// can end a local part before it.
    private static let atDomain = NSRegularExpression.fixed(
        #"(?<=[\p{L}\p{M}\p{N}.!#$%&'*+/=?^_`{|}~\-])@(?:[\p{L}\p{M}\p{N}_\-]+\.)+(?:xn--[A-Za-z0-9\-]+|[\p{L}\p{M}]{2,})(?![\p{L}\p{M}\p{N}\-])"#)

    /// Every address in `line`. One in a URL's user info is an address too: a password never hides an address, so
    /// `localhost:3000?email=jane@example.com` gives `jane@…` (with what is glued to it), and `admin:s3cret@db.example.com`
    /// gives `s3cret@db.example.com`, which the password's mask then joins.
    static func emailAddresses(in line: String) -> [Range<String.Index>] {
        atDomain.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard let atDomain = Range(match.range, in: line),
                  let start = localPartStart(before: atDomain.lowerBound, in: line) else { return nil }
            return start..<atDomain.upperBound
        }
    }

    /// Where the local part that ends at `at` (an `@`) starts: back over local-part characters, to a space, another `@` or a
    /// character that isn't one, without the quote or slashes it may start with. Nil if nothing is left.
    ///
    /// Every `@` is read on its own, and nothing is cut from inside the run: `list-bounces+jane=example.org@…`,
    /// `tom&jerry@…` and `a=b@…` are whole. In a chain written without spaces (`a@x.test?cc=b@x.test`) the second local part
    /// runs back over the first address's domain and the `?cc=` after it: the two masks overlap and join, and every address
    /// is whole. A label glued to an address (`email=jane@…`) is masked with it. It stays linear: a local part stops at the
    /// `@` before it, so each character is read back by the `@` after it only.
    private static func localPartStart(before at: String.Index, in line: String) -> String.Index? {
        let scalars = line.unicodeScalars
        var start = at
        while start > scalars.startIndex, isLocalPartCharacter(scalars[scalars.index(before: start)]) {
            start = scalars.index(before: start)
        }
        while start < at, notStartingAnAddress.contains(scalars[start]) { start = scalars.index(after: start) }
        return start < at ? start : nil
    }

    // MARK: Phone

    /// A phone number has this many digits at least. The system's data detector reads some shorter runs as numbers
    /// ("+1 555 01"), and a run this short is far likelier to be a code than a number.
    static let minimumPhoneDigits = 7

    /// The system's data detector, set to phone numbers only: with dates on, it claims the digits of "2026-10-09" first.
    /// Looking for phone numbers alone it reads dates, times and version numbers as nothing (the tests pin that).
    private static let phoneDetector: NSDataDetector = {
        do {
            return try NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
        } catch {
            preconditionFailure("CSSensitive: the phone-number detector can't be made: \(error)")
        }
    }()

    /// The detector costs time in proportion to the digits it reads, up to half a millisecond a character on digits
    /// parted by spaces (a table of numbers), and a line is as long as its text. So a line is read in windows of this
    /// many characters, each overlapping the last by `phoneWindowOverlap` (a phone number is shorter than that, so one
    /// lies whole in some window), a window with fewer than 7 digits isn't read, and no more than `maximumPhoneWindows`
    /// windows are read per line, and one more if the last of them read a number that ends in its overlap with the next
    /// (numbers come in groups: a list, a table row). A line of text is read through to its end; a line of digits for
    /// about 400 characters.
    /// OCR lines are 100 characters or so, and read in one window.
    static let phoneWindow = 160, phoneWindowOverlap = 40, maximumPhoneWindows = 3
    /// A match that ends this many characters or fewer before the end of a window, with only spaces and punctuation
    /// between (a separator: " - ", ") ", ". "), may go on in the next window. One with more than that after it ended
    /// where the match does: a number followed by a run of dots or spaces is a number.
    static let maximumCutGap = 3
    /// A row of this many groups of one or two digits ("12 13 14 15 16 17") is a table, a count or a score, not a phone
    /// number, unless it starts with `+` or `0` as a number with a country or trunk prefix does ("+33 1 23 45 67 89",
    /// "01 23 45 67 89").
    static let shortGroupsInARow = 6

    /// The phone numbers in `line`, read window by window.
    ///
    /// A match that may go on past the end of its window is **held back** until a later window reads it whole, and it is
    /// **never dropped**: if the data detector reads no number that covers it in a later window, it is reported as it is
    /// (and if it does, that number is the verdict: a row that a window cut is still a row). When no more windows are to
    /// be read, the next window is read for the held numbers alone (other numbers in it are past the windows read), so a
    /// number across the end of the last window read is found whole, not cut. Every number reported takes in the digit
    /// groups that go on after it (`continued`).
    static func phoneNumbers(in line: String) -> [Range<String.Index>] {
        guard hasDigits(line, atLeast: minimumPhoneDigits) else { return [] }
        var numbers: [Range<String.Index>] = []
        var heldBack: [PhoneMatch] = []
        var endedInTheOverlap = false
        var start = line.startIndex
        var budget = maximumPhoneWindows
        var extraRead = false
        while start < line.endIndex {
            let end = line.index(start, offsetBy: phoneWindow, limitedBy: line.endIndex) ?? line.endIndex
            let window = start..<end
            if hasDigits(line[window], atLeast: minimumPhoneDigits) {
                if budget > 0 {
                    budget -= 1
                } else if !heldBack.isEmpty || endedInTheOverlap, !extraRead {
                    // The last window read held a number back, or read one in its overlap with this one: one more window,
                    // to read the first whole and the ones beside it.
                    extraRead = true
                } else {
                    numbers += finished(heldBack, readingAgain: window, of: line)
                    heldBack = []
                    break
                }
                let read = phoneMatches(in: window, of: line, isLastWindow: end == line.endIndex)
                numbers += reported(notCovered(heldBack, by: (read.whole + read.heldBack).map(\.range)), in: line)
                numbers += reported(read.whole, in: line)
                heldBack = read.heldBack
                let overlap = line.index(end, offsetBy: -phoneWindowOverlap, limitedBy: start) ?? start
                endedInTheOverlap = (read.whole + read.heldBack).contains { $0.range.upperBound > overlap }
            } else {
                // A window that isn't read can't finish what was held back: it is reported as it is.
                numbers += reported(heldBack, in: line)
                heldBack = []
                endedInTheOverlap = false
            }
            guard end < line.endIndex else { break }
            start = line.index(end, offsetBy: -phoneWindowOverlap)
        }
        return numbers + reported(heldBack, in: line)
    }

    /// A match of the data detector, and where the next match in the same window starts: a number is never continued into
    /// the next one.
    private struct PhoneMatch {
        let range: Range<String.Index>
        let nextStart: String.Index?
    }

    /// What the data detector reads as a phone number in `window` of `line`: the matches it reads whole, and those that may
    /// go on in the next window (held back), unless `window` ends the line.
    private static func phoneMatches(in window: Range<String.Index>, of line: String, isLastWindow: Bool)
        -> (whole: [PhoneMatch], heldBack: [PhoneMatch])
    {
        let ranges = phoneDetector.matches(in: line, range: NSRange(window, in: line)).compactMap { match in
            match.resultType == .phoneNumber ? Range(match.range, in: line) : nil
        }
        var whole: [PhoneMatch] = [], heldBack: [PhoneMatch] = []
        for (index, range) in ranges.enumerated() {
            let match = PhoneMatch(range: range, nextStart: index + 1 < ranges.count ? ranges[index + 1].lowerBound : nil)
            if !isLastWindow, mayGoOn(range, pastTheEndOf: window, in: line) {
                heldBack.append(match)
            } else {
                whole.append(match)
            }
        }
        return (whole, heldBack)
    }

    /// Whether the match `range` may go on past the end of `window`: it ends there, or only spaces and punctuation, no
    /// more than `maximumCutGap` of them, lie between ("+44 20 7946 " and then the edge, and "0958" after it).
    static func mayGoOn(_ range: Range<String.Index>, pastTheEndOf window: Range<String.Index>, in line: String) -> Bool {
        var index = range.upperBound
        var gap = 0
        while index < window.upperBound {
            let character = line[index]
            guard gap < maximumCutGap, !character.isLetter, !character.isNumber else { return false }
            gap += 1
            index = line.index(after: index)
        }
        return true
    }

    /// The numbers held back, finished by reading `window` (the window after the one that held them, which is otherwise
    /// not read) for them alone, as far as a number that goes on from them can reach: each match there that overlaps one
    /// of them, and each held number that none of those covers, as it is.
    private static func finished(_ heldBack: [PhoneMatch], readingAgain window: Range<String.Index>, of line: String)
        -> [Range<String.Index>]
    {
        guard let last = heldBack.last else { return [] }
        let reach = line.index(last.range.upperBound, offsetBy: phoneWindowOverlap, limitedBy: window.upperBound) ?? window.upperBound
        let finishing = phoneMatches(in: window.lowerBound..<reach, of: line, isLastWindow: true).whole.filter { match in
            heldBack.contains { $0.range.overlaps(match.range) }
        }
        return reported(finishing, in: line) + reported(notCovered(heldBack, by: finishing.map(\.range)), in: line)
    }

    /// The matches of `heldBack` that none of `later` covers whole.
    private static func notCovered(_ heldBack: [PhoneMatch], by later: [Range<String.Index>]) -> [PhoneMatch] {
        heldBack.filter { held in !later.contains { $0.lowerBound <= held.range.lowerBound && held.range.upperBound <= $0.upperBound } }
    }

    /// The numbers to report for `matches`: each continued, and only those that are phone numbers.
    private static func reported(_ matches: [PhoneMatch], in line: String) -> [Range<String.Index>] {
        matches.map { continued($0.range, before: $0.nextStart, in: line) }.filter { isPhoneNumber($0, in: line) }
    }

    /// `range` with what goes on after it: digits, and a separator of up to `maximumCutGap` spaces and punctuation between
    /// digits, up to `limit` (where the next number starts). The data detector stops a number grouped by spaces one group
    /// early when the last group is glued to a character it doesn't expect (`+44 20 7946 0958•`, `06 12 34 56 78·`), and a
    /// window can cut a number off (`202-555-01` and the edge); either way the rest is part of it. A full stop and a space
    /// part groups like any other separator (`+1 202 555. 0143`), at the price of a number that ends a sentence taking the
    /// digit that starts the next (`call 202-555-0143. 5 rings`): a mask may cover a little more, never leave a group readable.
    private static func continued(_ range: Range<String.Index>, before limit: String.Index?, in line: String) -> Range<String.Index> {
        func isDigit(_ character: Character) -> Bool { character.isASCII && character.isNumber }
        let last = limit ?? line.endIndex
        var end = range.upperBound
        var taken = 0
        while end < last, taken < phoneWindowOverlap {
            if isDigit(line[end]) {
                end = line.index(after: end)
                taken += 1
                continue
            }
            var next = end
            var separators = 0
            while next < last, separators < maximumCutGap, phoneSeparators.contains(line[next]) {
                next = line.index(after: next)
                separators += 1
            }
            guard separators > 0, next < last, isDigit(line[next]) else { break }
            end = next
            taken += separators
        }
        return range.lowerBound..<end
    }

    /// What parts the groups of a phone number.
    private static let phoneSeparators: Set<Character> = [" ", "\u{00A0}", "-", "‐", "–", ".", "(", ")", "/"]

    /// Whether a match of the data detector is a phone number to us: 7 digits or more, not part of a row of short numbers,
    /// not a signed decimal.
    private static func isPhoneNumber(_ range: Range<String.Index>, in line: String) -> Bool {
        line[range].count(where: { $0.isASCII && $0.isNumber }) >= minimumPhoneDigits
            && !isPartOfARowOfShortNumbers(range, in: line) && !isSignedDecimal(range, in: line)
    }

    private static func hasDigits(_ text: some StringProtocol, atLeast count: Int) -> Bool {
        var seen = 0
        for character in text where character.isASCII && character.isNumber {
            seen += 1
            if seen == count { return true }
        }
        return false
    }

    /// Whether `range` (a match of the data detector) is, or is part of, a row of short numbers: groups of one or two
    /// digits, parted by spaces, six or more of them ("12 13 14 15 16 17 18"). The detector cuts a long row into pieces of
    /// seven groups, and the last may be four, so the row is measured around the match, not just in it. Not a row if it
    /// starts with a `0` (as "01 23 45 67 89" does), and a match with a longer group or a `+` in it isn't made of short
    /// groups at all.
    private static func isPartOfARowOfShortNumbers(_ range: Range<String.Index>, in line: String) -> Bool {
        let groups = line[range].split(whereSeparator: \.isWhitespace)
        guard groups.allSatisfy(isShortNumber) else { return false }
        var count = groups.count
        var first = groups[0]
        // The short numbers before it, then the ones after it, up to a reach that is plainly a table.
        var position = range.lowerBound
        while count < maximumRowReach, let token = token(endingAt: position, in: line), isShortNumber(token) {
            count += 1
            first = token
            position = token.startIndex
        }
        position = range.upperBound
        while count < maximumRowReach, let token = token(startingAt: position, in: line), isShortNumber(token) {
            count += 1
            position = token.endIndex
        }
        return count >= shortGroupsInARow && (count >= maximumRowReach || !first.hasPrefix("0"))
    }

    private static let maximumRowReach = 64

    private static func isShortNumber(_ text: Substring) -> Bool {
        (1...2).contains(text.count) && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The word (a run of characters that aren't spaces) that ends at `position`, past any spaces before it.
    private static func token(endingAt position: String.Index, in line: String) -> Substring? {
        var end = position
        while end > line.startIndex, line[line.index(before: end)].isWhitespace { end = line.index(before: end) }
        var start = end
        while start > line.startIndex, !line[line.index(before: start)].isWhitespace { start = line.index(before: start) }
        return start < end && end < position ? line[start..<end] : nil
    }

    /// The word that starts at `position`, past any spaces.
    private static func token(startingAt position: String.Index, in line: String) -> Substring? {
        var start = position
        while start < line.endIndex, line[start].isWhitespace { start = line.index(after: start) }
        var end = start
        while end < line.endIndex, !line[end].isWhitespace { end = line.index(after: end) }
        return start < end && start > position ? line[start..<end] : nil
    }

    /// A decimal with a minus sign before it is a coordinate or a measurement. The data detector reads its digits as a
    /// number and leaves the sign out of the range, so the character before the range is looked at.
    private static func isSignedDecimal(_ range: Range<String.Index>, in line: String) -> Bool {
        guard let before = line[..<range.lowerBound].last, before == "-" || before == "\u{2212}" else { return false }
        let parts = line[range].split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
}
