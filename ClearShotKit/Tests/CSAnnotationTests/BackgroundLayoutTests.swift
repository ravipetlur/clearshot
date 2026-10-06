import CoreGraphics
import CSCapture
import Foundation
import Testing
@testable import CSAnnotation

/// The background's frame in output pixels: padding and inset at the document's scale, the ratio and the alignment, the
/// 16 383-pixel limit, the corners and the output bounds; and auto-balance's trims.
struct BackgroundLayoutTests {
    static func style(padding: Double = 0, inset: Double = 0, corners: Double = 0, alignment: BackgroundAlignment = .center,
                      ratio: BackgroundRatio = .auto, autoBalance: Bool = false) -> BackgroundStyle {
        var style = BackgroundStyle.standard
        style.padding = padding
        style.inset = inset
        style.corners = corners
        style.alignment = alignment
        style.ratio = ratio
        style.autoBalance = autoBalance
        return style
    }

    /// The layout around a canvas of `width` by `height` at the origin.
    static func layout(_ width: Double, _ height: Double, scale: Double = 1, _ style: BackgroundStyle) -> BackgroundLayout {
        BackgroundLayout.make(canvas: CGRect(x: 0, y: 0, width: width, height: height), style: style, scale: scale)
    }

    static func document(_ width: Double, _ height: Double, pixelScale: Double = 1, style: BackgroundStyle?) -> AnnotationDocument {
        var document = AnnotationDocument(baseSize: CGSize(width: width, height: height), pixelScale: pixelScale)
        document.background = style.map { DocumentBackground(style: $0) }
        return document
    }

    // MARK: The layout

    @Test func noRatioCentersTheBoxWithEvenPadding() {
        let layout = Self.layout(100, 80, Self.style(padding: 64))
        let canvas = CGRect(x: 0, y: 0, width: 100, height: 80)
        #expect(layout.frame == CGRect(x: -64, y: -64, width: 228, height: 208))
        #expect(layout.content == canvas)
        #expect(layout.box == canvas)
        #expect(layout.padding == 64)
        #expect(layout.inset == 0)
        #expect(layout.ratio == .auto)
    }

    @Test func paddingAndInsetFollowTheScale() throws {
        let document = Self.document(200, 160, pixelScale: 2, style: Self.style(padding: 64, inset: 8))
        #expect(document.backgroundScale == 2)
        let layout = try #require(document.backgroundLayout())
        #expect(layout.padding == 128)
        #expect(layout.inset == 16)
        #expect(layout.content == CGRect(x: 0, y: 0, width: 200, height: 160))
        #expect(layout.box == CGRect(x: -16, y: -16, width: 232, height: 192))
        #expect(layout.frame == CGRect(x: -144, y: -144, width: 488, height: 448))
        #expect(document.outputBounds() == layout.frame)
    }

    @Test func aResizeOpScalesTheLengths() throws {
        let style = Self.style(padding: 64, inset: 8, corners: 12)
        let halved = Self.document(200, 160, pixelScale: 2, style: style).applying(.resize(width: 100, height: 80))
        let oneX = Self.document(100, 80, pixelScale: 1, style: style)
        #expect(halved.backgroundScale == 1)
        let layout = try #require(halved.backgroundLayout())
        let expected = try #require(oneX.backgroundLayout())
        #expect(layout == expected)
        #expect(layout.padding == 64)
        #expect(layout.inset == 8)
        #expect(layout.cornerRadius == 12)
    }

    @Test func paddingRoundsLikeTheWindowCapture() {
        #expect(Self.layout(100, 80, scale: 1.5, Self.style(padding: 13)).padding == 20)
        #expect(Self.layout(100, 80, Self.style(padding: 47.6)).padding == 48)
        // A half rounds away from zero, never to even: 18.5 is 19, not 18. The inset rounds the same way.
        #expect(Self.layout(100, 80, Self.style(padding: 18.5)).padding == 19)
        #expect(Self.layout(100, 80, Self.style(inset: 18.5)).inset == 19)
        #expect(Self.layout(100, 80, scale: 1.5, Self.style(inset: 13)).inset == 20)
    }

