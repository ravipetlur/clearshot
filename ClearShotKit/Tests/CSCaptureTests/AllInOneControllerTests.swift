import CoreGraphics
import CSCore
import Testing
@testable import CSCapture

struct AllInOneControllerTests {
    static let main = AdjustableSelectionTests.main
    static let portrait = AdjustableSelectionTests.portrait
    let point = CGPoint(x: 1000, y: 1000)

    func empty(ratio: SelectionRatio = .freeform) -> AllInOneController {
        AllInOneController(displays: [Self.main, Self.portrait], ratio: ratio)
    }

    /// A controller holding a dragged selection (100, 100, 400, 300) on the main display.
    func selected() -> AllInOneController {
        var controller = empty()
        controller.mouseDown(at: CGPoint(x: 100, y: 100), modifiers: [])
        controller.mouseDragged(to: CGPoint(x: 500, y: 400), modifiers: [])
        controller.mouseUp(at: CGPoint(x: 500, y: 400), modifiers: [])
        return controller
    }

    func press(_ character: String, _ modifiers: SelectionModifiers = [], on controller: inout AllInOneController) -> AllInOneKeyResult {
        controller.key(.character(character), modifiers: modifiers, at: point)
    }

    @Test func aDragMakesASelection() {
        var controller = empty()
        #expect(controller.mode == .area)
        #expect(!controller.hasSelection)
        controller = selected()
        #expect(controller.hasSelection)
        #expect(controller.selection.rect == CGRect(x: 100, y: 100, width: 400, height: 300))
    }

    @Test func fRunsFullscreenWithOrWithoutASelection() {
        var controller = empty()
        #expect(press("f", on: &controller) == .run(.fullscreen))
        #expect(press("F", .shift, on: &controller) == .run(.fullscreen))
        var withSelection = selected()
        #expect(press("f", on: &withSelection) == .run(.fullscreen))
        #expect(withSelection.key(.space, modifiers: [], at: point) == .changed)
        #expect(press("f", on: &withSelection) == .run(.fullscreen))
    }

    @Test func lettersComeFromCharactersNotKeyCodes() {
        var controller = selected()
        #expect(press("A", .shift, on: &controller) == .run(.captureArea))
        #expect(press("a", .control, on: &controller) == .run(.captureArea))
        #expect(press("q", on: &controller) == .ignored)
        #expect(press("", on: &controller) == .ignored)
        #expect(controller.key(.other, modifiers: [], at: point) == .ignored)
    }

    @Test func areaCommandsNeedASelection() {
        var controller = empty()
        #expect(press("a", on: &controller) == .ignored)
        #expect(controller.key(.returnKey, modifiers: [], at: point) == .ignored)
        #expect(press("t", on: &controller) == .ignored)
        #expect(press("o", on: &controller) == .ignored)
        #expect(press("s", on: &controller) == .ignored)

        var withSelection = selected()
        #expect(press("a", on: &withSelection) == .run(.captureArea))
        #expect(withSelection.key(.returnKey, modifiers: [], at: point) == .run(.captureArea))
        #expect(press("t", on: &withSelection) == .run(.selfTimer))
        #expect(press("o", on: &withSelection) == .run(.text))
        #expect(press("s", on: &withSelection) == .run(.scrolling))

        // In window mode the area selection is hidden, so there is none to run on.
        #expect(press("w", on: &withSelection) == .changed)
        #expect(!withSelection.hasSelection)
        #expect(press("a", on: &withSelection) == .ignored)
        #expect(withSelection.key(.returnKey, modifiers: [], at: point) == .ignored)
        #expect(press("s", on: &withSelection) == .ignored)
    }

    @Test func recordRunsAlways() {
        var controller = empty()
        #expect(press("r", on: &controller) == .run(.record))
        var withSelection = selected()
        #expect(press("R", .shift, on: &withSelection) == .run(.record))
        #expect(press("w", on: &withSelection) == .changed)
        #expect(press("r", on: &withSelection) == .run(.record))
    }

