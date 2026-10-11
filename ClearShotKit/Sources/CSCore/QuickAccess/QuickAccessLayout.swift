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

    // MARK: Inside a thumbnail

    /// The corner buttons' side.
    public static let circleSize: CGFloat = 22
    /// How far the corner buttons, and the pill between them, sit from the thumbnail's edges and from each other.
    public static let controlInset: CGFloat = 6
    /// The possible-secrets pill: one size in every state and for every thumbnail. Its widest text is "Masked", 38.7 pt in
    /// 10 pt semibold type (measured; "⚠︎ 99+" is 32.7), plus 7 pt either side.
    public static let sensitiveBadgeSize = CGSize(width: 54, height: 18)
    /// The Copy and Save pills' height, and how far they are from the middle.
    private static let centerPillHeight: CGFloat = 26

    /// The hover controls and the possible-secrets pill, each a frame in the thumbnail's picture area.
    public struct ThumbnailControls: Equatable, Sendable {
        public var copy: CGRect
        public var save: CGRect
        public var close: CGRect
        public var annotate: CGRect
        public var trim: CGRect
        public var trash: CGRect
        public var pin: CGRect
        /// Where the pill is, whether or not the hover buttons show: right of the Trash slot, short of the Pin one, its lower
        /// edge flush with theirs (as low as it goes, away from Save). Nothing the pointer brings in ever takes its place, so
        /// a click aimed at it can't land on one.
        public var sensitiveBadge: CGRect
        /// Copy and Save are side by side in one row on the middle, each half as wide, not one above the other: the layout of a
        /// picture area shorter than `stackedPillsMinimumHeight`.
        public var copyAndSaveShareARow: Bool
    }

    /// The shortest picture area that stacks Copy above Save. Shorter than this, Save's lower edge would reach the
    /// possible-secrets pill's row (the pill sits between the corner buttons, and the stacked pills are as wide as that gap),
    /// so the two pills share one row instead, which clears the pill (by 5 pt at the shortest, 84 pt) and Trim (by 1 pt).
    public static let stackedPillsMinimumHeight: CGFloat = 106
    /// The gap between Copy and Save when they share a row.
    private static let sharedRowGap: CGFloat = 4

    /// The frames for a picture area `size` big (AppKit coordinates: y grows upward from the bottom-left corner): Copy and
    /// Save in the middle, Close and Annotate (with Trim beside it) at the top corners, Trash and Pin at the bottom ones,
    /// and the pill between those two. They depend on the area's size alone, so they are the same whichever corner the
    /// stack is in.
    public static func controls(in size: CGSize) -> ThumbnailControls {
        let pillWidth = min(112, size.width - 24)
        let pillX = (size.width - pillWidth) / 2
        let midY = size.height / 2
        let circle = circleSize
        let inset = controlInset
        let annotate = CGRect(x: size.width - inset - circle, y: size.height - inset - circle, width: circle, height: circle)
        let trash = CGRect(x: inset, y: inset, width: circle, height: circle)
        let badge = sensitiveBadgeSize
        let sharesARow = size.height < stackedPillsMinimumHeight
        let copy: CGRect
        let save: CGRect
        if sharesARow {
            let half = (pillWidth - sharedRowGap) / 2
            copy = CGRect(x: pillX, y: midY - centerPillHeight / 2, width: half, height: centerPillHeight)
            save = CGRect(x: pillX + half + sharedRowGap, y: copy.minY, width: half, height: centerPillHeight)
        } else {
            copy = CGRect(x: pillX, y: midY + 3, width: pillWidth, height: centerPillHeight)
            save = CGRect(x: pillX, y: midY - 3 - centerPillHeight, width: pillWidth, height: centerPillHeight)
        }
        return ThumbnailControls(
            copy: copy,
            save: save,
            close: CGRect(x: inset, y: size.height - inset - circle, width: circle, height: circle),
            annotate: annotate,
            trim: annotate.offsetBy(dx: -(circle + 4), dy: 0),
            trash: trash,
            pin: CGRect(x: size.width - inset - circle, y: inset, width: circle, height: circle),
            sensitiveBadge: CGRect(x: trash.maxX + inset, y: trash.minY, width: badge.width, height: badge.height),
            copyAndSaveShareARow: sharesARow)
    }

    /// Whether `point` (in a view `size` big, y up) is inside the capsule that fills it: a rectangle with ends as round as
    /// its height. The pill takes clicks only there, so the corners of its rectangle belong to whatever is under them.
    public static func capsuleContains(_ point: CGPoint, in size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0, point.x >= 0, point.x <= size.width, point.y >= 0, point.y <= size.height else {
            return false
        }
        let radius = size.height / 2
        let nearest = min(max(point.x, radius), size.width - radius)
        return hypot(point.x - nearest, point.y - radius) <= radius
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
