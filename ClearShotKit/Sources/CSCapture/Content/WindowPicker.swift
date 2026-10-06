import CoreGraphics

public enum WindowPicker {
    /// Smallest window worth offering in window mode, in points.
    public static let minimumSide: CGFloat = 40

    /// The frontmost capturable window under a CG global point. `windows` must be front to back.
    /// Capturable means a normal or floating layer (0..<20, which leaves out the Dock, the menu bar and the
    /// desktop), visible, on screen, not excluded, and at least 40×40 pt.
    public static func window(at point: CGPoint, in windows: [WindowRecord], excluding: Set<UInt32>) -> WindowRecord? {
        windows.first { window in
            (0..<20).contains(window.layer)
                && window.isOnScreen
                && window.alpha > 0
                && !excluding.contains(window.id)
                && window.frame.width >= minimumSide
                && window.frame.height >= minimumSide
                && window.frame.contains(point)
        }
    }
}
