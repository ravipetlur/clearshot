import CoreGraphics
import Foundation

/// A parsed `clearshot://` URL: its command, and what was ignored on the way, for the log.
///
/// Parsing is tolerant: a parameter a command doesn't take is ignored and noted, and of a repeated one the first wins.
/// Names are matched ignoring case. Values are read through `URLComponents`, so they are percent-decoded and a `+`
/// stays a `+`.
public struct APIRequest: Sendable, Equatable {
    public let command: APICommand
    /// What was ignored, one line each, for the log.
    public let notes: [String]

    /// The URL's command name as given, lowercased, without parsing anything else: the host, else the first path
    /// component (so `clearshot://capture-area/` and `clearshot:capture-area` are both "capture-area"). It stays
    /// percent-encoded, so a consent prompt that shows it can't be made to read as something else.
    public static func commandName(of url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        if let host = components.percentEncodedHost, !host.isEmpty {
            return host.lowercased()
        }
        return components.percentEncodedPath.split(separator: "/").first.map { $0.lowercased() } ?? ""
    }

    /// The most characters of a command name a message shows (`shortened`).
    public static let shownNameLimit = 40

    /// A command name as a message shows it: whole up to `shownNameLimit` characters, else cut to that many with the
    /// last an ellipsis, so a long URL can't fill the HUD or a prompt.
    public static func shortened(_ name: String) -> String {
        name.count <= shownNameLimit ? name : name.prefix(shownNameLimit - 1) + "…"
    }

    /// Checks syntax and types only, never the screen or the disk: display numbers are checked by `APIArea.resolve`,
    /// files by `APIFiles.validate`. `allowsDebugCommands` admits `debug-selftest` (Debug builds); otherwise it is an
    /// unknown command.
    public static func parse(_ url: URL, allowsDebugCommands: Bool) throws(APIError) -> APIRequest {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "clearshot" else { throw .wrongScheme(scheme) }
        let name = commandName(of: url)
        var query = QueryParameters(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])

        let command: APICommand
        switch name {
        case "all-in-one":
            command = try .allInOne(query.area())
        case "capture-area":
            command = try .captureArea(query.area(), action: query.action())
        case "capture-area-raycast-aichat":
            command = try .captureAreaForRaycast(query.area())
        case "capture-previous-area":
            command = try .capturePreviousArea(action: query.action())
        case "capture-fullscreen":
            command = try .captureFullscreen(action: query.action())
        case "capture-window":
            command = try .captureWindow(action: query.action())
        case "self-timer":
            command = try .selfTimer(action: query.action())
        case "scrolling-capture":
            let area = try query.area()
            command = try .scrollingCapture(area, start: query.scrollStart(hasArea: area != nil))
        case "record-screen":
            command = try .recordScreen(query.area())
        case "capture-text":
            let file = query.filePath()
            if file != nil, QueryParameters.areaNames.contains(where: query.has) { throw .fileAndArea }
            let area = try query.area()
            let source: APITextSource = if let file { .file(file) } else if let area { .area(area) } else { .overlay }
            command = try .captureText(source, keepLineBreaks: query.flag("linebreaks"))
        case "pin":
            command = .pin(filePath: query.filePath())
        case "open-annotate":
            command = .openAnnotate(filePath: query.filePath())
        case "open-from-clipboard":
            command = .openFromClipboard
        case "add-quick-access-overlay":
            guard let file = query.filePath() else { throw .missingFile(name) }
            command = .addQuickAccessOverlay(filePath: file)
        case "open-history":
            command = .openHistory
        case "restore-recently-closed":
            command = .restoreRecentlyClosed
        case "open-settings":
            command = .openSettings(query.tab())
        case "toggle-desktop-icons":
            command = .toggleDesktopIcons
        case "hide-desktop-icons":
            command = .hideDesktopIcons
        case "show-desktop-icons":
            command = .showDesktopIcons
        case "debug-selftest" where allowsDebugCommands:
            command = .debugSelfTest
        default:
            throw .unknownCommand(name)
        }
        query.noteUnread(by: name)
        return APIRequest(command: command, notes: query.notes)
    }
}

/// A URL's query parameters as one command reads them: names ignoring case, the first of a repeat, and a note for each
/// parameter the command never read.
private struct QueryParameters {
    static let areaNames = ["x", "y", "width", "height"]

