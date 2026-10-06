import CSCore
import Foundation

/// What a letter in the editor can pick: a tool, or the Background panel, which isn't a tool (a drawing mode) but shares
/// the tools' letters and their rules.
public enum AnnotateKeyTarget: Hashable, Sendable, Identifiable {
    case tool(EditorTool)
    case backgroundPanel

    /// The tools in their order, then the panel: Settings' rows, and the order stored letters are taken in.
    public static let allCases: [AnnotateKeyTarget] = EditorTool.allCases.map { .tool($0) } + [.backgroundPanel]

    /// The name its letter is stored under: the tool's raw value, or "background".
    public var id: String {
        switch self {
        case .tool(let tool): tool.rawValue
        case .backgroundPanel: "background"
        }
    }

    public var title: String {
        switch self {
        case .tool(let tool): tool.title
        case .backgroundPanel: "Background"
        }
    }

    public var symbol: String {
        switch self {
        case .tool(let tool): tool.symbol
        case .backgroundPanel: "photo.artframe"
        }
    }

    /// The letter that picks it unless Settings › Annotate › Tool shortcuts changes it.
    public var defaultKey: Character {
        switch self {
        case .tool(let tool): tool.defaultKey
        case .backgroundPanel: "g"
        }
    }

    /// The letters' section in Settings › Shortcuts, which a search finds whole.
    public static let groupTitle = "Annotate tools"

    /// Extra search words for Settings › Shortcuts.
    public var keywords: [String] {
        switch self {
        case .tool(.redact): ["pixelate", "blur", "hide"]
        case .tool(.highlighter): ["marker"]
        case .tool(.pen): ["draw", "freehand"]
        case .tool(.counter): ["number", "step"]
        case .tool(.spotlight): ["focus", "dim"]
        case .tool(.crop): ["resize"]
        case .tool(.text): ["type", "label"]
        case .tool(.arrow): ["pointer"]
        case .tool(.filledRectangle): ["box", "fill"]
        case .tool(.select): ["move"]
        case .backgroundPanel: ["wallpaper", "padding"]
        case .tool(.rectangle), .tool(.ellipse), .tool(.line): []
        }
    }

    /// Case-insensitive search over title, keywords and `groupTitle`, in `allCases` order. A blank query returns
    /// everything, as `ClearShotAction.matching` does.
    public static func matching(_ query: String) -> [AnnotateKeyTarget] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return allCases }
        return allCases.filter { target in
            target.title.lowercased().contains(needle)
                || target.keywords.contains { $0.contains(needle) }
                || groupTitle.lowercased().contains(needle)
        }
    }
}

/// The letters that pick Annotate's tools and open the Background panel (Settings › Annotate › Tool shortcuts). Only
/// letters changed from the defaults are stored, by `AnnotateKeyTarget.id`.
public struct AnnotateToolKeys: JSONPrefValue, Equatable {
    /// Changed letters by target. An entry that isn't one letter a–z, or that names no target, is ignored.
    public var letters: [String: String]

    public init(letters: [String: String] = [:]) {
        self.letters = letters
    }

    private enum CodingKeys: String, CodingKey {
        case letters
    }

    /// Tolerant like the other Annotate settings: a stored value without `letters`, or with something else there, decodes
    /// as no changes, rather than making the preferences store drop it. A bad entry is dropped on its own and leaves the
    /// others. Encoding stays synthesized.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = (try? container.decodeIfPresent([String: Entry].self, forKey: .letters)) ?? [:]
        letters = entries.compactMapValues(\.letter)
    }

    /// One stored letter, decoded on its own so that a value that isn't a string fails only itself.
    private struct Entry: Decodable {
        let letter: String?

        init(from decoder: any Decoder) throws {
            letter = try? decoder.singleValueContainer().decode(String.self)
        }
    }

    /// Keys that can never pick a tool or the panel: the size keys (`ToolSizes.levels`, 1–6), and `[` and `]`, which
    /// change the size, or the redact intensity.
    public static let reserved: Set<Character> = {
        var keys: Set<Character> = ["[", "]"]
        for level in ToolSizes.levels where (0...9).contains(level) {
            keys.insert(Character(String(level)))
        }
        return keys
    }()

    /// Why a letter can't be a target's.
    public enum Problem: Equatable, Sendable {
        case notALetter
        case reserved
        case taken(by: AnnotateKeyTarget)
    }

    /// Each target's letter, in `AnnotateKeyTarget.allCases` order:
    /// - its stored letter, when that is a usable letter no target before it has taken;
    /// - otherwise its default, when that is still free;
    /// - otherwise none.
    ///
    /// Two targets never share a key.
    public var resolved: [AnnotateKeyTarget: Character] {
        var result: [AnnotateKeyTarget: Character] = [:]
        var used: Set<Character> = []
        // Stored letters first, so a stored letter wins over another target's default.
        for target in AnnotateKeyTarget.allCases {
            guard let letter = letters[target.id].flatMap(Self.letter(from:)), !used.contains(letter) else { continue }
            result[target] = letter
            used.insert(letter)
        }
        for target in AnnotateKeyTarget.allCases where result[target] == nil && !used.contains(target.defaultKey) {
            result[target] = target.defaultKey
            used.insert(target.defaultKey)
        }
        return result
    }

    public func key(for target: AnnotateKeyTarget) -> Character? {
        resolved[target]
    }

    public func key(for tool: EditorTool) -> Character? {
        key(for: .tool(tool))
    }

    /// What `key` picks, in either case.
    public func target(for key: Character) -> AnnotateKeyTarget? {
        guard let lower = key.lowercased().first else { return nil }
        return resolved.first { $0.value == lower }?.key
    }

    /// The tool `key` picks, in either case: nil for the Background panel's letter.
    public func tool(for key: Character) -> EditorTool? {
        guard case .tool(let tool) = target(for: key) else { return nil }
        return tool
    }

    /// Why `input` can't be `target`'s letter, or nil when it can. A letter is one of a–z, in either case.
    public func problem(with input: String, for target: AnnotateKeyTarget) -> Problem? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 1, let character = trimmed.first, Self.reserved.contains(character) { return .reserved }
        guard let letter = Self.letter(from: trimmed) else { return .notALetter }
        if let owner = resolved.first(where: { $0.key != target && $0.value == letter })?.key { return .taken(by: owner) }
        return nil
    }

    public func problem(with input: String, for tool: EditorTool) -> Problem? {
        problem(with: input, for: .tool(tool))
    }

    /// Sets `target`'s letter, unless `problem(with:for:)` refuses it, and returns the refusal. A target set back to its
    /// default letter stores nothing.
    @discardableResult
    public mutating func set(_ input: String, for target: AnnotateKeyTarget) -> Problem? {
        if let problem = problem(with: input, for: target) { return problem }
        guard let letter = Self.letter(from: input.trimmingCharacters(in: .whitespaces)) else { return .notALetter }
        letters[target.id] = letter == target.defaultKey ? nil : String(letter)
        return nil
    }

    @discardableResult
    public mutating func set(_ input: String, for tool: EditorTool) -> Problem? {
        set(input, for: .tool(tool))
    }

    /// The lowercase letter `string` is, if it is exactly one of a–z in either case. Nothing else is a letter here: not an
    /// accented one, a ligature, or a character that only lowercases to one (the Kelvin sign).
    static func letter(from string: String) -> Character? {
        let scalars = string.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) else {
            return nil
        }
        return Character(String(scalar).lowercased())
    }
}
