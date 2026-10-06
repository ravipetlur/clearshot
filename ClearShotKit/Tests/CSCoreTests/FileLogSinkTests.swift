import Foundation
import Testing
@testable import CSCore

struct FileLogSinkTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "clearshot-log-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func writesLevelCategoryAndMessage() throws {
        let sink = FileLogSink(directory: directory)
        sink.append(level: .warning, category: "capture", message: "hello", date: Date(timeIntervalSince1970: 0))
        let text = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        #expect(text == "1970-01-01T00:00:00Z [WARN] [capture] hello\n")
    }

    /// Text from outside (a URL's parameter names, an app's name) can't forge a line of its own. Control characters,
    /// line breaks among them, and the Unicode line and paragraph separators are written as escapes.
    @Test func aMessageCantStartALineOfItsOwn() throws {
        let sink = FileLogSink(directory: directory)
        let forged = "api ignores x\n1970-01-01T00:00:00Z [INFO] [api] Running pin"
            + "\r\ttab\u{1B}[31m\u{0}\u{85}\u{2028}\u{2029}end"
        sink.append(level: .info, category: "api", message: forged, date: Date(timeIntervalSince1970: 0))
        let text = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        #expect(text == "1970-01-01T00:00:00Z [INFO] [api] api ignores x"
            + "\\n1970-01-01T00:00:00Z [INFO] [api] Running pin"
            + "\\r\\ttab\\u{1B}[31m\\u{0}\\u{85}\\u{2028}\\u{2029}end\n")
        // Everything else is written as it is.
        #expect(FileLogSink.escaped("Raycast “Pro” 📸 → café") == "Raycast “Pro” 📸 → café")
    }

    @Test func rotatesAndKeepsOnlyTheConfiguredNumberOfFiles() throws {
        let sink = FileLogSink(directory: directory, maxBytes: 200, rotatedFilesToKeep: 2)
        for index in 0..<20 {
            sink.append(level: .info, category: "t", message: "line \(index) xxxxxxxxxxxxxxxx")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
        #expect(files == ["clearshot.1.log", "clearshot.2.log", "clearshot.log"])
        let current = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        #expect(current.contains("line 19 "))
        #expect(!current.contains("line 0 "))
        let size = try FileManager.default.attributesOfItem(atPath: sink.currentFileURL.path(percentEncoded: false))[.size] as? Int
        #expect((size ?? 0) <= 200)
    }
}
