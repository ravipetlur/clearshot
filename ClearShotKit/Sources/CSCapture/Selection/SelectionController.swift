import CoreGraphics

public struct SelectionModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = SelectionModifiers(rawValue: 1 << 0)
    public static let option = SelectionModifiers(rawValue: 1 << 1)
    public static let command = SelectionModifiers(rawValue: 1 << 2)
    public static let control = SelectionModifiers(rawValue: 1 << 3)
}

public enum ArrowKey: Sendable {
    case left, right, up, down
}

/// The eight grips of an adjusting selection: its corners and edge midpoints. "Top" is the rect's `maxY` (AppKit, y up).
public enum SelectionHandle: CaseIterable, Sendable, Equatable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Which way the handle pulls on each axis: -1 toward `minX`/`minY`, 1 toward `maxX`/`maxY`, 0 not on that axis.
    var pull: (x: CGFloat, y: CGFloat) {
        switch self {
        case .topLeft: (-1, 1)
        case .top: (0, 1)
        case .topRight: (1, 1)
        case .right: (1, 0)
        case .bottomRight: (1, -1)
        case .bottom: (0, -1)
        case .bottomLeft: (-1, -1)
        case .left: (-1, 0)
        }
    }

    var isCorner: Bool { pull.x != 0 && pull.y != 0 }

    /// Where the handle sits on `rect`.
    public func point(on rect: CGRect) -> CGPoint {
        CGPoint(x: pull.x < 0 ? rect.minX : pull.x > 0 ? rect.maxX : rect.midX,
                y: pull.y < 0 ? rect.minY : pull.y > 0 ? rect.maxY : rect.midY)
    }
}

