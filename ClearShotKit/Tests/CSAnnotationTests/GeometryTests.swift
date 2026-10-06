import AppKit
import CoreGraphics
import Testing
@testable import CSAnnotation

private func object(_ kind: ObjectKind, width: Double = 4) -> AnnotationObject {
    AnnotationObject(kind: kind, style: ObjectStyle(color: .black, lineWidth: width, shadow: false))
}

struct HitTestTests {
    @Test func outlineRectanglesHitOnTheirEdgeOnly() {
        let rect = object(.rectangle(CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(ObjectGeometry.hitTest(rect, at: CGPoint(x: 1, y: 50), tolerance: 2))
        #expect(!ObjectGeometry.hitTest(rect, at: CGPoint(x: 50, y: 50), tolerance: 2))
        #expect(!ObjectGeometry.hitTest(rect, at: CGPoint(x: 120, y: 50), tolerance: 2))
    }

    @Test func filledShapesHitInside() {
        let filled = object(.filledRectangle(CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(ObjectGeometry.hitTest(filled, at: CGPoint(x: 50, y: 50), tolerance: 0))
    }

    @Test func ellipsesHitOnTheirRing() {
        let ellipse = object(.ellipse(CGRect(x: 0, y: 0, width: 100, height: 50)))
        #expect(ObjectGeometry.hitTest(ellipse, at: CGPoint(x: 1, y: 25), tolerance: 2))
        #expect(!ObjectGeometry.hitTest(ellipse, at: CGPoint(x: 50, y: 25), tolerance: 2))
        #expect(!ObjectGeometry.hitTest(ellipse, at: CGPoint(x: 2, y: 2), tolerance: 2))
    }

    @Test func linesHitNearTheSegment() {
        let line = object(.line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0)))
        #expect(ObjectGeometry.hitTest(line, at: CGPoint(x: 50, y: 3), tolerance: 2))
        #expect(!ObjectGeometry.hitTest(line, at: CGPoint(x: 50, y: 10), tolerance: 2))
        #expect(!ObjectGeometry.hitTest(line, at: CGPoint(x: 110, y: 0), tolerance: 2))
    }

    @Test func curvedArrowsHitAlongTheCurve() {
        let arrow = object(.arrow(ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), control: CGPoint(x: 50, y: 80), style: .curved)))
        #expect(ObjectGeometry.hitTest(arrow, at: CGPoint(x: 50, y: 40), tolerance: 3))
        #expect(!ObjectGeometry.hitTest(arrow, at: CGPoint(x: 50, y: 0), tolerance: 3))
    }

    @Test func countersHitWithinTheirCircle() {
        let counter = object(.counter(CounterObject(center: CGPoint(x: 50, y: 50), value: 1, style: .numbers, diameter: 20)))
        #expect(ObjectGeometry.hitTest(counter, at: CGPoint(x: 58, y: 50), tolerance: 0))
        #expect(!ObjectGeometry.hitTest(counter, at: CGPoint(x: 65, y: 50), tolerance: 0))
    }

    @Test func singlePointStrokesHitNearThePoint() {
        let dot = object(.stroke(StrokeObject(points: [CGPoint(x: 10, y: 10)], smoothed: false)), width: 6)
        #expect(ObjectGeometry.hitTest(dot, at: CGPoint(x: 12, y: 10), tolerance: 1))
    }

    /// The object a click at `point` picks, the way the select tool looks for it: the one drawn on top.
    private func topHit(in document: AnnotationDocument, at point: CGPoint) -> AnnotationObject? {
        document.visualOrder.reversed().first { ObjectGeometry.hitTest($0, at: point, tolerance: 3) }
    }

    @Test func objectsDrawnOverASpotlightWinTheClick() {
        // An arrow, then a spotlight around it: the canvas draws the arrow above the spotlight's dimming.
        let arrow = object(.arrow(ArrowShape(start: CGPoint(x: 20, y: 50), end: CGPoint(x: 80, y: 50), style: .standard)))
        let spotlight = object(.spotlight(SpotlightObject(rect: CGRect(x: 10, y: 30, width: 80, height: 40), shape: .rectangle,
                                                          opacity: 0.6)))
        var document = AnnotationDocument(baseSize: CGSize(width: 100, height: 100), pixelScale: 1)
        document.objects = [arrow, spotlight]
        #expect(topHit(in: document, at: CGPoint(x: 50, y: 50))?.id == arrow.id)
        // A redaction made later over the arrow is drawn under it too.
        let redaction = object(.redact(RedactObject(rect: CGRect(x: 30, y: 40, width: 40, height: 20), style: .pixelate, intensity: 5)))
        document.objects = [arrow, redaction, spotlight]
        #expect(topHit(in: document, at: CGPoint(x: 50, y: 50))?.id == arrow.id)
        // Beside the arrow, inside the redaction, the redaction is what shows, so it is what the click picks.
        #expect(topHit(in: document, at: CGPoint(x: 35, y: 57))?.id == redaction.id)
    }

