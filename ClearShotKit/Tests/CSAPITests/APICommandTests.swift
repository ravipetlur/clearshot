import CoreGraphics
import Foundation
import Testing
@testable import CSAPI

struct APICommandTests {
    /// The "is capturing your screen" notice shows only when the command takes the picture with no on-screen choice by
    /// the person. Commands that open an overlay are their own notice.
    @Test func theNoticeShowsOnlyForCapturesWithNoOnScreenChoice() {
        let table: [(APICommand, Bool)] = [
            (.allInOne(nil), false),
            (.allInOne(areaA), false),
            (.captureArea(nil, action: nil), false),
            (.captureArea(nil, action: .copy), false),
            (.captureArea(areaA, action: nil), true),
            (.captureArea(areaA, action: .save), true),
            (.captureAreaForRaycast(nil), false),
            (.captureAreaForRaycast(areaA), true),
            (.capturePreviousArea(action: nil), true),
            (.capturePreviousArea(action: .pin), true),
            (.captureFullscreen(action: nil), true),
            (.captureFullscreen(action: .annotate), true),
            (.captureWindow(action: nil), false),
            (.selfTimer(action: .copy), false),
            (.scrollingCapture(nil, start: .none), false),
            (.scrollingCapture(nil, start: .manual), false),
            (.scrollingCapture(areaA, start: .none), false),
            (.scrollingCapture(areaA, start: .manual), true),
            (.scrollingCapture(areaA, start: .autoScroll), true),
            (.recordScreen(nil), false),
            (.recordScreen(areaA), false),
            (.captureText(.overlay, keepLineBreaks: nil), false),
            (.captureText(.area(areaA), keepLineBreaks: true), true),
            (.captureText(.file("/tmp/a.png"), keepLineBreaks: nil), false),
            (.pin(filePath: nil), false),
            (.pin(filePath: "/tmp/a.png"), false),
            (.openAnnotate(filePath: nil), false),
            (.openAnnotate(filePath: "/tmp/a.png"), false),
            (.openFromClipboard, false),
            (.addQuickAccessOverlay(filePath: "/tmp/a.png"), false),
            (.openHistory, false),
            (.restoreRecentlyClosed, false),
            (.openSettings(nil), false),
            (.openSettings(.advanced), false),
            (.toggleDesktopIcons, false),
            (.hideDesktopIcons, false),
            (.showDesktopIcons, false),
            (.debugSelfTest, false),
        ]
        #expect(Set(table.map { kind(of: $0.0) }) == Set(CommandKind.allCases))
        for (command, notice) in table {
            #expect(command.capturesWithoutChoice == notice, "\(command)")
        }
    }

    /// What the app checks against the screen and the disk before a command runs: the area it gives, and the file it
    /// gives with what that must be.
    @Test func everyCommandSaysWhatToCheckBeforeItRuns() {
        let file = "/tmp/a.png"
        let table: [(command: APICommand, area: APIArea?, file: APIFileKind?)] = [
            (.allInOne(nil), nil, nil),
            (.allInOne(areaA), areaA, nil),
            (.captureArea(nil, action: .copy), nil, nil),
            (.captureArea(areaA, action: nil), areaA, nil),
            (.captureAreaForRaycast(nil), nil, nil),
            (.captureAreaForRaycast(areaA), areaA, nil),
            (.capturePreviousArea(action: .pin), nil, nil),
            (.captureFullscreen(action: nil), nil, nil),
            (.captureWindow(action: nil), nil, nil),
            (.selfTimer(action: .save), nil, nil),
            (.scrollingCapture(nil, start: .none), nil, nil),
            (.scrollingCapture(areaA, start: .autoScroll), areaA, nil),
            (.recordScreen(nil), nil, nil),
            (.recordScreen(areaA), areaA, nil),
            (.captureText(.overlay, keepLineBreaks: nil), nil, nil),
            (.captureText(.area(areaA), keepLineBreaks: true), areaA, nil),
            (.captureText(.file(file), keepLineBreaks: false), nil, .image),
            (.pin(filePath: nil), nil, nil),
            (.pin(filePath: file), nil, .image),
            (.openAnnotate(filePath: nil), nil, nil),
            (.openAnnotate(filePath: file), nil, .imageOrProject),
            (.openFromClipboard, nil, nil),
            (.addQuickAccessOverlay(filePath: file), nil, .imageOrMovie),
            (.openHistory, nil, nil),
            (.restoreRecentlyClosed, nil, nil),
            (.openSettings(.advanced), nil, nil),
            (.toggleDesktopIcons, nil, nil),
            (.hideDesktopIcons, nil, nil),
            (.showDesktopIcons, nil, nil),
            (.debugSelfTest, nil, nil),
        ]
        #expect(Set(table.map { kind(of: $0.command) }) == Set(CommandKind.allCases))
        for row in table {
            let checks = row.command.checks
            #expect(checks.area == row.area, "\(row.command)")
            #expect(checks.file?.kind == row.file, "\(row.command)")
            #expect(checks.file?.path == row.file.map { _ in file }, "\(row.command)")
        }
    }

    /// Planner note (activation classes): commands that open ClearShot windows or a chooser keep the activation the URL
    /// gave ClearShot; every other one hands it back first.
    @Test func windowOpeningCommandsKeepActivation() {
        let keeping: Set<CommandKind> = [.openSettings, .openHistory, .openAnnotate, .pin, .openFromClipboard]
        #expect(Set(everyCommand.map(kind)) == Set(CommandKind.allCases))
        for command in everyCommand {
            #expect(command.keepsActivation == keeping.contains(kind(of: command)), "\(command)")
        }
        #expect(APICommand.openSettings(.general).keepsActivation)
        #expect(APICommand.pin(filePath: "/tmp/a.png").keepsActivation)
        #expect(APICommand.openAnnotate(filePath: "/tmp/a.png").keepsActivation)
    }
}
