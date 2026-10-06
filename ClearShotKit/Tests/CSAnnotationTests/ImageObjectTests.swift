import CoreGraphics
import CSCapture
import CSCore
import CSHistory
import Foundation
import ImageIO
import Testing
@testable import CSAnnotation

struct ImagePlacementTests {
    @Test(arguments: [(72.0, 1.0), (71.6, 1.0), (143.99, 2.0), (144.0, 2.0), (144.02, 2.0), (215.7, 3.0), (216.0, 3.0), (216.5, 3.0)])
    func aDensityOf72TimesOneToThreeIsThePixelsPerPoint(dpi: Double, scale: Double) {
        #expect(ImagePlacement.scale(forDPI: dpi) == scale)
    }

    @Test(arguments: [96.0, 150.0, 300.0, 288.0, 360.0, 600.0, 72.6, 144.6, 36.0])
    func anyOtherDensityIsAPrintSettingAndCountsAsOne(dpi: Double) {
        #expect(ImagePlacement.scale(forDPI: dpi) == 1)
    }

    @Test func aMissingOrNonsenseDensityCountsAsOne() {
        #expect(ImagePlacement.scale(forDPI: nil) == 1)
        #expect(ImagePlacement.scale(forDPI: 0) == 1)
        #expect(ImagePlacement.scale(forDPI: -144) == 1)
        #expect(ImagePlacement.scale(forDPI: .nan) == 1)
        #expect(ImagePlacement.scale(forDPI: .infinity) == 1)
    }

