import CoreGraphics
import CSCapture
import CSCore
import CSTestSupport
import Foundation
import Testing
@testable import CSAnnotation

struct RGBAColorTests {
    @Test func parsesSixAndEightDigitHex() throws {
        let red = try #require(RGBAColor(hex: "#FF0000"))
        #expect(red == RGBAColor(red: 1, green: 0, blue: 0))
        let halfBlue = try #require(RGBAColor(hex: "0000ff80"))
        #expect(halfBlue.blue == 1)
        #expect(abs(halfBlue.alpha - 128.0 / 255) < 0.0001)
    }

    @Test func trimsWhitespaceAndNewlinesAroundHex() {
        #expect(RGBAColor(hex: "#FF0000\n") == RGBAColor(red: 1, green: 0, blue: 0))
        #expect(RGBAColor(hex: " \t00ff00 \r\n") == RGBAColor(red: 0, green: 1, blue: 0))
    }

    @Test func rejectsBadHex() {
        #expect(RGBAColor(hex: "#12345") == nil)
        #expect(RGBAColor(hex: "#GG0000") == nil)
        #expect(RGBAColor(hex: "+12345") == nil)
    }

    @Test func threeDigitHexExpands() throws {
        let orange = try #require(RGBAColor(hex: "#F80"))
        #expect(orange == RGBAColor(hex: "#FF8800"))
        #expect(RGBAColor(hex: "0af") == RGBAColor(hex: "#00AAFF"))
        #expect(RGBAColor(hex: " #FfF\n") == .white)
        #expect(RGBAColor(hex: "#F8") == nil)
        #expect(RGBAColor(hex: "#GGG") == nil)
    }

    @Test func hexWithoutAlphaTakesTheDefaultAlpha() throws {
        let sixDigits = try #require(RGBAColor(hex: "#FF8800", defaultAlpha: 0.4))
        #expect(sixDigits == RGBAColor(red: 1, green: 136.0 / 255, blue: 0, alpha: 0.4))
        #expect(RGBAColor(hex: "#F80", defaultAlpha: 0.4)?.alpha == 0.4)
        let eightDigits = try #require(RGBAColor(hex: "#FF8800FF", defaultAlpha: 0.4))
        #expect(eightDigits.alpha == 1)
        #expect(RGBAColor(hex: "#FF8800")?.alpha == 1)
        #expect(RGBAColor(hex: "nope", defaultAlpha: 0.4) == nil)
    }

    @Test func hexRoundTripsAndAddsAlphaOnlyWhenNeeded() {
        #expect(RGBAColor(red: 1, green: 0.5, blue: 0).hex == "#FF8000")
        #expect(RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.5).hex == "#00000080")
    }

    @Test func convertsGrayCGColorsToSRGB() throws {
        // Mid gray is where a missing conversion would show: generic gray 0.5 is about 0.5723 in sRGB.
        let gray = try #require(RGBAColor(CGColor(gray: 0.5, alpha: 1)))
        #expect(abs(gray.red - 0.5723) < 0.01)
        #expect(abs(gray.green - 0.5723) < 0.01)
        #expect(abs(gray.blue - 0.5723) < 0.01)
        #expect(gray.alpha == 1)
    }

    @Test func picksReadableTextColors() {
        #expect(RGBAColor(hex: "#FFCC00")!.contrastingTextColor == .black)
        #expect(RGBAColor(hex: "#FF3B30")!.contrastingTextColor == .white)
        #expect(RGBAColor.white.contrastingTextColor == .black)
        #expect(RGBAColor.black.contrastingTextColor == .white)
    }

    @Test func paletteColorsGetTheReadableTextColor() {
        let black: Set = ["Orange", "Yellow", "Green", "Teal", "White"]
        for named in ColorPalette.standard {
            let expected: RGBAColor = black.contains(named.name) ? .black : .white
            #expect(named.color.contrastingTextColor == expected, "\(named.name)")
        }
    }
}

struct ColorPaletteTests {
    @Test func namesPaletteColorsAndNearbyOnes() {
        let blue = ColorPalette.standard.first { $0.name == "Blue" }!.color
        #expect(ColorPalette.name(for: blue) == "Blue")
        #expect(ColorPalette.name(for: RGBAColor(red: blue.red, green: blue.green + 0.01, blue: blue.blue)) == "Blue")
    }

    @Test func farColorsAreNamedByHex() {
        #expect(ColorPalette.name(for: RGBAColor(red: 0.2, green: 0.4, blue: 0.2)) == "#336633")
    }

    @Test func defaultColorIsRed() {
        #expect(ColorPalette.defaultColor == RGBAColor(hex: "#FF3B30"))
        #expect(ColorPalette.standard.count == 13)
    }
}

struct DocumentTransformTests {
    let size = CGSize(width: 200, height: 100)

