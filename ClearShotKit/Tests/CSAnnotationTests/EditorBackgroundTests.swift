import CoreGraphics
import CSCore
import Foundation
import Testing
@testable import CSAnnotation

private let red = RGBAColor(red: 1, green: 0, blue: 0)
private let blue = RGBAColor(red: 0, green: 0, blue: 1)
private let green = RGBAColor(red: 0, green: 1, blue: 0)

/// A style unlike either standard one.
private let customStyle = BackgroundStyle(fill: .color(blue), padding: 20, inset: 4, insetColor: .auto, shadow: 0, corners: 6,
                                          autoBalance: false, alignment: .topLeft, ratio: .square)

extension EditorHarness {
    /// `act` for an action that awaits: whatever it registers becomes one undo step.
    func actAsync(_ body: () async -> Void) async {
        editor.undoManager.beginUndoGrouping()
        await body()
        editor.undoManager.endUndoGrouping()
    }
}

/// Pictures for image-backed fills, counting what is asked of each source. While `holdsDesktop` is on, the desktop waits
/// for `release()` before it answers. `whenDesktopAnswers` runs on the main actor as soon as it is free after the desktop
/// has answered: while the apply that asked prepares the picture (`answered` is that run).
@MainActor
final class FakePictures {
    var desktop: CGImage? = TestBitmaps.solid(300, 200, TestBitmaps.blue)
    var wallpapers: [String: CGImage] = [:]
    var customs: [UUID: CGImage] = [:]
    private(set) var desktopCalls = 0
    private(set) var wallpaperCalls: [String] = []
    private(set) var customCalls: [UUID] = []
    var holdsDesktop = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var whenDesktopAnswers: (@MainActor @Sendable () -> Void)?
    private(set) var answered: Task<Void, Never>?

    var source: BackgroundPictureSource {
        BackgroundPictureSource(
            desktop: { [self] in
                desktopCalls += 1
                if holdsDesktop { await withCheckedContinuation { held.append($0) } }
                if let hook = whenDesktopAnswers { answered = Task { @MainActor in hook() } }
                return desktop
            },
            systemWallpaper: { [self] name in
                wallpaperCalls.append(name)
                return wallpapers[name]
            },
            customPicture: { [self] id in
                customCalls.append(id)
                return customs[id]
            })
    }

    /// Lets every held desktop request answer.
    func release() {
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    /// Returns once the desktop has been asked `count` times.
    func waitForDesktopCalls(_ count: Int) async {
        while desktopCalls < count { await Task.yield() }
    }
}

/// A 100×80 white picture with a black 60×40 block in the middle: a uniform 20-pixel margin all round.
private func marginedPicture() -> CGImage {
    let context = TestBitmaps.context(100, 80)
    context.setFillColor(TestBitmaps.white)
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
    context.setFillColor(TestBitmaps.black)
    context.fill(CGRect(x: 20, y: 20, width: 60, height: 40))
    return context.makeImage()!
}

@MainActor
struct EditorBackgroundTests {
    // MARK: The panel

    @Test func openingThePanelAppliesTheStandardStyleAsOneStep() async {
        let h = EditorHarness()
        #expect(!h.editor.isBackgroundPanelOpen)
        await h.actAsync { await h.editor.openBackgroundPanel(pictures: .none) }
        #expect(h.editor.isBackgroundPanelOpen)
        #expect(h.editor.document.background == DocumentBackground(style: .standard))
        #expect(h.editor.undoManager.undoActionName == "Add Background")
        h.editor.undoManager.undo()
        #expect(h.editor.document.background == nil)
        #expect(!h.editor.undoManager.canUndo)
        // Undo leaves the panel open; without a background, its style edits do nothing.
        #expect(h.editor.isBackgroundPanelOpen)
        h.editor.updateBackgroundStyle("Change Padding") { $0.padding = 10 } // outside `act`: a registration would raise
        #expect(h.editor.document.background == nil)
    }

    @Test func openingThePanelAppliesPreviousSettings() async {
        let h = EditorHarness()
        h.preferences[Prefs.lastBackgroundStyle] = RememberedBackgroundStyle(customStyle)
        #expect(h.editor.defaultBackgroundStyle == customStyle)
        await h.actAsync { await h.editor.openBackgroundPanel(pictures: .none) }
        #expect(h.editor.document.background == DocumentBackground(style: customStyle))
    }

    @Test func aWindowShotUsesWindowDefaultsAndItsOwnPrevious() async throws {
        let h = EditorHarness(isWindowShot: true)
        // A screenshot's Previous Settings aren't a window shot's.
        h.preferences[Prefs.lastBackgroundStyle] = RememberedBackgroundStyle(customStyle)
        #expect(h.editor.presetKind == .window)
        #expect(h.editor.defaultBackgroundStyle == .windowStandard)
        let pictures = FakePictures()
        await h.actAsync { await h.editor.openBackgroundPanel(pictures: pictures.source) }
        let background = try #require(h.editor.document.background)
        #expect(background.style == .windowStandard)
        #expect(pictures.desktopCalls == 1)
        let ref = try #require(background.image)
        #expect(ref.name.hasPrefix("images/background-"))
        #expect(ref.name.hasSuffix(".jpg")) // the desktop is opaque
        #expect(h.editor.images[ref] != nil)

        h.preferences[Prefs.lastWindowBackgroundStyle] = RememberedBackgroundStyle(customStyle)
        #expect(h.editor.defaultBackgroundStyle == customStyle)
        #expect(EditorHarness().editor.presetKind == .screenshot)
    }