    /// The density and pixels per point an editor reads from `data`, the way a dropped or pasted picture is read.
    private func readBack(_ data: Data) throws -> (dpi: Double?, scale: Double) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let loaded = try #require(ImageOps.loadUpright(from: source))
        return (loaded.dpi, ImagePlacement.scale(forDPI: loaded.dpi))
    }

    /// ClearShot's own screenshots record their pixels per point, as macOS's do, so one dragged or pasted into an editor
    /// keeps its size instead of coming in at twice it.
    @Test(arguments: [ImageFormat.png, .jpeg, .heic])
    func aRetinaImageEncodedByClearShotReadsBackAsScale2(format: ImageFormat) throws {
        let data = try ImageEncoder.encode(TestBitmaps.solid(40, 20, TestBitmaps.red), as: format, quality: 1, pixelsPerPoint: 2)
        let read = try readBack(data)
        #expect(read.dpi == 144)
        #expect(read.scale == 2)
    }

    /// Reopened from disk (Quick Access Open…, a drop from Finder), a Retina file ClearShot saved, and its history working
    /// copy, read back at their own scale.
    @Test func aRetinaFileClearShotSavedReopensAtScale2() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "reopen-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let picture = TestBitmaps.solid(40, 20, TestBitmaps.red)
        let saved = folder.appending(path: "Saved.png")
        try Exporter.write(picture, as: .png, quality: 1, pixelsPerPoint: 2, to: saved, screenCapture: nil)
        let details = HistoryWriter.Details(origin: .capture, captureKind: .selection, displayName: "Shot", savedURL: nil, scale: 2,
                                            appName: nil, isTransparent: false, globalRect: .zero, createdAt: Date())
        let item = try HistoryWriter.create(picture, details: details, root: folder.appending(path: "History"))
        for url in [saved, item.mediaURL(in: folder.appending(path: "History"))] {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let loaded = try #require(ImageOps.loadUpright(from: source))
            #expect(ImagePlacement.scale(forDPI: loaded.dpi) == 2, "\(url.lastPathComponent)")
        }
    }

    @Test(arguments: [ImageFormat.png, .jpeg, .heic])
    func aOneXImageEncodedByClearShotReadsBackAsScale1(format: ImageFormat) throws {
        let data = try ImageEncoder.encode(TestBitmaps.solid(40, 20, TestBitmaps.red), as: format, quality: 1, pixelsPerPoint: 1)
        let read = try readBack(data)
        #expect(read.dpi == 72)
        #expect(read.scale == 1)
    }

    @Test func aRetinaImageIsHalfAsBigInA1xDocument() {
        #expect(ImagePlacement.naturalSize(pixelSize: CGSize(width: 200, height: 100), imageScale: 2, outputScale: 1)
            == CGSize(width: 100, height: 50))
    }

    @Test func anImageIsScaledDownToFitEightyPercentOfTheCanvas() {
        let rect = ImagePlacement.placed(size: CGSize(width: 1000, height: 1000), in: CGRect(x: 0, y: 0, width: 400, height: 300),
                                         centeredOn: CGPoint(x: 200, y: 150))
        #expect(rect == CGRect(x: 80, y: 30, width: 240, height: 240))
    }

    @Test func aSmallImageKeepsItsSize() {
        let rect = ImagePlacement.placed(size: CGSize(width: 40, height: 20), in: CGRect(x: 0, y: 0, width: 400, height: 300),
                                         centeredOn: CGPoint(x: 100, y: 100))
        #expect(rect == CGRect(x: 80, y: 90, width: 40, height: 20))
    }

    @Test func aHugeBitmapIsLimitedTo16383Pixels() throws {
        let huge = TestBitmaps.solid(20_000, 4, TestBitmaps.red)
        let limited = try #require(ImagePlacement.limited(huge))
        #expect(limited.width == 16_383)
        #expect(limited.height == 3)
        let small = TestBitmaps.solid(10, 10, TestBitmaps.red)
        #expect(ImagePlacement.limited(small) === small)
    }

    @Test func aHugeExtendedRangeBitmapIsLimitedToo() throws {
        // Float extended sRGB can't be drawn into an 8-bit bitmap in its own color space; scaling it down falls back to sRGB.
        let huge = TestBitmaps.extendedSRGB(20_000, 4, TestBitmaps.red)
        let limited = try #require(ImagePlacement.limited(huge))
        #expect(limited.width == 16_383)
        #expect(limited.height == 3)
        #expect(TestBitmaps.pixel(limited, 8_000, 1) == .init(r: 255, g: 0, b: 0, a: 255))
    }

    @Test func aBitmapIsTurnedToTheBase() throws {
        let picture = TestBitmaps.split(4, 2, left: TestBitmaps.red, right: TestBitmaps.blue)
        let turned = DocumentTransform(baseSize: CGSize(width: 10, height: 10), ops: [.rotateRight])
        let stored = try #require(ImagePlacement.orientedForBase(picture, transform: turned))
        #expect(stored.width == 2)
        #expect(stored.height == 4)
        let upright = DocumentTransform(baseSize: CGSize(width: 10, height: 10), ops: [])
        #expect(ImagePlacement.orientedForBase(picture, transform: upright) === picture)
    }

    @Test func aCentreNearACornerKeepsTheImageInsideTheCanvas() {
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 300)
        let size = CGSize(width: 40, height: 20)
        #expect(ImagePlacement.placed(size: size, in: canvas, centeredOn: CGPoint(x: 5, y: 5)) == CGRect(x: 0, y: 0, width: 40, height: 20))
        #expect(ImagePlacement.placed(size: size, in: canvas, centeredOn: CGPoint(x: 1000, y: 1000))
            == CGRect(x: 360, y: 280, width: 40, height: 20))
        // A canvas whose origin isn't zero (a crop, an expansion): the edges are its own.
        let cropped = CGRect(x: 100, y: -50, width: 400, height: 300)
        #expect(ImagePlacement.placed(size: size, in: cropped, centeredOn: .zero) == CGRect(x: 100, y: -10, width: 40, height: 20))
        #expect(ImagePlacement.placed(size: size, in: cropped, centeredOn: CGPoint(x: 900, y: 900))
            == CGRect(x: 460, y: 230, width: 40, height: 20))
    }

    @Test func anImageBiggerThanTheCanvasIsScaledToFitBeforeItIsKeptInside() {
        let canvas = CGRect(x: 0, y: 0, width: 100, height: 80)
        // Scaled to 80%: 80×64, then kept inside whatever the centre.
        #expect(ImagePlacement.placed(size: CGSize(width: 400, height: 320), in: canvas, centeredOn: CGPoint(x: -30, y: 200))
            == CGRect(x: 0, y: 16, width: 80, height: 64))
        // Even a fraction past 100% never puts it outside.
        let full = ImagePlacement.placed(size: CGSize(width: 400, height: 320), in: canvas, centeredOn: CGPoint(x: 50, y: 40), fraction: 3)
        #expect(canvas.contains(full))
    }

    @Test func anExtendedRangeBitmapIsTurnedToTheBaseToo() throws {
        let picture = TestBitmaps.extendedSRGB(4, 2, TestBitmaps.red)
        let turned = DocumentTransform(baseSize: CGSize(width: 10, height: 10), ops: [.rotateRight])
        let stored = try #require(ImagePlacement.orientedForBase(picture, transform: turned))
        #expect(stored.width == 2)
        #expect(stored.height == 4)
        #expect(TestBitmaps.pixel(stored, 0, 0) == .init(r: 255, g: 0, b: 0, a: 255))
        let flipped = DocumentTransform(baseSize: CGSize(width: 10, height: 10), ops: [.flipHorizontal])
        #expect(ImagePlacement.orientedForBase(picture, transform: flipped) != nil)
    }
}

struct CombineLayoutTests {
    let canvas = CGRect(x: 0, y: 0, width: 100, height: 80)
    let size = CGSize(width: 40, height: 20)

