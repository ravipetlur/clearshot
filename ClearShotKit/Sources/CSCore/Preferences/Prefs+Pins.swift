import Foundation

/// How a pin is drawn. Each pin starts from the defaults in Settings › Advanced and can change its own.
public struct PinStyle: Equatable, Sendable {
    public var shadow: Bool
    public var roundedCorners: Bool
    public var border: Bool

    public init(shadow: Bool, roundedCorners: Bool, border: Bool) {
        self.shadow = shadow
        self.roundedCorners = roundedCorners
        self.border = border
    }

    /// The style a new pin starts with.
    @MainActor
    public static func defaults(in preferences: Preferences) -> PinStyle {
        PinStyle(shadow: preferences[Prefs.pinShadow],
                 roundedCorners: preferences[Prefs.pinRoundedCorners],
                 border: preferences[Prefs.pinBorder])
    }

    /// What is actually drawn. A transparent image has no card to round or outline, so it keeps only the shadow, which
    /// follows its alpha.
    public func effective(isTransparent: Bool) -> PinStyle {
        guard isTransparent else { return self }
        return PinStyle(shadow: shadow, roundedCorners: false, border: false)
    }
}

public extension Prefs {
    // Pin defaults (Advanced pane)
    static let pinShadow = PrefKey("pinShadow", default: true)
    static let pinRoundedCorners = PrefKey("pinRoundedCorners", default: true)
    static let pinBorder = PrefKey("pinBorder", default: true)
}