    @Test func commandCCopiesTheSelectionOrTheHoveredWindow() {
        var withSelection = selected()
        #expect(press("c", .command, on: &withSelection) == .run(.captureAndCopy))
        #expect(press("C", [.command, .shift], on: &withSelection) == .run(.captureAndCopy))
        #expect(press("c", [.command, .option], on: &withSelection) == .ignored)
        #expect(press("c", [.command, .control], on: &withSelection) == .ignored)
        #expect(press("a", .command, on: &withSelection) == .ignored)
        #expect(press("f", .command, on: &withSelection) == .ignored)
        #expect(press("c", on: &withSelection) == .ignored)

        var window = empty()
        #expect(press("w", on: &window) == .changed)
        #expect(press("c", .command, on: &window) == .run(.captureAndCopy))

        var area = empty()
        #expect(press("c", .command, on: &area) == .ignored)
    }

    @Test func spaceMovesWhileDraggingAndTogglesWindowModeOtherwise() {
        var controller = empty()
        controller.mouseDown(at: CGPoint(x: 100, y: 100), modifiers: [])
        controller.mouseDragged(to: CGPoint(x: 200, y: 200), modifiers: [])
        #expect(controller.key(.space, modifiers: [], at: CGPoint(x: 200, y: 200)) == .ignored)
        #expect(controller.selection.phase == .moving)
        #expect(controller.mode == .area)
        controller.mouseDragged(to: CGPoint(x: 250, y: 220), modifiers: [])
        #expect(controller.selection.rect == CGRect(x: 150, y: 120, width: 100, height: 100))
        controller.keyUp(.space, at: CGPoint(x: 250, y: 220))
        #expect(controller.selection.phase == .dragging)
        controller.mouseUp(at: CGPoint(x: 250, y: 220), modifiers: [])
        #expect(controller.selection.phase == .adjusting)

        #expect(controller.key(.space, modifiers: [], at: point) == .changed)
        #expect(controller.mode == .window)
        #expect(controller.key(.space, modifiers: [], at: point) == .changed)
        #expect(controller.mode == .area)
        #expect(controller.selection.rect == CGRect(x: 150, y: 120, width: 100, height: 100))
    }

    @Test func aSpaceMovedDragCountsOnlyOnceItIsASelection() {
        // Mouse-down then Space: a drag with no rect yet, being moved. Nothing to run on.
        var controller = empty()
        controller.mouseDown(at: CGPoint(x: 100, y: 100), modifiers: [])
        #expect(controller.key(.space, modifiers: [], at: CGPoint(x: 100, y: 100)) == .ignored)
        #expect(controller.selection.phase == .moving)
        #expect(!controller.hasSelection)
        #expect(!controller.selection.isAdjustable)
        #expect(press("a", on: &controller) == .ignored)
        #expect(controller.key(.returnKey, modifiers: [], at: point) == .ignored)
        #expect(press("t", on: &controller) == .ignored)
        #expect(press("o", on: &controller) == .ignored)
        #expect(press("s", on: &controller) == .ignored)
        #expect(press("c", .command, on: &controller) == .ignored)

        // Under 4 pt on a side it still isn't one.
        controller.keyUp(.space, at: CGPoint(x: 100, y: 100))
        controller.mouseDragged(to: CGPoint(x: 102, y: 150), modifiers: [])
        #expect(controller.key(.space, modifiers: [], at: CGPoint(x: 102, y: 150)) == .ignored)
        #expect(controller.selection.phase == .moving)
        #expect(!controller.hasSelection)
        #expect(press("a", on: &controller) == .ignored)

        // At 4 pt or more on each side, the moved drag is a selection.
        controller.keyUp(.space, at: CGPoint(x: 102, y: 150))
        controller.mouseDragged(to: CGPoint(x: 200, y: 200), modifiers: [])
        #expect(controller.key(.space, modifiers: [], at: CGPoint(x: 200, y: 200)) == .ignored)
        #expect(controller.selection.phase == .moving)
        #expect(controller.hasSelection)
        #expect(press("a", on: &controller) == .run(.captureArea))
    }

