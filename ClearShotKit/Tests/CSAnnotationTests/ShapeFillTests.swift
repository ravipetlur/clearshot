import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

private let red = RGBAColor(red: 1, green: 0, blue: 0)
private let blue = RGBAColor(red: 0, green: 0, blue: 1)

private func shape(_ kind: ObjectKind, fillColor: RGBAColor? = nil, fillOpacity: Double = 0) -> AnnotationObject {
    AnnotationObject(kind: kind, style: ObjectStyle(color: red, lineWidth: 4, shadow: false, fillColor: fillColor, fillOpacity: fillOpacity))
}

private func render(_ object: AnnotationObject) throws -> CGImage {
    let (document, images) = TestBitmaps.document(base: TestBitmaps.solid(60, 60, TestBitmaps.white), objects: [object])
    return try #require(Renderer.render(document, images: images))
}

struct ShapeFillModelTests {
    @Test func aStyleSavedBeforeFillsHasNone() throws {
        let json = #"{"color":{"red":1,"green":0,"blue":0,"alpha":1},"lineWidth":4,"shadow":true}"#
        let style = try JSONDecoder().decode(ObjectStyle.self, from: Data(json.utf8))
        #expect(style.fillColor == nil)
        #expect(style.fillOpacity == 0)
        #expect(!style.hasFill)
    }

    @Test func anUnfilledStyleWritesNoFillKeys() throws {
        let data = try JSONEncoder().encode(ObjectStyle(color: red, lineWidth: 4, shadow: false))
        #expect(!String(decoding: data, as: UTF8.self).contains("fill"))
    }

    @Test func aFillRoundTripsThroughJSON() throws {
        let object = shape(.ellipse(CGRect(x: 1, y: 2, width: 30, height: 20)), fillColor: blue, fillOpacity: 0.4)
        let decoded = try JSONDecoder().decode(AnnotationObject.self, from: JSONEncoder().encode(object))
        #expect(decoded == object)
        #expect(decoded.style.fillColor == blue)
        #expect(decoded.style.fillOpacity == 0.4)
        let followsStroke = shape(.rectangle(CGRect(x: 1, y: 2, width: 30, height: 20)), fillOpacity: 1)
        #expect(try JSONDecoder().decode(AnnotationObject.self, from: JSONEncoder().encode(followsStroke)) == followsStroke)
    }

    @Test func anOutOfRangeOpacityIsClamped() throws {
        let json = #"{"color":{"red":1,"green":0,"blue":0,"alpha":1},"lineWidth":4,"fillOpacity":7}"#
        #expect(try JSONDecoder().decode(ObjectStyle.self, from: Data(json.utf8)).fillOpacity == 1)
    }

    @Test func aFilledShapeIsHitInsideItsOutline() {
        let rect = CGRect(x: 10, y: 10, width: 40, height: 40)
        let centre = CGPoint(x: 30, y: 30)
        for kind in [ObjectKind.rectangle(rect), .ellipse(rect)] {
            #expect(!ObjectGeometry.hitTest(shape(kind), at: centre, tolerance: 2))
            #expect(ObjectGeometry.hitTest(shape(kind, fillOpacity: 0.5), at: centre, tolerance: 2))
        }
    }

    @Test func toolSettingsWithoutAFillDecodeUnfilled() throws {
        let settings = try JSONDecoder().decode(AnnotateToolSettings.self, from: Data(#"{"sizeLevel":2}"#.utf8))
        #expect(settings.fillColor == nil)
        #expect(settings.fillOpacity == 0)
        var filled = AnnotateToolSettings()
        filled.fillColor = blue
        filled.fillOpacity = 0.3
        #expect(try JSONDecoder().decode(AnnotateToolSettings.self, from: JSONEncoder().encode(filled)) == filled)
    }
}

struct ShapeFillRenderTests {
    let rect = CGRect(x: 10, y: 10, width: 40, height: 40)
    let white = TestBitmaps.RGBA(r: 255, g: 255, b: 255, a: 255)

    @Test func noFillLeavesTheInsideAlone() throws {
        for kind in [ObjectKind.rectangle(rect), .ellipse(rect)] {
            #expect(TestBitmaps.pixel(try render(shape(kind)), 30, 30) == white)
        }
    }

    @Test func theFillIsItsOwnColor() throws {
        for kind in [ObjectKind.rectangle(rect), .ellipse(rect)] {
            let image = try render(shape(kind, fillColor: blue, fillOpacity: 1))
            #expect(TestBitmaps.pixel(image, 30, 30) == .init(r: 0, g: 0, b: 255, a: 255))
        }
    }

    @Test func withoutAFillColorTheStrokeColorFills() throws {
        let image = try render(shape(.rectangle(rect), fillOpacity: 1))
        #expect(TestBitmaps.pixel(image, 30, 30) == .init(r: 255, g: 0, b: 0, a: 255))
    }

    @Test func aPartialFillBlendsWithThePicture() throws {
        let pixel = TestBitmaps.pixel(try render(shape(.rectangle(rect), fillColor: blue, fillOpacity: 0.5)), 30, 30)
        #expect(abs(Int(pixel.r) - 128) <= 2 && abs(Int(pixel.g) - 128) <= 2 && abs(Int(pixel.b) - 255) <= 2)
    }

    @Test func theStrokeIsDrawnOverTheFill() throws {
        let image = try render(shape(.rectangle(rect), fillColor: blue, fillOpacity: 1))
        // The stroke is 4 wide, inside the rect's edge: its middle is 2 in.
        #expect(TestBitmaps.pixel(image, 12, 30) == .init(r: 255, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(image, 30, 12) == .init(r: 255, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(image, 20, 20) == .init(r: 0, g: 0, b: 255, a: 255))
        #expect(TestBitmaps.pixel(image, 5, 5) == white)
    }
}