    @Test(arguments: SpotlightShape.allCases)
    func aSpotlightsInteriorDoesNotCatchClicks(shape: SpotlightShape) {
        let rect = CGRect(x: 10, y: 20, width: 80, height: 60)
        let spotlight = object(.spotlight(SpotlightObject(rect: rect, shape: shape, opacity: 0.6)))
        // Its lit inside looks like the plain picture: clicks there go through.
        #expect(!ObjectGeometry.hitTest(spotlight, at: CGPoint(x: rect.midX, y: rect.midY), tolerance: 3))
        #expect(!ObjectGeometry.hitTest(spotlight, at: CGPoint(x: rect.minX + 10, y: rect.midY), tolerance: 3))
        // Its edge, where the dimming starts, takes the click, from either side within the tolerance.
        #expect(ObjectGeometry.hitTest(spotlight, at: CGPoint(x: rect.minX, y: rect.midY), tolerance: 3))
        #expect(ObjectGeometry.hitTest(spotlight, at: CGPoint(x: rect.midX, y: rect.maxY + 2), tolerance: 3))
        #expect(ObjectGeometry.hitTest(spotlight, at: CGPoint(x: rect.maxX - 2, y: rect.midY), tolerance: 3))
        // Well outside, in the dimmed picture, it doesn't.
        #expect(!ObjectGeometry.hitTest(spotlight, at: CGPoint(x: rect.minX - 6, y: rect.midY), tolerance: 3))
    }

    @Test func redactionsAreHitAnywhereInside() {
        let redaction = object(.redact(RedactObject(rect: CGRect(x: 10, y: 10, width: 80, height: 60), style: .pixelate, intensity: 5)))
        #expect(ObjectGeometry.hitTest(redaction, at: CGPoint(x: 50, y: 40), tolerance: 0))
    }
}