    @Test func eachSidePlacesTheImageCentredOnTheOtherAxis() throws {
        let right = try #require(CombineLayout.place(imageSize: size, onto: canvas, edge: .right, gap: 0))
        #expect(right.rect == CGRect(x: 100, y: 30, width: 40, height: 20))
        #expect(right.canvas == CGRect(x: 0, y: 0, width: 140, height: 80))
        let left = try #require(CombineLayout.place(imageSize: size, onto: canvas, edge: .left, gap: 0))
        #expect(left.rect == CGRect(x: -40, y: 30, width: 40, height: 20))
        #expect(left.canvas == CGRect(x: -40, y: 0, width: 140, height: 80))
        let top = try #require(CombineLayout.place(imageSize: size, onto: canvas, edge: .top, gap: 0))
        #expect(top.rect == CGRect(x: 30, y: -20, width: 40, height: 20))
        #expect(top.canvas == CGRect(x: 0, y: -20, width: 100, height: 100))
        let bottom = try #require(CombineLayout.place(imageSize: size, onto: canvas, edge: .bottom, gap: 0))
        #expect(bottom.rect == CGRect(x: 30, y: 80, width: 40, height: 20))
        #expect(bottom.canvas == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func aTallerImageGrowsTheCanvasBothWays() throws {
        let placed = try #require(CombineLayout.place(imageSize: CGSize(width: 40, height: 120), onto: canvas, edge: .right, gap: 0))
        #expect(placed.rect == CGRect(x: 100, y: -20, width: 40, height: 120))
        #expect(placed.canvas == CGRect(x: 0, y: -20, width: 140, height: 120))
    }

    @Test func aGapSeparatesTheImage() throws {
        let placed = try #require(CombineLayout.place(imageSize: size, onto: canvas, edge: .right, gap: 10))
        #expect(placed.rect.minX == 110)
        #expect(placed.canvas.width == 150)
    }

    @Test func aCombineThatWouldPassTheLimitIsScaledDown() throws {
        let wide = CGRect(x: 0, y: 0, width: 16_000, height: 500)
        let placed = try #require(CombineLayout.place(imageSize: CGSize(width: 1000, height: 500), onto: wide, edge: .right, gap: 0))
        #expect(placed.rect.width == 383)
        #expect(placed.canvas.width == 16_383)
    }

    @Test func noRoomLeftMeansNoCombine() {
        #expect(CombineLayout.place(imageSize: size, onto: CGRect(x: 0, y: 0, width: 16_383, height: 80), edge: .right, gap: 0) == nil)
    }

    @Test func dropZonesLineTheEdges() {
        let area = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(CombineLayout.dropZones(in: area, thickness: 60).count == 4)
        #expect(CombineLayout.edge(at: CGPoint(x: 390, y: 150), in: area, thickness: 60) == .right)
        #expect(CombineLayout.edge(at: CGPoint(x: 10, y: 150), in: area, thickness: 60) == .left)
        #expect(CombineLayout.edge(at: CGPoint(x: 200, y: 10), in: area, thickness: 60) == .top)
        #expect(CombineLayout.edge(at: CGPoint(x: 200, y: 290), in: area, thickness: 60) == .bottom)
        #expect(CombineLayout.edge(at: CGPoint(x: 200, y: 150), in: area, thickness: 60) == nil)
    }

    @Test func aCanvasWhoseOriginIsntZeroPlacesFromItsOwnEdges() throws {
        let moved = CGRect(x: -50, y: 20, width: 100, height: 80) // x -50…50, y 20…100
        let right = try #require(CombineLayout.place(imageSize: size, onto: moved, edge: .right, gap: 0))
        #expect(right.rect == CGRect(x: 50, y: 50, width: 40, height: 20))
        #expect(right.canvas == CGRect(x: -50, y: 20, width: 140, height: 80))
        let left = try #require(CombineLayout.place(imageSize: size, onto: moved, edge: .left, gap: 10))
        #expect(left.rect == CGRect(x: -100, y: 50, width: 40, height: 20))
        #expect(left.canvas == CGRect(x: -100, y: 20, width: 150, height: 80))
        let top = try #require(CombineLayout.place(imageSize: size, onto: moved, edge: .top, gap: 10))
        #expect(top.rect == CGRect(x: -20, y: -10, width: 40, height: 20))
        #expect(top.canvas == CGRect(x: -50, y: -10, width: 100, height: 110))
        let bottom = try #require(CombineLayout.place(imageSize: size, onto: moved, edge: .bottom, gap: 10))
        #expect(bottom.rect == CGRect(x: -20, y: 110, width: 40, height: 20))
        #expect(bottom.canvas == CGRect(x: -50, y: 20, width: 100, height: 110))
    }

