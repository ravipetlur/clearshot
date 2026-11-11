import CoreGraphics
import CSCore
import Foundation
import Testing
@testable import CSCapture

struct FormatClassifierTests {
    /// A deterministic pseudo-random byte source.
    struct Noise {
        var state: UInt32 = 987_654_321
        mutating func next() -> Int {
            state = state &* 1_103_515_245 &+ 12345
            return Int(state >> 16) & 0x7FFF
        }
    }

    static func render(width: Int, height: Int, opaque: Bool = true, _ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: TestImages.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }

    /// A UI mock: a window with a toolbar, sidebar, list rows, and text-like strokes (thin dark bars, several colors).
    static func uiMock(width: Int, height: Int) -> CGImage {
        render(width: width, height: height) { context in
            func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) {
                context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
                context.fill(rect)
            }
            let w = CGFloat(width), h = CGFloat(height)
            fill(1, 1, 1, CGRect(x: 0, y: 0, width: w, height: h))
            fill(0.93, 0.93, 0.95, CGRect(x: 0, y: h * 0.92, width: w, height: h * 0.08))
            fill(0.95, 0.95, 0.97, CGRect(x: 0, y: 0, width: w * 0.22, height: h * 0.92))
            fill(0.2, 0.45, 0.95, CGRect(x: w * 0.25, y: h * 0.8, width: w * 0.12, height: h * 0.05))
            var rng = Noise()
            for row in 0..<28 {
                let y = h * 0.86 - CGFloat(row) * h * 0.028
                var x = w * 0.25
                while x < w * 0.9 {
                    let length = w * (0.01 + CGFloat(rng.next() % 40) / 1000)
                    fill(0.12, 0.12, 0.14, CGRect(x: x, y: y, width: length, height: h * 0.006))
                    x += length + w * 0.008
                }
            }
        }
    }

    /// A photo-like picture: a smooth diagonal color gradient with a few soft blobs and sensor-like noise.
    static func photoLike(width: Int, height: Int) -> CGImage {
        var rng = Noise()
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width), v = Double(y) / Double(height)
                let blob = exp(-((u - 0.4) * (u - 0.4) + (v - 0.5) * (v - 0.5)) * 12)
                let base = [0.2 + 0.6 * u + 0.2 * blob, 0.3 + 0.4 * v + 0.3 * blob, 0.7 - 0.4 * u * v + 0.1 * blob]
                let index = (y * width + x) * 4
                for channel in 0..<3 {
                    let noise = Double(rng.next() % 17 - 8) / 255
                    bytes[index + channel] = UInt8(max(0, min(255, (base[channel] + noise) * 255)))
                }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: TestImages.srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func aFlatUIMockIsFlat() throws {
        let image = Self.uiMock(width: 1600, height: 1000)
        let measured = try #require(FormatClassifier.measure(image))
        #expect(measured.distinctColors < 100)
        #expect(measured.topShare > 0.9)
        #expect(FormatClassifier.classify(image) == .flat)
        #expect(ExportFormatPolicy.format(preferred: .automatic, image: image, isTransparent: false) == .png)
    }

    @Test func aNoisyGradientIsPhotographic() throws {
        let image = Self.photoLike(width: 1600, height: 1000)
        let measured = try #require(FormatClassifier.measure(image))
        #expect(measured.distinctColors > 1_000)
        #expect(measured.topShare < 0.1)
        #expect(FormatClassifier.classify(image) == .photographic)
        #expect(ExportFormatPolicy.format(preferred: .automatic, image: image, isTransparent: false) == .jpeg)
    }

    @Test func pureNoiseIsPhotographic() {
        #expect(FormatClassifier.classify(TestImages.noise(width: 800, height: 600)) == .photographic)
    }

    @Test func aSolidPictureIsFlat() {
        #expect(FormatClassifier.classify(TestImages.solid(width: 300, height: 200, color: TestImages.red)) == .flat)
    }

    @Test func aPhotoInsideAMostlyFlatPageStaysPNG() {
        // A page that's a quarter photograph: its text would smear in JPEG.
        let photo = Self.photoLike(width: 400, height: 300)
        let page = Self.render(width: 1600, height: 1000) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
            context.draw(photo, in: CGRect(x: 100, y: 500, width: 600, height: 450))
        }
        #expect(FormatClassifier.classify(page) == .flat)
    }

    @Test func transparencyIsAlwaysPNG() {
        let image = Self.render(width: 1200, height: 800) { context in
            context.draw(Self.photoLike(width: 1200, height: 800), in: CGRect(x: 0, y: 0, width: 1200, height: 800))
            context.clear(CGRect(x: 0, y: 0, width: 1200, height: 100))
        }
        #expect(FormatClassifier.classify(image) == .flat)
        // The caller's own transparency flag counts too, even when the sampled pixels are all opaque.
        let photo = Self.photoLike(width: 400, height: 300)
        #expect(ExportFormatPolicy.format(preferred: .automatic, image: photo, isTransparent: true) == .png)
    }

    @Test func anUnreadablePictureIsPNG() {
        #expect(ExportFormatPolicy.format(preferred: .automatic, image: nil, isTransparent: false) == .png)
    }

    @Test func fixedFormatsKeepTheirOwnRules() {
        let photo = Self.photoLike(width: 400, height: 300)
        #expect(ExportFormatPolicy.format(preferred: .png, image: photo, isTransparent: false) == .png)
        #expect(ExportFormatPolicy.format(preferred: .jpeg, image: photo, isTransparent: false) == .jpeg)
        #expect(ExportFormatPolicy.format(preferred: .jpeg, image: photo, isTransparent: true) == .png)
        #expect(ExportFormatPolicy.format(preferred: .webp, image: nil, isTransparent: false) == .webp)
    }

    /// A 6K capture (6016 x 3384) classified well inside 20 ms. Measured on Apple Silicon at about 1 to 3 ms. The time is
    /// the calling thread's CPU time, best of five, so a busy test machine doesn't make it flaky.
    @Test func aSixKCaptureClassifiesQuickly() {
        let image = Self.uiMock(width: 6016, height: 3384)
        _ = FormatClassifier.classify(image)  // warm up
        let best = (0..<5).map { _ in
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            _ = FormatClassifier.classify(image)
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6
        }.min() ?? .infinity
        print("FormatClassifier 6K: \(best) ms of CPU")
        #expect(best < 20)
    }
}
