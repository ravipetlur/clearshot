import CoreGraphics
import CSCore

/// An aspect ratio a selection can be locked to: Freeform, one of the presets, or a custom W:H.
public enum SelectionRatio: Hashable, Sendable, Codable, JSONPrefValue {
    case freeform
    case preset(width: Int, height: Int)
    case custom(width: Int, height: Int)

    /// The ratio list's presets, in its order.
    public static let presets: [SelectionRatio] = [
        .preset(width: 1, height: 1), .preset(width: 4, height: 3), .preset(width: 3, height: 2),
        .preset(width: 16, height: 10), .preset(width: 16, height: 9), .preset(width: 5, height: 4),
        .preset(width: 9, height: 16), .preset(width: 3, height: 4), .preset(width: 2, height: 3),
        .preset(width: 4, height: 5),
    ]

    /// Width ÷ height, or nil for Freeform (and for a side that isn't positive).
    public var aspect: CGFloat? {
        guard case let (width, height)? = sides, width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }

    /// "Freeform", or "W:H" for a preset or a custom ratio.
    public var title: String {
        guard case let (width, height)? = sides else { return "Freeform" }
        return "\(width):\(height)"
    }

    /// The ratio turned on its side: a preset becomes its partner preset when there is one (16:9 ⇄ 9:16), else a custom
    /// ratio (16:10 → 10:16). Freeform stays.
    public func swapped() -> SelectionRatio {
        switch self {
        case .freeform:
            return .freeform
        case let .preset(width, height):
            let partner = SelectionRatio.preset(width: height, height: width)
            return Self.presets.contains(partner) ? partner : .custom(width: height, height: width)
        case let .custom(width, height):
            return .custom(width: height, height: width)
        }
    }

    private var sides: (width: Int, height: Int)? {
        switch self {
        case .freeform: nil
        case let .preset(width, height), let .custom(width, height): (width, height)
        }
    }
}

public extension Prefs {
    /// All-In-One's aspect ratio, kept between sessions.
    static let allInOneRatio = PrefKey("allInOneRatio", default: SelectionRatio.freeform)
}
