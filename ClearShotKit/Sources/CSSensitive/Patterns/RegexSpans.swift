import Foundation

extension NSRegularExpression {
    /// A pattern that is written in this package and fixed. One that doesn't compile is a bug the tests meet at once, so
    /// it stops the program instead of being handled.
    static func fixed(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        } catch {
            preconditionFailure("CSSensitive: the pattern \(pattern) doesn't compile: \(error)")
        }
    }

    /// Where the pattern matches in `line`, or where its capture group `group` does. A group that took no part in a match
    /// gives no range.
    func ranges(in line: String, group: Int = 0) -> [Range<String.Index>] {
        matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { Range($0.range(at: group), in: line) }
    }
}