    @Test func noOperationsIsTheIdentity() {
        let t = DocumentTransform(baseSize: size, ops: [])
        #expect(t.outputSize == size)
        #expect(t.toOutput(CGPoint(x: 10, y: 20)) == CGPoint(x: 10, y: 20))
        #expect(t.scale == 1)
    }

    @Test func rotateRightMovesTheTopLeftCornerToTheTopRight() {
        let t = DocumentTransform(baseSize: size, ops: [.rotateRight])
        #expect(t.outputSize == CGSize(width: 100, height: 200))
        #expect(t.toOutput(.zero) == CGPoint(x: 100, y: 0))
        #expect(t.toOutput(CGPoint(x: 200, y: 0)) == CGPoint(x: 100, y: 200))
    }

    @Test func rotateLeftMovesTheTopLeftCornerToTheBottomLeft() {
        let t = DocumentTransform(baseSize: size, ops: [.rotateLeft])
        #expect(t.outputSize == CGSize(width: 100, height: 200))
        #expect(t.toOutput(.zero) == CGPoint(x: 0, y: 200))
        #expect(t.toOutput(CGPoint(x: 200, y: 0)) == CGPoint(x: 0, y: 0))
        #expect(t.toOutput(CGPoint(x: 0, y: 100)) == CGPoint(x: 100, y: 200))
    }

    @Test func rotateRightThenLeftIsTheIdentity() {
        let t = DocumentTransform(baseSize: size, ops: [.rotateRight, .rotateLeft])
        #expect(t.outputSize == size)
        for point in [CGPoint.zero, CGPoint(x: 200, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: 33, y: 44)] {
            #expect(t.toOutput(point) == point)
        }
    }

    @Test func aResizeBelowOnePixelIsSkipped() {
        for ops in [[ImageOp.resize(width: 0, height: 0)], [.resize(width: 0, height: 50)], [.resize(width: 50, height: 0)],
                    [.resize(width: -5, height: 50)]] {
            let t = DocumentTransform(baseSize: size, ops: ops)
            #expect(t.outputSize == size, "\(ops)")
            #expect(t.toOutput(CGPoint(x: 10, y: 20)) == CGPoint(x: 10, y: 20), "\(ops)")
            #expect(t.scale == 1, "\(ops)")
            #expect(t.toBase(CGPoint(x: 10, y: 20)) == CGPoint(x: 10, y: 20), "\(ops)")
        }
        // A skipped resize doesn't disturb the operations around it.
        let around = DocumentTransform(baseSize: size, ops: [.rotateRight, .resize(width: 0, height: 0), .flipHorizontal])
        let without = DocumentTransform(baseSize: size, ops: [.rotateRight, .flipHorizontal])
        #expect(around == without)
    }

    @Test func flipsMirrorTheAxes() {
        #expect(DocumentTransform(baseSize: size, ops: [.flipHorizontal]).toOutput(CGPoint(x: 0, y: 30)) == CGPoint(x: 200, y: 30))
        #expect(DocumentTransform(baseSize: size, ops: [.flipVertical]).toOutput(CGPoint(x: 5, y: 0)) == CGPoint(x: 5, y: 100))
    }

    @Test func resizeScalesAndReportsItsScale() {
        let t = DocumentTransform(baseSize: size, ops: [.resize(width: 400, height: 200)])
        #expect(t.outputSize == CGSize(width: 400, height: 200))
        #expect(t.toOutput(CGPoint(x: 10, y: 10)) == CGPoint(x: 20, y: 20))
        #expect(abs(t.scale - 2) < 0.0001)
    }

    @Test func operationsCompose() {
        let twice = DocumentTransform(baseSize: size, ops: [.rotateRight, .rotateRight])
        let flips = DocumentTransform(baseSize: size, ops: [.flipHorizontal, .flipVertical])
        let point = CGPoint(x: 30, y: 70)
        #expect(twice.outputSize == size)
        #expect(twice.toOutput(point) == flips.toOutput(point))
    }

    @Test func toBaseUndoesToOutput() {
        let t = DocumentTransform(baseSize: size, ops: [.rotateLeft, .resize(width: 50, height: 100), .flipHorizontal])
        let point = CGPoint(x: 33, y: 44)
        let back = t.toBase(t.toOutput(point))
        #expect(abs(back.x - point.x) < 0.001)
        #expect(abs(back.y - point.y) < 0.001)
    }
}

struct CounterLabelTests {
    @Test func numbers() {
        #expect(CounterLabel.text(for: 0, style: .numbers) == "0")
        #expect(CounterLabel.text(for: 12, style: .numbers) == "12")
    }

    @Test func romanNumerals() {
        #expect(CounterLabel.text(for: 4, style: .roman) == "IV")
        #expect(CounterLabel.text(for: 1994, style: .roman) == "MCMXCIV")
        #expect(CounterLabel.text(for: 0, style: .roman) == "0")
    }

