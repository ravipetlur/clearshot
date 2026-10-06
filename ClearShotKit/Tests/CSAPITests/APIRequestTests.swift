import CoreGraphics
import Foundation
import Testing
@testable import CSAPI

private func parse(_ string: String, debug: Bool = false) throws(APIError) -> APIRequest {
    try APIRequest.parse(api(string), allowsDebugCommands: debug)
}

private func area(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, display: Int? = nil) -> APIArea {
    APIArea(rect: CGRect(x: x, y: y, width: width, height: height), display: display)
}

struct APIRequestTests {
    @Test func everyCommandNameParses() throws {
        let documented: [(String, APICommand)] = [
            ("all-in-one", .allInOne(nil)),
            ("capture-area", .captureArea(nil, action: nil)),
            ("capture-previous-area", .capturePreviousArea(action: nil)),
            ("capture-fullscreen", .captureFullscreen(action: nil)),
            ("capture-window", .captureWindow(action: nil)),
            ("self-timer", .selfTimer(action: nil)),
            ("scrolling-capture", .scrollingCapture(nil, start: .none)),
            ("pin", .pin(filePath: nil)),
            ("record-screen", .recordScreen(nil)),
            ("capture-text", .captureText(.overlay, keepLineBreaks: nil)),
            ("open-annotate", .openAnnotate(filePath: nil)),
            ("open-from-clipboard", .openFromClipboard),
            ("toggle-desktop-icons", .toggleDesktopIcons),
            ("hide-desktop-icons", .hideDesktopIcons),
            ("show-desktop-icons", .showDesktopIcons),
            ("add-quick-access-overlay?filepath=/tmp/a.png", .addQuickAccessOverlay(filePath: "/tmp/a.png")),
            ("open-history", .openHistory),
            ("restore-recently-closed", .restoreRecentlyClosed),
            ("open-settings", .openSettings(nil)),
        ]
        #expect(documented.count == 19)
        for (name, command) in documented {
            #expect(try parse("clearshot://\(name)").command == command, "\(name)")
        }
        #expect(try parse("clearshot://capture-area-raycast-aichat").command == .captureAreaForRaycast(nil))
        #expect(try parse("clearshot://debug-selftest", debug: true).command == .debugSelfTest)
    }

    @Test func theCommandIsTheHostOrTheFirstPathComponent() throws {
        #expect(try parse("clearshot://capture-area/").command == .captureArea(nil, action: nil))
        #expect(try parse("clearshot:capture-fullscreen").command == .captureFullscreen(action: nil))
        #expect(try parse("CLEARSHOT://Capture-Area").command == .captureArea(nil, action: nil))
        #expect(try parse("clearshot:capture-fullscreen/?action=copy").command == .captureFullscreen(action: .copy))
    }

    @Test func anUnknownCommandIsAnError() {
        #expect(throws: APIError.unknownCommand("capture-everything")) { try parse("clearshot://Capture-Everything") }
        #expect(throws: APIError.unknownCommand("")) { try parse("clearshot://") }
        // The error keeps a long name whole; its message shortens it to 40 characters, the last an ellipsis.
        let long = String(repeating: "a", count: 41)
        #expect(throws: APIError.unknownCommand(long)) { try parse("clearshot://\(long)") }
        #expect(APIError.unknownCommand(long).message == "Unknown command “\(String(repeating: "a", count: 39))…”")
        let forty = String(repeating: "b", count: 40)
        #expect(APIError.unknownCommand(forty).message == "Unknown command “\(forty)”")
        #expect(APIRequest.shortened(forty) == forty)
        #expect(APIRequest.shortened(long).count == 40)
        #expect(APIRequest.shortened("") == "")
    }

    @Test func onlyTheClearshotSchemeIsAccepted() {
        #expect(throws: APIError.wrongScheme("otherapp")) { try parse("otherapp://capture-area") }
        #expect(throws: APIError.wrongScheme("https")) { try parse("https://capture-area") }
    }

