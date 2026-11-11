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

/// Color, line width (base pixels) and shadow, shared by every object. A rectangle or ellipse can also be filled:
/// `fillOpacity` is how much (0, the default, is no fill) and `fillColor` the color (nil: the stroke's color). The
/// rectangle, ellipse and arrow can be hand-drawn: `handDrawn` draws them as rough strokes, which `seed` fixes, so every
/// draw of the object is the same shape (text keeps its own flag, `TextObject.handDrawn`, since laying it out needs it).
public struct ObjectStyle: Codable, Equatable, Sendable {
    public var color: RGBAColor
    public var lineWidth: Double
    public var shadow: Bool
    public var fillColor: RGBAColor?
    public var fillOpacity: Double
    public var handDrawn: Bool
    public var seed: UInt32

    public init(color: RGBAColor, lineWidth: Double, shadow: Bool, fillColor: RGBAColor? = nil, fillOpacity: Double = 0,
                handDrawn: Bool = false, seed: UInt32 = 0) {
        self.color = color
        self.lineWidth = lineWidth
        self.shadow = shadow
        self.fillColor = fillColor
        self.fillOpacity = fillOpacity
        self.handDrawn = handDrawn
        self.seed = seed
    }

    /// Whether a shape of this style is filled.
    public var hasFill: Bool { fillOpacity > 0 }

    private enum CodingKeys: String, CodingKey {
        case color, lineWidth, shadow, fillColor, fillOpacity, handDrawn, seed
    }

    /// `shadow`, the fill, `handDrawn` and `seed` are optional on disk so a style saved before they existed still
    /// decodes, unfilled and clean.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decode(RGBAColor.self, forKey: .color)
        lineWidth = try container.decode(Double.self, forKey: .lineWidth)
        shadow = try container.decodeIfPresent(Bool.self, forKey: .shadow) ?? false
        fillColor = try container.decodeIfPresent(RGBAColor.self, forKey: .fillColor)
        let opacity = try container.decodeIfPresent(Double.self, forKey: .fillOpacity) ?? 0
        fillOpacity = opacity.isFinite ? min(max(opacity, 0), 1) : 0
        handDrawn = try container.decodeIfPresent(Bool.self, forKey: .handDrawn) ?? false
        seed = try container.decodeIfPresent(UInt32.self, forKey: .seed) ?? 0
    }

    /// The fill and the hand-drawn keys are written only when they matter, so a plain object's file is what it always was.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(color, forKey: .color)
        try container.encode(lineWidth, forKey: .lineWidth)
        try container.encode(shadow, forKey: .shadow)
        if hasFill {
            try container.encodeIfPresent(fillColor, forKey: .fillColor)
            try container.encode(fillOpacity, forKey: .fillOpacity)
        }
        if handDrawn { try container.encode(true, forKey: .handDrawn) }
        if seed != 0 { try container.encode(seed, forKey: .seed) }
    }
}

/// The head is at `end`; a double-headed arrow has one at `start` too. `control` bends the arrow, whatever its style (a curved one starts bent); nil is straight.
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
/// wraps it into left-aligned paragraphs. `handDrawn` sets it in a handwriting font.
public struct TextObject: Codable, Equatable, Sendable {
    public var origin: CGPoint
    public var width: Double?
    public var string: String
    public var style: TextStyle
    public var fontSize: Double
    public var handDrawn: Bool

    public init(origin: CGPoint, width: Double? = nil, string: String, style: TextStyle, fontSize: Double, handDrawn: Bool = false) {
        self.origin = origin
        self.width = width
        self.string = string
        self.style = style
        self.fontSize = fontSize
        self.handDrawn = handDrawn
    }

    private enum CodingKeys: String, CodingKey {
        case origin, width, string, style, fontSize, handDrawn
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        origin = try container.decode(CGPoint.self, forKey: .origin)
        width = try container.decodeIfPresent(Double.self, forKey: .width)
        string = try container.decode(String.self, forKey: .string)
        style = try container.decode(TextStyle.self, forKey: .style)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        handDrawn = try container.decodeIfPresent(Bool.self, forKey: .handDrawn) ?? false
    }

    /// Written only when set, so a document without hand-drawn text is written as before.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(origin, forKey: .origin)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encode(string, forKey: .string)
        try container.encode(style, forKey: .style)
        try container.encode(fontSize, forKey: .fontSize)
        if handDrawn { try container.encode(true, forKey: .handDrawn) }
    }
}

/// `intensity` runs from 1 to 10.
///
/// `isSecretsMask` marks the redactions the secrets check made (`AnnotationObject.pixelateMask`): the ones the sensitive-info
/// button takes out again. A redaction the person draws never has it. It is written only when set, so a document with none is
/// written exactly as before, and a document without the key reads as having none; an older build ignores the key it doesn't
/// know (and drops it if it saves the document, which makes the masks ordinary redactions there).
public struct RedactObject: Codable, Equatable, Sendable {
    public var rect: CGRect
    public var style: RedactStyle
    public var intensity: Int
    public var isSecretsMask: Bool

    public init(rect: CGRect, style: RedactStyle, intensity: Int, isSecretsMask: Bool = false) {
        self.rect = rect
        self.style = style
        self.intensity = intensity
        self.isSecretsMask = isSecretsMask
    }

    private enum CodingKeys: String, CodingKey {
        case rect, style, intensity, isSecretsMask
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rect = try container.decode(CGRect.self, forKey: .rect)
        style = try container.decode(RedactStyle.self, forKey: .style)
        intensity = try container.decode(Int.self, forKey: .intensity)
        isSecretsMask = try container.decodeIfPresent(Bool.self, forKey: .isSecretsMask) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rect, forKey: .rect)
        try container.encode(style, forKey: .style)
        try container.encode(intensity, forKey: .intensity)
        if isSecretsMask { try container.encode(true, forKey: .isSecretsMask) }
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
    /// The least and most an image can show through (1 = opaque).
    public static let opacityRange: ClosedRange<Double> = 0.05...1

    public var rect: CGRect
    public var image: ImageRef
    public var opacity: Double

    public init(rect: CGRect, image: ImageRef, opacity: Double = 1) {
        self.rect = rect
        self.image = image
        self.opacity = opacity
    }

    private enum CodingKeys: String, CodingKey {
        case rect, image, opacity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rect = try container.decode(CGRect.self, forKey: .rect)
        image = try container.decode(ImageRef.self, forKey: .image)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rect, forKey: .rect)
        try container.encode(image, forKey: .image)
        try container.encode(opacity, forKey: .opacity)
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
    /// A measurement: a line with end caps and its length (`RulerObject`).
    case ruler(RulerObject)
    case magnifier(MagnifierObject)
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
        let fill = style.fillColor.map { [$0.red, $0.green, $0.blue, $0.alpha] } ?? []
        return ([style.lineWidth, color.red, color.green, color.blue, color.alpha] + fill + numbers).allSatisfy(\.isFinite)
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
        case .image(let image): return rect(image.rect) + [image.opacity]
        case .ruler(let ruler): return point(ruler.start) + point(ruler.end)
        case .magnifier(let magnifier): return rect(magnifier.source) + rect(magnifier.callout)
        }
    }
}
