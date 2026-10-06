import AppKit
import CSRecording
import QuartzCore

/// A highlighted click on screen: its layer, and when it appeared (a held ring's minimum hold counts from there).
struct ClickRing {
    let layer: CAShapeLayer
    let shownAt: CFTimeInterval
}

/// One highlighted click as a Core Animation layer: a ring of the style's diameter, outlined, or filled at 35% inside a
/// 2 pt rim, in the chosen colour. Animated, it grows from half size, then fades and goes by itself; not animated, it
/// shows at full size until its mouse-up (`release`), for at least the style's minimum hold. The recording's click
/// overlay and Settings' preview both draw with this, through `ClickRings`.
enum ClickRippleLayer {
    private static let animationKey = "ripple"

    /// A ring centred on `point`, in `layer`'s coordinates, added to `layer` and, with the style, animated.
    @discardableResult
    static func ripple(style: ClickRippleStyle, at point: CGPoint, in layer: CALayer) -> ClickRing {
        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: style.diameter, height: style.diameter)
        ring.position = point
        ring.contentsScale = layer.contentsScale
        // Inset by half the line, so the stroke stays inside the diameter.
        let inset = style.lineWidth / 2
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: inset, dy: inset), transform: nil)
        let color = style.color.nsColor
        ring.lineWidth = style.lineWidth
        ring.strokeColor = color.cgColor
        ring.fillColor = style.isFilled ? color.withAlphaComponent(ClickRippleStyle.fillOpacity).cgColor : nil
        withoutImplicitAnimation {
            if style.animates {
                // Its resting state is gone: the animation shows it, and nothing flashes back as it ends.
                ring.opacity = 0
            }
            layer.addSublayer(ring)
        }
        if style.animates {
            animate(ring, style: style)
        }
        return ClickRing(layer: ring, shownAt: CACurrentMediaTime())
    }

    /// The mouse-up of a held ring: it goes once it has shown for the style's minimum hold. An animated ring goes by
    /// itself, so this leaves it alone.
    static func release(_ ring: ClickRing, style: ClickRippleStyle) {
        guard ring.layer.animation(forKey: animationKey) == nil else { return }
        let remaining = style.minimumHold - (CACurrentMediaTime() - ring.shownAt)
        if remaining > 0 {
            remove(ring.layer, after: remaining)
        } else {
            withoutImplicitAnimation { ring.layer.removeFromSuperlayer() }
        }
    }

    /// Every ring in `layer` goes at once, animating or held.
    static func removeAll(from layer: CALayer) {
        withoutImplicitAnimation { layer.sublayers?.forEach { $0.removeFromSuperlayer() } }
    }

    /// Grows from the start scale to full size, then fades out, then goes.
    private static func animate(_ ring: CAShapeLayer, style: ClickRippleStyle) {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = style.startScale
        grow.toValue = 1
        grow.duration = style.growDuration
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = style.growDuration
        fade.duration = style.fadeDuration
        // Opaque while it grows, before the fade begins.
        fade.fillMode = .backwards
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = style.growDuration + style.fadeDuration
        ring.add(group, forKey: animationKey)
        remove(ring, after: group.duration)
    }

    private static func remove(_ ring: CALayer, after seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            withoutImplicitAnimation { ring.removeFromSuperlayer() }
        }
    }

    /// Rings appear and go at once: a layer's implicit fade would soften the click.
    private static func withoutImplicitAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

/// The rings one surface draws (the recording's click overlay, Settings' preview), by mouse button: each press may draw
/// a ring; not animated, it is held until that button's mouse-up. A press first lets go of the button's last held ring,
/// so a mouse-up that never came never leaves a ring up for good.
struct ClickRings<Button: Hashable> {
    private var held: [Button: ClickRing] = [:]

    /// `button` went down: a ring at `point` in `layer`, or none when `point` is nil (the click doesn't count).
    mutating func press(_ button: Button, at point: CGPoint?, style: ClickRippleStyle, in layer: CALayer) {
        release(button, style: style)
        guard let point else { return }
        let ring = ClickRippleLayer.ripple(style: style, at: point, in: layer)
        if !style.animates {
            held[button] = ring
        }
    }

    /// `button` went up: its held ring goes, after the minimum hold.
    mutating func release(_ button: Button, style: ClickRippleStyle) {
        guard let ring = held.removeValue(forKey: button) else { return }
        ClickRippleLayer.release(ring, style: style)
    }

    /// Every ring in `layer` goes now, held or animating.
    mutating func removeAll(from layer: CALayer) {
        held = [:]
        ClickRippleLayer.removeAll(from: layer)
    }
}

private extension ClickHighlightColor {
    var nsColor: NSColor {
        switch self {
        case .accent: .controlAccentColor
        case .red: .systemRed
        case .purple: .systemPurple
        case .green: .systemGreen
        case .orange: .systemOrange
        case .yellow: .systemYellow
        }
    }
}
