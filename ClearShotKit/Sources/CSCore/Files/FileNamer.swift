import Foundation

/// Everything a template needs that isn't in the template itself.
public struct FileNameContext: Sendable {
    public var date: Date
    public var timeZone: TimeZone
    public var locale: Locale
    public var appName: String?
    public var windowTitle: String?
    public var autoIncrement: Int
    public var removeIllegalCharacters: Bool
    public var randomCharacters: @Sendable () -> String

    public init(date: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current,
                appName: String? = nil, windowTitle: String? = nil, autoIncrement: Int = 1,
                removeIllegalCharacters: Bool = true,
                randomCharacters: @escaping @Sendable () -> String = { FileNamer.randomCharacters() }) {
        self.date = date
        self.timeZone = timeZone
        self.locale = locale
        self.appName = appName
        self.windowTitle = windowTitle
        self.autoIncrement = autoIncrement
        self.removeIllegalCharacters = removeIllegalCharacters
        self.randomCharacters = randomCharacters
    }
}

public enum FileNamer {
    public static let fallbackName = "Screenshot"
    /// APFS allows 255 UTF-8 bytes per name; 240 leaves room for " (12)" and an extension.
    public static let maxBytes = 240

    /// The file name without its extension.
    public static func baseName(for template: FileNameTemplate, context: FileNameContext) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        calendar.locale = context.locale
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: context.date)
        let hour = parts.hour ?? 0
        let twelveHour = template.usesAMPM

        let raw = template.tokens.map { token -> String in
            switch token {
            case .text(let text): text
            case .year: String(format: "%04d", parts.year ?? 0)
            case .monthNumber: String(format: "%02d", parts.month ?? 0)
            case .monthName: calendar.standaloneMonthSymbols[max(0, (parts.month ?? 1) - 1)]
            case .day: String(format: "%02d", parts.day ?? 0)
            case .weekday: calendar.weekdaySymbols[max(0, (parts.weekday ?? 1) - 1)]
            case .hour: String(format: "%02d", twelveHour ? (hour % 12 == 0 ? 12 : hour % 12) : hour)
            case .minute: String(format: "%02d", parts.minute ?? 0)
            case .second: String(format: "%02d", parts.second ?? 0)
            case .ampm: hour < 12 ? calendar.amSymbol : calendar.pmSymbol
            case .random: context.randomCharacters()
            case .appName: context.appName ?? ""
            case .windowTitle: context.windowTitle ?? ""
            case .autoIncrement: String(context.autoIncrement)
            }
        }.joined()
        return sanitize(raw, removeIllegalCharacters: context.removeIllegalCharacters)
    }

    public static func sanitize(_ name: String, removeIllegalCharacters: Bool) -> String {
        var result = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        // Control characters and newlines are never usable in a file name.
        var removed = CharacterSet.controlCharacters.union(.newlines)
        if removeIllegalCharacters {
            // The optional set ("Remove illegal characters"): characters other systems reject.
            removed.formUnion(CharacterSet(charactersIn: "\\?%*|\"<>"))
        }
        result = String(String.UnicodeScalarView(result.unicodeScalars.filter { !removed.contains($0) }))
        result = result.trimmingCharacters(in: .whitespaces)
        while result.hasPrefix(".") { result.removeFirst() }
        result = result.trimmingCharacters(in: .whitespaces)
        while result.utf8.count > maxBytes { result.removeLast() }
        return result.isEmpty ? fallbackName : result
    }

    /// `directory/baseName.ext`, or `baseName (2).ext`, `(3)`… if taken.
    public static func uniqueURL(in directory: URL, baseName: String, pathExtension: String,
                                 fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) -> URL {
        var candidate = directory.appending(path: baseName).appendingPathExtension(pathExtension)
        var number = 2
        while fileExists(candidate) {
            candidate = directory.appending(path: "\(baseName) (\(number))").appendingPathExtension(pathExtension)
            number += 1
        }
        return candidate
    }

    public static func randomCharacters() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
