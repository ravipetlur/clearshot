import CoreGraphics
import Testing
@testable import CSCapture

struct PostProcessorTests {
    @Test func scalingTo1xHalvesARetinaImage() {
        let image = TestImages.solid(width: 20, height: 10, color: TestImages.red)
        let result = PostProcessor.apply(image, scale: 2, options: PostProcessOptions(scaleTo1x: true))
        #expect(result.width == 10)
        #expect(result.height == 5)
    }

    @Test func scalingTo1xLeavesNonRetinaImagesAlone() {
        let image = TestImages.solid(width: 20, height: 10, color: TestImages.red)
        let result = PostProcessor.apply(image, scale: 1, options: PostProcessOptions(scaleTo1x: true))
        #expect(result.width == 20)
    }

    @Test func borderKeepsTheSizeAndOnlyDarkensTheEdge() {
        let image = TestImages.solid(width: 10, height: 10, color: TestImages.white)
        let result = PostProcessor.addingBorder(image)
        #expect(result.width == 10 && result.height == 10)
        #expect(TestImages.pixel(result, x: 0, y: 0).r < 255)
        #expect(TestImages.pixel(result, x: 5, y: 5) == TestImages.RGBA(r: 255, g: 255, b: 255, a: 255))
    }

    @Test func croppingTopRemovesTheTopRows() {
        let image = TestImages.withTopRows(width: 6, height: 10, rows: 2, top: TestImages.red, base: TestImages.blue)
        let result = PostProcessor.croppingTop(image, pixels: 2)
        #expect(result.height == 8)
        #expect(TestImages.pixel(result, x: 0, y: 0).b == 255)
    }

    @Test func croppedUsesATopLeftOrigin() {
        let image = TestImages.withTopRows(width: 6, height: 10, rows: 2, top: TestImages.red, base: TestImages.blue)
        let top = PostProcessor.cropped(image, to: CGRect(x: 0, y: 0, width: 6, height: 2))
        #expect(top.map { TestImages.pixel($0, x: 3, y: 1).r } == 255)
        #expect(PostProcessor.cropped(image, to: CGRect(x: 50, y: 50, width: 4, height: 4)) == nil)
    }

    @Test func compositeAddsPaddingFilledWithTheBackground() {
        let window = TestImages.solid(width: 10, height: 10, color: TestImages.red)
        let background = TestImages.solid(width: 30, height: 30, color: TestImages.green)
        let result = PostProcessor.compositingWindow(window, background: background, padding: 5)
        #expect(result.width == 20 && result.height == 20)
        #expect(TestImages.pixel(result, x: 0, y: 0).g == 255)
        #expect(TestImages.pixel(result, x: 10, y: 10).r == 255)
    }

    @Test func compositeWithoutBackgroundIsTransparentPadding() {
        let window = TestImages.solid(width: 10, height: 10, color: TestImages.red)
        let result = PostProcessor.compositingWindow(window, background: nil, padding: 4)
        #expect(TestImages.pixel(result, x: 0, y: 0).a == 0)
    }

    @Test func sRGBConversionChangesTheColorSpace() {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let image = TestImages.solid(width: 4, height: 4, color: TestImages.red, space: p3)
        #expect(PostProcessor.convertedToSRGB(image).colorSpace?.name == CGColorSpace.sRGB)
    }
}