struct BoundsAndMovesTests {
    @Test func boundsCoverLineWidth() {
        let line = object(.line(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 10)), width: 6)
        #expect(ObjectGeometry.bounds(of: line) == CGRect(x: 7, y: 7, width: 46, height: 6))
    }

    @Test func translatingMovesEveryPoint() {
        let arrow = object(.arrow(ArrowShape(start: .zero, end: CGPoint(x: 10, y: 0), control: CGPoint(x: 5, y: 5), style: .curved)))
        let moved = ObjectGeometry.translated(arrow, by: CGVector(dx: 3, dy: 4))
        #expect(moved.kind == .arrow(ArrowShape(start: CGPoint(x: 3, y: 4), end: CGPoint(x: 13, y: 4),
                                               control: CGPoint(x: 8, y: 9), style: .curved)))
        #expect(moved.id == arrow.id)
    }

    @Test func rectHandlesAreTheEightPointsAndLinesTheirEnds() {
        #expect(ObjectGeometry.handles(of: object(.rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)))).count == 8)
        #expect(ObjectGeometry.handles(of: object(.line(start: .zero, end: CGPoint(x: 5, y: 5)))) == [.start, .end])
        let curved = object(.arrow(ArrowShape(start: .zero, end: CGPoint(x: 9, y: 0), style: .curved)))
        #expect(ObjectGeometry.handles(of: curved) == [.start, .end, .control])
        #expect(ObjectGeometry.handlePoint(.control, of: curved) == CGPoint(x: 4.5, y: 0))
    }

    @Test func rectHandlesIncludeEveryRectEdge() {
        // `RectEdge`, not `Edge`: that name collides with SwiftUI.Edge in files importing both.
        #expect(RectEdge.allCases.count == 4)
        let handles = ObjectGeometry.handles(of: object(.ellipse(CGRect(x: 0, y: 0, width: 10, height: 10))))
        for edge in RectEdge.allCases {
            #expect(handles.contains(.edge(edge)))
        }
    }

    @Test func draggingACornerResizes() {
        let rect = object(.rectangle(CGRect(x: 0, y: 0, width: 100, height: 50)))
        let dragged = ObjectGeometry.dragging(.corner(.bottomRight), of: rect, to: CGPoint(x: 150, y: 80), constrained: false)
        #expect(ObjectGeometry.rect(of: dragged.kind) == CGRect(x: 0, y: 0, width: 150, height: 80))
    }

    @Test func shiftKeepsTheAspectRatio() {
        let rect = object(.rectangle(CGRect(x: 0, y: 0, width: 100, height: 50)))
        let dragged = ObjectGeometry.dragging(.corner(.bottomRight), of: rect, to: CGPoint(x: 300, y: 60), constrained: true)
        #expect(ObjectGeometry.rect(of: dragged.kind) == CGRect(x: 0, y: 0, width: 300, height: 150))
    }

    @Test func shiftOnAnEdgeKeepsTheProportions() {
        let picture = object(.image(ImageObject(rect: CGRect(x: 0, y: 0, width: 100, height: 50), image: ImageRef(name: "images/a.png"))))
        let dragged = ObjectGeometry.dragging(.edge(.right), of: picture, to: CGPoint(x: 200, y: 0), constrained: true)
        #expect(ObjectGeometry.rect(of: dragged.kind) == CGRect(x: 0, y: -25, width: 200, height: 100))
    }

    @Test func draggingPastTheOppositeEdgeFlipsCleanly() {
        let rect = object(.filledRectangle(CGRect(x: 10, y: 10, width: 20, height: 20)))
        let dragged = ObjectGeometry.dragging(.edge(.left), of: rect, to: CGPoint(x: 50, y: 0), constrained: false)
        #expect(ObjectGeometry.rect(of: dragged.kind) == CGRect(x: 30, y: 10, width: 20, height: 20))
    }

    @Test func draggingAnArrowEndWithShiftSnapsTo45Degrees() {
        let arrow = object(.arrow(ArrowShape(start: .zero, end: CGPoint(x: 10, y: 0), style: .standard)))
        let dragged = ObjectGeometry.dragging(.end, of: arrow, to: CGPoint(x: 100, y: 4), constrained: true)
        guard case .arrow(let shape) = dragged.kind else { Issue.record("not an arrow"); return }
        #expect(abs(shape.end.y) < 0.0001)
    }

    @Test func textHandlesSetTheWrapWidth() {
        let text = object(.text(TextObject(origin: CGPoint(x: 10, y: 10), string: "Hello there", style: .standard, fontSize: 20)))
        #expect(ObjectGeometry.handles(of: text) == [.edge(.left), .edge(.right)])
        let dragged = ObjectGeometry.dragging(.edge(.right), of: text, to: CGPoint(x: 90, y: 0), constrained: false)
        guard case .text(let result) = dragged.kind else { Issue.record("not text"); return }
        #expect(result.width == 80)
        #expect(result.origin == CGPoint(x: 10, y: 10))
    }

    @Test func outlineRectangleBoundsAreItsRect() {
        let rect = CGRect(x: 5, y: 6, width: 40, height: 30)
        #expect(ObjectGeometry.bounds(of: object(.rectangle(rect), width: 8)) == rect)
    }

    @Test func strokeBoundsGrowByHalfTheWidth() {
        let stroke = object(.stroke(StrokeObject(points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 20)], smoothed: false)), width: 6)
        #expect(ObjectGeometry.bounds(of: stroke) == CGRect(x: 7, y: 7, width: 26, height: 16))
    }

    @Test(arguments: [CGPoint(x: 100, y: 0), CGPoint(x: 80, y: 60), CGPoint(x: 0, y: 90)])
    func fancyArrowBoundsCoverTheWholeBody(end: CGPoint) {
        let shape = ArrowShape(start: .zero, end: end, style: .fancy)
        let arrow = object(.arrow(shape), width: 6)
        let body = ArrowGeometry.parts(for: shape, width: 6).fills[0].boundingBoxOfPath
        #expect(ObjectGeometry.bounds(of: arrow).insetBy(dx: -0.001, dy: -0.001).contains(body))
    }

    @Test func translatingMovesText() {
        let text = object(.text(TextObject(origin: CGPoint(x: 10, y: 10), width: 80, string: "Hi", style: .box, fontSize: 20)))
        let moved = ObjectGeometry.translated(text, by: CGVector(dx: 5, dy: -3))
        #expect(moved.kind == .text(TextObject(origin: CGPoint(x: 15, y: 7), width: 80, string: "Hi", style: .box, fontSize: 20)))
    }

    @Test func translatingMovesHighlightPointsAndRects() {
        let highlight = object(.highlight(HighlightObject(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)],
                                                          rects: [CGRect(x: 0, y: 0, width: 10, height: 5)],
                                                          width: 16, opacity: 0.4)))
        let moved = ObjectGeometry.translated(highlight, by: CGVector(dx: 2, dy: 3))
        #expect(moved.kind == .highlight(HighlightObject(points: [CGPoint(x: 2, y: 3), CGPoint(x: 12, y: 3)],
                                                         rects: [CGRect(x: 2, y: 3, width: 10, height: 5)],
                                                         width: 16, opacity: 0.4)))
    }

    @Test func draggingTheLeftEdgeOfTextMovesTheOriginAndWidthTogether() {
        let text = object(.text(TextObject(origin: CGPoint(x: 10, y: 10), width: 100, string: "Hello there", style: .standard, fontSize: 20)))
        let dragged = ObjectGeometry.dragging(.edge(.left), of: text, to: CGPoint(x: 50, y: 0), constrained: false)
        guard case .text(let result) = dragged.kind else { Issue.record("not text"); return }
        #expect(result.origin == CGPoint(x: 50, y: 10))
        #expect(result.width == 60)
    }

    @Test func draggingTheControlPointBendsTheArrow() {
        let arrow = object(.arrow(ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), control: CGPoint(x: 50, y: 10), style: .curved)))
        let dragged = ObjectGeometry.dragging(.control, of: arrow, to: CGPoint(x: 40, y: 60), constrained: false)
        #expect(dragged.kind == .arrow(ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), control: CGPoint(x: 40, y: 60), style: .curved)))
    }

    @Test(arguments: [TextStyle.standard, .box])
    func textWidthNeverShrinksBelowItsPaddingAndFontSize(style: TextStyle) {
        let minimum = Double(2 * TextLayout.padding(for: style, fontSize: 48).width + 48)
        let text = object(.text(TextObject(origin: CGPoint(x: 10, y: 10), width: 200, string: "Hello there", style: style, fontSize: 48)))
        let right = ObjectGeometry.dragging(.edge(.right), of: text, to: CGPoint(x: 11, y: 0), constrained: false)
        guard case .text(let rightResult) = right.kind else { Issue.record("not text"); return }
        #expect(rightResult.width == minimum)
        let left = ObjectGeometry.dragging(.edge(.left), of: text, to: CGPoint(x: 400, y: 0), constrained: false)
        guard case .text(let leftResult) = left.kind else { Issue.record("not text"); return }
        #expect(leftResult.width == minimum)
        #expect(leftResult.origin.x + minimum == 210)
    }
}

struct RectHandleTests {
    let rect = CGRect(x: 10, y: 10, width: 100, height: 50)