    @Test func openingThePanelOnABackgroundChangesNothing() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        h.preferences[Prefs.lastBackgroundStyle] = RememberedBackgroundStyle(customStyle)
        let before = h.editor.document
        await h.editor.openBackgroundPanel(pictures: .none) // outside `act`: a registration would raise
        #expect(h.editor.isBackgroundPanelOpen)
        #expect(h.editor.document == before)
        h.editor.undoManager.undo()
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func openingThePanelDuringACropAppliesNothing() async {
        let h = EditorHarness()
        h.editor.tool = .crop
        await h.editor.openBackgroundPanel(pictures: .none) // outside `act`: a registration would raise
        #expect(h.editor.isBackgroundPanelOpen)
        #expect(h.editor.document.background == nil)
        #expect(!h.editor.undoManager.canUndo)

        // Nor while a live change is open.
        let dragging = EditorHarness()
        dragging.editor.beginLiveChange()
        await dragging.editor.openBackgroundPanel(pictures: .none)
        #expect(dragging.editor.isBackgroundPanelOpen)
        #expect(dragging.editor.document.background == nil)
        dragging.editor.cancelLiveChange()
        #expect(!dragging.editor.undoManager.canUndo)
    }

    @Test func closingThePanelKeepsTheBackground() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.openBackgroundPanel(pictures: .none) }
        h.editor.closeBackgroundPanel()
        #expect(!h.editor.isBackgroundPanelOpen)
        #expect(h.editor.document.background == DocumentBackground(style: .standard))
        h.editor.undoManager.undo()
        #expect(h.editor.document.background == nil)
        #expect(!h.editor.undoManager.canUndo)
    }

    // MARK: Pictures

    @Test func aMissingCustomPictureFallsBackToTheFirstGradient() async {
        let id = UUID()
        let h = EditorHarness()
        let pictures = FakePictures()
        await h.actAsync { await h.editor.setBackgroundFill(.custom(id: id), pictures: pictures.source) }
        #expect(pictures.customCalls == [id])
        #expect(h.editor.document.background?.style.fill == .gradient(.standard))
        #expect(h.editor.document.background?.image == nil)
        #expect(h.editor.images.images.count == 1)

        // Every other missing source as well, the rest of the style kept.
        let missing: [BackgroundFill] = [.systemWallpaper(fileName: "Gone.heic"), .desktop, .blurredDesktop, .windowWallpaper]
        for fill in missing {
            let h = EditorHarness()
            let pictures = FakePictures()
            pictures.desktop = nil
            var style = customStyle
            style.fill = fill
            await h.actAsync { await h.editor.applyBackground(style, actionName: "Apply", pictures: pictures.source) }
            var expected = customStyle
            expected.fill = .gradient(.standard)
            #expect(h.editor.document.background == DocumentBackground(style: expected), "\(fill)")
        }
    }

    @Test func anImageBackedFillStoresItsPictureInTheSameStep() async throws {
        let h = EditorHarness()
        let pictures = FakePictures()
        pictures.desktop = TestBitmaps.solid(1000, 800, TestBitmaps.blue)
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        await h.actAsync { await h.editor.setBackgroundFill(.desktop, pictures: pictures.source) }
        let background = try #require(h.editor.document.background)
        var expected = BackgroundStyle.standard
        expected.fill = .desktop
        #expect(background.style == expected)
        let ref = try #require(background.image)
        let stored = try #require(h.editor.images[ref])
        // Prepared for the new style's frame (228×208 around 100×80), which it covers 1.5 times over.
        let size = BackgroundImagePrep.storedSize(source: CGSize(width: 1000, height: 800), frame: CGSize(width: 228, height: 208),
                                                  blurred: false)
        #expect(CGSize(width: stored.width, height: stored.height) == size)
        #expect(h.editor.undoManager.undoActionName == "Change Background")

        h.editor.undoManager.undo()
        #expect(h.editor.document.background == DocumentBackground(style: .standard))
        // The picture stays in the store, so redo finds it.
        h.editor.undoManager.redo()
        #expect(h.editor.document.background?.image == ref)
        #expect(h.editor.images[ref] != nil)

        // Added with the background itself: one undo takes both away.
        let fresh = EditorHarness()
        await fresh.actAsync { await fresh.editor.applyBackground(expected, actionName: "Apply", pictures: pictures.source) }
        #expect(fresh.editor.document.background?.image != nil)
        fresh.editor.undoManager.undo()
        #expect(fresh.editor.document.background == nil)
        #expect(!fresh.editor.undoManager.canUndo)
    }

    @Test func eachPictureFillAsksItsOwnSource() async throws {
        let id = UUID()
        let pictures = FakePictures()
        pictures.desktop = TestBitmaps.solid(1000, 800, TestBitmaps.blue)
        pictures.wallpapers["Sky.heic"] = TestBitmaps.solid(64, 48, TestBitmaps.green)
        pictures.customs[id] = TestBitmaps.solid(64, 48, TestBitmaps.yellow)
        let h = EditorHarness()

        await h.actAsync { await h.editor.setBackgroundFill(.systemWallpaper(fileName: "Sky.heic"), pictures: pictures.source) }
        #expect(pictures.wallpaperCalls == ["Sky.heic"])
        #expect(h.editor.document.background?.style.fill == .systemWallpaper(fileName: "Sky.heic"))
        #expect(h.editor.document.background?.image != nil)

        await h.actAsync { await h.editor.setBackgroundFill(.custom(id: id), pictures: pictures.source) }
        #expect(pictures.customCalls == [id])
        #expect(h.editor.document.background?.style.fill == .custom(id: id))

        // The blurred desktop is stored blurred, small.
        await h.actAsync { await h.editor.setBackgroundFill(.blurredDesktop, pictures: pictures.source) }
        #expect(pictures.desktopCalls == 1)
        let ref = try #require(h.editor.document.background?.image)
        let stored = try #require(h.editor.images[ref])
        #expect(max(stored.width, stored.height) <= BackgroundBlur.maximumSide)

        // The blurred screenshot is made when drawn: nothing is asked or stored.
        await h.actAsync { await h.editor.setBackgroundFill(.blurredScreenshot, pictures: pictures.source) }
        #expect(h.editor.document.background?.image == nil)
        #expect(pictures.desktopCalls == 1)
    }

    @Test func aLateResultForAnOlderRequestIsDropped() async {
        let h = EditorHarness()
        let pictures = FakePictures()
        pictures.holdsDesktop = true
        let first = Task { await h.editor.setBackgroundFill(.desktop, pictures: pictures.source) }
        await pictures.waitForDesktopCalls(1)
        await h.actAsync { await h.editor.setBackgroundFill(.color(blue), pictures: pictures.source) }
        pictures.release()
        await first.value
        var expected = BackgroundStyle.standard
        expected.fill = .color(blue)
        #expect(h.editor.document.background == DocumentBackground(style: expected))
        #expect(h.editor.images.images.count == 1) // the late picture was never stored
        h.editor.undoManager.undo()
        #expect(h.editor.document.background == nil)
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func aLateResultAfterRemovingTheBackgroundIsDropped() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        let pictures = FakePictures()
        pictures.holdsDesktop = true
        let pending = Task { await h.editor.setBackgroundFill(.desktop, pictures: pictures.source) }
        await pictures.waitForDesktopCalls(1)
        h.act { h.editor.removeBackground() }
        pictures.release()
        await pending.value
        #expect(h.editor.document.background == nil)
        #expect(h.editor.undoManager.undoActionName == "Remove Background")
    }

    // A picture that arrives after the background has changed since it was asked for (an edit, an undo, a redo) is dropped:
    // it would put back the style from before. Each late result is awaited outside `act`, so one that registered would raise.

    @Test func aTypedEditWhileThePictureLoadsWins() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        let pictures = FakePictures()
        pictures.holdsDesktop = true
        let pending = Task { await h.editor.setBackgroundFill(.desktop, pictures: pictures.source) }
        await pictures.waitForDesktopCalls(1)
        h.act { h.editor.updateBackgroundStyle("Change Padding") { $0.padding = 10 } }
        pictures.release()
        await pending.value
        var expected = BackgroundStyle.standard
        expected.padding = 10
        #expect(h.editor.document.background == DocumentBackground(style: expected))
        #expect(h.editor.images.images.count == 1)
        #expect(h.editor.undoManager.undoActionName == "Change Padding")
        h.editor.undoManager.undo()
        #expect(h.editor.document.background == DocumentBackground(style: .standard))
        h.editor.undoManager.undo()
        #expect(h.editor.document.background == nil)
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func anUndoWhileThePictureLoadsIsKept() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.applyBackground(customStyle, actionName: "Apply", pictures: .none) }
        let pictures = FakePictures()
        pictures.holdsDesktop = true
        let pending = Task { await h.editor.setBackgroundFill(.desktop, pictures: pictures.source) }
        await pictures.waitForDesktopCalls(1)
        h.editor.undoManager.undo()
        pictures.release()
        await pending.value
        #expect(h.editor.document.background == nil)
        #expect(!h.editor.undoManager.canUndo)
        #expect(h.editor.undoManager.canRedo)
        h.editor.undoManager.redo()
        #expect(h.editor.document.background == DocumentBackground(style: customStyle))
    }

    @Test func aSliderDragThatEndsBeforeThePictureArrivesWins() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        let pictures = FakePictures()
        pictures.holdsDesktop = true
        let pending = Task { await h.editor.setBackgroundFill(.desktop, pictures: pictures.source) }
        await pictures.waitForDesktopCalls(1)
        h.editor.sliderEditingChanged(true, actionName: "Change Shadow")
        for shadow in [40.0, 30, 20] {
            h.editor.updateBackgroundStyle("Change Shadow") { $0.shadow = shadow }
        }
        h.act { h.editor.sliderEditingChanged(false, actionName: "Change Shadow") }
        pictures.release()
        await pending.value
        var expected = BackgroundStyle.standard
        expected.shadow = 20
        #expect(h.editor.document.background == DocumentBackground(style: expected))
        #expect(h.editor.undoManager.undoActionName == "Change Shadow")
        h.editor.undoManager.undo()
        #expect(h.editor.document.background == DocumentBackground(style: .standard))
    }

    @Test func anEditWhileThePictureIsPreparedWins() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        let pictures = FakePictures()
        // The edit runs once the desktop has answered: after the check that follows it, while the picture is prepared.
        pictures.whenDesktopAnswers = { h.act { h.editor.updateBackgroundStyle("Change Corners") { $0.corners = 4 } } }
        await h.editor.setBackgroundFill(.desktop, pictures: pictures.source)
        await pictures.answered?.value
        #expect(pictures.desktopCalls == 1)
        var expected = BackgroundStyle.standard
        expected.corners = 4
        #expect(h.editor.document.background == DocumentBackground(style: expected))
        #expect(h.editor.images.images.count == 1)
        #expect(h.editor.undoManager.undoActionName == "Change Corners")
    }

    // MARK: Style edits

    @Test func sliderDragsAreOneStep() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        // Outside `act`: nothing may register during the drag.
        h.editor.sliderEditingChanged(true, actionName: "Change Padding")
        for padding in [70.0, 80, 90, 100, 110] {
            h.editor.updateBackgroundStyle("Change Padding") { $0.padding = padding }
        }
        #expect(h.editor.document.background?.style.padding == 110)
        h.act { h.editor.sliderEditingChanged(false, actionName: "Change Padding") }
        #expect(!h.editor.isInLiveChange)
        #expect(h.editor.undoManager.undoActionName == "Change Padding")
        h.editor.undoManager.undo()
        #expect(h.editor.document.background?.style.padding == 64)
        #expect(h.editor.undoManager.undoActionName == "Add Background")
    }

    @Test func typedValuesAreOneStepEach() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        h.act { h.editor.updateBackgroundStyle("Change Padding") { $0.padding = 10 } }
        h.act { h.editor.updateBackgroundStyle("Change Corners") { $0.corners = 20 } }
        #expect(h.editor.undoManager.undoActionName == "Change Corners")
        h.editor.undoManager.undo()
        #expect(h.editor.document.background?.style.corners == 12)
        #expect(h.editor.document.background?.style.padding == 10)
        #expect(h.editor.undoManager.undoActionName == "Change Padding")
        h.editor.undoManager.undo()
        #expect(h.editor.document.background == DocumentBackground(style: .standard))
    }

    @Test func aCoalescedColorStreamIsOneStep() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        h.act { h.editor.updateBackgroundStyle("Change Background", coalescing: true) { $0.fill = .color(red) } }
        h.clock += 0.5
        h.editor.updateBackgroundStyle("Change Background", coalescing: true) { $0.fill = .color(blue) } // coalesced
        h.clock += 0.9
        h.editor.updateBackgroundStyle("Change Background", coalescing: true) { $0.fill = .color(green) } // coalesced
        #expect(h.editor.document.background?.style.fill == .color(green))
        h.editor.undoManager.undo()
        #expect(h.editor.document.background == DocumentBackground(style: .standard))
        #expect(h.editor.undoManager.undoActionName == "Add Background")
    }

    @Test func styleValuesAreClamped() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        h.act {
            h.editor.updateBackgroundStyle("Change Padding") { style in
                style.padding = 999
                style.inset = -5
                style.shadow = 500
                style.corners = 65
            }
        }
        let style = h.editor.document.background?.style
        #expect(style?.padding == 256)
        #expect(style?.inset == 0)
        #expect(style?.shadow == 100)
        #expect(style?.corners == 64)

        // A whole style is held to the ranges too.
        var wild = BackgroundStyle.standard
        wild.padding = 999
        wild.inset = .nan
        await h.actAsync { await h.editor.applyBackground(wild, actionName: "Apply", pictures: .none) }
        #expect(h.editor.document.background?.style.padding == 256)
        #expect(h.editor.document.background?.style.inset == BackgroundStyle.standard.inset)
    }

    @Test func aColorFillDropsTheOldPicture() async throws {
        let h = EditorHarness()
        let pictures = FakePictures()
        await h.actAsync { await h.editor.setBackgroundFill(.desktop, pictures: pictures.source) }
        let picture = try #require(h.editor.document.background?.image)
        // An edit that keeps the fill keeps its picture.
        h.act { h.editor.updateBackgroundStyle("Change Padding") { $0.padding = 10 } }
        #expect(h.editor.document.background?.image == picture)
        h.act { h.editor.updateBackgroundStyle("Change Background") { $0.fill = .color(red) } }
        #expect(h.editor.document.background?.style.fill == .color(red))
        #expect(h.editor.document.background?.image == nil)
        #expect(h.editor.document.background?.style.padding == 10)

        // Applying a fill without a picture stores none either.
        await h.actAsync { await h.editor.setBackgroundFill(.desktop, pictures: pictures.source) }
        #expect(h.editor.document.background?.image != nil)
        await h.actAsync { await h.editor.setBackgroundFill(.gradient(BackgroundGradient.catalog[3]), pictures: pictures.source) }
        #expect(h.editor.document.background?.image == nil)
    }

    @Test func styleEditsCantSwitchToAnImageFill() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        let before = h.editor.document
        // Outside `act`: a registration would raise.
        h.editor.updateBackgroundStyle("Change Background") { $0.fill = .desktop }
        h.editor.updateBackgroundStyle("Change Background") { style in
            style.fill = .custom(id: UUID())
            style.padding = 10
        }
        #expect(h.editor.document == before)
    }

    @Test func removingTheBackgroundIsOneStepAndClosesThePanel() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.openBackgroundPanel(pictures: .none) }
        h.act { h.editor.removeBackground() }
        #expect(h.editor.document.background == nil)
        #expect(!h.editor.isBackgroundPanelOpen)
        #expect(h.editor.undoManager.undoActionName == "Remove Background")
        h.editor.undoManager.undo()
        #expect(h.editor.document.background == DocumentBackground(style: .standard))
        #expect(!h.editor.isBackgroundPanelOpen) // undo leaves the panel as it is
        h.editor.undoManager.undo()
        #expect(!h.editor.undoManager.canUndo)
        // Without a background there is nothing to remove.
        h.editor.removeBackground() // outside `act`: a registration would raise
        #expect(!h.editor.undoManager.canUndo)
    }

    @Test func backgroundCommandsWaitForALiveChangeAndACrop() async {
        let h = EditorHarness()
        let pictures = FakePictures()
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        h.preferences[Prefs.lastBackgroundStyle] = RememberedBackgroundStyle(customStyle)
        let preset = BackgroundPreset(name: "Blue", style: customStyle)
        let before = h.editor.document
        // Outside `act` throughout: a registration would raise.
        func tryEverything(styleEdits: Bool) async {
            await h.editor.applyBackground(customStyle, actionName: "Apply", pictures: pictures.source)
            await h.editor.setBackgroundFill(.desktop, pictures: pictures.source)
            await h.editor.applyPreset(preset, pictures: pictures.source)
            await h.editor.applyPreviousSettings(pictures: pictures.source)
            h.editor.removeBackground()
            if styleEdits { h.editor.updateBackgroundStyle("Change Padding") { $0.padding = 10 } }
        }

        // A drag, a slider or a text being typed.
        h.editor.beginLiveChange()
        await tryEverything(styleEdits: false)
        #expect(h.editor.document == before)
        h.editor.cancelLiveChange()

        // Crop & Resize, style edits included.
        h.editor.tool = .crop
        await tryEverything(styleEdits: true)
        #expect(h.editor.document == before)
        #expect(h.editor.lastAppliedPresetID == nil)
        #expect(pictures.desktopCalls == 0)
        h.editor.cancelCrop()

        // A picture that comes back once a live change has opened is dropped, and so is one that comes back in Crop & Resize.
        pictures.holdsDesktop = true
        let duringDrag = Task { await h.editor.setBackgroundFill(.desktop, pictures: pictures.source) }
        await pictures.waitForDesktopCalls(1)
        h.editor.beginLiveChange()
        pictures.release()
        await duringDrag.value
        h.editor.cancelLiveChange()
        #expect(h.editor.document == before)

        let duringCrop = Task { await h.editor.setBackgroundFill(.desktop, pictures: pictures.source) }
        await pictures.waitForDesktopCalls(2)
        h.editor.tool = .crop
        pictures.release()
        await duringCrop.value
        h.editor.cancelCrop()
        #expect(h.editor.document == before)
        #expect(h.editor.undoManager.undoActionName == "Add Background")
    }

    // MARK: The canvas

    @Test func outputBoundsAreTheFrameWithItsTrims() async {
        let h = EditorHarness(images: [ImageRef.original.name: marginedPicture()])
        #expect(h.editor.outputBounds == CGRect(x: 0, y: 0, width: 100, height: 80))
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        #expect(h.editor.outputBounds == CGRect(x: -64, y: -64, width: 228, height: 208))
        h.act { h.editor.updateBackgroundStyle("Change Auto-balance") { $0.autoBalance = true } }
        // The 20-pixel margins are trimmed: the frame is around the black block. Measured once, into the shared cache.
        #expect(h.editor.outputBounds == CGRect(x: -44, y: -44, width: 188, height: 168))
        #expect(h.editor.renderCache.contentAnalysis?.trims == EdgeTrims(top: 20, left: 20, bottom: 20, right: 20))
    }

    @Test func autoExpandDoesNotRunWithABackground() async {
        let object = editorRectangle() // 10…30
        let h = EditorHarness(objects: [object])
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        // Dragged into the padding under the picture.
        h.act {
            h.editor.beginLiveChange()
            h.editor.updateLive { $0.objects[0] = ObjectGeometry.translated($0.objects[0], by: CGVector(dx: 0, dy: 70)) }
            h.editor.endLiveChange("Move")
        }
        #expect(h.rect(of: object.id)?.minY == 80)
        #expect(h.editor.document.canvasRect == nil)
        // Nor for an object added past the canvas.
        h.act { h.editor.add(editorRectangle(CGRect(x: 90, y: 10, width: 30, height: 20)), actionName: "Add Rectangle") }
        #expect(h.editor.document.canvasRect == nil)
    }

    @Test func autoExpandStillRunsWithoutOne() async {
        let object = editorRectangle()
        let h = EditorHarness(objects: [object])
        // A background that has been removed doesn't count.
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        h.act { h.editor.removeBackground() }
        h.act {
            h.editor.beginLiveChange()
            h.editor.updateLive { $0.objects[0] = ObjectGeometry.translated($0.objects[0], by: CGVector(dx: 0, dy: 70)) }
            h.editor.endLiveChange("Move")
        }
        #expect(h.editor.document.canvasRect == CGRect(x: 0, y: 0, width: 100, height: 116))
    }

    @Test func resizeUsesTheFrame() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        #expect(h.editor.outputBounds.size == CGSize(width: 228, height: 208))
        #expect(h.editor.resizeLimit == CGSize(width: 16_383, height: 16_383)) // 16 383 × 228 ÷ 100, held to the limit
        h.act { h.editor.resizeImage(width: 114, height: 104) }
        #expect(h.editor.document.imageOps == [.resize(width: 50, height: 40)])
        let frame = h.editor.outputBounds.size
        #expect(abs(frame.width - 114) <= 2)
        #expect(abs(frame.height - 104) <= 2)
        #expect(h.editor.undoManager.undoActionName == "Resize Image")
        // The frame's own size records nothing.
        h.editor.resizeImage(width: Int(frame.width), height: Int(frame.height)) // outside `act`: a registration would raise
        #expect(h.editor.document.imageOps.count == 1)

        // A crop of a larger picture: the limit is the picture's share of the frame, and the canvas is pinned to its own
        // share of the request, not to the request.
        let cropped = EditorHarness(baseSize: CGSize(width: 1000, height: 800))
        cropped.editor.tool = .crop
        cropped.editor.updateCrop(CGRect(x: 100, y: 100, width: 100, height: 80))
        cropped.act { cropped.editor.applyCrop() }
        await cropped.actAsync { await cropped.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        // 16 383 × 228 ÷ 1000 and × 208 ÷ 800, rounded down (1638 × 1638 without the background).
        #expect(cropped.editor.resizeLimit == CGSize(width: 3735, height: 4259))
        cropped.act { cropped.editor.resizeImage(width: 115, height: 105) }
        #expect(cropped.editor.document.canvasBounds.size == CGSize(width: 50, height: 40))
        let croppedFrame = cropped.editor.outputBounds.size
        #expect(abs(croppedFrame.width - 115) <= 2)
        #expect(abs(croppedFrame.height - 105) <= 2)
    }

    @Test func cropRotateAndUndoKeepTheBackground() async {
        let h = EditorHarness()
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Add Background", pictures: .none) }
        let original = h.editor.document
        h.editor.tool = .crop
        h.editor.updateCrop(CGRect(x: 0, y: 0, width: 50, height: 40))
        h.act { h.editor.applyCrop() }
        // The frame re-forms around the crop.
        #expect(h.editor.document.background == original.background)
        #expect(h.editor.outputBounds == CGRect(x: -64, y: -64, width: 178, height: 168))
        h.act { h.editor.rotateRight() }
        // Around the turned content: the crop is now 40×50 at (40, 0).
        #expect(h.editor.document.canvasBounds == CGRect(x: 40, y: 0, width: 40, height: 50))
        #expect(h.editor.outputBounds == CGRect(x: -24, y: -64, width: 168, height: 178))
        #expect(h.editor.document.background == original.background)
        h.editor.undoManager.undo()
        h.editor.undoManager.undo()
        #expect(h.editor.document == original)
        #expect(h.editor.outputBounds == CGRect(x: -64, y: -64, width: 228, height: 208))
    }

    @Test func capturedWallpaperStaysAvailableAfterSwitchingFill() async throws {
        let ref = ImageRef(name: "images/background-captured.png")
        var style = BackgroundStyle.windowStandard
        style.fill = .windowWallpaper
        let h = EditorHarness(background: DocumentBackground(style: style, image: ref), isWindowShot: true,
                              images: [ref.name: TestBitmaps.solid(200, 160, TestBitmaps.green)])
        #expect(h.editor.capturedWallpaper == ref)
        let pictures = FakePictures()
        await h.actAsync { await h.editor.setBackgroundFill(.color(red), pictures: pictures.source) }
        #expect(h.editor.document.background?.image == nil)
        #expect(h.editor.capturedWallpaper == ref)
        // Picked again, it is the same picture: nothing is asked or stored.
        await h.actAsync { await h.editor.setBackgroundFill(.windowWallpaper, pictures: pictures.source) }
        #expect(h.editor.document.background == DocumentBackground(style: style, image: ref))
        #expect(pictures.desktopCalls == 0)
        #expect(h.editor.images.images.count == 2)

        // Only a window wallpaper with its picture counts: not one without a name, nor one whose bitmap is missing (a damaged
        // package), nor another fill's picture.
        #expect(EditorHarness().editor.capturedWallpaper == nil)
        #expect(EditorHarness(background: DocumentBackground(style: style), isWindowShot: true).editor.capturedWallpaper == nil)
        #expect(EditorHarness(background: DocumentBackground(style: style, image: ref), isWindowShot: true)
            .editor.capturedWallpaper == nil)
        var desktop = BackgroundStyle.windowStandard
        desktop.fill = .desktop
        #expect(EditorHarness(background: DocumentBackground(style: desktop, image: ref),
                              images: [ref.name: TestBitmaps.solid(8, 8, TestBitmaps.green)]).editor.capturedWallpaper == nil)
    }
}

