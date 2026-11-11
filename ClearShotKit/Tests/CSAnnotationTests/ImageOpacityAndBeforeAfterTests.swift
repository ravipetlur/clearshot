import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CSAnnotation

private let first = ImageRef(name: "images/first.png")
private let second = ImageRef(name: "images/second.png")

private func picture(_ ref: ImageRef, rect: CGRect, opacity: Double = 1) -> AnnotationObject {
    AnnotationObject(kind: .image(ImageObject(rect: rect, image: ref, opacity: opacity)),
                     style: ObjectStyle(color: RGBAColor(red: 0, green: 0, blue: 0), lineWidth: 1, shadow: false))
}

private func fixture(_ objects: [AnnotationObject]) -> (AnnotationDocument, ImageStore) {
    var (document, images) = TestBitmaps.document(base: TestBitmaps.solid(60, 40, TestBitmaps.white), objects: objects)
    images.set(TestBitmaps.solid(10, 10, TestBitmaps.blue), for: first)
    images.set(TestBitmaps.solid(10, 10, TestBitmaps.red), for: second)
    document.objects = objects
    return (document, images)
}

struct ImageOpacityModelTests {
    @Test func anImageWithNoOpacityInItsFileOpensOpaque() throws {
        let object = picture(first, rect: CGRect(x: 1, y: 2, width: 3, height: 4))
        let data = try JSONEncoder().encode(object)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var kind = try #require(json["kind"] as? [String: Any])
        // The synthesized enum coding nests the payload under the case's name.
        var payload = try #require(kind["image"] as? [String: Any])
        payload["opacity"] = nil
        kind["image"] = payload
        json["kind"] = kind
        let old = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(AnnotationObject.self, from: old)
        guard case .image(let image) = decoded.kind else {
            Issue.record("not an image")
            return
        }
        #expect(image.opacity == 1)
    }

    @Test func opacityRoundTrips() throws {
        let object = picture(first, rect: CGRect(x: 0, y: 0, width: 5, height: 5), opacity: 0.4)
        let decoded = try JSONDecoder().decode(AnnotationObject.self, from: JSONEncoder().encode(object))
        #expect(decoded == object)
    }

    @Test func aHalfOpaqueImageBlendsWithWhatIsUnderIt() throws {
        let (document, images) = fixture([picture(first, rect: CGRect(x: 10, y: 10, width: 20, height: 20), opacity: 0.5)])
        let image = try #require(Renderer.render(document, images: images))
        let pixel = TestBitmaps.pixel(image, 20, 20)
        #expect(abs(Int(pixel.r) - 128) <= 2)
        #expect(abs(Int(pixel.g) - 128) <= 2)
        #expect(pixel.b == 255)
    }

    @Test func anOpaqueImageCoversWhatIsUnderIt() throws {
        let (document, images) = fixture([picture(first, rect: CGRect(x: 10, y: 10, width: 20, height: 20))])
        let image = try #require(Renderer.render(document, images: images))
        #expect(TestBitmaps.pixel(image, 20, 20) == .init(r: 0, g: 0, b: 255, a: 255))
    }
}

@MainActor
struct ImageOpacityKeyTests {
    private func harness(selecting select: Bool = true, tool: EditorTool = .select) -> (EditorHarness, AnnotationObject) {
        let object = picture(first, rect: CGRect(x: 10, y: 10, width: 20, height: 20))
        let harness = EditorHarness(objects: [object], images: [first.name: TestBitmaps.solid(10, 10, TestBitmaps.blue)])
        harness.editor.tool = tool
        if select { harness.editor.selection = [object.id] }
        return (harness, object)
    }

    private func opacity(_ harness: EditorHarness) -> Double? {
        guard case .image(let image) = harness.editor.document.objects.first?.kind else { return nil }
        return image.opacity
    }

    @Test(arguments: 1...9)
    func digitsOneToNineSetTenToNinetyPercent(digit: Int) throws {
        let (harness, _) = harness()
        var taken = false
        harness.act { taken = harness.editor.handleImageOpacityKey(Character(String(digit))) }
        #expect(taken)
        #expect(abs(try #require(opacity(harness)) - Double(digit) / 10) < 0.0001)
    }

    @Test func zeroSetsFullOpacity() throws {
        let (harness, _) = harness()
        harness.act { harness.editor.setImageOpacity(0.3) }
        harness.act { _ = harness.editor.handleImageOpacityKey("0") }
        #expect(opacity(harness) == 1)
    }