    @Test func everyHandleSitsWhereItsNameSays() {
        let box = CGRect(x: 10, y: 20, width: 100, height: 50)
        let points: [(Handle, CGPoint)] = [
            (.corner(.topLeft), CGPoint(x: 10, y: 20)), (.corner(.topRight), CGPoint(x: 110, y: 20)),
            (.corner(.bottomLeft), CGPoint(x: 10, y: 70)), (.corner(.bottomRight), CGPoint(x: 110, y: 70)),
            (.edge(.top), CGPoint(x: 60, y: 20)), (.edge(.bottom), CGPoint(x: 60, y: 70)),
            (.edge(.left), CGPoint(x: 10, y: 45)), (.edge(.right), CGPoint(x: 110, y: 45)),
            // The handles a rect doesn't have fall back to its middle.
            (.start, CGPoint(x: 60, y: 45)), (.end, CGPoint(x: 60, y: 45)), (.control, CGPoint(x: 60, y: 45)),
        ]
        for (handle, point) in points {
            #expect(ObjectGeometry.point(of: handle, in: box) == point, "\(handle)")
        }
    }

    @Test func aFreeDragMovesOnlyTheHandlesSide() {
        let drags: [(Handle, CGPoint, CGRect)] = [
            (.corner(.topLeft), CGPoint(x: 0, y: 0), CGRect(x: 0, y: 0, width: 110, height: 60)),
            (.corner(.topRight), CGPoint(x: 130, y: 0), CGRect(x: 10, y: 0, width: 120, height: 60)),
            (.corner(.bottomLeft), CGPoint(x: 0, y: 90), CGRect(x: 0, y: 10, width: 110, height: 80)),
            (.corner(.bottomRight), CGPoint(x: 150, y: 90), CGRect(x: 10, y: 10, width: 140, height: 80)),
            (.edge(.top), CGPoint(x: 99, y: 0), CGRect(x: 10, y: 0, width: 100, height: 60)),
            (.edge(.bottom), CGPoint(x: 99, y: 90), CGRect(x: 10, y: 10, width: 100, height: 80)),
            (.edge(.left), CGPoint(x: 0, y: 99), CGRect(x: 0, y: 10, width: 110, height: 50)),
            (.edge(.right), CGPoint(x: 130, y: 99), CGRect(x: 10, y: 10, width: 120, height: 50)),
        ]
        for (handle, point, expected) in drags {
            #expect(ObjectGeometry.resized(rect, handle: handle, to: point, aspect: nil) == expected, "\(handle)")
        }
    }

    @Test func aRatioCornerDragKeepsTheOppositeCornerAndTheLargerPullWins() {
        let drags: [(Corner, CGPoint, CGRect)] = [
            (.topLeft, CGPoint(x: 0, y: 0), CGRect(x: -10, y: 0, width: 120, height: 60)),
            (.topRight, CGPoint(x: 130, y: 0), CGRect(x: 10, y: 0, width: 120, height: 60)),
            (.bottomLeft, CGPoint(x: 0, y: 90), CGRect(x: -50, y: 10, width: 160, height: 80)),
            (.bottomRight, CGPoint(x: 150, y: 90), CGRect(x: 10, y: 10, width: 160, height: 80)),
        ]
        for (corner, point, expected) in drags {
            #expect(ObjectGeometry.resized(rect, handle: .corner(corner), to: point, aspect: 2) == expected, "\(corner)")
        }
    }

    @Test func aRatioEdgeDragGrowsTheOtherSideAboutTheMiddle() {
        let drags: [(RectEdge, CGPoint, CGRect)] = [
            (.right, CGPoint(x: 130, y: 0), CGRect(x: 10, y: 5, width: 120, height: 60)),
            (.left, CGPoint(x: -90, y: 0), CGRect(x: -90, y: -15, width: 200, height: 100)),
            (.bottom, CGPoint(x: 0, y: 110), CGRect(x: -40, y: 10, width: 200, height: 100)),
            (.top, CGPoint(x: 0, y: -40), CGRect(x: -40, y: -40, width: 200, height: 100)),
        ]
        for (edge, point, expected) in drags {
            #expect(ObjectGeometry.resized(rect, handle: .edge(edge), to: point, aspect: 2) == expected, "\(edge)")
        }
        // Past the opposite side it flips, keeping the ratio.
        #expect(ObjectGeometry.resized(rect, handle: .edge(.right), to: CGPoint(x: -20, y: 0), aspect: 2)
            == CGRect(x: -20, y: 27.5, width: 30, height: 15))
    }

    @Test func aDragPastTheOppositeSideStandardizesTheRect() {
        // `CGRect ==` treats a flipped rect as equal to its standardized self, so the stored origin and size are checked.
        let corner = ObjectGeometry.resized(rect, handle: .corner(.bottomRight), to: CGPoint(x: 0, y: 0), aspect: nil)
        #expect(corner.origin == CGPoint(x: 0, y: 0))
        #expect(corner.size == CGSize(width: 10, height: 10))
        let ratioCorner = ObjectGeometry.resized(rect, handle: .corner(.bottomRight), to: CGPoint(x: 0, y: 0), aspect: 2)
        #expect(ratioCorner.origin == CGPoint(x: -10, y: 0))
        #expect(ratioCorner.size == CGSize(width: 20, height: 10))
        let edge = ObjectGeometry.resized(rect, handle: .edge(.right), to: CGPoint(x: -20, y: 0), aspect: nil)
        #expect(edge.origin == CGPoint(x: -20, y: 10))
        #expect(edge.size == CGSize(width: 30, height: 50))
        let ratioEdge = ObjectGeometry.resized(rect, handle: .edge(.right), to: CGPoint(x: -20, y: 0), aspect: 2)
        #expect(ratioEdge.origin == CGPoint(x: -20, y: 27.5))
        #expect(ratioEdge.size == CGSize(width: 30, height: 15))
    }

    @Test func anAspectThatIsNoRatioDragsFreely() {
        for aspect in [0, -2, .nan, .infinity, -.infinity] as [Double] {
            #expect(ObjectGeometry.resized(rect, handle: .corner(.bottomRight), to: CGPoint(x: 150, y: 90), aspect: aspect)
                == CGRect(x: 10, y: 10, width: 140, height: 80), "corner, aspect \(aspect)")
            #expect(ObjectGeometry.resized(rect, handle: .edge(.bottom), to: CGPoint(x: 0, y: 110), aspect: aspect)
                == CGRect(x: 10, y: 10, width: 100, height: 100), "edge, aspect \(aspect)")
        }
    }

    @Test func theHandlesAnObjectDoesntHaveLeaveItsRectAlone() {
        #expect(ObjectGeometry.resized(rect, handle: .start, to: CGPoint(x: 150, y: 90), aspect: 2) == rect)
    }
}