    @Test func aCombinedCanvasCanBeCombinedAgain() throws {
        let first = try #require(CombineLayout.place(imageSize: size, onto: canvas, edge: .left, gap: 0))
        let second = try #require(CombineLayout.place(imageSize: size, onto: first.canvas, edge: .left, gap: 0))
        #expect(second.rect == CGRect(x: -80, y: 30, width: 40, height: 20))
        #expect(second.canvas == CGRect(x: -80, y: 0, width: 180, height: 80))
    }

    @Test func theLimitScalesAnImageDownOnEverySide() throws {
        // 16 000 wide with 383 left; 1000×500 shrinks to 383×191.5, which rounds to 192.
        let wide = CGRect(x: 1000, y: 0, width: 16_000, height: 500)
        let left = try #require(CombineLayout.place(imageSize: CGSize(width: 1000, height: 500), onto: wide, edge: .left, gap: 0))
        #expect(left.rect == CGRect(x: 617, y: 154, width: 383, height: 192))
        #expect(left.canvas == CGRect(x: 617, y: 0, width: 16_383, height: 500))
        // 16 000 tall, a 10-pixel gap and 373 left; 500×1000 shrinks to 373 tall, 187 wide.
        let tall = CGRect(x: 0, y: 500, width: 500, height: 16_000)
        let top = try #require(CombineLayout.place(imageSize: CGSize(width: 500, height: 1000), onto: tall, edge: .top, gap: 10))
        #expect(top.rect.height == 373)
        #expect(top.rect.width == 187)
        #expect(top.rect.maxY == 490)
        #expect(top.canvas.height == 16_383)
        let bottom = try #require(CombineLayout.place(imageSize: CGSize(width: 500, height: 1000),
                                                      onto: CGRect(x: 0, y: 0, width: 500, height: 16_000), edge: .bottom, gap: 10))
        #expect(bottom.rect.minY == 16_010)
        #expect(bottom.rect.height == 373)
        #expect(bottom.canvas.height == 16_383)
    }

    @Test func anImageLongerThanTheLimitAcrossTheOtherAxisIsScaledToo() throws {
        // Beside the right edge, the image's height is what passes the limit: the canvas grows to 16 383 tall, not past it.
        let right = try #require(CombineLayout.place(imageSize: CGSize(width: 100, height: 40_000), onto: canvas, edge: .right, gap: 0))
        #expect(right.rect.height == 16_383)
        #expect(right.rect.width == 41)
        #expect(right.canvas.height == 16_383)
        let top = try #require(CombineLayout.place(imageSize: CGSize(width: 40_000, height: 100), onto: canvas, edge: .top, gap: 0))
        #expect(top.rect.width == 16_383)
        #expect(top.canvas.width == 16_383)
    }

    @Test func aSliverIsNoCombine() throws {
        // 3 pixels left: 1000×500 would come out 3×2.
        #expect(CombineLayout.place(imageSize: CGSize(width: 1000, height: 500), onto: CGRect(x: 0, y: 0, width: 16_380, height: 80),
                                    edge: .right, gap: 0) == nil)
        // 23 left: 23×12, still under 16 on a side.
        #expect(CombineLayout.place(imageSize: CGSize(width: 1000, height: 500), onto: CGRect(x: 0, y: 0, width: 16_360, height: 80),
                                    edge: .right, gap: 0) == nil)
        // 43 left: 43×22 is a picture.
        let fits = try #require(CombineLayout.place(imageSize: CGSize(width: 1000, height: 500),
                                                    onto: CGRect(x: 0, y: 0, width: 16_340, height: 80), edge: .right, gap: 0))
        #expect(fits.rect.size == CGSize(width: 43, height: 22))
        // A small image that needed no scaling is combined as it is.
        let icon = try #require(CombineLayout.place(imageSize: CGSize(width: 10, height: 8), onto: canvas, edge: .right, gap: 0))
        #expect(icon.rect.size == CGSize(width: 10, height: 8))
    }
}

@MainActor
struct ImageInsertionTests {
    private func insertedImage(_ h: EditorHarness) -> ImageObject? {
        guard let object = h.editor.document.objects.last, case .image(let image) = object.kind else { return nil }
        return image
    }

    private func insertedObject(_ h: EditorHarness) -> AnnotationObject? {
        guard let object = h.editor.document.objects.last, case .image = object.kind else { return nil }
        return object
    }

    private func isApproximately(_ rect: CGRect, _ expected: CGRect) -> Bool {
        [rect.minX - expected.minX, rect.minY - expected.minY, rect.width - expected.width, rect.height - expected.height]
            .allSatisfy { abs($0) < 0.001 }
    }

    private let red = TestBitmaps.red, green = TestBitmaps.green, blue = TestBitmaps.blue, yellow = TestBitmaps.yellow

