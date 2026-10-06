import CoreGraphics
import Testing
@testable import CSCapture

struct WallpaperCropTests {
    @Test func cropsThePartBehindARectProportionally() {
        // A 2x wallpaper for a 100×50 pt display at CG (-100, -20).
        let wallpaper = TestImages.withTopRows(width: 200, height: 100, rows: 40, top: TestImages.red, base: TestImages.blue)
        let display = CGRect(x: -100, y: -20, width: 100, height: 50)
        let behind = WallpaperProvider.crop(wallpaper, displayCGFrame: display, to: CGRect(x: -90, y: -20, width: 20, height: 10))
        #expect(behind?.width == 40)
        #expect(behind?.height == 20)
        #expect(behind.map { TestImages.pixel($0, x: 0, y: 0).r } == 255)
    }

    /// A picture of another aspect fills the display the way the desktop shows it, centred and cropped, not stretched:
    /// a 2000 × 1000 picture on a 1000 × 1000 pt display shows its middle 1000 × 1000 pixels, so the display's left
    /// half is the picture's x 500…1000.
    @Test func aWiderPictureIsAspectFilledNotStretched() {
        let context = CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: TestImages.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Bands across the picture: red x 0…500 (off the display), blue 500…1000, green 1000…2000.
        context.setFillColor(TestImages.red)
        context.fill(CGRect(x: 0, y: 0, width: 500, height: 1000))
        context.setFillColor(TestImages.blue)
        context.fill(CGRect(x: 500, y: 0, width: 500, height: 1000))
        context.setFillColor(TestImages.green)
        context.fill(CGRect(x: 1000, y: 0, width: 1000, height: 1000))
        let wallpaper = context.makeImage()!
        let display = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let leftHalf = WallpaperProvider.crop(wallpaper, displayCGFrame: display, to: CGRect(x: 0, y: 0, width: 500, height: 1000))
        #expect(leftHalf?.width == 500)
        #expect(leftHalf?.height == 1000)
        #expect(leftHalf.map { TestImages.pixel($0, x: 0, y: 0) } == TestImages.RGBA(r: 0, g: 0, b: 255, a: 255))
        #expect(leftHalf.map { TestImages.pixel($0, x: 499, y: 999) } == TestImages.RGBA(r: 0, g: 0, b: 255, a: 255))
    }

    /// A taller picture loses its top and bottom: a 1000 × 2000 picture on a 1000 × 1000 pt display shows its middle
    /// 1000 × 1000 pixels, so the display's top half (CG's y counts down from the top, as the picture's rows do) is the
    /// picture's y 500…1000.
    @Test func aTallerPictureIsAspectFilledNotStretched() {
        let context = CGContext(data: nil, width: 1000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: TestImages.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Bands down the picture, in its row order: red y 0…500 (off the display), blue 500…1000, green 1000…2000.
        // The context is y-up, so the picture's top rows are its highest y.
        context.setFillColor(TestImages.red)
        context.fill(CGRect(x: 0, y: 1500, width: 1000, height: 500))
        context.setFillColor(TestImages.blue)
        context.fill(CGRect(x: 0, y: 1000, width: 1000, height: 500))
        context.setFillColor(TestImages.green)
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let wallpaper = context.makeImage()!
        let display = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let topHalf = WallpaperProvider.crop(wallpaper, displayCGFrame: display, to: CGRect(x: 0, y: 0, width: 1000, height: 500))
        #expect(topHalf?.width == 1000)
        #expect(topHalf?.height == 500)
        #expect(topHalf.map { TestImages.pixel($0, x: 0, y: 0) } == TestImages.RGBA(r: 0, g: 0, b: 255, a: 255))
        #expect(topHalf.map { TestImages.pixel($0, x: 999, y: 499) } == TestImages.RGBA(r: 0, g: 0, b: 255, a: 255))
    }

    @Test func aRectOffTheDisplayGivesNothing() {
        let wallpaper = TestImages.solid(width: 200, height: 100, color: TestImages.blue)
        #expect(WallpaperProvider.crop(wallpaper, displayCGFrame: CGRect(x: 0, y: 0, width: 100, height: 50),
                                       to: CGRect(x: 500, y: 500, width: 10, height: 10)) == nil)
    }
}
