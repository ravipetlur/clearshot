import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// The distance from `point` to the nearest point of the polyline through `outline`.
private func distance(from point: CGPoint, to outline: [CGPoint]) -> Double {
    var nearest = Double.infinity
    for index in 0..<(outline.count - 1) {
        let a = outline[index]
        let b = outline[index + 1]
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1) : 0
        nearest = min(nearest, hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy)))
    }
    return nearest
}

private func closedOutline(of rect: CGRect) -> [CGPoint] {
    [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
     CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)]
}

private func ellipseOutline(_ rect: CGRect) -> [CGPoint] {
    (0...720).map { index in
        let angle = Double(index) / 720 * 2 * Double.pi
        return CGPoint(x: rect.midX + rect.width / 2 * cos(angle), y: rect.midY + rect.height / 2 * sin(angle))
    }
}

struct RoughRandomTests {
    /// A seed gives the same sequence every time, and different seeds give different ones.
    @Test func theSeedDecidesTheSequence() {
        var a = RoughRandom(seed: 42)
        var b = RoughRandom(seed: 42)
        #expect((0..<20).map { _ in a.unit() } == (0..<20).map { _ in b.unit() })
        var c = RoughRandom(seed: 1)
        var d = RoughRandom(seed: 2)
        #expect((0..<5).map { _ in c.unit() } != (0..<5).map { _ in d.unit() })
    }

    @Test func valuesStayInRange() {
        var random = RoughRandom(seed: 0)
        var units: [Double] = [], signeds: [Double] = []
        for _ in 0..<1000 {
            units.append(random.unit())
            signeds.append(random.signed())
        }
        #expect(units.filter { !($0 >= 0 && $0 < 1) } == [])
        #expect(signeds.filter { !($0 >= -1 && $0 < 1) } == [])
    }
}

struct RoughPathTests {
    private let rect = CGRect(x: 10, y: 20, width: 200, height: 120)

