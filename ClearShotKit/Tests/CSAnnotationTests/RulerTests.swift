import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// The ruler: measuring the picture between its edges (inner and outer), and the annotation that imprints a measurement.
struct RulerTests {
    private let white: (UInt8, UInt8, UInt8) = (255, 255, 255)
    private let black: (UInt8, UInt8, UInt8) = (0, 0, 0)
    private let gray: (UInt8, UInt8, UInt8) = (128, 128, 128)

    /// A sampler `width` × `height` painted by `color(x, y)`.
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

    /// 20 across: white 0–4, a black pixel at 5, gray 6–13, a black pixel at 14, white 15–19. Rows alike.
    private func framedRow(rows: Int = 1) -> PixelSampler {
        sampler(20, rows) { x, _ in
            switch x {
            case 5, 14: black
            case 6...13: gray
            default: white
            }
        }
    }

    private func span(_ sampler: PixelSampler, x: Double, outer: Bool, tolerance: Int = 8) -> (lower: Int, upper: Int)? {
        sampler.rulerSpan(through: CGPoint(x: x, y: 0.5), axis: .horizontal, outer: outer, tolerance: tolerance)
    }

    // MARK: Inner and outer size

    @Test func innerSizeRunsFromTheNearestEdgeEachWay() throws {
        let result = try #require(span(framedRow(), x: 10.5, outer: false))
        #expect(result.lower == 6 && result.upper == 14)
    }

    /// Outer steps over the first edge and the run of color beyond it: the gray area and its one-pixel border.
    @Test func outerSizeStepsOverTheFirstEdges() throws {
        let result = try #require(span(framedRow(), x: 10.5, outer: true))
        #expect(result.lower == 5 && result.upper == 15)
    }

    @Test func outerSizeCrossesTheWholeRunBeyondAnEdge() throws {
        // Gray 0–3, then a wider band 4–9 (black), then white from 10: from the gray, the outer size takes the band too.
        let wide = sampler(14, 1) { x, _ in x < 4 ? gray : x < 10 ? black : white }
        let inner = try #require(wide.rulerSpan(through: CGPoint(x: 1.5, y: 0.5), axis: .horizontal, outer: false, tolerance: 8))
        #expect(inner.lower == 0 && inner.upper == 4)
        let outer = try #require(wide.rulerSpan(through: CGPoint(x: 1.5, y: 0.5), axis: .horizontal, outer: true, tolerance: 8))
        #expect(outer.lower == 0 && outer.upper == 10)
    }

    @Test func aSideAtTheBorderStaysThere() throws {
        let sampler = framedRow()
        let inner = try #require(span(sampler, x: 2.5, outer: false))
        #expect(inner.lower == 0 && inner.upper == 5)
        // Left has nothing beyond the border; right crosses the black pixel.
        let outer = try #require(span(sampler, x: 2.5, outer: true))
        #expect(outer.lower == 0 && outer.upper == 6)
        #expect(span(sampler, x: 25, outer: false) == nil)
    }

    @Test func theVerticalAxisMeasuresDownTheColumn() throws {
        let column = sampler(1, 20) { _, y in y == 5 || y == 14 ? black : (6...13).contains(y) ? gray : white }
        let inner = try #require(column.rulerSpan(through: CGPoint(x: 0.5, y: 9.5), axis: .vertical, outer: false, tolerance: 8))
        #expect(inner.lower == 6 && inner.upper == 14)
        let outer = try #require(column.rulerSpan(through: CGPoint(x: 0.5, y: 9.5), axis: .vertical, outer: true, tolerance: 8))
        #expect(outer.lower == 5 && outer.upper == 15)
    }

    @Test func theToleranceDecidesWhatIsAnEdge() throws {
        let faint = sampler(20, 1) { x, _ in x < 10 ? (100, 100, 100) : (106, 106, 106) }
        let loose = try #require(faint.rulerSpan(through: CGPoint(x: 4.5, y: 0.5), axis: .horizontal, outer: false, tolerance: 8))
        #expect(loose.lower == 0 && loose.upper == 20)
        let exact = try #require(faint.rulerSpan(through: CGPoint(x: 4.5, y: 0.5), axis: .horizontal, outer: false, tolerance: 0))
        #expect(exact.lower == 0 && exact.upper == 10)
    }