    @Test func ratioGrowsTheShorterSide() {
        let wide = Self.layout(100, 100, Self.style(ratio: .r16x9))
        #expect(wide.frame.size == CGSize(width: 178, height: 100))
        #expect(wide.ratio == .r16x9)
        let tall = Self.layout(100, 100, Self.style(ratio: .r9x16))
        #expect(tall.frame.size == CGSize(width: 100, height: 178))
        // An exact product stays exact rather than rounding up a pixel.
        #expect(Self.layout(100, 100, Self.style(ratio: .r3x2)).frame.size == CGSize(width: 150, height: 100))
        #expect(Self.layout(75, 75, Self.style(ratio: .r4x3)).frame.size == CGSize(width: 100, height: 75))
        #expect(Self.layout(75, 75, Self.style(ratio: .r3x4)).frame.size == CGSize(width: 75, height: 100))
        #expect(Self.layout(160, 90, Self.style(ratio: .r16x9)).frame.size == CGSize(width: 160, height: 90))
        // A frame wider than the ratio grows down; the padding counts before the ratio.
        #expect(Self.layout(200, 100, Self.style(ratio: .square)).frame.size == CGSize(width: 200, height: 200))
        #expect(Self.layout(100, 100, Self.style(padding: 10, ratio: .r16x9)).frame.size == CGSize(width: 214, height: 120))
    }

    @Test func alignmentPlacesTheSlack() {
        func origin(_ alignment: BackgroundAlignment, _ ratio: BackgroundRatio = .r16x9) -> CGPoint {
            Self.layout(100, 100, Self.style(alignment: alignment, ratio: ratio)).frame.origin
        }
        #expect(origin(.topLeft) == CGPoint(x: 0, y: 0))
        #expect(origin(.center) == CGPoint(x: -39, y: 0))
        #expect(origin(.bottomRight) == CGPoint(x: -78, y: 0))
        // Down a tall frame.
        #expect(origin(.top, .r9x16) == CGPoint(x: 0, y: 0))
        #expect(origin(.center, .r9x16) == CGPoint(x: 0, y: -39))
        #expect(origin(.bottom, .r9x16) == CGPoint(x: 0, y: -78))
        // An odd slack splits on whole pixels: 5:4 on 100 leaves 25, 12 before the box and 13 after.
        #expect(origin(.center, .r5x4) == CGPoint(x: -12, y: 0))
        #expect(origin(.right, .r5x4) == CGPoint(x: -25, y: 0))
    }

    @Test func thinPictureWithRatioFallsBackToAuto() {
        let layout = Self.layout(16_000, 100, Self.style(padding: 64, ratio: .r9x16))
        #expect(layout.ratio == .auto)
        #expect(layout.padding == 64)
        #expect(layout.frame == CGRect(x: -64, y: -64, width: 16_128, height: 228))
    }

    @Test func aHugePaddingIsReducedToFit() {
        let layout = Self.layout(16_000, 100, Self.style(padding: 256))
        #expect(layout.padding == 191)
        #expect(layout.ratio == .auto)
        #expect(layout.frame == CGRect(x: -191, y: -191, width: 16_382, height: 482))
        // With a ratio: Auto first, then less padding.
        let withRatio = Self.layout(16_000, 100, Self.style(padding: 256, ratio: .r16x9))
        #expect(withRatio.ratio == .auto)
        #expect(withRatio.padding == 191)
        #expect(withRatio.frame == layout.frame)
    }

    @Test func anOversizedBoxReducesTheInset() {
        let layout = Self.layout(16_300, 50, Self.style(padding: 64, inset: 128))
        #expect(layout.inset == 41)
        #expect(layout.padding == 0)
        #expect(layout.ratio == .auto)
        #expect(layout.box == CGRect(x: -41, y: -41, width: 16_382, height: 132))
        #expect(layout.frame == layout.box)
    }

    @Test func aContentOverTheLimitIsItsOwnFrame() {
        // Only a document `isWellFormed` allows, up to 32 768 a side, can be this big.
        let layout = Self.layout(20_000, 100, Self.style(padding: 64, inset: 8, ratio: .square))
        let canvas = CGRect(x: 0, y: 0, width: 20_000, height: 100)
        #expect(layout.frame == canvas)
        #expect(layout.box == canvas)
        #expect(layout.content == canvas)
        #expect(layout.padding == 0)
        #expect(layout.inset == 0)
        #expect(layout.ratio == .auto)
    }

    @Test func cornerRadiusIsClampedToHalfTheShorterSide() {
        #expect(Self.layout(100, 40, scale: 2, Self.style(corners: 64)).cornerRadius == 20)
        #expect(Self.layout(100, 80, scale: 2, Self.style(corners: 12)).cornerRadius == 24)
        // The inset is part of the box: 10 px of it make the box 120 by 60.
        #expect(Self.layout(100, 40, scale: 2, Self.style(inset: 5, corners: 64)).cornerRadius == 30)
        #expect(Self.layout(100, 40, Self.style(corners: 0)).cornerRadius == 0)
        #expect(Self.layout(100, 40, Self.style(corners: -8)).cornerRadius == 0)
    }

