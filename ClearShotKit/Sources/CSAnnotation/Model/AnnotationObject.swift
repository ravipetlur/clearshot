import CoreGraphics
import Foundation

public enum ArrowStyle: String, Codable, CaseIterable, Sendable {
    case standard, curved, fancy, double

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .curved: "Curved"
        case .fancy: "Fancy"
        case .double: "Double-headed"
        }
    }
}

public enum TextStyle: String, Codable, CaseIterable, Sendable {
    case standard, rounded, mono, outline, box, monoBox, roundedBox

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .rounded: "Rounded"
        case .mono: "Mono"
        case .outline: "Outline"
        case .box: "Box"
        case .monoBox: "Mono box"
        case .roundedBox: "Rounded box"
        }
    }

    public var hasBox: Bool { self == .box || self == .monoBox || self == .roundedBox }
}

public enum RedactStyle: String, Codable, CaseIterable, Sendable {
    case pixelate, secureBlur, smoothBlur, blackOut

    public var title: String {
        switch self {
        case .pixelate: "Pixelate"
        case .secureBlur: "Blur (secure)"
        case .smoothBlur: "Blur (smooth)"
        case .blackOut: "Black out"
        }
    }
}

public enum SpotlightShape: String, Codable, CaseIterable, Sendable {
    case rectangle, roundedRectangle, ellipse

    public var title: String {
        switch self {
        case .rectangle: "Rectangle"
        case .roundedRectangle: "Rounded rectangle"
        case .ellipse: "Ellipse"
        }
    }
}

public enum CounterStyle: String, Codable, CaseIterable, Sendable {
    case numbers, roman, uppercase, lowercase

    public var title: String {
        switch self {
        case .numbers: "1 2 3"
        case .roman: "I II III"
        case .uppercase: "A B C"
        case .lowercase: "a b c"
        }
    }
}

/// Color, line width (base pixels) and shadow, shared by every object.
public struct ObjectStyle: Codable, Equatable, Sendable {
    public var color: RGBAColor
    public var lineWidth: Double
    public var shadow: Bool

    public init(color: RGBAColor, lineWidth: Double, shadow: Bool) {
        self.color = color
        self.lineWidth = lineWidth
        self.shadow = shadow
    }

    private enum CodingKeys: String, CodingKey {
        case color, lineWidth, shadow
    }

    /// `shadow` is optional on disk so a style saved before it existed still decodes; encoding stays synthesized.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decode(RGBAColor.self, forKey: .color)
        lineWidth = try container.decode(Double.self, forKey: .lineWidth)
        shadow = try container.decodeIfPresent(Bool.self, forKey: .shadow) ?? false
    }
}

/// The head is at `end`; a double-headed arrow has one at `start` too. `control` bends a curved arrow.
public struct ArrowShape: Codable, Equatable, Sendable {
    public var start: CGPoint
    public var end: CGPoint
    public var control: CGPoint?
    public var style: ArrowStyle

    public init(start: CGPoint, end: CGPoint, control: CGPoint? = nil, style: ArrowStyle) {
        self.start = start
        self.end = end
        self.control = control
        self.style = style
    }
}

/// Text laid out from `origin` (the box's top-left). `width` nil grows with the text on one line per paragraph; a width
/// wraps it into left-aligned paragraphs.
public struct TextObject: Codable, Equatable, Sendable {
    public var origin: CGPoint
    public var width: Double?
    public var string: String
    public var style: TextStyle
    public var fontSize: Double

    public init(origin: CGPoint, width: Double? = nil, string: String, style: TextStyle, fontSize: Double) {
        self.origin = origin
        self.width = width
        self.string = string
        self.style = style
        self.fontSize = fontSize
    }
}

/// `intensity` runs from 1 to 10.
public struct RedactObject: Codable, Equatable, Sendable {
    public var rect: CGRect
    public var style: RedactStyle
    public var intensity: Int

    public init(rect: CGRect, style: RedactStyle, intensity: Int) {
        self.rect = rect
        self.style = style
        self.intensity = intensity
    }
}