struct ArrowGeometryTests {
    @Test func aStandardArrowHasOneHeadAtItsEnd() {
        let parts = ArrowGeometry.parts(for: ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), style: .standard), width: 4)
        #expect(parts.fills.count == 1)
        let head = parts.fills[0].boundingBoxOfPath
        #expect(abs(head.maxX - 100) < 0.001)
        #expect(abs(head.minX - (100 - ArrowGeometry.headLength(for: 4))) < 0.001)
        #expect(parts.shaft.currentPoint.x < 100)
    }

    @Test func doubleArrowsHaveTwoHeads() {
        let parts = ArrowGeometry.parts(for: ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), style: .double), width: 4)
        #expect(parts.fills.count == 2)
        #expect(parts.fills.contains { abs($0.boundingBoxOfPath.minX) < 0.001 })
    }

    @Test func curvedArrowHeadsFollowTheCurve() {
        let shape = ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), control: CGPoint(x: 100, y: -100), style: .curved)
        let head = ArrowGeometry.parts(for: shape, width: 4).fills[0].boundingBoxOfPath
        // Arriving from straight above, the head is taller than it is wide.
        #expect(head.height > head.width)
        let spine = ArrowGeometry.spine(of: shape)
        #expect(spine.first == .zero)
        #expect(spine.last == CGPoint(x: 100, y: 0))
        #expect(spine.count == 25)
    }

    @Test func fancyArrowsAreOneFilledShapeFromStartToTip() {
        let parts = ArrowGeometry.parts(for: ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), style: .fancy), width: 6)
        #expect(parts.fills.count == 1)
        let box = parts.fills[0].boundingBoxOfPath
        #expect(abs(box.minX) < 0.001)
        #expect(abs(box.maxX - 100) < 0.001)
    }

    @Test func zeroLengthArrowsDrawNothing() {
        let parts = ArrowGeometry.parts(for: ArrowShape(start: CGPoint(x: 5, y: 5), end: CGPoint(x: 5, y: 5), style: .standard), width: 4)
        #expect(parts.fills.isEmpty)
    }

    @Test func aShortArrowKeepsItsHeadInsideItsLength() {
        let parts = ArrowGeometry.parts(for: ArrowShape(start: .zero, end: CGPoint(x: 20, y: 0), style: .standard), width: 10)
        let head = parts.fills[0].boundingBoxOfPath
        #expect(head.minX >= 0)
        #expect(abs(head.maxX - 20) < 0.001)
        if !parts.shaft.isEmpty {
            let shaft = parts.shaft.boundingBoxOfPath
            #expect(shaft.minX >= 0)
            #expect(shaft.maxX <= 20)
        }
    }

    @Test func aShortDoubleArrowsHeadsDontOverlap() {
        let parts = ArrowGeometry.parts(for: ArrowShape(start: .zero, end: CGPoint(x: 50, y: 0), style: .double), width: 10)
        #expect(parts.fills.count == 2)
        let heads = parts.fills.map(\.boundingBoxOfPath).sorted { $0.minX < $1.minX }
        #expect(heads[0].maxX <= heads[1].minX + 0.001)
        if !parts.shaft.isEmpty {
            let shaft = parts.shaft.boundingBoxOfPath
            #expect(shaft.minX >= heads[0].maxX - 0.001)
            #expect(shaft.maxX <= heads[1].minX + 0.001)
        }
    }

    @Test func aShaftNeverRunsBackwardsWhateverTheLength() {
        for length in stride(from: 1.0, through: 80.0, by: 3.0) {
            for style in [ArrowStyle.standard, .double] {
                let parts = ArrowGeometry.parts(for: ArrowShape(start: .zero, end: CGPoint(x: length, y: 0), style: style), width: 8)
                guard !parts.shaft.isEmpty else { continue }
                let shaft = parts.shaft.boundingBoxOfPath
                #expect(shaft.minX >= -0.001 && shaft.maxX <= length + 0.001)
                #expect(shaft.width >= 0)
            }
        }
    }

    @Test func aCurvedShaftNeverOvershootsItsControlPoint() {
        // The control point is closer to the tip than the usual set-back; the shaft stops at it instead of hooking past it.
        let shape = ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), control: CGPoint(x: 100, y: -10), style: .curved)
        let shaft = ArrowGeometry.parts(for: shape, width: 10).shaft
        let tip = shape.end
        let reach = hypot(shaft.currentPoint.x - tip.x, shaft.currentPoint.y - tip.y)
        #expect(reach <= 10.001)
    }

    @Test func aCurvedArrowWhoseControlSitsOnItsEndPointsAlongTheChord() {
        let across = ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), control: CGPoint(x: 100, y: 0), style: .curved)
        let acrossHead = ArrowGeometry.parts(for: across, width: 4).fills[0].boundingBoxOfPath
        #expect(acrossHead.width > acrossHead.height)
        let down = ArrowShape(start: .zero, end: CGPoint(x: 0, y: 100), control: CGPoint(x: 0, y: 100), style: .curved)
        let downParts = ArrowGeometry.parts(for: down, width: 4)
        let downHead = downParts.fills[0].boundingBoxOfPath
        #expect(downHead.height > downHead.width)
        #expect(downParts.shaft.currentPoint.y < 100 - ArrowGeometry.headLength(for: 4) + 0.001)
    }
}