    @Test func anImageGoesInTheMiddleOfWhatIsVisibleAsOneStep() throws {
        let h = EditorHarness(pixelScale: 2) // 100×80 output pixels
        let picture = TestBitmaps.solid(40, 20, TestBitmaps.red)
        h.act { #expect(h.editor.insertImage(picture, scale: 2, .centered(visible: CGRect(x: 0, y: 0, width: 50, height: 40)))) }
        let inserted = try #require(insertedImage(h))
        // A 2× image in a 2× document keeps its pixels: 40×20, centred on the visible area's middle (25, 20).
        #expect(inserted.rect == CGRect(x: 5, y: 10, width: 40, height: 20))
        #expect(h.editor.images[inserted.image] != nil)
        #expect(inserted.image.name.hasPrefix("images/"))
        #expect(h.editor.selection == Set(h.editor.document.objects.map(\.id)))
        #expect(h.editor.undoManager.undoActionName == "Add Image")
        h.editor.undoManager.undo()
        #expect(h.editor.document.objects.isEmpty)
    }

    @Test func aDropPointCentresTheImageThere() throws {
        let h = EditorHarness()
        h.act { #expect(h.editor.insertImage(TestBitmaps.solid(40, 20, TestBitmaps.red), scale: 1, .at(CGPoint(x: 30, y: 30)))) }
        let inserted = try #require(insertedImage(h))
        #expect(inserted.rect == CGRect(x: 10, y: 20, width: 40, height: 20))
    }

    @Test func aDropZoneCombinesBesideTheCanvasAsOneStep() throws {
        let h = EditorHarness() // 100×80 at 1×
        h.act { #expect(h.editor.insertImage(TestBitmaps.solid(40, 20, TestBitmaps.red), scale: 1, .beside(.right))) }
        let inserted = try #require(insertedImage(h))
        #expect(inserted.rect == CGRect(x: 100, y: 30, width: 40, height: 20))
        #expect(h.editor.document.canvasRect == CGRect(x: 0, y: 0, width: 140, height: 80))
        #expect(h.editor.undoManager.undoActionName == "Combine Images")
        h.editor.undoManager.undo()
        #expect(h.editor.document.canvasRect == nil)
        #expect(h.editor.document.objects.isEmpty)
    }

    @Test func anImageAddedAfterRotatingShowsUpright() throws {
        let h = EditorHarness(baseSize: CGSize(width: 40, height: 20), ops: [.rotateRight]) // the picture is 20×40
        let picture = TestBitmaps.split(20, 10, left: TestBitmaps.red, right: TestBitmaps.blue)
        h.act { #expect(h.editor.insertImage(picture, scale: 1, .centered(visible: h.editor.document.canvasBounds))) }
        // 20×10 scaled to 80% of the 20-pixel-wide canvas: 16×8 at (2, 16), in output pixels.
        let rendered = try #require(Renderer.render(h.editor.document, images: h.editor.images))
        #expect(TestBitmaps.pixel(rendered, 4, 20) == .init(r: 255, g: 0, b: 0, a: 255))
        #expect(TestBitmaps.pixel(rendered, 15, 20) == .init(r: 0, g: 0, b: 255, a: 255))
    }

    @Test func aHugeImageIsStoredAt16383PixelsAtMost() throws {
        let h = EditorHarness()
        h.act { #expect(h.editor.insertImage(TestBitmaps.solid(20_000, 4, TestBitmaps.red), scale: 1, .centered(visible: h.editor.document.canvasBounds))) }
        let inserted = try #require(insertedImage(h))
        #expect(h.editor.images[inserted.image]?.width == 16_383)
        #expect(inserted.rect.width == 80) // 80% of the 100-pixel canvas
    }

    @Test func shadowsReachImageObjects() {
        let picture = AnnotationObject(kind: .image(ImageObject(rect: CGRect(x: 0, y: 0, width: 10, height: 10), image: ImageRef(name: "images/a.png"))),
                                       style: ObjectStyle(color: .black, lineWidth: 1, shadow: false))
        let h = EditorHarness(objects: [picture])
        h.editor.selection = [picture.id]
        h.act { h.editor.setShadows(true) }
        #expect(h.editor.object(picture.id)?.style.shadow == true)
    }

    // Like the other canvas and object commands, inserting does nothing in crop mode or under a live change. Each of these
    // runs outside `act`: a refused insertion registers no undo.

    @Test func nothingIsInsertedWhileACropIsBeingEdited() {
        let h = EditorHarness()
        h.editor.tool = .crop
        #expect(h.editor.crop != nil)
        let picture = TestBitmaps.solid(40, 20, TestBitmaps.red)
        let before = h.editor.document
        let imagesBefore = h.editor.images.images.count
        for insertion in [ImageInsertion.centered(visible: before.canvasBounds), .at(CGPoint(x: 30, y: 30)), .beside(.right)] {
            #expect(!h.editor.insertImage(picture, scale: 1, insertion), "\(insertion)")
        }
        #expect(h.editor.document == before)
        #expect(h.editor.images.images.count == imagesBefore)
        #expect(h.editor.selection.isEmpty)
        #expect(!h.editor.undoManager.canUndo)
        #expect(h.editor.crop != nil)
    }

    @Test func nothingIsInsertedDuringALiveChange() {
        let h = EditorHarness()
        h.editor.beginLiveChange()
        let picture = TestBitmaps.solid(40, 20, TestBitmaps.red)
        let before = h.editor.document
        let imagesBefore = h.editor.images.images.count
        for insertion in [ImageInsertion.centered(visible: before.canvasBounds), .at(CGPoint(x: 30, y: 30)), .beside(.right)] {
            #expect(!h.editor.insertImage(picture, scale: 1, insertion), "\(insertion)")
        }
        #expect(h.editor.document == before)
        #expect(h.editor.images.images.count == imagesBefore)
        #expect(h.editor.selection.isEmpty)
        #expect(h.editor.isInLiveChange)
        h.editor.cancelLiveChange()
        #expect(!h.editor.undoManager.canUndo)
        // With the live change over, the same insertion goes through.
        h.act { #expect(h.editor.insertImage(picture, scale: 1, .at(CGPoint(x: 30, y: 30)))) }
        #expect(insertedImage(h) != nil)
    }

    // MARK: Orientation and placement in a transformed document

    private func rgba(_ color: CGColor) -> TestBitmaps.RGBA {
        let c = color.components ?? []
        return .init(r: UInt8((c[0] * 255).rounded()), g: UInt8((c[1] * 255).rounded()), b: UInt8((c[2] * 255).rounded()), a: 255)
    }

    @Test func anExtendedRangeImageCanBeInsertedAfterRotateAndFlip() throws {
        for ops in [[ImageOp.rotateRight], [.flipHorizontal], [.rotateLeft, .flipVertical]] {
            let h = EditorHarness(baseSize: CGSize(width: 40, height: 20), ops: ops)
            let picture = TestBitmaps.extendedSRGB(20, 10, TestBitmaps.red)
            h.act { #expect(h.editor.insertImage(picture, scale: 1, .centered(visible: h.editor.document.canvasBounds)), "\(ops)") }
            let inserted = try #require(insertedImage(h), "\(ops)")
            let stored = try #require(h.editor.images[inserted.image], "\(ops)")
            // A turned picture is stored turned; one only mirrored keeps its size.
            let turned = ops.contains(.rotateRight) || ops.contains(.rotateLeft)
            #expect(stored.width == (turned ? 10 : 20), "\(ops)")
            #expect(stored.height == (turned ? 20 : 10), "\(ops)")
            let rendered = try #require(Renderer.render(h.editor.document, images: h.editor.images), "\(ops)")
            let center = h.editor.document.canvasBounds
            #expect(TestBitmaps.pixel(rendered, Int(center.midX), Int(center.midY)) == rgba(TestBitmaps.red), "\(ops)")
        }
    }

    /// Image operations that turn, mirror and scale, alone and together.
    private static let transforms: [[ImageOp]] = [
        [.flipHorizontal], [.flipVertical], [.rotateLeft], [.rotateRight, .flipHorizontal], [.flipVertical, .rotateLeft],
        [.resize(width: 120, height: 60)], [.rotateRight, .resize(width: 80, height: 120)],
    ]

    @Test func anImageShowsUprightAtItsRectInAnyTransformedDocument() throws {
        // 20×10 picture, each quarter its own color. Wherever it lands in the output it reads the same way up.
        let picture = TestBitmaps.quadrants(20, 10, topLeft: red, topRight: green, bottomLeft: blue, bottomRight: yellow)
        let insertions: [(String, ImageInsertion)] = [
            ("centered", .centered(visible: CGRect(x: 0, y: 0, width: 1000, height: 1000))), ("at", .at(CGPoint(x: 25, y: 20))),
            ("beside right", .beside(.right)), ("beside left", .beside(.left)), ("beside top", .beside(.top)),
            ("beside bottom", .beside(.bottom)),
        ]
        for ops in Self.transforms {
            for (name, insertion) in insertions {
                let label = Comment(rawValue: "\(name) after \(ops)")
                let h = EditorHarness(baseSize: CGSize(width: 60, height: 40), ops: ops)
                h.preferences[Prefs.annotateObjectShadows] = false
                let canvas = h.editor.document.canvasBounds
                let expected: CGRect = switch insertion {
                case .centered: CGRect(x: canvas.midX - 10, y: canvas.midY - 5, width: 20, height: 10)
                case .at: CGRect(x: 15, y: 15, width: 20, height: 10)
                case .beside(.right): CGRect(x: canvas.maxX, y: canvas.midY - 5, width: 20, height: 10)
                case .beside(.left): CGRect(x: canvas.minX - 20, y: canvas.midY - 5, width: 20, height: 10)
                case .beside(.top): CGRect(x: canvas.midX - 10, y: canvas.minY - 10, width: 20, height: 10)
                case .beside(.bottom): CGRect(x: canvas.midX - 10, y: canvas.maxY, width: 20, height: 10)
                }
                h.act { #expect(h.editor.insertImage(picture, scale: 1, insertion), label) }
                let object = try #require(insertedObject(h), label)
                // The object is in base pixels; through the document it is the rect asked for.
                #expect(isApproximately(h.editor.document.outputBounds(of: object), expected), label)
                let rendered = try #require(Renderer.render(h.editor.document, images: h.editor.images), label)
                let origin = h.editor.document.canvasBounds.origin
                func color(_ x: Double, _ y: Double) -> TestBitmaps.RGBA {
                    TestBitmaps.pixel(rendered, Int((x - origin.x).rounded(.down)), Int((y - origin.y).rounded(.down)))
                }
                let quarters: [(CGColor, Double, Double)] = [(red, 0.25, 0.25), (green, 0.75, 0.25), (blue, 0.25, 0.75), (yellow, 0.75, 0.75)]
                for (quarter, fx, fy) in quarters {
                    #expect(color(expected.minX + expected.width * fx, expected.minY + expected.height * fy) == rgba(quarter),
                            Comment(rawValue: "\(label.rawValue), quarter at \(fx), \(fy)"))
                }
                if case .beside = insertion { continue }
                // On the picture, just outside the rect is plain (shadows are off).
                let white = rgba(TestBitmaps.white)
                #expect(color(expected.minX - 2, expected.midY) == white, label)
                #expect(color(expected.maxX + 1.5, expected.midY) == white, label)
                #expect(color(expected.midX, expected.minY - 2) == white, label)
                #expect(color(expected.midX, expected.maxY + 1.5) == white, label)
            }
        }
    }

    // MARK: Scales

    @Test func aRetinaImageInAOneXDocumentKeepsItsSizeOnScreen() throws {
        let h = EditorHarness() // pixelScale 1
        h.act { #expect(h.editor.insertImage(TestBitmaps.solid(40, 20, TestBitmaps.red), scale: 2, .centered(visible: h.editor.document.canvasBounds))) }
        let inserted = try #require(insertedImage(h))
        #expect(inserted.rect.size == CGSize(width: 20, height: 10))
    }

    @Test func aOneXImageInARetinaDocumentIsTwiceItsPixels() throws {
        let h = EditorHarness(pixelScale: 2) // 100×80 output pixels
        h.act { #expect(h.editor.insertImage(TestBitmaps.solid(40, 20, TestBitmaps.red), scale: 1, .centered(visible: h.editor.document.canvasBounds))) }
        let inserted = try #require(insertedImage(h))
        #expect(inserted.rect.size == CGSize(width: 80, height: 40))
    }

    // MARK: Shadows

    @Test func aCombinedImageCastsNoShadowAndOthersFollowTheSetting() throws {
        let picture = TestBitmaps.solid(40, 20, TestBitmaps.red)
        for shadows in [true, false] {
            let h = EditorHarness()
            h.preferences[Prefs.annotateObjectShadows] = shadows
            h.act { #expect(h.editor.insertImage(picture, scale: 1, .at(CGPoint(x: 30, y: 30)))) }
            let dropped = try #require(insertedObject(h))
            #expect(dropped.style.shadow == shadows)
            h.act { #expect(h.editor.insertImage(picture, scale: 1, .centered(visible: h.editor.document.canvasBounds))) }
            let centred = try #require(insertedObject(h))
            #expect(centred.style.shadow == shadows)
            // Beside the canvas nothing should fall across the seam.
            h.act { #expect(h.editor.insertImage(picture, scale: 1, .beside(.right))) }
            let combined = try #require(insertedObject(h))
            #expect(combined.style.shadow == false)
        }
    }

    // MARK: Kept inside the canvas

    @Test func aCentredImageNeverGrowsTheCanvas() throws {
        let h = EditorHarness() // 100×80, auto-expand on by default
        #expect(h.preferences[Prefs.annotateAutoExpandCanvas])
        // Zoomed into the top-left corner: the visible middle is (15, 10), and the 80×62 image would hang off two sides.
        h.act {
            #expect(h.editor.insertImage(TestBitmaps.solid(90, 70, TestBitmaps.red), scale: 1,
                                         .centered(visible: CGRect(x: 0, y: 0, width: 30, height: 20))))
        }
        let inserted = try #require(insertedImage(h))
        #expect(inserted.rect == CGRect(x: 0, y: 0, width: 80, height: 62))
        #expect(h.editor.document.canvasRect == nil)
    }

    @Test func aDropPointNeverGrowsTheCanvasEither() throws {
        let h = EditorHarness()
        h.act { #expect(h.editor.insertImage(TestBitmaps.solid(40, 20, TestBitmaps.red), scale: 1, .at(.zero))) }
        let corner = try #require(insertedImage(h))
        #expect(corner.rect == CGRect(x: 0, y: 0, width: 40, height: 20))
        h.act { #expect(h.editor.insertImage(TestBitmaps.solid(40, 20, TestBitmaps.red), scale: 1, .at(CGPoint(x: 500, y: 500)))) }
        let far = try #require(insertedImage(h))
        #expect(far.rect == CGRect(x: 60, y: 60, width: 40, height: 20))
        #expect(h.editor.document.canvasRect == nil)
    }

    @Test func aCroppedCanvasKeepsTheImageInsideItToo() throws {
        let h = EditorHarness(canvasRect: CGRect(x: 20, y: 20, width: 50, height: 40))
        h.act { #expect(h.editor.insertImage(TestBitmaps.solid(40, 20, TestBitmaps.red), scale: 1, .at(.zero))) }
        let inserted = try #require(insertedImage(h))
        #expect(inserted.rect == CGRect(x: 20, y: 20, width: 40, height: 20))
        #expect(h.editor.document.canvasRect == CGRect(x: 20, y: 20, width: 50, height: 40))
    }

    // MARK: Slivers

    @Test func aCombineLeavingOnlyASliverIsRefused() {
        let h = EditorHarness(canvasRect: CGRect(x: 0, y: 0, width: 16_380, height: 80))
        let before = h.editor.document
        let imagesBefore = h.editor.images.images.count
        // 3 pixels of room: the image would be 3×2. The caller falls back to the drop point.
        #expect(!h.editor.insertImage(TestBitmaps.solid(1000, 500, TestBitmaps.red), scale: 1, .beside(.right)))
        #expect(h.editor.document == before)
        #expect(h.editor.images.images.count == imagesBefore)
        #expect(!h.editor.undoManager.canUndo)
    }

    // MARK: A batch is one undo step of its own

    private func insertTwoBesideTheCanvas(_ h: EditorHarness) {
        #expect(h.editor.insertImage(TestBitmaps.solid(30, 30, TestBitmaps.red), scale: 1, .beside(.right)))
        #expect(h.editor.insertImage(TestBitmaps.solid(30, 30, TestBitmaps.blue), scale: 1, .beside(.right)))
    }

    private func imageCount(_ h: EditorHarness) -> Int {
        h.editor.document.objects.filter { if case .image = $0.kind { true } else { false } }.count
    }

    @Test func aBatchWithNoGroupOpenIsOneStep() {
        let h = EditorHarness() // 100×80
        var ran = false
        h.editor.asOneUndoStep {
            ran = true
            insertTwoBesideTheCanvas(h)
        }
        #expect(ran) // nothing to wait for
        #expect(imageCount(h) == 2)
        #expect(h.editor.document.canvasBounds.width == 160)
        h.editor.undoManager.undo()
        #expect(imageCount(h) == 0)
        #expect(h.editor.document.canvasRect == nil)
        #expect(!h.editor.undoManager.canUndo)
    }

    /// In the app the undo manager opens a group for each run loop event and joins into it everything recorded there, so a
    /// drop's batch would be undone together with the text edit the drop ended. The harness turns that off; an open group
    /// stands for the event's. The batch waits for it to close, and then makes a step of its own.
    @Test func aBatchWaitsForTheEventsGroupAndIsAStepApartFromItsEarlierChange() async throws {
        let h = EditorHarness()
        let manager = h.editor.undoManager
        manager.beginUndoGrouping() // the event
        h.editor.add(editorRectangle(), actionName: "Edit Text")
        var ran = false
        h.editor.asOneUndoStep {
            ran = true
            insertTwoBesideTheCanvas(h)
        }
        #expect(!ran) // the event's group is still open
        manager.endUndoGrouping() // the event ends
        for _ in 0..<200 where !ran { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ran)
        #expect(imageCount(h) == 2)
        #expect(h.editor.document.objects.count == 3)
        #expect(manager.groupingLevel == 0)
        manager.undo() // the batch, all of it
        #expect(imageCount(h) == 0)
        #expect(h.editor.document.objects.count == 1)
        #expect(h.editor.document.canvasRect == nil)
        manager.undo() // then the change before it
        #expect(h.editor.document.objects.isEmpty)
        #expect(!manager.canUndo)
        manager.redo()
        manager.redo()
        #expect(imageCount(h) == 2)
        #expect(h.editor.document.objects.count == 3)
    }
}
