import Foundation

/// Where a private key's block lies among the lines of a screenshot, in reading order: the header, the key's body and the
/// END line.
///
/// The detector flags a header and nothing else (the body's lines are base64, which can't be told from a long word on
/// their own), so the scanner takes the block from the header through the lines that follow it, up to and including the END
/// line, and stops at the first line that is neither. A key pasted as one JSON or `.env` string (`"private_key":
/// "-----BEGIN PRIVATE KEY-----\nMIIE…\n-----END PRIVATE KEY-----\n"`) is wrapped by the screen at arbitrary points, so
/// no line can be judged alone:
/// - a line ending in a backslash goes on with the next, which starts with the `n` of the escape;
/// - a header or an END marker can be split across up to `maximumSplit` lines, at a space (`-----END RSA PRIVATE` |
///   `KEY-----`) or inside a word (`-----` | `END PRIVATE KEY-----`): the lines are tried joined with a space and without
///   at each break;
/// - a body line may hold `\n` escapes and quotes and commas (a key written as an array of strings);
/// - a short line of base64, straight above the END line, is the key's last line;
/// - OCR reads a rendered backslash as a bar (`|n` for `\n`) as often as it reads it, so inside a block a bar counts as the
///   backslash, and a dash run the wrap broke after the header goes on at the start of the next line;
/// - OCR also reads a character of a key wrongly (a symbol for a letter, a space put inside a long run), and one such line must
///   not end the block with the rest of the key left readable: a body line may have a space (with 8 characters or more on
///   each side) and up to two characters that aren't base64, and the text before an END marker up to two. Prose, with its
///   words and spaces, is still not a body line;
/// - an END line is any line with the marker after key material alone, whatever follows it (the closing quote, the next
///   JSON field), so that the last of the key, glued to the marker, is masked with it.
///
/// Pure: lines in, line numbers out. Nothing a line says is kept.
enum PrivateKeyBlocks {
    struct Block: Equatable {
        /// The lines the header is on: one, or the lines it is split across.
        let header: ClosedRange<Int>
        /// The block's last line: its END line, or its last line of key when the key has none.
        let last: Int

        /// Every line of the block, the header's first to the last.
        var lines: ClosedRange<Int> { header.lowerBound...last }
    }

    /// The most lines a header or an END marker is looked for across: `-----BEGIN PGP PRIVATE KEY BLOCK-----` is five
    /// words.
    static let maximumSplit = 5

    /// The blocks among `lines`, in order. A line of a block is never in another.
    static func blocks(in lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var index = 0
        while index < lines.count {
            guard let header = header(startingAt: index, in: lines) else {
                index += 1
                continue
            }
            let last = lastLine(of: header, in: lines)
            blocks.append(Block(header: header.lines, last: last))
            index = last + 1
        }
        return blocks
    }

    // MARK: The header

    private struct Header {
        let lines: ClosedRange<Int>
        /// What follows the header on its last line (the start of the key, usually).
        let rest: String
        /// Whether an END marker follows the header in the same lines: the whole key is there.
        let holdsEnd: Bool
    }

    /// The header that starts on line `first`, if one does: complete on the line, or made whole by the lines after it.
    private static func header(startingAt first: Int, in lines: [String]) -> Header? {
        for count in 1...min(maximumSplit, lines.count - first) {
            // A header split across lines starts on a line that has BEGIN, or the start of it at the end, or a run of dashes.
            if count > 1, !mayStartSplitHeader(lines[first]) { break }
            let window = Array(lines[first..<first + count])
            for text in joinings(of: window) {
                let firstLineEnd = String.Index(utf16Offset: window[0].utf16.count, in: text)
                for match in PrivateKeyBlockPatterns.headerRanges(in: text)
                where match.lowerBound < firstLineEnd && (count == 1 || match.upperBound > firstLineEnd) {
                    let holdsEnd = PrivateKeyBlockPatterns.endMarkerRanges(in: text).contains { $0.lowerBound >= match.upperBound }
                    return Header(lines: first...first + count - 1, rest: String(text[match.upperBound...]), holdsEnd: holdsEnd)
                }
            }
        }
        return nil
    }

    private static func mayStartSplitHeader(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.contains("BEGIN") || text.last.map(isDash) == true { return true }
        return ["B", "BE", "BEG", "BEGI"].contains { text.hasSuffix($0) }
    }

    // MARK: The body and the END line

    /// The last line of the block that `header` starts.
    private static func lastLine(of header: Header, in lines: [String]) -> Int {
        var last = header.lines.upperBound
        if header.holdsEnd { return last }
        // An END marker that begins on the header's line, after the start of the key, and ends on the lines below.
        if header.rest.contains("END") {
            for count in stride(from: 2, through: maximumSplit, by: 1) where last + count - 1 < lines.count {
                let window = [header.rest] + Array(lines[(last + 1)...(last + count - 1)])
                if joinings(of: window).contains(where: isEnd) { return last + count - 1 }
            }
        }
        // A header that ends its line may have had its dashes broken by the wrap: they go on at the start of the next one.
        var dashes = header.rest.trimmingCharacters(in: .whitespaces).isEmpty
        var position = last + 1
        while position < lines.count {
            if let count = endLines(at: position, in: lines) { return position + count - 1 }
            guard isBody(lines[position], dashes: dashes) || isLastLineOfKey(at: position, dashes: dashes, in: lines) else { break }
            last = position
            dashes = false
            position += 1
        }
        return last
    }

