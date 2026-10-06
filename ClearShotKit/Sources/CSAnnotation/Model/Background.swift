import Foundation

/// Where the picture sits in a frame with room to spare: one of nine positions.
public enum BackgroundAlignment: String, Codable, CaseIterable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    /// The share of the spare room that goes before the picture on each axis: 0 for the left column or top row, ½ for
    /// the middle, 1 for the right column or bottom row (`topRight` is (1, 0)).
    public var factor: (x: Double, y: Double) {
        switch self {
        case .topLeft: (0, 0)
        case .top: (0.5, 0)
        case .topRight: (1, 0)
        case .left: (0, 0.5)
        case .center: (0.5, 0.5)
        case .right: (1, 0.5)
        case .bottomLeft: (0, 1)
        case .bottom: (0.5, 1)
        case .bottomRight: (1, 1)
        }
    }
}

/// The frame's shape: Auto follows the picture, the others fix width ÷ height. `allCases` is the menu's order.
public enum BackgroundRatio: String, Codable, CaseIterable, Sendable {
    case auto, square = "1:1", r3x4 = "3:4", r4x3 = "4:3", r3x2 = "3:2", r5x4 = "5:4", r16x9 = "16:9", r4x5 = "4:5", r9x16 = "9:16"

    /// Width ÷ height, or nil for Auto.
    public var aspect: Double? {
        switch self {
        case .auto: nil
        case .square: 1
        case .r3x4: 0.75
        case .r4x3: 4.0 / 3
        case .r3x2: 1.5
        case .r5x4: 1.25
        case .r16x9: 16.0 / 9
        case .r4x5: 0.8
        case .r9x16: 0.5625
        }
    }

    /// "Auto", "1:1", "3:4", …
    public var title: String {
        self == .auto ? "Auto" : rawValue
    }
}

/// What fills the inset around the picture: the picture's own edge colour (`EdgeColor`), or a colour.
public enum InsetColor: Codable, Hashable, Sendable {
    case auto
    case color(RGBAColor)
}

/// A gradient fill, kept by value so a document draws the same whatever the catalog becomes. Linear runs from the first
/// stop to the last along (cos θ, sin θ) in output pixels, y down: 0° is left to right, 90° top to bottom, 45° top-left to
/// bottom-right. Radial runs from the centre out.
public struct BackgroundGradient: Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        /// `angle` in degrees.
        case linear(angle: Double)
        case radial
    }

    public struct Stop: Codable, Hashable, Sendable {
        public var color: RGBAColor
        /// 0 at the start, 1 at the end.
        public var location: Double

        public init(color: RGBAColor, location: Double) {
            self.color = color
            self.location = location
        }
    }

    /// The catalog gradient this is (`catalog`), or nil for one made elsewhere. Part of equality: the panel highlights a
    /// tile by it, so a catalog gradient and the same colours without an id are different.
    public var id: String?
    public var kind: Kind
    public var stops: [Stop]

    /// The most stops a gradient keeps.
    static let maximumStops = 6

    public init(id: String? = nil, kind: Kind, stops: [Stop]) {
        self.id = id
        self.kind = kind
        self.stops = stops
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, stops
    }

    /// Tolerant of numbers a file that may not be ours could hold: colour components and locations are clamped to 0…1,
    /// the stops sorted by location (equal ones keep their order) and only the first six kept; an angle is reduced to
    /// 0..<360 (a non-finite one is 0). Fewer than two stops make no gradient and throw. An id that isn't a string is
    /// dropped. Encoding stays synthesized.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stops = try container.decode([Stop].self, forKey: .stops)
        guard stops.count >= 2 else {
            throw DecodingError.dataCorruptedError(forKey: .stops, in: container,
                                                   debugDescription: "A gradient needs two stops or more.")
        }
        let id = try? container.decodeIfPresent(String.self, forKey: .id)
        let kind = try container.decode(Kind.self, forKey: .kind)
        self.init(id: id, kind: kind.normalized, stops: Self.normalized(stops))
    }

    /// `stops` clamped into range, sorted by location (stable) and cut to `maximumStops`.
    private static func normalized(_ stops: [Stop]) -> [Stop] {
        let clamped = stops.map { Stop(color: $0.color.clampedToUnit, location: clampToUnit($0.location)) }
        let sorted = clamped.enumerated().sorted { ($0.element.location, $0.offset) < ($1.element.location, $1.offset) }
        return Array(sorted.map(\.element).prefix(maximumStops))
    }

    /// Every number in the gradient is finite.
    var isFinite: Bool {
        if case .linear(let angle) = kind, !angle.isFinite { return false }
        return stops.allSatisfy { $0.location.isFinite && $0.color.isFinite }
    }
}

