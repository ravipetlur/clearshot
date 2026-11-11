import CoreGraphics
import CoreText
import CSCore
import CSOCR
import Foundation
import Testing
@testable import CSAnnotation

/// A picture of one-pixel black and white squares: any average of two or more of its pixels is grey, so every pixel a
/// Pixelate block covers changes.
private func checkerboard(_ width: Int, _ height: Int) -> CGImage {
    let context = TestBitmaps.context(width, height)
    context.setFillColor(TestBitmaps.white)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(TestBitmaps.black)
    for y in 0..<height {
        for x in 0..<width where (x + y) % 2 == 0 {
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return context.makeImage()!
}

private func redaction(_ style: RedactStyle = .pixelate, rect: CGRect, textOnly: Bool = true,
                       words: RedactionWords? = nil) -> AnnotationObject {
    AnnotationObject(kind: .redact(RedactObject(rect: rect, style: style, intensity: 5, textOnly: textOnly, words: words)),
                     style: ObjectStyle(color: RGBAColor(red: 0, green: 0, blue: 0), lineWidth: 1, shadow: false))
}

private func redact(_ object: AnnotationObject) -> RedactObject? {
    if case .redact(let redact) = object.kind { redact } else { nil }
}

/// Words over `rect` read from `base`'s pixels.
private func words(_ boxes: [CGRect], rect: CGRect, of base: CGImage, runVertically: Bool = false) -> RedactionWords {
    RedactionWords(rect: rect, boxes: boxes, runVertically: runVertically, picture: RedactionWords.fingerprint(of: base, in: rect))
}

struct TextOnlyRedactionModelTests {
    /// A fingerprint standing for the pixels under the rect in the model tests.
    let picture: UInt64 = 7

    @Test func anOldRedactionDecodesAsCoveringItsWholeRect() throws {
        let json = #"{"rect":[[1,2],[30,40]],"style":"pixelate","intensity":5}"#
        let decoded = try JSONDecoder().decode(RedactObject.self, from: Data(json.utf8))
        #expect(decoded.textOnly == false)
        #expect(decoded.words == nil)
        #expect(decoded.coversWholeRect(picture: picture))
        // And one that isn't text-only is written exactly as before.
        let written = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(Set(written.keys) == ["rect", "style", "intensity"])
    }

    @Test func aTextOnlyRedactionRoundTripsWithItsWords() throws {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 40)
        let words = RedactionWords(rect: rect, boxes: [CGRect(x: 10, y: 10, width: 30, height: 20)], runVertically: true,
                                   picture: UInt64.max - 3)
        let original = RedactObject(rect: rect, style: .smoothBlur, intensity: 7, textOnly: true, words: words)
        let decoded = try JSONDecoder().decode(RedactObject.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        var document = AnnotationDocument(baseSize: CGSize(width: 120, height: 40), pixelScale: 1)
        document.objects = [AnnotationObject(kind: .redact(original), style: ObjectStyle(color: .init(red: 0, green: 0, blue: 0),
                                                                                       lineWidth: 1, shadow: false))]
        #expect(try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document)) == document)
    }

    @Test func wordsApplyOnlyToTheRectAndPixelsTheyWereFoundFor() {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 40)
        let box = CGRect(x: 10, y: 10, width: 30, height: 20)
        var redact = RedactObject(rect: rect, style: .pixelate, intensity: 5, textOnly: true)
        #expect(redact.needsWords(picture: picture))
        #expect(redact.coversWholeRect(picture: picture))
        redact.words = RedactionWords(rect: rect, boxes: [box], picture: picture)
        #expect(!redact.needsWords(picture: picture))
        #expect(!redact.coversWholeRect(picture: picture))
        // Other pixels under the same rect (another document, a changed base), or none to compare: the whole rect.
        #expect(redact.needsWords(picture: picture + 1))
        #expect(redact.coveredAreas(baseSize: CGSize(width: 200, height: 40), picture: picture + 1) == [rect])
        #expect(redact.coversWholeRect(picture: nil))
        // Words without a fingerprint match nothing.
        redact.words?.picture = nil
        #expect(redact.coversWholeRect(picture: picture))
        redact.words?.picture = picture
        // Moved: the words are of what was under the old rect.
        redact.rect = rect.offsetBy(dx: 5, dy: 0)
        #expect(redact.needsWords(picture: picture))
        #expect(redact.coveredAreas(baseSize: CGSize(width: 200, height: 40), picture: picture) == [redact.rect])
        // No text found: the whole rect.
        redact.words = RedactionWords(rect: redact.rect, boxes: [], picture: picture)
        #expect(!redact.needsWords(picture: picture))
        #expect(redact.coversWholeRect(picture: picture))
        // Not text-only: the words don't count.
        redact.words = RedactionWords(rect: redact.rect, boxes: [box], picture: picture)
        redact.textOnly = false
        #expect(redact.coversWholeRect(picture: picture))
    }

    @Test func theFingerprintIsOfThePixelsUnderTheRect() {
        let white = TestBitmaps.solid(120, 40, TestBitmaps.white)
        let rect = CGRect(x: 10, y: 10, width: 50, height: 20)
        #expect(RedactionWords.fingerprint(of: white, in: rect) == RedactionWords.fingerprint(of: white, in: rect))
        // The same pixels drawn again: the same fingerprint.
        #expect(RedactionWords.fingerprint(of: TestBitmaps.solid(120, 40, TestBitmaps.white), in: rect)
            == RedactionWords.fingerprint(of: white, in: rect))
        // Other pixels, or another place.
        #expect(RedactionWords.fingerprint(of: checkerboard(120, 40), in: rect) != RedactionWords.fingerprint(of: white, in: rect))
        #expect(RedactionWords.fingerprint(of: white, in: rect.offsetBy(dx: 1, dy: 0)) != RedactionWords.fingerprint(of: white, in: rect))
        // Nothing of the base under it.
        #expect(RedactionWords.fingerprint(of: white, in: CGRect(x: 500, y: 0, width: 10, height: 10)) == nil)
    }

    @Test func theMarginGrowsWithTheTextsHeight() {
        let base = CGSize(width: 1000, height: 1000)
        func area(_ box: CGRect, vertical: Bool = false) -> CGRect? {
            let rect = CGRect(origin: .zero, size: base)
            let redact = RedactObject(rect: rect, style: .pixelate, intensity: 5, textOnly: true,
                                      words: RedactionWords(rect: rect, boxes: [box], runVertically: vertical, picture: picture))
            return redact.coveredAreas(baseSize: base, picture: picture).first
        }
        // 20 px text: 2 above and below, 4 to each side.
        #expect(area(CGRect(x: 100, y: 100, width: 60, height: 20)) == CGRect(x: 96, y: 98, width: 68, height: 24))
        // 40 px text: 4 and 8.
        #expect(area(CGRect(x: 100, y: 100, width: 60, height: 40)) == CGRect(x: 92, y: 96, width: 76, height: 48))
        // 100 px text: 10 above and below, and the side margin stops at 16.
        #expect(area(CGRect(x: 100, y: 100, width: 300, height: 100)) == CGRect(x: 84, y: 90, width: 332, height: 120))
        // Text reading down the base (a turned picture): the text's height is the box's width, and the wide margin runs along it.
        #expect(area(CGRect(x: 100, y: 100, width: 20, height: 60), vertical: true) == CGRect(x: 98, y: 96, width: 24, height: 68))
    }

    @Test func theAreasStayInsideTheRect() {
        let rect = CGRect(x: 50, y: 50, width: 100, height: 40)
        let redact = RedactObject(rect: rect, style: .pixelate, intensity: 5, textOnly: true,
                                  words: RedactionWords(rect: rect, boxes: [CGRect(x: 50, y: 50, width: 40, height: 40)],
                                                        picture: picture))
        #expect(redact.coveredAreas(baseSize: CGSize(width: 400, height: 400), picture: picture)
            == [CGRect(x: 50, y: 50, width: 48, height: 40)])
    }

    @Test func coverageCountsTheWords() {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 40)
        let words = RedactionWords(rect: rect, boxes: [CGRect(x: 10, y: 10, width: 30, height: 20)], picture: picture)
        let id = UUID()
        func document(_ redact: RedactObject) -> AnnotationDocument {
            var document = AnnotationDocument(baseSize: CGSize(width: 120, height: 40), pixelScale: 1)
            document.objects = [AnnotationObject(id: id, kind: .redact(redact),
                                                 style: ObjectStyle(color: .init(red: 0, green: 0, blue: 0), lineWidth: 1, shadow: false))]
            return document
        }
        let whole = document(RedactObject(rect: rect, style: .pixelate, intensity: 5))
        let pending = document(RedactObject(rect: rect, style: .pixelate, intensity: 5, textOnly: true))
        let wordsOnly = document(RedactObject(rect: rect, style: .pixelate, intensity: 5, textOnly: true, words: words))
        // Words arriving, or text only switched on, hide less.
        #expect(!wordsOnly.onlyAddsCoverage(since: pending))
        #expect(!wordsOnly.onlyAddsCoverage(since: whole))
        // Back to the whole rect hides more.
        #expect(whole.onlyAddsCoverage(since: wordsOnly))
        #expect(!wordsOnly.onlyAddsCoverage(since: wordsOnly))
    }

    @Test func aCopyDropsTheWords() throws {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 40)
        let object = redaction(rect: rect, words: RedactionWords(rect: rect, boxes: [rect], picture: picture))
        let copy = try #require(redact(object.copied()))
        #expect(copy.textOnly)
        #expect(copy.words == nil)
    }
}

