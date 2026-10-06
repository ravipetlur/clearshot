import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CSCapture

struct ImageOpsTests {
    /// Left half red, right half blue.
    static func leftRight(width: Int = 4, height: Int = 2) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: TestImages.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(TestImages.blue)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(TestImages.red)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    static let opaqueRed = TestImages.RGBA(r: 255, g: 0, b: 0, a: 255)
    static let opaqueBlue = TestImages.RGBA(r: 0, g: 0, b: 255, a: 255)

    @Test func thumbnailCapsTheLongestSideAndKeepsTheAspect() {
        let thumbnail = ImageOps.thumbnail(TestImages.solid(width: 1000, height: 500, color: TestImages.red), maxPixel: 640)
        #expect(thumbnail.width == 640)
        #expect(thumbnail.height == 320)
    }

    @Test func thumbnailLeavesSmallImagesAlone() {
        let image = TestImages.solid(width: 300, height: 200, color: TestImages.red)
        #expect(ImageOps.thumbnail(image, maxPixel: 640) === image)
    }

    @Test func rotatingLeftTurnsTheTopRowIntoTheLeftColumn() throws {
        let image = TestImages.withTopRows(width: 4, height: 2, rows: 1, top: TestImages.red, base: TestImages.blue)
        let rotated = try #require(ImageOps.rotatedLeft(image))
        #expect(rotated.width == 2)
        #expect(rotated.height == 4)
        for y in 0..<4 {
            #expect(TestImages.pixel(rotated, x: 0, y: y) == Self.opaqueRed)
            #expect(TestImages.pixel(rotated, x: 1, y: y) == Self.opaqueBlue)
        }
    }

    @Test func flippingSwapsLeftAndRight() throws {
        let flipped = try #require(ImageOps.flippedHorizontally(Self.leftRight()))
        #expect(TestImages.pixel(flipped, x: 0, y: 0) == Self.opaqueBlue)
        #expect(TestImages.pixel(flipped, x: 3, y: 1) == Self.opaqueRed)
    }

    @Test func rotationKeepsTransparency() throws {
        let rotated = try #require(ImageOps.rotatedLeft(TestImages.solid(width: 6, height: 3, color: TestImages.clear)))
        #expect(TestImages.pixel(rotated, x: 1, y: 1).a == 0)
        #expect(ImageOps.hasAlpha(rotated))
    }

    @Test func resizeGivesExactPixelsAndRejectsEmptySizes() throws {
        let image = TestImages.solid(width: 100, height: 60, color: TestImages.red)
        let resized = try #require(ImageOps.resized(image, width: 25, height: 40))
        #expect(resized.width == 25)
        #expect(resized.height == 40)
        #expect(ImageOps.resized(image, width: 0, height: 10) == nil)
    }

    @Test func resizingAnExtendedRangeImageWorks() throws {
        // An HDR capture or picture is float extended sRGB, which an 8-bit bitmap context can't be made in: the result
        // falls back to sRGB instead of failing.
        let hdr = TestImages.extendedRange(width: 20, height: 10, color: TestImages.red)
        #expect(hdr.colorSpace?.model == .rgb)
        let resized = try #require(ImageOps.resized(hdr, width: 10, height: 5))
        #expect(resized.width == 10)
        #expect(resized.height == 5)
        #expect(TestImages.pixel(resized, x: 5, y: 2) == Self.opaqueRed)
    }

    @Test func rotatingAndFlippingAnExtendedRangeImageWork() throws {
        let hdr = TestImages.extendedRange(width: 6, height: 2, color: TestImages.blue)
        let rotated = try #require(ImageOps.rotatedLeft(hdr))
        #expect(rotated.width == 2)
        #expect(rotated.height == 6)
        #expect(TestImages.pixel(rotated, x: 1, y: 3) == Self.opaqueBlue)
        let flipped = try #require(ImageOps.flippedHorizontally(hdr))
        #expect(flipped.width == 6)
        #expect(TestImages.pixel(flipped, x: 2, y: 1) == Self.opaqueBlue)
    }

    @Test func hasAlphaReadsTheAlphaInfo() {
        #expect(ImageOps.hasAlpha(TestImages.solid(width: 2, height: 2, color: TestImages.red)))
        #expect(!ImageOps.hasAlpha(TestImages.noise(width: 2, height: 2)))
    }

