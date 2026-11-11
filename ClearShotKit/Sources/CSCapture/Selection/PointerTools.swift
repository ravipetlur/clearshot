import CoreGraphics

/// Where the pointer may be. Points are AppKit global points (y up), as `NSEvent.mouseLocation` gives them, so a display's
/// pointer positions are `minX <= x < maxX` and `minY < y <= maxY` (the top row belongs to the display, as in
/// `DisplayInfo.containsMouse`). A pointer clamped to the far edge sits a point inside it.
public enum PointerBounds {
    /// `point` if some display holds it, else the nearest position on the nearest display.
    public static func clamp(_ point: CGPoint, to displays: [CGRect]) -> CGPoint {
        var best: (point: CGPoint, distance: CGFloat)?
        for frame in displays where frame.width > 0 && frame.height > 0 {
            let clamped = CGPoint(x: min(max(point.x, frame.minX), max(frame.maxX - 1, frame.minX)),
                                  y: min(max(point.y, min(frame.minY + 1, frame.maxY)), frame.maxY))
            let distance = hypot(clamped.x - point.x, clamped.y - point.y)
            if distance == 0 { return point }
            if best == nil || distance < best!.distance { best = (clamped, distance) }
        }
        return best?.point ?? point
    }
}

/// W, A, S and D nudging the pointer in plain Capture Area: one point, or ten with ⇧.
public enum PointerNudge {
    public enum Direction: Sendable, Equatable {
        case up, down, left, right
    }

    public static let step: CGFloat = 1
    public static let largeStep: CGFloat = 10

    /// The pointer after one nudge from `point`, kept on the displays (it crosses to a neighbouring display where they touch).
    public static func target(from point: CGPoint, _ direction: Direction, large: Bool, displays: [CGRect]) -> CGPoint {
        let distance = large ? largeStep : step
        var moved = point
        switch direction {
        case .up: moved.y += distance
        case .down: moved.y -= distance
        case .left: moved.x -= distance
        case .right: moved.x += distance
        }
        return PointerBounds.clamp(moved, to: displays)
    }
}

/// ⌘ held: the pointer moves at a quarter of the hand's speed.
///
/// The overlay can't slow the system pointer, so it follows it: each move event carries the hardware's delta; the overlay
/// puts the pointer at the last precise position plus a quarter of that delta (`CGWarpMouseCursorPosition`, then
/// `CGAssociateMouseAndMouseCursorPosition(1)` to end the pause in pointer events a warp causes) and uses that point
/// instead of where the system put the pointer. The mouse is never disassociated from the cursor, so nothing has to be
/// restored if the overlay ends mid-gesture. The position is kept in `anchor` unrounded, so slow movement accumulates
/// instead of stalling.
public struct PrecisionPointer: Sendable, Equatable {
    public static let factor: CGFloat = 0.25
    /// How far the system's pointer may sit from the anchor, before an event's delta, without the anchor being given up
    /// (it was moved by something else: a nudge, a click's own warp). Rounding by the system stays within it.
    public static let resyncDistance: CGFloat = 1.5

    public private(set) var anchor: CGPoint?

    public init() {}

    /// Forget the anchor: ⌘ was released, or the pointer was moved some other way.
    public mutating func reset() { anchor = nil }

    /// The pointer's new position for a move event: `delta` is the hardware's movement (y up) and `current` where the
    /// system now has the pointer, after that movement.
    public mutating func move(byHardwareDelta delta: CGVector, systemPointer current: CGPoint, displays: [CGRect]) -> CGPoint {
        let before = CGPoint(x: current.x - delta.dx, y: current.y - delta.dy)
        var from = anchor ?? before
        if hypot(from.x - before.x, from.y - before.y) > Self.resyncDistance { from = before }
        let target = CGPoint(x: from.x + delta.dx * Self.factor, y: from.y + delta.dy * Self.factor)
        let clamped = PointerBounds.clamp(target, to: displays)
        anchor = clamped
        return clamped
    }
}

/// Hold Z: a lens with the area around the pointer at 10×.
public enum ZoomLens {
    public static let factor: CGFloat = 10
    public static let side: CGFloat = 480
    /// The gap between the pointer and the lens.
    public static let gap: CGFloat = 24

    /// The lens on `bounds` (a display, y up): below and right of the pointer, on the other side of it where that would
    /// run off the display, and in any case kept inside it.
    public static func frame(near cursor: CGPoint, side: CGFloat = side, gap: CGFloat = gap, in bounds: CGRect) -> CGRect {
        var origin = CGPoint(x: cursor.x + gap, y: cursor.y - gap - side)
        if origin.x + side > bounds.maxX { origin.x = cursor.x - gap - side }
        if origin.y < bounds.minY { origin.y = cursor.y + gap }
        origin.x = max(min(origin.x, bounds.maxX - side), bounds.minX)
        origin.y = max(min(origin.y, bounds.maxY - side), bounds.minY)
        return CGRect(x: origin.x, y: origin.y, width: min(side, bounds.width), height: min(side, bounds.height))
    }

    /// Pixels the lens samples across: the lens's side over the factor, in points, at the display's scale.
    public static func sampleSide(scale: CGFloat, side: CGFloat = side, factor: CGFloat = factor) -> Int {
        max(Int((side / factor * scale).rounded()), 1)
    }

    /// The part of the display's image the lens shows, by the magnifier's sampling (`Magnifier.sampleRect`).
    public static func sampleRect(centeredOn pixel: CGPoint, scale: CGFloat, imageSize: CGSize) -> CGRect {
        Magnifier.sampleRect(centeredOn: pixel, gridSize: sampleSide(scale: scale), imageSize: imageSize)
    }

    /// The pixel under the pointer as a rect in the lens (top-left origin, `lensSide` square) for marking it, or nil when
    /// the pixel is outside what the lens samples.
    public static func markerRect(pixel: CGPoint, sample: CGRect, lensSide: CGFloat) -> CGRect? {
        guard sample.width > 0, sample.height > 0, sample.contains(pixel) else { return nil }
        let cellWidth = lensSide / sample.width
        let cellHeight = lensSide / sample.height
        return CGRect(x: (pixel.x.rounded(.down) - sample.minX) * cellWidth, y: (pixel.y.rounded(.down) - sample.minY) * cellHeight,
                      width: cellWidth, height: cellHeight)
    }
}
