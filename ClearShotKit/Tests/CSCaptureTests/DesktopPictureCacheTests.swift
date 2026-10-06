import CoreGraphics
import Foundation
import Testing
@testable import CSCapture

/// The desktop pictures window shots and the desktop covers share: one per display, kept only while the display's
/// desktop picture file is the one it was read with.
struct DesktopPictureCacheTests {
    let picture = TestImages.solid(width: 8, height: 8, color: TestImages.blue)
    let sequoia = URL(filePath: "/System/Library/Desktop Pictures/Sequoia.heic")
    let tahoe = URL(filePath: "/System/Library/Desktop Pictures/Tahoe.heic")

    @Test func theSameURLHits() {
        var cache = DesktopPictureCache()
        cache.store(picture, for: 1, url: sequoia)
        #expect(cache.picture(for: 1, url: sequoia) === picture)
        // A picture read when the display's file wasn't known is found the same way.
        cache.store(picture, for: 2, url: nil)
        #expect(cache.picture(for: 2, url: nil) === picture)
    }

    @Test func aChangedURLMisses() {
        var cache = DesktopPictureCache()
        cache.store(picture, for: 1, url: sequoia)
        #expect(cache.picture(for: 1, url: tahoe) == nil)
        #expect(cache.picture(for: 1, url: nil) == nil)
        // Another display has its own.
        #expect(cache.picture(for: 2, url: sequoia) == nil)
    }

    @Test func removeAllEmptiesIt() {
        var cache = DesktopPictureCache()
        cache.store(picture, for: 1, url: sequoia)
        cache.store(picture, for: 2, url: tahoe)
        cache.removeAll()
        #expect(cache.picture(for: 1, url: sequoia) == nil)
        #expect(cache.picture(for: 2, url: tahoe) == nil)
    }
}
