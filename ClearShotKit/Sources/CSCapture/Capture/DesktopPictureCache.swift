import CoreGraphics
import Foundation

/// The desktop pictures window shots and the desktop covers share, one per display. Each is kept with the display's
/// desktop picture file as it was when the picture was read, and is found only while that file is still the display's:
/// a changed desktop picture is read again even before anything drops the cache. A picture that changes under the same
/// file (a dynamic desktop) still needs `removeAll`.
public struct DesktopPictureCache: Sendable {
    private var entries: [UInt32: (url: URL?, image: CGImage)] = [:]

    public init() {}

    /// The display's picture; nil when there is none, or it was read for another file than `url`.
    public func picture(for displayID: UInt32, url: URL?) -> CGImage? {
        guard let entry = entries[displayID], entry.url == url else { return nil }
        return entry.image
    }

    /// Keeps `image` as the display's picture, read while `url` was its desktop picture file.
    public mutating func store(_ image: CGImage, for displayID: UInt32, url: URL?) {
        entries[displayID] = (url, image)
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
