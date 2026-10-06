import CoreGraphics
import CSCore

public enum NotchCrop {
    /// Pixels to remove from the top of a fullscreen capture of a notched built-in display when a full-screen app
    /// leaves the band beside the notch black. Zero in every other case. `frontmostAppWindowFrames` and
    /// `displayCGFrame` are CG global points.
    public static func pixels(for display: DisplayInfo, kind: CaptureKind, frontmostAppWindowFrames: [CGRect],
                              displayCGFrame: CGRect) -> Int {
        guard kind == .display, display.isBuiltIn, display.safeAreaTop > 0 else { return 0 }
        let belowNotch = CGRect(x: displayCGFrame.minX, y: displayCGFrame.minY + display.safeAreaTop,
                                width: displayCGFrame.width, height: displayCGFrame.height - display.safeAreaTop)
        let fullScreenAppPresent = frontmostAppWindowFrames.contains { frame in
            frame.equalTo(belowNotch) || frame.equalTo(displayCGFrame)
        }
        return fullScreenAppPresent ? Int((display.safeAreaTop * display.scale).rounded()) : 0
    }
}
