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

    @Test func aFullWidthEraseOnA6KPictureIsFast() throws {
        let width = 6144, height = 3456
        let context = TestBitmaps.context(width, height)
        context.setFillColor(TestBitmaps.blue)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(TestBitmaps.yellow)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        let base = try #require(context.makeImage())
        let band = CGRect(x: 0, y: 1200, width: width, height: 1000)
        _ = EraseFill.image(base, region: CGRect(x: 0, y: 0, width: 10, height: 10)) // warm up
        // This thread's processor time, the best of a few runs, so the tests running alongside don't count.
        func threadTime() -> Duration {
            var time = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
            return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
        }
        var image: CGImage?
        let elapsed = (0..<5).map { _ in
            let start = threadTime()
            image = EraseFill.image(base, region: band)
            return threadTime() - start
        }.min()!
        #expect(image?.width == width && image?.height == 1000)
        #expect(elapsed < .milliseconds(100), "\(elapsed)")
    }
}

struct EraseModelTests {
    @Test func eraseIsARedactStyleWithATitle() {
        #expect(RedactStyle.allCases.contains(.erase))
        #expect(RedactStyle.erase.title == "Erase")
    }

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
