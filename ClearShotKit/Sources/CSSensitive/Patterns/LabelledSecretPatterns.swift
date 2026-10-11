import Foundation

/// The values of labelled secrets: `password: …`, `API_KEY=…`, `"token": "…"`. Only the value is the finding.
///
/// How far a value goes is a guess about the text around it, and a guess that stops early leaves part of a secret readable,
/// so the rules lean towards taking too much:
///
/// - a **quoted** value is what's between the quotes; a quote with a backslash before it doesn't close it, nor does a
///   doubled single quote (`'it''s'`, as YAML writes one); and if more than closing punctuation is glued after the closing
///   quote (`"hun"ter2`), the value runs on to the next space;
/// - after `passphrase`, and after any label that starts a line (after spaces, quotes, `export`, and the marks that start a
///   comment, a list item, a quotation, a prompt, a table row or a numbered line), the value is **the rest of the line**,
///   because a passphrase is words, and a line that starts with a label is a setting, which a UI's help text
///   ("Password: Must be 8 characters") also looks like;
/// - elsewhere the value is the **first word**, up to a space, and up to an `&` only where it starts the next field of a
///   query string (`&user=`) or the label itself is in one (`?token=…&…`); but a first word too short to be a secret
///   ("Password: my secret pass") is the start of a value of several words, which runs to the end of the line or to the
///   next label.
///
/// A value is scanned by Unicode scalars, which is several times quicker than by Characters, and its ends are taken outward
/// to Character edges by the detector.
enum LabelledSecretPatterns {
    /// A word that labels a secret (the first group), a separator, and the spaces after it. The word may sit inside a name
    /// (`GITHUB_TOKEN`, `clientSecret`, `aws_secret_access_key`, `PASSWORD_FOR_DB_PROD_1`), may have digits after it
    /// (`password1`), may be quoted (`"password": …`), and may be followed by `=>` as well as `:` or `=`. `API key` may have
    /// a space. A word that goes on into letters ("secretary") isn't one. Markdown's bold (`**` or `__`, and `*` or `***`)
    /// around the label, before or after its separator, is the label's: `**Password:** value`, `**Password**: value`.
    private static let label = NSRegularExpression.fixed(
        #"(passwords?|passwd|pwd|passphrase|private[ _-]?key|secret|token|api[ _-]?key)[0-9]*+(?:[_.\-][A-Za-z0-9]++){0,8}(?:\*{1,3}|_{2,3})?["'’”]?\s*(?:=>|[:=])(?:(?:\*{1,3}|_{2,3})(?=\s|$))?\s*"#,
        caseInsensitive: true)

    /// A value shorter than this isn't taken for a secret: `token: {`, `secret: -`.
    static let minimumValueLength = 3
    /// A value is read this far at most: a password isn't longer.
    static let maximumValueLength = 1_024
    /// How far back a label's name (`GITHUB_TOKEN`) is looked for, and how many marks (characters that aren't spaces) may
    /// come before it on its line for it to start the line.
    private static let maximumNameLength = 64

    /// The quotes a value may be in, and the character that closes each.
    private static let closingQuote: [Unicode.Scalar: Unicode.Scalar] = [
        "\"": "\"", "'": "'", "`": "`", "“": "”", "‘": "’", "«": "»",
    ]
    /// What a value in a sentence is followed by but doesn't hold.
    private static let trailingPunctuation: Set<Unicode.Scalar> = [",", ";", "."]
    /// What may follow a closing quote and close the field or the sentence around it (`",`, `"}`, `".`), rather than go on
    /// with the value.
    private static let closingPunctuation: Set<Unicode.Scalar> = [
        ",", ";", ".", ":", "!", "?", ")", "]", "}", ">", "\"", "'", "`", "”", "’", "»",
    ]
    /// What a hidden password is drawn with.
    private static let maskCharacters: Set<Unicode.Scalar> = ["*", "•", "●", "·", "∙"]

    /// What may come before a label's name for it to start its line: spaces, quotes, `export`, and marks: a comment (`#`,
    /// `//`, `;`), a list item (`-`, `*`, `•`, `+`, `1.`, `12)`), a quotation (`>`), a prompt (`$`, `%`), a table row (`|`), a
    /// section (`[db]`), a line number (`12` and spaces).
    private static let lineStart = NSRegularExpression.fixed(
        #"\A(?:[\s"'`“”‘’«»]|[0-9]+(?=[ \t])|[0-9]{1,3}[.)](?=\s)|\[[^\]]{1,40}\]|#+|//+|;+|[-*•+]+|>+|[$%]|\|)*+(?:export\s++(?:[\s"'`“”‘’«»])*+)?\z"#,
        caseInsensitive: true)