struct TextOnlyRedactionRenderTests {
    let rect = CGRect(x: 0, y: 0, width: 120, height: 40)
    /// Two words, 20 px tall, with 30 px between them.
    let boxes = [CGRect(x: 10, y: 10, width: 30, height: 20), CGRect(x: 70, y: 10, width: 30, height: 20)]
    /// The boxes with their margins: 2 above and below, 4 to each side.
    let areas = [CGRect(x: 6, y: 8, width: 38, height: 24), CGRect(x: 66, y: 8, width: 38, height: 24)]

    private func render(_ base: CGImage, _ objects: [AnnotationObject]) throws -> CGImage {
        let (document, images) = TestBitmaps.document(base: base, objects: objects)
        return try #require(Renderer.render(document, images: images))
    }

    /// Checks every pixel of `rendered` against `base`: changed inside `areas`, unchanged everywhere else.
    private func expectOnlyAreasChanged(_ rendered: CGImage, base: CGImage, areas: [CGRect],
                                        sourceLocation: SourceLocation = #_sourceLocation) {
        let before = TestBitmaps.bytes(base)
        let after = TestBitmaps.bytes(rendered)
        var unchangedInside = 0
        var changedOutside = 0
        for y in 0..<base.height {
            for x in 0..<base.width {
                let index = (y * base.width + x) * 4
                let same = before[index..<index + 4] == after[index..<index + 4]
                let inside = areas.contains { $0.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) }
                if inside, same { unchangedInside += 1 }
                if !inside, !same { changedOutside += 1 }
            }
        }
        #expect(unchangedInside == 0, sourceLocation: sourceLocation)
        #expect(changedOutside == 0, sourceLocation: sourceLocation)
    }

    @Test(arguments: [RedactStyle.pixelate, .secureBlur])
    func storedWordsChangeOnlyTheWords(style: RedactStyle) throws {
        let base = checkerboard(120, 40)
        let object = redaction(style, rect: rect, words: words(boxes, rect: rect, of: base))
        expectOnlyAreasChanged(try render(base, [object]), base: base, areas: areas)
    }

    @Test func blackOutCoversOnlyTheWords() throws {
        let base = TestBitmaps.solid(120, 40, TestBitmaps.white)
        let object = redaction(.blackOut, rect: rect, words: words(boxes, rect: rect, of: base))
        let rendered = try render(base, [object])
        expectOnlyAreasChanged(rendered, base: base, areas: areas)
        #expect(TestBitmaps.pixel(rendered, 20, 20) == .init(r: 0, g: 0, b: 0, a: 255))
    }

    @Test func aBackgroundDrawsTheWordsTheSame() throws {
        // With a background, redactions are drawn with the content: the same covers.
        let base = TestBitmaps.solid(120, 40, TestBitmaps.white)
        var (document, images) = TestBitmaps.document(base: base, objects: [
            redaction(.blackOut, rect: rect, words: words(boxes, rect: rect, of: base)),
        ])
        var style = BackgroundStyle.standard
        style.fill = .color(RGBAColor(red: 1, green: 0, blue: 0))
        document.background = DocumentBackground(style: style, image: nil)
        let rendered = try #require(Renderer.render(document, images: images))
        // The standard padding: the content starts 64 pixels in.
        #expect(TestBitmaps.pixel(rendered, 64 + 20, 64 + 20) == .init(r: 0, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(rendered, 64 + 55, 64 + 20) == .init(r: 255, g: 255, b: 255, a: 255))
        #expect(TestBitmaps.pixel(rendered, 64 + 20, 64 + 4) == .init(r: 255, g: 255, b: 255, a: 255))
    }

    @Test func pendingWordsCoverTheWholeRect() throws {
        let base = TestBitmaps.solid(120, 40, TestBitmaps.white)
        // Not found yet; found for another rect; none found.
        for found in [nil, words(boxes, rect: rect.offsetBy(dx: 1, dy: 0), of: base), words([], rect: rect, of: base)] {
            let rendered = try render(base, [redaction(.blackOut, rect: rect, words: found)])
            expectOnlyAreasChanged(rendered, base: base, areas: [rect])
        }
        let pixelated = checkerboard(120, 40)
        expectOnlyAreasChanged(try render(pixelated, [redaction(.pixelate, rect: rect)]), base: pixelated, areas: [rect])
    }

    @Test func theSameRectOverOtherPixelsCoversTheWholeRect() throws {
        // Words read from one picture, in a document over another at the same rect (pasted, or the base changed under it).
        let readFrom = TestBitmaps.solid(120, 40, TestBitmaps.white)
        for (style, other) in [(RedactStyle.blackOut, TestBitmaps.solid(120, 40, TestBitmaps.yellow)), (.pixelate, checkerboard(120, 40))] {
            let object = redaction(style, rect: rect, words: words(boxes, rect: rect, of: readFrom))
            expectOnlyAreasChanged(try render(other, [object]), base: other, areas: [rect])
        }
        // The same words over the pixels they were read from cover just the words.
        let blackOut = redaction(.blackOut, rect: rect, words: words(boxes, rect: rect, of: readFrom))
        expectOnlyAreasChanged(try render(readFrom, [blackOut]), base: readFrom, areas: areas)
    }

    @Test func aBaseChangedUnderTheRedactionCoversTheWholeRectWithACache() throws {
        // The canvas keeps a cache across frames: a new base under the same redaction is checked again.
        let first = TestBitmaps.solid(120, 40, TestBitmaps.white)
        let object = redaction(.blackOut, rect: rect, words: words(boxes, rect: rect, of: first))
        let cache = RenderCache()
        let (document, images) = TestBitmaps.document(base: first, objects: [object])
        let context = TestBitmaps.flippedContext(120, 40)
        Renderer.draw(document, images: images, in: context, cache: cache)
        #expect(TestBitmaps.pixel(try #require(context.makeImage()), 55, 20) == .init(r: 255, g: 255, b: 255, a: 255))
        let second = TestBitmaps.solid(120, 40, TestBitmaps.yellow)
        let (changed, newImages) = TestBitmaps.document(base: second, objects: [object])
        let next = TestBitmaps.flippedContext(120, 40)
        Renderer.draw(changed, images: newImages, in: next, cache: cache)
        #expect(TestBitmaps.pixel(try #require(next.makeImage()), 55, 20) == .init(r: 0, g: 0, b: 0, a: 255))
    }

    @Test func eachWordIsItsStyleOfJustThatArea() throws {
        // Any style that is a function of the picture and an area works per word: the effect is asked for each area.
        let base = checkerboard(120, 40)
        let (document, images) = TestBitmaps.document(base: base, objects: [
            redaction(.pixelate, rect: rect, words: words(boxes, rect: rect, of: base)),
        ])
        let cache = RenderCache()
        nonisolated(unsafe) var asked: [CGRect] = []
        cache.effect = { redact, region, base, scale, seed in
            asked.append(region)
            #expect(redact.rect == region)
            return Redaction.image(for: redact, region: region, base: base, pixelScale: scale, seed: seed)
        }
        Renderer.draw(document, images: images, in: TestBitmaps.flippedContext(120, 40), cache: cache)
        #expect(Set(asked.map { "\($0)" }) == Set(areas.map { "\($0)" }))
        // Cached: the next frame asks for nothing.
        asked = []
        Renderer.draw(document, images: images, in: TestBitmaps.flippedContext(120, 40), cache: cache)
        #expect(asked.isEmpty)
    }

    @Test func eachWordHasNoiseOfItsOwn() throws {
        // A flat grey picture: Pixelate's blocks all average the same grey, so only the noise tells two words apart.
        let grey = TestBitmaps.solid(120, 40, CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        let object = redaction(.pixelate, rect: rect, words: words(boxes, rect: rect, of: grey))
        let rendered = try render(grey, [object])
        func pixels(of area: CGRect) -> [TestBitmaps.RGBA] {
            let bytes = TestBitmaps.bytes(rendered)
            return (Int(area.minY)..<Int(area.maxY)).flatMap { y in
                (Int(area.minX)..<Int(area.maxX)).map { x in
                    let index = (y * rendered.width + x) * 4
                    return TestBitmaps.RGBA(r: bytes[index], g: bytes[index + 1], b: bytes[index + 2], a: bytes[index + 3])
                }
            }
        }
        #expect(areas[0].size == areas[1].size)
        #expect(pixels(of: areas[0]) != pixels(of: areas[1]))
        // And the same each time.
        #expect(try render(grey, [object]).dataProvider?.data == rendered.dataProvider?.data)
        let id = UUID()
        #expect(Renderer.seed(id, for: areas[0]) == Renderer.seed(id, for: areas[0]))
        #expect(Renderer.seed(id, for: areas[0]) != Renderer.seed(id, for: areas[1]))
        #expect(Renderer.seed(id, for: areas[0]) != id)
    }

    @Test func aFailedWordEffectIsBlack() throws {
        let base = TestBitmaps.solid(120, 40, TestBitmaps.white)
        let (document, images) = TestBitmaps.document(base: base, objects: [
            redaction(.pixelate, rect: rect, words: words(boxes, rect: rect, of: base)),
        ])
        let cache = RenderCache()
        cache.effect = { _, _, _, _, _ in nil }
        let context = TestBitmaps.flippedContext(120, 40)
        Renderer.draw(document, images: images, in: context, cache: cache)
        let image = try #require(context.makeImage())
        #expect(TestBitmaps.pixel(image, 20, 20) == .init(r: 0, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(image, 55, 20) == .init(r: 255, g: 255, b: 255, a: 255))
        #expect(cache.wordRedactions.isEmpty)
    }
}

