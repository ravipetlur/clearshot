import CoreGraphics
import CSCore
import Foundation
import Testing
@testable import CSAnnotation

private let red = RGBAColor(red: 1, green: 0, blue: 0)

private func styled(_ kind: ObjectKind, width: Double = 10) -> AnnotationObject {
    AnnotationObject(kind: kind, style: ObjectStyle(color: red, lineWidth: width, shadow: true))
}

/// A small deterministic stream of numbers, so a test over many shapes is the same on every run.
private struct Dice {
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Double(state >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

struct ObjectScalingTests {
    @Test func everyLengthScales() {
        let highlight = styled(.highlight(HighlightObject(points: [CGPoint(x: 10, y: 20)], rects: [CGRect(x: 2, y: 4, width: 6, height: 8)],
                                                          width: 16, opacity: 0.4)))
        let scaled = ObjectScaling.scaled(highlight, by: 0.5)
        #expect(scaled.kind == .highlight(HighlightObject(points: [CGPoint(x: 5, y: 10)], rects: [CGRect(x: 1, y: 2, width: 3, height: 4)],
                                                          width: 8, opacity: 0.4)))
        #expect(scaled.style.lineWidth == 5)
        #expect(scaled.id == highlight.id)
        let picture = styled(.image(ImageObject(rect: CGRect(x: 10, y: 10, width: 40, height: 20), image: ImageRef(name: "images/a.png"))))
        #expect(ObjectScaling.scaled(picture, by: 2).kind == .image(ImageObject(rect: CGRect(x: 20, y: 20, width: 80, height: 40),
                                                                                 image: ImageRef(name: "images/a.png"))))
    }
}

@MainActor
struct PasteTests {
    @Test func aRetinaObjectPastedIntoA1xDocumentKeepsItsSize() throws {
        let h = EditorHarness(baseSize: CGSize(width: 200, height: 150), pixelScale: 1)
        let arrow = styled(.arrow(ArrowShape(start: CGPoint(x: 40, y: 40), end: CGPoint(x: 120, y: 40), style: .standard)))
        let text = styled(.text(TextObject(origin: CGPoint(x: 20, y: 20), width: 200, string: "Hi", style: .standard, fontSize: 48)),
                          width: 2)
        let counter = styled(.counter(CounterObject(center: CGPoint(x: 60, y: 60), value: 1, style: .numbers, diameter: 64)), width: 2)
        // Copied from a 2× document: two base pixels per point there, one here.
        h.act { h.editor.paste([arrow, text, counter], sourceScale: 2) }
        let pasted = h.editor.document.objects
        try #require(pasted.count == 3)
        guard case .arrow(let shape) = pasted[0].kind, case .text(let label) = pasted[1].kind,
              case .counter(let number) = pasted[2].kind else {
            Issue.record("the pasted objects changed kind")
            return
        }
        // Half the size, then the paste offset of 10 points.
        #expect(shape.start == CGPoint(x: 30, y: 30))
        #expect(shape.end == CGPoint(x: 70, y: 30))
        #expect(pasted[0].style.lineWidth == 5)
        #expect(label.origin == CGPoint(x: 20, y: 20))
        #expect(label.fontSize == 24)
        #expect(label.width == 100)
        #expect(number.center == CGPoint(x: 40, y: 40))
        #expect(number.diameter == 32)
    }

    @Test func aPasteAtTheSameScaleKeepsTheSize() throws {
        let h = EditorHarness()
        h.act { h.editor.paste([editorRectangle()], sourceScale: 1) }
        let pasted = try #require(h.editor.document.objects.first)
        #expect(ObjectGeometry.rect(of: pasted.kind) == CGRect(x: 20, y: 20, width: 20, height: 20))
        #expect(pasted.style.lineWidth == 4)
    }

    @Test func pastedObjectsAreMovedIntoTheCanvas() throws {
        let h = EditorHarness() // 100×80 at 1×
        // The paste offset would put it at (100, 80), past the bottom-right corner.
        h.act { h.editor.paste([editorRectangle(CGRect(x: 90, y: 70, width: 20, height: 20))]) }
        let pasted = try #require(h.editor.document.objects.first)
        #expect(ObjectGeometry.rect(of: pasted.kind) == CGRect(x: 80, y: 60, width: 20, height: 20))
        #expect(h.editor.document.canvasRect == nil)
    }

