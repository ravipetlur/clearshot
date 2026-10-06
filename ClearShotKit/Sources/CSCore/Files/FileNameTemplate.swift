import Foundation

/// A file name pattern such as "Screenshot %y-%m-%d at %H.%M.%S".
public struct FileNameTemplate: Sendable, Equatable, Hashable {
    public enum Token: Sendable, Equatable, Hashable {
        case text(String)
        case year, monthNumber, monthName, day, weekday, hour, minute, second, ampm
        case random, appName, windowTitle, autoIncrement

        /// The `%x` code, or nil for literal text.
        public var code: String? {
            switch self {
            case .text: nil
            case .year: "%y"
            case .monthNumber: "%m"
            case .monthName: "%n"
            case .day: "%d"
            case .weekday: "%w"
            case .hour: "%H"
            case .minute: "%M"
            case .second: "%S"
            case .ampm: "%p"
            case .random: "%r"
            case .appName: "%a"
            case .windowTitle: "%t"
            case .autoIncrement: "%i"
            }
        }

        public var displayName: String {
            switch self {
            case .text(let text): text
            case .year: "Year"
            case .monthNumber: "Month (number)"
            case .monthName: "Month (name)"
            case .day: "Day"
            case .weekday: "Day of week"
            case .hour: "Hour"
            case .minute: "Minutes"
            case .second: "Seconds"
            case .ampm: "AM/PM"
            case .random: "Random characters"
            case .appName: "App name"
            case .windowTitle: "Window title"
            case .autoIncrement: "Auto-increment"
            }
        }

        /// Every placeholder token, in the order shown in the template editor.
        public static let placeholders: [Token] = [
            .year, .monthNumber, .monthName, .day, .weekday, .hour, .minute, .second, .ampm,
            .random, .appName, .windowTitle, .autoIncrement,
        ]

        static let byCode: [Character: Token] = [
            "y": .year, "m": .monthNumber, "n": .monthName, "d": .day, "w": .weekday,
            "H": .hour, "M": .minute, "S": .second, "p": .ampm, "r": .random,
            "a": .appName, "t": .windowTitle, "i": .autoIncrement,
        ]
    }

    public private(set) var tokens: [Token]

    public init(tokens: [Token]) {
        self.tokens = Self.mergingText(tokens)
    }

    /// Parses `%x` codes. `%%` is a literal percent sign; unknown codes stay as literal text.
    public init(parsing string: String) {
        var tokens: [Token] = []
        var text = ""
        let characters = Array(string)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "%", index + 1 < characters.count {
                let next = characters[index + 1]
                if next == "%" {
                    text.append("%")
                    index += 2
                    continue
                }
                if let token = Token.byCode[next] {
                    if !text.isEmpty {
                        tokens.append(.text(text))
                        text = ""
                    }
                    tokens.append(token)
                    index += 2
                    continue
                }
            }
            text.append(character)
            index += 1
        }
        if !text.isEmpty { tokens.append(.text(text)) }
        self.tokens = tokens
    }

    public var stringValue: String {
        tokens.map { token in
            if case .text(let text) = token {
                return Self.escape(text)
            }
            return token.code ?? ""
        }.joined()
    }

    public var usesAutoIncrement: Bool { tokens.contains(.autoIncrement) }
    public var usesAMPM: Bool { tokens.contains(.ampm) }

    /// The default: "Screenshot 2026-10-03 at 14.22.01".
    public static let standard = FileNameTemplate(parsing: "Screenshot %y-%m-%d at %H.%M.%S")

    /// Doubles a `%` only where it would otherwise be read as a code or as `%%`.
    private static func escape(_ text: String) -> String {
        var result = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character == "%", index + 1 < characters.count {
                let next = characters[index + 1]
                if next == "%" || Token.byCode[next] != nil {
                    result.append("%%")
                    continue
                }
            }
            result.append(character)
        }
        return result
    }

    private static func mergingText(_ tokens: [Token]) -> [Token] {
        var merged: [Token] = []
        for token in tokens {
            if case .text(let text) = token, case .text(let previous)? = merged.last {
                merged[merged.count - 1] = .text(previous + text)
            } else {
                merged.append(token)
            }
        }
        return merged
    }
}