    /// The same seed draws the same strokes, and a different seed different ones.
    @Test func theSeedDecidesTheStrokes() {
        let amplitude = RoughPath.amplitude(lineWidth: 4, extent: 120)
        #expect(RoughPath.rectangle(rect, amplitude: amplitude, seed: 7) == RoughPath.rectangle(rect, amplitude: amplitude, seed: 7))
        #expect(RoughPath.ellipse(rect, amplitude: amplitude, seed: 7) == RoughPath.ellipse(rect, amplitude: amplitude, seed: 7))
        #expect(RoughPath.path(from: RoughPath.ellipse(rect, amplitude: amplitude, seed: 7))
            == RoughPath.path(from: RoughPath.ellipse(rect, amplitude: amplitude, seed: 7)))
        #expect(RoughPath.rectangle(rect, amplitude: amplitude, seed: 7) != RoughPath.rectangle(rect, amplitude: amplitude, seed: 8))
        #expect(RoughPath.ellipse(rect, amplitude: amplitude, seed: 7) != RoughPath.ellipse(rect, amplitude: amplitude, seed: 8))
        let line = (CGPoint.zero, CGPoint(x: 100, y: 30))
        #expect(RoughPath.line(from: line.0, to: line.1, amplitude: 2, seed: 1) != RoughPath.line(from: line.0, to: line.1, amplitude: 2, seed: 2))
    }

    @Test func eachShapeIsTwoPasses() {
        #expect(RoughPath.line(from: .zero, to: CGPoint(x: 50, y: 0), amplitude: 2, seed: 1).count == 2)
        #expect(RoughPath.ellipse(rect, amplitude: 2, seed: 1).count == 2)
        #expect(RoughPath.rectangle(rect, amplitude: 2, seed: 1).count == 8)
    }

    @Test func aRectangleStaysNearTheCleanOutline() {
        let outline = closedOutline(of: rect)
        for seed in UInt32(0)..<20 {
            let amplitude = RoughPath.amplitude(lineWidth: 6, extent: rect.height)
            let points = RoughPath.rectangle(rect, amplitude: amplitude, seed: seed).flatMap { $0 }
            for point in points {
                #expect(distance(from: point, to: outline) <= RoughPath.reachFactor * amplitude)
            }
        }
    }

    @Test func anEllipseStaysNearTheCleanEllipse() {
        let outline = ellipseOutline(rect)
        for seed in UInt32(0)..<20 {
            let amplitude = RoughPath.amplitude(lineWidth: 6, extent: rect.height)
            let points = RoughPath.ellipse(rect, amplitude: amplitude, seed: seed).flatMap { $0 }
            for point in points {
                #expect(distance(from: point, to: outline) <= RoughPath.reachFactor * amplitude)
            }
        }
    }

    @Test func aLineStaysNearTheCleanLineAndOvershootsItsEnds() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 300, y: 40)
        let amplitude = 3.0
        var overshot = false
        for seed in UInt32(0)..<20 {
            for stroke in RoughPath.line(from: start, to: end, amplitude: amplitude, seed: seed) {
                for point in stroke {
                    // The clean line, extended by the most an overshoot can add.
                    let direction = CGVector(dx: end.x - start.x, dy: end.y - start.y)
                    let length = hypot(direction.dx, direction.dy)
                    let extended = [CGPoint(x: start.x - direction.dx / length * 2 * amplitude, y: start.y - direction.dy / length * 2 * amplitude),
                                    CGPoint(x: end.x + direction.dx / length * 2 * amplitude, y: end.y + direction.dy / length * 2 * amplitude)]
                    #expect(distance(from: point, to: extended) <= RoughPath.reachFactor * amplitude)
                }
                if let last = stroke.last, hypot(last.x - end.x, last.y - end.y) > 0 { overshot = true }
            }
        }
        #expect(overshot)
    }

    @Test func theCurveFitsInTheCleanShapeGrownByItsReach() {
        let amplitude = RoughPath.amplitude(lineWidth: 4, extent: rect.height)
        let reach = RoughPath.reachFactor * amplitude
        let box = rect.insetBy(dx: -reach, dy: -reach)
        for path in [RoughPath.path(from: RoughPath.rectangle(rect, amplitude: amplitude, seed: 3)),
                     RoughPath.path(from: RoughPath.ellipse(rect, amplitude: amplitude, seed: 3))] {
            #expect(box.contains(path.boundingBoxOfPath))
        }
    }

    @Test func theWobbleScalesWithLineWidthButNotPastASmallShape() {
        #expect(RoughPath.amplitude(lineWidth: 8, extent: 400) > RoughPath.amplitude(lineWidth: 2, extent: 400))
        #expect(RoughPath.amplitude(lineWidth: 8, extent: 10) < 1)
    }

    @Test func aDegenerateRunOfPointsDrawsNothing() {
        #expect(RoughPath.polyline([], closed: false, amplitude: 2, seed: 1).isEmpty)
        #expect(RoughPath.polyline([.zero], closed: true, amplitude: 2, seed: 1).isEmpty)
        #expect(RoughPath.line(from: .zero, to: .zero, amplitude: 2, seed: 1).allSatisfy { $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } })
    }
}