    // MARK: The output bounds

    @Test func outputBoundsIsTheCanvasWithoutABackground() {
        var document = Self.document(100, 80, style: nil)
        document.canvasRect = CGRect(x: -10, y: -5, width: 120, height: 90)
        #expect(document.backgroundLayout() == nil)
        #expect(document.outputBounds() == document.canvasBounds)
        #expect(document.outputBounds(trims: EdgeTrims(top: 5, left: 5, bottom: 5, right: 5)) == document.canvasBounds)
        // With one, the frame around that canvas.
        document.background = DocumentBackground(style: Self.style(padding: 10))
        #expect(document.outputBounds() == CGRect(x: -20, y: -15, width: 140, height: 110))
    }

    @Test func trimsShrinkTheContent() {
        let trims = EdgeTrims(top: 50, left: 100, bottom: 30, right: 60)
        let layout = BackgroundLayout.make(canvas: CGRect(x: 0, y: 0, width: 200, height: 100), style: Self.style(padding: 10),
                                           scale: 1, trims: trims)
        #expect(layout.content == CGRect(x: 100, y: 50, width: 40, height: 20))
        #expect(layout.box == layout.content)
        #expect(layout.frame == CGRect(x: 90, y: 40, width: 60, height: 40))
        // Through the document with auto-balance on; with it off the trims don't count.
        let balanced = Self.document(200, 100, style: Self.style(padding: 10, autoBalance: true))
        #expect(balanced.backgroundLayout(trims: trims) == layout)
        #expect(balanced.outputBounds(trims: trims) == layout.frame)
        let plain = Self.document(200, 100, style: Self.style(padding: 10))
        #expect(plain.outputBounds(trims: trims) == CGRect(x: -10, y: -10, width: 220, height: 120))
    }

    @Test func aFrameTooBigInPointsIsNotWellFormed() {
        // 8 175 px is 32 700 pt, within the limit; the 64 px of padding on each side take the frame to 33 212 pt.
        let framed = Self.document(8_175, 100, pixelScale: 0.25, style: Self.style(padding: 256))
        #expect(!framed.isWellFormed)
        let plain = Self.document(8_175, 100, pixelScale: 0.25, style: nil)
        #expect(plain.isWellFormed)
        #expect(Self.document(8_175, 100, pixelScale: 0.25, style: Self.style(padding: 0)).isWellFormed)
    }

    @Test func aResizeShareUsesTheOutputSize() {
        let document = Self.document(100, 80, style: Self.style(padding: 64))
        let frame = document.outputBounds()
        #expect(frame.size == CGSize(width: 228, height: 208))
        let change = ImageTransform.resize(width: 114, height: 104)
        #expect(document.imageOp(for: change, itemScale: 1, outputSize: frame.size) == .resize(width: 50, height: 40))
        // Without an output size the share is the canvas's, as before.
        #expect(document.imageOp(for: change, itemScale: 1) == .resize(width: 114, height: 104))
    }

    // MARK: Auto-balance

    static let white = TestBitmaps.RGBA(r: 255, g: 255, b: 255, a: 255)
    static let black = TestBitmaps.RGBA(r: 0, g: 0, b: 0, a: 255)
    static let red = TestBitmaps.RGBA(r: 255, g: 0, b: 0, a: 255)
    static let clear = TestBitmaps.RGBA(r: 0, g: 0, b: 0, a: 0)

    static func gray(_ level: UInt8) -> TestBitmaps.RGBA {
        TestBitmaps.RGBA(r: level, g: level, b: level, a: 255)
    }

