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

struct TextOnlyRedactionModelTests {
    @Test func anOldRedactionDecodesAsCoveringItsWholeRect() throws {
        let json = #"{"rect":[[1,2],[30,40]],"style":"pixelate","intensity":5}"#
        let decoded = try JSONDecoder().decode(RedactObject.self, from: Data(json.utf8))
        #expect(decoded.textOnly == false)
        #expect(decoded.words == nil)
        #expect(decoded.coversWholeRect)
        // And one that isn't text-only is written exactly as before.
        let written = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(Set(written.keys) == ["rect", "style", "intensity"])
    }

    @Test func aTextOnlyRedactionRoundTripsWithItsWords() throws {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 40)
        let words = RedactionWords(rect: rect, boxes: [CGRect(x: 10, y: 10, width: 30, height: 20)], runVertically: true)
        let original = RedactObject(rect: rect, style: .smoothBlur, intensity: 7, textOnly: true, words: words)
        let decoded = try JSONDecoder().decode(RedactObject.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        var document = AnnotationDocument(baseSize: CGSize(width: 120, height: 40), pixelScale: 1)
        document.objects = [AnnotationObject(kind: .redact(original), style: ObjectStyle(color: .init(red: 0, green: 0, blue: 0),
                                                                                       lineWidth: 1, shadow: false))]
        #expect(try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document)) == document)
    }