/// Dims everything outside `rect`; `opacity` is the dimming's.
public struct SpotlightObject: Codable, Equatable, Sendable {
    public var rect: CGRect
    public var shape: SpotlightShape
    public var opacity: Double

    public init(rect: CGRect, shape: SpotlightShape, opacity: Double) {
        self.rect = rect
        self.shape = shape
        self.opacity = opacity
    }
}

public struct CounterObject: Codable, Equatable, Sendable {
    public var center: CGPoint
    public var value: Int
    public var style: CounterStyle
    public var diameter: Double

    public init(center: CGPoint, value: Int, style: CounterStyle, diameter: Double) {
        self.center = center
        self.value = value
        self.style = style
        self.diameter = diameter
    }
}

public struct StrokeObject: Codable, Equatable, Sendable {
    public var points: [CGPoint]
    public var smoothed: Bool

    public init(points: [CGPoint], smoothed: Bool) {
        self.points = points
        self.smoothed = smoothed
    }
}

/// A highlighter mark: freehand `points` of `width`, or, when the Smart Highlighter snapped it to words, `rects`.
public struct HighlightObject: Codable, Equatable, Sendable {
    public var points: [CGPoint]
    public var rects: [CGRect]
    public var width: Double
    public var opacity: Double

    public init(points: [CGPoint], rects: [CGRect], width: Double, opacity: Double) {
        self.points = points
        self.rects = rects
        self.width = width
        self.opacity = opacity
    }
}

public struct ImageObject: Codable, Equatable, Sendable {
    public var rect: CGRect
    public var image: ImageRef

    public init(rect: CGRect, image: ImageRef) {
        self.rect = rect
        self.image = image
    }
}

public enum ObjectKind: Codable, Equatable, Sendable {
    case rectangle(CGRect)
    case filledRectangle(CGRect)
    case ellipse(CGRect)
    case line(start: CGPoint, end: CGPoint)
    case arrow(ArrowShape)
    case text(TextObject)
    case redact(RedactObject)
    case spotlight(SpotlightObject)
    case counter(CounterObject)
    case stroke(StrokeObject)
    case highlight(HighlightObject)
    case image(ImageObject)
}

/// One annotation. Geometry is in base pixels.
public struct AnnotationObject: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: ObjectKind
    public var style: ObjectStyle

    public init(id: UUID = UUID(), kind: ObjectKind, style: ObjectStyle) {
        self.id = id
        self.kind = kind
        self.style = style
    }

    /// Whether every number the object holds (its geometry, sizes, opacities, line width and color) is finite. Documents
    /// read from a file that may not be ours are checked with this (`AnnotationDocument.isWellFormed`).
    public var isFinite: Bool {
        let color = style.color
        return ([style.lineWidth, color.red, color.green, color.blue, color.alpha] + numbers).allSatisfy(\.isFinite)
    }

    /// The numbers in the object's kind.
    private var numbers: [Double] {
        func point(_ point: CGPoint) -> [Double] { [point.x, point.y] }
        func rect(_ rect: CGRect) -> [Double] { [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height] }
        switch kind {
        case .rectangle(let shape), .filledRectangle(let shape), .ellipse(let shape): return rect(shape)
        case .line(let start, let end): return point(start) + point(end)
        case .arrow(let arrow): return point(arrow.start) + point(arrow.end) + (arrow.control.map(point) ?? [])
        case .text(let text): return point(text.origin) + [text.width ?? 0, text.fontSize]
        case .redact(let redact): return rect(redact.rect)
        case .spotlight(let spotlight): return rect(spotlight.rect) + [spotlight.opacity]
        case .counter(let counter): return point(counter.center) + [counter.diameter]
        case .stroke(let stroke): return stroke.points.flatMap(point)
        case .highlight(let highlight):
            return highlight.points.flatMap(point) + highlight.rects.flatMap(rect) + [highlight.width, highlight.opacity]
        case .image(let image): return rect(image.rect)
        }
    }
}