    @Test func aClampedPasteWithUnevenCoordinatesDoesNotGrowTheCanvas() {
        // Coordinates that aren't sums of powers of two: the move into the canvas then rounds, and the object could be left
        // a hair past the edge, which auto-expand counted as outside and grew the canvas by 17 pixels.
        let big = EditorHarness(baseSize: CGSize(width: 1440, height: 900))
        big.act { big.editor.paste([editorRectangle(CGRect(x: 1295.8427973997225, y: 876.4329116057118, width: 184.127966532534,
                                                           height: 143.7439670459015))], sourceScale: 1) }
        #expect(big.editor.document.canvasRect == nil)
        let second = EditorHarness(baseSize: CGSize(width: 1440, height: 900))
        second.act { second.editor.paste([editorRectangle(CGRect(x: 1283.4556462257456, y: 871.6324523257713, width: 52.049858700914456,
                                                                  height: 148.0075313860317))]) }
        #expect(second.editor.document.canvasRect == nil)
        var grew = 0
        var random = Dice()
        let setups: [(scale: Double, ops: [ImageOp], source: Double?)] = [(1, [], 1), (2, [], 1), (1, [.rotateRight], 1),
                                                                         (1, [.flipHorizontal, .rotateLeft], 2)]
        for setup in setups {
            for _ in 0..<150 {
                let h = EditorHarness(baseSize: CGSize(width: 300, height: 200), pixelScale: setup.scale, ops: setup.ops)
                let rect = CGRect(x: random.next(in: -60...330), y: random.next(in: -60...230), width: random.next(in: 10...140),
                                  height: random.next(in: 10...90))
                h.act { h.editor.paste([editorRectangle(rect)], sourceScale: setup.source) }
                if h.editor.document.canvasRect != nil { grew += 1 }
            }
        }
        #expect(grew == 0)
    }

    @Test func pastedPicturesBringTheirBitmapsUnderNewNames() throws {
        let h = EditorHarness()
        let elsewhere = ImageRef(name: "images/elsewhere.png")
        let picture = styled(.image(ImageObject(rect: CGRect(x: 0, y: 0, width: 10, height: 10), image: elsewhere)))
        h.act { h.editor.paste([picture], sourceScale: 1, images: [elsewhere: TestBitmaps.solid(10, 10, TestBitmaps.red)]) }
        let pasted = try #require(h.editor.document.objects.first)
        guard case .image(let object) = pasted.kind else {
            Issue.record("not an image object")
            return
        }
        #expect(object.image != elsewhere)
        #expect(object.image.name.hasPrefix("images/"))
        #expect(h.editor.images[object.image]?.width == 10)
    }

    @Test func aHugePastedBitmapIsStoredAt16383PixelsAtMost() throws {
        // The pasteboard is any app's to write: a bitmap past the output limit is held to it, as an inserted picture is.
        let h = EditorHarness()
        let elsewhere = ImageRef(name: "images/elsewhere.png")
        let picture = styled(.image(ImageObject(rect: CGRect(x: 0, y: 0, width: 80, height: 2), image: elsewhere)))
        h.act { h.editor.paste([picture], sourceScale: 1, images: [elsewhere: TestBitmaps.solid(20_000, 10, TestBitmaps.red)]) }
        let pasted = try #require(h.editor.document.objects.first)
        guard case .image(let object) = pasted.kind else {
            Issue.record("not an image object")
            return
        }
        let stored = try #require(h.editor.images[object.image])
        #expect(stored.width == 16_383)
        #expect(stored.height == 8)
        // The object's rect, not its bitmap, sets its size.
        #expect(object.rect.size == CGSize(width: 80, height: 2))
    }

    @Test func anObjectFromAOneTimesDocumentPastedIntoATwoTimesOneArrivesAtDoubleThePixels() throws {
        let h = EditorHarness(baseSize: CGSize(width: 200, height: 150), pixelScale: 2)
        h.act { h.editor.paste([editorRectangle()], sourceScale: 1) }
        let pasted = try #require(h.editor.document.objects.first)
        // 20 pixels become 40, the origin 10 becomes 20, and the 10-point offset is 20 pixels here.
        #expect(ObjectGeometry.rect(of: pasted.kind) == CGRect(x: 40, y: 40, width: 40, height: 40))
        #expect(pasted.style.lineWidth == 8)
    }