    @Test func toleranceIsHeldToItsRange() {
        #expect(RulerGeometry.toleranceRange == 0...64)
        #expect(RulerGeometry.clampedTolerance(-3) == 0)
        #expect(RulerGeometry.clampedTolerance(200) == 64)
        #expect(RulerGeometry.clampedTolerance(RulerGeometry.defaultTolerance) == RulerGeometry.defaultTolerance)
    }

    // MARK: On the picture, as shown

    private func pixels(ops: [ImageOp] = []) throws -> PicturePixels {
        var (document, images) = TestBitmaps.document(base: TestBitmaps.split(40, 20, left: TestBitmaps.red, right: TestBitmaps.white, at: 10))
        document.imageOps = ops
        return try #require(PicturePixels.make(of: document, images: images))
    }

    @Test func measuresInBasePixels() throws {
        let measurement = try #require(try pixels().measure(through: CGPoint(x: 20, y: 5), axis: .horizontal, outer: false, tolerance: 8))
        #expect(measurement.pixels == 30)
        #expect(measurement.start == CGPoint(x: 10, y: 5.5) && measurement.end == CGPoint(x: 40, y: 5.5))
        let vertical = try #require(try pixels().measure(through: CGPoint(x: 20, y: 5), axis: .vertical, outer: false, tolerance: 8))
        #expect(vertical.pixels == 20)
        #expect(vertical.start == CGPoint(x: 20.5, y: 0) && vertical.end == CGPoint(x: 20.5, y: 20))
        #expect(try pixels().measure(through: CGPoint(x: 50, y: 5), axis: .horizontal, outer: false, tolerance: 8) == nil)
    }

