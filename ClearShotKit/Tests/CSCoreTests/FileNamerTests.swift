import Foundation
import Testing
@testable import CSCore

struct FileNamerTests {
    static let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    static let posix = Locale(identifier: "en_US_POSIX")
    /// Friday, 2 October 2026, 14:05:09 in Kolkata (08:35:09 UTC).
    static let date: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = kolkata
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 14, minute: 5, second: 9))!
    }()

    func context(appName: String? = "Safari", windowTitle: String? = "Inbox", autoIncrement: Int = 7,
                 timeZone: TimeZone = kolkata, removeIllegal: Bool = true) -> FileNameContext {
        FileNameContext(date: Self.date, timeZone: timeZone, locale: Self.posix, appName: appName,
                        windowTitle: windowTitle, autoIncrement: autoIncrement,
                        removeIllegalCharacters: removeIllegal, randomCharacters: { "abc123" })
    }

    @Test func defaultTemplateNamesLikeMacOSScreenshots() {
        let name = FileNamer.baseName(for: .standard, context: context())
        #expect(name == "Screenshot 2026-10-02 at 14.05.09")
    }

    @Test func everyTokenRenders() {
        let template = FileNameTemplate(parsing: "%y_%m_%n_%d_%w_%H_%M_%S_%p_%r_%a_%t_%i")
        let name = FileNamer.baseName(for: template, context: context())
        // %p is present, so %H uses the 12-hour clock.
        #expect(name == "2026_10_October_02_Friday_02_05_09_PM_abc123_Safari_Inbox_7")
    }

    @Test func hourIs24HourWithoutAMPM() {
        let name = FileNamer.baseName(for: FileNameTemplate(parsing: "%H"), context: context())
        #expect(name == "14")
    }

    @Test func utcChangesTheTime() {
        let name = FileNamer.baseName(for: .standard, context: context(timeZone: .gmt))
        #expect(name == "Screenshot 2026-10-02 at 08.35.09")
    }

    @Test func parsingRoundTripsAndKeepsUnknownCodes() {
        // "%%y" is a literal "%y"; "%q" is not a code and stays literal.
        let source = "Shot %y 100%%y done %q"
        let template = FileNameTemplate(parsing: source)
        #expect(template.tokens == [.text("Shot "), .year, .text(" 100%y done %q")])
        #expect(template.stringValue == source)
    }

    @Test func illegalCharactersAreRemovedOrReplaced() {
        let template = FileNameTemplate(parsing: "%t")
        let strict = FileNamer.baseName(for: template, context: context(windowTitle: "a/b:c?d*\"e\n"))
        #expect(strict == "a-b-cde")
        let lenient = FileNamer.baseName(for: template, context: context(windowTitle: "a/b:c?d*", removeIllegal: false))
        #expect(lenient == "a-b-c?d*")
    }

    @Test func emptyResultFallsBackToScreenshot() {
        let name = FileNamer.baseName(for: FileNameTemplate(parsing: "%a"), context: context(appName: nil))
        #expect(name == "Screenshot")
        #expect(FileNamer.sanitize("  ..  ", removeIllegalCharacters: true) == "Screenshot")
    }

    @Test func controlCharactersAndNewlinesAreAlwaysRemoved() {
        // Even with "Remove illegal characters" off, NUL and newlines would make an unusable name.
        #expect(FileNamer.sanitize("a\u{0}b\nc\td", removeIllegalCharacters: false) == "abcd")
    }

    @Test func longNamesAreCappedByUTF8BytesOnCharacterBoundaries() {
        // APFS allows 255 UTF-8 bytes per name; 240 leaves room for " (12)" and an extension.
        #expect(FileNamer.sanitize(String(repeating: "x", count: 500), removeIllegalCharacters: true).utf8.count == 240)
        let cjk = FileNamer.sanitize(String(repeating: "界", count: 120), removeIllegalCharacters: true)
        #expect(cjk.utf8.count <= 240)
        #expect(cjk == String(repeating: "界", count: 80))
    }

    @Test func uniqueURLAddsANumberOnCollision() {
        let dir = URL(filePath: "/tmp/shots", directoryHint: .isDirectory)
        let taken: Set<String> = ["/tmp/shots/A.jpg", "/tmp/shots/A (2).jpg"]
        let url = FileNamer.uniqueURL(in: dir, baseName: "A", pathExtension: "jpg") {
            taken.contains($0.path(percentEncoded: false))
        }
        #expect(url.lastPathComponent == "A (3).jpg")
    }

    @Test func randomCharactersAreSixAlphanumerics() {
        let random = FileNamer.randomCharacters()
        #expect(random.count == 6)
        #expect(random.allSatisfy { $0.isLetter || $0.isNumber })
    }
}