struct StrokeAndConstraintTests {
    @Test func simplifyingDropsClosePointsButKeepsTheEnd() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 3, y: 0), CGPoint(x: 3.2, y: 0)]
        #expect(StrokeSmoothing.simplified(points, minimumDistance: 2) == [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 0), CGPoint(x: 3.2, y: 0)])
    }

    @Test(arguments: [false, true])
    func pathsEndAtTheLastPoint(smoothed: Bool) {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 5), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 8)]
        #expect(StrokeSmoothing.path(through: points, smoothed: smoothed).currentPoint == CGPoint(x: 30, y: 8))
    }

    @Test func aSinglePointIsADot() {
        #expect(!StrokeSmoothing.path(through: [CGPoint(x: 4, y: 4)], smoothed: true).isEmpty)
    }

    @Test func squareRectsKeepTheDragDirection() {
        #expect(ShapeConstraints.rect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 20, y: 60), square: true)
            == CGRect(x: 20, y: 50, width: 30, height: 30))
        #expect(ShapeConstraints.rect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 20, y: 60), square: false)
            == CGRect(x: 0, y: 0, width: 20, height: 60))
    }

    @Test func snappingRoundsToTheNearest45Degrees() {
        let flat = ShapeConstraints.snapped(CGPoint(x: 100, y: 10), from: .zero)
        #expect(abs(flat.y) < 0.0001)
        let diagonal = ShapeConstraints.snapped(CGPoint(x: 100, y: 90), from: .zero)
        #expect(abs(diagonal.x - diagonal.y) < 0.0001)
    }

    @Test func axisLockKeepsTheDominantAxis() {
        #expect(ShapeConstraints.axisLocked(CGVector(dx: 10, dy: 3)) == CGVector(dx: 10, dy: 0))
        #expect(ShapeConstraints.axisLocked(CGVector(dx: -2, dy: -9)) == CGVector(dx: 0, dy: -9))
    }
}

struct TextLayoutTests {
    @Test func autoWidthGrowsWithTheText() {
        let short = TextLayout.frame(of: TextObject(origin: .zero, string: "Hi", style: .standard, fontSize: 20))
        let long = TextLayout.frame(of: TextObject(origin: .zero, string: "Hello, world", style: .standard, fontSize: 20))
        #expect(long.width > short.width)
        #expect(short.height > 15)
    }

    @Test func aFixedWidthWrapsIntoMoreLines() {
        let oneLine = TextLayout.frame(of: TextObject(origin: .zero, string: "one two three four five", style: .standard, fontSize: 20))
        let wrapped = TextLayout.frame(of: TextObject(origin: CGPoint(x: 5, y: 6), width: 60, string: "one two three four five",
                                                      style: .standard, fontSize: 20))
        #expect(wrapped.width == 60)
        #expect(wrapped.origin == CGPoint(x: 5, y: 6))
        #expect(wrapped.height > oneLine.height * 2)
    }

    @Test func boxStylesAddPadding() {
        let plain = TextLayout.frame(of: TextObject(origin: .zero, string: "Box", style: .standard, fontSize: 20))
        let boxed = TextLayout.frame(of: TextObject(origin: .zero, string: "Box", style: .box, fontSize: 20))
        #expect(boxed.width > plain.width)
        #expect(boxed.height > plain.height)
    }

    @Test func emptyTextStillHasAHeight() {
        #expect(TextLayout.frame(of: TextObject(origin: .zero, string: "", style: .standard, fontSize: 20)).height > 0)
    }

    @Test func monoStylesUseAFixedPitchFont() {
        #expect(TextLayout.font(for: .mono, size: 20).isFixedPitch)
        #expect(TextLayout.font(for: .monoBox, size: 20).isFixedPitch)
        #expect(!TextLayout.font(for: .standard, size: 20).isFixedPitch)
    }

    @Test func aTrailingNewlineAddsALine() {
        let plain = TextLayout.frame(of: TextObject(origin: .zero, string: "abc", style: .standard, fontSize: 20))
        let returned = TextLayout.frame(of: TextObject(origin: .zero, string: "abc\n", style: .standard, fontSize: 20))
        #expect(returned.height > plain.height)
        #expect(abs(returned.width - plain.width) < 1)
    }

