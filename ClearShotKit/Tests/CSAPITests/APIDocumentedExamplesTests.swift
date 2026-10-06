import CoreGraphics
import Foundation
import Testing
@testable import CSAPI

/// Documented examples, one or more for every command and parameter the URL scheme takes, each parsing to its command
/// with nothing ignored.
struct APIDocumentedExamplesTests {
    /// `filepath=/tmp/my%20screenshot.png`, decoded.
    static let file = "/tmp/my screenshot.png"

    static let examples: [(String, APICommand)] = [
        // All-In-One
        ("clearshot://all-in-one", .allInOne(nil)),
        ("clearshot://all-in-one?x=100&y=120&width=200&height=150&display=1", .allInOne(areaA)),
        // Screenshots
        ("clearshot://capture-area", .captureArea(nil, action: nil)),
        ("clearshot://capture-area?action=annotate", .captureArea(nil, action: .annotate)),
        ("clearshot://capture-area?x=100&y=120&width=200&height=150&display=1", .captureArea(areaA, action: nil)),
        ("clearshot://capture-area?x=100&y=120&width=200&height=150&display=1&action=copy",
         .captureArea(areaA, action: .copy)),
        ("clearshot://capture-previous-area", .capturePreviousArea(action: nil)),
        ("clearshot://capture-fullscreen", .captureFullscreen(action: nil)),
        ("clearshot://capture-window", .captureWindow(action: nil)),
        ("clearshot://self-timer", .selfTimer(action: nil)),
        ("clearshot://scrolling-capture", .scrollingCapture(nil, start: .none)),
        ("clearshot://scrolling-capture?x=100&y=120&width=200&height=150&start=true&autoscroll=true",
         .scrollingCapture(APIArea(rect: areaA.rect, display: nil), start: .autoScroll)),
        ("clearshot://pin", .pin(filePath: nil)),
        ("clearshot://pin?filepath=/tmp/my%20screenshot.png", .pin(filePath: file)),
        // Screen Recording
        ("clearshot://record-screen", .recordScreen(nil)),
        ("clearshot://record-screen?x=100&y=120&width=200&height=150&display=1", .recordScreen(areaA)),
        // Text Recognition
        ("clearshot://capture-text", .captureText(.overlay, keepLineBreaks: nil)),
        ("clearshot://capture-text?filepath=/tmp/my%20screenshot.png",
         .captureText(.file(file), keepLineBreaks: nil)),
        ("clearshot://capture-text?x=100&y=120&width=200&height=150&display=1",
         .captureText(.area(areaA), keepLineBreaks: nil)),
        // Annotate
        ("clearshot://open-annotate", .openAnnotate(filePath: nil)),
        ("clearshot://open-annotate?filepath=/tmp/my%20screenshot.png", .openAnnotate(filePath: file)),
        ("clearshot://open-from-clipboard", .openFromClipboard),
        // Desktop icons
        ("clearshot://toggle-desktop-icons", .toggleDesktopIcons),
        ("clearshot://hide-desktop-icons", .hideDesktopIcons),
        ("clearshot://show-desktop-icons", .showDesktopIcons),
        // Quick Access Overlay
        ("clearshot://add-quick-access-overlay?filepath=/tmp/my%20screenshot.png",
         .addQuickAccessOverlay(filePath: file)),
        // Capture History
        ("clearshot://open-history", .openHistory),
        ("clearshot://restore-recently-closed", .restoreRecentlyClosed),
        // Settings
        ("clearshot://open-settings", .openSettings(nil)),
        ("clearshot://open-settings?tab=recording", .openSettings(.recording)),
    ]

    @Test(arguments: examples)
    func everyDocumentedExampleParses(example: String, command: APICommand) throws {
        let url = api(example)
        let request = try APIRequest.parse(url, allowsDebugCommands: false)
        #expect(request.command == command)
        #expect(request.notes.isEmpty)
    }

    /// Each command's `name` is the one its URL takes: a URL made from it, with the command's required parameters,
    /// parses back to the same case.
    @Test func commandNamesRoundTrip() throws {
        #expect(everyCommand.count == CommandKind.allCases.count)
        #expect(Set(everyCommand.map(kind)) == Set(CommandKind.allCases))
        for command in everyCommand {
            let required = if case let .addQuickAccessOverlay(path) = command { "?filepath=\(path)" } else { "" }
            let url = api("clearshot://\(command.name)\(required)")
            let parsed = try APIRequest.parse(url, allowsDebugCommands: true).command
            #expect(parsed.name == command.name)
            #expect(kind(of: parsed) == kind(of: command), "\(command.name)")
        }
    }
}
