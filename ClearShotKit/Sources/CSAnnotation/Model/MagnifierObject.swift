import CoreGraphics
import Foundation

public enum MagnifierShape: String, Codable, CaseIterable, Sendable {
    case circle, roundedSquare

    public var title: String {
        switch self {
        case .circle: "Circle"
        case .roundedSquare: "Rounded square"
        }
    }
}

/// A zoomed callout of part of the picture: `source` (base pixels, the area magnified) drawn into `callout` (where it is
/// shown), with a connector from one to the other and, when `border` is on, an outline in the style's color and width. The
/// two keep one aspect ratio, so the zoom (the callout's size over the source's) is the same both ways; it stays within
/// `zoomRange` (`MagnifierGeometry`).
///
/// The callout shows the picture as it is shown, with the redactions and the pasted images on it, and never what a
/// redaction hides (`Renderer.drawMagnifier`). The other annotations aren't in it.
public struct MagnifierObject: Codable, Equatable, Sendable {
    /// The least and most a callout magnifies.
    public static let zoomRange: ClosedRange<Double> = 2...8
    /// A new magnifier's zoom.
    public static let defaultZoom = 3.0

    public var source: CGRect
    public var callout: CGRect
    public var shape: MagnifierShape
    public var border: Bool

    public init(source: CGRect, callout: CGRect, shape: MagnifierShape = .circle, border: Bool = true) {
        self.source = source
        self.callout = callout
        self.shape = shape
        self.border = border
    }

    /// The callout's width over the source's; 1 for a source with no width.
    public var zoom: Double {
        let source = source.standardized, callout = callout.standardized
        guard source.width > 0, source.width.isFinite, callout.width.isFinite else { return 1 }
        return callout.width / source.width
    }

    private enum CodingKeys: String, CodingKey {
        case source, callout, shape, border
    }

    /// `shape` and `border` are optional on disk, and fall back to a bordered circle.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(CGRect.self, forKey: .source)
        callout = try container.decode(CGRect.self, forKey: .callout)
        shape = try container.decodeIfPresent(MagnifierShape.self, forKey: .shape) ?? .circle
        border = try container.decodeIfPresent(Bool.self, forKey: .border) ?? true
    }
}
