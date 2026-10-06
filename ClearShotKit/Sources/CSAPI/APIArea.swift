import CoreGraphics
import CSCore

/// An area as a URL gives it.
public struct APIArea: Sendable, Equatable {
    /// API points: from the display's bottom-left, y up.
    public let rect: CGRect
    /// 1-based, in the layout's order (1 is the main display); nil: the display under the pointer.
    public let display: Int?

    public init(rect: CGRect, display: Int?) {
        self.rect = rect
        self.display = display
    }

    /// The area on the screen now. Display n is `layout.displays[n − 1]` (`DisplayLayout.current()` keeps `NSScreen`
    /// order, the menu-bar screen first), never a `CGDirectDisplayID`; without a display, the one under the pointer
    /// (`mouse`, an `NSEvent.mouseLocation` point), else the main display. The rect is clamped to that display and
    /// needs 4 points each way on it, as Capture Previous Area's does (`SavedArea.resolved`): with none of it on the
    /// display it isn't on that display, with less it is too small.
    public func resolve(in layout: DisplayLayout, mouse: CGPoint) throws(APIError) -> ResolvedAPIArea {
        let target: DisplayInfo
        if let display {
            guard display >= 1, display <= layout.displays.count else { throw .noSuchDisplay(display) }
            target = layout.displays[display - 1]
        } else {
            target = layout.display(containingMouse: mouse) ?? layout.main
        }
        let number = display ?? (layout.displays.firstIndex(of: target) ?? 0) + 1
        let requested = layout.appKitRect(fromAPI: rect, on: target)
        guard let resolved = SavedArea(rect: requested, displayID: target.id).resolved(in: layout, minimumSide: 4) else {
            throw requested.standardized.intersection(target.frame).isEmpty ? .areaOffDisplay(number) : .areaTooSmall
        }
        return ResolvedAPIArea(rect: resolved.rect, display: resolved.display, wasClamped: resolved.rect != requested)
    }
}

/// An area on the screen now: AppKit global points, clamped to its display.
public struct ResolvedAPIArea: Sendable, Equatable {
    public let rect: CGRect, display: DisplayInfo, wasClamped: Bool
}
