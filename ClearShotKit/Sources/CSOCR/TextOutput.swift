import Foundation

/// What Capture Text copies, and whether it offers to open a link.
public enum TextOutput {
    /// The QR codes' payloads when there are any, one per line; otherwise the assembled text. Trimmed.
    public static func text(for result: OCRResult, keepLineBreaks: Bool) -> String {
        let text = result.qrPayloads.isEmpty
            ? TextAssembler.text(from: result.lines, keepLineBreaks: keepLineBreaks)
            : result.qrPayloads.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The link the text is, if it is exactly one `http` or `https` link and nothing else. A bare domain counts
    /// (`NSDataDetector` gives it as `http://…`); an e-mail address doesn't (its link is `mailto:`).
    public static func singleLink(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let whole = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = detector.matches(in: trimmed, range: whole)
        guard matches.count == 1, let match = matches.first, match.range == whole,
              let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    /// The link to offer to open once `text` is copied: its single link (`singleLink(in:)`), when Detect links is on and
    /// no capture is under way. A capture's overlay sits above alerts, so a prompt shown then would open beneath it and
    /// the screen would look stuck; the text is on the clipboard either way.
    public static func linkToOffer(in text: String, detectsLinks: Bool, isCapturing: Bool) -> URL? {
        guard detectsLinks, !isCapturing else { return nil }
        return singleLink(in: text)
    }
}
