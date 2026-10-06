import CoreGraphics

/// One connected display. `frame` is in AppKit global points (origin at the main display's
/// bottom-left, y up), the same space as `NSScreen.frame`.
public struct DisplayInfo: Sendable, Equatable, Hashable, Codable {
    public let id: UInt32
    public let name: String
    public let frame: CGRect
    public let scale: CGFloat
    public let isBuiltIn: Bool
    public let safeAreaTop: CGFloat

    public init(id: UInt32, name: String, frame: CGRect, scale: CGFloat, isBuiltIn: Bool, safeAreaTop: CGFloat) {
        self.id = id
        self.name = name
        self.frame = frame
        self.scale = scale
        self.isBuiltIn = isBuiltIn
        self.safeAreaTop = safeAreaTop
    }

    public var pixelSize: CGSize {
        CGSize(width: frame.width * scale, height: frame.height * scale)
    }

    /// Whether an `NSEvent.mouseLocation` point is on this display, by `NSMouseInRect`'s unflipped rule: `minX <= x < maxX`
    /// and `minY < y <= maxY`, so the top row (at `frame.maxY`) is this display's and never the one above's
    /// (`DisplayLayout.display(containingMouse:)`).
    public func containsMouse(_ point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX && point.y > frame.minY && point.y <= frame.maxY
    }
}

/// All displays, plus the only conversions between coordinate spaces used anywhere in ClearShot.
///
/// - AppKit: global points, origin at the main display's bottom-left, y up (`NSScreen.frame`).
/// - CG: global points, origin at the main display's top-left, y down (`CGDisplayBounds`, ScreenCaptureKit).
/// - Local: points relative to one display's top-left, y down (image space).
/// - API: points relative to one display's bottom-left, y up (the URL scheme's areas).
public struct DisplayLayout: Sendable, Equatable {
    public let displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) {
        precondition(!displays.isEmpty, "DisplayLayout needs at least one display")
        self.displays = displays
    }

    /// The main display is the one whose AppKit frame starts at the origin.
    public var main: DisplayInfo {
        displays.first { $0.frame.origin == .zero } ?? displays[0]
    }

    public func display(id: UInt32) -> DisplayInfo? {
        displays.first { $0.id == id }
    }

    /// The display containing an AppKit point (max edges excluded).
    public func display(containing point: CGPoint) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
    }

    /// The display under an `NSEvent.mouseLocation` point.
    ///
    /// `mouseLocation` is the CG cursor position flipped by the main display's height, so the top row of a display
    /// lands exactly on `frame.maxY`, which `display(containing:)` excludes (`CGRect.contains` leaves out the max
    /// edges). This uses `NSMouseInRect`'s unflipped rule instead: `minX <= x < maxX` and `minY < y <= maxY`.
    public func display(containingMouse point: CGPoint) -> DisplayInfo? {
        displays.first { $0.containsMouse(point) }
    }

    /// The display that overlaps the most area of an AppKit rect, or nil if it is off every display.
    public func display(bestMatching rect: CGRect) -> DisplayInfo? {
        var best: DisplayInfo?
        var bestArea: CGFloat = 0
        for display in displays {
            let overlap = display.frame.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                best = display
                bestArea = area
            }
        }
        return best
    }

    // MARK: AppKit ⇄ CG (the same flip in both directions)

    public func cgRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: main.frame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    public func appKitRect(fromCG rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: main.frame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    public func cgPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: main.frame.height - point.y)
    }

    public func appKitPoint(fromCG point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: main.frame.height - point.y)
    }

    // MARK: AppKit ⇄ display-local

    public func localRect(_ rect: CGRect, in display: DisplayInfo) -> CGRect {
        CGRect(x: rect.minX - display.frame.minX,
               y: display.frame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    public func appKitRect(fromLocal rect: CGRect, in display: DisplayInfo) -> CGRect {
        CGRect(x: display.frame.minX + rect.minX,
               y: display.frame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// A display-local pixel rect, rounded outward to whole pixels.
    public func pixelRect(_ rect: CGRect, in display: DisplayInfo) -> CGRect {
        let local = localRect(rect, in: display)
        return CGRect(x: local.minX * display.scale,
                      y: local.minY * display.scale,
                      width: local.width * display.scale,
                      height: local.height * display.scale).integral
    }

    // MARK: URL API

    public func appKitRect(fromAPI rect: CGRect, on display: DisplayInfo) -> CGRect {
        CGRect(x: display.frame.minX + rect.minX,
               y: display.frame.minY + rect.minY,
               width: rect.width, height: rect.height)
    }
}