    @Test func lettersContinuePastZ() {
        #expect(CounterLabel.text(for: 1, style: .uppercase) == "A")
        #expect(CounterLabel.text(for: 26, style: .uppercase) == "Z")
        #expect(CounterLabel.text(for: 27, style: .uppercase) == "AA")
        #expect(CounterLabel.text(for: 52, style: .uppercase) == "AZ")
        #expect(CounterLabel.text(for: 53, style: .uppercase) == "BA")
        #expect(CounterLabel.text(for: 2, style: .lowercase) == "b")
        #expect(CounterLabel.text(for: 0, style: .lowercase) == "0")
    }
}

struct AnnotationDocumentTests {
    static let style = ObjectStyle(color: .black, lineWidth: 4, shadow: false)

    static func counter(_ value: Int) -> AnnotationObject {
        AnnotationObject(kind: .counter(CounterObject(center: .zero, value: value, style: .numbers, diameter: 30)), style: style)
    }

    static let everyKind: [ObjectKind] = [
        .rectangle(CGRect(x: 1, y: 2, width: 3, height: 4)),
        .filledRectangle(CGRect(x: 5, y: 6, width: 7, height: 8)),
        .ellipse(CGRect(x: 0, y: 0, width: 10, height: 20)),
        .line(start: CGPoint(x: 1, y: 1), end: CGPoint(x: 9, y: 9)),
        .arrow(ArrowShape(start: .zero, end: CGPoint(x: 50, y: 0), control: CGPoint(x: 25, y: 10), style: .curved)),
        .text(TextObject(origin: CGPoint(x: 3, y: 3), width: 120, string: "Hi 👋", style: .roundedBox, fontSize: 24)),
        .redact(RedactObject(rect: CGRect(x: 0, y: 0, width: 40, height: 20), style: .pixelate, intensity: 5)),
        .spotlight(SpotlightObject(rect: CGRect(x: 0, y: 0, width: 40, height: 20), shape: .ellipse, opacity: 0.6)),
        .counter(CounterObject(center: CGPoint(x: 10, y: 10), value: 3, style: .roman, diameter: 32)),
        .stroke(StrokeObject(points: [.zero, CGPoint(x: 4, y: 4)], smoothed: true)),
        .highlight(HighlightObject(points: [.zero, CGPoint(x: 9, y: 0)], rects: [CGRect(x: 0, y: 0, width: 9, height: 3)],
                                   width: 20, opacity: 0.4)),
        .image(ImageObject(rect: CGRect(x: 0, y: 0, width: 8, height: 8), image: ImageRef(name: "images/a.png"))),
    ]