    /// An sRGB picture whose pixel at (x, y), y counted from the top, is `color(x, y)`: premultiplied, or with
    /// `premultiplied` false, straight alpha (so a transparent pixel can keep a colour).
    static func picture(_ width: Int, _ height: Int, premultiplied: Bool = true,
                        _ color: (Int, Int) -> TestBitmaps.RGBA) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = color(x, y)
                let index = (y * width + x) * 4
                bytes[index] = pixel.r
                bytes[index + 1] = pixel.g
                bytes[index + 2] = pixel.b
                bytes[index + 3] = pixel.a
            }
        }
        let alpha = premultiplied ? CGImageAlphaInfo.premultipliedLast : .last
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: TestBitmaps.srgb, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func uniformMarginsAreTrimmed() {
        let image = Self.picture(200, 100) { x, y in
            (100..<140).contains(x) && (50..<70).contains(y) ? Self.black : Self.white
        }
        #expect(AutoBalance.trims(of: image) == EdgeTrims(top: 50, left: 100, bottom: 30, right: 60))
    }

    @Test func aUniformPictureIsNotTrimmed() {
        #expect(AutoBalance.trims(of: TestBitmaps.solid(200, 100, TestBitmaps.white)) == .zero)
        #expect(AutoBalance.trims(of: TestBitmaps.transparent(200, 100)) == .zero)
        // Within the tolerance of the top-left pixel everywhere is uniform too.
        let nearly = Self.picture(200, 100) { x, _ in x < 100 ? Self.white : Self.gray(250) }
        #expect(AutoBalance.trims(of: nearly) == .zero)
    }

    @Test func trimsKeepSixteenPixelsAndTenPercent() {
        // 199 a side would leave 2 px; each axis keeps 10% (40) and the trims are cut in proportion.
        let image = Self.picture(400, 400) { x, y in
            (199..<201).contains(x) && (199..<201).contains(y) ? Self.black : Self.white
        }
        #expect(AutoBalance.trims(of: image) == EdgeTrims(top: 180, left: 180, bottom: 180, right: 180))
        // On 100 px the 16-pixel minimum is the larger: 50 and 49 share 84, floored to 42 and 41, keeping 17.
        let small = Self.picture(100, 100) { x, y in x == 50 && y == 50 ? Self.black : Self.white }
        #expect(AutoBalance.trims(of: small) == EdgeTrims(top: 42, left: 42, bottom: 41, right: 41))
    }

    @Test func withinEightLevelsIsUniform() {
        // Twenty white rows, twenty rows at `level`, twenty white rows, then a black block over twenty rows.
        func picture(_ level: UInt8) -> CGImage {
            Self.picture(100, 100) { x, y in
                if (60..<80).contains(y), (40..<60).contains(x) { return Self.black }
                return (20..<40).contains(y) ? Self.gray(level) : Self.white
            }
        }
        #expect(AutoBalance.trims(of: picture(247)) == EdgeTrims(top: 60, left: 40, bottom: 20, right: 40))
        #expect(AutoBalance.trims(of: picture(246)) == EdgeTrims(top: 20, left: 0, bottom: 20, right: 0))
    }

    @Test func alphaCountsInTheTolerance() {
        // A transparent margin above and below rows of faint black.
        func picture(alpha: UInt8) -> CGImage {
            Self.picture(100, 100) { _, y in (30..<70).contains(y) ? TestBitmaps.RGBA(r: 0, g: 0, b: 0, a: alpha) : Self.clear }
        }
        #expect(AutoBalance.trims(of: picture(alpha: 10)) == EdgeTrims(top: 30, left: 0, bottom: 30, right: 0))
        // Eight levels of alpha are within the tolerance, so the whole picture is uniform.
        #expect(AutoBalance.trims(of: picture(alpha: 8)) == .zero)
        // Premultiplied, transparent red and transparent blue are the same pixel: one transparent margin.
        let colouredClear = Self.picture(100, 100, premultiplied: false) { x, y in
            if (30..<70).contains(y) { return Self.black }
            return x < 50 ? TestBitmaps.RGBA(r: 255, g: 0, b: 0, a: 0) : TestBitmaps.RGBA(r: 0, g: 0, b: 255, a: 0)
        }
        #expect(AutoBalance.trims(of: colouredClear) == EdgeTrims(top: 30, left: 0, bottom: 30, right: 0))
    }

    @Test func eachEdgeHasItsOwnReference() {
        // A white margin at the top and a black one at the bottom; then a white one at the left and a black one at the right.
        let rows = Self.picture(100, 100) { _, y in y < 30 ? Self.white : y < 70 ? Self.red : Self.black }
        #expect(AutoBalance.trims(of: rows) == EdgeTrims(top: 30, left: 0, bottom: 30, right: 0))
        let columns = Self.picture(100, 100) { x, _ in x < 30 ? Self.white : x < 70 ? Self.red : Self.black }
        #expect(AutoBalance.trims(of: columns) == EdgeTrims(top: 0, left: 30, bottom: 0, right: 30))
    }

    @Test func aPictureUnderSixteenPixelsIsNotTrimmed() {
        // 15 px across: the margins at the sides stay, the ones at the top and bottom go.
        let narrow = Self.picture(15, 100) { x, y in
            (5..<10).contains(x) && (40..<60).contains(y) ? Self.black : Self.white
        }
        #expect(AutoBalance.trims(of: narrow) == EdgeTrims(top: 40, left: 0, bottom: 40, right: 0))
        let tiny = Self.picture(15, 15) { x, y in x == 7 && y == 7 ? Self.black : Self.white }
        #expect(AutoBalance.trims(of: tiny) == .zero)
    }
}