    /// A label found in a line: its keyword, the whole match (up to where the value starts), and where its name starts.
    private struct Label {
        let keyword: Range<String.Index>, whole: Range<String.Index>, name: String.Index
    }

    /// The value of every labelled secret in `line`.
    static func values(in line: String) -> [Range<String.Index>] {
        let labels = label.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match -> Label? in
            guard let keyword = Range(match.range(at: 1), in: line), let whole = Range(match.range, in: line) else { return nil }
            return Label(keyword: keyword, whole: whole, name: nameStart(before: keyword.lowerBound, in: line))
        }
        return labels.indices.compactMap { index in
            let label = labels[index]
            let restOfLine = line[label.keyword].lowercased() == "passphrase" || startsLine(at: label.name, in: line)
            let inQuery = label.name > line.startIndex && ["?", "&"].contains(line[line.index(before: label.name)])
            let nextLabel = index + 1 < labels.count ? labels[index + 1].name : nil
            return value(in: line, from: label.whole.upperBound, restOfLine: restOfLine, inQuery: inQuery, nextLabel: nextLabel)
        }
    }

    // MARK: Where the label is

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "." || character == "-"
    }

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_" || scalar == "." || scalar == "-"
    }

    /// Where the name that holds the label starts (`GITHUB_TOKEN`'s `G`): back over letters, digits, `_`, `.` and `-`.
    private static func nameStart(before keyword: String.Index, in line: String) -> String.Index {
        var start = keyword
        var length = 0
        while start > line.startIndex, length < maximumNameLength, isNameCharacter(line[line.index(before: start)]) {
            start = line.index(before: start)
            length += 1
        }
        return start
    }

    /// Whether only what `lineStart` allows comes before `name` on its line. Spaces don't count towards the cap, however
    /// many there are (an indented line, a comment aligned far to the right); a prefix with more than `maximumNameLength`
    /// marks is not one.
    private static func startsLine(at name: String.Index, in line: String) -> Bool {
        let scalars = line.unicodeScalars
        var index = name
        var marks = 0
        while index > scalars.startIndex {
            index = scalars.index(before: index)
            if !isSpace(scalars[index]) {
                marks += 1
                if marks > maximumNameLength { return false }
            }
        }
        let prefix = String(line[..<name])
        return lineStart.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) != nil
    }

    // MARK: The value

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII ? scalar == " " || (scalar.value >= 9 && scalar.value <= 13) : scalar.properties.isWhitespace
    }

    /// The value that starts at `start`, or nil if there's none, it's too short, or it's only dots drawn for a hidden
    /// password. `nextLabel` is where the next label on the line starts, if there's one.
    private static func value(in line: String, from start: String.Index, restOfLine: Bool, inQuery: Bool, nextLabel: String.Index?)
        -> Range<String.Index>?
    {
        let scalars = line.unicodeScalars
        guard start < scalars.endIndex, scalars[start] != "=" else { return nil }
        /// The end of a value without quotes (or whose closing quote is lost) that starts at `from`.
        func unquotedEnd(from: String.Index) -> String.Index {
            if restOfLine { return endOfLine(from: from, in: scalars) }
            let word = endOfWord(from: from, in: scalars, inQuery: inQuery)
            // A first word too short to be a secret, in the middle of a line ("Password: my secret pass"), starts a value of
            // several words: it runs to the end of the line, or to the next label, as at the start of one. (Not in a query
            // string, where a value has no spaces, and not where the word ended at the next field.)
            guard !inQuery, !word.endedAtAField, scalars.distance(from: from, to: word.end) < minimumValueLength else { return word.end }
            let limit = nextLabel.flatMap { $0 > word.end ? $0 : nil }
            return max(word.end, endOfLine(from: from, in: scalars, before: limit))
        }
        var valueStart = start
        var end: String.Index
        var quoted = false
        if let close = closingQuote[scalars[start]] {
            quoted = true
            valueStart = scalars.index(after: start)
            if let closing = closingQuote(close, in: scalars, from: valueStart) {
                end = endAfterClosingQuote(closing, in: scalars)
            } else {
                // The closing quote was lost (OCR), or isn't near: the value is read as if it had no quote.
                end = unquotedEnd(from: valueStart)
            }
        } else {
            end = unquotedEnd(from: start)
        }
        let value = scalars[valueStart..<end]
        guard value.count >= minimumValueLength, !isOnlyMask(value, quoted: quoted) else { return nil }
        return valueStart..<end
    }

    /// Where a quoted value ends whose closing quote is at `closing`: there, unless more than closing punctuation is glued
    /// after the quote (`"hun"ter2`: a quote inside the value, or one OCR put there), and then at the next space, without
    /// the punctuation of the sentence it's in.
    private static func endAfterClosingQuote(_ closing: String.Index, in scalars: String.UnicodeScalarView) -> String.Index {
        var end = scalars.index(after: closing)
        var length = 0
        var goesOn = false
        while end < scalars.endIndex, length < maximumValueLength, !isSpace(scalars[end]) {
            if !closingPunctuation.contains(scalars[end]) { goesOn = true }
            end = scalars.index(after: end)
            length += 1
        }
        guard goesOn else { return closing }
        while trailingPunctuation.contains(scalars[scalars.index(before: end)]) { end = scalars.index(before: end) }
        return end
    }

    /// Whether a value is mask characters, and not a secret. A quoted value is one only if all of it is; an unquoted one,
    /// whose end is a guess ("•••• Show"), if its first word is.
    private static func isOnlyMask(_ value: Substring.UnicodeScalarView, quoted: Bool) -> Bool {
        let characters = value.filter { !isSpace($0) }
        if quoted { return characters.allSatisfy(maskCharacters.contains) }
        var firstWord = value.drop(while: isSpace)
        firstWord = firstWord.prefix(while: { !isSpace($0) })
        return firstWord.allSatisfy(maskCharacters.contains)
    }

    /// The quote that closes a value that starts at `from`: the next `close` that no backslash escapes (and, for `'`, that
    /// isn't doubled), within the cap.
    private static func closingQuote(_ close: Unicode.Scalar, in scalars: String.UnicodeScalarView, from: String.Index) -> String.Index? {
        var index = from
        var length = 0
        while index < scalars.endIndex, length < maximumValueLength {
            let scalar = scalars[index]
            if scalar == "\\" {
                // The next character is escaped, whatever it is (a quote, or another backslash).
                index = scalars.index(after: index)
                length += 1
                if index == scalars.endIndex { return nil }
            } else if scalar == close {
                let next = scalars.index(after: index)
                if close == "'", next < scalars.endIndex, scalars[next] == "'" {
                    index = next
                    length += 1
                } else {
                    return index
                }
            }
            index = scalars.index(after: index)
            length += 1
        }
        return nil
    }

    /// The end of the line (or `limit`, if it comes first), or the cap, without the spaces at its end.
    private static func endOfLine(from start: String.Index, in scalars: String.UnicodeScalarView, before limit: String.Index? = nil)
        -> String.Index
    {
        let last = limit ?? scalars.endIndex
        var end = scalars.index(start, offsetBy: maximumValueLength, limitedBy: last) ?? last
        while end > start, isSpace(scalars[scalars.index(before: end)]) { end = scalars.index(before: end) }
        return end
    }

    /// The end of the first word: at a space, or at an `&` that starts the next field of a query string (or any `&`, if the
    /// label is in one), without the punctuation of the sentence it's in. And whether it ended at such an `&`.
    private static func endOfWord(from start: String.Index, in scalars: String.UnicodeScalarView, inQuery: Bool)
        -> (end: String.Index, endedAtAField: Bool)
    {
        var end = start
        var length = 0
        var endedAtAField = false
        while end < scalars.endIndex, length < maximumValueLength {
            let scalar = scalars[end]
            if isSpace(scalar) { break }
            if scalar == "&", inQuery || startsQueryField(after: end, in: scalars) {
                endedAtAField = true
                break
            }
            end = scalars.index(after: end)
            length += 1
        }
        while end > start, trailingPunctuation.contains(scalars[scalars.index(before: end)]) { end = scalars.index(before: end) }
        return (end, endedAtAField)
    }

    /// Whether the `&` at `ampersand` starts a field of a query string: a name, then `=`.
    private static func startsQueryField(after ampersand: String.Index, in scalars: String.UnicodeScalarView) -> Bool {
        var index = scalars.index(after: ampersand)
        var length = 0
        while index < scalars.endIndex, length < maximumNameLength, isNameScalar(scalars[index]) {
            index = scalars.index(after: index)
            length += 1
        }
        return length > 0 && index < scalars.endIndex && scalars[index] == "="
    }
}
