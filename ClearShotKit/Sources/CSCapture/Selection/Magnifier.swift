import CoreGraphics

/// Pixel math for the selection magnifier. Pixel coordinates use a top-left origin.
public enum Magnifier {
    /// Pixels shown across the magnifier (odd, so one pixel sits in the center).
    public static let gridSize = 15

    public static func sampleRect(centeredOn pixel: CGPoint, gridSize: Int, imageSize: CGSize) -> CGRect {
        let size = CGFloat(gridSize)
        let half = (size / 2).rounded(.down)
        let width = min(size, imageSize.width)
        let height = min(size, imageSize.height)
        let x = min(max(pixel.x - half, 0), imageSize.width - width)
        let y = min(max(pixel.y - half, 0), imageSize.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The pixel under a display-local point (points, top-left origin).
    public static func pixel(forLocalPoint point: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: (point.x * scale).rounded(.down), y: (point.y * scale).rounded(.down))
    }
}