@MainActor
struct EditorBackgroundPresetTests {
    /// A list of two presets: "A" (the standard style) and "B" (`customStyle`).
    private func twoPresets() -> (list: BackgroundPresetList, a: BackgroundPreset, b: BackgroundPreset) {
        var list = BackgroundPresetList()
        let a = list.add(name: "A", style: .standard)
        let b = list.add(name: "B", style: customStyle)
        return (list, a, b)
    }

    @Test func savingAPresetGoesToTheDocumentsList() async throws {
        let h = EditorHarness(isWindowShot: true)
        #expect(h.editor.saveBackgroundAsPreset(named: "Nothing") == nil) // no background yet
        await h.actAsync { await h.editor.applyBackground(customStyle, actionName: "Apply", pictures: .none) }
        let preset = try #require(h.editor.saveBackgroundAsPreset(named: "  Blue  "))
        #expect(preset.name == "Blue")
        #expect(preset.style == customStyle)
        #expect(h.preferences[Prefs.windowBackgroundPresets].presets == [preset])
        #expect(h.preferences[Prefs.backgroundPresets].presets.isEmpty)
        #expect(h.editor.presets == [preset])
        #expect(h.editor.lastAppliedPreset == preset)
        #expect(h.editor.matchingPreset == preset)
        #expect(h.editor.undoManager.undoActionName == "Apply") // saving is no step

        // A screenshot's goes to the screenshot list, named by its place when the name is empty.
        let screenshot = EditorHarness()
        await screenshot.actAsync { await screenshot.editor.applyBackground(.standard, actionName: "Apply", pictures: .none) }
        let unnamed = try #require(screenshot.editor.saveBackgroundAsPreset(named: " "))
        #expect(unnamed.name == "Preset 1")
        #expect(screenshot.preferences[Prefs.backgroundPresets].presets == [unnamed])
        #expect(screenshot.preferences[Prefs.windowBackgroundPresets].presets.isEmpty)
    }

