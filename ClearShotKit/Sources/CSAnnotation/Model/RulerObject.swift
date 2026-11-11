import CoreGraphics
import Foundation

/// A measurement imprinted on the picture: a thin line from `start` to `end` (base pixels) with a perpendicular cap at each
/// end and the length written beside it, in the object's color.
///
/// The length is never stored. It is what the two ends are apart as the picture is now (through a resize or a turn), written
/// in the unit Settings › Annotate › Show sizes in has now, so the label can't go stale. `label` holds that text for the one
/// draw: `AnnotationDocument.visualOrder` fills it in (`RulerGeometry.labelText`), the renderer draws it, and it is never
/// written to a file.
public struct RulerObject: Codable, Equatable, Sendable {
    public var start: CGPoint
    public var end: CGPoint
    /// The text the renderer writes beside the line; nil draws none. Set by `AnnotationDocument.visualOrder`, not saved.
    public var label: String?

    public init(start: CGPoint, end: CGPoint, label: String? = nil) {
        self.start = start
        self.end = end
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case start, end
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(CGPoint.self, forKey: .start)
        end = try container.decode(CGPoint.self, forKey: .end)
        label = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
    }
}