    @Test func loadReadsAWrittenFileAndReturnsNilForAMissingOne() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "imageops-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageEncoder.encode(TestImages.solid(width: 7, height: 5, color: TestImages.green), as: .png, quality: 1).write(to: url)
        let loaded = try #require(ImageOps.load(url))
        #expect(loaded.width == 7)
        #expect(loaded.height == 5)
        #expect(ImageOps.load(url.deletingLastPathComponent().appending(path: "missing-\(UUID().uuidString).png")) == nil)
    }

    @Test func loadingDecodedGivesTheFilesPixelsAndNilForAMissingFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "imageops-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageEncoder.encode(Self.leftRight(), as: .png, quality: 1).write(to: url)
        let loaded = try #require(ImageOps.loadDecoded(url))
        #expect(loaded.width == 4)
        #expect(loaded.height == 2)
        #expect(TestImages.pixel(loaded, x: 0, y: 1) == Self.opaqueRed)
        #expect(TestImages.pixel(loaded, x: 3, y: 0) == Self.opaqueBlue)
        #expect(ImageOps.loadDecoded(url.deletingLastPathComponent().appending(path: "missing-\(UUID().uuidString).png")) == nil)
    }

    @Test func scaleTo1xHalvesARetinaImageAndResetsTheScale() throws {
        let result = try #require(ImageOps.apply(.scaleTo1x, to: TestImages.solid(width: 100, height: 60, color: TestImages.red), scale: 2))
        #expect(result.image.width == 50)
        #expect(result.image.height == 30)
        #expect(result.scale == 1)
    }

    @Test func otherTransformsKeepTheScale() throws {
        let image = TestImages.solid(width: 100, height: 60, color: TestImages.red)
        let rotated = try #require(ImageOps.apply(.rotateLeft, to: image, scale: 2))
        #expect(rotated.image.width == 60)
        #expect(rotated.image.height == 100)
        #expect(rotated.scale == 2)
        let resized = try #require(ImageOps.apply(.resize(width: 10, height: 6), to: image, scale: 2))
        #expect(resized.image.width == 10)
        #expect(resized.image.height == 6)
        #expect(resized.scale == 2)
        let flipped = try #require(ImageOps.apply(.flipHorizontal, to: image, scale: 1))
        #expect(flipped.image.width == 100)
        #expect(flipped.scale == 1)
    }

    @Test func opaqueImagesWithAnAlphaChannelHaveNoTransparentPixels() {
        #expect(!ImageOps.hasTransparentPixels(TestImages.solid(width: 8, height: 4, color: TestImages.red)))
        #expect(!ImageOps.hasTransparentPixels(TestImages.noise(width: 8, height: 4)))
    }

    @Test func oneSeeThroughPixelCounts() {
        let context = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: TestImages.srgb,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(TestImages.red)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        context.clear(CGRect(x: 3, y: 2, width: 1, height: 1))
        #expect(ImageOps.hasTransparentPixels(context.makeImage()!))
        #expect(ImageOps.hasTransparentPixels(TestImages.solid(width: 2, height: 2, color: TestImages.clear)))
    }

    @Test func imagesOverThePixelCapCountAsTransparentWithoutAScan() {
        let opaque = TestImages.solid(width: 8, height: 4, color: TestImages.red)
        #expect(ImageOps.hasTransparentPixels(opaque, maxPixels: 4))
        #expect(!ImageOps.hasTransparentPixels(opaque))
    }

    @Test func pixelCountsThatOverflowOrHaveAnEmptySideAreNil() {
        #expect(ImageOps.pixelCount(width: 4, height: 5) == 20)
        #expect(ImageOps.pixelCount(width: Int.max, height: 2) == nil)
        #expect(ImageOps.pixelCount(width: 1 << 32, height: 1 << 32) == nil)
        #expect(ImageOps.pixelCount(width: 0, height: 5) == nil)
        #expect(ImageOps.pixelCount(width: 5, height: -1) == nil)
    }

    static func jpegData(_ image: CGImage, orientation: UInt32) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func uprightLoadingAppliesTheOrientationTag() throws {
        let data = Self.jpegData(TestImages.solid(width: 40, height: 20, color: TestImages.red), orientation: 6)
        let fromData = try #require(ImageOps.loadUpright(data: data))
        #expect(fromData.width == 20)
        #expect(fromData.height == 40)
        let url = FileManager.default.temporaryDirectory.appending(path: "upright-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let fromFile = try #require(ImageOps.loadUpright(url))
        #expect(fromFile.width == 20)
        #expect(fromFile.height == 40)
    }

    @Test func uprightLoadingLeavesUntaggedImagesAlone() throws {
        let data = Self.jpegData(TestImages.solid(width: 40, height: 20, color: TestImages.red), orientation: 1)
        let image = try #require(ImageOps.loadUpright(data: data))
        #expect(image.width == 40)
        #expect(image.height == 20)
    }

    /// Images encoded into one file, each with its density in dots per inch (nil for none).
    static func encoded(_ images: [(image: CGImage, dpi: Double?)], as type: String) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type as CFString, images.count, nil)!
        for (image, dpi) in images {
            let properties: [CFString: Any] = dpi.map { [kCGImagePropertyDPIWidth: $0, kCGImagePropertyDPIHeight: $0] } ?? [:]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func loadingFromAnOpenSourceGivesTheImageAndItsDensity() throws {
        let png = Self.encoded([(TestImages.solid(width: 40, height: 20, color: TestImages.red), 144)], as: "public.png")
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let loaded = try #require(ImageOps.loadUpright(from: source))
        #expect(loaded.image.width == 40)
        #expect(loaded.dpi == 144)
        let bare = Self.encoded([(TestImages.solid(width: 40, height: 20, color: TestImages.red), nil)], as: "public.png")
        let bareSource = try #require(CGImageSourceCreateWithData(bare as CFData, nil))
        #expect(try #require(ImageOps.loadUpright(from: bareSource)).dpi == nil)
    }

    @Test func theDensityIsThatOfTheLargestImageWhateverTheOrder() throws {
        let small = TestImages.solid(width: 10, height: 10, color: TestImages.red)
        let large = TestImages.solid(width: 20, height: 20, color: TestImages.red)
        for pair in [[(small, 72.0), (large, 144.0)], [(large, 144.0), (small, 72.0)]] {
            let tiff = Self.encoded(pair.map { (image: $0.0, dpi: $0.1) }, as: "public.tiff")
            let source = try #require(CGImageSourceCreateWithData(tiff as CFData, nil))
            let loaded = try #require(ImageOps.loadUpright(from: source))
            #expect(loaded.image.width == 20)
            #expect(loaded.dpi == 144)
        }
    }

    @Test func loadingFromAnOpenSourceAppliesTheOrientationTag() throws {
        let data = Self.jpegData(TestImages.solid(width: 40, height: 20, color: TestImages.red), orientation: 6)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let loaded = try #require(ImageOps.loadUpright(from: source))
        #expect(loaded.image.width == 20)
        #expect(loaded.image.height == 40)
    }

    /// A picture past the output limit is decoded scaled down to it, not in full first; its density still comes with it.
    @Test func aHugeImageLoadsAtTheOutputLimit() throws {
        let png = try ImageEncoder.encode(TestImages.solid(width: 20_000, height: 10, color: TestImages.red), as: .png, quality: 1,
                                          pixelsPerPoint: 2)
        let url = FileManager.default.temporaryDirectory.appending(path: "huge-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try png.write(to: url)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let loaded = try #require(ImageOps.loadUpright(from: source))
        #expect(loaded.dpi == 144)
        let fromData = try #require(ImageOps.loadUpright(data: png))
        let fromFile = try #require(ImageOps.loadUpright(url))
        for (name, image) in [("source", loaded.image), ("data", fromData), ("file", fromFile)] {
            #expect(image.width <= 16_383 && image.width > 16_000, "\(name): \(image.width)")
            #expect(image.height <= 8 && image.height >= 7, "\(name): \(image.height)")
            #expect(TestImages.pixel(image, x: image.width / 2, y: image.height / 2) == TestImages.RGBA(r: 255, g: 0, b: 0, a: 255),
                    "\(name)")
        }
    }

    @Test func aSourceWithNoImageGivesNothing() throws {
        let source = try #require(CGImageSourceCreateWithData(Data("not an image".utf8) as CFData, nil))
        #expect(ImageOps.loadUpright(from: source) == nil)
    }
}
