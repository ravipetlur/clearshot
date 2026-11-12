import CoreGraphics
import Testing
import CSUpdate

/// Where a manual check answers: under the status icon when it can be pointed at, else in Settings › About.
struct CheckSourceTests {
    static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// A status item's window: the top of the screen, in the menu bar.
    static let button = CGRect(x: 1200, y: 954, width: 28, height: 28)

    // MARK: Which surface

    /// A check from Settings always answers in Settings. One from the status menu answers under the icon while it can be
    /// pointed at, and never in a floating HUD: with no icon to point at, the answer goes to the line in Settings › About.
    @Test(arguments: [
        (CheckSource.settings, true, CheckSource.settings), (.settings, false, .settings),
        (.statusMenu, true, .statusMenu), (.statusMenu, false, .settings),
    ])
    func theAnswerGoesWhereItCanBeSeen(source: CheckSource, anchorIsUsable: Bool, answering: CheckSource) {
        #expect(source.answering(anchorIsUsable: anchorIsUsable) == answering)
    }

    // MARK: The icon can be pointed at

    /// A visible icon on a screen can be pointed at, on whichever display's menu bar holds it. A hidden icon, no button,
    /// an empty frame, or no screen can't. Nor can an icon off every screen, where the menu bar's overflow (a full menu
    /// bar, a notch) leaves the item's window, or a button only brushing a screen's edge: where the middle of the button
    /// is decides.
    @Test(arguments: [
        (true, CheckSourceTests.button, [CheckSourceTests.screen], true),
        (false, CheckSourceTests.button, [CheckSourceTests.screen], false),
        (true, nil, [CheckSourceTests.screen], false),
        (true, CGRect(x: -4000, y: 954, width: 28, height: 28), [CheckSourceTests.screen], false),
        (true, CGRect(x: 1200, y: 5000, width: 28, height: 28), [CheckSourceTests.screen], false),
        (true, CGRect.zero, [CheckSourceTests.screen], false),
        (true, CGRect.null, [CheckSourceTests.screen], false),
        (true, CheckSourceTests.button, [], false),
        (true, CGRect(x: 2800, y: 1052, width: 28, height: 28),
         [CheckSourceTests.screen, CGRect(x: 1512, y: 0, width: 1920, height: 1080)], true),
        (true, CGRect(x: -27, y: 954, width: 28, height: 28), [CheckSourceTests.screen], false),
    ] as [(Bool, CGRect?, [CGRect], Bool)])
    func theIconCanBePointedAtOnlyWhenItIsOnAScreen(itemIsVisible: Bool, buttonFrame: CGRect?, screenFrames: [CGRect],
                                                     usable: Bool) {
        #expect(StatusIconAnchor.isUsable(itemIsVisible: itemIsVisible, buttonFrame: buttonFrame, screenFrames: screenFrames)
            == usable)
    }
}