    @Test func aTrailingSpaceIsMeasured() {
        let plain = TextLayout.frame(of: TextObject(origin: .zero, string: "abc", style: .standard, fontSize: 20))
        let spaced = TextLayout.frame(of: TextObject(origin: .zero, string: "abc ", style: .standard, fontSize: 20))
        #expect(spaced.width > plain.width)
    }

    @Test func aStringOfOnlySpacesStillHasWidth() {
        let blank = TextLayout.frame(of: TextObject(origin: .zero, string: "", style: .standard, fontSize: 20))
        let spaces = TextLayout.frame(of: TextObject(origin: .zero, string: "   ", style: .standard, fontSize: 20))
        #expect(blank.width == 0)
        #expect(spaces.width > blank.width)
        #expect(spaces.height == blank.height)
    }
}

struct HighlightSnappingTests {
    let words = [CGRect(x: 0, y: 100, width: 40, height: 20), CGRect(x: 50, y: 100, width: 40, height: 20),
                 CGRect(x: 100, y: 100, width: 40, height: 20), CGRect(x: 0, y: 200, width: 60, height: 20)]

    @Test func aStrokeAcrossALineCoversTheWordsItTouches() {
        let rects = HighlightSnapping.rects(along: [CGPoint(x: 10, y: 110), CGPoint(x: 70, y: 112)], width: 16, words: words)
        #expect(rects.count == 1)
        #expect(rects[0].minX <= 0)
        #expect(rects[0].maxX >= 90)
        #expect(rects[0].maxX < 100)
    }

    @Test func aStrokeOverNoWordsStaysFreehand() {
        #expect(HighlightSnapping.rects(along: [CGPoint(x: 300, y: 300), CGPoint(x: 350, y: 300)], width: 16, words: words).isEmpty)
    }

    @Test func aDiagonalStrokeCoversEachLineSeparately() {
        let rects = HighlightSnapping.rects(along: [CGPoint(x: 10, y: 110), CGPoint(x: 30, y: 210)], width: 16, words: words)
        #expect(rects.count == 2)
    }

    /// Three lines of 20 px words with a 4 px gap, like tightly set text.
    let tightLines = [0, 24, 48].flatMap { y in
        [0.0, 50, 100].map { CGRect(x: $0, y: Double(y) + 100, width: 40, height: 20) }
    }

    @Test func aStrokeOnOneTightlySpacedLineStaysOnThatLine() {
        let rects = HighlightSnapping.rects(along: [CGPoint(x: 5, y: 110), CGPoint(x: 130, y: 110)], width: 22, words: tightLines)
        #expect(rects.count == 1)
        guard let rect = rects.first else { return }
        #expect(rect.contains(CGPoint(x: 70, y: 110)))
        #expect(rect.maxY < 124)
    }

    @Test func aStrokeSlightlyOffCentreStillPicksOnlyItsLine() {
        let rects = HighlightSnapping.rects(along: [CGPoint(x: 5, y: 115), CGPoint(x: 130, y: 115)], width: 22, words: tightLines)
        #expect(rects.count == 1)
    }

    @Test func aDefaultMarkerOnOrdinaryLeadingStaysOnItsLine() {
        // 13 px words on a 17 px pitch, with the default 22 pt marker.
        let words = [0, 17, 34].map { CGRect(x: 0, y: Double($0), width: 60, height: 13) }
        let rects = HighlightSnapping.rects(along: [CGPoint(x: 2, y: 23.5), CGPoint(x: 58, y: 23.5)], width: 22, words: words)
        #expect(rects.count == 1)
        #expect(rects.first.map { $0.minY > 13 && $0.maxY < 34 } == true)
    }

    @Test func aStrokeThatOnlyGrazesAWordsEdgeStillCountsWithinTolerance() {
        // 3 px above a 20 px tall word: inside the 5 px tolerance (a quarter of the word's height).
        let rects = HighlightSnapping.rects(along: [CGPoint(x: 0, y: 97), CGPoint(x: 30, y: 97)], width: 22, words: words)
        #expect(rects.count == 1)
    }
}