extension BackgroundGradient.Kind {
    /// The angle in 0..<360, 0 when it isn't finite.
    var normalized: Self {
        guard case .linear(let angle) = self else { return self }
        guard angle.isFinite else { return .linear(angle: 0) }
        var reduced = angle.truncatingRemainder(dividingBy: 360)
        if reduced < 0 { reduced += 360 }
        // A tiny negative angle plus 360 can round to 360 itself.
        return .linear(angle: reduced >= 360 ? 0 : reduced)
    }
}

/// What fills the frame around the picture.
public enum BackgroundFill: Codable, Hashable, Sendable {
    /// Nothing: transparent around the box. Inset, corners and shadow still apply.
    case none
    case color(RGBAColor)
    case gradient(BackgroundGradient)
    /// The wallpaper of the capture's display.
    case desktop
    /// The same, blurred.
    case blurredDesktop
    /// A picture in /System/Library/Desktop Pictures, by its file name.
    case systemWallpaper(fileName: String)
    /// A picture the user added (`BackgroundLibrary`), by its id.
    case custom(id: UUID)
    /// The wallpaper captured behind a window.
    case windowWallpaper
    /// The picture itself, blurred, computed when drawn.
    case blurredScreenshot

    /// Whether the fill shows a picture resolved from a source and stored with the document (`DocumentBackground.image`):
    /// the desktop, blurred desktop, a system wallpaper, a custom picture and the captured window wallpaper.
    public var isImageBacked: Bool {
        switch self {
        case .desktop, .blurredDesktop, .systemWallpaper, .custom, .windowWallpaper: true
        case .none, .color, .gradient, .blurredScreenshot: false
        }
    }

    /// Whether a fill read from a file can be used as it is. A system wallpaper's name comes from a file that may not be
    /// ours, so it must be one plain file name in the wallpapers folder: not empty, `.` or `..`, and without `/` or NUL.
    var isUsable: Bool {
        guard case .systemWallpaper(let fileName) = self else { return true }
        return !fileName.isEmpty && fileName != "." && fileName != ".." && !fileName.contains("/") && !fileName.contains("\0")
    }

    /// Every number in the fill is finite.
    var isFinite: Bool {
        switch self {
        case .color(let color): color.isFinite
        case .gradient(let gradient): gradient.isFinite
        default: true
        }
    }
}

/// How a background looks, apart from its picture: what presets and Previous Settings store. Lengths are in points.
public struct BackgroundStyle: Codable, Hashable, Sendable {
    public var fill: BackgroundFill
    /// Room around the box, in points.
    public var padding: Double
    /// Room between the picture and the box's edge, in points, filled with `insetColor`.
    public var inset: Double
    public var insetColor: InsetColor
    /// The box's shadow, 0 (none) to 100.
    public var shadow: Double
    /// The box's corner radius, in points.
    public var corners: Double
    /// Whether uniform margins are trimmed off the picture first.
    public var autoBalance: Bool
    public var alignment: BackgroundAlignment
    public var ratio: BackgroundRatio

    public static let paddingRange: ClosedRange<Double> = 0...256
    public static let insetRange: ClosedRange<Double> = 0...128
    public static let shadowRange: ClosedRange<Double> = 0...100
    public static let cornersRange: ClosedRange<Double> = 0...64