    @Test func wordsApplyOnlyToTheRectTheyWereFoundFor() {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 40)
        let box = CGRect(x: 10, y: 10, width: 30, height: 20)
        var redact = RedactObject(rect: rect, style: .pixelate, intensity: 5, textOnly: true)
        #expect(redact.needsWords)
        #expect(redact.coversWholeRect)
        redact.words = RedactionWords(rect: rect, boxes: [box])
        #expect(!redact.needsWords)
        #expect(!redact.coversWholeRect)
        // Moved: the words are of what was under the old rect.
        redact.rect = rect.offsetBy(dx: 5, dy: 0)
        #expect(redact.needsWords)
        #expect(redact.coveredAreas(baseSize: CGSize(width: 200, height: 40)) == [redact.rect])
        // No text found: the whole rect.
        redact.words = RedactionWords(rect: redact.rect, boxes: [])
        #expect(!redact.needsWords)
        #expect(redact.coversWholeRect)
        // Not text-only: the words don't count.
        redact.words = RedactionWords(rect: redact.rect, boxes: [box])
        redact.textOnly = false
        #expect(redact.coversWholeRect)
    }

    @Test func theMarginGrowsWithTheTextsHeight() {
        let base = CGSize(width: 1000, height: 1000)
        func area(_ box: CGRect, vertical: Bool = false) -> CGRect? {
            let rect = CGRect(origin: .zero, size: base)
            let redact = RedactObject(rect: rect, style: .pixelate, intensity: 5, textOnly: true,
                                      words: RedactionWords(rect: rect, boxes: [box], runVertically: vertical))
            return redact.coveredAreas(baseSize: base).first
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
                                  words: RedactionWords(rect: rect, boxes: [CGRect(x: 50, y: 50, width: 40, height: 40)]))
        #expect(redact.coveredAreas(baseSize: CGSize(width: 400, height: 400)) == [CGRect(x: 50, y: 50, width: 48, height: 40)])
    }

    @Test func coverageCountsTheWords() {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 40)
        let words = RedactionWords(rect: rect, boxes: [CGRect(x: 10, y: 10, width: 30, height: 20)])
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
    private func expectOnlyAreasChanged(_ rendered: CGImage, base: CGImage, areas: [CGRect]) {
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
        #expect(unchangedInside == 0)
        #expect(changedOutside == 0)
    }

    @Test(arguments: [RedactStyle.pixelate, .secureBlur])
    func storedWordsChangeOnlyTheWords(style: RedactStyle) throws {
        let base = checkerboard(120, 40)
        let object = redaction(style, rect: rect, words: RedactionWords(rect: rect, boxes: boxes))
        expectOnlyAreasChanged(try render(base, [object]), base: base, areas: areas)
    }

    @Test func blackOutCoversOnlyTheWords() throws {
        let base = TestBitmaps.solid(120, 40, TestBitmaps.white)
        let object = redaction(.blackOut, rect: rect, words: RedactionWords(rect: rect, boxes: boxes))
        let rendered = try render(base, [object])
        expectOnlyAreasChanged(rendered, base: base, areas: areas)
        #expect(TestBitmaps.pixel(rendered, 20, 20) == .init(r: 0, g: 0, b: 0, a: 255))
    }

    @Test func aBackgroundDrawsTheWordsTheSame() throws {
        // With a background, redactions are drawn with the content: the same covers.
        let base = TestBitmaps.solid(120, 40, TestBitmaps.white)
        var (document, images) = TestBitmaps.document(base: base, objects: [
            redaction(.blackOut, rect: rect, words: RedactionWords(rect: rect, boxes: boxes)),
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
        for words in [nil, RedactionWords(rect: rect.offsetBy(dx: 1, dy: 0), boxes: boxes), RedactionWords(rect: rect, boxes: [])] {
            let rendered = try render(base, [redaction(.blackOut, rect: rect, words: words)])
            expectOnlyAreasChanged(rendered, base: base, areas: [rect])
        }
        let pixelated = checkerboard(120, 40)
        expectOnlyAreasChanged(try render(pixelated, [redaction(.pixelate, rect: rect)]), base: pixelated, areas: [rect])
    }

    @Test func eachWordIsItsStyleOfJustThatArea() throws {
        // Any style that is a function of the picture and an area works per word: the effect is asked for each area.
        let base = checkerboard(120, 40)
        let (document, images) = TestBitmaps.document(base: base, objects: [
            redaction(.pixelate, rect: rect, words: RedactionWords(rect: rect, boxes: boxes)),
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

    @Test func aFailedWordEffectIsBlack() throws {
        let base = TestBitmaps.solid(120, 40, TestBitmaps.white)
        let (document, images) = TestBitmaps.document(base: base, objects: [
            redaction(.pixelate, rect: rect, words: RedactionWords(rect: rect, boxes: boxes)),
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
        let words = try #require(await RedactionWordFinder.words(in: rect, of: picture, options: options))
        #expect(words.rect == rect)
        #expect(words.boxes.count >= 2)
        // The gap between the two words is covered by no area.
        let redact = RedactObject(rect: rect, style: .pixelate, intensity: 5, textOnly: true, words: words)
        let areas = redact.coveredAreas(baseSize: rect.size)
        let firstEnd = 20 + widthOf("garden")
        let secondStart = 20 + widthOf("garden       ")
        let middle = CGPoint(x: (firstEnd + secondStart) / 2, y: 40)
        #expect(!areas.contains { $0.contains(middle) })
    }

    @Test func aPictureWithNoTextFindsNoWords() async throws {
        let (document, images) = TestBitmaps.document(base: page(nil))
        let picture = try #require(RedactionWordFinder.picture(of: document, images: images))
        let rect = CGRect(x: 10, y: 10, width: 200, height: 50)
        let words = try #require(await RedactionWordFinder.words(in: rect, of: picture, options: options))
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
    @Test func textOnlyIsRememberedAndRestylesTheSelection() throws {
        let rect = CGRect(x: 10, y: 10, width: 60, height: 30)
        let object = redaction(rect: rect, textOnly: true, words: RedactionWords(rect: rect, boxes: [rect]))
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
        #expect(try #require(editor.object(object.id).flatMap(redact)).needsWords)
    }

    @Test func wordsAreStoredOnlyForTheRectTheyWereFoundFor() throws {
        let rect = CGRect(x: 10, y: 10, width: 60, height: 30)
        let object = redaction(rect: rect)
        let harness = EditorHarness(objects: [object])
        let editor = harness.editor
        #expect(!editor.storeWords(RedactionWords(rect: rect.offsetBy(dx: 1, dy: 0), boxes: []), of: object.id))
        #expect(editor.storeWords(RedactionWords(rect: rect, boxes: [rect]), of: object.id))
        #expect(try #require(editor.object(object.id).flatMap(redact)).currentWords?.boxes == [rect])
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
        for _ in 0..<200 where notices.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(notices == [AnnotationEditor.noTextFoundNotice])
        let found = try #require(editor.object(object.id).flatMap(redact))
        #expect(found.currentWords?.boxes == [])
        #expect(found.coversWholeRect)
    }
}