    @Test func aTargetWithAResizeOpTakesTheScaleOfItsPixelsPerPoint() throws {
        // Resized to half, a point is two base pixels: the 1× object's 20 pixels are 40 in the base, its origin 10 is 20, and
        // the offset of 10 points is 20 base pixels.
        let h = EditorHarness(baseSize: CGSize(width: 100, height: 80), ops: [.resize(width: 50, height: 40)])
        h.act { h.editor.paste([editorRectangle()], sourceScale: 1) }
        let pasted = try #require(h.editor.document.objects.first)
        #expect(ObjectGeometry.rect(of: pasted.kind) == CGRect(x: 40, y: 40, width: 40, height: 40))
        #expect(pasted.style.lineWidth == 8)
        // What the person sees is the same size and the same 10 points down and right: 20 by 20 at (20, 20) of the output.
        #expect(h.editor.document.outputBounds(of: pasted) == CGRect(x: 20, y: 20, width: 20, height: 20))
    }

    @Test func aFlippedTargetKeepsBaseCoordinatesAndOnlyTheOffsetFollowsTheScreen() throws {
        // Objects live in base pixels. Pasted into a document flipped left to right, a rectangle keeps its base size and its
        // base place, moved 10 points down and, on the screen's right, which is the base's left.
        let h = EditorHarness(ops: [.flipHorizontal])
        h.act { h.editor.paste([editorRectangle()], sourceScale: 1) }
        let pasted = try #require(h.editor.document.objects.first)
        #expect(ObjectGeometry.rect(of: pasted.kind) == CGRect(x: 0, y: 20, width: 20, height: 20))
        #expect(h.editor.document.outputBounds(of: pasted) == CGRect(x: 80, y: 20, width: 20, height: 20))
    }

