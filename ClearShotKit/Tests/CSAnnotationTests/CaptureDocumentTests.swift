import CoreGraphics
import CSCapture
import CSCore
import CSHistory
import CSTestSupport
import Foundation
import Testing
@testable import CSAnnotation

/// A screenshot preset and a window preset with styles that tell them apart.
private let screenshotPreset = BackgroundPreset(name: "Screenshots", style: .standard)
private let windowPreset = BackgroundPreset(name: "Windows", style: .windowStandard)

/// `BackgroundStyle.standard` with `change` applied.
private func style(_ change: (inout BackgroundStyle) -> Void) -> BackgroundStyle {
    var style = BackgroundStyle.standard
    change(&style)
    return style
}

/// One row of the auto-apply table.
private func choice(window: Bool, shift: Bool, screenshot: BackgroundPreset? = nil, windowPreset: BackgroundPreset? = nil,
                    mode: WindowBackgroundMode = .transparent) -> CaptureBackgroundChoice {
    AutoApply.choice(isWindow: window, shiftHeld: shift, screenshotPreset: screenshot, windowPreset: windowPreset, windowMode: mode)
}

struct AutoApplyTests {
    @Test func anAreaWithAPresetGetsIt() {
        #expect(choice(window: false, shift: false, screenshot: screenshotPreset) == .preset(screenshotPreset.style))
    }

    @Test func shiftSkipsAnAreasPreset() {
        #expect(choice(window: false, shift: true, screenshot: screenshotPreset) == .none)
    }

    @Test func anAreaWithoutAPresetGetsNothingEvenWithShift() {
        #expect(choice(window: false, shift: true) == .none)
        #expect(choice(window: false, shift: false) == .none)
    }

    @Test func aWindowWithAPresetGetsIt() {
        #expect(choice(window: true, shift: false, windowPreset: windowPreset, mode: .transparent) == .preset(windowPreset.style))
        #expect(choice(window: true, shift: false, windowPreset: windowPreset, mode: .wallpaper) == .preset(windowPreset.style))
    }

    @Test func shiftSkipsAWindowPresetForTheWallpaperSettingAsItIs() {
        #expect(choice(window: true, shift: true, windowPreset: windowPreset, mode: .wallpaper) == .windowWallpaper)
    }

    @Test func shiftSkipsAWindowPresetForTheTransparentSettingAsItIs() {
        #expect(choice(window: true, shift: true, windowPreset: windowPreset, mode: .transparent) == .none)
    }

    @Test func withoutAWindowPresetShiftTurnsTransparentIntoWallpaper() {
        #expect(choice(window: true, shift: true, mode: .transparent) == .windowWallpaper)
    }

    @Test func withoutAWindowPresetShiftTurnsWallpaperIntoTransparent() {
        #expect(choice(window: true, shift: true, mode: .wallpaper) == .none)
    }

    @Test func aTransparentWindowWithoutAPresetGetsNothing() {
        #expect(choice(window: true, shift: false, mode: .transparent) == .none)
    }

    @Test func aWallpaperWindowWithoutAPresetGetsTheWallpaper() {
        #expect(choice(window: true, shift: false, mode: .wallpaper) == .windowWallpaper)
    }

    @Test func aWindowIgnoresTheScreenshotPreset() {
        #expect(choice(window: true, shift: false, screenshot: screenshotPreset, mode: .transparent) == .none)
        #expect(choice(window: true, shift: false, screenshot: screenshotPreset, mode: .wallpaper) == .windowWallpaper)
        #expect(choice(window: true, shift: true, screenshot: screenshotPreset, mode: .transparent) == .windowWallpaper)
    }

