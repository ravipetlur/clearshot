import Foundation

/// Turns recognized lines into the text Capture Text copies.
public enum TextAssembler {
    /// Each line trimmed, blank ones skipped. With line breaks they are joined by newlines. Without, by spaces, except
    /// that a word hyphenated across lines is put back together ("infor-" + "mation" → "information", "Jean-" + "Paul"
    /// → "Jean-Paul"), and Chinese and Japanese text runs on without a space (Korean keeps it: see `runsOn`).
    public static func text(from lines: [OCRLine], keepLineBreaks: Bool) -> String {
        let texts = lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if keepLineBreaks { return texts.joined(separator: "\n") }

        guard var joined = texts.first else { return "" }
        for (previous, text) in zip(texts, texts.dropFirst()) {
            if endsInHyphenatedWord(previous) {
                if text.first?.isLowercase == true { joined.removeLast() }
                joined += text
            } else if runsOn(previous.last, text.first) {
                joined += text
            } else {
                joined += " " + text
            }
        }
        return joined
    }

    /// Whether a line ending in `before` runs on into one starting with `after`: between CJK characters (full-width
    /// punctuation included), as Chinese and Japanese are written without spaces between words, but not where either is
    /// Hangul, as Korean separates words with spaces (Hanja beside Hangul too).
    private static func runsOn(_ before: Character?, _ after: Character?) -> Bool {
        guard let before, let after else { return false }
        return before.isCJK && after.isCJK && !before.isHangul && !after.isHangul
    }

    /// A line ending in `-` straight after a letter. A dash after a space (or alone) is punctuation.
    private static func endsInHyphenatedWord(_ line: String) -> Bool {
        guard line.last == "-" else { return false }
        let beforeHyphen = line.dropLast().last
        return beforeHyphen?.isLetter == true
    }
}