    private var values: [String: String] = [:]
    /// Names in the order they first appear, for the notes.
    private var names: [String] = []
    private var read: Set<String> = []
    private(set) var notes: [String] = []

    init(_ items: [URLQueryItem]) {
        var repeated: Set<String> = []
        for item in items where !item.name.isEmpty {
            let name = item.name.lowercased()
            if values[name] == nil {
                values[name] = item.value ?? ""
                names.append(name)
            } else if repeated.insert(name).inserted {
                notes.append("\(name) is given more than once; the first one is used")
            }
        }
    }

    func has(_ name: String) -> Bool {
        values[name] != nil
    }

    mutating func noteUnread(by command: String) {
        for name in names where !read.contains(name) {
            notes.append("\(command) ignores \(name)")
        }
    }

    // MARK: Values

    /// x, y, width, height and display: all four or none of the first four. A display without them is ignored.
    mutating func area() throws(APIError) -> APIArea? {
        let given = Self.areaNames.filter(has)
        guard !given.isEmpty else {
            ignoredWithoutArea("display")
            return nil
        }
        guard given.count == Self.areaNames.count else { throw .incompleteArea }
        let x = try number("x"), y = try number("y")
        guard x >= 0 else { throw .negative("x") }
        guard y >= 0 else { throw .negative("y") }
        let width = try number("width"), height = try number("height")
        guard width > 0 else { throw .notPositive("width") }
        guard height > 0 else { throw .notPositive("height") }
        return try APIArea(rect: CGRect(x: x, y: y, width: width, height: height), display: display())
    }

    /// copy, save, annotate or pin, ignoring case; upload is refused.
    mutating func action() throws(APIError) -> APIAction? {
        guard let text = take("action") else { return nil }
        let value = text.lowercased()
        guard value != "upload" else { throw .uploadRefused }
        guard let action = APIAction(rawValue: value) else { throw .badAction(text) }
        return action
    }

    /// start and autoscroll; autoscroll implies start. Without an area both are ignored: Ready needs a region.
    mutating func scrollStart(hasArea: Bool) throws(APIError) -> APIScrollStart {
        guard hasArea else {
            ignoredWithoutArea("start")
            ignoredWithoutArea("autoscroll")
            return .none
        }
        let start = try flag("start") ?? false
        let autoScroll = try flag("autoscroll") ?? false
        return autoScroll ? .autoScroll : start ? .manual : .none
    }

    /// true or false, also 1 or 0 and yes or no, ignoring case.
    mutating func flag(_ name: String) throws(APIError) -> Bool? {
        guard let text = take(name) else { return nil }
        switch text.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: throw .badBoolean(name: name, value: text)
        }
    }

    /// The decoded path as given; an empty one is no file.
    mutating func filePath() -> String? {
        guard let text = take("filepath"), !text.isEmpty else { return nil }
        return text
    }

    /// A Settings tab name, ignoring case. An unknown one is noted, and Settings opens anyway.
    mutating func tab() -> APISettingsTab? {
        guard let text = take("tab") else { return nil }
        guard let tab = APISettingsTab(rawValue: text.lowercased()) else {
            notes.append("Unknown tab “\(text)”")
            return nil
        }
        return tab
    }

    // MARK: Helpers

    private mutating func take(_ name: String) -> String? {
        read.insert(name)
        return values[name]
    }

    private mutating func ignoredWithoutArea(_ name: String) {
        if take(name) != nil {
            notes.append("\(name) is ignored without x, y, width and height")
        }
    }

    /// A finite decimal: digits with an optional sign and point, nothing else (no exponents, hex, inf or nan).
    private mutating func number(_ name: String) throws(APIError) -> Double {
        let text = take(name) ?? ""
        guard !text.isEmpty, text.allSatisfy({ "0123456789.+-".contains($0) }), let value = Double(text), value.isFinite
        else { throw .notANumber(name) }
        return value
    }

    /// A whole number from 1. Whether that display exists is checked by `APIArea.resolve`.
    private mutating func display() throws(APIError) -> Int? {
        guard let text = take("display") else { return nil }
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(text), number >= 1
        else { throw .badDisplay(text) }
        return number
    }
}
