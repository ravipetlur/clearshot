import CoreGraphics

/// Where the Quick Access thumbnails go. AppKit coordinates: y grows upward.
public enum QuickAccessLayout {
    public static let margin: CGFloat = 16
    public static let spacing: CGFloat = 12
    /// Height of the "Ask for name" strip under a thumbnail: a text field above Discard / Save.
    public static let nameStripHeight: CGFloat = 64

    /// The thumbnail is `size.width` wide. Its height follows the image's aspect ratio but stays between half and
    /// 1.25 times the width, so extreme images still leave room for the buttons.
    public static func thumbnailSize(imagePixels: CGSize, size: QuickAccessSize) -> CGSize {
        let width = size.width
        guard imagePixels.width > 0, imagePixels.height > 0 else {
            return CGSize(width: width, height: (width * 0.625).rounded())
        }
        let natural = width * imagePixels.height / imagePixels.width
        return CGSize(width: width, height: min(max(natural, width * 0.5), width * 1.25).rounded())
    }

    /// Frames for a stack of thumbnails, newest first. The newest sits in the bottom corner of `visibleFrame` on the
    /// `position` side, and each older one sits above the one before. A thumbnail that would cross the top margin
    /// gets nil (it stays hidden until there is room), and so does every older one.
    public static func frames(for sizes: [CGSize], in visibleFrame: CGRect, position: QuickAccessPosition) -> [CGRect?] {
        var frames: [CGRect?] = []
        var y = visibleFrame.minY + margin
        var full = false
        for size in sizes {
            if full || y + size.height > visibleFrame.maxY - margin {
                full = true
                frames.append(nil)
                continue
            }
            let x = position == .left ? visibleFrame.minX + margin : visibleFrame.maxX - margin - size.width
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            y += size.height + spacing
        }
        return frames
    }
}
