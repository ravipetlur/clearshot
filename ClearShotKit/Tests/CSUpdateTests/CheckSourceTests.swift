import CoreGraphics
import Testing
import CSUpdate

/// Where a manual check answers: under the status icon when it can be pointed at, else in Settings › About.
struct CheckSourceTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// A status item's window: the top of the screen, in the menu bar.
    let button = CGRect(x: 1200, y: 954, width: 28, height: 28)

    // MARK: Which surface

    @Test func aCheckFromSettingsAlwaysAnswersInSettings() {
        #expect(CheckSource.settings.answering(anchorIsUsable: true) == .settings)
        #expect(CheckSource.settings.answering(anchorIsUsable: false) == .settings)
    }

    @Test func aCheckFromTheStatusMenuAnswersUnderTheIconWhileItCanBePointedAt() {
        #expect(CheckSource.statusMenu.answering(anchorIsUsable: true) == .statusMenu)
    }

    /// Never a floating HUD: with no icon to point at, the answer goes to the line in Settings › About.
    @Test func aCheckFromTheStatusMenuWithNoIconAnswersInSettings() {
        #expect(CheckSource.statusMenu.answering(anchorIsUsable: false) == .settings)
    }

    // MARK: The icon can be pointed at

    @Test func aVisibleIconOnAScreenCanBePointedAt() {
        #expect(StatusIconAnchor.isUsable(itemIsVisible: true, buttonFrame: button, screenFrames: [screen]))
    }

    @Test func aHiddenIconCannotBePointedAt() {
        #expect(!StatusIconAnchor.isUsable(itemIsVisible: false, buttonFrame: button, screenFrames: [screen]))
    }

    @Test func noButtonCannotBePointedAt() {
        #expect(!StatusIconAnchor.isUsable(itemIsVisible: true, buttonFrame: nil, screenFrames: [screen]))
    }

    /// The menu bar's overflow (a full menu bar, a notch) leaves the item's window far off every screen.
    @Test func anIconOffEveryScreenCannotBePointedAt() {
        let overflowed = CGRect(x: -4000, y: 954, width: 28, height: 28)
        #expect(!StatusIconAnchor.isUsable(itemIsVisible: true, buttonFrame: overflowed, screenFrames: [screen]))
        let farAbove = CGRect(x: 1200, y: 5000, width: 28, height: 28)
        #expect(!StatusIconAnchor.isUsable(itemIsVisible: true, buttonFrame: farAbove, screenFrames: [screen]))
    }

    @Test func anEmptyFrameCannotBePointedAt() {
        #expect(!StatusIconAnchor.isUsable(itemIsVisible: true, buttonFrame: .zero, screenFrames: [screen]))
        #expect(!StatusIconAnchor.isUsable(itemIsVisible: true, buttonFrame: .null, screenFrames: [screen]))
    }

    @Test func noScreenMeansNothingToPointAt() {
        #expect(!StatusIconAnchor.isUsable(itemIsVisible: true, buttonFrame: button, screenFrames: []))
    }

    /// The icon is on whichever display's menu bar holds it, not only the first one.
    @Test func anIconOnASecondDisplayCanBePointedAt() {
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let onSecond = CGRect(x: 2800, y: 1052, width: 28, height: 28)
        #expect(StatusIconAnchor.isUsable(itemIsVisible: true, buttonFrame: onSecond, screenFrames: [screen, second]))
    }

    /// Where the middle of the button is decides, so a button only brushing a screen's edge isn't one to point at.
    @Test func aButtonOnlyBrushingAScreenIsNotPointedAt() {
        let brushing = CGRect(x: -27, y: 954, width: 28, height: 28)
        #expect(!StatusIconAnchor.isUsable(itemIsVisible: true, buttonFrame: brushing, screenFrames: [screen]))
    }
}