    @Test func theSliderRangeIsClamped() {
        let (harness, _) = harness()
        harness.act { harness.editor.setImageOpacity(0) }
        #expect(opacity(harness) == 0.05)
        harness.act { harness.editor.setImageOpacity(3) }
        #expect(opacity(harness) == 1)
    }

    @Test func digitsAreLeftAloneWithoutAnImageSelectedOrOutsideTheSelectTool() {
        let (none, _) = harness(selecting: false)
        #expect(!none.editor.handleImageOpacityKey("5"))
        #expect(opacity(none) == 1)
        let (drawing, _) = harness(tool: .rectangle)
        #expect(!drawing.editor.handleImageOpacityKey("5"))
        #expect(opacity(drawing) == 1)
    }

    @Test func digitsAreLeftAloneWhileTextIsEdited() {
        let (harness, _) = harness()
        harness.editor.editingTextID = UUID()
        #expect(!harness.editor.handleImageOpacityKey("5"))
        #expect(opacity(harness) == 1)
    }

    @Test func aShapeSelectedKeepsItsSizeKeys() {
        let rectangle = editorRectangle()
        let harness = EditorHarness(objects: [rectangle])
        harness.editor.tool = .select
        harness.editor.selection = [rectangle.id]
        #expect(!harness.editor.handleImageOpacityKey("3"))
    }
}

struct BeforeAfterGIFTests {
    private let one = picture(first, rect: CGRect(x: 5, y: 5, width: 20, height: 20))
    private let two = picture(second, rect: CGRect(x: 30, y: 5, width: 20, height: 20))
    private let shape = editorRectangle(CGRect(x: 2, y: 30, width: 10, height: 8))

    @Test func theTopmostImageIsTheLastOne() {
        let (document, _) = fixture([one, shape, two, shape])
        #expect(BeforeAfterGIF.topmostImage(in: document)?.id == two.id)
        #expect(BeforeAfterGIF.isAvailable(for: document))
    }

    @Test func aDocumentWithoutImagesIsNotAvailable() {
        let (document, images) = fixture([shape])
        #expect(!BeforeAfterGIF.isAvailable(for: document))
        #expect(BeforeAfterGIF.withoutTopmostImage(document) == nil)
        #expect(throws: BeforeAfterGIF.Failure.noImage) { try BeforeAfterGIF.frames(for: document, images: images) }
    }

    @Test func theFirstFrameOmitsExactlyTheTopmostImage() throws {
        let (document, _) = fixture([one, shape, two])
        let before = try #require(BeforeAfterGIF.withoutTopmostImage(document))
        #expect(before.objects.map(\.id) == [one.id, shape.id])
    }

    @Test func theFramesShareASizeAndShowWithoutAndWithTheImage() throws {
        let (document, images) = fixture([one, two])
        let frames = try BeforeAfterGIF.frames(for: document, images: images)
        #expect(frames.count == 2)
        #expect(frames[0].width == frames[1].width && frames[0].height == frames[1].height)
        // The second image is at (30...50, 5...25): absent first, there second; the first image is in both.
        #expect(TestBitmaps.pixel(frames[0], 40, 15) == .init(r: 255, g: 255, b: 255, a: 255))
        #expect(TestBitmaps.pixel(frames[1], 40, 15) == .init(r: 255, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(frames[0], 15, 15) == .init(r: 0, g: 0, b: 255, a: 255))
        #expect(TestBitmaps.pixel(frames[1], 15, 15) == .init(r: 0, g: 0, b: 255, a: 255))
    }

    @Test func theGIFLoopsTwoFramesOfEightTenthsOfASecond() throws {
        let (document, images) = fixture([one, two])
        let data = try BeforeAfterGIF.data(for: document, images: images)
        #expect(data.prefix(6) == Data("GIF89a".utf8))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        let file = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let gif = try #require(file[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        #expect(gif[kCGImagePropertyGIFLoopCount] as? Int == 0)
        for index in 0..<2 {
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let frame = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            let delay = try #require((frame[kCGImagePropertyGIFUnclampedDelayTime] ?? frame[kCGImagePropertyGIFDelayTime]) as? Double)
            #expect(abs(delay - 0.8) < 0.001)
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 60)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 40)
        }
    }
}
