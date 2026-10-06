import CSCore
import Foundation

/// The current tool look, remembered between editors.
public struct AnnotateToolSettings: JSONPrefValue, Equatable {
    public var color = ColorPalette.defaultColor
    public var sizeLevel = 3
    public var arrowStyle = ArrowStyle.standard
    public var textStyle = TextStyle.standard
    public var redactStyle = RedactStyle.pixelate
    public var redactIntensity = 5
    public var spotlightShape = SpotlightShape.rectangle
    public var spotlightOpacity = 0.6
    public var counterStyle = CounterStyle.numbers
    public var counterStart = 1
    public var highlightOpacity = 0.4
    public var smartHighlighter = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case color, sizeLevel, arrowStyle, textStyle, redactStyle, redactIntensity, spotlightShape, spotlightOpacity
        case counterStyle, counterStart, highlightOpacity, smartHighlighter
    }

    /// Every field is optional on disk and falls back to its default. A stored value from before a field existed keeps
    /// its other settings (the preferences store would otherwise reset the whole value silently). Encoding stays
    /// synthesized.
    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decodeIfPresent(RGBAColor.self, forKey: .color) ?? color
        sizeLevel = try container.decodeIfPresent(Int.self, forKey: .sizeLevel) ?? sizeLevel
        arrowStyle = try container.decodeIfPresent(ArrowStyle.self, forKey: .arrowStyle) ?? arrowStyle
        textStyle = try container.decodeIfPresent(TextStyle.self, forKey: .textStyle) ?? textStyle
        redactStyle = try container.decodeIfPresent(RedactStyle.self, forKey: .redactStyle) ?? redactStyle
        redactIntensity = try container.decodeIfPresent(Int.self, forKey: .redactIntensity) ?? redactIntensity
        spotlightShape = try container.decodeIfPresent(SpotlightShape.self, forKey: .spotlightShape) ?? spotlightShape
        spotlightOpacity = try container.decodeIfPresent(Double.self, forKey: .spotlightOpacity) ?? spotlightOpacity
        counterStyle = try container.decodeIfPresent(CounterStyle.self, forKey: .counterStyle) ?? counterStyle
        counterStart = try container.decodeIfPresent(Int.self, forKey: .counterStart) ?? counterStart
        highlightOpacity = try container.decodeIfPresent(Double.self, forKey: .highlightOpacity) ?? highlightOpacity
        smartHighlighter = try container.decodeIfPresent(Bool.self, forKey: .smartHighlighter) ?? smartHighlighter
    }
}

/// Saved custom colors.
public struct MyColors: JSONPrefValue, Equatable {
    public var colors: [RGBAColor]

    public init(colors: [RGBAColor] = []) {
        self.colors = colors
    }

    /// Saves `color`, unless that exact color is already saved.
    public mutating func add(_ color: RGBAColor) {
        guard !colors.contains(color) else { return }
        colors.append(color)
    }

    /// Replaces the color at `index`. A copy of `color` saved elsewhere is dropped, so the list never holds duplicates.
    /// An index out of range changes nothing.
    public mutating func update(at index: Int, to color: RGBAColor) {
        guard colors.indices.contains(index) else { return }
        colors[index] = color
        colors = colors.enumerated().filter { $0.offset == index || $0.element != color }.map(\.element)
    }

    /// Removes the color at `index`; an index out of range changes nothing.
    public mutating func remove(at index: Int) {
        guard colors.indices.contains(index) else { return }
        colors.remove(at: index)
    }

    private enum CodingKeys: String, CodingKey {
        case colors
    }

    /// Tolerant like `AnnotateToolSettings`, so a later field can't make the preferences store drop saved colors.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colors = try container.decodeIfPresent([RGBAColor].self, forKey: .colors) ?? []
    }
}

/// Save As formats.
public enum AnnotateSaveFormat: String, CaseIterable, Sendable, Identifiable, PrefValue {
    case png, jpeg, heic, webp, project

    public var id: String { rawValue }

    /// The Save As format that writes `format`.
    public init(_ format: ImageFormat) {
        self = switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .webp: .webp
        }
    }

    /// What a screenshot's Save As offers: the image formats, not the project.
    public static let imageFormats: [AnnotateSaveFormat] = ImageFormat.allCases.map(AnnotateSaveFormat.init)

    public var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .webp: "WebP"
        case .project: "ClearShot Project"
        }
    }

    /// The image format, or nil for a project.
    public var imageFormat: ImageFormat? {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .webp: .webp
        case .project: nil
        }
    }

    public var fileExtension: String {
        imageFormat?.fileExtension ?? "clearshot"
    }
}

public extension Prefs {
    // Annotate pane
    static let annotateInvertArrows = PrefKey("annotateInvertArrows", default: false)
    static let annotateSmoothDrawing = PrefKey("annotateSmoothDrawing", default: true)
    static let annotateObjectShadows = PrefKey("annotateObjectShadows", default: true)
    static let annotateAutoExpandCanvas = PrefKey("annotateAutoExpandCanvas", default: true)
    static let annotateAlwaysOnTop = PrefKey("annotateAlwaysOnTop", default: true)
    static let annotateShowDockIcon = PrefKey("annotateShowDockIcon", default: true)
    static let annotateShowColorNames = PrefKey("annotateShowColorNames", default: true)
    static let annotateRememberBackgroundTool = PrefKey("annotateRememberBackgroundTool", default: true)

    // Editor state
    static let annotateToolSettings = PrefKey("annotateToolSettings", default: AnnotateToolSettings())
    static let annotateMyColors = PrefKey("annotateMyColors", default: MyColors())
    static let annotateLastSaveFolder = PrefKey("annotateLastSaveFolder", default: "")
    static let annotateLastSaveFormat = PrefKey("annotateLastSaveFormat", default: AnnotateSaveFormat.png)
    static let annotateToolKeys = PrefKey("annotateToolKeys", default: AnnotateToolKeys())
    /// Whether the last editor closed with the Background panel open.
    static let annotateBackgroundToolWasOpen = PrefKey("annotateBackgroundToolWasOpen", default: false)

    // Backgrounds: presets, Previous Settings and the auto-apply preset, per `BackgroundPresetKind`. An auto-apply id
    // of "" or one naming no preset is off.
    static let backgroundPresets = PrefKey("backgroundPresets", default: BackgroundPresetList())
    static let windowBackgroundPresets = PrefKey("windowBackgroundPresets", default: BackgroundPresetList())
    static let lastBackgroundStyle = PrefKey("lastBackgroundStyle", default: RememberedBackgroundStyle())
    static let lastWindowBackgroundStyle = PrefKey("lastWindowBackgroundStyle", default: RememberedBackgroundStyle())
    static let autoApplyBackgroundPresetID = PrefKey("autoApplyBackgroundPresetID", default: "")
    static let autoApplyWindowBackgroundPresetID = PrefKey("autoApplyWindowBackgroundPresetID", default: "")
}
