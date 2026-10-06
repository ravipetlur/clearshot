import Testing
@testable import CSCore

struct ClearShotActionTests {
    @Test func onlyTheThreeSystemShortcutsHaveDefaults() {
        let defaults = ClearShotAction.allCases.compactMap { action in action.defaultShortcut.map { (action, $0) } }
        #expect(defaults.count == 3)
        #expect(ClearShotAction.captureFullscreen.defaultShortcut == .commandShift(KeyCode.digit3))
        #expect(ClearShotAction.captureArea.defaultShortcut == .commandShift(KeyCode.digit4))
        #expect(ClearShotAction.allInOne.defaultShortcut == .commandShift(KeyCode.digit5))
    }

    @Test func commandShiftMatchesTheCarbonValues() {
        // ⇧⌘4 in Carbon terms: the 4 key is 21, and ⌘ (256) + ⇧ (512) is 768.
        #expect(ShortcutSpec.commandShift(KeyCode.digit4) == ShortcutSpec(carbonKeyCode: 21, carbonModifiers: 768))
    }

    @Test func titlesAreUniqueAndNonEmpty() {
        let titles = ClearShotAction.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    @Test func screenRecordingShortcutsHaveNoCameraToggle() {
        // The camera overlay was dropped, and with it Toggle Camera Fullscreen.
        #expect(ClearShotAction.allCases.filter { $0.group == .screenRecording }
            == [.recordScreen, .recordWindow, .pauseResumeRecording, .restartRecording])
    }

    @Test func recordWindowHasNoDefaultAndIsFoundByWindow() {
        let action = ClearShotAction.recordWindow
        #expect(action.rawValue == "recordWindow")
        #expect(action.title == "Record Window")
        #expect(action.menuTitle == "Record Window")
        #expect(action.group == .screenRecording)
        #expect(action.keywords == ["video", "window", "record"])
        #expect(action.symbolName == "macwindow")
        #expect(action.defaultShortcut == nil)
        #expect(!StatusMenuLayout.entries.contains(.action(action)))
        #expect(ClearShotAction.matching("window").contains(action))
    }

    @Test func startStopCapturingIsAScrollingShortcutWithNoDefault() {
        let action = ClearShotAction.startStopScrollingCapture
        #expect(action.rawValue == "startStopScrollingCapture")
        #expect(action.title == "Start/Stop Capturing")
        #expect(action.menuTitle == "Start/Stop Capturing")
        #expect(action.group == .scrollingCapture)
        #expect(action.keywords == ["scroll", "start", "stop", "done"])
        #expect(action.symbolName == "arrow.up.and.down.text.horizontal")
        #expect(action.defaultShortcut == nil)
        #expect(!StatusMenuLayout.entries.contains(.action(action)))
        #expect(ClearShotAction.allCases.filter { $0.group == .scrollingCapture } == [.scrollingCapture, .startStopScrollingCapture])
        #expect(ClearShotAction.matching("done") == [.startStopScrollingCapture])
    }

    @Test func searchMatchesTitlesKeywordsAndGroups() {
        #expect(ClearShotAction.matching("delay").contains(.selfTimer))
        #expect(ClearShotAction.matching("OCR").contains(.captureText))
        #expect(ClearShotAction.matching("pin").contains(.closeAllPins))
        #expect(ClearShotAction.matching("  ").count == ClearShotAction.allCases.count)
        #expect(ClearShotAction.matching("zzzz").isEmpty)
    }

    @Test func theDesktopIconsItemSaysWhatItWillDo() {
        #expect(ClearShotAction.toggleDesktopIcons.menuTitle(desktopIconsHidden: true) == "Show Desktop Icons")
        #expect(ClearShotAction.toggleDesktopIcons.menuTitle(desktopIconsHidden: false) == "Hide Desktop Icons")
        #expect(ClearShotAction.captureArea.menuTitle(desktopIconsHidden: true) == "Capture Area")
        #expect(ClearShotAction.captureArea.menuTitle(desktopIconsHidden: false) == "Capture Area")
        let others = ClearShotAction.allCases.filter { $0 != .toggleDesktopIcons }
        #expect(others.allSatisfy { $0.menuTitle(desktopIconsHidden: true) == $0.menuTitle })
    }

    @Test func statusMenuListsItsItemsInOrder() {
        let actions = StatusMenuLayout.entries.compactMap { entry -> ClearShotAction? in
            if case .action(let action) = entry { action } else { nil }
        }
        #expect(actions == [
            .allInOne, .captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow, .selfTimer,
            .scrollingCapture, .captureText, .recordScreen,
            .openFile, .openFromClipboard, .chooseAndPinImage, .openCaptureHistory, .restoreLastCapture,
            .toggleDesktopIcons,
        ])
        #expect(StatusMenuLayout.entries.suffix(3) == [.settings, .about, .quit])
    }
}
