import CoreGraphics

/// Where the live preview of a scrolling capture goes: beside a vertical capture (right of the region, else left, else
/// inside its right edge) as tall as the screen allows, or under a horizontal one (else above, else inside its bottom
/// edge) as wide as the screen allows. AppKit global points, whole points.
public enum PreviewPlacement {
    /// The panel's width beside a vertical capture.
    public static let width: CGFloat = 200
    /// The panel's height under a horizontal capture.
    public static let height: CGFloat = 160
    /// Between the region and the panel, and how far inside the region the panel sits when neither side has room.
    static let gap: CGFloat = 12
    /// Kept clear at both ends of the visible frame along the panel's long side.
    static let inset: CGFloat = 24

    /// The panel's frame for a capture of `region` growing along `axis`. `visibleFrame` is the region's screen without
    /// the menu bar and the Dock (`NSScreen.visibleFrame`).
    public static func frame(region: CGRect, axis: ScrollAxis, visibleFrame: CGRect) -> CGRect {
        let frame: CGRect
        switch axis {
        case .vertical:
            let x: CGFloat
            if region.maxX + gap + width <= visibleFrame.maxX {
                x = region.maxX + gap
            } else if region.minX - gap - width >= visibleFrame.minX {
                x = region.minX - gap - width
            } else {
                x = max(min(region.maxX - gap - width, visibleFrame.maxX - width), visibleFrame.minX)
            }
            frame = CGRect(x: x, y: visibleFrame.minY + inset, width: width, height: visibleFrame.height - 2 * inset)
        case .horizontal:
            let y: CGFloat
            if region.minY - gap - height >= visibleFrame.minY {
                y = region.minY - gap - height
            } else if region.maxY + gap + height <= visibleFrame.maxY {
                y = region.maxY + gap
            } else {
                y = max(min(region.minY + gap, visibleFrame.maxY - height), visibleFrame.minY)
            }
            frame = CGRect(x: visibleFrame.minX + inset, y: y, width: visibleFrame.width - 2 * inset, height: height)
        }
        return CGRect(x: frame.minX.rounded(), y: frame.minY.rounded(),
                      width: frame.width.rounded(), height: frame.height.rounded())
    }
}