    /// The axis is the one on screen: after a flip the run is the same length, its ends swapped in the base.
    @Test func followsAFlip() throws {
        let flipped = try #require(try pixels(ops: [.flipHorizontal]).measure(through: CGPoint(x: 20, y: 5), axis: .horizontal,
                                                                           outer: false, tolerance: 8))
        #expect(flipped.pixels == 30)
        #expect(flipped.start == CGPoint(x: 40, y: 5.5) && flipped.end == CGPoint(x: 10, y: 5.5))
    }

    @Test func aTurnSwapsWhichAxisRunsAcross() throws {
        // Turned right, the picture is 20 wide and 40 tall; a horizontal run on screen is a vertical one in the base.
        let turned = try #require(try pixels(ops: [.rotateRight]).measure(through: CGPoint(x: 20, y: 5), axis: .horizontal,
                                                                       outer: false, tolerance: 8))
        #expect(turned.pixels == 20)
        #expect(abs(turned.end.y - turned.start.y) == 20 && turned.start.x == turned.end.x)
    }

    // MARK: Label and geometry

    @Test func labelsReadInTheChosenUnit() {
        #expect(RulerGeometry.labelText(outputPixels: 246, unit: .pixels, pixelsPerPoint: 2) == "246 px")
        #expect(RulerGeometry.labelText(outputPixels: 246, unit: .points, pixelsPerPoint: 2) == "123 pt")
        #expect(RulerGeometry.labelText(outputPixels: 100, unit: .points, pixelsPerPoint: 1.5) == "66.7 pt")
        #expect(RulerGeometry.labelText(outputPixels: 100, unit: .points, pixelsPerPoint: 1) == "100 pt")
    }

    @Test func theLengthIsTheCurrentOneAsShown() {
        let ruler = RulerObject(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 110, y: 10))
        var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 2)
        #expect(RulerGeometry.outputLength(of: ruler, in: document) == 100)
        #expect(RulerGeometry.labelText(of: ruler, in: document, unit: .points) == "50 pt")
        #expect(RulerGeometry.labelText(of: ruler, in: document, unit: .pixels) == "100 px")
        // Resized to half, the ruler is half as long in pixels and, the capture now being 1x, the same in points.
        document.imageOps = [.resize(width: 100, height: 50)]
        #expect(RulerGeometry.labelText(of: ruler, in: document, unit: .pixels) == "50 px")
        #expect(RulerGeometry.labelText(of: ruler, in: document, unit: .points) == "50 pt")
        // Turned, nothing changes.
        document.imageOps = [.rotateRight]
        #expect(RulerGeometry.labelText(of: ruler, in: document, unit: .pixels) == "100 px")
    }

    private func rulerKind(of object: AnnotationObject) throws -> RulerObject {
        guard case .ruler(let ruler) = object.kind else { throw RulerTestError.notARuler }
        return ruler
    }

    private enum RulerTestError: Error { case notARuler }

    @Test func labelsAreMadeForTheDrawOnly() throws {
        let object = AnnotationObject(kind: .ruler(RulerObject(start: .zero, end: CGPoint(x: 40, y: 0))),
                                      style: ObjectStyle(color: .white, lineWidth: 2, shadow: false))
        var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        document.objects = [object]
        let labeled = document.labelingRulers(document.objects, in: .pixels)
        let ruler = try rulerKind(of: labeled[0])
        #expect(ruler.label == "40 px")
        #expect(labeled[0].id == object.id)
        let stored = try rulerKind(of: document.objects[0])
        #expect(stored.label == nil)
    }

    @Test func capsStandAcrossTheLine() {
        let ruler = RulerObject(start: CGPoint(x: 10, y: 50), end: CGPoint(x: 110, y: 50))
        let caps = RulerGeometry.caps(of: ruler, lineWidth: 2)
        let half = RulerGeometry.capHalfLength(lineWidth: 2)
        #expect(caps.count == 2)
        #expect(caps[0].0 == CGPoint(x: 10, y: 50 - half) && caps[0].1 == CGPoint(x: 10, y: 50 + half))
        #expect(caps[1].0.x == 110 && caps[1].1.x == 110)
        // Down a column the caps lie across it.
        let vertical = RulerGeometry.caps(of: RulerObject(start: CGPoint(x: 5, y: 0), end: CGPoint(x: 5, y: 30)), lineWidth: 2)
        #expect(vertical[1].0.y == 30 && vertical[1].1.y == 30 && vertical[1].0.x != vertical[1].1.x)
    }

    @Test func theLabelSitsClearOfTheLine() {
        let size = CGSize(width: 40, height: 14)
        let across = RulerObject(start: CGPoint(x: 0, y: 100), end: CGPoint(x: 100, y: 100))
        let above = RulerGeometry.labelFrame(of: across, size: size, lineWidth: 2)
        #expect(above.midX == 50 && above.maxY < 100 - RulerGeometry.capHalfLength(lineWidth: 2))
        let down = RulerObject(start: CGPoint(x: 100, y: 0), end: CGPoint(x: 100, y: 100))
        let beside = RulerGeometry.labelFrame(of: down, size: size, lineWidth: 2)
        #expect(beside.midY == 50 && beside.minX > 100 + RulerGeometry.capHalfLength(lineWidth: 2))
    }

    // MARK: The annotation

    private func rulerObject() -> AnnotationObject {
        AnnotationObject(kind: .ruler(RulerObject(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 90, y: 20))),
                         style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 4, shadow: false))
    }

    @Test func actsLikeALine() throws {
        let object = rulerObject()
        #expect(ObjectGeometry.hitTest(object, at: CGPoint(x: 50, y: 21), tolerance: 2))
        #expect(!ObjectGeometry.hitTest(object, at: CGPoint(x: 50, y: 40), tolerance: 2))
        let bounds = ObjectGeometry.bounds(of: object)
        #expect(bounds.contains(CGPoint(x: 10, y: 20)) && bounds.contains(CGPoint(x: 90, y: 20)))
        #expect(ObjectGeometry.handles(of: object) == [.start, .end])
        #expect(ObjectGeometry.handlePoint(.end, of: object) == CGPoint(x: 90, y: 20))
        let moved = try rulerKind(of: ObjectGeometry.translated(object, by: CGVector(dx: 5, dy: 7)))
        #expect(moved.start == CGPoint(x: 15, y: 27) && moved.end == CGPoint(x: 95, y: 27))
        let dragged = try rulerKind(of: ObjectGeometry.dragging(.end, of: object, to: CGPoint(x: 70, y: 20), constrained: false))
        #expect(dragged.end == CGPoint(x: 70, y: 20) && dragged.start == CGPoint(x: 10, y: 20))
        let scaled = try rulerKind(of: ObjectScaling.scaled(object, by: 2))
        #expect(scaled.end == CGPoint(x: 180, y: 40))
        #expect(object.isFinite)
    }

    @Test func roundTripsThroughAFileWithoutItsLabel() throws {
        var object = rulerObject()
        var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 2)
        document.objects = [object]
        let data = try JSONEncoder().encode(document)
        #expect(!String(decoding: data, as: UTF8.self).contains("label"))
        #expect(try JSONDecoder().decode(AnnotationDocument.self, from: data) == document)
        // A label set for a draw is not written, and the object reads back without one.
        if case .ruler(var ruler) = object.kind {
            ruler.label = "46 pt"
            object.kind = .ruler(ruler)
        }
        document.objects = [object]
        let again = try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document))
        let read = try rulerKind(of: again.objects[0])
        #expect(read.label == nil && read.start == CGPoint(x: 10, y: 20))
    }

    /// A document written before rulers existed holds none, and reads as it did.
    @Test func aDocumentWithoutRulersStillDecodes() throws {
        let json = """
        {"version":1,"baseSize":[200,100],"pixelScale":2,"imageOps":[],"objects":[]}
        """
        let document = try JSONDecoder().decode(AnnotationDocument.self, from: Data(json.utf8))
        #expect(document.objects.isEmpty)
        let line = AnnotationObject(kind: .line(start: .zero, end: CGPoint(x: 5, y: 5)),
                                    style: ObjectStyle(color: .white, lineWidth: 2, shadow: false))
        let old = try JSONDecoder().decode(AnnotationObject.self, from: JSONEncoder().encode(line))
        #expect(old == line)
    }

    @Test func theRenderShowsTheRulerAndItsLabel() throws {
        var (document, images) = TestBitmaps.document(base: TestBitmaps.solid(120, 60, TestBitmaps.white))
        document.objects = [rulerObject()]
        let image = try #require(Renderer.render(document, images: images))
        // The line, and the cap at its start, are in the color; far from them the picture is untouched.
        let line = TestBitmaps.pixel(image, 50, 20)
        #expect(line.r > 200 && line.g < 80 && line.b < 80)
        let cap = TestBitmaps.pixel(image, 10, 14)
        #expect(cap.g < 80)
        let far = TestBitmaps.pixel(image, 50, 55)
        #expect(far.r == 255 && far.g == 255 && far.b == 255)
        // The label's plate is above the line, in the color too.
        let plate = ObjectGeometry.bounds(of: document.objects[0])
        let labeled = document.labelingRulers(document.objects, in: .pixels)
        let ruler = try rulerKind(of: labeled[0])
        #expect(ruler.label == "80 px")
        #expect(plate.minY < 20)
    }

    @Test func theToleranceIsRememberedInTheSettings() throws {
        var settings = AnnotateToolSettings()
        #expect(settings.rulerTolerance == RulerGeometry.defaultTolerance)
        settings.rulerTolerance = 20
        #expect(try JSONDecoder().decode(AnnotateToolSettings.self, from: JSONEncoder().encode(settings)).rulerTolerance == 20)
        // Settings saved before it existed keep their other values and get the default.
        let old = try JSONDecoder().decode(AnnotateToolSettings.self, from: Data(#"{"sizeLevel":5}"#.utf8))
        #expect(old.sizeLevel == 5 && old.rulerTolerance == RulerGeometry.defaultTolerance)
        let wild = try JSONDecoder().decode(AnnotateToolSettings.self, from: Data(#"{"rulerTolerance":900}"#.utf8))
        #expect(wild.rulerTolerance == 64)
    }
}