    @Test func updateWritesIntoTheLastAppliedPreset() async {
        let (list, a, _) = twoPresets()
        let h = EditorHarness()
        h.preferences[Prefs.backgroundPresets] = list
        await h.actAsync { await h.editor.applyPreset(a, pictures: .none) }
        #expect(h.editor.undoManager.undoActionName == "Apply Preset")
        #expect(h.editor.lastAppliedPreset == a)
        h.act { h.editor.updateBackgroundStyle("Change Padding") { $0.padding = 10 } }
        #expect(h.editor.matchingPreset == nil)
        h.editor.updateLastAppliedPreset()
        var expected = BackgroundStyle.standard
        expected.padding = 10
        #expect(h.preferences[Prefs.backgroundPresets].preset(id: a.id)?.style == expected)
        #expect(h.editor.matchingPreset?.id == a.id)
        #expect(h.editor.presets.count == 2)
    }

    @Test func updateNeedsAnAppliedPreset() async {
        let (list, _, _) = twoPresets()
        let h = EditorHarness()
        h.preferences[Prefs.backgroundPresets] = list
        h.editor.updateLastAppliedPreset() // no background, no preset
        // The same style as A, but not applied as a preset.
        await h.actAsync { await h.editor.applyBackground(.standard, actionName: "Apply", pictures: .none) }
        #expect(h.editor.lastAppliedPreset == nil)
        h.act { h.editor.updateBackgroundStyle("Change Padding") { $0.padding = 10 } }
        h.editor.updateLastAppliedPreset()
        #expect(h.preferences[Prefs.backgroundPresets] == list)
    }