/// Area selection as a pure state machine. Points and rects are AppKit global points (y up).
///
/// With `confirmsOnMouseUp` (the capture overlay) a drag ends the selection. Without it (All-In-One, scrolling capture)
/// the selection stays `adjusting` after the drag: its handles resize it, a drag inside moves it, a drag outside
/// replaces it, and a click outside that is too small to be a selection keeps it.
public struct SelectionController: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle, dragging, moving, adjusting, done, cancelled
        case resizing(SelectionHandle)
    }

    public static let minimumSize: CGFloat = 4
    /// How far from a handle (per axis), or from an edge, a point still grabs it.
    public static let handleTolerance: CGFloat = 6

    public private(set) var phase: Phase = .idle
    public private(set) var rect: CGRect = .zero
    /// The modifier keys held at the mouse-down that began the current drag, `[]` before any. A mouse-down that moves
    /// an adjusting selection keeps them. Unlike the modifiers each drag event passes, which shape the rect as they
    /// change (⇧ squares it while held), these are fixed for the selection: the ⇧ that skips the background preset is
    /// read here, so a ⇧ pressed mid-drag only squares, and one held as the drag began still skips after it is
    /// released.
    public private(set) var startModifiers: SelectionModifiers = []
    public let bounds: CGRect
    public let confirmsOnMouseUp: Bool
    public var snapLines: SnapLines
    public var snapThreshold: CGFloat = 8
    /// Width ÷ height that new drags, handle resizes, typed sizes and `fitToAspectRatio` keep; nil is freeform. While it
    /// is set, ⇧ adds nothing.
    public var aspectRatio: CGFloat?

    /// The fixed corner of the drag, or its center while ⌥ is held.
    private var anchor = CGPoint.zero
    private var pointer = CGPoint.zero
    private var lastMovePoint = CGPoint.zero
    /// True when a move started from `adjusting` (dragging inside the rect), so mouse-up returns there.
    private var movingFromAdjusting = false
    /// The selection a new drag from `adjusting` replaces, brought back if that drag ends too small (a stray click).
    private var replacedSelection: (rect: CGRect, startModifiers: SelectionModifiers)?
    /// The rect as a handle resize began; the handle's pull is measured from it.
    private var resizeStart = CGRect.zero
    /// From the mouse-down to the grabbed handle, so a handle follows the pointer without jumping to it.
    private var grabOffset = CGPoint.zero

    /// Handles, resizing and the stray-click revert belong to a selection that stays adjustable after the drag.
    private var adjustsAfterDrag: Bool { !confirmsOnMouseUp }

    public init(bounds: CGRect, confirmsOnMouseUp: Bool = true, snapLines: SnapLines = SnapLines()) {
        self.bounds = bounds
        self.confirmsOnMouseUp = confirmsOnMouseUp
        self.snapLines = snapLines
    }

    /// `modifiers` are the keys held at the mouse-down; they become `startModifiers` when it begins a drag.
    public mutating func mouseDown(at point: CGPoint, modifiers: SelectionModifiers = []) {
        if let handle = handle(at: point) {
            let grabbed = handle.point(on: rect)
            resizeStart = rect
            grabOffset = CGPoint(x: grabbed.x - point.x, y: grabbed.y - point.y)
            phase = .resizing(handle)
            return
        }
        switch phase {
        case .adjusting where rect.contains(point):
            phase = .moving
            movingFromAdjusting = true
            lastMovePoint = point
        case .idle, .adjusting:
            replacedSelection = phase == .adjusting && adjustsAfterDrag ? (rect, startModifiers) : nil
            anchor = clamp(point)
            pointer = anchor
            rect = CGRect(origin: anchor, size: .zero)
            movingFromAdjusting = false
            startModifiers = modifiers
            phase = .dragging
        default:
            break
        }
    }

    /// The handle under `point`: corners first (within `handleTolerance` of the corner on both axes), then edges (within
    /// `handleTolerance` of the edge line, between the corners). Only an adjusting selection that stays adjustable after
    /// its drag has handles.
    public func handle(at point: CGPoint) -> SelectionHandle? {
        guard phase == .adjusting, adjustsAfterDrag else { return nil }
        let tolerance = Self.handleTolerance
        let distance = { (handle: SelectionHandle) -> CGFloat in
            let spot = handle.point(on: rect)
            return max(abs(point.x - spot.x), abs(point.y - spot.y))
        }
        let corners = SelectionHandle.allCases.filter(\.isCorner).filter { distance($0) <= tolerance }
        if let corner = corners.min(by: { distance($0) < distance($1) }) { return corner }
        let alongX = point.x >= rect.minX && point.x <= rect.maxX
        let alongY = point.y >= rect.minY && point.y <= rect.maxY
        let edges: [(SelectionHandle, CGFloat)] = [
            (.top, alongX ? abs(point.y - rect.maxY) : .infinity),
            (.right, alongY ? abs(point.x - rect.maxX) : .infinity),
            (.bottom, alongX ? abs(point.y - rect.minY) : .infinity),
            (.left, alongY ? abs(point.x - rect.minX) : .infinity),
        ]
        guard let nearest = edges.min(by: { $0.1 < $1.1 }), nearest.1 <= tolerance else { return nil }
        return nearest.0
    }

    public mutating func mouseDragged(to point: CGPoint, modifiers: SelectionModifiers) {
        switch phase {
        case .dragging:
            pointer = point
            rect = rectFromDrag(modifiers)
        case .moving:
            move(by: CGPoint(x: point.x - lastMovePoint.x, y: point.y - lastMovePoint.y))
            lastMovePoint = point
        case .resizing(let handle):
            rect = resized(handle, to: point, modifiers: modifiers)
        default:
            break
        }
    }

    public mutating func mouseUp(at point: CGPoint, modifiers: SelectionModifiers) {
        switch phase {
        case .dragging:
            pointer = point
            rect = rectFromDrag(modifiers)
        case .moving:
            move(by: CGPoint(x: point.x - lastMovePoint.x, y: point.y - lastMovePoint.y))
            lastMovePoint = point
            if movingFromAdjusting {
                movingFromAdjusting = false
                phase = .adjusting
                return
            }
        case .resizing(let handle):
            rect = resized(handle, to: point, modifiers: modifiers)
            phase = .adjusting
            return
        default:
            return
        }
        defer { replacedSelection = nil }
        if rect.width < Self.minimumSize || rect.height < Self.minimumSize {
            if let replacedSelection {
                // A stray click: the selection it would have replaced stays.
                rect = replacedSelection.rect
                startModifiers = replacedSelection.startModifiers
                phase = .adjusting
            } else {
                phase = .idle
                rect = .zero
                startModifiers = []
            }
            return
        }
        phase = confirmsOnMouseUp ? .done : .adjusting
    }

    /// Space while dragging moves the whole selection until Space is released.
    public mutating func spaceDown(at point: CGPoint) {
        guard phase == .dragging else { return }
        phase = .moving
        lastMovePoint = point
    }

    public mutating func spaceUp(at point: CGPoint) {
        guard phase == .moving, !movingFromAdjusting else { return }
        phase = .dragging
    }

    /// Arrows move the selection; ⇧ resizes it (growing stops at the display edge); ⌘ makes 10 pt steps. Only in
    /// `adjusting`.
    public mutating func arrow(_ key: ArrowKey, modifiers: SelectionModifiers) {
        guard phase == .adjusting else { return }
        let step: CGFloat = modifiers.contains(.command) ? 10 : 1
        var next = rect
        if modifiers.contains(.shift) {
            switch key {
            case .right: next.size.width = max(next.width, min(next.width + step, bounds.maxX - next.minX))
            case .left: next.size.width = max(Self.minimumSize, next.width - step)
            case .up: next.size.height = max(next.height, min(next.height + step, bounds.maxY - next.minY))
            case .down: next.size.height = max(Self.minimumSize, next.height - step)
            }
        } else {
            switch key {
            case .right: next.origin.x += step
            case .left: next.origin.x -= step
            case .up: next.origin.y += step
            case .down: next.origin.y -= step
            }
        }
        rect = keepInside(next)
    }

    public mutating func confirm() {
        if phase == .adjusting { phase = .done }
    }

    public mutating func cancel() {
        phase = .cancelled
    }

    /// Starts from a known rect, ready for adjusting. A remembered area or the display has no drag start, so
    /// `startModifiers` is `[]`; a selection dragged out elsewhere (All-In-One's, handed to a scrolling capture) brings
    /// that drag's, which it keeps, as a dragged one does, until a fresh drag replaces it.
    ///
    /// Only applies from `idle` or `adjusting`, and only when the part of `newRect` inside `bounds` is at least
    /// `minimumSize` in both directions. Otherwise nothing changes and it returns `false`.
    @discardableResult
    public mutating func setRect(_ newRect: CGRect, startModifiers: SelectionModifiers = []) -> Bool {
        guard phase == .idle || phase == .adjusting else { return false }
        let clamped = newRect.standardized.intersection(bounds)
        guard !clamped.isNull, clamped.width >= Self.minimumSize, clamped.height >= Self.minimumSize else { return false }
        rect = clamped
        self.startModifiers = startModifiers
        phase = .adjusting
        return true
    }

    /// A typed size in points; nil keeps that side. With `aspectRatio` the given side drives the other (the width when
    /// both are given). Sides are rounded to whole points and kept within `minimumSize`…`bounds` (with a ratio, both
    /// scale together to fit). The top-left corner stays unless the rect would leave `bounds`, then it slides back in.
    /// Only in `adjusting`; returns whether it applied.
    @discardableResult
    public mutating func setSize(width: CGFloat?, height: CGFloat?) -> Bool {
        guard phase == .adjusting, width != nil || height != nil,
              width?.isFinite ?? true, height?.isFinite ?? true else { return false }
        let size: CGSize
        if let ratio = lockedRatio(aspectRatio) {
            let driven: CGSize
            switch (width, height) {
            case let (width?, _):
                let typed = max(width.rounded(), Self.minimumSize)
                driven = CGSize(width: typed, height: typed / ratio)
            case let (nil, height?):
                let typed = max(height.rounded(), Self.minimumSize)
                driven = CGSize(width: typed * ratio, height: typed)
            case (nil, nil):
                return false
            }
            let fitted = fitted(driven, ratio: ratio, within: bounds.size)
            size = CGSize(width: clampSide(fitted.width.rounded(), to: bounds.width),
                          height: clampSide(fitted.height.rounded(), to: bounds.height))
        } else {
            size = CGSize(width: width.map { clampSide($0.rounded(), to: bounds.width) } ?? rect.width,
                          height: height.map { clampSide($0.rounded(), to: bounds.height) } ?? rect.height)
        }
        rect = keepInside(CGRect(x: rect.minX, y: rect.maxY - size.height, width: size.width, height: size.height))
        return true
    }

    /// Reshapes an adjusting selection to `aspectRatio`: the width and top-left corner stay and the height follows, both
    /// scaling down together if that would reach below `bounds`. Nothing happens without a ratio or outside `adjusting`.
    public mutating func fitToAspectRatio() {
        guard phase == .adjusting, let ratio = lockedRatio(aspectRatio) else { return }
        let room = CGSize(width: bounds.maxX - rect.minX, height: rect.maxY - bounds.minY)
        let size = fitted(CGSize(width: rect.width, height: rect.width / ratio), ratio: ratio, within: room)
        rect = keepInside(CGRect(x: rect.minX, y: rect.maxY - size.height, width: size.width, height: size.height))
    }

    // MARK: Helpers

    private func rectFromDrag(_ modifiers: SelectionModifiers) -> CGRect {
        // A ratio is ⇧'s square generalised: width ÷ height fixed, 1 for the square.
        let ratio: CGFloat? = lockedRatio(aspectRatio) ?? (modifiers.contains(.shift) ? 1 : nil)
        let fromCenter = modifiers.contains(.option)
        var target = pointer
        if ratio == nil, !fromCenter {
            target = snapLines.snapped(target, threshold: snapThreshold)
        }
        let dx = target.x - anchor.x
        let dy = target.y - anchor.y
        // Room from the anchor to each edge of `bounds`. Extents are limited to it before the rect is built, so the
        // ⇧ square, a ratio and the ⌥ center keep their shape at the display edge instead of being clipped afterwards.
        let roomLeft = max(0, anchor.x - bounds.minX)
        let roomRight = max(0, bounds.maxX - anchor.x)
        let roomDown = max(0, anchor.y - bounds.minY)
        let roomUp = max(0, bounds.maxY - anchor.y)

        let raw: CGRect
        if fromCenter {
            var halfWidth = min(abs(dx), roomLeft, roomRight)
            var halfHeight = min(abs(dy), roomDown, roomUp)
            if let ratio {
                halfWidth = min(max(abs(dx), abs(dy) * ratio), roomLeft, roomRight, roomDown * ratio, roomUp * ratio)
                halfHeight = halfWidth / ratio
            }
            raw = CGRect(x: anchor.x - halfWidth, y: anchor.y - halfHeight, width: halfWidth * 2, height: halfHeight * 2)
        } else {
            // A zero offset counts as positive, matching the sign used for the ⇧ square.
            let roomX = dx < 0 ? roomLeft : roomRight
            let roomY = dy < 0 ? roomDown : roomUp
            var width = min(abs(dx), roomX)
            var height = min(abs(dy), roomY)
            if let ratio {
                width = min(max(abs(dx), abs(dy) * ratio), roomX, roomY * ratio)
                height = width / ratio
            }
            raw = CGRect(x: dx < 0 ? anchor.x - width : anchor.x, y: dy < 0 ? anchor.y - height : anchor.y, width: width, height: height)
        }
        let clamped = raw.intersection(bounds)
        return clamped.isNull ? .zero : clamped
    }

    private mutating func move(by delta: CGPoint) {
        let moved = keepInside(rect.offsetBy(dx: delta.x, dy: delta.y))
        let actual = CGPoint(x: moved.minX - rect.minX, y: moved.minY - rect.minY)
        rect = moved
        anchor = CGPoint(x: anchor.x + actual.x, y: anchor.y + actual.y)
        pointer = CGPoint(x: pointer.x + actual.x, y: pointer.y + actual.y)
    }

    /// The rect while `handle` is dragged to `point`. The handle's edges follow the pointer (less the grab offset), within
    /// `bounds`, never below `minimumSize` and never past the opposite edge. A ratio (`aspectRatio`, or with ⇧ the rect's
    /// aspect as the resize began) keeps the opposite corner, or the opposite edge and the centre of the other axis, and
    /// shrinks to stay inside `bounds`. ⌥ resizes about the centre.
    private func resized(_ handle: SelectionHandle, to point: CGPoint, modifiers: SelectionModifiers) -> CGRect {
        let start = resizeStart
        let target = clamp(CGPoint(x: point.x + grabOffset.x, y: point.y + grabOffset.y))
        let fromCenter = modifiers.contains(.option)
        let ratio = lockedRatio(aspectRatio) ?? (modifiers.contains(.shift) ? lockedRatio(start.width / start.height) : nil)
        let x = AxisPull(pull: handle.pull.x, target: target.x, lower: start.minX, upper: start.maxX,
                         bounds: bounds.minX...bounds.maxX, fromCenter: fromCenter)
        let y = AxisPull(pull: handle.pull.y, target: target.y, lower: start.minY, upper: start.maxY,
                         bounds: bounds.minY...bounds.maxY, fromCenter: fromCenter)
        var width = x.size
        var height = y.size
        if let ratio {
            // The axis the handle doesn't pull on keeps its centre, so its room is about the centre.
            switch (handle.isCorner, handle.pull.x != 0) {
            case (true, _): width = max(x.size, y.size * ratio)
            case (false, true): width = x.size
            case (false, false): width = y.size * ratio
            }
            width = max(width, Self.minimumSize, Self.minimumSize * ratio)
            width = min(width, x.room(centred: handle.pull.x == 0), y.room(centred: handle.pull.y == 0) * ratio)
            height = width / ratio
        } else {
            width = min(max(width, Self.minimumSize), x.room(centred: false))
            height = min(max(height, Self.minimumSize), y.room(centred: false))
        }
        let (minX, minY) = (x.origin(for: width, locked: ratio != nil), y.origin(for: height, locked: ratio != nil))
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    /// A handle resize along one axis.
    private struct AxisPull {
        /// -1 toward `lower`, 1 toward `upper`, 0 for an edge handle on the other axis.
        let pull: CGFloat
        let target: CGFloat
        /// The rect's edges on this axis as the resize began.
        let lower: CGFloat
        let upper: CGFloat
        let bounds: ClosedRange<CGFloat>
        let fromCenter: Bool

        var center: CGFloat { (lower + upper) / 2 }
        /// The edge that stays put: the opposite edge, or the centre with ⌥.
        var fixed: CGFloat { fromCenter ? center : pull > 0 ? lower : upper }

        /// The size the pointer asks for (0 once it crosses the fixed edge); the rect's size on an axis not pulled.
        var size: CGFloat {
            guard pull != 0 else { return upper - lower }
            let extent = max(0, pull * (target - fixed))
            return fromCenter ? extent * 2 : extent
        }

        /// The largest size that fits in `bounds`: measured from the fixed edge, or about the centre (with ⌥, or when
        /// a ratio resizes an axis the handle doesn't pull on).
        func room(centred: Bool) -> CGFloat {
            if pull == 0 && !centred { return upper - lower }
            if fromCenter || centred {
                return 2 * min(center - bounds.lowerBound, bounds.upperBound - center)
            }
            return pull > 0 ? bounds.upperBound - fixed : fixed - bounds.lowerBound
        }

        /// Where the rect starts on this axis for `size`.
        func origin(for size: CGFloat, locked: Bool) -> CGFloat {
            if pull == 0 { return locked ? center - size / 2 : lower }
            if fromCenter { return center - size / 2 }
            return pull > 0 ? fixed : fixed - size
        }
    }

    /// `ratio` when it can lock a shape (positive and finite), else nil.
    private func lockedRatio(_ ratio: CGFloat?) -> CGFloat? {
        guard let ratio, ratio.isFinite, ratio > 0 else { return nil }
        return ratio
    }

    /// `size` (already `ratio`-shaped) scaled down to fit `room`, then up to `minimumSize` on both sides.
    private func fitted(_ size: CGSize, ratio: CGFloat, within room: CGSize) -> CGSize {
        let shrink = min(1, room.width / size.width, room.height / size.height)
        var width = size.width * shrink
        width = max(width, Self.minimumSize, Self.minimumSize * ratio)
        return CGSize(width: width, height: width / ratio)
    }

    private func clampSide(_ value: CGFloat, to limit: CGFloat) -> CGFloat {
        min(max(value, Self.minimumSize), limit)
    }

    /// Slides a rect back inside `bounds` without changing its size (unless it's bigger than `bounds`).
    private func keepInside(_ candidate: CGRect) -> CGRect {
        var result = candidate
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
        return result
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }
}