/// Recognition on a rendered picture: Vision, on this Mac.
struct RedactionWordFinderTests {
    private func page(_ text: String?, width: Int = 420, height: Int = 80) -> CGImage {
        let context = TestBitmaps.context(width, height)
        context.setFillColor(TestBitmaps.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let text {
            let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): TestBitmaps.black,
            ])
            context.textPosition = CGPoint(x: 20, y: 28)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return context.makeImage()!
    }

    private let options = TextRecognitionOptions(automaticallyDetectsLanguage: false, primaryLanguage: "en-US",
                                                 usesLanguageCorrection: false)

    @Test func findsEachWordAndLeavesTheGapsBetweenThem() async throws {
        let base = page("garden       harbor")
        let (document, images) = TestBitmaps.document(base: base)
        let picture = try #require(RedactionWordFinder.picture(of: document, images: images))
        let rect = CGRect(x: 0, y: 0, width: 420, height: 80)
        let words = try #require(await RedactionWordFinder.words(in: rect, of: picture, base: base, options: options))
        #expect(words.rect == rect)
        #expect(words.boxes.count >= 2)
        let fingerprint = RedactionWords.fingerprint(of: base, in: rect)
        #expect(words.picture == fingerprint)
        // The gap between the two words is covered by no area.
        let redact = RedactObject(rect: rect, style: .pixelate, intensity: 5, textOnly: true, words: words)
        let areas = redact.coveredAreas(baseSize: rect.size, picture: fingerprint)
        let firstEnd = 20 + widthOf("garden")
        let secondStart = 20 + widthOf("garden       ")
        let middle = CGPoint(x: (firstEnd + secondStart) / 2, y: 40)
        #expect(areas.count >= 2)
        #expect(!areas.contains { $0.contains(middle) })
    }

    @Test func aPictureWithNoTextFindsNoWords() async throws {
        let base = page(nil)
        let (document, images) = TestBitmaps.document(base: base)
        let picture = try #require(RedactionWordFinder.picture(of: document, images: images))
        let rect = CGRect(x: 10, y: 10, width: 200, height: 50)
        let words = try #require(await RedactionWordFinder.words(in: rect, of: picture, base: base, options: options))
        #expect(words.boxes.isEmpty)
    }

    @Test func aLineWithAWordLeftUnboxedIsCoveredWhole() {
        let line = OCRLine(text: "one two", box: CGRect(x: 0, y: 0, width: 100, height: 20),
                           marks: [OCRMark(text: "one", box: CGRect(x: 0, y: 0, width: 40, height: 20), tag: 0)])
        #expect(RedactionWordFinder.boxes(of: line).contains(line.box))
        let both = OCRLine(text: "one two", box: line.box, marks: line.marks + [OCRMark(text: "two", box: CGRect(x: 60, y: 0, width: 40, height: 20), tag: 0)])
        #expect(!RedactionWordFinder.boxes(of: both).contains(line.box))
    }

    @Test func wordRangesAreTheRunsBetweenBlanks() {
        let line = "  alpha beta\tgamma "
        #expect(RedactionWordFinder.wordRanges(line).map { String(line[$0.range]) } == ["alpha", "beta", "gamma"])
    }

    private func widthOf(_ string: String) -> Double {
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let attributed = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
    }
}

