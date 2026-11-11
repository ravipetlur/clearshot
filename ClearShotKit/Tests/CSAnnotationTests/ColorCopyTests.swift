import CoreGraphics
import CSCore
import Foundation
import Testing
@testable import CSAnnotation

/// Which point or area each color-copy command reads, and how the result is written.
struct ColorCopyTests {
    private let red = RGBAColor(red: 1, green: 0, blue: 0)
    private let green = RGBAColor(red: 0, green: 1, blue: 0)
    private let blue = RGBAColor(red: 0, green: 0, blue: 1)

    /// 40 × 20, a quarter each: red top-left, green top-right, blue bottom-left, white bottom-right.
    private func pixels() throws -> PicturePixels {
        let (document, images) = TestBitmaps.document(base: TestBitmaps.quadrants(40, 20, topLeft: TestBitmaps.red,
                                                                                  topRight: TestBitmaps.green,
                                                                                  bottomLeft: TestBitmaps.blue,
                                                                                  bottomRight: TestBitmaps.white))
        return try #require(PicturePixels.make(of: document, images: images))
    }

    @Test func underPointerReadsThePixelThere() throws {
        let pixels = try pixels()
        #expect(ColorCopy.underPointer.color(in: pixels, pointer: CGPoint(x: 5, y: 5), selection: nil) == red)
        #expect(ColorCopy.underPointer.color(in: pixels, pointer: CGPoint(x: 35, y: 15), selection: nil) == .white)
    }

    @Test func underPointerHasNothingOffThePictureOrWithoutAPointer() throws {
        let pixels = try pixels()
        #expect(ColorCopy.underPointer.color(in: pixels, pointer: CGPoint(x: 90, y: 5), selection: nil) == nil)
        #expect(ColorCopy.underPointer.color(in: pixels, pointer: nil, selection: nil) == nil)
        #expect(ColorCopy.textUnderPointer.color(in: pixels, pointer: nil, selection: nil) == nil)
    }

    /// On the red and blue quarters' boundary the 20-pixel square reaches both, and the darker one wins; well inside a
    /// quarter, it is that quarter's color.
    @Test func textUnderPointerTakesTheDarkestInTheSquare() throws {
        let pixels = try pixels()
        let boundary = CGPoint(x: 5, y: 10)
        let color = try #require(ColorCopy.textUnderPointer.color(in: pixels, pointer: boundary, selection: nil))
        #expect(color == pixels.darkest(around: boundary, side: ColorCopy.textSide))
        #expect(color == blue)
        #expect(ColorCopy.textUnderPointer.color(in: pixels, pointer: CGPoint(x: 35, y: 3), selection: nil) == green)
    }

    @Test func selectionAverageNeedsASelection() throws {
        let pixels = try pixels()
        #expect(ColorCopy.selectionAverage.color(in: pixels, pointer: CGPoint(x: 5, y: 5), selection: nil) == nil)
        let inRed = CGRect(x: 1, y: 1, width: 8, height: 8)
        #expect(ColorCopy.selectionAverage.color(in: pixels, pointer: nil, selection: inRed) == red)
        let top = try #require(ColorCopy.selectionAverage.color(in: pixels, pointer: nil,
                                                                selection: CGRect(x: 0, y: 0, width: 40, height: 10)))
        #expect(abs(top.red - 0.5) < 0.01 && abs(top.green - 0.5) < 0.01 && top.blue < 0.01)
    }

    @Test func textAndNoticeFollowTheFormat() {
        let dodger = RGBAColor(red: 30 / 255, green: 144 / 255, blue: 1)
        #expect(ColorCopy.text(for: dodger, format: .hex) == "#1E90FF")
        #expect(ColorCopy.text(for: dodger, format: .hexWithoutHash) == "1E90FF")
        #expect(ColorCopy.text(for: dodger, format: .rgb) == "rgb(30, 144, 255)")
        #expect(ColorCopy.notice(copying: "#1E90FF") == "Copied #1E90FF")
    }
}
