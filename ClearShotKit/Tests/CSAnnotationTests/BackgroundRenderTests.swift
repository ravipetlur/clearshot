import AppKit
import CoreGraphics
import CSCapture
import Testing
@testable import CSAnnotation

private let redColor = RGBAColor(red: 1, green: 0, blue: 0)
private let blueColor = RGBAColor(red: 0, green: 0, blue: 1)
private let greenColor = RGBAColor(red: 0, green: 1, blue: 0)
private let whiteColor = RGBAColor(red: 1, green: 1, blue: 1)

private let red = TestBitmaps.RGBA(r: 255, g: 0, b: 0, a: 255)
private let blue = TestBitmaps.RGBA(r: 0, g: 0, b: 255, a: 255)
private let green = TestBitmaps.RGBA(r: 0, g: 255, b: 0, a: 255)
private let white = TestBitmaps.RGBA(r: 255, g: 255, b: 255, a: 255)

/// Where a test document keeps its background picture.
private let pictureRef = ImageRef(name: "images/background.png")

/// The standard style (gradient fill, padding 64, shadow 50, corners 12) with `change` applied.
private func style(_ change: (inout BackgroundStyle) -> Void = { _ in }) -> BackgroundStyle {
    var style = BackgroundStyle.standard
    change(&style)
    return style
}

/// A document over `base` with a background in `style`. An image-backed fill refers to `pictureRef`, which holds `picture`
/// when one is given.
private func backgrounded(_ base: CGImage, _ style: BackgroundStyle = .standard, pixelScale: Double = 1,
                          objects: [AnnotationObject] = [], picture: CGImage? = nil) -> (AnnotationDocument, ImageStore) {
    var (document, images) = TestBitmaps.document(base: base, objects: objects)
    document.pixelScale = pixelScale
    document.background = DocumentBackground(style: style, image: style.fill.isImageBacked ? pictureRef : nil)
    if let picture { images.set(picture, for: pictureRef) }
    return (document, images)
}

private func render(_ document: AnnotationDocument, _ images: ImageStore) throws -> CGImage {
    try #require(Renderer.render(document, images: images))
}

private func isNear(_ a: TestBitmaps.RGBA, _ b: TestBitmaps.RGBA, within tolerance: Int) -> Bool {
    [(a.r, b.r), (a.g, b.g), (a.b, b.b), (a.a, b.a)].allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
}

/// `margin` pixels of `edge` around a block of `inside`.
private func margined(_ width: Int, _ height: Int, margin: Int, edge: CGColor, inside: CGColor) -> CGImage {
    let context = TestBitmaps.context(width, height)
    context.setFillColor(edge)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(inside)
    context.fill(CGRect(x: margin, y: margin, width: width - 2 * margin, height: height - 2 * margin))
    return context.makeImage()!
}

/// An 80 × 80 window shot: transparent, with an opaque black 40 × 40 square in the middle.
private let windowShot = TestBitmaps.transparent(80, 80, blocks: [CGRect(x: 20, y: 20, width: 40, height: 40)])

private func redaction(_ style: RedactStyle, _ rect: CGRect) -> AnnotationObject {
    AnnotationObject(kind: .redact(RedactObject(rect: rect, style: style, intensity: 5)),
                     style: ObjectStyle(color: .black, lineWidth: 4, shadow: false))
}

/// White, with a green block in the top-left corner (`block`, y down).
private func whiteWithGreenBlock(_ width: Int, _ height: Int, block: CGRect) -> CGImage {
    let context = TestBitmaps.context(width, height)
    context.setFillColor(TestBitmaps.white)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(TestBitmaps.green)
    context.fill(CGRect(x: block.minX, y: CGFloat(height) - block.maxY, width: block.width, height: block.height))
    return context.makeImage()!
}

/// The document as `render` draws it, but with `cache`: `Renderer.draw` into a bitmap of the output bounds.
private func drawn(_ document: AnnotationDocument, _ images: ImageStore, cache: RenderCache) throws -> CGImage {
    let output = Renderer.outputBounds(of: document, images: images, cache: cache).integral
    let context = TestBitmaps.flippedContext(Int(output.width), Int(output.height))
    context.translateBy(x: -output.minX, y: -output.minY)
    Renderer.draw(document, images: images, in: context, cache: cache)
    return try #require(context.makeImage())
}

/// A cache whose redaction effect is translucent green: whatever red shows under a redaction comes from the original.
private func translucentGreenEffect() -> RenderCache {
    let cache = RenderCache()
    cache.effect = { _, region, _, _, _ in
        TestBitmaps.solid(Int(region.width), Int(region.height), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.5))
    }
    return cache
}

/// The largest red value of any pixel.
private func largestRed(_ image: CGImage) -> Int {
    let bytes = TestBitmaps.bytes(image)
    return stride(from: 0, to: bytes.count, by: 4).map { Int(bytes[$0]) }.max() ?? 0
}

