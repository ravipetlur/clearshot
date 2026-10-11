/// A string cut into the lines a narrow column shows it as, for tests that draw or read wrapped text.
public enum TextWrapping {
    /// `text` cut every `width` characters, as a column that wide shows a string with no spaces.
    public static func chunks(of text: String, width: Int) -> [String] {
        stride(from: 0, to: text.count, by: width).map { start in
            let from = text.index(text.startIndex, offsetBy: start)
            return String(text[from..<text.index(from, offsetBy: min(width, text.count - start))])
        }
    }

    /// `text` as a column `width` characters wide shows it: words kept whole where they fit on the line, a word wider than the
    /// column started on a line of its own and broken every `width` characters, with the rest of it left for the words that
    /// follow.
    public static func words(of text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            if !current.isEmpty, current.count + 1 + word.count <= width {
                current += " " + word
                continue
            }
            if !current.isEmpty { lines.append(current) }
            var rest = Substring(word)
            while rest.count > width {
                lines.append(String(rest.prefix(width)))
                rest = rest.dropFirst(width)
            }
            current = String(rest)
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
