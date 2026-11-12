import CSCore
import CSTestSupport
import Testing
@testable import CSRecording

struct ClickRippleStyleTests {
    func style(size: ClickHighlightSize = .medium, color: ClickHighlightColor = .accent, style: ClickHighlightStyle = .outline,
               animates: Bool = true) -> ClickRippleStyle {
        ClickRippleStyle(size: size, color: color, style: style, animates: animates)
    }

    /// Animated, the ring grows from half size, then fades, whatever the button does. Not animated, it shows at full
    /// size while the button is down, for at least 0.15 s.
    @Test func notAnimatedHoldsWhileDown() {
        let still = style(animates: false)
        #expect(!still.animates)
        #expect(still.startScale == 1)
        #expect(still.growDuration == 0)
        #expect(still.fadeDuration == 0)
        #expect(still.minimumHold == 0.15)
        let animated = style(animates: true)
        #expect(animated.animates)
        #expect(animated.startScale == 0.5)
        #expect(animated.growDuration == 0.35)
        #expect(animated.fadeDuration == 0.25)
        #expect(animated.minimumHold == 0)
    }

    @MainActor
    @Test func preferencesDefaultsGiveMediumAccentOutlineAnimated() {
        withThrowawayDefaults("ripple") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(ClickRippleStyle(preferences: prefs) == style())
            prefs[Prefs.clickHighlightSize] = .large
            prefs[Prefs.clickHighlightColor] = .green
            prefs[Prefs.clickHighlightStyle] = .filled
            prefs[Prefs.clickHighlightAnimates] = false
            #expect(ClickRippleStyle(preferences: prefs) == style(size: .large, color: .green, style: .filled, animates: false))
        }
    }
}
