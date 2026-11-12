import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// An opaque picture whose pixel at (x, y), y down, is `color(x, y)`.
private func picture(_ width: Int, _ height: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = color(x, y)
            let index = (y * width + x) * 4
            bytes[index] = r
            bytes[index + 1] = g
            bytes[index + 2] = b
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: TestBitmaps.srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// A loud magenta-and-green check, unlike anything around it.
private func pattern(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
    (x + y).isMultiple(of: 2) ? (255, 0, 255) : (0, 255, 0)
}

private func inside(_ rect: CGRect, _ x: Int, _ y: Int) -> Bool {
    rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
}

private func erase(_ rect: CGRect) -> AnnotationObject {
    AnnotationObject(kind: .redact(RedactObject(rect: rect, style: .erase, intensity: 5)),
                     style: ObjectStyle(color: RGBAColor(red: 0, green: 0, blue: 0), lineWidth: 1, shadow: false))
}

struct EraseFillTests {
    let rect = CGRect(x: 30, y: 20, width: 40, height: 24)

    @Test func aFlatRingFillsFlat() throws {
        // A grey ring that varies by a few levels, with the pattern under the area.
        let base = picture(100, 64) { x, y in
            if inside(rect, x, y) { return pattern(x, y) }
            let level = UInt8(120 + (x * 7 + y * 3) % 5)
            return (level, level, level)
        }
        let fill = TestBitmaps.bytes(try #require(EraseFill.image(base, region: rect)))
        let first = Array(fill[0..<4])
        for index in stride(from: 0, to: fill.count, by: 4) {
            #expect(Array(fill[index..<index + 4]) == first)
        }
        #expect(first[3] == 255)
        #expect((120...124).contains(first[0]) && first[0] == first[1] && first[1] == first[2])
    }

    @Test(arguments: [true, false])
    func aGradientRingIsInterpolated(horizontal: Bool) throws {
        // A gradient across the picture: the fill continues it.
        let level = { (x: Int, y: Int) -> UInt8 in UInt8(horizontal ? 20 + x * 2 : 20 + y * 3) }
        let base = picture(100, 64) { x, y in inside(rect, x, y) ? pattern(x, y) : (level(x, y), 255 - level(x, y), 90) }
        let fill = TestBitmaps.bytes(try #require(EraseFill.image(base, region: rect)))
        for y in 0..<Int(rect.height) {
            for x in 0..<Int(rect.width) {
                let index = (y * Int(rect.width) + x) * 4
                let expected = Int(level(x + Int(rect.minX), y + Int(rect.minY)))
                #expect(abs(Int(fill[index]) - expected) <= 1, "red at \(x), \(y)")
                #expect(abs(Int(fill[index + 1]) - (255 - expected)) <= 1, "green at \(x), \(y)")
                #expect(abs(Int(fill[index + 2]) - 90) <= 1, "blue at \(x), \(y)")
            }
        }
    }

    @Test func eachSideLeadsNearIt() throws {
        // Red on the left, blue on the right, white above and below: each fill pixel is nearest its nearer side's colour.
        let base = picture(100, 64) { x, y in
            if inside(rect, x, y) { return pattern(x, y) }
            if y < Int(rect.minY) || y >= Int(rect.maxY) { return (255, 255, 255) }
            return x < Int(rect.minX) ? (255, 0, 0) : (0, 0, 255)
        }
        let image = try #require(EraseFill.image(base, region: rect))
        let left = TestBitmaps.pixel(image, 0, 12), right = TestBitmaps.pixel(image, 39, 12)
        let top = TestBitmaps.pixel(image, 20, 0), bottom = TestBitmaps.pixel(image, 20, 23)
        #expect(left.r > 200 && left.b < 40)
        #expect(right.b > 200 && right.r < 40)
        #expect(top.g > 200 && bottom.g > 200)
    }

    @Test func atThePicturesEdgeOnlyTheSidesThatExistAreUsed() throws {
        // In the top-left corner: only the right side (red) and the bottom (blue) exist. The pattern runs to the edges.
        let corner = CGRect(x: 0, y: 0, width: 30, height: 20)
        let base = picture(60, 40) { x, y in
            if inside(corner, x, y) { return pattern(x, y) }
            return y >= 20 ? (0, 0, 255) : (255, 0, 0)
        }
        let image = try #require(EraseFill.image(base, region: corner))
        #expect(image.width == 30 && image.height == 20)
        let nearRight = TestBitmaps.pixel(image, 29, 2), nearBottom = TestBitmaps.pixel(image, 2, 19)
        #expect(nearRight.r > 200 && nearRight.b < 60)
        #expect(nearBottom.b > 200 && nearBottom.r < 60)
        let bytes = TestBitmaps.bytes(image)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            #expect(bytes[index + 1] == 0, "no green from the pattern")
            #expect(bytes[index + 3] == 255)
        }
    }

    @Test func aFullWidthAreaFillsBetweenTopAndBottom() throws {
        let band = CGRect(x: 0, y: 10, width: 50, height: 20)
        let base = picture(50, 40) { x, y in inside(band, x, y) ? pattern(x, y) : (y < 10 ? (0, 0, 0) : (200, 200, 200)) }
        let image = try #require(EraseFill.image(base, region: band))
        #expect(TestBitmaps.pixel(image, 25, 0).r < 20)
        #expect(TestBitmaps.pixel(image, 25, 19).r > 180)
        let middle = TestBitmaps.pixel(image, 25, 10).r
        #expect((80...120).contains(middle))
    }

    @Test func theWholePictureErasedIsBlack() throws {
        let base = picture(20, 20, pattern)
        let image = try #require(EraseFill.image(base, region: CGRect(x: 0, y: 0, width: 20, height: 20)))
        #expect(TestBitmaps.pixel(image, 10, 10) == .init(r: 0, g: 0, b: 0, a: 255))
    }

    /// Two pictures that differ only inside the area export the same pixels there, and none of them is the pattern's.
    @Test func nothingOfWhatWasThereIsInTheExport() throws {
        let rect = CGRect(x: 23, y: 17, width: 41, height: 29)
        let around = { (x: Int, y: Int) -> (UInt8, UInt8, UInt8) in
            (UInt8((x * 5 + y) % 120 + 60), UInt8((y * 4) % 100 + 80), UInt8((x + y * 2) % 90 + 70))
        }
        let marked = picture(96, 72) { x, y in inside(rect, x, y) ? pattern(x, y) : around(x, y) }
        let other = picture(96, 72) { x, y in inside(rect, x, y) ? (UInt8(x * 3 % 256), 9, UInt8(y * 5 % 256)) : around(x, y) }
        let (document, images) = TestBitmaps.document(base: marked, objects: [erase(rect)])
        let (_, otherImages) = TestBitmaps.document(base: other)
        let exported = TestBitmaps.bytes(try #require(Renderer.render(document, images: images)))
        let exportedOther = TestBitmaps.bytes(try #require(Renderer.render(document, images: otherImages)))
        var checked = 0
        for y in 0..<72 {
            for x in 0..<96 where inside(rect, x, y) {
                checked += 1
                let index = (y * 96 + x) * 4
                #expect(exported[index..<index + 4] == exportedOther[index..<index + 4], "\(x), \(y) depends on what was there")
                let (r, g, b) = pattern(x, y)
                #expect(exported[index..<index + 3] != [r, g, b][...], "\(x), \(y) shows the pattern")
                // Neither of the pattern's colours, nor anything near them: the ring has no strong magenta or green.
                #expect(!(exported[index] > 200 && exported[index + 1] < 60), "\(x), \(y) is magenta")
                #expect(!(exported[index + 1] > 200 && exported[index] < 60), "\(x), \(y) is green")
            }
        }
        #expect(checked == 41 * 29)
    }

    @Test func movingItFillsFromItsNewPlace() throws {
        // White on the left half, black on the right: moved across, its fill follows the new ring.
        let base = TestBitmaps.split(80, 40, left: TestBitmaps.white, right: TestBitmaps.black)
        var object = erase(CGRect(x: 10, y: 10, width: 10, height: 10))
        let (document, images) = TestBitmaps.document(base: base, objects: [object])
        let cache = RenderCache()
        let context = TestBitmaps.flippedContext(80, 40)
        Renderer.draw(document, images: images, in: context, cache: cache)
        #expect(TestBitmaps.pixel(try #require(context.makeImage()), 15, 15).r == 255)
        object.kind = .redact(RedactObject(rect: CGRect(x: 60, y: 10, width: 10, height: 10), style: .erase, intensity: 5))
        var moved = document
        moved.objects = [object]
        let after = TestBitmaps.flippedContext(80, 40)
        Renderer.draw(moved, images: images, in: after, cache: cache)
        #expect(TestBitmaps.pixel(try #require(after.makeImage()), 65, 15).r == 0)
    }

    /// A full-width Erase is linear in its pixels: on a 2048 × 1152 picture, a ninth of a 6K one, a band a ninth of the 6K
    /// test's (6144 × 1000 in 100 ms) takes no more than a ninth of its time.
    @Test func aFullWidthEraseIsFast() throws {
        let width = 2048, height = 1152
        let context = TestBitmaps.context(width, height)
        context.setFillColor(TestBitmaps.blue)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(TestBitmaps.yellow)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        let base = try #require(context.makeImage())
        let bandHeight = 333
        let band = CGRect(x: 0, y: 400, width: width, height: bandHeight)
        // 100 ms for 6144 × 1000, scaled to this band's pixels.
        let ceiling = Duration.milliseconds(100) * (Double(width * bandHeight) / Double(6144 * 1000))
        _ = EraseFill.image(base, region: CGRect(x: 0, y: 0, width: 10, height: 10)) // warm up
        // The thread's processor time, the best of a few runs, at the priority an edit on the canvas runs at, so the tests
        // running alongside count as little as they can.
        func threadTime() -> Duration {
            var time = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
            return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
        }
        let (elapsed, size) = DispatchQueue.global(qos: .userInteractive).sync {
            var size = (0, 0)
            let elapsed = (0..<5).map { _ in
                let start = threadTime()
                let image = EraseFill.image(base, region: band)
                let elapsed = threadTime() - start
                size = (image?.width ?? 0, image?.height ?? 0)
                return elapsed
            }.min()!
            return (elapsed, size)
        }
        #expect(size.0 == width && size.1 == bandHeight)
        #expect(elapsed < ceiling, "\(elapsed) against \(ceiling)")
    }
}

struct EraseModelTests {
    @Test func aRedactionWrittenBeforeEraseStillReads() throws {
        let old = #"{"rect":[[1,2],[30,40]],"style":"blackOut","intensity":4}"#
        let decoded = try JSONDecoder().decode(RedactObject.self, from: Data(old.utf8))
        #expect(decoded == RedactObject(rect: CGRect(x: 1, y: 2, width: 30, height: 40), style: .blackOut, intensity: 4))
    }

    @Test func anEraseIsWrittenWithNoNewFields() throws {
        let erase = RedactObject(rect: CGRect(x: 1, y: 2, width: 30, height: 40), style: .erase, intensity: 5)
        let data = try JSONEncoder().encode(erase)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["rect", "style", "intensity"])
        #expect(try JSONDecoder().decode(RedactObject.self, from: data) == erase)
    }
}

@MainActor
struct EditorEraseTests {
    @Test func deleteOnAPixelSelectionAddsOneEraseAsOneStep() throws {
        let h = EditorHarness()
        h.editor.selectPixels(CGRect(x: 10, y: 12, width: 30, height: 20))
        h.act { h.editor.deleteSelection() }
        #expect(h.editor.document.objects.count == 1)
        let object = try #require(h.editor.document.objects.first)
        guard case .redact(let redact) = object.kind else { Issue.record("not a redaction"); return }
        #expect(redact.style == .erase)
        #expect(redact.rect == CGRect(x: 10, y: 12, width: 30, height: 20))
        #expect(!object.isSecretsMask)
        #expect(h.editor.pixelSelection == nil)
        #expect(h.editor.selection.isEmpty)
        h.editor.undoManager.undo()
        #expect(h.editor.document.objects.isEmpty)
        #expect(!h.editor.undoManager.canUndo)
        h.editor.undoManager.redo()
        #expect(h.editor.document.objects == [object])
    }

    @Test func deleteWithAnObjectSelectedStillDeletesIt() {
        let rectangle = editorRectangle()
        let h = EditorHarness(objects: [rectangle])
        h.editor.selection = [rectangle.id]
        h.act { h.editor.deleteSelection() }
        #expect(h.editor.document.objects.isEmpty)
    }

    @Test func deleteWithNothingSelectedDoesNothing() {
        let h = EditorHarness()
        h.editor.deleteSelection() // outside `act`: a registration here would raise
        #expect(h.editor.document.objects.isEmpty)
        #expect(!h.editor.undoManager.canUndo)
    }
}

/// An Erase never reads what another redaction hides: its ring comes from the picture with every other redaction in it.
struct EraseBesideRedactionsTests {
    /// Calm greys, nothing near the pattern's magenta or green.
    static func around(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let level = (x * 3 + y * 2) % 100 + 80
        return (UInt8(level), UInt8(level + 10), UInt8(level - 10))
    }

    static func redaction(_ style: RedactStyle, _ rect: CGRect, id: UUID = UUID()) -> AnnotationObject {
        AnnotationObject(id: id, kind: .redact(RedactObject(rect: rect, style: style, intensity: 3)),
                         style: ObjectStyle(color: RGBAColor(red: 0, green: 0, blue: 0), lineWidth: 1, shadow: false))
    }

    /// The picture: `hidden` areas hold the pattern (or, `swapped`, its other phase), the rest calm colours.
    static func base(hidden: [CGRect], swapped: Bool = false) -> CGImage {
        picture(96, 64) { x, y in
            guard hidden.contains(where: { inside($0, x, y) }) else { return around(x, y) }
            return pattern(x + (swapped ? 1 : 0), y)
        }
    }

    static func rendered(_ objects: [AnnotationObject], over base: CGImage) throws -> [UInt8] {
        let (document, images) = TestBitmaps.document(base: base, objects: objects)
        return TestBitmaps.bytes(try #require(Renderer.render(document, images: images)))
    }

    /// No pixel of `rect` in `bytes` (96 wide) is near the pattern's magenta or green.
    static func expectNoPattern(in bytes: [UInt8], _ rect: CGRect, _ label: String) {
        var found = 0
        for y in 0..<64 {
            for x in 0..<96 where inside(rect, x, y) {
                let index = (y * 96 + x) * 4
                let (r, g, b) = (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
                if (r > 195 && g < 60 && b > 195) || (r < 60 && g > 195 && b < 60) { found += 1 }
            }
        }
        #expect(found == 0, "\(found) pixels of the \(label) fill look like the pattern")
    }

    static func expectSame(_ a: [UInt8], _ b: [UInt8], in rect: CGRect, _ label: String) {
        var differ = 0
        for y in 0..<64 {
            for x in 0..<96 where inside(rect, x, y) {
                let index = (y * 96 + x) * 4
                if a[index..<index + 4] != b[index..<index + 4] { differ += 1 }
            }
        }
        #expect(differ == 0, "\(differ) pixels of the \(label) fill depend on what is hidden")
    }

    let erase = CGRect(x: 40, y: 20, width: 20, height: 20)

    /// A Black Out just left of the Erase, the pattern under it, before or after the Erase in the document.
    @Test(arguments: [true, false])
    func aBlackOutBesideItHidesThePatternFromIt(blackOutFirst: Bool) throws {
        let covered = CGRect(x: 30, y: 15, width: 10, height: 30)
        var objects = [Self.redaction(.erase, erase)]
        objects.insert(Self.redaction(.blackOut, covered), at: blackOutFirst ? 0 : 1)
        let first = try Self.rendered(objects, over: Self.base(hidden: [covered]))
        let second = try Self.rendered(objects, over: Self.base(hidden: [covered], swapped: true))
        Self.expectNoPattern(in: first, erase, "erase")
        Self.expectSame(first, second, in: erase, "erase")
        // The ring's left side is the Black Out's black: the fill darkens toward it.
        let nearLeft = (30 * 96 + 40) * 4
        #expect(first[nearLeft] < 60 && first[nearLeft + 1] < 60)
    }

    @Test(arguments: [true, false])
    func aPixelateBesideItShowsItOnlyThePixelation(pixelateFirst: Bool) throws {
        let covered = CGRect(x: 30, y: 15, width: 10, height: 30)
        let pixelate = Self.redaction(.pixelate, covered)
        var objects = [Self.redaction(.erase, erase)]
        objects.insert(pixelate, at: pixelateFirst ? 0 : 1)
        let base = Self.base(hidden: [covered])
        let bytes = try Self.rendered(objects, over: base)
        Self.expectNoPattern(in: bytes, erase, "erase")
        // Exactly the fill made from the picture with the pixelation in it.
        guard case .redact(let redact) = pixelate.kind else { return }
        let pixelated = try #require(Renderer.redactedBase(base, redactions: [RedactionKey(id: pixelate.id, redact: redact)],
                                                           pixelScale: 1, cache: nil)?.image)
        let expected = TestBitmaps.bytes(try #require(EraseFill.image(pixelated, region: erase)))
        var differ = 0
        for y in 0..<20 {
            for x in 0..<20 {
                let from = (y * 20 + x) * 4, to = ((y + 20) * 96 + x + 40) * 4
                if expected[from..<from + 4] != bytes[to..<to + 4] { differ += 1 }
            }
        }
        #expect(differ == 0)
    }

    /// Two Erases side by side, the pattern under both: neither is made from what the other hides.
    @Test func twoAdjacentErasesReadNothingOfEachOther() throws {
        let right = CGRect(x: 60, y: 20, width: 20, height: 20)
        let objects = [Self.redaction(.erase, erase), Self.redaction(.erase, right)]
        let first = try Self.rendered(objects, over: Self.base(hidden: [erase, right]))
        let second = try Self.rendered(objects, over: Self.base(hidden: [erase, right], swapped: true))
        for (rect, label) in [(erase, "left"), (right, "right")] {
            Self.expectNoPattern(in: first, rect, label)
            Self.expectSame(first, second, in: rect, label)
        }
    }

    /// An Erase overlapping a Black Out, the pattern under the part of the Black Out its ring crosses.
    @Test func anEraseOverlappingARedactionReadsWhatItShows() throws {
        let covered = CGRect(x: 50, y: 10, width: 30, height: 20)
        for objects in [[Self.redaction(.blackOut, covered), Self.redaction(.erase, erase)],
                        [Self.redaction(.erase, erase), Self.redaction(.blackOut, covered)]] {
            let first = try Self.rendered(objects, over: Self.base(hidden: [covered]))
            let second = try Self.rendered(objects, over: Self.base(hidden: [covered], swapped: true))
            Self.expectNoPattern(in: first, erase, "erase")
            Self.expectSame(first, second, in: CGRect(x: 0, y: 0, width: 96, height: 64), "picture")
        }
    }

    /// A Black Out added over the pattern beside an Erase already drawn: the canvas's cached fill is made again.
    @Test func aRedactionAddedBesideItRemakesItsCachedFill() throws {
        let covered = CGRect(x: 30, y: 15, width: 10, height: 30)
        let base = Self.base(hidden: [covered])
        let (document, images) = TestBitmaps.document(base: base, objects: [Self.redaction(.erase, erase)])
        let cache = RenderCache()
        func draw(_ document: AnnotationDocument) throws -> [UInt8] {
            let context = TestBitmaps.flippedContext(96, 64)
            Renderer.draw(document, images: images, in: context, cache: cache)
            return TestBitmaps.bytes(try #require(context.makeImage()))
        }
        let before = try draw(document)
        var covering = document
        covering.objects.append(Self.redaction(.blackOut, covered))
        let after = try draw(covering)
        let index = (30 * 96 + 40) * 4
        #expect(before[index..<index + 4] != after[index..<index + 4])
        Self.expectNoPattern(in: after, erase, "erase")
        Self.expectSame(after, try Self.rendered(covering.objects, over: base), in: erase, "cached erase")
        // Moved away, the Black Out uncovers the pattern, and the fill is made again from what now shows.
        var moved = covering
        moved.objects[1] = Self.redaction(.blackOut, covered.offsetBy(dx: -25, dy: 0), id: moved.objects[1].id)
        let away = try draw(moved)
        Self.expectSame(away, try Self.rendered(moved.objects, over: base), in: erase, "erase after the move")
    }
}