    @Test func movingAnExistingSelectionStillCounts() {
        var controller = selected()
        controller.mouseDown(at: CGPoint(x: 300, y: 250), modifiers: [])
        #expect(controller.selection.phase == .moving)
        #expect(controller.hasSelection)
        #expect(press("a", on: &controller) == .run(.captureArea))
        #expect(press("c", .command, on: &controller) == .run(.captureAndCopy))
    }

    @Test func modeKeysWaitWhileTheMouseIsDown() {
        // Switching to window mode mid-resize would strand the drag: its mouse-up would never reach the selection.
        var controller = selected()
        controller.mouseDown(at: CGPoint(x: 500, y: 250), modifiers: [])
        #expect(controller.selection.phase == .resizing(.right))
        #expect(controller.key(.space, modifiers: [], at: point) == .ignored)
        #expect(press("w", on: &controller) == .ignored)
        #expect(controller.mode == .area)
        controller.mouseUp(at: CGPoint(x: 600, y: 250), modifiers: [])
        #expect(controller.selection.rect == CGRect(x: 100, y: 100, width: 500, height: 300))
    }

    @Test func windowModeHidesAndRestoresTheSelection() {
        var controller = selected()
        #expect(press("w", on: &controller) == .changed)
        #expect(controller.mode == .window)
        #expect(!controller.hasSelection)
        // The click in window mode is the app's (it captures the hovered window); the selection doesn't see it.
        controller.mouseDown(at: CGPoint(x: 1000, y: 1000), modifiers: [])
        controller.mouseDragged(to: CGPoint(x: 1500, y: 1500), modifiers: [])
        controller.mouseUp(at: CGPoint(x: 1500, y: 1500), modifiers: [])
        #expect(controller.selection.phase == .adjusting)
        #expect(controller.selection.rect == CGRect(x: 100, y: 100, width: 400, height: 300))

        #expect(press("W", .shift, on: &controller) == .changed)
        #expect(controller.mode == .area)
        #expect(controller.hasSelection)
        #expect(controller.selection.rect == CGRect(x: 100, y: 100, width: 400, height: 300))
    }

    @Test func escapeCancels() {
        var controller = empty()
        #expect(controller.key(.escape, modifiers: [], at: point) == .cancel)
        var withSelection = selected()
        #expect(withSelection.key(.escape, modifiers: [], at: point) == .cancel)
        #expect(press("w", on: &withSelection) == .changed)
        #expect(withSelection.key(.escape, modifiers: [], at: point) == .cancel)
    }

    @Test func arrowsAdjust() {
        var controller = selected()
        #expect(controller.key(.arrow(.right), modifiers: [], at: point) == .changed)
        #expect(controller.key(.arrow(.up), modifiers: .command, at: point) == .changed)
        #expect(controller.selection.rect == CGRect(x: 101, y: 110, width: 400, height: 300))
        #expect(controller.key(.arrow(.left), modifiers: .shift, at: point) == .changed)
        #expect(controller.selection.rect == CGRect(x: 101, y: 110, width: 399, height: 300))

        var none = empty()
        #expect(none.key(.arrow(.right), modifiers: [], at: point) == .ignored)
        #expect(press("w", on: &controller) == .changed)
        #expect(controller.key(.arrow(.right), modifiers: [], at: point) == .ignored)
        #expect(controller.selection.rect == CGRect(x: 101, y: 110, width: 399, height: 300))
    }

    @Test func theFullscreenToggleSavesAndRestores() {
        var controller = selected()
        #expect(!controller.isFullscreenSelection)
        controller.toggleFullscreenSelection()
        #expect(controller.selection.rect == Self.main.frame)
        #expect(controller.isFullscreenSelection)
        #expect(controller.hasSelection)
        controller.toggleFullscreenSelection()
        #expect(controller.selection.rect == CGRect(x: 100, y: 100, width: 400, height: 300))
        #expect(!controller.isFullscreenSelection)

        // With nothing selected there is nothing to fill.
        var none = empty()
        none.toggleFullscreenSelection()
        #expect(none.selection.rect == nil)
        #expect(!none.isFullscreenSelection)
    }