    @Test func renameAndDelete() async {
        let (list, a, b) = twoPresets()
        let h = EditorHarness()
        h.preferences[Prefs.backgroundPresets] = list
        await h.actAsync { await h.editor.applyPreset(a, pictures: .none) }
        h.editor.renamePreset(a.id, to: "  Renamed ")
        #expect(h.editor.presets.map(\.name) == ["Renamed", "B"])
        h.editor.renamePreset(a.id, to: "   ") // nothing to name it
        #expect(h.editor.presets.map(\.name) == ["Renamed", "B"])
        #expect(h.editor.lastAppliedPreset?.name == "Renamed")

        h.editor.deletePreset(UUID()) // no such preset
        #expect(h.editor.lastAppliedPresetID == a.id)
        h.editor.deletePreset(a.id)
        #expect(h.editor.presets == [b])
        #expect(h.editor.lastAppliedPresetID == nil)
        #expect(h.editor.lastAppliedPreset == nil)
        // The document keeps its background.
        #expect(h.editor.document.background == DocumentBackground(style: .standard))
    }

    @Test func deletingTheAutoApplyPresetTurnsAutoApplyOff() async {
        let (list, a, b) = twoPresets()
        let h = EditorHarness()
        h.preferences[Prefs.backgroundPresets] = list
        await h.actAsync { await h.editor.applyPreset(a, pictures: .none) }
        h.editor.setAutoApplyLastPreset(true)
        #expect(h.preferences[Prefs.autoApplyBackgroundPresetID] == a.id.uuidString)
        h.editor.deletePreset(b.id)
        #expect(h.preferences[Prefs.autoApplyBackgroundPresetID] == a.id.uuidString)
        h.editor.deletePreset(a.id)
        #expect(h.preferences[Prefs.autoApplyBackgroundPresetID] == "")
        #expect(!h.editor.autoAppliesLastPreset)
    }

