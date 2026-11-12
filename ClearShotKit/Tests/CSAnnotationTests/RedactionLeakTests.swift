import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// Nothing a redaction hides may be recovered from anything rendered. Each test renders one document over two pictures
/// that differ only in pixels a redaction covers, and expects the same pixels from both.

private func picture(_ width: Int, _ height: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = color(x, y)
            let index = (y * width + x) * 4
            bytes[index] = r; bytes[index + 1] = g; bytes[index + 2] = b
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: TestBitmaps.srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func inside(_ rect: CGRect, _ x: Int, _ y: Int) -> Bool {
    rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
}

private let plain = ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 2, shadow: false)

private func redaction(_ redact: RedactObject, id: UUID = UUID()) -> AnnotationObject {
    AnnotationObject(id: id, kind: .redact(redact), style: ObjectStyle(color: RGBAColor(red: 0, green: 0, blue: 0), lineWidth: 1,
                                                                       shadow: false))
}

private func blackOut(_ rect: CGRect) -> AnnotationObject {
    redaction(RedactObject(rect: rect, style: .blackOut, intensity: 5))
}

/// How many pixels differ between two images; -1 when their sizes differ.
private func differing(_ a: CGImage, _ b: CGImage) -> Int {
    guard a.width == b.width, a.height == b.height else { return -1 }
    let x = TestBitmaps.bytes(a), y = TestBitmaps.bytes(b)
    guard x.count == y.count else { return -1 }
    return stride(from: 0, to: x.count, by: 4).count { x[$0..<$0 + 4] != y[$0..<$0 + 4] }
}

private func images(_ base: CGImage) -> ImageStore {
    ImageStore([ImageRef.original.name: base])
}

struct RedactionLeakTests {
    // Two words on a line, 20 pixels tall, 5 pixels apart: each word's Erase ring reaches the other word.
    let rect = CGRect(x: 10, y: 10, width: 180, height: 40)
    let wordA = CGRect(x: 20, y: 20, width: 40, height: 20)
    let wordB = CGRect(x: 65, y: 20, width: 40, height: 20)
    let red = TestBitmaps.solid(100, 60, TestBitmaps.red)
    let blue = TestBitmaps.solid(100, 60, TestBitmaps.blue)

    /// Grey paper with some texture, word A dark, and word B's pixels `secret`, the only thing that differs.
    func words(secret: (UInt8, UInt8, UInt8)) -> CGImage {
        picture(200, 60) { x, y in
            if inside(wordB, x, y) { return secret }
            if inside(wordA, x, y) { return (30, 30, 30) }
            let value = UInt8(200 + (x * 3 + y) % 20)
            return (value, value, value)
        }
    }