/// A Retina canvas's frame: `Renderer.draw` into a bitmap twice the size of `frame` whose base transform carries the 2, as a
/// window's backing does, with the frame's top-left at the context's origin.
private func retinaDraw(_ document: AnnotationDocument, _ images: ImageStore, frame: CGRect) throws -> CGImage {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width) * 2,
                                            pixelsHigh: Int(frame.height) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                            bitsPerPixel: 0))
    rep.size = NSSize(width: frame.width, height: frame.height)
    let graphics = try #require(NSGraphicsContext(bitmapImageRep: rep))
    let context = graphics.cgContext
    context.translateBy(x: 0, y: frame.height)
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: -frame.minX, y: -frame.minY)
    Renderer.draw(document, images: images, in: context, deviceScale: 2)
    return try #require(rep.cgImage)
}

struct BackgroundRenderTests {
    // MARK: The frame

    @Test func theRenderIsTheFrame() throws {
        let (document, images) = backgrounded(TestBitmaps.solid(100, 80, TestBitmaps.blue))
        let image = try render(document, images)
        #expect(image.width == 228)
        #expect(image.height == 208)
        #expect(Renderer.outputBounds(of: document, images: images, cache: nil) == CGRect(x: -64, y: -64, width: 228, height: 208))
        // The content sits in the middle, where the canvas is.
        #expect(TestBitmaps.pixel(image, 64 + 50, 64 + 40) == blue)
    }

    @Test func aCropCutsTheContentTheBackgroundFormsAround() throws {
        let base = TestBitmaps.quadrants(100, 80, topLeft: TestBitmaps.red, topRight: TestBitmaps.green,
                                         bottomLeft: TestBitmaps.blue, bottomRight: TestBitmaps.yellow)
        var (document, images) = backgrounded(base)
        document.canvasRect = CGRect(x: 10, y: 10, width: 50, height: 40)
        let image = try render(document, images)
        #expect(image.width == 178)
        #expect(image.height == 168)
        #expect(Renderer.outputBounds(of: document, images: images, cache: nil) == CGRect(x: -54, y: -54, width: 178, height: 168))
        // Inside the box's rounded corners: the canvas's (16, 16) is in the picture's top-left quarter, its (53, 43) in the
        // bottom-right one.
        #expect(TestBitmaps.pixel(image, 64 + 6, 64 + 6) == red)
        #expect(TestBitmaps.pixel(image, 64 + 43, 64 + 33) == TestBitmaps.RGBA(r: 255, g: 255, b: 0, a: 255))
    }

    // MARK: Fills

    @Test func aColorFillFillsThePadding() throws {
        let (document, images) = backgrounded(TestBitmaps.solid(100, 80, TestBitmaps.white), style { $0.fill = .color(redColor) })
        let image = try render(document, images)
        #expect(TestBitmaps.pixel(image, 2, 2) == red)
        #expect(TestBitmaps.pixel(image, 225, 2) == red)
    }

    @Test func noneLeavesThePaddingTransparent() throws {
        let (document, images) = backgrounded(TestBitmaps.solid(100, 80, TestBitmaps.white), style { $0.fill = .none })
        let image = try render(document, images)
        #expect(TestBitmaps.pixel(image, 2, 2).a == 0)
        // The shadow still falls below the box.
        #expect(TestBitmaps.pixel(image, 114, 144 + 12).a > 0)
        #expect(TestBitmaps.pixel(image, 114, 104) == white)
    }

    @Test func aLinearGradientRunsAtItsAngle() throws {
        func gradient(_ angle: Double) -> BackgroundStyle {
            style {
                $0.fill = .gradient(BackgroundGradient(kind: .linear(angle: angle), stops: [.init(color: redColor, location: 0),
                                                                                         .init(color: blueColor, location: 1)]))
                $0.shadow = 0
            }
        }
        // Each across the frame's short side (168 of 168 × 428), so a gradient as long as the other side would show.
        let (across, acrossImages) = backgrounded(TestBitmaps.solid(40, 300, TestBitmaps.white), gradient(0))
        let acrossImage = try render(across, acrossImages)
        #expect(isNear(TestBitmaps.pixel(acrossImage, 0, 214), red, within: 16))
        #expect(isNear(TestBitmaps.pixel(acrossImage, 167, 214), blue, within: 16))
        let (down, downImages) = backgrounded(TestBitmaps.solid(300, 40, TestBitmaps.white), gradient(90))
        let downImage = try render(down, downImages)
        #expect(isNear(TestBitmaps.pixel(downImage, 214, 0), red, within: 16))
        #expect(isNear(TestBitmaps.pixel(downImage, 214, 167), blue, within: 16))
    }

    @Test func aRadialGradientIsCentred() throws {
        let fill = BackgroundFill.gradient(BackgroundGradient(kind: .radial, stops: [.init(color: redColor, location: 0),
                                                                                    .init(color: blueColor, location: 1)]))
        // A transparent picture, so the frame's centre shows the fill.
        let (document, images) = backgrounded(TestBitmaps.transparent(100, 80), style { $0.fill = fill; $0.shadow = 0 })
        let image = try render(document, images)
        #expect(isNear(TestBitmaps.pixel(image, 114, 104), red, within: 16))
        for (x, y) in [(0, 0), (227, 0), (0, 207), (227, 207)] {
            #expect(isNear(TestBitmaps.pixel(image, x, y), blue, within: 16), "corner (\(x), \(y))")
        }
    }