    @Test func aChangedSelectionIsSavedOnTheNextToggle() {
        var controller = selected()
        controller.toggleFullscreenSelection()
        controller.setSize(width: 1000, height: 500)
        #expect(!controller.isFullscreenSelection)
        let changed = controller.selection.rect
        #expect(changed == CGRect(x: 0, y: 1390, width: 1000, height: 500))
        controller.toggleFullscreenSelection()
        #expect(controller.isFullscreenSelection)
        controller.toggleFullscreenSelection()
        #expect(controller.selection.rect == changed)

        // A selection that is the display frame with nothing saved stays as it is.
        var full = empty()
        full.mouseDown(at: CGPoint(x: 0, y: 1890), modifiers: [])
        full.mouseUp(at: CGPoint(x: 3360, y: 0), modifiers: [])
        #expect(full.isFullscreenSelection)
        full.toggleFullscreenSelection()
        #expect(full.isFullscreenSelection)
    }

    @Test func choosingARatioFitsTheSelection() {
        var controller = selected()
        controller.setRatio(.preset(width: 16, height: 9))
        #expect(controller.ratio == .preset(width: 16, height: 9))
        let sixteenNine: CGFloat = 16.0 / 9.0
        #expect(controller.selection.aspectRatio == sixteenNine)
        // The width and top-left (100, 400) stay.
        #expect(controller.selection.rect == CGRect(x: 100, y: 175, width: 400, height: 225))

        // Swap: 9:16 at 400 wide needs 711 pt below the top edge, which has 400, so both scale down.
        controller.setRatio(controller.ratio.swapped())
        #expect(controller.ratio == .preset(width: 9, height: 16))
        #expect(controller.selection.rect == CGRect(x: 100, y: 0, width: 225, height: 400))

        controller.setRatio(.freeform)
        #expect(controller.selection.aspectRatio == nil)
        #expect(controller.selection.rect == CGRect(x: 100, y: 0, width: 225, height: 400))

        // Without a selection the ratio waits for the next drag; one given at the start does the same.
        var none = empty(ratio: .preset(width: 1, height: 1))
        #expect(none.selection.aspectRatio == 1)
        none.setRatio(.preset(width: 4, height: 3))
        #expect(none.selection.rect == nil)
        none.mouseDown(at: CGPoint(x: 100, y: 100), modifiers: [])
        none.mouseUp(at: CGPoint(x: 500, y: 150), modifiers: [])
        #expect(none.selection.rect == CGRect(x: 100, y: 100, width: 400, height: 300))
    }

    @Test func aRatioChosenInWindowModeFitsTheSelectionWhenTheAreaComesBack() {
        var controller = selected()
        #expect(press("w", on: &controller) == .changed)
        controller.setRatio(.preset(width: 16, height: 9))
        #expect(controller.ratio == .preset(width: 16, height: 9))
        // Hidden, it waits.
        #expect(controller.selection.rect == CGRect(x: 100, y: 100, width: 400, height: 300))
        #expect(press("w", on: &controller) == .changed)
        #expect(controller.mode == .area)
        #expect(controller.selection.rect == CGRect(x: 100, y: 175, width: 400, height: 225))
    }

    @Test func typedSizesGoToTheSelection() {
        var controller = selected()
        let typed = controller.setSize(width: 800, height: nil)
        #expect(typed)
        #expect(controller.selection.rect == CGRect(x: 100, y: 100, width: 800, height: 300))
        var none = empty()
        let typedWithoutSelection = none.setSize(width: 800, height: nil)
        #expect(!typedWithoutSelection)
    }

