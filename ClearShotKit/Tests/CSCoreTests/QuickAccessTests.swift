import CoreGraphics
import CSTestSupport
import Foundation
import Testing
@testable import CSCore

@MainActor
final class QuickAccessPrefsTests {
    let throwaway = ThrowawayDefaults("quickaccess")
    let defaults: UserDefaults
    let prefs: Preferences

    init() {
        defaults = throwaway.defaults
        prefs = Preferences(defaults: defaults)
    }

    @Test func defaultsAreTheDecidedOnes() {
        #expect(prefs[Prefs.quickAccessPosition] == .left)
        #expect(prefs[Prefs.quickAccessSize] == .medium)
        #expect(prefs[Prefs.quickAccessMoveToActiveScreen])
        #expect(prefs[Prefs.quickAccessAutoClose])
        #expect(prefs[Prefs.quickAccessAutoCloseSeconds] == 15)
        #expect(prefs[Prefs.quickAccessAutoCloseAction] == .close)
        #expect(prefs[Prefs.quickAccessCloseAfterDragging])
        #expect(!prefs[Prefs.quickAccessSaveAsksForLocation])
        #expect(prefs[Prefs.confirmCloseAllOverlays])
        #expect(prefs[Prefs.historyRetention] == .oneMonth)
        #expect(Prefs.autoCloseIntervalChoices.contains(prefs[Prefs.quickAccessAutoCloseSeconds]))
    }

    @Test func resettingWarningDialogsTurnsThemBackOn() {
        prefs[Prefs.confirmCloseAllOverlays] = false
        Prefs.warningDialogs.forEach { prefs.reset($0) }
        #expect(prefs[Prefs.confirmCloseAllOverlays])
    }

    @Test func resettingWarningDialogsAlsoBringsBackTheHistoryDeleteConfirmation() {
        #expect(prefs[Prefs.confirmHistoryDelete])
        #expect(Prefs.warningDialogs.map(\.name) == ["confirmCloseAllOverlays", "confirmHistoryDelete", "confirmCloseRecording"])
        prefs[Prefs.confirmCloseAllOverlays] = false
        prefs[Prefs.confirmHistoryDelete] = false
        Prefs.warningDialogs.forEach { prefs.reset($0) }
        #expect(prefs[Prefs.confirmCloseAllOverlays])
        #expect(prefs[Prefs.confirmHistoryDelete])
    }

    @Test func resettingWarningDialogsAlsoBringsBackCloseThisRecording() {
        #expect(prefs[Prefs.confirmCloseRecording])
        prefs[Prefs.confirmCloseRecording] = false
        #expect(!prefs[Prefs.confirmCloseRecording])
        Prefs.warningDialogs.forEach { prefs.reset($0) }
        #expect(prefs[Prefs.confirmCloseRecording])
    }

    @Test func enumsPersistAsTheirRawValues() {
        prefs[Prefs.quickAccessPosition] = .right
        prefs[Prefs.historyRetention] = .threeDays
        prefs[Prefs.quickAccessAutoCloseAction] = .saveAndClose
        #expect(defaults.string(forKey: "quickAccessPosition") == "right")
        #expect(defaults.string(forKey: "historyRetention") == "threeDays")
        #expect(defaults.string(forKey: "quickAccessAutoCloseAction") == "saveAndClose")
    }
}

struct HistoryRetentionTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func cutoffsCountBackFromNow() {
        #expect(HistoryRetention.oneDay.cutoff(now: now) == now.addingTimeInterval(-86_400))
        #expect(HistoryRetention.threeDays.cutoff(now: now) == now.addingTimeInterval(-3 * 86_400))
        #expect(HistoryRetention.oneWeek.cutoff(now: now) == now.addingTimeInterval(-7 * 86_400))
        #expect(HistoryRetention.oneMonth.cutoff(now: now) == now.addingTimeInterval(-30 * 86_400))
    }

    @Test func neverKeepsNothingOnceClosed() {
        #expect(HistoryRetention.never.cutoff(now: now) == now)
    }
}

struct ImageFormatExtensionTests {
    @Test(arguments: zip(["png", "JPG", "jpeg", "heic", "webp"], [ImageFormat.png, .jpeg, .jpeg, .heic, .webp]))
    func knownExtensionsMap(fileExtension: String, format: ImageFormat) {
        #expect(ImageFormat(fileExtension: fileExtension) == format)
    }

    @Test func unknownExtensionsAreNil() {
        #expect(ImageFormat(fileExtension: "gif") == nil)
        #expect(ImageFormat(fileExtension: "") == nil)
    }
}