    @Test func anImageFillIsAspectFilled() throws {
        // A 228 × 228 frame: the 200 × 100 picture is scaled 2.28× to cover it, and its middle 100 pixels show.
        let base = TestBitmaps.solid(100, 100, TestBitmaps.white)
        let customFill = style { $0.fill = .custom(id: UUID()); $0.shadow = 0 }
        let (document, images) = backgrounded(base, customFill,
                                              picture: TestBitmaps.split(200, 100, left: TestBitmaps.red, right: TestBitmaps.blue))
        let image = try render(document, images)
        #expect(TestBitmaps.pixel(image, 10, 114) == red)
        #expect(TestBitmaps.pixel(image, 217, 114) == blue)
        // The seam is in the middle, at the top too.
        #expect(TestBitmaps.pixel(image, 110, 2) == red)
        #expect(TestBitmaps.pixel(image, 118, 2) == blue)
        // Covered, not stretched: a seam at 80 of 200 lands 30 of the 100 shown pixels in, at 68.4, not at 91.2.
        let (offCentre, offImages) = backgrounded(base, customFill, picture: TestBitmaps.split(200, 100, left: TestBitmaps.red,
                                                                                               right: TestBitmaps.blue, at: 80))
        let offImage = try render(offCentre, offImages)
        #expect(TestBitmaps.pixel(offImage, 64, 2) == red)
        #expect(TestBitmaps.pixel(offImage, 73, 2) == blue)
    }

    @Test func aMissingBackgroundPictureDrawsNothing() throws {
        let (document, images) = backgrounded(TestBitmaps.solid(100, 80, TestBitmaps.white), style { $0.fill = .desktop })
        #expect(images[pictureRef] == nil)
        let image = try render(document, images)
        #expect(image.width == 228)
        #expect(TestBitmaps.pixel(image, 2, 2).a == 0)
        #expect(TestBitmaps.pixel(image, 114, 104) == white)
    }

    // MARK: The box

    @Test func cornersRoundTheBox() throws {
        let (document, images) = backgrounded(TestBitmaps.solid(100, 80, TestBitmaps.red),
                                              style { $0.fill = .color(blueColor); $0.shadow = 0 })
        let image = try render(document, images)
        // The box's corner pixel is outside the 12-pixel arc; its centre is the picture.
        #expect(TestBitmaps.pixel(image, 64, 64) == blue)
        #expect(TestBitmaps.pixel(image, 114, 104) == red)
        // Along an edge, away from the corners, the box is square.
        #expect(TestBitmaps.pixel(image, 64, 104) == red)
    }

    @Test func insetFillsTheRingWithTheInsetColor() throws {
        let inset = style { $0.fill = .color(whiteColor); $0.inset = 8; $0.insetColor = .color(greenColor); $0.shadow = 0 }
        let (document, images) = backgrounded(TestBitmaps.solid(100, 80, TestBitmaps.red), inset)
        let image = try render(document, images)
        // The box is the content grown by 8, the frame the box grown by 64: the content starts at 72.
        #expect(image.width == 244)
        #expect(TestBitmaps.pixel(image, 72 - 4, 72 + 40) == green)
        #expect(TestBitmaps.pixel(image, 72 + 50, 72 + 40) == red)
        #expect(TestBitmaps.pixel(image, 72 - 12, 72 + 40) == white)
        // Auto is the picture's edge colour.
        var auto = inset
        auto.insetColor = .auto
        let (bordered, borderedImages) = backgrounded(TestBitmaps.bordered(100, border: 4, edge: TestBitmaps.blue,
                                                                           inside: TestBitmaps.red), auto)
        let borderedImage = try render(bordered, borderedImages)
        #expect(isNear(TestBitmaps.pixel(borderedImage, 72 - 4, 72 + 50), blue, within: 1))
    }

    @Test func theShadowFallsBelowTheBox() throws {
        let (document, images) = backgrounded(TestBitmaps.solid(100, 80, TestBitmaps.red),
                                              style { $0.fill = .color(whiteColor); $0.shadow = 50 })
        let image = try render(document, images)
        let below = TestBitmaps.pixel(image, 114, 144 + 4)
        let above = TestBitmaps.pixel(image, 114, 64 - 4)
        #expect(below.g < above.g)
        #expect(below.g < 200)
    }

    @Test func aTransparentWindowShotCastsItsOwnShape() throws {
        let (document, images) = backgrounded(windowShot, style { $0.fill = .color(whiteColor); $0.shadow = 100; $0.inset = 0 })
        let image = try render(document, images)
        // The window's transparent top corners show the fill: no box behind the window, and no box-shaped shadow.
        let corners = [TestBitmaps.pixel(image, 64 + 2, 64 + 2), TestBitmaps.pixel(image, 64 + 77, 64 + 2)]
        for corner in corners {
            #expect(isNear(corner, white, within: 6), "a top corner is \(corner)")
        }
        // Below the square, inside the picture, its own shadow falls.
        let below = TestBitmaps.pixel(image, 64 + 40, 64 + 60 + 3)
        #expect(Int(below.g) + 30 < Int(corners[0].g), "below the square is \(below)")
    }

