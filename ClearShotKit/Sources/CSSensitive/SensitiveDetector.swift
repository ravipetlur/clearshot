/// Finds the sensitive spans of a line of text: email addresses and phone numbers, the well-known formats of keys and
/// tokens, payment card numbers and IP addresses.
///
/// Pure: a line in, the ranges out. Detection runs on the Mac and nothing is logged, least of all what was matched.
public enum SensitiveDetector {
    /// The findings in `line` for the kinds asked, sorted by where they start. Findings that overlap are merged into one
    /// over both spans, named for the most specific kind (a key or token before a card number, before an address, before
    /// a contact detail).
    ///
    /// The kinds are filtered before the merge, so a kind that is off never hides one that is on: with only contact
    /// details on, the email in "password: jane@example.com" is found.
    public static func findings(in line: String, kinds: SensitiveKinds) -> [TextFinding] {
        guard !line.isEmpty, !kinds.isEmpty else { return [] }
        var spans: [TextFinding] = []
        func add(_ kind: SensitiveKind, _ ranges: [Range<String.Index>]) {
            spans += ranges.map { alignedToCharacters(TextFinding(kind: kind, range: $0), in: line) }
        }
        if kinds.contains(.contact) { add(.contact, ContactPatterns.spans(in: line)) }
        if kinds.contains(.keysAndTokens) { add(.keyOrToken, KeyAndTokenPatterns.spans(in: line)) }
        if kinds.contains(.cards) { add(.card, CardPatterns.spans(in: line)) }
        if kinds.contains(.ipAddresses) { add(.ipAddress, IPAddressPatterns.spans(in: line)) }
        return merged(spans)
    }

    /// `finding` with its range taken outward to the edges of the Characters it touches. A pattern works on the text's
    /// UTF-16, so a span can end between a letter and the accent that follows it, or a digit and its emoji selector, and
    /// then isn't a range of whole Characters, which is what anything that boxes the text, or cuts it, needs.
    static func alignedToCharacters(_ finding: TextFinding, in line: String) -> TextFinding {
        let lower = line.characterEdge(roundingDown: finding.range.lowerBound)
        let upper = line.characterEdge(roundingUp: finding.range.upperBound)
        return TextFinding(kind: finding.kind, range: lower..<upper)
    }

    /// `spans` by where they start, with the ones that overlap (share at least a character) made one: over the union of
    /// the two, of the more specific kind. Spans that only touch stay apart.
    static func merged(_ spans: [TextFinding]) -> [TextFinding] {
        let ordered = spans.sorted { first, second in
            first.range.lowerBound != second.range.lowerBound
                ? first.range.lowerBound < second.range.lowerBound
                : first.range.upperBound > second.range.upperBound
        }
        var result: [TextFinding] = []
        for span in ordered {
            guard let last = result.last, span.range.lowerBound < last.range.upperBound else {
                result.append(span)
                continue
            }
            let kind = span.kind.specificity > last.kind.specificity ? span.kind : last.kind
            result[result.count - 1] = TextFinding(kind: kind, range: last.range.lowerBound..<max(last.range.upperBound, span.range.upperBound))
        }
        return result
    }

    /// Whether `line` is a line of a private key's body: base64 only, 16 characters or more, up to two `=` at the end, no
    /// spaces, and not just hex digits. On its own it proves nothing (a long word is one), so it is never a finding: the
    /// scanner uses it to take a private-key header over the lines that follow, up to the END line.
    public static func isPrivateKeyBodyLine(_ line: String) -> Bool {
        PrivateKeyBlockPatterns.isBodyLine(line)
    }

    /// Whether `line` is the END line of a private-key block: `END`, the key's kind and `PRIVATE KEY`, with or without
    /// the dashes around them, and nothing else on the line.
    public static func isPrivateKeyEndLine(_ line: String) -> Bool {
        PrivateKeyBlockPatterns.isEndLine(line)
    }
}

private extension String {
    /// `index`, or the start of the Character it is inside.
    func characterEdge(roundingDown index: Index) -> Index {
        index == endIndex ? index : self.index(before: self.index(after: index))
    }

    /// `index`, or the end of the Character it is inside.
    func characterEdge(roundingUp index: Index) -> Index {
        characterEdge(roundingDown: index) == index ? index : self.index(after: index)
    }
}
