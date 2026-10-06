import CoreGraphics

/// One screen as placement sees it: `NSScreen.frame` and `visibleFrame`, in AppKit global points.
public struct PinScreen: Equatable, Sendable {
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Where a new pin goes: over the area it was captured from, or the middle of the active screen.
public enum PinAnchor: Equatable, Sendable {
    /// The capture's rect in AppKit global points (the history item's `globalRect`).
    case capture(CGRect)
    case activeScreen
}

/// A new pin's window frame and zoom.
public struct PinStart: Equatable, Sendable {
    public let frame: CGRect
    public let zoom: Double
}

/// Where pins go: a new pin's frame and zoom, keeping it on screen, and moving it back after a display change. AppKit
/// global points; every origin it returns is on whole points.
public enum PinPlacement {
    /// How far each pin on the active screen is moved right and down from the previous one.
    public static let cascadeStep: CGFloat = 20
    /// A new pin larger than this fraction of the visible frame zooms out to fit it.
    public static let fitFraction: Double = 0.8
    /// A pin overlapping some screen by at least this much on both axes stays where it is after a display change.
    public static let minimumVisible: CGFloat = 20

    /// 100%, or the zoom that fits a larger image within `fitFraction` of the visible frame; never below 10%.
    public static func initialZoom(imagePoints: CGSize, visibleFrame: CGRect) -> Double {
        let width = Double(imagePoints.width), height = Double(imagePoints.height)
        let fitWidth = fitFraction * Double(visibleFrame.width), fitHeight = fitFraction * Double(visibleFrame.height)
        guard width > fitWidth || height > fitHeight else { return 1 }
        return max(PinGeometry.zoomLimits.lowerBound, min(fitWidth / width, fitHeight / height))
    }

    /// A new pin. Over a capture: on the screen holding most of the captured rect, centred on it (exactly over it when
    /// the image is the rect's size). On the active screen, or when the rect is empty or off every screen: centred,
    /// then `cascade` steps right and down, starting over from the centre when that would leave the visible frame.
    /// Either way, kept inside the visible frame.
    public static func start(imagePoints: CGSize, anchor: PinAnchor, screens: [PinScreen], active: PinScreen,
                             cascade: Int) -> PinStart {
        if case .capture(let rect) = anchor, !rect.isEmpty, let screen = screen(holdingMostOf: rect, in: screens) {
            let zoom = initialZoom(imagePoints: imagePoints, visibleFrame: screen.visibleFrame)
            let size = PinGeometry.windowSize(imagePoints: imagePoints, zoom: zoom)
            let frame = centred(size, on: CGPoint(x: rect.midX, y: rect.midY))
            return PinStart(frame: clamped(frame, to: screen.visibleFrame), zoom: zoom)
        }
        let visible = active.visibleFrame
        let zoom = initialZoom(imagePoints: imagePoints, visibleFrame: visible)
        let size = PinGeometry.windowSize(imagePoints: imagePoints, zoom: zoom)
        let centre = centred(size, on: CGPoint(x: visible.midX, y: visible.midY))
        let step = cascadeStep * CGFloat(cascade)
        let cascaded = centre.offsetBy(dx: step, dy: -step)
        return PinStart(frame: clamped(visible.contains(cascaded) ? cascaded : centre, to: visible), zoom: zoom)
    }

    /// `frame` moved inside `visibleFrame`, its origin floored to whole points. On an axis where it is larger, it aligns
    /// to the left or top edge.
    public static func clamped(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let x = frame.width > visibleFrame.width
            ? visibleFrame.minX
            : min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
        let y = frame.height > visibleFrame.height
            ? visibleFrame.maxY - frame.height
            : min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        return CGRect(x: x.rounded(.down), y: y.rounded(.down), width: frame.width, height: frame.height)
    }

    /// After a display change: nil when some screen still shows at least `minimumVisible` × `minimumVisible` pt of the
    /// pin (leave it there); otherwise the pin centred on the main screen.
    public static func rescued(_ frame: CGRect, screens: [PinScreen], main: PinScreen) -> CGRect? {
        let stillShown = screens.contains { screen in
            let overlap = screen.frame.intersection(frame)
            return !overlap.isNull && overlap.width >= minimumVisible && overlap.height >= minimumVisible
        }
        guard !stillShown else { return nil }
        let visible = main.visibleFrame
        return clamped(centred(frame.size, on: CGPoint(x: visible.midX, y: visible.midY)), to: visible)
    }

    /// The screen whose frame overlaps the most of `rect`, or nil when it overlaps none.
    private static func screen(holdingMostOf rect: CGRect, in screens: [PinScreen]) -> PinScreen? {
        var best: PinScreen?
        var bestArea: CGFloat = 0
        for screen in screens {
            let overlap = screen.frame.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                best = screen
                bestArea = area
            }
        }
        return best
    }

    /// A frame of `size` centred on `point`. (`clamped` puts the origin on whole points.)
    private static func centred(_ size: CGSize, on point: CGPoint) -> CGRect {
        CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
    }
}