    @Test func insetGivesATransparentWindowAFilledBox() throws {
        let inset = style { $0.fill = .color(whiteColor); $0.shadow = 100; $0.inset = 8; $0.insetColor = .color(redColor) }
        let (document, images) = backgrounded(windowShot, inset)
        let image = try render(document, images)
        // The content starts at 72: its transparent corner and the ring around it are the inset colour.
        #expect(TestBitmaps.pixel(image, 72 + 2, 72 + 2) == red)
        #expect(TestBitmaps.pixel(image, 72 - 4, 72 + 40) == red)
    }

    // MARK: Redactions

    @Test func aRedactionOverATransparentCornerShowsTheBackdropNotAHole() throws {
        let redaction = AnnotationObject(kind: .redact(RedactObject(rect: CGRect(x: 0, y: 0, width: 80, height: 80), style: .pixelate,
                                                                    intensity: 5)),
                                         style: ObjectStyle(color: .black, lineWidth: 4, shadow: false))
        let (document, images) = backgrounded(windowShot, style { $0.fill = .color(redColor) }, objects: [redaction])
        let image = try render(document, images)
        let bytes = TestBitmaps.bytes(image)
        let holes = stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] < 255 }.count
        #expect(holes == 0)
    }

    @Test func aRedactionWithABackgroundStillHidesTheOriginal() throws {
        // As `redactionReplacesPartlyTransparentPixels`: one opaque black 2 × 2 block, pixelated to almost nothing.
        let base = TestBitmaps.transparent(64, 64, blocks: [CGRect(x: 30, y: 32, width: 2, height: 2)])
        let redaction = AnnotationObject(kind: .redact(RedactObject(rect: CGRect(x: 0, y: 0, width: 64, height: 64), style: .pixelate,
                                                                    intensity: 5)),
                                         style: ObjectStyle(color: .black, lineWidth: 4, shadow: false))
        let (document, images) = backgrounded(base, style { $0.fill = .color(redColor) }, objects: [redaction])
        let pixel = TestBitmaps.pixel(try render(document, images), 64 + 30, 64 + 32)
        #expect(pixel != TestBitmaps.RGBA(r: 0, g: 0, b: 0, a: 255))
        // The backdrop under the nearly transparent block.
        #expect(pixel.r > 200)
        #expect(pixel.a == 255)
        // With no fill the backdrop is transparent, and the original still doesn't show through.
        let (unfilled, _) = backgrounded(base, style { $0.fill = .none }, objects: [redaction])
        let unfilledPixel = TestBitmaps.pixel(try render(unfilled, images), 64 + 30, 64 + 32)
        #expect(unfilledPixel != TestBitmaps.RGBA(r: 0, g: 0, b: 0, a: 255))
        #expect(unfilledPixel.a < 64)
    }

    @Test func aRedactionIsClippedToTheBox() throws {
        let redaction = AnnotationObject(kind: .redact(RedactObject(rect: CGRect(x: 0, y: 0, width: 100, height: 80), style: .pixelate,
                                                                    intensity: 5)),
                                         style: ObjectStyle(color: .black, lineWidth: 4, shadow: false))
        let (document, images) = backgrounded(TestBitmaps.noise(100, 80), style { $0.fill = .color(blueColor); $0.corners = 32; $0.shadow = 0 },
                                              objects: [redaction])
        let image = try render(document, images)
        #expect(TestBitmaps.pixel(image, 64, 64) == blue)
        #expect(TestBitmaps.pixel(image, 64 + 99, 64 + 79) == blue)
        // Along the box's edge, away from the corners, the redaction reaches the edge.
        #expect(TestBitmaps.pixel(image, 64, 104) != blue)
    }

    @Test func aRedactionAfterACropStaysInTheContent() throws {
        // The canvas is cut out of the picture, so base pixels lie under the inset ring too. The redaction over the whole
        // picture covers the content only: the ring keeps its colour rather than showing the cropped-away pixels.
        let redaction = AnnotationObject(kind: .redact(RedactObject(rect: CGRect(x: 0, y: 0, width: 100, height: 80), style: .pixelate,
                                                                    intensity: 5)),
                                         style: ObjectStyle(color: .black, lineWidth: 4, shadow: false))
        var (document, images) = backgrounded(TestBitmaps.noise(100, 80),
                                              style { $0.inset = 8; $0.insetColor = .color(redColor); $0.shadow = 0 },
                                              objects: [redaction])
        document.canvasRect = CGRect(x: 10, y: 10, width: 50, height: 40)
        let image = try render(document, images)
        // The content starts at 64 + 8: the ring's left side, at its middle, is red; the content is redacted.
        #expect(TestBitmaps.pixel(image, 72 - 4, 72 + 20) == red)
        #expect(TestBitmaps.pixel(image, 72 + 25, 72 - 4) == red)
        #expect(TestBitmaps.pixel(image, 72 + 25, 72 + 20) != red)
    }

    @Test func aRedactionOverTheInsetShowsTheInsetColorUnderIt() throws {
        // Pixelate over the whole window: its corner block is all transparent, and it goes over the inset colour.
        let inset = style { $0.fill = .color(whiteColor); $0.shadow = 0; $0.inset = 8; $0.insetColor = .color(redColor) }
        let (document, images) = backgrounded(windowShot, inset,
                                              objects: [redaction(.pixelate, CGRect(x: 0, y: 0, width: 80, height: 80))])
        let image = try render(document, images)
        #expect(TestBitmaps.pixel(image, 72 + 2, 72 + 2) == red)
    }

    @Test(arguments: [RedactStyle.blackOut, .pixelate], [0.0, 8.0])
    func aRedactionLeavesNoOriginalColorAtARoundedCorner(style redactStyle: RedactStyle, inset: Double) throws {
        // A red picture redacted all over, in a frame with nothing else red: a blue fill, a green inset, and pixelate's
        // effect made translucent green. Any red in the output, at the rounded corners included, is the original's.
        let corners = style { $0.fill = .color(blueColor); $0.corners = 32; $0.inset = inset; $0.insetColor = .color(greenColor) }
        let (document, images) = backgrounded(TestBitmaps.solid(100, 80, TestBitmaps.red), corners,
                                              objects: [redaction(redactStyle, CGRect(x: 0, y: 0, width: 100, height: 80))])
        let drawnRed = largestRed(try drawn(document, images, cache: translucentGreenEffect()))
        #expect(drawnRed <= 1)
        if redactStyle == .blackOut {
            let renderedRed = largestRed(try render(document, images))
            #expect(renderedRed <= 1)
        }
    }

    @Test(arguments: [RedactStyle.blackOut, .pixelate])
    func aRedactionLeavesNoOriginalColorAtAFractionalCanvasEdge(style redactStyle: RedactStyle) throws {
        // A crop, then a resize: the canvas's edges land between output pixels.
        var (document, images) = backgrounded(TestBitmaps.solid(101, 81, TestBitmaps.red),
                                              style { $0.fill = .color(blueColor); $0.corners = 0 },
                                              objects: [redaction(redactStyle, CGRect(x: 0, y: 0, width: 101, height: 81))])
        document.canvasRect = CGRect(x: 10, y: 10, width: 61, height: 41)
        document = document.applying(.resize(width: 67, height: 55))
        let canvas = document.canvasBounds
        #expect(canvas.minX != canvas.minX.rounded() && canvas.maxY != canvas.maxY.rounded())
        let red = largestRed(try drawn(document, images, cache: translucentGreenEffect()))
        #expect(red <= 1)
    }

    @Test func theBoxShadowIsCastFromTheRedactedAlpha() throws {
        // A transparent window with a black-out band over its transparent top: the band is opaque, so it casts a shadow.
        let window = TestBitmaps.transparent(200, 200, blocks: [CGRect(x: 80, y: 80, width: 40, height: 40)])
        let shadowed = style { $0.fill = .color(whiteColor); $0.shadow = 100; $0.inset = 0 }
        let (banded, images) = backgrounded(window, shadowed, objects: [redaction(.blackOut, CGRect(x: 0, y: 0, width: 200, height: 60))])
        let (plain, _) = backgrounded(window, shadowed)
        let belowBand = TestBitmaps.pixel(try render(banded, images), 64 + 30, 64 + 70)
        let withoutBand = TestBitmaps.pixel(try render(plain, images), 64 + 30, 64 + 70)
        #expect(Int(belowBand.g) + 30 < Int(withoutBand.g), "\(belowBand) below the band, \(withoutBand) without it")
    }

    // MARK: Objects

    @Test func objectsCastOnlyTheirOwnShadows() throws {
        // An unshadowed rect in the top-left padding, under a strong box shadow: below it, the frame is as it is without it.
        let rect = AnnotationObject(kind: .filledRectangle(CGRect(x: -60, y: -60, width: 30, height: 20)),
                                    style: ObjectStyle(color: redColor, lineWidth: 4, shadow: false))
        let strong = style { $0.fill = .color(whiteColor); $0.shadow = 100 }
        let base = TestBitmaps.solid(100, 80, TestBitmaps.blue)
        let (withRect, images) = backgrounded(base, strong, objects: [rect])
        let (without, _) = backgrounded(base, strong)
        let drawn = try render(withRect, images)
        #expect(TestBitmaps.pixel(drawn, 19, 14) == red)
        #expect(TestBitmaps.pixel(drawn, 19, 30) == TestBitmaps.pixel(try render(without, images), 19, 30))
    }

    @Test func objectsDrawInThePaddingAndAreClippedToTheFrame() throws {
        // From 100 pixels left of the picture, past the frame's edge at −64, to 20 pixels left of it.
        let rect = AnnotationObject(kind: .filledRectangle(CGRect(x: -100, y: 20, width: 80, height: 40)),
                                    style: ObjectStyle(color: redColor, lineWidth: 4, shadow: false))
        let (document, images) = backgrounded(TestBitmaps.solid(100, 80, TestBitmaps.white),
                                              style { $0.fill = .color(blueColor); $0.shadow = 0 }, objects: [rect])
        let image = try render(document, images)
        #expect(image.width == 228)
        #expect(image.height == 208)
        #expect(TestBitmaps.pixel(image, 10, 64 + 40) == red)
        #expect(TestBitmaps.pixel(image, 50, 64 + 40) == blue)
        // In a bigger context, nothing is drawn left of the frame.
        let context = TestBitmaps.flippedContext(300, 280)
        context.translateBy(x: 36 + 64, y: 36 + 64)
        Renderer.draw(document, images: images, in: context)
        let drawn = try #require(context.makeImage())
        #expect(TestBitmaps.pixel(drawn, 20, 36 + 104).a == 0)
        #expect(TestBitmaps.pixel(drawn, 40, 36 + 104) == red)
    }

    @Test func spotlightsDimTheWholeFrame() throws {
        let light = AnnotationObject(kind: .spotlight(SpotlightObject(rect: CGRect(x: 30, y: 20, width: 40, height: 40),
                                                                      shape: .rectangle, opacity: 0.5)),
                                     style: ObjectStyle(color: .black, lineWidth: 4, shadow: false))
        let plain = style { $0.fill = .color(whiteColor); $0.shadow = 0 }
        let base = TestBitmaps.solid(100, 80, TestBitmaps.white)
        let (lit, images) = backgrounded(base, plain, objects: [light])
        let (unlit, _) = backgrounded(base, plain)
        let dimmed = try render(lit, images)
        #expect(TestBitmaps.pixel(try render(unlit, images), 2, 2) == white)
        for (x, y) in [(2, 2), (225, 205), (114, 30)] {
            let pixel = TestBitmaps.pixel(dimmed, x, y)
            #expect(pixel.r > 110 && pixel.r < 145, "padding (\(x), \(y)) is \(pixel)")
        }
        #expect(TestBitmaps.pixel(dimmed, 64 + 50, 64 + 40) == white)
    }

    // MARK: Blurred screenshot

    @Test func blurredScreenshotIsTheBlurredContent() throws {
        let base = TestBitmaps.split(100, 80, left: TestBitmaps.red, right: TestBitmaps.blue)
        let (document, images) = backgrounded(base, style { $0.fill = .blurredScreenshot; $0.shadow = 0 })
        let image = try render(document, images)
        // The 100 × 80 blur covers the 228 × 208 frame at 2.6×, from x = −16.
        let left = TestBitmaps.pixel(image, 10, 104)
        let right = TestBitmaps.pixel(image, 217, 104)
        #expect(left.r > 200 && left.b < 55)
        #expect(right.b > 200 && right.r < 55)
        // Five content pixels left of the seam (x = 101 in the frame), red and blue mix: it is blurred.
        let nearSeam = TestBitmaps.pixel(image, 101, 10)
        #expect(nearSeam.b > 30 && nearSeam.r > 100)
    }

    @Test func theBlurIsAtMost512Pixels() throws {
        let large = try #require(BackgroundBlur.blurred(TestBitmaps.noise(1024, 600)))
        #expect(large.width == 512)
        #expect(large.height == 300)
        #expect(large.colorSpace?.name == CGColorSpace.sRGB)
        // A small picture is never scaled up.
        let small = try #require(BackgroundBlur.blurred(TestBitmaps.noise(100, 60)))
        #expect(small.width == 100)
        #expect(small.height == 60)
    }

    @Test func aBlackOutLeavesNoTraceInTheBlurredScreenshot() throws {
        // A green block in the picture's corner, blacked out: the blur in the padding is made from what the box shows.
        let base = whiteWithGreenBlock(100, 80, block: CGRect(x: 0, y: 0, width: 30, height: 30))
        let (document, images) = backgrounded(base, style { $0.fill = .blurredScreenshot; $0.shadow = 0 },
                                              objects: [redaction(.blackOut, CGRect(x: 0, y: 0, width: 30, height: 30))])
        let bytes = TestBitmaps.bytes(try render(document, images))
        /// How much greener than its red and blue a pixel is.
        func greenTint(_ offset: Int) -> Int {
            let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
            return green - max(red, blue)
        }
        let greenest = stride(from: 0, to: bytes.count, by: 4).map(greenTint).max() ?? 0
        #expect(greenest <= 2)
    }

    @Test func addingMovingOrRestylingARedactionRefreshesTheBlur() throws {
        let base = whiteWithGreenBlock(100, 80, block: CGRect(x: 0, y: 0, width: 30, height: 30))
        var (document, images) = backgrounded(base, style { $0.fill = .blurredScreenshot })
        let cache = RenderCache()
        func blur() throws -> CGImage? {
            _ = try drawn(document, images, cache: cache)
            return cache.contentAnalysis?.blur?.image
        }
        let unredacted = try blur()
        #expect(unredacted != nil)
        document.objects = [redaction(.blackOut, CGRect(x: 0, y: 0, width: 30, height: 30))]
        let added = try #require(try blur())
        #expect(added !== unredacted)
        // The blacked-out corner is dark in the new blur, not green.
        let corner = TestBitmaps.pixel(added, 2, 2)
        #expect(Int(corner.g) <= Int(corner.r) + 2)
        document.objects[0].kind = .redact(RedactObject(rect: CGRect(x: 5, y: 5, width: 30, height: 30), style: .blackOut, intensity: 5))
        let moved = try blur()
        #expect(moved !== added)
        document.objects[0].kind = .redact(RedactObject(rect: CGRect(x: 5, y: 5, width: 30, height: 30), style: .pixelate, intensity: 5))
        let restyled = try blur()
        #expect(restyled !== moved)
        // Unchanged, it is reused; at another pixel scale (bigger pixelate blocks), it is made again.
        #expect(try blur() === restyled)
        document.pixelScale = 2
        #expect(try blur() !== restyled)
    }

    // MARK: Auto-balance

    @Test func autoBalanceRemovesUniformMargins() throws {
        let base = margined(200, 160, margin: 40, edge: TestBitmaps.white, inside: TestBitmaps.black)
        let (document, images) = backgrounded(base, style { $0.autoBalance = true })
        let image = try render(document, images)
        #expect(image.width == 120 + 128)
        #expect(image.height == 80 + 128)
        #expect(Renderer.outputBounds(of: document, images: images, cache: nil) == CGRect(x: -24, y: -24, width: 248, height: 208))
        // The block starts right at the box, with the fill just outside it, not the white margin.
        #expect(TestBitmaps.pixel(image, 64, 104) == TestBitmaps.RGBA(r: 0, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(image, 62, 104) != white)
    }

    @Test func trimsAreCachedPerContent() {
        let base = margined(200, 160, margin: 40, edge: TestBitmaps.white, inside: TestBitmaps.black)
        let (document, images) = backgrounded(base, style { $0.autoBalance = true })
        let cache = RenderCache()
        let trims = Renderer.balanceTrims(for: document, images: images, cache: cache)
        #expect(trims == EdgeTrims(top: 40, left: 40, bottom: 40, right: 40))
        #expect(cache.contentAnalysis?.trims == trims)
        // The second call reads the cache: a marked entry comes back as it is.
        let marked = EdgeTrims(top: 1, left: 2, bottom: 3, right: 4)
        cache.contentAnalysis?.trims = marked
        #expect(Renderer.balanceTrims(for: document, images: images, cache: cache) == marked)
        // Another canvas is other content: measured again. This one cuts the right margin to 20 pixels.
        var cropped = document
        cropped.canvasRect = CGRect(x: 0, y: 0, width: 180, height: 160)
        #expect(Renderer.balanceTrims(for: cropped, images: images, cache: cache) == EdgeTrims(top: 40, left: 40, bottom: 40, right: 20))
    }

    @Test func nothingIsMeasuredWithoutAutoBalance() {
        let base = margined(200, 160, margin: 40, edge: TestBitmaps.white, inside: TestBitmaps.black)
        let (document, images) = backgrounded(base)
        let cache = RenderCache()
        #expect(Renderer.balanceTrims(for: document, images: images, cache: cache) == .zero)
        #expect(Renderer.outputBounds(of: document, images: images, cache: cache) == CGRect(x: -64, y: -64, width: 328, height: 288))
        #expect(cache.contentAnalysis == nil)
    }

    @Test func theTrimsIgnoreRedactions() throws {
        // A pixelate over the top margin: measured, its noise would make the margin uneven and leave it untrimmed.
        let base = margined(200, 160, margin: 40, edge: TestBitmaps.white, inside: TestBitmaps.black)
        let (plain, images) = backgrounded(base, style { $0.autoBalance = true; $0.fill = .blurredScreenshot })
        var redacted = plain
        redacted.objects = [redaction(.pixelate, CGRect(x: 0, y: 0, width: 200, height: 60))]
        let trims = EdgeTrims(top: 40, left: 40, bottom: 40, right: 40)
        #expect(Renderer.balanceTrims(for: redacted, images: images, cache: nil) == trims)
        // With a cache, adding the redaction keeps the measured trims (a marked entry stays) and makes the blur again.
        let cache = RenderCache()
        _ = try drawn(plain, images, cache: cache)
        let blurred = cache.contentAnalysis?.blur?.image
        let marked = EdgeTrims(top: 1, left: 2, bottom: 3, right: 4)
        cache.contentAnalysis?.trims = marked
        _ = try drawn(redacted, images, cache: cache)
        #expect(cache.contentAnalysis?.trims == marked)
        #expect(cache.contentAnalysis?.blur?.image != nil)
        #expect(cache.contentAnalysis?.blur?.image !== blurred)
    }

    @Test func oneContentAnalysisServesTheTrimsAndTheBlur() {
        let base = margined(200, 160, margin: 40, edge: TestBitmaps.white, inside: TestBitmaps.black)
        let (document, images) = backgrounded(base, style { $0.autoBalance = true; $0.fill = .blurredScreenshot })
        let cache = RenderCache()
        Renderer.draw(document, images: images, in: TestBitmaps.flippedContext(248, 208), cache: cache)
        #expect(cache.contentAnalysis?.trims == EdgeTrims(top: 40, left: 40, bottom: 40, right: 40))
        let blurred = cache.contentAnalysis?.blur?.image
        #expect(blurred != nil)
        // The next frame draws from the cache.
        Renderer.draw(document, images: images, in: TestBitmaps.flippedContext(248, 208), cache: cache)
        #expect(cache.contentAnalysis?.blur?.image === blurred)
    }

    // MARK: Scale

    /// The same picture at 1× (100 × 80) and at 2× (200 × 160): four coloured quarters.
    private func quarters(_ scale: Int) -> CGImage {
        TestBitmaps.quadrants(100 * scale, 80 * scale, topLeft: TestBitmaps.red, topRight: TestBitmaps.green,
                              bottomLeft: TestBitmaps.blue, bottomRight: TestBitmaps.yellow)
    }

    /// The frame's corner, the padding's midpoints, the box's corner and its centre, in a 1× standard frame.
    private let samples = [(0, 0), (114, 30), (114, 178), (30, 104), (197, 104), (64, 64), (163, 143), (114, 104)]

    @Test func aOneXAndATwoXCaptureLookTheSame() throws {
        let (oneX, oneXImages) = backgrounded(quarters(1))
        let (twoX, twoXImages) = backgrounded(quarters(2), pixelScale: 2)
        let one = try render(oneX, oneXImages)
        let two = try render(twoX, twoXImages)
        #expect(one.width == 228)
        #expect(two.width == 2 * one.width)
        #expect(two.height == 2 * one.height)
        for (x, y) in samples {
            let a = TestBitmaps.pixel(one, x, y), b = TestBitmaps.pixel(two, 2 * x + 1, 2 * y + 1)
            #expect(isNear(a, b, within: 3), "(\(x), \(y)): \(a) at 1×, \(b) at 2×")
        }
    }

    @Test func aRetinaCanvasDrawsTheBackgroundAsTheRenderDoes() throws {
        // The canvas at 2× in a window: the shadow and the corners are sized in points, as in the export.
        let (document, images) = backgrounded(quarters(1))
        let rendered = try render(document, images)
        let drawn = try retinaDraw(document, images, frame: CGRect(x: -64, y: -64, width: 228, height: 208))
        #expect(drawn.width == 456)
        for (x, y) in samples {
            let a = TestBitmaps.pixel(rendered, x, y), b = TestBitmaps.pixel(drawn, 2 * x + 1, 2 * y + 1)
            #expect(isNear(a, b, within: 3), "(\(x), \(y)): \(a) rendered, \(b) drawn at 2×")
        }
    }

    @Test func scaleTo1xOnABackgroundedDocumentHalvesTheRender() throws {
        let (document, images) = backgrounded(quarters(2), pixelScale: 2)
        let original = try render(document, images)
        let frame = Renderer.outputBounds(of: document, images: images, cache: nil)
        let scaled = document.applying(document.imageOp(for: .scaleTo1x, itemScale: 2, outputSize: frame.size))
        let half = try render(scaled, images)
        #expect(abs(2 * half.width - original.width) <= 2)
        #expect(abs(2 * half.height - original.height) <= 2)
    }

    // MARK: Window shots

    @Test(arguments: [1.0, 2.0])
    func aWindowShotRendersLikeTodaysComposite(pixelScale: Double) throws {
        // A 60 × 40 window: an opaque body inside a ring of 30% black, its shadow.
        let context = TestBitmaps.context(60, 40)
        context.setFillColor(CGColor(gray: 0, alpha: 0.3))
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        context.clear(CGRect(x: 6, y: 6, width: 48, height: 28))
        context.setFillColor(TestBitmaps.white)
        context.fill(CGRect(x: 8, y: 8, width: 44, height: 24))
        let window = try #require(context.makeImage())
        let wallpaper = TestBitmaps.noise(100, 80)
        var windowStyle = BackgroundStyle.windowStandard
        windowStyle.fill = .windowWallpaper
        windowStyle.padding = 10
        let (document, images) = backgrounded(window, windowStyle, pixelScale: pixelScale, picture: wallpaper)
        let rendered = try render(document, images)
        let composite = PostProcessor.compositingWindow(window, background: wallpaper, padding: Int(10 * pixelScale))
        #expect(rendered.width == composite.width)
        #expect(rendered.height == composite.height)
        let difference = zip(TestBitmaps.bytes(rendered), TestBitmaps.bytes(composite)).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(difference <= 1)
    }
}
