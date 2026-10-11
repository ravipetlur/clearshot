import Foundation

/// A private key's block, as it reads on a screen:
///
///     -----BEGIN RSA PRIVATE KEY-----
///     <lines of base64>
///     -----END RSA PRIVATE KEY-----
///
/// or, in a JSON or `.env` file, on one line, with a backslash and an `n` where the lines break:
///
///     "private_key": "-----BEGIN PRIVATE KEY-----\nMIIE…\n…\n-----END PRIVATE KEY-----\n"
///
/// The header is a finding, and takes in whatever key material follows it on its line (`spans`). The body's lines are base64
/// and nothing else, so on their own they can't be told from a long word: they are never findings, and the scanner takes
/// them with the header, up to the END line, using `isBodyLine` and `isEndLine`.
enum PrivateKeyBlockPatterns {
    /// Any dash, whatever its width: OCR turns `-----` into `—–—`, and drops some.
    private static let dash = #"[\p{Pd}−]"#
    /// The words of the header's second part, after BEGIN or END: the key's kind (RSA, EC, OPENSSH, PGP...), PRIVATE
    /// KEY, and for PGP, BLOCK. Upper case, as the format writes them: "to begin private key rotation" isn't a header.
    private static func words(_ keyword: String) -> String {
        keyword + #"\s++(?:[A-Z0-9]++\s++){0,3}?PRIVATE\s++KEY(?:\s++BLOCK)?"#
    }