struct QuickAccessLayoutTests {
    @Test func thumbnailHeightFollowsTheImage() {
        #expect(QuickAccessLayout.thumbnailSize(imagePixels: CGSize(width: 1600, height: 1000), size: .medium)
            == CGSize(width: 216, height: 135))
    }

    @Test func extremeImagesAreClamped() {
        #expect(QuickAccessLayout.thumbnailSize(imagePixels: CGSize(width: 4000, height: 100), size: .medium).height == 108)
        #expect(QuickAccessLayout.thumbnailSize(imagePixels: CGSize(width: 100, height: 4000), size: .medium).height == 270)
    }

    @Test func anEmptyImageGetsADefaultShape() {
        #expect(QuickAccessLayout.thumbnailSize(imagePixels: .zero, size: .small) == CGSize(width: 168, height: 105))
    }

    @Test func newestSitsInTheBottomLeftCornerAndOlderOnesStackAbove() {
        let visible = CGRect(x: 0, y: 25, width: 1000, height: 800)
        let frames = QuickAccessLayout.frames(for: [CGSize(width: 216, height: 135), CGSize(width: 216, height: 100)],
                                              in: visible, position: .left)
        #expect(frames == [CGRect(x: 16, y: 41, width: 216, height: 135), CGRect(x: 16, y: 188, width: 216, height: 100)])
    }

    @Test func rightPositionHugsTheRightEdge() {
        let frames = QuickAccessLayout.frames(for: [CGSize(width: 216, height: 135)],
                                              in: CGRect(x: 0, y: 0, width: 1000, height: 800), position: .right)
        #expect(frames == [CGRect(x: 768, y: 16, width: 216, height: 135)])
    }

    @Test func displaysWithNegativeOriginsWork() {
        let frames = QuickAccessLayout.frames(for: [CGSize(width: 216, height: 135)],
                                              in: CGRect(x: -1080, y: -400, width: 1080, height: 1895), position: .left)
        #expect(frames == [CGRect(x: -1064, y: -384, width: 216, height: 135)])
    }

    @Test func overflowHidesTheOldest() {
        let size = CGSize(width: 216, height: 135)
        let frames = QuickAccessLayout.frames(for: [size, size, size], in: CGRect(x: 0, y: 0, width: 1000, height: 300),
                                              position: .left)
        #expect(frames[0] == CGRect(x: 16, y: 16, width: 216, height: 135))
        #expect(frames[1] == nil)
        #expect(frames[2] == nil)
    }

    @Test func aSmallerThumbnailAboveAHiddenOneStaysHidden() {
        let sizes = [CGSize(width: 216, height: 135), CGSize(width: 216, height: 270), CGSize(width: 216, height: 50)]
        let frames = QuickAccessLayout.frames(for: sizes, in: CGRect(x: 0, y: 0, width: 1000, height: 400), position: .left)
        #expect(frames[0] != nil)
        #expect(frames[1] == nil)
        #expect(frames[2] == nil)
    }
}

struct SwipeTrackerTests {
    @Test(arguments: [70.0, -70.0])
    func aSidewaysSwipeDismissesOnce(deltaX: Double) {
        var tracker = SwipeTracker()
        tracker.begin()
        #expect(tracker.add(deltaX: deltaX / 2, fingersDown: 0) == .none)
        #expect(tracker.add(deltaX: deltaX / 2, fingersDown: 0) == .dismiss)
        #expect(tracker.add(deltaX: deltaX, fingersDown: 0) == .none)
    }

    @Test func aDownwardSwipeHidesAll() {
        var tracker = SwipeTracker()
        tracker.begin()
        #expect(tracker.add(deltaX: 5, fingersDown: 65) == .hideAll)
    }

    @Test func anUpwardSwipeDoesNothing() {
        var tracker = SwipeTracker()
        tracker.begin()
        #expect(tracker.add(deltaX: 0, fingersDown: -200) == .none)
    }

    @Test func aMostlyVerticalGestureDoesntDismiss() {
        var tracker = SwipeTracker()
        tracker.begin()
        #expect(tracker.add(deltaX: 61, fingersDown: -90) == .none)
    }

    @Test func beginStartsANewGesture() {
        var tracker = SwipeTracker()
        tracker.begin()
        #expect(tracker.add(deltaX: 80, fingersDown: 0) == .dismiss)
        tracker.begin()
        #expect(tracker.add(deltaX: 30, fingersDown: 0) == .none)
        #expect(tracker.add(deltaX: 30, fingersDown: 0) == .dismiss)
    }
}

struct AutoCloseClockTests {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func expiresAfterTheInterval() {
        let clock = AutoCloseClock(interval: 15, now: start)
        #expect(!clock.isExpired(now: start.addingTimeInterval(14.9)))
        #expect(clock.isExpired(now: start.addingTimeInterval(15)))
    }