    @Test func pastingIntoTheSameDocumentDoesNotScale() throws {
        // A resize makes the pixels per point uneven (1 ÷ 0.7); a paste in the same document divides it by itself.
        let h = EditorHarness(ops: [.resize(width: 70, height: 56)])
        let source = h.editor.document.pixels(fromPoints: 1)
        let arrow = styled(.arrow(ArrowShape(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 40, y: 20), style: .standard)), width: 3)
        h.act { h.editor.paste([arrow], sourceScale: source) }
        let pasted = try #require(h.editor.document.objects.first)
        guard case .arrow(let shape) = pasted.kind else {
            Issue.record("not an arrow")
            return
        }
        let offset = h.editor.baseVector(fromPoints: CGVector(dx: 10, dy: 10))
        #expect(shape.start == CGPoint(x: 10 + offset.dx, y: 10 + offset.dy))
        #expect(shape.end == CGPoint(x: 40 + offset.dx, y: 20 + offset.dy))
        #expect(pasted.style.lineWidth == 3)
    }

    @Test func pastingOnePictureTwiceMakesTwoObjectsWithTheirOwnBitmaps() throws {
        let h = EditorHarness()
        let elsewhere = ImageRef(name: "images/elsewhere.png")
        let bitmaps = [elsewhere: TestBitmaps.solid(10, 10, TestBitmaps.red)]
        func picture(at origin: CGPoint) -> AnnotationObject {
            styled(.image(ImageObject(rect: CGRect(origin: origin, size: CGSize(width: 10, height: 10)), image: elsewhere)))
        }
        h.act { h.editor.paste([picture(at: .zero)], sourceScale: 1, images: bitmaps) }
        h.act { h.editor.paste([picture(at: CGPoint(x: 50, y: 40))], sourceScale: 1, images: bitmaps) }
        let refs = h.editor.document.objects.compactMap { object -> ImageRef? in
            guard case .image(let picture) = object.kind else { return nil }
            return picture.image
        }
        try #require(refs.count == 2)
        #expect(refs[0] != refs[1])
        #expect(!refs.contains(elsewhere))
        #expect(refs.allSatisfy { h.editor.images[$0] != nil })
        // Both are drawn, in their own places.
        let rendered = try #require(Renderer.render(h.editor.document, images: h.editor.images))
        #expect(TestBitmaps.pixel(rendered, 15, 15) == .init(r: 255, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(rendered, 65, 55) == .init(r: 255, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(rendered, 35, 30) == .init(r: 255, g: 255, b: 255, a: 255))
    }

    @Test func aPictureAlreadyInTheDocumentKeepsItsBitmapWhenPasted() throws {
        let h = EditorHarness()
        let known = ImageRef(name: "images/known.png")
        let bitmap = TestBitmaps.solid(10, 10, TestBitmaps.red)
        h.editor.addImage(bitmap, for: known)
        let before = h.editor.images.images.count
        let picture = styled(.image(ImageObject(rect: CGRect(x: 0, y: 0, width: 10, height: 10), image: known)))
        h.act { h.editor.paste([picture], sourceScale: 1, images: [known: bitmap]) }
        let pasted = try #require(h.editor.document.objects.first)
        guard case .image(let object) = pasted.kind else {
            Issue.record("not an image object")
            return
        }
        #expect(object.image == known)
        #expect(h.editor.images.images.count == before)
    }

    @Test func bitmapsNoPastedObjectUsesAreNotKept() {
        let h = EditorHarness()
        let before = h.editor.images.images.count
        let stray = ImageRef(name: "images/stray.png")
        h.act { h.editor.paste([editorRectangle()], sourceScale: 1, images: [stray: TestBitmaps.solid(10, 10, TestBitmaps.red)]) }
        #expect(h.editor.images.images.count == before)
    }

    @Test func pastedObjectsWithBadNumbersAreDropped() throws {
        // The pasteboard is any app's to write: numbers that aren't finite, or that scaling would push there, never get in.
        let h = EditorHarness()
        let notANumber = editorRectangle(CGRect(x: Double.nan, y: 0, width: 10, height: 10))
        let endless = styled(.arrow(ArrowShape(start: .zero, end: CGPoint(x: Double.infinity, y: 5), style: .standard)))
        let thickness = AnnotationObject(kind: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)),
                                         style: ObjectStyle(color: red, lineWidth: Double.nan, shadow: false))
        let enormous = editorRectangle(CGRect(x: 1e308, y: 0, width: 10, height: 10)) // finite, but doubled it isn't
        let sound = editorRectangle()
        h.act { h.editor.paste([notANumber, endless, thickness, enormous, sound], sourceScale: 0.5) }
        let pasted = h.editor.document.objects
        try #require(pasted.count == 1)
        // Doubled (the source's points are half as many pixels), then 10 points down and right.
        #expect(ObjectGeometry.rect(of: pasted[0].kind) == CGRect(x: 30, y: 30, width: 40, height: 40))
        #expect(h.editor.document.isWellFormed)
        #expect(h.editor.selection == [pasted[0].id])
    }

    @Test func aPasteWithNothingSoundLeftChangesNothing() {
        let h = EditorHarness()
        // Outside `act`: a call that records nothing must not be inside an undo group.
        h.editor.paste([editorRectangle(CGRect(x: Double.nan, y: 0, width: 10, height: 10))])
        #expect(h.editor.document.objects.isEmpty)
        #expect(h.editor.selection.isEmpty)
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func aScaleBeyondOneSixtyFourthToSixtyFourPastesAtTheSameSize() throws {
        // A source scale that would make the paste 1000 times as big, or a thousandth the size, is a bad number, not a scale.
        for source in [1e-9, 1e9, 1.0 / 65, 65, Double.nan, Double.infinity, -2, 0] {
            let h = EditorHarness()
            h.act { h.editor.paste([editorRectangle(CGRect(x: 0, y: 0, width: 10, height: 10))], sourceScale: source) }
            let pasted = try #require(h.editor.document.objects.first)
            #expect(ObjectGeometry.rect(of: pasted.kind) == CGRect(x: 10, y: 10, width: 10, height: 10), "source scale \(source)")
            #expect(pasted.style.lineWidth == 4, "source scale \(source)")
        }
    }

    @Test func theLimitsOfTheScaleRangeAreStillScales() throws {
        let tiny = EditorHarness()
        tiny.act { tiny.editor.paste([editorRectangle(CGRect(x: 0, y: 0, width: 64, height: 64))], sourceScale: 64) }
        #expect(ObjectGeometry.rect(of: try #require(tiny.editor.document.objects.first).kind)
            == CGRect(x: 10, y: 10, width: 1, height: 1))
        let big = EditorHarness()
        big.act { big.editor.paste([editorRectangle(CGRect(x: 0, y: 0, width: 1, height: 1))], sourceScale: 1.0 / 64) }
        #expect(ObjectGeometry.rect(of: try #require(big.editor.document.objects.first).kind)
            == CGRect(x: 10, y: 10, width: 64, height: 64))
    }

    @Test func picturesWithoutTheirBitmapsAreLeftOut() {
        let h = EditorHarness()
        let picture = styled(.image(ImageObject(rect: CGRect(x: 0, y: 0, width: 10, height: 10), image: ImageRef(name: "images/missing.png"))))
        h.act { h.editor.paste([picture, editorRectangle()]) }
        #expect(h.editor.document.objects.count == 1)
        #expect(h.editor.selection.count == 1)
    }
}

