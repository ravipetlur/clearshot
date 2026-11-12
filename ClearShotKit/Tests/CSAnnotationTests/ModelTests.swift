import CoreGraphics
import CSCapture
import CSCore
import CSTestSupport
import Foundation
import Testing
@testable import CSAnnotation

struct RGBAColorTests {
    /// Hex as written, the alpha a hex without one takes (nil to use the initializer without it), and the colour it reads
    /// as, or nil when it is refused: six and eight digits, three that expand, whitespace and newlines around it, bad hex.
    static let hexCases: [(hex: String, defaultAlpha: Double?, color: RGBAColor?)] = [
        ("#FF0000", nil, RGBAColor(red: 1, green: 0, blue: 0)),
        ("0000ff80", nil, RGBAColor(red: 0, green: 0, blue: 1, alpha: 128.0 / 255)),
        ("#FF0000\n", nil, RGBAColor(red: 1, green: 0, blue: 0)),
        (" \t00ff00 \r\n", nil, RGBAColor(red: 0, green: 1, blue: 0)),
        ("#12345", nil, nil),
        ("#GG0000", nil, nil),
        ("+12345", nil, nil),
        ("#F80", nil, RGBAColor(hex: "#FF8800")),
        ("0af", nil, RGBAColor(hex: "#00AAFF")),
        (" #FfF\n", nil, .white),
        ("#F8", nil, nil),
        ("#GGG", nil, nil),
        ("#FF8800", 0.4, RGBAColor(red: 1, green: 136.0 / 255, blue: 0, alpha: 0.4)),
        ("#F80", 0.4, RGBAColor(red: 1, green: 136.0 / 255, blue: 0, alpha: 0.4)),
        ("#FF8800FF", 0.4, RGBAColor(red: 1, green: 136.0 / 255, blue: 0)),
        ("#FF8800", nil, RGBAColor(red: 1, green: 136.0 / 255, blue: 0)),
        ("nope", 0.4, nil),
    ]

    @Test(arguments: hexCases)
    func parsesHex(hex: String, defaultAlpha: Double?, color: RGBAColor?) {
        let parsed = if let defaultAlpha { RGBAColor(hex: hex, defaultAlpha: defaultAlpha) } else { RGBAColor(hex: hex) }
        #expect(parsed == color)
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

    @Test func picksReadableTextColorsIncludingForThePalette() {
        #expect(RGBAColor(hex: "#FFCC00")!.contrastingTextColor == .black)
        #expect(RGBAColor(hex: "#FF3B30")!.contrastingTextColor == .white)
        #expect(RGBAColor.white.contrastingTextColor == .black)
        #expect(RGBAColor.black.contrastingTextColor == .white)
        let black: Set = ["Orange", "Yellow", "Green", "Teal", "White"]
        for named in ColorPalette.standard {
            let expected: RGBAColor = black.contains(named.name) ? .black : .white
            #expect(named.color.contrastingTextColor == expected, "\(named.name)")
        }
    }
}

struct ColorPaletteTests {
    /// A palette colour and one near it go by the colour's name; a colour far from every one goes by its hex.
    @Test func namesPaletteColorsAndNearbyOnesAndFarOnesByHex() {
        let blue = ColorPalette.standard.first { $0.name == "Blue" }!.color
        #expect(ColorPalette.name(for: blue) == "Blue")
        #expect(ColorPalette.name(for: RGBAColor(red: blue.red, green: blue.green + 0.01, blue: blue.blue)) == "Blue")
        #expect(ColorPalette.name(for: RGBAColor(red: 0.2, green: 0.4, blue: 0.2)) == "#336633")
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

    /// Each turn and flip on the 200 × 100 picture: the output's size, and where base points land. A right turn moves the
    /// top-left corner to the top right, a left turn to the bottom left; the flips mirror one axis.
    static let turnsAndFlips: [(op: ImageOp, outputSize: CGSize, moves: [(base: CGPoint, output: CGPoint)])] = [
        (.rotateRight, CGSize(width: 100, height: 200), [(.zero, CGPoint(x: 100, y: 0)), (CGPoint(x: 200, y: 0), CGPoint(x: 100, y: 200))]),
        (.rotateLeft, CGSize(width: 100, height: 200), [(.zero, CGPoint(x: 0, y: 200)), (CGPoint(x: 200, y: 0), .zero),
                                                       (CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 200))]),
        (.flipHorizontal, CGSize(width: 200, height: 100), [(CGPoint(x: 0, y: 30), CGPoint(x: 200, y: 30))]),
        (.flipVertical, CGSize(width: 200, height: 100), [(CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 100))]),
    ]

