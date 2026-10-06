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

    @Test func sameVolumeMoves() {
        #expect(operation() == .move)
    }

    @Test func otherVolumeCopies() {
        #expect(operation(sameVolume: false) == .copy)
    }

    @Test func optionCopiesOnTheSameVolume() {
        #expect(operation(optionHeld: true) == .copy)
    }

    @Test func aSourceThatOnlyAllowsCopyIsCopied() {
        #expect(operation(allowsMove: false) == .copy)
        // And the other way round: a source that only allows a move is moved, even across volumes.
        #expect(operation(sameVolume: false, allowsCopy: false) == .move)
    }

    @Test func aSourceThatAllowsNeitherIsRefused() {
        #expect(operation(allowsMove: false, allowsCopy: false) == nil)
        #expect(operation(sameVolume: false, optionHeld: true, allowsMove: false, allowsCopy: false) == nil)
    }

    @Test func aFileAlreadyOnTheDesktopIsRefused() {
        #expect(operation(alreadyThere: true) == nil)
        #expect(operation(optionHeld: true, alreadyThere: true) == nil)
    }

    // MARK: Names

    @Test func aFreeNameIsKept() {
        #expect(name("Shot.png", taken: ["Other.png"]) == "Shot.png")
    }

    @Test func aClashGetsTwo() {
        #expect(name("Shot.png", taken: ["Shot.png"]) == "Shot 2.png")
    }

    @Test func aClashWithTwoTakenGetsThree() {
        #expect(name("Shot.png", taken: ["Shot.png", "Shot 2.png"]) == "Shot 3.png")
    }

    @Test func aNameEndingInANumberCountsOn() {
        #expect(name("Shot 2.png", taken: ["Shot 2.png"]) == "Shot 3.png")
        // 1 isn't a copy number, and neither is a zero-padded counter.
        #expect(name("Shot 1.png", taken: ["Shot 1.png"]) == "Shot 1 2.png")
        #expect(name("IMG 007.png", taken: ["IMG 007.png"]) == "IMG 007 2.png")
    }

    @Test func aYearIsNotACounter() {
        #expect(name("Report 2024.pdf", taken: ["Report 2024.pdf"]) == "Report 2024 2.pdf")
    }

    @Test func aLargeNumberIsNotACounter() {
        #expect(name("IMG 1234.png", taken: ["IMG 1234.png"]) == "IMG 1234 2.png")
    }

    @Test func ninetyNineStillCountsOn() {
        #expect(name("Shot 99.png", taken: ["Shot 99.png"]) == "Shot 100.png")
    }

    @Test func aHundredIsNotACounter() {
        #expect(name("Shot 100.png", taken: ["Shot 100.png"]) == "Shot 100 2.png")
    }

    @Test func clashesIgnoreCase() {
        #expect(name("Shot.png", taken: ["shot.PNG"]) == "Shot 2.png")
        #expect(name("Shot.png", taken: ["shot.PNG", "SHOT 2.png"]) == "Shot 3.png")
    }

    @Test func aFolderKeepsItsDots() {
        #expect(name("My.Folder", splitsExtension: false, taken: ["My.Folder"]) == "My.Folder 2")
    }

    @Test func aDotFileHasNoExtension() {
        #expect(name(".zshrc", taken: [".zshrc"]) == ".zshrc 2")
    }

    @Test func onlyTheLastExtensionIsSplit() {
        #expect(name("a.tar.gz", taken: ["a.tar.gz"]) == "a.tar 2.gz")
    }

    // MARK: Files kept back

    @Test func oneKeptFileIsNamedWithTheReason() {
        let text = DesktopDrop.undeliveredAlert(names: ["IMG_1.heic"], reason: "You don't have permission.",
                                                inUndeliveredDrops: true)
        #expect(text.message == "Couldn't put “IMG_1.heic” on the Desktop")
        #expect(text.detail == "You don't have permission. It's kept in ClearShot's Undelivered Drops folder.")
    }

    @Test func severalKeptFilesAreTheFiles() {
        let text = DesktopDrop.undeliveredAlert(names: ["IMG_1.heic", "IMG_2.heic"], reason: "The disk is full.",
                                                inUndeliveredDrops: true)
        #expect(text.message == "Couldn't put the files on the Desktop")
        #expect(text.detail == "The disk is full. They're kept in ClearShot's Undelivered Drops folder.")
    }

    @Test func aFileLeftInTheTemporaryFolderSaysSo() {
        // Only when it couldn't be moved into Undelivered Drops either; macOS empties that folder on its own.
        let reason = "The disk is full."
        let one = DesktopDrop.undeliveredAlert(names: ["IMG_1.heic"], reason: reason, inUndeliveredDrops: false)
        #expect(one.detail == "\(reason) It's in a temporary folder that macOS empties after a few days.")
        let several = DesktopDrop.undeliveredAlert(names: ["IMG_1.heic", "IMG_2.heic"], reason: reason,
                                                   inUndeliveredDrops: false)
        #expect(several.detail == "\(reason) They're in a temporary folder that macOS empties after a few days.")
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