    @MainActor @Test func presetsResolveIDs() {
        withThrowawayDefaults("autoapply") { defaults in
            let preferences = Preferences(defaults: defaults)
            /// The two presets `AutoApply` finds, by name.
            @MainActor func names() -> [String?] {
                let presets = AutoApply.presets(in: preferences)
                return [presets.screenshot?.name, presets.window?.name]
            }
            #expect(names() == [nil, nil]) // nothing set: ""
            preferences[Prefs.backgroundPresets] = BackgroundPresetList([screenshotPreset])
            preferences[Prefs.windowBackgroundPresets] = BackgroundPresetList([windowPreset])
            preferences[Prefs.autoApplyBackgroundPresetID] = screenshotPreset.id.uuidString
            preferences[Prefs.autoApplyWindowBackgroundPresetID] = windowPreset.id.uuidString
            let found = AutoApply.presets(in: preferences)
            #expect(found.screenshot == screenshotPreset)
            #expect(found.window == windowPreset)
            // "" is none, and so is an id no preset of that kind has: unknown, another kind's, or not an id at all.
            preferences[Prefs.autoApplyBackgroundPresetID] = ""
            preferences[Prefs.autoApplyWindowBackgroundPresetID] = UUID().uuidString
            #expect(names() == [nil, nil])
            preferences[Prefs.autoApplyBackgroundPresetID] = windowPreset.id.uuidString
            preferences[Prefs.autoApplyWindowBackgroundPresetID] = "not an id"
            #expect(names() == [nil, nil])
        }
    }
}