    public init(fill: BackgroundFill, padding: Double, inset: Double, insetColor: InsetColor, shadow: Double, corners: Double,
                autoBalance: Bool, alignment: BackgroundAlignment, ratio: BackgroundRatio) {
        self.fill = fill
        self.padding = padding
        self.inset = inset
        self.insetColor = insetColor
        self.shadow = shadow
        self.corners = corners
        self.autoBalance = autoBalance
        self.alignment = alignment
        self.ratio = ratio
    }

    /// A screenshot's background when nothing else is remembered: the first catalog gradient.
    public static let standard = BackgroundStyle(fill: .gradient(.standard), padding: 64, inset: 0, insetColor: .auto, shadow: 50,
                                                 corners: 12, autoBalance: false, alignment: .center, ratio: .auto)

    /// A window screenshot's when nothing else is remembered: the desktop wallpaper.
    public static let windowStandard = BackgroundStyle(fill: .desktop, padding: 48, inset: 0, insetColor: .auto, shadow: 0,
                                                       corners: 0, autoBalance: false, alignment: .center, ratio: .auto)

    /// The style with each length in its range; one that isn't finite becomes `standard`'s.
    public func clamped() -> BackgroundStyle {
        func clamp(_ value: Double, to range: ClosedRange<Double>, standard: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : standard
        }
        var style = self
        style.padding = clamp(padding, to: Self.paddingRange, standard: Self.standard.padding)
        style.inset = clamp(inset, to: Self.insetRange, standard: Self.standard.inset)
        style.shadow = clamp(shadow, to: Self.shadowRange, standard: Self.standard.shadow)
        style.corners = clamp(corners, to: Self.cornersRange, standard: Self.standard.corners)
        return style
    }

    /// Every number in the style is finite: lengths, colours, and a gradient's angle and stops. A decoded style always is;
    /// one made in code may not be (`AnnotationDocument.isWellFormed`).
    var isFinite: Bool {
        guard [padding, inset, shadow, corners].allSatisfy(\.isFinite), fill.isFinite else { return false }
        if case .color(let color) = insetColor { return color.isFinite }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case fill, padding, inset, insetColor, shadow, corners, autoBalance, alignment, ratio
    }

    /// Each field decodes on its own: a missing or damaged one takes `standard`'s value and leaves the others, so a preset
    /// stays usable as the format grows. A fill that doesn't decode (an unknown kind, a refused gradient, a system
    /// wallpaper name that isn't a plain file name) is the standard gradient. Numbers are then `clamped()`. Encoding stays
    /// synthesized.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = Self.standard
        func value<T: Decodable>(_ key: CodingKeys, _ standardValue: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? standardValue
        }
        if let decoded = try? container.decodeIfPresent(BackgroundFill.self, forKey: .fill), decoded.isUsable {
            fill = decoded
        } else {
            fill = standard.fill
        }
        padding = value(.padding, standard.padding)
        inset = value(.inset, standard.inset)
        insetColor = value(.insetColor, standard.insetColor)
        shadow = value(.shadow, standard.shadow)
        corners = value(.corners, standard.corners)
        autoBalance = value(.autoBalance, standard.autoBalance)
        alignment = value(.alignment, standard.alignment)
        ratio = value(.ratio, standard.ratio)
        self = clamped()
    }
}

/// A document's background: its style and, for an image-backed fill, the picture it shows, stored with the document so it
/// renders the same forever.
public struct DocumentBackground: Codable, Hashable, Sendable {
    public var style: BackgroundStyle
    /// The fill's picture in the document's `ImageStore`, for an image-backed fill.
    public var image: ImageRef?

    public init(style: BackgroundStyle, image: ImageRef? = nil) {
        self.style = style
        self.image = image
    }
}

/// `value` clamped to 0…1; NaN is 0.
private func clampToUnit(_ value: Double) -> Double {
    value.isNaN ? 0 : min(max(value, 0), 1)
}

private extension RGBAColor {
    var clampedToUnit: RGBAColor {
        RGBAColor(red: clampToUnit(red), green: clampToUnit(green), blue: clampToUnit(blue), alpha: clampToUnit(alpha))
    }
}

extension RGBAColor {
    /// Every component is finite.
    var isFinite: Bool {
        [red, green, blue, alpha].allSatisfy(\.isFinite)
    }
}