@MainActor
struct TextOnlyEditorTests {
    /// The editor harness's picture: white, 100×80.
    let white = TestBitmaps.solid(100, 80, TestBitmaps.white)

    /// Waits up to ten seconds, off and on, for `condition`.
    private func wait(for condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func textOnlyIsRememberedAndRestylesTheSelection() throws {
        let rect = CGRect(x: 10, y: 10, width: 60, height: 30)
        let object = redaction(rect: rect, textOnly: true, words: words([rect], rect: rect, of: white))
        let harness = EditorHarness(objects: [object])
        let editor = harness.editor
        editor.selection = [object.id]
        harness.act { editor.setRedactTextOnly(false) }
        #expect(editor.settings.redactTextOnly == false)
        let off = try #require(editor.object(object.id).flatMap(redact))
        #expect(!off.textOnly)
        #expect(off.words == nil)
        harness.act { editor.setRedactTextOnly(true) }
        #expect(editor.settings.redactTextOnly)
        #expect(harness.preferences[Prefs.annotateToolSettings].redactTextOnly)
        #expect(try #require(editor.object(object.id).flatMap(redact)).words == nil)
    }

    @Test func wordsAreStoredOnlyForTheRectTheyWereFoundFor() throws {
        let rect = CGRect(x: 10, y: 10, width: 60, height: 30)
        let object = redaction(rect: rect)
        let harness = EditorHarness(objects: [object])
        let editor = harness.editor
        #expect(!editor.storeWords(words([], rect: rect.offsetBy(dx: 1, dy: 0), of: white), of: object.id))
        #expect(editor.storeWords(words([rect], rect: rect, of: white), of: object.id))
        let stored = try #require(editor.object(object.id).flatMap(redact))
        #expect(stored.currentWords(picture: RedactionWords.fingerprint(of: white, in: rect))?.boxes == [rect])
        // Not an undo step of its own.
        #expect(!editor.undoManager.canUndo)
    }

    @Test func aBlankAreaSaysNoTextWasFound() async throws {
        let rect = CGRect(x: 10, y: 10, width: 60, height: 30)
        let object = redaction(rect: rect)
        let harness = EditorHarness(objects: [object])
        let editor = harness.editor
        var notices: [String] = []
        editor.textOnlyNotice = { notices.append($0) }
        // The search runs after a quiet moment, off the main actor.
        try await wait { !notices.isEmpty }
        #expect(notices == [AnnotationEditor.noTextFoundNotice])
        let found = try #require(editor.object(object.id).flatMap(redact))
        #expect(found.currentWords(picture: RedactionWords.fingerprint(of: white, in: rect))?.boxes == [])
    }

    @Test func wordsFromOtherPixelsAreReadAgain() async throws {
        // A text-only redaction whose words came from another picture at the same rect (a document from elsewhere, or a
        // base that changed): it covers its whole rect, and its words are read again from these pixels.
        let rect = CGRect(x: 10, y: 10, width: 60, height: 30)
        let elsewhere = checkerboard(100, 80)
        let object = redaction(.blackOut, rect: rect, words: words([CGRect(x: 12, y: 12, width: 10, height: 10)], rect: rect,
                                                                   of: elsewhere))
        let harness = EditorHarness(objects: [object])
        let editor = harness.editor
        // Meanwhile the whole rect is covered.
        let rendered = try #require(Renderer.render(editor.document, images: editor.images))
        #expect(TestBitmaps.pixel(rendered, 60, 30) == .init(r: 0, g: 0, b: 0, a: 255))
        let fingerprint = RedactionWords.fingerprint(of: white, in: rect)
        try await wait { editor.object(object.id).flatMap(redact)?.words?.picture == fingerprint }
        let reread = try #require(editor.object(object.id).flatMap(redact))
        #expect(reread.words?.picture == fingerprint)
        #expect(reread.words?.boxes == [])
    }

    @Test func aPictureChangeUnderTheRedactionCoversTheWholeRectUntilReadAgain() async throws {
        let rect = CGRect(x: 10, y: 10, width: 60, height: 30)
        let box = CGRect(x: 12, y: 12, width: 10, height: 10)
        let object = redaction(.blackOut, rect: rect, words: words([box], rect: rect, of: white))
        let harness = EditorHarness(objects: [object])
        let editor = harness.editor
        // Read from these pixels: only the word is covered.
        var rendered = try #require(Renderer.render(editor.document, images: editor.images))
        #expect(TestBitmaps.pixel(rendered, 60, 30) == .init(r: 255, g: 255, b: 255, a: 255))
        // The base's pixels change under it.
        let changed = checkerboard(100, 80)
        editor.addImage(changed, for: editor.document.base)
        rendered = try #require(Renderer.render(editor.document, images: editor.images))
        #expect(TestBitmaps.pixel(rendered, 60, 30) == .init(r: 0, g: 0, b: 0, a: 255))
        // And they are read again from the new pixels.
        let fingerprint = RedactionWords.fingerprint(of: changed, in: rect)
        try await wait { editor.object(object.id).flatMap(redact)?.words?.picture == fingerprint }
        #expect(editor.object(object.id).flatMap(redact)?.words?.picture == fingerprint)
    }

    @Test func aPastedTextOnlyRedactionCoversTheWholeRectUntilReadAgain() async throws {
        let rect = CGRect(x: 10, y: 10, width: 60, height: 30)
        // Words that would apply here, had they come with the paste.
        let object = redaction(.blackOut, rect: rect, words: words([CGRect(x: 12, y: 12, width: 10, height: 10)], rect: rect,
                                                                   of: white))
        let harness = EditorHarness()
        let editor = harness.editor
        harness.act { editor.paste([object]) }
        let pasted = try #require(editor.selectedObjects.first)
        let copy = try #require(redact(pasted))
        #expect(copy.textOnly)
        #expect(copy.words == nil)
        let rendered = try #require(Renderer.render(editor.document, images: editor.images))
        let middle = CGPoint(x: copy.rect.midX, y: copy.rect.midY)
        #expect(TestBitmaps.pixel(rendered, Int(middle.x), Int(middle.y)) == .init(r: 0, g: 0, b: 0, a: 255))
        let fingerprint = RedactionWords.fingerprint(of: white, in: copy.rect)
        try await wait { editor.object(pasted.id).flatMap(redact)?.words?.picture == fingerprint }
        #expect(editor.object(pasted.id).flatMap(redact)?.words?.picture == fingerprint)
    }
}