struct FreehandHandleTests {
    @Test func strokesAndHighlightsHaveCornerAndEdgeHandles() {
        let stroke = object(.stroke(StrokeObject(points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 20)], smoothed: false)))
        #expect(ObjectGeometry.handles(of: stroke).count == 8)
        // The handles sit on the painted bounds: the points grown by half the 4-pixel width.
        #expect(ObjectGeometry.handlePoint(.corner(.bottomRight), of: stroke) == CGPoint(x: 32, y: 22))
        let highlight = object(.highlight(HighlightObject(points: [], rects: [CGRect(x: 0, y: 0, width: 20, height: 10)], width: 10,
                                                          opacity: 0.4)))
        #expect(ObjectGeometry.handles(of: highlight).count == 8)
    }

    @Test func draggingACornerScalesTheStrokeAboutTheOppositeCorner() {
        let stroke = object(.stroke(StrokeObject(points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 20)], smoothed: false)))
        let dragged = ObjectGeometry.dragging(.corner(.bottomRight), of: stroke, to: CGPoint(x: 52, y: 42), constrained: false)
        guard case .stroke(let result) = dragged.kind else { Issue.record("not a stroke"); return }
        #expect(result.points == [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 40)])
        #expect(dragged.style.lineWidth == 4)
    }

    @Test func shiftKeepsAStrokesProportions() {
        let stroke = object(.stroke(StrokeObject(points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)], smoothed: false)))
        let dragged = ObjectGeometry.dragging(.corner(.bottomRight), of: stroke, to: CGPoint(x: 56, y: 40), constrained: true)
        guard case .stroke(let result) = dragged.kind else { Issue.record("not a stroke"); return }
        #expect(result.points == [CGPoint(x: 10, y: 10), CGPoint(x: 54, y: 54)])
    }

    @Test func snappedHighlightRectsStretchWithTheirBounds() {
        let highlight = object(.highlight(HighlightObject(points: [], rects: [CGRect(x: 0, y: 0, width: 20, height: 10),
                                                                              CGRect(x: 0, y: 14, width: 10, height: 10)],
                                                          width: 10, opacity: 0.4)))
        let dragged = ObjectGeometry.dragging(.edge(.right), of: highlight, to: CGPoint(x: 40, y: 0), constrained: false)
        guard case .highlight(let result) = dragged.kind else { Issue.record("not a highlight"); return }
        #expect(result.rects == [CGRect(x: 0, y: 0, width: 40, height: 10), CGRect(x: 0, y: 14, width: 20, height: 10)])
    }

    @Test func aFreehandHighlightKeepsItsWidth() {
        // Painted bounds: (5, 5, 50, 10), the points grown by half the 10-pixel marker.
        let highlight = object(.highlight(HighlightObject(points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10)], rects: [], width: 10,
                                                          opacity: 0.4)))
        let dragged = ObjectGeometry.dragging(.edge(.right), of: highlight, to: CGPoint(x: 95, y: 0), constrained: false)
        guard case .highlight(let result) = dragged.kind else { Issue.record("not a highlight"); return }
        #expect(result.points == [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 10)])
        #expect(result.width == 10)
    }

    @Test func aMarkWithNoPointsHasNoHandles() {
        let stroke = object(.stroke(StrokeObject(points: [], smoothed: false)))
        let highlight = object(.highlight(HighlightObject(points: [], rects: [], width: 10, opacity: 0.4)))
        for empty in [stroke, highlight] {
            #expect(ObjectGeometry.handles(of: empty).isEmpty)
            // And dragging a handle that isn't there changes nothing.
            #expect(ObjectGeometry.dragging(.corner(.bottomRight), of: empty, to: CGPoint(x: 50, y: 50), constrained: false) == empty)
        }
    }

    @Test func aSingleDotHasNoHandles() {
        let dot = object(.stroke(StrokeObject(points: [CGPoint(x: 10, y: 10)], smoothed: false)))
        let marker = object(.highlight(HighlightObject(points: [CGPoint(x: 10, y: 10)], rects: [], width: 10, opacity: 0.4)))
        let tapped = object(.stroke(StrokeObject(points: [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10)], smoothed: false)))
        for mark in [dot, marker, tapped] {
            #expect(ObjectGeometry.handles(of: mark).isEmpty)
        }
    }

    @Test func aFlatStrokeStretchesOnlyAlongItsLength() {
        let flat = object(.stroke(StrokeObject(points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10)], smoothed: false)))
        #expect(ObjectGeometry.handles(of: flat) == [.edge(.left), .edge(.right)])
        // The painted bounds are (8, 8, 44, 4), so the right handle sits at (52, 10).
        #expect(ObjectGeometry.handlePoint(.edge(.right), of: flat) == CGPoint(x: 52, y: 10))
        for constrained in [false, true] {
            // ⇧ has no proportions to keep on a line: it stretches the same.
            let dragged = ObjectGeometry.dragging(.edge(.right), of: flat, to: CGPoint(x: 92, y: 40), constrained: constrained)
            guard case .stroke(let result) = dragged.kind else { Issue.record("not a stroke"); return }
            #expect(result.points == [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 10)], "constrained: \(constrained)")
        }
        // The handles it doesn't have do nothing.
        #expect(ObjectGeometry.dragging(.edge(.top), of: flat, to: CGPoint(x: 30, y: 60), constrained: false) == flat)
        #expect(ObjectGeometry.dragging(.corner(.bottomRight), of: flat, to: CGPoint(x: 90, y: 60), constrained: false) == flat)
    }

    @Test func aStraightUpAndDownStrokeStretchesOnlyAlongItsLength() {
        let upright = object(.stroke(StrokeObject(points: [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 50)], smoothed: false)))
        #expect(ObjectGeometry.handles(of: upright) == [.edge(.top), .edge(.bottom)])
        let dragged = ObjectGeometry.dragging(.edge(.bottom), of: upright, to: CGPoint(x: 70, y: 92), constrained: true)
        guard case .stroke(let result) = dragged.kind else { Issue.record("not a stroke"); return }
        #expect(result.points == [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 90)])
        #expect(ObjectGeometry.dragging(.edge(.left), of: upright, to: CGPoint(x: -30, y: 30), constrained: false) == upright)
    }

    @Test func aFlatHighlightKeepsOnlyTheEdgesAlongItsLength() {
        let flat = object(.highlight(HighlightObject(points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10)], rects: [], width: 10,
                                                     opacity: 0.4)))
        #expect(ObjectGeometry.handles(of: flat) == [.edge(.left), .edge(.right)])
        // A snapped highlight is its word boxes, which have a height: all eight handles.
        let snapped = object(.highlight(HighlightObject(points: [], rects: [CGRect(x: 0, y: 0, width: 20, height: 10)], width: 10,
                                                        opacity: 0.4)))
        #expect(ObjectGeometry.handles(of: snapped).count == 8)
    }
}