    @Test func matchingPresetNamesTheCurrentStyle() async {
        let (list, _, b) = twoPresets()
        let h = EditorHarness()
        h.preferences[Prefs.backgroundPresets] = list
        #expect(h.editor.matchingPreset == nil) // no background
        await h.actAsync { await h.editor.applyBackground(customStyle, actionName: "Apply", pictures: .none) }
        #expect(h.editor.matchingPreset == b)
        #expect(h.editor.lastAppliedPreset == nil) // matching isn't applying
        h.act { h.editor.updateBackgroundStyle("Change Padding") { $0.padding = 30 } }
        #expect(h.editor.matchingPreset == nil)
        // Only the document's kind's list counts.
        let window = EditorHarness(isWindowShot: true)
        window.preferences[Prefs.backgroundPresets] = list
        await window.actAsync { await window.editor.applyBackground(customStyle, actionName: "Apply", pictures: .none) }
        #expect(window.editor.matchingPreset == nil)
    }

    @Test func autoApplyToggleWritesTheIDForTheKind() async {
        var list = BackgroundPresetList()
        let preset = list.add(name: "Window", style: customStyle)
        let h = EditorHarness(isWindowShot: true)
        h.preferences[Prefs.windowBackgroundPresets] = list
        #expect(!h.editor.autoAppliesLastPreset)
        h.editor.setAutoApplyLastPreset(true) // no preset applied yet: nothing to write
        #expect(h.preferences[Prefs.autoApplyWindowBackgroundPresetID] == "")

        await h.actAsync { await h.editor.applyPreset(preset, pictures: .none) }
        h.editor.setAutoApplyLastPreset(true)
        #expect(h.preferences[Prefs.autoApplyWindowBackgroundPresetID] == preset.id.uuidString)
        #expect(h.preferences[Prefs.autoApplyBackgroundPresetID] == "")
        #expect(h.editor.autoAppliesLastPreset)
        h.editor.setAutoApplyLastPreset(false)
        #expect(h.preferences[Prefs.autoApplyWindowBackgroundPresetID] == "")
        #expect(!h.editor.autoAppliesLastPreset)
    }