    @Test func pausingStopsTheCountdownAndResumingContinuesIt() {
        var clock = AutoCloseClock(interval: 15, now: start)
        clock.pause(now: start.addingTimeInterval(10))
        #expect(clock.isPaused)
        #expect(!clock.isExpired(now: start.addingTimeInterval(100)))
        clock.resume(now: start.addingTimeInterval(100))
        #expect(!clock.isPaused)
        #expect(!clock.isExpired(now: start.addingTimeInterval(104.9)))
        #expect(clock.isExpired(now: start.addingTimeInterval(105)))
    }

    @Test func pausingTwiceKeepsTheFirstRemainder() {
        var clock = AutoCloseClock(interval: 15, now: start)
        clock.pause(now: start.addingTimeInterval(5))
        clock.pause(now: start.addingTimeInterval(9))
        clock.resume(now: start.addingTimeInterval(20))
        #expect(!clock.isExpired(now: start.addingTimeInterval(29.9)))
        #expect(clock.isExpired(now: start.addingTimeInterval(30)))
    }
}

struct QuickAccessRulesTests {
    @Test func copyClosesUnlessOptionIsHeld() {
        #expect(QuickAccessRules.closesAfterCopy(optionHeld: false))
        #expect(!QuickAccessRules.closesAfterCopy(optionHeld: true))
    }

    @Test func optionInvertsCloseAfterDragging() {
        #expect(QuickAccessRules.closesAfterDrag(closeAfterDragging: true, optionHeld: false))
        #expect(!QuickAccessRules.closesAfterDrag(closeAfterDragging: true, optionHeld: true))
        #expect(QuickAccessRules.closesAfterDrag(closeAfterDragging: false, optionHeld: true))
        #expect(!QuickAccessRules.closesAfterDrag(closeAfterDragging: false, optionHeld: false))
    }

    @Test func optionDoesTheOppositeOfTheSaveButtonSetting() {
        #expect(!QuickAccessRules.saveAsksForLocation(optionHeld: false, askByDefault: false))
        #expect(QuickAccessRules.saveAsksForLocation(optionHeld: true, askByDefault: false))
        #expect(QuickAccessRules.saveAsksForLocation(optionHeld: false, askByDefault: true))
        #expect(!QuickAccessRules.saveAsksForLocation(optionHeld: true, askByDefault: true))
    }

    @Test func theClockRunsWhenNothingStopsIt() {
        #expect(QuickAccessRules.clockRuns(hovering: false, hidden: false, previewing: false, holds: 0))
    }

    @Test func hoveringStopsTheClock() {
        #expect(!QuickAccessRules.clockRuns(hovering: true, hidden: false, previewing: false, holds: 0))
    }

    @Test func hidingTheStackStopsTheClock() {
        #expect(!QuickAccessRules.clockRuns(hovering: false, hidden: true, previewing: false, holds: 0))
    }

    @Test func quickLookStopsTheClock() {
        #expect(!QuickAccessRules.clockRuns(hovering: false, hidden: false, previewing: true, holds: 0))
    }

    @Test(arguments: [1, 2])
    func anyHoldStopsTheClock(holds: Int) {
        #expect(!QuickAccessRules.clockRuns(hovering: false, hidden: false, previewing: false, holds: holds))
    }

    @Test func autoCloseSavesOnlyUnsavedCapturesAndNeverInterruptsNaming() {
        #expect(QuickAccessRules.autoCloseOutcome(action: .saveAndClose, isSaved: false, isNaming: false) == .saveAndClose)
        #expect(QuickAccessRules.autoCloseOutcome(action: .saveAndClose, isSaved: true, isNaming: false) == .close)
        #expect(QuickAccessRules.autoCloseOutcome(action: .close, isSaved: false, isNaming: false) == .close)
        #expect(QuickAccessRules.autoCloseOutcome(action: .close, isSaved: false, isNaming: true) == .keepOpen)
        #expect(QuickAccessRules.autoCloseOutcome(action: .saveAndClose, isSaved: false, isNaming: true) == .keepOpen)
    }

    /// Auto-close's "Save and close" and "Close this recording?" share this: an item opened from a file is on disk
    /// already only while it is unchanged; once edited (a rotate, an annotation, Replace, Mute) the edit is only in
    /// history.
    @Test func anOpenedFileIsOnDiskOnlyUntilItIsEdited() {
        #expect(QuickAccessRules.isOnDisk(isSaved: true, isOpenedFile: false, isChangedSinceOpening: false))
        #expect(QuickAccessRules.isOnDisk(isSaved: true, isOpenedFile: true, isChangedSinceOpening: true))
        #expect(QuickAccessRules.isOnDisk(isSaved: false, isOpenedFile: true, isChangedSinceOpening: false))
        #expect(!QuickAccessRules.isOnDisk(isSaved: false, isOpenedFile: true, isChangedSinceOpening: true))
        #expect(!QuickAccessRules.isOnDisk(isSaved: false, isOpenedFile: false, isChangedSinceOpening: false))
        // So "Save and close" saves an edited opened video, and just closes an unchanged one.
        let edited = QuickAccessRules.isOnDisk(isSaved: false, isOpenedFile: true, isChangedSinceOpening: true)
        #expect(QuickAccessRules.autoCloseOutcome(action: .saveAndClose, isSaved: edited, isNaming: false) == .saveAndClose)
        let unchanged = QuickAccessRules.isOnDisk(isSaved: false, isOpenedFile: true, isChangedSinceOpening: false)
        #expect(QuickAccessRules.autoCloseOutcome(action: .saveAndClose, isSaved: unchanged, isNaming: false) == .close)
    }