    /// The header line: BEGIN, the words, with or without the dashes around them. A run of dashes is only tried from its
    /// start, so a long one is read once, not once for every dash in it.
    private static let header = NSRegularExpression.fixed(
        "(?:(?<!" + dash + ")" + dash + #"++\s*+)?(?<![A-Za-z0-9])"# + words("BEGIN") + #"(?:\s*+"# + dash + "++)?")

    /// An END marker, anywhere.
    private static let endMarker = NSRegularExpression.fixed(
        "(?:(?<!" + dash + ")" + dash + #"++\s*+)?(?<![A-Za-z0-9])"# + words("END") + #"(?:\s*+"# + dash + "++)?")

    /// Where the headers are in `text`, which may be several lines of a screenshot put together (`PrivateKeyBlocks`).
    static func headerRanges(in text: String) -> [Range<String.Index>] { header.ranges(in: text) }

    /// Where the END markers are in `text`.
    static func endMarkerRanges(in text: String) -> [Range<String.Index>] { endMarker.ranges(in: text) }

    // MARK: The header and the key on its line

    /// The headers in `line`, each taken over the key material that follows it on the line:
    ///
    /// - what is glued to the header (`-----BEGIN PRIVATE KEY-----\nMIIE…`), whatever it is, up to a space or a quote;
    /// - then, past spaces, each word that is a line of a key's body (a PEM whose newlines became spaces);
    /// - and an END marker on the line, which has spaces inside it, and what is glued to it (the `\n` after it).
    ///
    /// It stops at a quote (the one that closes a JSON string or a `.env` value, which isn't part of the key) and at any
    /// other word. A header inside a key already taken isn't looked at again.
    static func spans(in line: String) -> [Range<String.Index>] {
        let headers = header.ranges(in: line)
        guard !headers.isEmpty else { return [] }
        // The END markers of the line, found once: each header looks for the first one after it.
        let markers = endMarker.ranges(in: line)
        var spans: [Range<String.Index>] = []
        var takenUntil = line.startIndex
        for header in headers where header.lowerBound >= takenUntil {
            let span = header.lowerBound..<materialEnd(after: header.upperBound, in: line, markers: markers)
            spans.append(span)
            takenUntil = span.upperBound
        }
        return spans
    }

    private static func isQuote(_ character: Character) -> Bool { "\"'`“”‘’".contains(character) }

    /// The end of the run of characters at `start` that isn't a space or a quote.
    private static func endOfRun(from start: String.Index, in line: String) -> String.Index {
        var end = start
        while end < line.endIndex, !line[end].isWhitespace, !isQuote(line[end]) { end = line.index(after: end) }
        return end
    }

    /// How far an END marker is looked for when the key's own lines have run out (a short last line, a word that isn't one).
    private static let endMarkerSearchReach = 8_192

    /// The first of `markers` (in order) that starts at or after `position`.
    private static func firstMarker(atOrAfter position: String.Index, in markers: [Range<String.Index>]) -> Range<String.Index>? {
        var low = 0, high = markers.count
        while low < high {
            let middle = (low + high) / 2
            if markers[middle].lowerBound < position { low = middle + 1 } else { high = middle }
        }
        return low < markers.count ? markers[low] : nil
    }

    /// The end of the key material that follows a header that ends at `headerEnd`.
    private static func materialEnd(after headerEnd: String.Index, in line: String, markers: [Range<String.Index>]) -> String.Index {
        var end = headerEnd
        var glued = true
        while true {
            // The next word: at once after the header, then after spaces.
            var start = end
            if !glued { while start < line.endIndex, line[start].isWhitespace { start = line.index(after: start) } }
            let wordEnd = endOfRun(from: start, in: line)
            if wordEnd == start, glued {
                // Nothing is glued to the header: the key may still follow, after a space.
                glued = false
                continue
            }
            guard wordEnd > start else { return end }
            // An END marker that starts in this word: it runs on past the word, because of the spaces in "END PRIVATE KEY".
            if let marker = firstMarker(atOrAfter: start, in: markers), marker.lowerBound < wordEnd {
                return endOfRun(from: marker.upperBound, in: line)
            }
            guard glued || PrivateKeyBlockPatterns.isBodyLine(String(line[start..<wordEnd])) else {
                // A word that isn't a line of the key: the key's last line is short, or this isn't a key. If an END marker
                // follows in the same quotes, everything up to it is the key.
                return keyEnd(from: start, in: line, markers: markers).map { endOfRun(from: $0.upperBound, in: line) } ?? end
            }
            end = wordEnd
            glued = false
        }
    }

    /// The END marker that follows `start` on the line, within the reach and before the next quote, if there is one.
    private static func keyEnd(from start: String.Index, in line: String, markers: [Range<String.Index>]) -> Range<String.Index>? {
        guard let marker = firstMarker(atOrAfter: start, in: markers),
              line.utf8.distance(from: start, to: marker.lowerBound) <= endMarkerSearchReach else { return nil }
        var index = start
        while index < marker.lowerBound {
            if isQuote(line[index]) { return nil }
            index = line.index(after: index)
        }
        return marker
    }

    // MARK: The END line

    /// A whole line that is the END line: the END marker, with the base64 of the key's last lines before it and a quote,
    /// a comma or a brace after it when the key is wrapped JSON (`AbC…\n-----END PRIVATE KEY-----\n",`).
    private static let endLine = NSRegularExpression.fixed(
        #"\A\s*(?:\\n)?(?:[A-Za-z0-9+/]++={0,2}\\n)*+\s*+"# + #"(?:"# + dash + #"++\s*+)?"# + words("END")
            + #"(?:\s*+"# + dash + #"++)?(?:\\n)*+["'`]?[,;)}\]]*+\s*+\z"#)

    static func isEndLine(_ line: String) -> Bool {
        endLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    // MARK: Body lines

    /// A body line has this many base64 characters at least; a PEM's lines have 64.
    static let minimumBodyCharacters = 16

    /// A whole line of base64, `[A-Za-z0-9+/]`, 16 characters or more, with up to two `=` of padding at the end and no
    /// spaces; or several such pieces, joined by a backslash and an `n` (the lines of a key written on one line), with
    /// one at either end if the line starts or ends with a break. Not a line of only hex digits: a digest (a SHA-1, a
    /// SHA-256, a UUID without its dashes) isn't a key's body, and a body of 16 characters or more that was only hex digits
    /// would be a lucky one (1 in 3 000 000 000 000 at 64 characters).
    static func isBodyLine(_ line: String) -> Bool {
        var pieces = line.components(separatedBy: #"\n"#)
        if pieces.count > 1, pieces.first?.isEmpty == true { pieces.removeFirst() }
        if pieces.count > 1, pieces.last?.isEmpty == true { pieces.removeLast() }
        var characters = 0
        var onlyHex = true
        for piece in pieces {
            var bytes = piece.utf8[...]
            var padding = 0
            while padding < 2, bytes.last == UInt8(ascii: "=") {
                bytes = bytes.dropLast()
                padding += 1
            }
            guard !bytes.isEmpty else { return false }
            for byte in bytes {
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"), UInt8(ascii: "A")...UInt8(ascii: "F"):
                    break
                case UInt8(ascii: "g")...UInt8(ascii: "z"), UInt8(ascii: "G")...UInt8(ascii: "Z"), UInt8(ascii: "+"), UInt8(ascii: "/"):
                    onlyHex = false
                default:
                    return false
                }
            }
            characters += bytes.count
        }
        return characters >= minimumBodyCharacters && !onlyHex
    }
}