    @Test func applyPreviousSettingsUsesTheKindsMemory() async {
        let h = EditorHarness()
        #expect(!h.editor.canApplyPreviousSettings)
        await h.editor.applyPreviousSettings(pictures: .none) // outside `act`: nothing to apply, nothing registers
        #expect(h.editor.document.background == nil)
        // A window shot's memory isn't a screenshot's.
        var windowMemory = customStyle
        windowMemory.padding = 40
        h.preferences[Prefs.lastWindowBackgroundStyle] = RememberedBackgroundStyle(windowMemory)
        #expect(!h.editor.canApplyPreviousSettings)
        h.preferences[Prefs.lastBackgroundStyle] = RememberedBackgroundStyle(customStyle)
        #expect(h.editor.canApplyPreviousSettings)
        await h.actAsync { await h.editor.applyPreviousSettings(pictures: .none) }
        #expect(h.editor.document.background == DocumentBackground(style: customStyle))
        #expect(h.editor.undoManager.undoActionName == "Apply Previous Settings")

        let window = EditorHarness(isWindowShot: true)
        window.preferences[Prefs.lastWindowBackgroundStyle] = RememberedBackgroundStyle(windowMemory)
        await window.actAsync { await window.editor.applyPreviousSettings(pictures: .none) }
        #expect(window.editor.document.background == DocumentBackground(style: windowMemory))
    }