struct HandDrawnObjectTests {
    private func arrow(_ style: ArrowStyle, control: CGPoint? = nil) -> ArrowShape {
        ArrowShape(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 210, y: 90), control: control, style: style)
    }

    @Test func aHandDrawnArrowIsTheSameEveryTime() {
        for style in ArrowStyle.allCases {
            let a = ArrowGeometry.roughParts(for: arrow(style, control: CGPoint(x: 80, y: 120)), width: 4, seed: 9)
            let b = ArrowGeometry.roughParts(for: arrow(style, control: CGPoint(x: 80, y: 120)), width: 4, seed: 9)
            let c = ArrowGeometry.roughParts(for: arrow(style, control: CGPoint(x: 80, y: 120)), width: 4, seed: 10)
            #expect(a.shaft == b.shaft)
            #expect(a.shaft != c.shaft)
            #expect(a.fills == b.fills)
        }
    }

    @Test func aHandDrawnArrowKeepsTheCleanHeads() {
        for style in ArrowStyle.allCases {
            let clean = ArrowGeometry.parts(for: arrow(style), width: 4)
            let rough = ArrowGeometry.roughParts(for: arrow(style), width: 4, seed: 5)
            #expect(rough.fills == clean.fills)
        }
    }

    @Test func rendersTheSameFromTheSameSeed() throws {
        func rendered(seed: UInt32) throws -> Data {
            var document = AnnotationDocument(baseSize: CGSize(width: 240, height: 160), pixelScale: 1)
            document.objects = [AnnotationObject(kind: .ellipse(CGRect(x: 20, y: 20, width: 200, height: 120)),
                                                 style: ObjectStyle(color: .black, lineWidth: 4, shadow: false, handDrawn: true, seed: seed))]
            let store = ImageStore([ImageRef.original.name: TestBitmaps.solid(240, 160, TestBitmaps.white)])
            let image = try #require(Renderer.render(document, images: store))
            return try #require(image.dataProvider?.data as Data?)
        }
        #expect(try rendered(seed: 3) == rendered(seed: 3))
        #expect(try rendered(seed: 3) != rendered(seed: 4))
    }

    @Test func handDrawnObjectsKeepTheirSeedThroughTheFile() throws {
        let style = ObjectStyle(color: .black, lineWidth: 4, shadow: true, handDrawn: true, seed: 4_000_000_000)
        let object = AnnotationObject(kind: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)), style: style)
        let decoded = try JSONDecoder().decode(AnnotationObject.self, from: JSONEncoder().encode(object))
        #expect(decoded == object)
        #expect(decoded.style.seed == 4_000_000_000)
        let copy = object.copied()
        #expect(copy.style == object.style)
    }

    @Test func aStyleOrTextWrittenBeforeHandDrawnDecodesAsClean() throws {
        let style = try JSONDecoder().decode(ObjectStyle.self, from: Data(#"{"color":{"red":0,"green":0,"blue":0,"alpha":1},"lineWidth":3}"#.utf8))
        #expect(!style.handDrawn)
        #expect(style.seed == 0)
        let text = try JSONDecoder().decode(
            TextObject.self, from: Data(#"{"origin":[0,0],"string":"a","style":"standard","fontSize":20}"#.utf8))
        #expect(!text.handDrawn)
    }

    @Test func aCleanObjectIsWrittenWithoutTheHandDrawnKeys() throws {
        let object = AnnotationObject(kind: .ellipse(CGRect(x: 0, y: 0, width: 4, height: 4)),
                                      style: ObjectStyle(color: .black, lineWidth: 4, shadow: false))
        let json = try #require(String(data: JSONEncoder().encode(object), encoding: .utf8))
        #expect(!json.contains("handDrawn"))
        #expect(!json.contains("seed"))
    }

    @Test func handDrawnTextUsesAHandwritingFontWhenThereIsOne() {
        let plain = TextLayout.font(for: .standard, size: 20)
        let handwritten = TextLayout.font(for: .standard, size: 20, handDrawn: true)
        let available = TextLayout.handwritingFonts.contains { NSFont(name: $0, size: 20) != nil }
        #expect(available == (handwritten.fontName != plain.fontName))
        #expect(handwritten.pointSize == 20)
    }

    @Test func handDrawnOutlinesGrowTheBoundsByTheirReach() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 60)
        let clean = AnnotationObject(kind: .rectangle(rect), style: ObjectStyle(color: .black, lineWidth: 4, shadow: false))
        var rough = clean
        rough.style.handDrawn = true
        #expect(ObjectGeometry.bounds(of: clean) == rect)
        #expect(ObjectGeometry.bounds(of: rough).contains(rect.insetBy(dx: -RoughPath.amplitude(lineWidth: 4, extent: 60), dy: 0)))
    }
}