    @Test func onlyAnUnsavedRecordingAsksBeforeClosing() {
        func asks(media: Bool = true, saved: Bool = false, opened: Bool = false, changed: Bool = false, setting: Bool = true)
            -> Bool {
            QuickAccessRules.asksBeforeClosing(isVideoOrGIF: media, isSaved: saved, isOpenedFile: opened,
                                               isChangedSinceOpening: changed, askSetting: setting)
        }
        #expect(asks())
        // Saved, a screenshot, a video opened from a file and unchanged (it is on disk already), or "Don't ask again".
        #expect(!asks(saved: true))
        #expect(!asks(media: false))
        #expect(!asks(opened: true))
        #expect(!asks(setting: false))
        // An opened video edited since (Replace, Mute): the edit is only in history, so it asks.
        #expect(asks(opened: true, changed: true))
    }

    @Test func restoreBringsBackTheMostRecentlyClosedItemStillInHistory() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        // a closed before b; c is the newest capture and still on screen.
        #expect(QuickAccessRules.itemToRestore(closedOldestFirst: [a, b], historyNewestFirst: [c, b, a], shown: [c]) == b)
    }

    @Test func restoreSkipsClosedItemsThatAreGoneOrShown() {
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        // c closed last but has left history; b closed before it but is back on screen.
        #expect(QuickAccessRules.itemToRestore(closedOldestFirst: [a, b, c], historyNewestFirst: [d, b, a], shown: [b]) == a)
    }

    @Test func restoreFallsBackToTheNewestItemNotOnScreen() {
        let (gone, d, e) = (UUID(), UUID(), UUID())
        #expect(QuickAccessRules.itemToRestore(closedOldestFirst: [gone], historyNewestFirst: [d, e], shown: [d]) == e)
        #expect(QuickAccessRules.itemToRestore(closedOldestFirst: [], historyNewestFirst: [d, e], shown: []) == d)
    }

    @Test func restoreWithNothingLeftIsNil() {
        let a = UUID()
        #expect(QuickAccessRules.itemToRestore(closedOldestFirst: [a], historyNewestFirst: [a], shown: [a]) == nil)
        #expect(QuickAccessRules.itemToRestore(closedOldestFirst: [a], historyNewestFirst: [], shown: []) == nil)
        #expect(QuickAccessRules.itemToRestore(closedOldestFirst: [], historyNewestFirst: [], shown: []) == nil)
    }
}

struct ResizeDimensionsTests {
    let original = CGSize(width: 1600, height: 1000)

    @Test func theOtherSideIsRounded() {
        #expect(ResizeDimensions.height(forWidth: 1001, original: original) == 626)
        #expect(ResizeDimensions.width(forHeight: 700, original: original) == 1120)
    }

    @Test func roundedPairsCountAsProportional() {
        #expect(ResizeDimensions.isProportional(width: 1001, height: 626, original: original))
        #expect(ResizeDimensions.isProportional(width: 1000, height: 625, original: original))
        #expect(!ResizeDimensions.isProportional(width: 1000, height: 700, original: original))
    }

    @Test func validSizesStayWithinLimits() {
        #expect(ResizeDimensions.isValid(width: 1, height: 16_383))
        #expect(!ResizeDimensions.isValid(width: 0, height: 10))
        #expect(!ResizeDimensions.isValid(width: 10, height: 16_384))
    }

    @Test func hugeTypedSidesDontCrashAndAreInvalid() {
        let tall = CGSize(width: 1, height: 4)
        let height = ResizeDimensions.height(forWidth: Int.max, original: tall)
        #expect(!ResizeDimensions.isValid(width: 1, height: height))
        let wide = CGSize(width: 4, height: 1)
        #expect(!ResizeDimensions.isValid(width: ResizeDimensions.width(forHeight: Int.max, original: wide), height: 1))
    }

    @Test func sidesNeverDropBelowOne() {
        #expect(ResizeDimensions.height(forWidth: 1, original: CGSize(width: 4000, height: 10)) == 1)
        #expect(ResizeDimensions.width(forHeight: 5, original: .zero) >= 1)
    }
}