    @Test func recordPreviousWritesOnlyBackgroundedDocuments() {
        let h = EditorHarness()
        var document = AnnotationDocument(baseSize: CGSize(width: 10, height: 10), pixelScale: 1)
        BackgroundPresets.recordPrevious(document, in: h.preferences)
        #expect(!h.preferences.hasValue(Prefs.lastBackgroundStyle))
        #expect(!h.preferences.hasValue(Prefs.lastWindowBackgroundStyle))

        document.background = DocumentBackground(style: customStyle)
        BackgroundPresets.recordPrevious(document, in: h.preferences)
        #expect(h.preferences[Prefs.lastBackgroundStyle] == RememberedBackgroundStyle(customStyle))
        #expect(!h.preferences.hasValue(Prefs.lastWindowBackgroundStyle))

        var windowStyle = BackgroundStyle.windowStandard
        windowStyle.padding = 12
        document.isWindowShot = true
        document.background = DocumentBackground(style: windowStyle)
        BackgroundPresets.recordPrevious(document, in: h.preferences)
        #expect(h.preferences[Prefs.lastWindowBackgroundStyle] == RememberedBackgroundStyle(windowStyle))
        #expect(h.preferences[Prefs.lastBackgroundStyle] == RememberedBackgroundStyle(customStyle))

        // A later document without one leaves the memory as it is.
        document.background = nil
        BackgroundPresets.recordPrevious(document, in: h.preferences)
        #expect(h.preferences[Prefs.lastWindowBackgroundStyle] == RememberedBackgroundStyle(windowStyle))
    }

    @Test func aCapturedWallpaperIsRememberedAsTheDesktop() async throws {
        // A "With wallpaper" window shot written: its fill means "this document's captured picture", which the next window
        // shot doesn't have. Previous Settings keep the rest of its style with the desktop instead.
        let h = EditorHarness(isWindowShot: true)
        var captured = customStyle
        captured.fill = .windowWallpaper
        var written = AnnotationDocument(baseSize: CGSize(width: 10, height: 10), pixelScale: 1)
        written.isWindowShot = true
        written.background = DocumentBackground(style: captured, image: ImageRef(name: "images/background-captured.png"))
        BackgroundPresets.recordPrevious(written, in: h.preferences)
        var expected = captured
        expected.fill = .desktop
        #expect(h.preferences[Prefs.lastWindowBackgroundStyle] == RememberedBackgroundStyle(expected))

        // So the panel opened on a transparent window shot applies the desktop, from the picture source.
        let pictures = FakePictures()
        await h.actAsync { await h.editor.openBackgroundPanel(pictures: pictures.source) }
        #expect(pictures.desktopCalls == 1)
        let background = try #require(h.editor.document.background)
        #expect(background.style == expected)
        let ref = try #require(background.image)
        #expect(h.editor.images[ref] != nil)
    }
}