    @Test func restoreUsesTheResolver() {
        var controller = empty()
        let onPortrait = controller.restore(SavedArea(rect: CGRect(x: -1700, y: 200, width: 640, height: 480),
                                                      displayID: 2))
        #expect(onPortrait)
        #expect(controller.hasSelection)
        #expect(controller.selection.displayID == 2)
        #expect(controller.selection.rect == CGRect(x: -1700, y: 200, width: 640, height: 480))
        #expect(controller.selection.startModifiers == [])

        // Half off the portrait display: clamped to it.
        let halfOff = controller.restore(SavedArea(rect: CGRect(x: -100, y: 200, width: 400, height: 300), displayID: 2))
        #expect(halfOff)
        #expect(controller.selection.rect == CGRect(x: -100, y: 200, width: 100, height: 300))

        var gone = empty()
        let displayGone = gone.restore(SavedArea(rect: CGRect(x: 10, y: 10, width: 100, height: 100), displayID: 99))
        #expect(!displayGone)
        let empty = gone.restore(.none)
        #expect(!empty)
        #expect(!gone.hasSelection)
    }

    @Test func aRestoredAreaIsFittedToTheRatio() {
        var controller = empty(ratio: .preset(width: 16, height: 9))
        let restored = controller.restore(SavedArea(rect: CGRect(x: 100, y: 100, width: 400, height: 300), displayID: 3))
        #expect(restored)
        // The width and top-left (100, 400) stay; the height follows 16:9.
        #expect(controller.selection.rect == CGRect(x: 100, y: 175, width: 400, height: 225))

        var freeform = empty()
        let unchanged = freeform.restore(SavedArea(rect: CGRect(x: 100, y: 100, width: 400, height: 300), displayID: 3))
        #expect(unchanged)
        #expect(freeform.selection.rect == CGRect(x: 100, y: 100, width: 400, height: 300))
    }

    @Test func rememberRules() {
        #expect(AllInOneCommand.allCases.filter(\.remembersArea)
            == [.captureArea, .captureAndCopy, .selfTimer, .text, .scrolling, .record])
        #expect(AllInOneCommand.allCases.filter(\.updatesLastCaptureArea) == [.captureArea, .captureAndCopy, .selfTimer])
    }

    @Test func commandTitlesAreTheDecidedOnes() {
        #expect(AllInOneCommand.allCases.map(\.title) == [
            "Capture Area", "Capture Area & Copy", "Capture Fullscreen", "Self-Timer", "Capture Text",
            "Scrolling Capture", "Record Screen",
        ])
    }

    @Test func buttonLabelsAndSymbolsAreTheDecidedOnes() {
        #expect(AllInOneButton.allCases == [.area, .fullscreen, .window, .scrolling, .selfTimer, .text, .record])
        #expect(AllInOneButton.allCases.map(\.hoverLabel) == [
            "Capture Area (A)", "Capture Fullscreen (F)", "Capture Window (Space/W)", "Scrolling Capture (S)",
            "Self-Timer (T)", "Capture Text (O)", "Record Screen (R)",
        ])
        #expect(AllInOneButton.allCases.map(\.symbolName) == [
            "rectangle.dashed", "display", "macwindow", "arrow.up.and.down.text.horizontal", "timer", "text.viewfinder",
            "record.circle",
        ])
        // The same symbols as the matching actions.
        let actions: [ClearShotAction] = [.captureArea, .captureFullscreen, .captureWindow, .scrollingCapture, .selfTimer,
                                          .captureText, .recordScreen]
        #expect(AllInOneButton.allCases.map(\.symbolName) == actions.map(\.symbolName))
    }

    @Test func buttonsDoWhatTheirKeysDo() {
        var controller = selected()
        #expect(controller.press(.area) == .run(.captureArea))
        #expect(controller.press(.fullscreen) == .run(.fullscreen))
        #expect(controller.press(.scrolling) == .run(.scrolling))
        #expect(controller.press(.selfTimer) == .run(.selfTimer))
        #expect(controller.press(.text) == .run(.text))
        #expect(controller.press(.record) == .run(.record))
        #expect(controller.press(.window) == .changed)
        #expect(controller.mode == .window)
        #expect(controller.press(.window) == .changed)
        #expect(controller.mode == .area)

        var none = empty()
        #expect(none.press(.area) == .ignored)
        #expect(none.press(.text) == .ignored)
        #expect(none.press(.fullscreen) == .run(.fullscreen))
    }
}
