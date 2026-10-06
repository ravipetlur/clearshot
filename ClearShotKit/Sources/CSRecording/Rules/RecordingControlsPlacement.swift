import CoreGraphics
import CSCore

/// Where the control bar goes while recording, by "Controls position". AppKit global points.
public enum RecordingControlsPlacement {
    /// Between the bar and the top or bottom of the visible frame.
    public static let screenInset: CGFloat = 24

    /// The bar's frame, origin in whole points. Below the area it is placed as a selection's toolbar is
    /// (`ToolbarPlacement`): under the region, else over it, else inside its bottom edge, which is where a full-display
    /// region puts it. At the top or bottom of the screen it is centred on `visibleFrame`, the region's screen without
    /// the menu bar and the Dock.
    public static func frame(size: CGSize, region: CGRect, position: RecordingControlsPosition, visibleFrame: CGRect) -> CGRect {
        let y: CGFloat
        switch position {
        case .belowArea:
            return ToolbarPlacement.frame(size: size, anchoredTo: region, visibleFrame: visibleFrame).frame
        case .topOfScreen:
            y = visibleFrame.maxY - screenInset - size.height
        case .bottomOfScreen:
            y = visibleFrame.minY + screenInset
        }
        let x = visibleFrame.midX - size.width / 2
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }
}