    /// A document with every object kind, image operations, a canvas and a fill, and fixed object ids.
    static func fullDocument() -> AnnotationDocument {
        var document = AnnotationDocument(baseSize: CGSize(width: 800, height: 600), pixelScale: 2)
        document.imageOps = [.rotateRight, .resize(width: 300, height: 400)]
        document.canvasRect = CGRect(x: -10, y: -10, width: 320, height: 420)
        document.canvasFill = .color(RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4))
        document.objects = everyKind.enumerated().map { index, kind in
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            return AnnotationObject(id: id, kind: kind, style: style)
        }
        return document
    }

    /// Version 1 of the format, as `fullDocument()` encoded when it shipped (sorted keys). Saved documents must keep
    /// decoding as the format grows, so don't regenerate this: a failure here means old files would stop opening.
    static let versionOneJSON = #"""
    {"base":{"name":"original.png"},"baseSize":[800,600],"canvasFill":{"color":{"_0":{"alpha":0.4,"blue":0.3,"green":0.2,"red":0.1}}},"canvasRect":[[-10,-10],[320,420]],"imageOps":[{"rotateRight":{}},{"resize":{"height":400,"width":300}}],"objects":[{"id":"00000000-0000-0000-0000-000000000001","kind":{"rectangle":{"_0":[[1,2],[3,4]]}},"style":{"color":{"alpha":1,"blue":0,"green":0,"red":0},"lineWidth":4,"shadow":false}},{"id":"00000000-0000-0000-0000-000000000002","kind":{"filledRectangle":{"_0":[[5,6],[7,8]]}},"style":{"color":{"alpha":1,"blue":0,"green":0,"red":0},"lineWidth":4,"shadow":false}},{"id":"00000000-0000-0000-0000-000000000003","kind":{"ellipse":{"_0":[[0,0],[10,20]]}},"style":{"color":{"alpha":1,"blue":0,"green":0,"red":0},"lineWidth":4,"shadow":false}},{"id":"00000000-0000-0000-0000-000000000004","kind":{"line":{"end":[9,9],"start":[1,1]}},"style":{"color":{"alpha":1,"blue":0,"green":0,"red":0},"lineWidth":4,"shadow":false}},{"id":"00000000-0000-0000-0000-000000000005","kind":{"arrow":{"_0":{"control":[25,10],"end":[50,0],"start":[0,0],"style":"curved"}}},"style":{"color":{"alpha":1,"blue":0,"green":0,"red":0},"lineWidth":4,"shadow":false}},{"id":"00000000-0000-0000-0000-000000000006","kind":{"text":{"_0":{"fontSize":24,"origin":[3,3],"string":"Hi 👋","style":"roundedBox","width":120}}},"style":{"color":{"alpha":1,"blue":0,"green":0,"red":0},"lineWidth":4,"shadow":false}},{"id":"00000000-0000-0000-0000-000000000007","kind":{"redact":{"_0":{"intensity":5,"rect":[[0,0],[40,20]],"style":"pixelate"}}},"style":{"color":{"alpha":1,"blue":0,"green":0,"red":0},"lineWidth":4,"shadow":false}},{"id":"00000000-0000-0000-0000-000000000008","kind":{"spotlight":{"_0":{"opacity":0.6,"rect":[[0,0],[40,20]],"shape":"ellipse"}}},"style":{"color":{"alpha":1,"blue":0,"green":0,"red":0},"lineWidth":4,"shadow":false}},{"id":"00000000-0000-0000-0000-000000000009","kind":{"counter":{"_0":{"center":[10,10],"diameter":32,"style":"roman","value":3}}},"style":{"color":{"alpha":1,"blue":0,"green":0,"red":0},"lineWidth":4,"shadow":false}},{"id":"00000000-0000-0000-0000-000000000010","kind":{"stroke":{"_0":{"points":[[0,0],[4,4]],"smoothed":true}}},"style":{"color":{"alpha":1,"blue":0,"green":0,"red":0},"lineWidth":4,"shadow":false}},{"id":"00000000-0000-0000-0000-000000000011","kind":{"highlight":{"_0":{"opacity":0.4,"points":[[0,0],[9,0]],"rects":[[[0,0],[9,3]]],"width":20}}},"style":{"color":{"alpha":1,"blue":0,"green":0,"red":0},"lineWidth":4,"shadow":false}},{"id":"00000000-0000-0000-0000-000000000012","kind":{"image":{"_0":{"image":{"name":"images\/a.png"},"rect":[[0,0],[8,8]]}}},"style":{"color":{"alpha":1,"blue":0,"green":0,"red":0},"lineWidth":4,"shadow":false}}],"pixelScale":2,"version":1}
    """#

    @Test func roundTripsEveryObjectKindThroughJSON() throws {
        let document = Self.fullDocument()
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: data)
        #expect(decoded == document)
        #expect(decoded.version == AnnotationDocument.currentVersion)
    }

    @Test func decodesTheCheckedInVersionOneDocument() throws {
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: Data(Self.versionOneJSON.utf8))
        #expect(decoded == Self.fullDocument())
        #expect(decoded.objects.count == Self.everyKind.count)
    }

    @Test func savingAnOldDocumentStampsTheCurrentVersion() throws {
        // A file from an older format, saved again, is in today's format: an older build must then refuse it rather than
        // drop the fields it doesn't know and save over them.
        let old = Self.versionOneJSON.replacingOccurrences(of: #""version":1"#, with: #""version":0"#)
        #expect(old != Self.versionOneJSON)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: Data(old.utf8))
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(saved["version"] as? Int == AnnotationDocument.currentVersion)
        // Nothing else changes.
        #expect(try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(decoded)) == Self.fullDocument())
    }

    @Test func aDocumentMissingNewerOptionalFieldsDecodes() throws {
        let json = #"{"baseSize":[640,480],"pixelScale":2}"#
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: Data(json.utf8))
        #expect(decoded == AnnotationDocument(baseSize: CGSize(width: 640, height: 480), pixelScale: 2))
        #expect(decoded.version == AnnotationDocument.currentVersion)
        #expect(decoded.base == .original)
        #expect(decoded.imageOps.isEmpty)
        #expect(decoded.canvasRect == nil)
        #expect(decoded.canvasFill == .auto)
        #expect(decoded.objects.isEmpty)
    }

    @Test func aDocumentWithoutItsSizeDoesNotDecode() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AnnotationDocument.self, from: Data(#"{"pixelScale":2}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AnnotationDocument.self, from: Data(#"{"baseSize":[640,480]}"#.utf8))
        }
    }

    @Test func anObjectStyleWithoutAShadowDecodesWithoutOne() throws {
        let json = #"{"color":{"red":1,"green":0,"blue":0,"alpha":1},"lineWidth":3}"#
        let decoded = try JSONDecoder().decode(ObjectStyle.self, from: Data(json.utf8))
        #expect(decoded == ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 3, shadow: false))
    }

    @Test func canvasBoundsDefaultToTheTransformedImage() {
        var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        document.imageOps = [.rotateLeft]
        #expect(document.canvasBounds == CGRect(x: 0, y: 0, width: 100, height: 200))
        document.canvasRect = CGRect(x: -5, y: 0, width: 50, height: 50)
        #expect(document.canvasBounds == CGRect(x: -5, y: 0, width: 50, height: 50))
    }

    @Test func countersDrawLast() {
        var document = AnnotationDocument(baseSize: CGSize(width: 10, height: 10), pixelScale: 1)
        let rectangle = AnnotationObject(kind: .rectangle(.zero), style: Self.style)
        let counter = Self.counter(1)
        let line = AnnotationObject(kind: .line(start: .zero, end: .zero), style: Self.style)
        document.objects = [counter, rectangle, line]
        #expect(document.visualOrder.map(\.id) == [rectangle.id, line.id, counter.id])
    }

    @Test func visualOrderMatchesTheRenderer() {
        // The renderer draws redactions, then the spotlights' dimming, then everything else in creation order, then the
        // counters; clicks look for objects in the reverse of that.
        var document = AnnotationDocument(baseSize: CGSize(width: 100, height: 100), pixelScale: 1)
        let counter = Self.counter(1)
        let rectangle = AnnotationObject(kind: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)), style: Self.style)
        let spotlight = AnnotationObject(kind: .spotlight(SpotlightObject(rect: CGRect(x: 0, y: 0, width: 50, height: 50),
                                                                          shape: .rectangle, opacity: 0.6)), style: Self.style)
        let redaction = AnnotationObject(kind: .redact(RedactObject(rect: CGRect(x: 0, y: 0, width: 20, height: 20), style: .blackOut,
                                                                    intensity: 5)), style: Self.style)
        document.objects = [counter, rectangle, spotlight, redaction]
        #expect(document.visualOrder.map(\.id) == [redaction.id, spotlight.id, rectangle.id, counter.id])
    }

    @Test func nextCounterValueFollowsTheHighest() {
        var document = AnnotationDocument(baseSize: CGSize(width: 10, height: 10), pixelScale: 1)
        #expect(document.nextCounterValue(start: 0) == 0)
        document.objects = [Self.counter(3), Self.counter(1)]
        #expect(document.nextCounterValue(start: 0) == 4)
    }

    @Test func counterValuesSaturate() {
        // A document we didn't write can hold any value; the next counter mustn't overflow.
        var document = AnnotationDocument(baseSize: CGSize(width: 10, height: 10), pixelScale: 1)
        document.objects = [Self.counter(Int.max)]
        #expect(document.nextCounterValue(start: 1) == Int.max)
    }

    @Test func nonFiniteGeometryIsRejected() {
        let nan = Double.nan, infinity = Double.infinity
        let broken: [ObjectKind] = [
            .rectangle(CGRect(x: nan, y: 0, width: 10, height: 10)),
            .filledRectangle(CGRect(x: 0, y: 0, width: infinity, height: 10)),
            .ellipse(CGRect(x: 0, y: -infinity, width: 10, height: 10)),
            .line(start: CGPoint(x: 0, y: nan), end: .zero),
            .arrow(ArrowShape(start: .zero, end: CGPoint(x: 10, y: 0), control: CGPoint(x: nan, y: 0), style: .curved)),
            .text(TextObject(origin: .zero, width: infinity, string: "Hi", style: .standard, fontSize: 20)),
            .text(TextObject(origin: .zero, string: "Hi", style: .standard, fontSize: nan)),
            .redact(RedactObject(rect: CGRect(x: 0, y: 0, width: nan, height: 10), style: .pixelate, intensity: 5)),
            .spotlight(SpotlightObject(rect: CGRect(x: 0, y: 0, width: 10, height: 10), shape: .ellipse, opacity: nan)),
            .counter(CounterObject(center: .zero, value: 1, style: .numbers, diameter: infinity)),
            .stroke(StrokeObject(points: [.zero, CGPoint(x: nan, y: 1)], smoothed: true)),
            .highlight(HighlightObject(points: [], rects: [CGRect(x: 0, y: 0, width: 9, height: nan)], width: 20, opacity: 0.4)),
            .highlight(HighlightObject(points: [.zero], rects: [], width: infinity, opacity: 0.4)),
            .image(ImageObject(rect: CGRect(x: 0, y: infinity, width: 8, height: 8), image: ImageRef(name: "images/a.png"))),
        ]
        for kind in broken {
            let object = AnnotationObject(kind: kind, style: Self.style)
            #expect(!object.isFinite, "\(kind)")
            var document = AnnotationDocument(baseSize: CGSize(width: 100, height: 100), pixelScale: 1)
            document.objects = [object]
            #expect(!document.isWellFormed, "\(kind)")
        }
        // A non-finite line width or color is no better.
        var wide = AnnotationObject(kind: .line(start: .zero, end: CGPoint(x: 5, y: 5)), style: Self.style)
        wide.style.lineWidth = nan
        #expect(!wide.isFinite)
        wide.style = ObjectStyle(color: RGBAColor(red: infinity, green: 0, blue: 0), lineWidth: 4, shadow: false)
        #expect(!wide.isFinite)
        // Every kind with ordinary numbers is fine, and so is the whole document.
        let everyKindIsFinite = Self.fullDocument().objects.allSatisfy(\.isFinite)
        #expect(everyKindIsFinite)
        #expect(Self.fullDocument().isWellFormed)
    }

    @Test func aDocumentsNumbersMustBeOnesTheEditorCanShow() {
        let fine = AnnotationDocument(baseSize: CGSize(width: 640, height: 480), pixelScale: 2)
        #expect(fine.isWellFormed)
        for (size, scale) in [(CGSize(width: 640, height: 480), 0.0), (CGSize(width: 640, height: 480), -1), (CGSize(width: 640, height: 480), .nan),
                              (CGSize(width: 640, height: 480), 16.01), (CGSize(width: 0, height: 480), 2), (CGSize(width: 640, height: -1), 2),
                              (CGSize(width: Double.infinity, height: 480), 2), (CGSize(width: 32_769, height: 480), 2)] {
            #expect(!AnnotationDocument(baseSize: size, pixelScale: scale).isWellFormed, "\(size) at \(scale)")
        }
        #expect(AnnotationDocument(baseSize: CGSize(width: 32_768, height: 1), pixelScale: 16).isWellFormed)
        // The canvas the editor shows, in pixels or in points, has the same limit.
        var wide = fine
        wide.canvasRect = CGRect(x: 0, y: 0, width: 40_000, height: 480)
        #expect(!wide.isWellFormed)
        wide.canvasRect = CGRect(x: 0, y: 0, width: Double.nan, height: 480)
        #expect(!wide.isWellFormed)
        var enlarged = fine
        enlarged.imageOps = [.resize(width: 1_000_000, height: 480)]
        #expect(!enlarged.isWellFormed)
        let tinyScale = AnnotationDocument(baseSize: CGSize(width: 640, height: 480), pixelScale: 0.001)
        #expect(!tinyScale.isWellFormed)
    }

    @Test func pointSizesBecomeBasePixels() {
        var document = AnnotationDocument(baseSize: CGSize(width: 100, height: 100), pixelScale: 2)
        #expect(document.pixels(fromPoints: 3) == 6)
        document.imageOps = [.resize(width: 50, height: 50)]
        #expect(abs(document.pixels(fromPoints: 3) - 12) < 0.0001)
    }

    @Test func applyingAnOperationMovesAnExplicitCanvasWithThePicture() {
        var document = AnnotationDocument(baseSize: CGSize(width: 40, height: 40), pixelScale: 1)
        document.canvasRect = CGRect(x: -10, y: 0, width: 60, height: 40)
        let rotated = document.applying(.rotateRight)
        #expect(rotated.imageOps == [.rotateRight])
        #expect(rotated.canvasRect == CGRect(x: 0, y: -10, width: 40, height: 60))
        let plain = AnnotationDocument(baseSize: CGSize(width: 40, height: 20), pixelScale: 1).applying(.resize(width: 20, height: 10))
        #expect(plain.canvasRect == nil)
        #expect(plain.canvasBounds == CGRect(x: 0, y: 0, width: 20, height: 10))
    }
}

/// The Quick Access menu's changes, as the image operation an annotated capture records.
struct ImageOpMappingTests {
    @Test func rotateAndFlipMapDirectly() {
        let document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 2)
        #expect(document.imageOp(for: .rotateLeft, itemScale: 2) == .rotateLeft)
        #expect(document.imageOp(for: .flipHorizontal, itemScale: 2) == .flipHorizontal)
    }

    @Test func scaleTo1xHalvesARetinaOutput() {
        let retina = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 2)
        #expect(retina.imageOp(for: .scaleTo1x, itemScale: 2) == .resize(width: 100, height: 50))
        // The output is what is divided, so a rotation before it counts.
        let rotated = retina.applying(.rotateLeft)
        #expect(rotated.imageOp(for: .scaleTo1x, itemScale: 2) == .resize(width: 50, height: 100))
        // A 1x picture keeps its size.
        #expect(retina.imageOp(for: .scaleTo1x, itemScale: 1) == .resize(width: 200, height: 100))
    }

    @Test func resizeKeepsTheRequestedOutputSizeWithAnExplicitCanvas() {
        // The canvas reaches 25 px past the picture on each side; the dialog names the canvas's size, 150 by 50.
        var document = AnnotationDocument(baseSize: CGSize(width: 100, height: 50), pixelScale: 1)
        document.canvasRect = CGRect(x: -25, y: 0, width: 150, height: 50)
        let op = document.imageOp(for: .resize(width: 75, height: 25), itemScale: 1)
        #expect(op == .resize(width: 50, height: 25))
        let resized = document.applying(op)
        #expect(abs(resized.canvasBounds.width - 75) <= 1)
        #expect(abs(resized.canvasBounds.height - 25) <= 1)
        // Odd ratios still land within a pixel.
        let odd = document.applying(document.imageOp(for: .resize(width: 111, height: 37), itemScale: 1))
        #expect(abs(odd.canvasBounds.width - 111) <= 1)
        #expect(abs(odd.canvasBounds.height - 37) <= 1)
    }

    @Test func resizeWithoutAnExplicitCanvasIsTheRequestedSize() {
        let document = AnnotationDocument(baseSize: CGSize(width: 100, height: 50), pixelScale: 2).applying(.rotateRight)
        #expect(document.imageOp(for: .resize(width: 40, height: 80), itemScale: 2) == .resize(width: 40, height: 80))
    }

    @Test func resizeNeverGoesBelowOnePixel() {
        let document = AnnotationDocument(baseSize: CGSize(width: 100, height: 50), pixelScale: 1)
        #expect(document.imageOp(for: .resize(width: 0, height: 0), itemScale: 1) == .resize(width: 1, height: 1))
    }
}

struct ToolSizesTests {
    @Test func levelsAreClamped() {
        #expect(ToolSizes.lineWidth(0) == ToolSizes.lineWidth(1))
        #expect(ToolSizes.lineWidth(9) == ToolSizes.lineWidth(6))
        #expect(ToolSizes.fontSize(1) < ToolSizes.fontSize(6))
        #expect(ToolSizes.counterDiameter(3) == 32)
    }
}

@MainActor
final class AnnotatePrefsTests {
    let throwaway = ThrowawayDefaults("annotate")
    let defaults: UserDefaults
    let prefs: Preferences

    init() {
        defaults = throwaway.defaults
        prefs = Preferences(defaults: defaults)
    }

    @Test func defaultsAreTheDecidedOnes() {
        #expect(!prefs[Prefs.annotateInvertArrows])
        #expect(prefs[Prefs.annotateSmoothDrawing])
        #expect(prefs[Prefs.annotateObjectShadows])
        #expect(prefs[Prefs.annotateAutoExpandCanvas])
        #expect(prefs[Prefs.annotateAlwaysOnTop])
        #expect(prefs[Prefs.annotateShowDockIcon])
        #expect(prefs[Prefs.annotateShowColorNames])
        #expect(prefs[Prefs.annotateRememberBackgroundTool])
        #expect(prefs[Prefs.annotateLastSaveFolder] == "")
        #expect(prefs[Prefs.annotateToolSettings].color == ColorPalette.defaultColor)
        #expect(prefs[Prefs.annotateToolSettings].sizeLevel == 3)
        #expect(prefs[Prefs.annotateMyColors].colors.isEmpty)
        #expect(prefs[Prefs.annotateLastSaveFormat] == .png)
    }

    @Test func toolSettingsPersist() {
        var settings = prefs[Prefs.annotateToolSettings]
        settings.arrowStyle = .fancy
        settings.color = RGBAColor(hex: "#007AFF")!
        prefs[Prefs.annotateToolSettings] = settings
        #expect(Preferences(defaults: defaults)[Prefs.annotateToolSettings] == settings)
    }

    @Test func toolSettingsMissingAFieldKeepTheRest() throws {
        let json = #"{"arrowStyle":"fancy","sizeLevel":5,"color":{"red":0,"green":0.5,"blue":1,"alpha":1}}"#
        let decoded = try JSONDecoder().decode(AnnotateToolSettings.self, from: Data(json.utf8))
        #expect(decoded.arrowStyle == .fancy)
        #expect(decoded.sizeLevel == 5)
        #expect(decoded.color == RGBAColor(red: 0, green: 0.5, blue: 1))
        // Everything the stored value lacks takes today's default.
        #expect(decoded.smartHighlighter)
        #expect(decoded.textStyle == .standard)
        #expect(decoded.redactIntensity == 5)
        #expect(decoded.counterStart == 1)
        #expect(decoded.spotlightOpacity == 0.6)

        // Through the preferences store, where a decode failure would silently reset every tool setting.
        defaults.set(Data(json.utf8), forKey: Prefs.annotateToolSettings.name)
        let stored = Preferences(defaults: defaults)[Prefs.annotateToolSettings]
        #expect(stored.arrowStyle == .fancy)
        #expect(stored.sizeLevel == 5)
    }

    @Test func droppingOneStoredFieldLeavesEveryOtherSettingAlone() throws {
        var settings = AnnotateToolSettings()
        settings.arrowStyle = .double
        settings.color = RGBAColor(hex: "#007AFF")!
        settings.sizeLevel = 6
        settings.textStyle = .monoBox
        settings.redactStyle = .blackOut
        settings.redactIntensity = 9
        settings.spotlightShape = .ellipse
        settings.spotlightOpacity = 0.25
        settings.counterStyle = .roman
        settings.counterStart = 0
        settings.highlightOpacity = 0.7
        settings.smartHighlighter = false
        var stored = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(stored.removeValue(forKey: "smartHighlighter") != nil)
        let data = try JSONSerialization.data(withJSONObject: stored)

        var expected = settings
        expected.smartHighlighter = true
        #expect(try JSONDecoder().decode(AnnotateToolSettings.self, from: data) == expected)
    }

    @Test func emptyStoredToolSettingsAreTheDefaults() throws {
        let decoded = try JSONDecoder().decode(AnnotateToolSettings.self, from: Data("{}".utf8))
        #expect(decoded == AnnotateToolSettings())
    }

    @Test func myColorsSurviveAnExtraUnknownField() throws {
        let json = #"{"colors":[{"red":1,"green":0,"blue":0,"alpha":1},{"red":0,"green":1,"blue":0,"alpha":0.5}],"later":1}"#
        let decoded = try JSONDecoder().decode(MyColors.self, from: Data(json.utf8))
        #expect(decoded.colors == [RGBAColor(red: 1, green: 0, blue: 0), RGBAColor(red: 0, green: 1, blue: 0, alpha: 0.5)])

        defaults.set(Data(json.utf8), forKey: Prefs.annotateMyColors.name)
        #expect(Preferences(defaults: defaults)[Prefs.annotateMyColors].colors.count == 2)
    }

    @Test func emptyStoredMyColorsDecodeAsNoColors() throws {
        let decoded = try JSONDecoder().decode(MyColors.self, from: Data("{}".utf8))
        #expect(decoded.colors.isEmpty)
    }

    @Test func addingADuplicateMyColorDoesNothing() {
        let red = RGBAColor(red: 1, green: 0, blue: 0), green = RGBAColor(red: 0, green: 1, blue: 0)
        var saved = MyColors()
        saved.add(red)
        saved.add(green)
        saved.add(red)
        #expect(saved.colors == [red, green])
        saved.add(red.withAlpha(0.5))
        #expect(saved.colors == [red, green, red.withAlpha(0.5)])
    }

    @Test func updatingAMyColorReplacesItInPlace() {
        let red = RGBAColor(red: 1, green: 0, blue: 0), green = RGBAColor(red: 0, green: 1, blue: 0)
        let blue = RGBAColor(red: 0, green: 0, blue: 1)
        var saved = MyColors(colors: [red, green])
        saved.update(at: 1, to: blue)
        #expect(saved.colors == [red, blue])
        saved.update(at: 0, to: red)
        #expect(saved.colors == [red, blue])
    }

    @Test func updatingAMyColorToOneAlreadySavedLeavesOneCopy() {
        let red = RGBAColor(red: 1, green: 0, blue: 0), green = RGBAColor(red: 0, green: 1, blue: 0)
        let blue = RGBAColor(red: 0, green: 0, blue: 1)
        var saved = MyColors(colors: [red, green, blue])
        saved.update(at: 0, to: blue)
        #expect(saved.colors == [blue, green])
        saved.update(at: 1, to: blue)
        #expect(saved.colors == [blue])
    }

    @Test func removingAMyColorDropsIt() {
        let red = RGBAColor(red: 1, green: 0, blue: 0), green = RGBAColor(red: 0, green: 1, blue: 0)
        var saved = MyColors(colors: [red, green])
        saved.remove(at: 0)
        #expect(saved.colors == [green])
        saved.remove(at: 0)
        #expect(saved.colors.isEmpty)
    }

    @Test func outOfRangeMyColorEditsDoNothing() {
        let red = RGBAColor(red: 1, green: 0, blue: 0), green = RGBAColor(red: 0, green: 1, blue: 0)
        var saved = MyColors(colors: [red, green])
        saved.update(at: 2, to: .white)
        saved.update(at: -1, to: .white)
        saved.remove(at: 2)
        saved.remove(at: -1)
        #expect(saved.colors == [red, green])
        var empty = MyColors()
        empty.remove(at: 0)
        empty.update(at: 0, to: .white)
        #expect(empty.colors.isEmpty)
    }

    @Test func saveFormatsHaveTitlesAndExtensions() {
        #expect(AnnotateSaveFormat.allCases.map(\.title) == ["PNG", "JPEG", "HEIC", "WebP", "ClearShot Project"])
        #expect(AnnotateSaveFormat.allCases.map(\.fileExtension) == ["png", "jpg", "heic", "webp", "clearshot"])
        #expect(AnnotateSaveFormat.project.imageFormat == nil)
        #expect(AnnotateSaveFormat.jpeg.imageFormat == .jpeg)
    }

    /// A screenshot's Save As offers the image formats, not the project, and starts on the format Save would use: every
    /// image format has its own Save As format, matched by type rather than by name.
    @Test func everyImageFormatHasItsSaveAsFormat() {
        #expect(AnnotateSaveFormat.imageFormats == [.png, .jpeg, .heic, .webp])
        for format in ImageFormat.allCases {
            #expect(AnnotateSaveFormat(format).imageFormat == format)
        }
    }
}