    @Test func turnsAndFlipsMoveThePicturesPoints() {
        for (op, outputSize, moves) in Self.turnsAndFlips {
            let t = DocumentTransform(baseSize: size, ops: [op])
            #expect(t.outputSize == outputSize, "\(op)")
            for (base, output) in moves {
                #expect(t.toOutput(base) == output, "\(op) \(base)")
            }
        }
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
    /// Numbers, Roman numerals, and letters that continue past Z; zero is "0" in every style.
    @Test(arguments: [
        (0, CounterStyle.numbers, "0"), (12, .numbers, "12"),
        (4, .roman, "IV"), (1994, .roman, "MCMXCIV"), (0, .roman, "0"),
        (1, .uppercase, "A"), (26, .uppercase, "Z"), (27, .uppercase, "AA"), (52, .uppercase, "AZ"), (53, .uppercase, "BA"),
        (2, .lowercase, "b"), (0, .lowercase, "0"),
    ])
    func labels(value: Int, style: CounterStyle, text: String) {
        #expect(CounterLabel.text(for: value, style: style) == text)
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

    @Test func savingAnOldDocumentStampsTheLowestVersionThatHoldsIt() throws {
        // A file from an older format, saved again, is in today's format at the lowest version that holds it: with nothing
        // newer in it, the base version every released build reads.
        let old = Self.versionOneJSON.replacingOccurrences(of: #""version":1"#, with: #""version":0"#)
        #expect(old != Self.versionOneJSON)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: Data(old.utf8))
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(saved["version"] as? Int == AnnotationDocument.baseVersion)
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
        // And nothing stored is no colours.
        #expect(try JSONDecoder().decode(MyColors.self, from: Data("{}".utf8)).colors.isEmpty)
    }

    /// Adding a duplicate does nothing (the same colour at another opacity is no duplicate); updating replaces in place, and
    /// to a colour already saved leaves one copy; removing drops it; and edits out of range do nothing.
    @Test func editingMyColors() {
        let red = RGBAColor(red: 1, green: 0, blue: 0), green = RGBAColor(red: 0, green: 1, blue: 0)
        let blue = RGBAColor(red: 0, green: 0, blue: 1)

        var added = MyColors()
        added.add(red)
        added.add(green)
        added.add(red)
        #expect(added.colors == [red, green])
        added.add(red.withAlpha(0.5))
        #expect(added.colors == [red, green, red.withAlpha(0.5)])

        var updated = MyColors(colors: [red, green])
        updated.update(at: 1, to: blue)
        #expect(updated.colors == [red, blue])
        updated.update(at: 0, to: red)
        #expect(updated.colors == [red, blue])

        var merged = MyColors(colors: [red, green, blue])
        merged.update(at: 0, to: blue)
        #expect(merged.colors == [blue, green])
        merged.update(at: 1, to: blue)
        #expect(merged.colors == [blue])

        var removed = MyColors(colors: [red, green])
        removed.remove(at: 0)
        #expect(removed.colors == [green])
        removed.remove(at: 0)
        #expect(removed.colors.isEmpty)

        var outOfRange = MyColors(colors: [red, green])
        outOfRange.update(at: 2, to: .white)
        outOfRange.update(at: -1, to: .white)
        outOfRange.remove(at: 2)
        outOfRange.remove(at: -1)
        #expect(outOfRange.colors == [red, green])
        var empty = MyColors()
        empty.remove(at: 0)
        empty.update(at: 0, to: .white)
        #expect(empty.colors.isEmpty)
    }

    /// A screenshot's Save As offers the image formats, not the project, and starts on the format Save would use: every
    /// image format has its own Save As format, matched by type rather than by name. The project has no image format and
    /// takes the package's extension.
    @Test func everyImageFormatHasItsSaveAsFormat() {
        #expect(AnnotateSaveFormat.imageFormats == [.png, .jpeg, .heic, .webp])
        for format in ImageFormat.allCases {
            #expect(AnnotateSaveFormat(format).imageFormat == format)
        }
        #expect(AnnotateSaveFormat.project.imageFormat == nil)
        #expect(AnnotateSaveFormat.project.fileExtension == "clearshot")
    }
}