    @Test func debugSelfTestNeedsADebugBuild() throws {
        #expect(throws: APIError.unknownCommand("debug-selftest")) { try parse("clearshot://debug-selftest") }
        #expect(try parse("clearshot://debug-selftest", debug: true).command == .debugSelfTest)
    }

    @Test func xAndYAreFiniteAndNotNegative() throws {
        #expect(throws: APIError.negative("x")) { try parse("clearshot://capture-area?x=-1&y=0&width=10&height=10") }
        #expect(throws: APIError.negative("y")) { try parse("clearshot://capture-area?x=0&y=-0.5&width=10&height=10") }
        for bad in ["abc", "inf", "-inf", "nan", "", "1e3", "0x10", "1.2.3"] {
            #expect(throws: APIError.notANumber("x"), "\(bad)") {
                try parse("clearshot://capture-area?x=\(bad)&y=0&width=10&height=10")
            }
        }
        #expect(try parse("clearshot://capture-area?x=0&y=10.5&width=10&height=10").command
            == .captureArea(area(0, 10.5, 10, 10), action: nil))
    }

    @Test func widthAndHeightMustBePositive() {
        #expect(throws: APIError.notPositive("width")) { try parse("clearshot://capture-area?x=0&y=0&width=0&height=10") }
        #expect(throws: APIError.notPositive("height")) { try parse("clearshot://capture-area?x=0&y=0&width=10&height=-5") }
        #expect(throws: APIError.notANumber("height")) { try parse("clearshot://capture-area?x=0&y=0&width=10&height=inf") }
    }

    @Test func theFourGoTogether() {
        #expect(throws: APIError.incompleteArea) { try parse("clearshot://capture-area?x=1&y=2&width=3") }
        #expect(throws: APIError.incompleteArea) { try parse("clearshot://record-screen?height=3&display=1") }
    }

    @Test func displayIsAWholeNumberFromOne() throws {
        for bad in ["0", "1.5", "-1", "two", ""] {
            #expect(throws: APIError.badDisplay(bad), "\(bad)") {
                try parse("clearshot://capture-area?\(rectQuery)&display=\(bad)")
            }
        }
        #expect(try parse("clearshot://capture-area?\(rectQuery)&display=2").command
            == .captureArea(area(100, 120, 200, 150, display: 2), action: nil))
    }

    @Test func aDisplayWithoutAnAreaIsNoted() throws {
        let request = try parse("clearshot://capture-area?display=2")
        #expect(request.command == .captureArea(nil, action: nil))
        #expect(request.notes == ["display is ignored without x, y, width and height"])
    }

    @Test func actionsAreCaseInsensitive() throws {
        #expect(try parse("clearshot://capture-area?action=Copy").command == .captureArea(nil, action: .copy))
        for action in APIAction.allCases {
            #expect(try parse("clearshot://capture-fullscreen?action=\(action.rawValue.uppercased())").command
                == .captureFullscreen(action: action))
        }
        #expect(try parse("clearshot://capture-previous-area?action=save").command == .capturePreviousArea(action: .save))
        #expect(try parse("clearshot://capture-window?action=pin").command == .captureWindow(action: .pin))
        #expect(try parse("clearshot://self-timer?action=annotate").command == .selfTimer(action: .annotate))
        #expect(throws: APIError.badAction("Share")) { try parse("clearshot://capture-area?action=Share") }
    }

    @Test func uploadIsRefused() {
        #expect(throws: APIError.uploadRefused) { try parse("clearshot://capture-area?action=upload") }
        #expect(throws: APIError.uploadRefused) { try parse("clearshot://capture-fullscreen?action=Upload") }
    }

    @Test func anActionOnAnotherCommandIsNoted() throws {
        let request = try parse("clearshot://record-screen?action=copy")
        #expect(request.command == .recordScreen(nil))
        #expect(request.notes == ["record-screen ignores action"])
        // An ignored parameter isn't checked.
        let raycast = try parse("clearshot://capture-area-raycast-aichat?action=upload")
        #expect(raycast.command == .captureAreaForRaycast(nil))
        #expect(raycast.notes == ["capture-area-raycast-aichat ignores action"])
    }

    @Test func booleansAcceptTrueFalseOneZeroYesNo() throws {
        let values = [("true", true), ("TRUE", true), ("1", true), ("yes", true), ("Yes", true),
                      ("false", false), ("False", false), ("0", false), ("no", false), ("NO", false)]
        for (text, value) in values {
            #expect(try parse("clearshot://capture-text?linebreaks=\(text)").command
                == .captureText(.overlay, keepLineBreaks: value), "\(text)")
        }
    }

    @Test func aBadBooleanIsAnError() {
        #expect(throws: APIError.badBoolean(name: "start", value: "maybe")) {
            try parse("clearshot://scrolling-capture?\(rectQuery)&start=maybe")
        }
        #expect(throws: APIError.badBoolean(name: "autoscroll", value: "2")) {
            try parse("clearshot://scrolling-capture?\(rectQuery)&autoscroll=2")
        }
        #expect(throws: APIError.badBoolean(name: "linebreaks", value: "")) { try parse("clearshot://capture-text?linebreaks=") }
    }

    @Test func autoscrollImpliesStart() throws {
        let region = area(100, 120, 200, 150)
        let starts: [(String, APIScrollStart)] = [
            ("", .none), ("&start=false", .none), ("&start=true", .manual), ("&start=true&autoscroll=false", .manual),
            ("&autoscroll=true", .autoScroll), ("&start=false&autoscroll=true", .autoScroll),
        ]
        for (query, start) in starts {
            #expect(try parse("clearshot://scrolling-capture?\(rectQuery)\(query)").command
                == .scrollingCapture(region, start: start), "\(query)")
        }
    }

    @Test func startWithoutAnAreaIsNoted() throws {
        let request = try parse("clearshot://scrolling-capture?start=true&autoscroll=true")
        #expect(request.command == .scrollingCapture(nil, start: .none))
        #expect(request.notes == ["start is ignored without x, y, width and height",
                                  "autoscroll is ignored without x, y, width and height"])
    }

    @Test func aFilepathIsPercentDecoded() throws {
        #expect(try parse("clearshot://pin?filepath=/tmp/my%20screenshot.png").command
            == .pin(filePath: "/tmp/my screenshot.png"))
        // A + stays a +; %2B is one too.
        #expect(try parse("clearshot://open-annotate?filepath=/tmp/a%2Bb+c.png").command
            == .openAnnotate(filePath: "/tmp/a+b+c.png"))
        #expect(try parse("clearshot://capture-text?filepath=~/caf%C3%A9.png").command
            == .captureText(.file("~/café.png"), keepLineBreaks: nil))
        // An empty one is no file.
        #expect(try parse("clearshot://pin?filepath=").command == .pin(filePath: nil))
    }

    @Test func addQuickAccessOverlayNeedsAFile() throws {
        #expect(throws: APIError.missingFile("add-quick-access-overlay")) { try parse("clearshot://add-quick-access-overlay") }
        #expect(throws: APIError.missingFile("add-quick-access-overlay")) {
            try parse("clearshot://add-quick-access-overlay?filepath=")
        }
        #expect(try parse("clearshot://add-quick-access-overlay?filepath=/tmp/v.mp4").command
            == .addQuickAccessOverlay(filePath: "/tmp/v.mp4"))
    }

    @Test func captureTextTakesAFileOrAnAreaNotBoth() throws {
        #expect(throws: APIError.fileAndArea) { try parse("clearshot://capture-text?filepath=/tmp/a.png&\(rectQuery)") }
        #expect(throws: APIError.fileAndArea) { try parse("clearshot://capture-text?filepath=/tmp/a.png&x=1") }
        #expect(try parse("clearshot://capture-text?filepath=/tmp/a.png").command
            == .captureText(.file("/tmp/a.png"), keepLineBreaks: nil))
        #expect(try parse("clearshot://capture-text?\(rectQuery)&display=2").command
            == .captureText(.area(area(100, 120, 200, 150, display: 2)), keepLineBreaks: nil))
        #expect(try parse("clearshot://capture-text").command == .captureText(.overlay, keepLineBreaks: nil))
    }

    @Test func linebreaksSetsKeepLineBreaks() throws {
        #expect(try parse("clearshot://capture-text").command == .captureText(.overlay, keepLineBreaks: nil))
        #expect(try parse("clearshot://capture-text?linebreaks=true").command == .captureText(.overlay, keepLineBreaks: true))
        #expect(try parse("clearshot://capture-text?filepath=/tmp/a.png&linebreaks=false").command
            == .captureText(.file("/tmp/a.png"), keepLineBreaks: false))
        #expect(try parse("clearshot://capture-text?\(rectQuery)&linebreaks=0").command
            == .captureText(.area(area(100, 120, 200, 150)), keepLineBreaks: false))
    }

    @Test func tabsAreCaseInsensitiveAndUnknownOnesNoted() throws {
        #expect(try parse("clearshot://open-settings?tab=QuickAccess").command == .openSettings(.quickaccess))
        #expect(try parse("clearshot://open-settings?tab=cloud").command == .openSettings(.cloud))
        for tab in APISettingsTab.allCases {
            #expect(try parse("clearshot://open-settings?tab=\(tab.rawValue)").command == .openSettings(tab))
        }
        let unknown = try parse("clearshot://open-settings?tab=foo")
        #expect(unknown.command == .openSettings(nil))
        #expect(unknown.notes == ["Unknown tab “foo”"])
    }

    @Test func unknownParametersAreNotedAndTheFirstRepeatWins() throws {
        let request = try parse("clearshot://capture-area?x=1&y=2&width=30&height=40&x=2&colour=red")
        #expect(request.command == .captureArea(area(1, 2, 30, 40), action: nil))
        #expect(request.notes == ["x is given more than once; the first one is used", "capture-area ignores colour"])
        // The repeat isn't checked.
        let repeated = try parse("clearshot://capture-fullscreen?action=copy&action=upload")
        #expect(repeated.command == .captureFullscreen(action: .copy))
        #expect(repeated.notes == ["action is given more than once; the first one is used"])
    }

    @Test func errorMessagesAreTheDecidedOnes() {
        let expected: [(APIError, String)] = [
            (.wrongScheme("otherapp"), "ClearShot takes clearshot:// commands only"),
            (.unknownCommand("capture-everything"), "Unknown command “capture-everything”"),
            (.notANumber("x"), "x must be a number"),
            (.negative("y"), "y can't be negative"),
            (.notPositive("width"), "width must be more than 0"),
            (.incompleteArea, "x, y, width and height go together"),
            (.badDisplay("0"), "display must be 1 or more"),
            (.noSuchDisplay(2), "There's no display 2"),
            (.areaOffDisplay(1), "That area isn't on display 1"),
            (.areaTooSmall, "That area is too small (at least 4 × 4 points)"),
            (.badAction("share"), "Unknown action “share”: use copy, save, annotate or pin"),
            (.uploadRefused, "ClearShot doesn't upload"),
            (.badBoolean(name: "start", value: "maybe"), "start must be true or false"),
            (.missingFile("add-quick-access-overlay"), "add-quick-access-overlay needs a filepath"),
            (.fileAndArea, "Give capture-text a filepath or an area, not both"),
            (.relativePath("a.png"), "filepath must be a full path"),
            (.fileNotFound("~/Pictures/a.png"), "There's no file at ~/Pictures/a.png"),
            (.notAFile("Pictures"), "Pictures isn't a file"),
            (.unreadable("a.png"), "ClearShot can't read a.png"),
            (.wrongFileType("a.txt", expected: .image), "a.txt isn't an image"),
            (.wrongFileType("a.txt", expected: .imageOrMovie), "a.txt isn't an image or a video"),
            (.wrongFileType("a.txt", expected: .imageOrProject), "a.txt isn't an image or a ClearShot project"),
            (.couldntOpen("a.png"), "Couldn't open a.png"),
            (.tooLarge("a.png"), "a.png is too large to open"),
        ]
        for (error, message) in expected {
            #expect(error.message == message)
        }
    }

    /// Text from the URL (an action, a path, a file's name) is shown as `SenderText.name` shows a sender's name: on one
    /// line, without invisible characters, and at most 40 characters, the last an ellipsis. A URL can't put a
    /// multi-line, screen-wide message in a HUD.
    @Test func textFromTheURLIsOneShortLineInAMessage() {
        #expect(APIError.badAction("Your Mac\nis\u{2028}infected").message
            == "Unknown action “Your Mac is infected”: use copy, save, annotate or pin")
        let long = String(repeating: "a", count: 200)
        #expect(APIError.badAction(long).message
            == "Unknown action “\(String(repeating: "a", count: 39))…”: use copy, save, annotate or pin")
        #expect(APIError.fileNotFound("~/a\r\nb.png").message == "There's no file at ~/a  b.png")
        #expect(APIError.fileNotFound("~/" + long).message
            == "There's no file at ~/\(String(repeating: "a", count: 37))…")
        #expect(APIError.notAFile("evil\u{202E}gnp.exe").message == "evilgnp.exe isn't a file")
        #expect(APIError.unreadable("a\u{200B}b.png").message == "ClearShot can't read ab.png")
        #expect(APIError.wrongFileType("x\ny.txt", expected: .image).message == "x y.txt isn't an image")
        #expect(APIError.wrongFileType("x\ny.txt", expected: .imageOrMovie).message
            == "x y.txt isn't an image or a video")
        #expect(APIError.wrongFileType("x\ny.txt", expected: .imageOrProject).message
            == "x y.txt isn't an image or a ClearShot project")
        #expect(APIError.couldntOpen("a\nb.png").message == "Couldn't open a b.png")
        #expect(APIError.tooLarge("a\nb.tiff").message == "a b.tiff is too large to open")
        // Nothing visible left: it is shown percent-escaped, as an identifier is (`SenderText.code`).
        #expect(APIError.notAFile("\u{200B}").message == "%E2%80%8B isn't a file")
        #expect(APIError.badAction("").message == "Unknown action “”: use copy, save, annotate or pin")
        // The rule itself, which the app's own HUDs use for a file a URL names (add-quick-access-overlay).
        #expect(SenderText.shown("x\ny.png") == "x y.png")
        #expect(SenderText.shown("\u{200B}") == "%E2%80%8B")
        #expect(SenderText.shown(long) == String(repeating: "a", count: 39) + "…")
    }

    @Test func commandNameIsReadWithoutParsing() {
        #expect(APIRequest.commandName(of: api("clearshot://capture-area?x=abc")) == "capture-area")
        #expect(APIRequest.commandName(of: api("clearshot:capture-fullscreen")) == "capture-fullscreen")
        #expect(APIRequest.commandName(of: api("CLEARSHOT://Capture-Area/")) == "capture-area")
        #expect(APIRequest.commandName(of: api("clearshot://capture-everything")) == "capture-everything")
        #expect(APIRequest.commandName(of: api("clearshot://")) == "")
        // It stays percent-encoded, so a prompt that shows it can't be made to say something else.
        #expect(APIRequest.commandName(of: api("clearshot:pin%20now.%20Allow")) == "pin%20now.%20allow")
    }
}
