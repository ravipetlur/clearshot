import CoreGraphics
import CSCore

/// How a highlighted click is drawn: a ring, outlined or filled, that grows and fades or is held while the button is
/// down. The app's overlay layers and Settings' preview both draw from this.
public struct ClickRippleStyle: Sendable, Equatable {
    /// A filled ring's fill: its colour at this opacity, inside its rim.
    public static let fillOpacity = 0.35

    /// In points, at full size.
    public let diameter: CGFloat
    /// The ring's stroke: 3 pt outlined, a 2 pt rim filled.
    public let lineWidth: CGFloat
    public let color: ClickHighlightColor
    public let isFilled: Bool
    public let animates: Bool
    /// Animated: the ring grows from `startScale` to full size over `growDuration`, then fades over `fadeDuration`.
    /// Not animated: both are zero and `startScale` is 1.
    public let growDuration: Double
    public let fadeDuration: Double
    public let startScale: CGFloat
    /// Not animated: the ring shows while the button is down, and for at least this long. Zero when animated.
    public let minimumHold: Double

    public init(size: ClickHighlightSize, color: ClickHighlightColor, style: ClickHighlightStyle, animates: Bool) {
        diameter = switch size {
        case .small: 28
        case .medium: 40
        case .large: 56
        }
        isFilled = style == .filled
        lineWidth = isFilled ? 2 : 3
        self.color = color
        self.animates = animates
        growDuration = animates ? 0.35 : 0
        fadeDuration = animates ? 0.25 : 0
        startScale = animates ? 0.5 : 1
        minimumHold = animates ? 0 : 0.15
    }

    /// The style Settings › Screen Recording has chosen.
    @MainActor
    public init(preferences: Preferences) {
        self.init(size: preferences[Prefs.clickHighlightSize], color: preferences[Prefs.clickHighlightColor],
                  style: preferences[Prefs.clickHighlightStyle], animates: preferences[Prefs.clickHighlightAnimates])
    }
}