final class CaptureDocumentTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "capture-documents-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// What `make` gives for `base` with `style` (and its picture), which must succeed.
    func made(_ base: CGImage, _ style: BackgroundStyle, picture: CGImage? = nil, pixelScale: Double = 1, isWindowShot: Bool = false)
        throws -> (document: AnnotationDocument, images: ImageStore, rendered: CGImage) {
        try #require(CaptureDocument.make(base: base, pixelScale: pixelScale, isWindowShot: isWindowShot,
                                          background: CaptureBackground(style: style, picture: picture)))
    }

    func details(_ kind: CaptureKind = .selection, name: String = "Shot", isTransparent: Bool = false) -> HistoryWriter.Details {
        HistoryWriter.Details(origin: .capture, captureKind: kind, displayName: name, savedURL: nil, scale: 2, appName: nil,
                              isTransparent: isTransparent, globalRect: .zero, createdAt: Date())
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    // MARK: The document

    @Test func aPresetMakesADocumentOverTheProcessedCapture() throws {
        let base = TestBitmaps.noise(40, 30)
        let asked = style {
            $0.fill = .color(RGBAColor(red: 0, green: 1, blue: 0))
            $0.padding = 20
            $0.shadow = 0
            $0.corners = 100 // out of range: clamped
        }
        let (document, images, rendered) = try made(base, asked, pixelScale: 2)
        #expect(document.base == AnnotationStorage.historyBase)
        #expect(document.baseSize == CGSize(width: 40, height: 30))
        #expect(document.pixelScale == 2)
        #expect(!document.isWindowShot)
        #expect(document.objects.isEmpty)
        #expect(document.background == DocumentBackground(style: asked.clamped()))
        #expect(document.background?.style.corners == 64)
        let stored = try #require(images[AnnotationStorage.historyBase])
        let baseIsTheCapture = TestBitmaps.bytes(stored) == TestBitmaps.bytes(base)
        #expect(baseIsTheCapture)
        #expect(images.images.count == 1) // a colour fill stores no picture
        // The render is the frame: 20 pt of padding at 2 px a point on each side.
        let frame = try #require(document.backgroundLayout()?.frame)
        #expect(frame.size == CGSize(width: 120, height: 110))
        #expect(CGSize(width: rendered.width, height: rendered.height) == frame.size)
        #expect(TestBitmaps.pixel(rendered, 1, 1) == TestBitmaps.RGBA(r: 0, g: 255, b: 0, a: 255))
    }

    @Test func aWindowShotIsMarkedAsOne() throws {
        let (document, _, _) = try made(TestBitmaps.noise(20, 20), .windowStandard, picture: TestBitmaps.noise(60, 60),
                                        isWindowShot: true)
        #expect(document.isWindowShot)
    }

    @Test(arguments: [BackgroundFill.desktop, .blurredDesktop, .systemWallpaper(fileName: "Sonoma.heic"), .custom(id: UUID()),
                      .windowWallpaper])
    func aMissingPictureFallsBackToTheFirstGradient(fill: BackgroundFill) throws {
        let asked = style { $0.fill = fill }
        let (document, images, rendered) = try made(TestBitmaps.noise(40, 30), asked, isWindowShot: fill == .windowWallpaper)
        let background = try #require(document.background)
        #expect(background.style == style { $0.fill = .gradient(.standard) }) // only the fill changes
        #expect(background.image == nil)
        #expect(images.images.count == 1)
        // The frame shows the gradient, not nothing.
        #expect(TestBitmaps.pixel(rendered, 1, 1).a == 255)
    }

    @Test func aDesktopPictureIsStoredPreparedAsJPG() throws {
        // A 3:2 frame for a 3:2 picture: covering it × 1.5 is exactly 1.5 × the frame on both axes.
        let asked = style {
            $0.fill = .desktop
            $0.padding = 10
        }
        let (document, images, _) = try made(TestBitmaps.solid(100, 60, TestBitmaps.blue), asked,
                                             picture: TestBitmaps.solid(6000, 4000, TestBitmaps.red))
        let frame = try #require(document.backgroundLayout()?.frame.size)
        #expect(frame == CGSize(width: 120, height: 80))
        let ref = try #require(document.background?.image)
        #expect(ref.name.hasPrefix("images/background-"))
        #expect(ref.name.hasSuffix(".jpg"))
        let stored = try #require(images[ref])
        #expect(Double(stored.width) <= frame.width * BackgroundImagePrep.coverFactor)
        #expect(Double(stored.height) <= frame.height * BackgroundImagePrep.coverFactor)
        #expect(CGSize(width: stored.width, height: stored.height) == CGSize(width: 180, height: 120))
        #expect(document.background?.style.fill == .desktop)
    }

    @Test func aWindowWallpaperIsStoredAsCaptured() throws {
        let window = TestBitmaps.transparent(40, 30, blocks: [CGRect(x: 5, y: 5, width: 30, height: 20)])
        let wallpaper = TestBitmaps.noise(6000, 40) // far bigger than the frame on one side: still not resized
        var asked = BackgroundStyle.windowStandard
        asked.fill = .windowWallpaper
        let (document, images, _) = try made(window, asked, picture: wallpaper, isWindowShot: true)
        let ref = try #require(document.background?.image)
        #expect(ref.name.hasSuffix(".jpg"))
        let stored = try #require(images[ref])
        #expect(stored.width == 6000 && stored.height == 40)
        let storedAsCaptured = TestBitmaps.bytes(stored) == TestBitmaps.bytes(wallpaper)
        #expect(storedAsCaptured)
        #expect(document.background?.style.fill == .windowWallpaper)
    }

    @Test func aNoneFillWithCornersIsTransparentAndSavesAsPNG() throws {
        // No padding and no shadow: only the corners can let anything through.
        let asked = style {
            $0.fill = .none
            $0.padding = 0
            $0.shadow = 0
            $0.corners = 12
        }
        let base = TestBitmaps.solid(60, 40, TestBitmaps.blue)
        #expect(!ImageOps.hasTransparentPixels(base))
        let (_, _, rendered) = try made(base, asked)
        #expect(rendered.width == 60 && rendered.height == 40)
        #expect(TestBitmaps.pixel(rendered, 0, 0).a == 0)
        #expect(TestBitmaps.pixel(rendered, 30, 20) == TestBitmaps.RGBA(r: 0, g: 0, b: 255, a: 255))
        let isTransparent = ImageOps.hasTransparentPixels(rendered)
        #expect(isTransparent)
        #expect(ExportFormatPolicy.format(preferred: .jpeg, isTransparent: isTransparent) == .png)
    }

    @Test func aDocumentThatCouldntBeReopenedIsntMade() {
        // A pixel scale `isWellFormed` refuses would leave an item whose document can never be read back.
        let made = CaptureDocument.make(base: TestBitmaps.noise(20, 20), pixelScale: 0, isWindowShot: false,
                                        background: CaptureBackground(style: .standard, picture: nil))
        #expect(made == nil)
    }

    // MARK: The history item

    @Test @MainActor func createItemWritesTheDocumentAndARenderedWorkingCopy() throws {
        let base = TestBitmaps.noise(40, 30)
        let asked = style {
            $0.fill = .desktop
            $0.padding = 16
        }
        let (document, images, rendered) = try made(base, asked, picture: TestBitmaps.noise(400, 300), pixelScale: 2)
        // The raw capture said transparent (a window shot, say); the render is opaque, and that is what the item records.
        #expect(!ImageOps.hasTransparentPixels(rendered))
        let item = try AnnotationStorage.createItem(document: document, images: images, rendered: rendered,
                                                    details: details(isTransparent: true), root: root)
        let folder = item.folder(in: root)
        let original = try #require(ImageOps.load(folder.appending(path: ".original.png")))
        let originalIsTheBase = TestBitmaps.bytes(original) == TestBitmaps.bytes(base)
        #expect(originalIsTheBase)
        #expect(exists(folder.appending(path: DocumentPackage.documentFileName)))
        let pictures = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "images").path(percentEncoded: false))
        #expect(pictures.count == 1)
        #expect(pictures.allSatisfy { $0.hasPrefix("background-") && $0.hasSuffix(".jpg") })
        let working = try #require(ImageOps.load(item.mediaURL(in: root)))
        let workingIsTheRender = TestBitmaps.bytes(working) == TestBitmaps.bytes(rendered)
        #expect(workingIsTheRender)
        #expect(exists(item.thumbnailURL(in: root)))
        #expect(item.hasDocument == true)
        #expect(item.pixelSize == CGSize(width: rendered.width, height: rendered.height))
        #expect(!item.isTransparent)
        #expect(item.scale == document.renderedScale)
        #expect(item.captureKind == .selection)
        let reloaded = try #require(HistoryStore(root: root).item(id: item.id))
        #expect(reloaded == item)
        let (opened, openedImages, recovered) = try AnnotationStorage.open(reloaded, root: root)
        #expect(!recovered)
        #expect(opened == document)
        let pictureRef = try #require(opened.background?.image)
        #expect(openedImages[pictureRef]?.width == images[pictureRef]?.width)
    }

    @Test @MainActor func createItemRecordsATransparentRender() throws {
        let asked = style {
            $0.fill = .none
            $0.padding = 8
        }
        let (document, images, rendered) = try made(TestBitmaps.noise(40, 30), asked)
        let item = try AnnotationStorage.createItem(document: document, images: images, rendered: rendered,
                                                    details: details(isTransparent: false), root: root)
        #expect(item.isTransparent)
        #expect(HistoryStore(root: root).item(id: item.id)?.isTransparent == true)
    }

    @Test @MainActor func aCreateThatFailsBeforeItsMetadataLeavesNoItem() throws {
        let (document, images, rendered) = try made(TestBitmaps.noise(40, 30), .standard)
        let id = UUID()
        // A directory where the working copy goes makes its write throw, after the document but before `meta.json`.
        let folder = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "Shot.png"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try AnnotationStorage.createItem(document: document, images: images, rendered: rendered, details: details(name: "Shot"),
                                             id: id, root: root)
        }
        #expect(exists(folder.appending(path: DocumentPackage.documentFileName))) // what came before was written
        #expect(!exists(folder.appending(path: HistoryItem.metadataFileName)))
        #expect(HistoryStore(root: root).items.isEmpty)
    }

    @Test(arguments: [(CaptureKind.window, true), (.selection, false), (.display, false)])
    func openingANewWindowItemMarksItAWindowShot(kind: CaptureKind, isWindowShot: Bool) throws {
        let item = try HistoryWriter.create(TestBitmaps.noise(20, 20), details: details(kind), root: root)
        let (document, _, _) = try AnnotationStorage.open(item, root: root)
        #expect(document.isWindowShot == isWindowShot)
    }

    @Test func anAnnotatedItemKeepsItsDocumentsWindowFlag() throws {
        // A window shot annotated before documents had the flag reads it as false, and keeps it.
        let item = try HistoryWriter.create(TestBitmaps.noise(20, 20), details: details(.window), root: root)
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        #expect(document.isWindowShot)
        document.isWindowShot = false
        let rendered = try #require(Renderer.render(document, images: images))
        let saved = try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
        let (reopened, _, recovered) = try AnnotationStorage.open(saved, root: root)
        #expect(!recovered)
        #expect(!reopened.isWindowShot)
    }
}
