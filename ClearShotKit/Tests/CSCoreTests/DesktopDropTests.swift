import Foundation
import Testing
@testable import CSCore

/// Files dropped on the desktop cover go into ~/Desktop the way Finder would put them there.
struct DesktopDropTests {
    func operation(sameVolume: Bool = true, optionHeld: Bool = false, allowsMove: Bool = true, allowsCopy: Bool = true,
                   alreadyThere: Bool = false) -> DesktopDrop.Operation? {
        DesktopDrop.operation(sameVolume: sameVolume, optionHeld: optionHeld, sourceAllowsMove: allowsMove,
                              sourceAllowsCopy: allowsCopy, alreadyThere: alreadyThere)
    }

    func name(_ name: String, splitsExtension: Bool = true, taken: Set<String>) -> String {
        DesktopDrop.destinationName(for: name, splitsExtension: splitsExtension, taken: taken)
    }

    // MARK: Move or copy

    /// The same volume moves and another copies; Option copies on the same volume. A source that allows only one of the
    /// two gets that one, even across volumes, and one that allows neither is refused, as is a file already on the
    /// desktop.
    @Test(arguments: [
        // (same volume, Option held, allows move, allows copy, already there, operation)
        (true, false, true, true, false, .move),
        (false, false, true, true, false, .copy),
        (true, true, true, true, false, .copy),
        (true, false, false, true, false, .copy),
        (false, false, true, false, false, .move),
        (true, false, false, false, false, nil),
        (false, true, false, false, false, nil),
        (true, false, true, true, true, nil),
        (true, true, true, true, true, nil),
    ] as [(Bool, Bool, Bool, Bool, Bool, DesktopDrop.Operation?)])
    func theOperationIsTheOneFinderWouldUse(sameVolume: Bool, optionHeld: Bool, allowsMove: Bool, allowsCopy: Bool,
                                            alreadyThere: Bool, expected: DesktopDrop.Operation?) {
        #expect(operation(sameVolume: sameVolume, optionHeld: optionHeld, allowsMove: allowsMove, allowsCopy: allowsCopy,
                          alreadyThere: alreadyThere) == expected)
    }

    // MARK: Names

    /// A free name is kept; a clash counts on from 2. A trailing number from 2 to 99 is a copy number and counts on;
    /// 1, a zero-padded counter, a year or any number from 100 is part of the name. Clashes ignore case, a folder keeps
    /// its dots, a dot file has no extension, and only the last extension is split off.
    @Test(arguments: [
        ("Shot.png", true, ["Other.png"], "Shot.png"),
        ("Shot.png", true, ["Shot.png"], "Shot 2.png"),
        ("Shot.png", true, ["Shot.png", "Shot 2.png"], "Shot 3.png"),
        ("Shot 2.png", true, ["Shot 2.png"], "Shot 3.png"),
        ("Shot 1.png", true, ["Shot 1.png"], "Shot 1 2.png"),
        ("IMG 007.png", true, ["IMG 007.png"], "IMG 007 2.png"),
        ("Report 2024.pdf", true, ["Report 2024.pdf"], "Report 2024 2.pdf"),
        ("IMG 1234.png", true, ["IMG 1234.png"], "IMG 1234 2.png"),
        ("Shot 99.png", true, ["Shot 99.png"], "Shot 100.png"),
        ("Shot 100.png", true, ["Shot 100.png"], "Shot 100 2.png"),
        ("Shot.png", true, ["shot.PNG"], "Shot 2.png"),
        ("Shot.png", true, ["shot.PNG", "SHOT 2.png"], "Shot 3.png"),
        ("My.Folder", false, ["My.Folder"], "My.Folder 2"),
        (".zshrc", true, [".zshrc"], ".zshrc 2"),
        ("a.tar.gz", true, ["a.tar.gz"], "a.tar 2.gz"),
    ] as [(String, Bool, Set<String>, String)])
    func theNameIsFreeOrCountsOn(original: String, splitsExtension: Bool, taken: Set<String>, expected: String) {
        #expect(name(original, splitsExtension: splitsExtension, taken: taken) == expected)
    }

    // MARK: Files kept back

    /// One kept file is named, several are "the files"; the detail gives the reason, then where they are: Undelivered
    /// Drops, or, only when they couldn't be moved there either, a temporary folder macOS empties on its own.
    @Test(arguments: [
        (["IMG_1.heic"], "You don't have permission.", true, "Couldn't put “IMG_1.heic” on the Desktop",
         "You don't have permission. It's kept in ClearShot's Undelivered Drops folder."),
        (["IMG_1.heic", "IMG_2.heic"], "The disk is full.", true, "Couldn't put the files on the Desktop",
         "The disk is full. They're kept in ClearShot's Undelivered Drops folder."),
        (["IMG_1.heic"], "The disk is full.", false, "Couldn't put “IMG_1.heic” on the Desktop",
         "The disk is full. It's in a temporary folder that macOS empties after a few days."),
        (["IMG_1.heic", "IMG_2.heic"], "The disk is full.", false, "Couldn't put the files on the Desktop",
         "The disk is full. They're in a temporary folder that macOS empties after a few days."),
    ] as [([String], String, Bool, String, String)])
    func theAlertSaysWhatWasKeptAndWhere(names: [String], reason: String, inUndeliveredDrops: Bool, message: String,
                                         detail: String) {
        let text = DesktopDrop.undeliveredAlert(names: names, reason: reason, inUndeliveredDrops: inUndeliveredDrops)
        #expect(text.message == message)
        #expect(text.detail == detail)
    }

    // MARK: Copying in

    /// A folder of the test's own in the temporary directory, never ~/Desktop.
    func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "desktop-drop-\(UUID().uuidString)",
                                                                      directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func aCopyLandsAtTheDestinationAndTheSourceStays() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Shot.png")
        try Data("shot".utf8).write(to: source)
        let destination = root.appending(path: "Shot 2.png")
        try DesktopDrop.copyItem(at: source, to: destination)
        #expect(try Data(contentsOf: destination) == Data("shot".utf8))
        #expect(exists(source))
    }

    @Test func aCopyThatFailsPartwayLeavesNothingAtTheDestination() throws {
        // A folder whose second file can't be read: the copy makes the destination folder, then fails inside it, as a
        // full disk or an unplugged drive would leave a truncated file.
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("a".utf8).write(to: source.appending(path: "a.txt"))
        let unreadable = source.appending(path: "b.txt")
        try Data("b".utf8).write(to: unreadable)
        let unreadablePath = unreadable.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadablePath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadablePath) }
        let destination = root.appending(path: "Folder 2", directoryHint: .isDirectory)

        #expect(throws: (any Error).self) { try DesktopDrop.copyItem(at: source, to: destination) }
        #expect(!exists(destination))
        #expect(exists(source.appending(path: "a.txt")))
        #expect(exists(unreadable))
    }

    @Test func aCopyOntoANameSomethingElseTookLeavesThatFile() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Shot.png")
        try Data("shot".utf8).write(to: source)
        let destination = root.appending(path: "Shot 2.png")
        try Data("theirs".utf8).write(to: destination)

        let error = #expect(throws: CocoaError.self) { try DesktopDrop.copyItem(at: source, to: destination) }
        #expect(error?.code == .fileWriteFileExists)
        #expect(try Data(contentsOf: destination) == Data("theirs".utf8))
    }
}