    /// A text-only redaction of both words over `base`, with `extra` objects after it.
    func textOnly(_ base: CGImage, style: RedactStyle, extra: [AnnotationObject] = []) -> AnnotationDocument {
        let words = RedactionWords(rect: rect, boxes: [wordA, wordB], picture: RedactionWords.fingerprint(of: base, in: rect))
        var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 60), pixelScale: 1)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        document.objects = [redaction(RedactObject(rect: rect, style: style, intensity: 5, textOnly: true, words: words), id: id)]
            + extra
        return document
    }

    // MARK: Text-only Erase

    @Test(arguments: [RedactStyle.erase, .pixelate, .secureBlur, .smoothBlur, .blackOut])
    func aTextOnlyRedactionsWordsShowNothingOfEachOther(style: RedactStyle) throws {
        let one = words(secret: (255, 0, 0)), two = words(secret: (0, 0, 255))
        let first = try #require(Renderer.render(textOnly(one, style: style), images: images(one)))
        let second = try #require(Renderer.render(textOnly(two, style: style), images: images(two)))
        if style == .erase {
            // Erase reads around each word only: word B's pixels must reach no fill, its own or word A's.
            #expect(differing(first, second) == 0)
        } else {
            // The other effects are made from the pixels each word hides: only word B's own cover may differ.
            let areas = RedactObject(rect: rect, style: style, intensity: 5, textOnly: true,
                                     words: RedactionWords(rect: rect, boxes: [wordA, wordB],
                                                           picture: RedactionWords.fingerprint(of: one, in: rect)))
                .coveredAreas(baseSize: CGSize(width: 200, height: 60), picture: RedactionWords.fingerprint(of: one, in: rect))
            let coverB = try #require(areas.first { $0.intersects(wordB) }).integral
            let a = TestBitmaps.bytes(first), b = TestBitmaps.bytes(second)
            for y in 0..<60 {
                for x in 0..<200 where !inside(coverB, x, y) {
                    let index = (y * 200 + x) * 4
                    #expect(a[index..<index + 4] == b[index..<index + 4], "pixel \(x), \(y)")
                }
            }
        }
    }

    @Test func aWholeRectEraseOverTheWordsShowsNothingOfThem() throws {
        let one = words(secret: (255, 0, 0)), two = words(secret: (0, 0, 255))
        func document() -> AnnotationDocument {
            var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 60), pixelScale: 1)
            document.objects = [redaction(RedactObject(rect: rect, style: .erase, intensity: 5))]
            return document
        }
        let first = try #require(Renderer.render(document(), images: images(one)))
        let second = try #require(Renderer.render(document(), images: images(two)))
        #expect(differing(first, second) == 0)
    }

    @Test func aMagnifierOverATextOnlyEraseShowsNothingOfTheWords() throws {
        let one = words(secret: (255, 0, 0)), two = words(secret: (0, 0, 255))
        // The source is over word A's edge, where its fill's ring met word B. Copied on its own (Copy Object), the callout
        // can't contain word B.
        let magnifier = AnnotationObject(kind: .magnifier(MagnifierObject(source: CGRect(x: 50, y: 18, width: 12, height: 12),
                                                                          callout: CGRect(x: 120, y: 0, width: 60, height: 60))),
                                         style: plain)
        let first = try #require(Renderer.renderObjects([magnifier], document: textOnly(one, style: .erase, extra: [magnifier]),
                                                        images: images(one)))
        let second = try #require(Renderer.renderObjects([magnifier], document: textOnly(two, style: .erase, extra: [magnifier]),
                                                         images: images(two)))
        #expect(differing(first, second) == 0)
    }

    @Test func aTextOnlyErasesWordsAreCachedWithTheirHoles() throws {
        let base = words(secret: (255, 0, 0))
        let document = textOnly(base, style: .erase)
        let cache = RenderCache()
        let uncached = try #require(Renderer.render(document, images: images(base)))
        // Two frames with a cache: the second draws from it, and both are what an export makes.
        for _ in 0..<2 {
            let context = TestBitmaps.flippedContext(200, 60)
            Renderer.draw(document, images: images(base), in: context, cache: cache)
            #expect(differing(try #require(context.makeImage()), uncached) == 0)
        }
    }

    // MARK: Auto colours

    @Test(arguments: [false, true])
    func aMagnifiersBackdropComesFromTheRedactedPicture(withMagnifier: Bool) throws {
        func document() -> AnnotationDocument {
            var document = AnnotationDocument(baseSize: CGSize(width: 100, height: 60), pixelScale: 1)
            document.objects = [blackOut(CGRect(x: 0, y: 0, width: 100, height: 60))]
            if withMagnifier {
                // The source reaches past the picture: the backdrop shows there.
                document.objects.append(AnnotationObject(kind: .magnifier(MagnifierObject(source: CGRect(x: -10, y: -10, width: 20, height: 20),
                                                                                          callout: CGRect(x: 40, y: 10, width: 40, height: 40))),
                                                         style: plain))
            }
            return document
        }
        let first = try #require(Renderer.render(document(), images: images(red)))
        let second = try #require(Renderer.render(document(), images: images(blue)))
        #expect(differing(first, second) == 0)
    }

    @Test func anExpandedCanvasFillsFromTheRedactedPicture() throws {
        var document = AnnotationDocument(baseSize: CGSize(width: 100, height: 60), pixelScale: 1)
        document.canvasRect = CGRect(x: -20, y: -20, width: 140, height: 100)
        document.objects = [blackOut(CGRect(x: 0, y: 0, width: 100, height: 60))]
        let first = try #require(Renderer.render(document, images: images(red)))
        let second = try #require(Renderer.render(document, images: images(blue)))
        #expect(differing(first, second) == 0)
        // The fill is the redacted picture's edge colour: black.
        #expect(TestBitmaps.pixel(first, 5, 5) == TestBitmaps.RGBA(r: 0, g: 0, b: 0, a: 255))
        // With a cache too, and the colour follows the redaction when it goes.
        let cache = RenderCache()
        let context = TestBitmaps.flippedContext(140, 100)
        context.translateBy(x: 20, y: 20)
        Renderer.draw(document, images: images(red), in: context, cache: cache)
        #expect(differing(try #require(context.makeImage()), first) == 0)
        var unredacted = document
        unredacted.objects = []
        let shown = TestBitmaps.flippedContext(140, 100)
        shown.translateBy(x: 20, y: 20)
        Renderer.draw(unredacted, images: images(red), in: shown, cache: cache)
        #expect(TestBitmaps.pixel(try #require(shown.makeImage()), 5, 5) == TestBitmaps.RGBA(r: 255, g: 0, b: 0, a: 255))
    }

    @Test func anAutoInsetComesFromTheRedactedPicture() throws {
        var document = AnnotationDocument(baseSize: CGSize(width: 100, height: 60), pixelScale: 1)
        document.objects = [blackOut(CGRect(x: 0, y: 0, width: 100, height: 60))]
        document.background = DocumentBackground(style: BackgroundStyle(fill: .color(RGBAColor(red: 0, green: 1, blue: 0)),
                                                                        padding: 10, inset: 8, insetColor: .auto, shadow: 0,
                                                                        corners: 0, autoBalance: false, alignment: .center,
                                                                        ratio: .auto))
        let first = try #require(Renderer.render(document, images: images(red)))
        let second = try #require(Renderer.render(document, images: images(blue)))
        #expect(differing(first, second) == 0)
    }

    // MARK: Readers and exports

    @Test func thePixelReadersReadTheRedactedPicture() throws {
        var document = AnnotationDocument(baseSize: CGSize(width: 100, height: 60), pixelScale: 1)
        document.objects = [blackOut(CGRect(x: 10, y: 10, width: 50, height: 30))]
        let first = try #require(PicturePixels.make(of: document, images: images(red)))
        let second = try #require(PicturePixels.make(of: document, images: images(blue)))
        #expect(first.color(at: CGPoint(x: 30, y: 20)) == second.color(at: CGPoint(x: 30, y: 20)))
        let area = CGRect(x: 12, y: 12, width: 20, height: 20)
        #expect(first.average(in: area) == second.average(in: area))
    }

    /// Auto-balance measures the content with its redactions: a dark line hidden under a full-width Black Out, at row 20 or
    /// at row 34, must not move the box.
    @Test func autoBalanceMeasuresTheRedactedContent() throws {
        func base(line: Int) -> CGImage { picture(100, 60) { _, y in y == line ? (0, 0, 0) : (255, 255, 255) } }
        var document = AnnotationDocument(baseSize: CGSize(width: 100, height: 60), pixelScale: 1)
        document.objects = [redaction(RedactObject(rect: CGRect(x: 0, y: 15, width: 100, height: 25), style: .blackOut, intensity: 5),
                                      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)]
        document.background = DocumentBackground(style: BackgroundStyle(fill: .color(RGBAColor(red: 0, green: 1, blue: 0)),
                                                                        padding: 10, inset: 0, insetColor: .auto, shadow: 0,
                                                                        corners: 0, autoBalance: true, alignment: .center,
                                                                        ratio: .auto))
        let one = base(line: 20), two = base(line: 34)
        let first = try #require(Renderer.render(document, images: images(one)))
        let second = try #require(Renderer.render(document, images: images(two)))
        #expect(differing(first, second) == 0)
        #expect(Renderer.balanceTrims(for: document, images: images(one), cache: nil)
            == Renderer.balanceTrims(for: document, images: images(two), cache: nil))
        // The same through a cache.
        let cache = RenderCache()
        #expect(Renderer.balanceTrims(for: document, images: images(one), cache: cache)
            == Renderer.balanceTrims(for: document, images: images(two), cache: nil))
    }

    @Test func bothBeforeAfterFramesKeepTheRedactions() throws {
        let sticker = TestBitmaps.solid(10, 10, TestBitmaps.green)
        var document = AnnotationDocument(baseSize: CGSize(width: 100, height: 60), pixelScale: 1)
        document.objects = [blackOut(CGRect(x: 0, y: 0, width: 100, height: 60)),
                            AnnotationObject(kind: .image(ImageObject(rect: CGRect(x: 5, y: 5, width: 10, height: 10),
                                                                      image: ImageRef(name: "s.png"))),
                                             style: plain)]
        let first = try BeforeAfterGIF.frames(for: document, images: ImageStore([ImageRef.original.name: red, "s.png": sticker]))
        let second = try BeforeAfterGIF.frames(for: document, images: ImageStore([ImageRef.original.name: blue, "s.png": sticker]))
        try #require(first.count == second.count && !first.isEmpty)
        for (a, b) in zip(first, second) {
            #expect(differing(a, b) == 0)
        }
    }
}