struct CanvasClampTests {
    private let sheet = AnnotationDocument(baseSize: CGSize(width: 100, height: 80), pixelScale: 1)

    private func rect(_ object: AnnotationObject) -> CGRect? {
        ObjectGeometry.rect(of: object.kind)
    }

    @Test func objectsInsideTheCanvasStayWhereTheyAre() {
        let objects = [editorRectangle(), editorRectangle(CGRect(x: 70, y: 50, width: 30, height: 30))]
        #expect(sheet.clampedIntoCanvas(objects) == objects)
    }

    @Test func aGroupMovesTogetherByTheLeastItNeeds() {
        let first = editorRectangle(CGRect(x: 80, y: 10, width: 20, height: 20))
        let second = editorRectangle(CGRect(x: 90, y: 40, width: 20, height: 20))
        // The group spans 80…110: it moves 10 left, keeping the objects' places relative to each other.
        let moved = sheet.clampedIntoCanvas([first, second])
        #expect(moved.compactMap(rect) == [CGRect(x: 70, y: 10, width: 20, height: 20), CGRect(x: 80, y: 40, width: 20, height: 20)])
    }

    @Test func aGroupBiggerThanTheCanvasLinesUpWithItsTopLeft() {
        let big = editorRectangle(CGRect(x: -20, y: -30, width: 200, height: 200))
        #expect(sheet.clampedIntoCanvas([big]).compactMap(rect) == [CGRect(x: 0, y: 0, width: 200, height: 200)])
    }

    @Test func theCanvasIsTheCroppedOrExpandedOneNotThePicture() {
        var cropped = sheet
        cropped.canvasRect = CGRect(x: 20, y: 10, width: 40, height: 30)
        let moved = cropped.clampedIntoCanvas([editorRectangle(CGRect(x: 0, y: 0, width: 20, height: 20))])
        #expect(moved.compactMap(rect) == [CGRect(x: 20, y: 10, width: 20, height: 20)])
    }

    @Test func theMoveFollowsRotateAndFlip() {
        var turned = sheet
        turned.imageOps = [.rotateRight] // 100×80 becomes 80×100: base (x, y) lands at output (80 − y, x)
        // Base y 70…90 is output x −10…10: one axis out of the canvas, and base y is the output's x.
        let moved = turned.clampedIntoCanvas([editorRectangle(CGRect(x: 50, y: 70, width: 20, height: 20))])
        #expect(moved.compactMap(rect) == [CGRect(x: 50, y: 60, width: 20, height: 20)])
        let outside = turned.outputBounds(of: moved[0])
        #expect(turned.canvasBounds.contains(outside))
    }

    @Test func clampedObjectsLieInsideTheCanvasWhateverTheArithmetic() {
        var random = Dice()
        var outside = 0
        for variant in [[], [.rotateRight], [.flipHorizontal, .rotateLeft], [.resize(width: 213, height: 77)]] as [[ImageOp]] {
            var document = sheet
            document.imageOps = variant
            let canvas = document.canvasBounds
            for _ in 0..<300 {
                let rect = CGRect(x: random.next(in: -80...160), y: random.next(in: -80...140), width: random.next(in: 3...60),
                                  height: random.next(in: 3...60))
                let moved = document.clampedIntoCanvas([editorRectangle(rect)])
                let bounds = document.outputBounds(of: moved[0])
                if bounds.minX < canvas.minX || bounds.maxX > canvas.maxX || bounds.minY < canvas.minY || bounds.maxY > canvas.maxY {
                    outside += 1
                }
            }
        }
        #expect(outside == 0)
    }

    @Test func objectsThatPaintNothingDontCount() {
        let nothing = AnnotationObject(kind: .stroke(StrokeObject(points: [], smoothed: false)), style: ObjectStyle(color: red, lineWidth: 4, shadow: false))
        let inside = editorRectangle(CGRect(x: 90, y: 10, width: 20, height: 20))
        let moved = sheet.clampedIntoCanvas([nothing, inside])
        #expect(moved[0] == nothing)
        #expect(rect(moved[1]) == CGRect(x: 80, y: 10, width: 20, height: 20))
        #expect(sheet.clampedIntoCanvas([nothing]) == [nothing])
    }
}
