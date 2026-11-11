import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// The pixel buffer the pixel tools read: colors, areas, edges and flood fills, in the sampler's own pixels.
struct PixelSamplerTests {
    /// A sampler over `width` × `height` pixels painted by `color(x, y)` (opaque bytes, rows top first).
    private func sampler(_ width: Int, _ height: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> PixelSampler {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let index = (y * width + x) * 4
                bytes[index] = r; bytes[index + 1] = g; bytes[index + 2] = b
            }
        }
        return PixelSampler(width: width, height: height, premultipliedRGBA: bytes)!
    }

    private let white: (UInt8, UInt8, UInt8) = (255, 255, 255)
    private let black: (UInt8, UInt8, UInt8) = (0, 0, 0)

    // MARK: Building

    @Test func readsAnImageRowsTopFirst() throws {
        let image = TestBitmaps.quadrants(4, 4, topLeft: TestBitmaps.red, topRight: TestBitmaps.green, bottomLeft: TestBitmaps.blue,
                                          bottomRight: TestBitmaps.white)
        let sampler = try #require(PixelSampler(image: image))
        #expect(sampler.width == 4 && sampler.height == 4)
        #expect(sampler.color(at: CGPoint(x: 0.5, y: 0.5)) == RGBAColor(red: 1, green: 0, blue: 0))
        #expect(sampler.color(at: CGPoint(x: 3, y: 0)) == RGBAColor(red: 0, green: 1, blue: 0))
        #expect(sampler.color(at: CGPoint(x: 0, y: 3.9)) == RGBAColor(red: 0, green: 0, blue: 1))
        #expect(sampler.color(at: CGPoint(x: 3, y: 3)) == .white)
    }

    @Test func convertsOtherColorSpacesToSRGB() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: p3, components: [0.5, 0.5, 0.5, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let sampler = try #require(PixelSampler(image: context.makeImage()!))
        let color = try #require(sampler.color(at: .zero))
        // P3 and sRGB share their transfer curve and white point: a gray stays the same gray.
        #expect(abs(color.red - 0.5) < 0.01 && abs(color.green - 0.5) < 0.01 && abs(color.blue - 0.5) < 0.01)
    }

    @Test func refusesBytesOfTheWrongSize() {
        #expect(PixelSampler(width: 2, height: 2, premultipliedRGBA: [UInt8](repeating: 0, count: 15)) == nil)
        #expect(PixelSampler(width: 0, height: 2, premultipliedRGBA: []) == nil)
    }

    // MARK: Points

    @Test func pointsOutsideThePictureHaveNoColor() {
        let sampler = sampler(3, 3) { _, _ in white }
        #expect(sampler.color(at: CGPoint(x: -0.1, y: 1)) == nil)
        #expect(sampler.color(at: CGPoint(x: 3, y: 1)) == nil)
        #expect(sampler.color(at: CGPoint(x: 1, y: 3)) == nil)
        #expect(sampler.color(at: CGPoint(x: CGFloat.nan, y: 1)) == nil)
        #expect(sampler.color(at: CGPoint(x: CGFloat.infinity, y: 1)) == nil)
        #expect(sampler.color(at: CGPoint(x: 2.99, y: 2.99)) == .white)
    }

    @Test func colorsAreUnpremultiplied() throws {
        // Half-transparent red, premultiplied: (128, 0, 0, 128).
        let sampler = try #require(PixelSampler(width: 1, height: 1, premultipliedRGBA: [128, 0, 0, 128]))
        let color = try #require(sampler.color(at: .zero))
        #expect(color.red == 1 && color.green == 0 && color.alpha == 128.0 / 255)
        let clear = try #require(PixelSampler(width: 1, height: 1, premultipliedRGBA: [0, 0, 0, 0]))
        #expect(clear.color(at: .zero) == RGBAColor(red: 0, green: 0, blue: 0, alpha: 0))
    }

    // MARK: Areas

    @Test func averagesTheWholePixelsARectTouches() throws {
        // Left half black, right half white.
        let sampler = sampler(4, 2) { x, _ in x < 2 ? black : white }
        let all = try #require(sampler.average(in: CGRect(x: 0, y: 0, width: 4, height: 2)))
        #expect(abs(all.red - 0.5) < 1e-9 && all.alpha == 1)
        // 0.5...2.5 touches columns 0, 1 and 2: two black, one white.
        let part = try #require(sampler.average(in: CGRect(x: 0.5, y: 0, width: 2, height: 1)))
        #expect(abs(part.red - 1.0 / 3) < 1e-9)
        // Cut to the picture.
        let edge = try #require(sampler.average(in: CGRect(x: 3, y: -5, width: 10, height: 10)))
        #expect(edge == .white)
        #expect(sampler.average(in: CGRect(x: 10, y: 10, width: 2, height: 2)) == nil)
        #expect(sampler.average(in: .null) == nil)
    }

    @Test func averageWeighsColorByAlpha() throws {
        // An opaque red pixel beside a transparent one: the color stays red, half as opaque.
        let sampler = try #require(PixelSampler(width: 2, height: 1, premultipliedRGBA: [255, 0, 0, 255, 0, 0, 0, 0]))
        let average = try #require(sampler.average(in: sampler.bounds))
        #expect(average.red == 1 && average.green == 0 && abs(average.alpha - 0.5) < 1e-9)
    }

    @Test func darkestFindsTheInkOfText() throws {
        // A white field with a dark gray stroke and a darker blue dot.
        let sampler = sampler(10, 10) { x, y in
            if x == 7, y == 7 { return (0, 0, 80) }
            return x == 3 ? (60, 60, 60) : white
        }
        #expect(sampler.darkest(in: CGRect(x: 0, y: 0, width: 5, height: 5)) == RGBAColor(red: 60.0 / 255, green: 60.0 / 255, blue: 60.0 / 255))
        #expect(sampler.darkest(in: sampler.bounds) == RGBAColor(red: 0, green: 0, blue: 80.0 / 255))
        #expect(sampler.darkest(in: CGRect(x: 20, y: 20, width: 5, height: 5)) == nil)
    }

    @Test func darkestSkipsTransparentPixels() throws {
        let sampler = try #require(PixelSampler(width: 2, height: 1, premultipliedRGBA: [0, 0, 0, 0, 200, 200, 200, 255]))
        #expect(sampler.darkest(in: sampler.bounds) == RGBAColor(red: 200.0 / 255, green: 200.0 / 255, blue: 200.0 / 255))
        let clear = try #require(PixelSampler(width: 1, height: 1, premultipliedRGBA: [0, 0, 0, 0]))
        #expect(clear.darkest(in: clear.bounds) == nil)
    }

    // MARK: Edges

    /// White, with a black frame around columns 2...7 and rows 3...6 (as a button drawn on a page).
    private func framed() -> PixelSampler {
        sampler(12, 10) { x, y in
            let insideX = (2...7).contains(x), insideY = (3...6).contains(y)
            let frame = insideX && insideY && (x == 2 || x == 7 || y == 3 || y == 6)
            return frame ? black : white
        }
    }

    @Test func edgeIsTheDistanceToTheFirstDifferentPixel() {
        let sampler = framed()
        let start = CGPoint(x: 4.5, y: 4.5)
        // Inside the frame: columns 3...6 and rows 4...5 are white.
        #expect(sampler.edge(from: start, direction: .left, tolerance: 0) == 2)
        #expect(sampler.edge(from: start, direction: .right, tolerance: 0) == 3)
        #expect(sampler.edge(from: start, direction: .up, tolerance: 0) == 1)
        #expect(sampler.edge(from: start, direction: .down, tolerance: 0) == 2)
    }

    @Test func edgeStopsAtThePictureBorder() {
        let sampler = sampler(5, 1) { _, _ in white }
        #expect(sampler.edge(from: CGPoint(x: 1, y: 0), direction: .left, tolerance: 0) == 2)
        #expect(sampler.edge(from: CGPoint(x: 1, y: 0), direction: .right, tolerance: 0) == 4)
        #expect(sampler.edge(from: CGPoint(x: 4, y: 0), direction: .right, tolerance: 0) == 1)
        #expect(sampler.edge(from: CGPoint(x: 5, y: 0), direction: .right, tolerance: 0) == nil)
    }

    @Test func edgeToleranceLetsNearColorsThrough() {
        // A gentle ramp: each column 3 levels darker than the last.
        let sampler = sampler(10, 1) { x, _ in
            let level = UInt8(255 - 3 * x)
            return (level, level, level)
        }
        #expect(sampler.edge(from: .zero, direction: .right, tolerance: 0) == 1)
        // Within 10 of the start's 255: columns 0...3 (255, 252, 249, 246).
        #expect(sampler.edge(from: .zero, direction: .right, tolerance: 10) == 4)
        #expect(sampler.edge(from: .zero, direction: .right, tolerance: 255) == 10)
    }

    // MARK: Flood fill

    @Test func floodFillFindsTheConnectedRegion() {
        let sampler = framed()
        #expect(sampler.floodFillBounds(from: CGPoint(x: 4, y: 4), tolerance: 0, maxPixels: 1000) == CGRect(x: 3, y: 4, width: 4, height: 2))
        // The frame itself.
        #expect(sampler.floodFillBounds(from: CGPoint(x: 2, y: 3), tolerance: 0, maxPixels: 1000) == CGRect(x: 2, y: 3, width: 6, height: 4))
        // The page around it reaches every edge, round the frame.
        #expect(sampler.floodFillBounds(from: CGPoint(x: 0, y: 0), tolerance: 0, maxPixels: 1000) == sampler.bounds)
    }

    @Test func floodFillFollowsSidesNotCorners() {
        // Two black pixels touching only at a corner.
        let sampler = sampler(4, 4) { x, y in (x == 1 && y == 1) || (x == 2 && y == 2) ? black : white }
        #expect(sampler.floodFillBounds(from: CGPoint(x: 1, y: 1), tolerance: 0, maxPixels: 100) == CGRect(x: 1, y: 1, width: 1, height: 1))
    }

    @Test func floodFillFollowsWindingShapes() {
        // A black U: the fill has to go down one arm, along the bottom and up the other.
        let sampler = sampler(7, 6) { x, y in
            let arm = (x == 1 || x == 5) && (1...4).contains(y)
            let bottom = y == 4 && (1...5).contains(x)
            return arm || bottom ? black : white
        }
        #expect(sampler.floodFillBounds(from: CGPoint(x: 5, y: 1), tolerance: 0, maxPixels: 100) == CGRect(x: 1, y: 1, width: 5, height: 4))
    }

    @Test func floodFillGivesUpPastTheCap() {
        let sampler = framed()
        // The inside is 4 × 2 = 8 pixels.
        #expect(sampler.floodFillBounds(from: CGPoint(x: 4, y: 4), tolerance: 0, maxPixels: 8) != nil)
        #expect(sampler.floodFillBounds(from: CGPoint(x: 4, y: 4), tolerance: 0, maxPixels: 7) == nil)
        #expect(sampler.floodFillBounds(from: CGPoint(x: -1, y: 4), tolerance: 0, maxPixels: 100) == nil)
    }

    @Test func floodFillComparesWithTheStartPixel() {
        // A ramp 3 levels a column: tolerance 10 reaches four columns from the start, not the whole ramp step by step.
        let sampler = sampler(10, 2) { x, _ in
            let level = UInt8(255 - 3 * x)
            return (level, level, level)
        }
        #expect(sampler.floodFillBounds(from: .zero, tolerance: 10, maxPixels: 100) == CGRect(x: 0, y: 0, width: 4, height: 2))
    }

    /// A scrolling capture's height and a 6K display's width: built once, then each read is quick and a fill on the page
    /// stops at its cap.
    @Test func handlesATallPicture() throws {
        let width = 1_000, height = 16_383
        let context = TestBitmaps.context(width, height)
        context.setFillColor(TestBitmaps.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(TestBitmaps.black)
        // A black bar across the top 10 rows (CG is y-up).
        context.fill(CGRect(x: 0, y: height - 10, width: width, height: 10))
        let sampler = try #require(PixelSampler(image: context.makeImage()!))
        #expect(sampler.edge(from: CGPoint(x: 500, y: 16_000), direction: .up, tolerance: 0) == 15_991)
        #expect(sampler.floodFillBounds(from: CGPoint(x: 500, y: 16_000), tolerance: 0, maxPixels: 1_000_000) == nil)
        #expect(sampler.floodFillBounds(from: CGPoint(x: 500, y: 5), tolerance: 0, maxPixels: 1_000_000)
            == CGRect(x: 0, y: 0, width: width, height: 10))
    }
}