    /// How many lines, from `position`, make an END line (one, or the lines an END marker is split across).
    private static func endLines(at position: Int, in lines: [String]) -> Int? {
        for count in 1...min(maximumSplit, lines.count - position) {
            if joinings(of: Array(lines[position..<position + count])).contains(where: isEnd) { return count }
        }
        return nil
    }

    /// Whether `text` ends the key: an END line, or a line with the marker after key material alone, whatever follows it.
    private static func isEnd(_ text: String) -> Bool {
        let text = normalized(text)
        if SensitiveDetector.isPrivateKeyEndLine(text) { return true }
        guard let marker = PrivateKeyBlockPatterns.endMarkerRanges(in: text).first else { return false }
        let before = withoutEscapes(String(text[..<marker.lowerBound]))
        return !before.contains(where: \.isWhitespace)
            && before.filter { $0.asciiValue.map(isBase64) != true }.count <= mistakesAllowed
    }

    /// Whether `line` is a line of the key's body, once its quotes, commas and `\n` escapes are put aside, and a backslash at
    /// its end (half an escape the next line finishes). With `dashes`, a dash run at its start goes on from the header.
    private static func isBody(_ line: String, dashes: Bool) -> Bool {
        let material = keyMaterial(line, dashes: dashes)
        return SensitiveDetector.isPrivateKeyBodyLine(material) || isBodyReadWithMistakes(material)
    }

    /// The most characters that aren't base64 that a line or an END line's start may have, for OCR's mistakes.
    private static let mistakesAllowed = 2
    /// The least a piece of a body line holds on each side of a space OCR put in it.
    private static let shortestPiece = 8

    /// Whether `piece` has what a run of a key has and two ordinary words don't: a digit, a `+` or a `/`, or a capital letter
    /// inside it (random base64 of 8 characters has none of them for about 1 run in 670, of 9 for about 1 in 1 700, and only
    /// from 10 for 1 run in several thousand; "Additional" and "information" have none, a capital that starts a word not
    /// counting).
    private static func hasKeyCharacters(_ piece: Substring) -> Bool {
        piece.enumerated().contains { index, character in
            guard character.isASCII else { return false }
            return character.isNumber || character == "+" || character == "/" || (index > 0 && character.isUppercase)
        }
    }

    /// Whether `material` is a body line with a mistake or two of OCR in it: at most one space, with `shortestPiece` characters
    /// or more on each side, at most `mistakesAllowed` characters that aren't base64, and what a key's characters have
    /// (`hasKeyCharacters`); with the mistakes taken out, a body line.
    private static func isBodyReadWithMistakes(_ material: String) -> Bool {
        let pieces = material.split(separator: " ", omittingEmptySubsequences: false)
        guard pieces.count <= 2, pieces.allSatisfy({ $0.count >= shortestPiece }), pieces.contains(where: hasKeyCharacters) else {
            return false
        }
        let characters = pieces.joined()
        let kept = characters.filter { $0.asciiValue.map(isBase64) == true }
        guard characters.count - kept.count <= mistakesAllowed else { return false }
        return SensitiveDetector.isPrivateKeyBodyLine(String(kept))
    }

    /// A line of base64 of any length, straight above the END line: the last line of a key is as long as what is left.
    private static func isLastLineOfKey(at position: Int, dashes: Bool, in lines: [String]) -> Bool {
        let material = keyMaterial(lines[position], dashes: dashes)
        guard !material.isEmpty, material.utf8.allSatisfy(isBase64), position + 1 < lines.count else { return false }
        return endLines(at: position + 1, in: lines) != nil
    }

    /// What a line holds of the key: its text with quotes and commas taken out, the dashes of the header's run (if it goes
    /// on) and a backslash at the end (half an escape the next line finishes) dropped, and every `\n` escape taken out, so the
    /// base64 around the escapes runs together.
    private static func keyMaterial(_ line: String, dashes: Bool) -> String {
        var text = normalized(line)
        if dashes { text = String(text.drop { isDash($0) }) }
        return withoutEscapes(text)
    }

    /// `text` without its `\n` escapes, and without a backslash at its end.
    private static func withoutEscapes(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\\n", with: "")
        if text.hasSuffix("\\") { text.removeLast() }
        return text
    }

    private static func isDash(_ character: Character) -> Bool {
        character == "\u{2212}" || character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .dashPunctuation }
    }

    /// Base64's characters, and the `=` that pads it.
    private static func isBase64(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "="):
            true
        default:
            false
        }
    }

    // MARK: Lines put together

    private static let quotesAndCommas: Set<Character> = ["\"", "'", "`", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", ","]

    /// `text` without its quotes and commas (the string quotes and separators of a key written as JSON), a bar read for the
    /// backslash it is (OCR's commonest mistake for one), and without white space at either end.
    private static func normalized(_ text: String) -> String {
        var result = ""
        for character in text where !quotesAndCommas.contains(character) {
            result.append(character == "|" ? "\\" : character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func endsWithBackslash(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).hasSuffix("\\")
    }

    /// The lines of `window` put together every way a screen's wrap could have broken them: at each break, a space the wrap
    /// took, or nothing (a word broken by the width). A line that ends in a backslash is always followed by nothing, the `n`
    /// of its escape.
    private static func joinings(of window: [String]) -> [String] {
        guard window.count > 1 else { return [window[0]] }
        let free = (0..<window.count - 1).filter { !endsWithBackslash(window[$0]) }
        return (0..<(1 << free.count)).map { choice in
            var text = window[0]
            for boundary in 0..<window.count - 1 {
                let spaced = free.firstIndex(of: boundary).map { (choice >> $0) & 1 == 1 } ?? false
                text += (spaced ? " " : "") + window[boundary + 1]
            }
            return text
        }
    }
}
