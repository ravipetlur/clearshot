import CSCore
import Foundation

/// A named background style the user saved.
public struct BackgroundPreset: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var style: BackgroundStyle

    public init(id: UUID = UUID(), name: String, style: BackgroundStyle) {
        self.id = id
        self.name = name
        self.style = style
    }
}

/// The saved presets of one kind (`BackgroundPresetKind`), in the menu's order.
public struct BackgroundPresetList: JSONPrefValue, Equatable {
    public var presets: [BackgroundPreset]

    public init(_ presets: [BackgroundPreset] = []) {
        self.presets = presets
    }

    public func preset(id: UUID) -> BackgroundPreset? {
        presets.first { $0.id == id }
    }

    /// The preset a stored id names: nil for "" (none), a string that isn't a UUID, or a preset that no longer exists.
    public func preset(idString: String) -> BackgroundPreset? {
        UUID(uuidString: idString).flatMap(preset(id:))
    }

    /// The first preset whose style is exactly `style`, gradient id included.
    public func matching(_ style: BackgroundStyle) -> BackgroundPreset? {
        presets.first { $0.style == style }
    }

    /// Saves `style` as a new last preset. The name is trimmed; an empty one becomes "Preset N", N being the new count.
    @discardableResult
    public mutating func add(name: String, style: BackgroundStyle) -> BackgroundPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = BackgroundPreset(name: trimmed.isEmpty ? "Preset \(presets.count + 1)" : trimmed, style: style)
        presets.append(preset)
        return preset
    }

    /// Replaces the style of the preset `id`; an unknown id changes nothing.
    public mutating func update(_ id: UUID, style: BackgroundStyle) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].style = style
    }

    /// Renames the preset `id` to `name`, trimmed. A name that trims to nothing, or an unknown id, changes nothing.
    public mutating func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].name = trimmed
    }

    public mutating func remove(_ id: UUID) {
        presets.removeAll { $0.id == id }
    }

    private enum CodingKeys: String, CodingKey {
        case presets
    }

    /// Tolerant like the other Annotate settings, since the preferences store would otherwise drop the whole list
    /// silently: an entry that doesn't decode is dropped on its own, and so is a later entry with an id already seen.
    /// Encoding stays synthesized.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = (try? container.decodeIfPresent([Entry].self, forKey: .presets)) ?? []
        var seen: Set<UUID> = []
        presets = entries.compactMap(\.preset).filter { seen.insert($0.id).inserted }
    }

    /// One stored preset, decoded on its own so that a damaged one fails only itself.
    private struct Entry: Decodable {
        let preset: BackgroundPreset?

        init(from decoder: any Decoder) throws {
            preset = try? BackgroundPreset(from: decoder)
        }
    }
}

/// Previous Settings: the style of the last backgrounded document of a kind, or nil before there was one.
public struct RememberedBackgroundStyle: JSONPrefValue, Equatable {
    public var style: BackgroundStyle?

    public init(_ style: BackgroundStyle? = nil) {
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case style
    }

    /// A style that doesn't decode is none, rather than making the preferences store drop the value. Encoding stays
    /// synthesized.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try? container.decodeIfPresent(BackgroundStyle.self, forKey: .style)
    }
}

/// Screenshots and window screenshots keep their own presets, Previous Settings and auto-apply preset.
public enum BackgroundPresetKind: Sendable {
    case screenshot, window

    public var presetsKey: PrefKey<BackgroundPresetList> {
        switch self {
        case .screenshot: Prefs.backgroundPresets
        case .window: Prefs.windowBackgroundPresets
        }
    }

    public var previousKey: PrefKey<RememberedBackgroundStyle> {
        switch self {
        case .screenshot: Prefs.lastBackgroundStyle
        case .window: Prefs.lastWindowBackgroundStyle
        }
    }

    /// The id of the preset applied to every new capture of this kind; "" or an unknown id is none.
    public var autoApplyKey: PrefKey<String> {
        switch self {
        case .screenshot: Prefs.autoApplyBackgroundPresetID
        case .window: Prefs.autoApplyWindowBackgroundPresetID
        }
    }

    /// The style a document of this kind starts from without Previous Settings.
    public var standardStyle: BackgroundStyle {
        switch self {
        case .screenshot: .standard
        case .window: .windowStandard
        }
    }
}

extension BackgroundPresetKind {
    /// The kind whose presets and Previous Settings `document` takes: `.window` for a window screenshot.
    init(of document: AnnotationDocument) {
        self = document.isWindowShot ? .window : .screenshot
    }
}

/// What applying a document does to the background settings.
public enum BackgroundPresets {
    /// Previous Settings: a written document with a background leaves its style as its kind's memory, for the next
    /// document of that kind to start from. One without a background leaves the memory as it is. The captured wallpaper
    /// fill means that document's own picture, which the next one doesn't have, so it is remembered as the desktop (the
    /// standard window fill), the rest of the style as it is.
    @MainActor
    public static func recordPrevious(_ document: AnnotationDocument, in preferences: Preferences) {
        guard var style = document.background?.style else { return }
        if style.fill == .windowWallpaper { style.fill = BackgroundStyle.windowStandard.fill }
        preferences[BackgroundPresetKind(of: document).previousKey] = RememberedBackgroundStyle(style)
    }
}
