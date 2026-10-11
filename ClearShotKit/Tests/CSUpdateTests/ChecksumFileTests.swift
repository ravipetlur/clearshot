import Foundation
import Testing
import CSUpdate

struct ChecksumFileTests {
    let name = "ClearShot-1.2.0.dmg"
    /// SHA-256 of the three bytes "abc" (FIPS 180-4 example).
    let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    /// SHA-256 of nothing.
    let nothing = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let other = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    // MARK: Parsing: a good line

    @Test func readsTheHashFromTheShasumFormat() {
        #expect(ChecksumFile.expectedHash(in: "\(abc)  \(name)\n", forFile: name) == abc)
    }

    @Test func aMissingFinalNewlineIsFine() {
        #expect(ChecksumFile.expectedHash(in: "\(abc)  \(name)", forFile: name) == abc)
    }

    @Test func oneSpaceIsFine() {
        #expect(ChecksumFile.expectedHash(in: "\(abc) \(name)\n", forFile: name) == abc)
    }

    @Test func aStarMarksBinaryModeAndIsIgnored() {
        #expect(ChecksumFile.expectedHash(in: "\(abc) *\(name)\n", forFile: name) == abc)
        #expect(ChecksumFile.expectedHash(in: "\(abc)  *\(name)\n", forFile: name) == abc)
    }

    @Test func upperCaseHexIsReadAndReturnedInLowerCase() {
        #expect(ChecksumFile.expectedHash(in: "\(abc.uppercased())  \(name)\n", forFile: name) == abc)
        let mixed = String(abc.prefix(30)).uppercased() + String(abc.dropFirst(30))
        #expect(ChecksumFile.expectedHash(in: "\(mixed)  \(name)\n", forFile: name) == abc)
    }

    @Test func windowsLineEndingsAreFine() {
        #expect(ChecksumFile.expectedHash(in: "\(abc)  \(name)\r\n", forFile: name) == abc)
        #expect(ChecksumFile.expectedHash(in: "\(other)  Other.dmg\r\n\(abc)  \(name)\r\n", forFile: name) == abc)
    }

    // MARK: Parsing: the wrong name or hash

    @Test func theWrongNameGivesNothing() {
        #expect(ChecksumFile.expectedHash(in: "\(abc)  \(name)\n", forFile: "ClearShot-1.2.1.dmg") == nil)
    }

    @Test(arguments: ["clearshot-1.2.0.dmg", "ClearShot-1.2.0.dmg.sha256", "ClearShot-1.2.0", "learShot-1.2.0.dmg", "ClearShot-1.2.0.dmg ", "./ClearShot-1.2.0.dmg", "dist/ClearShot-1.2.0.dmg", ""])
    func theNameMustMatchExactly(asked: String) {
        #expect(ChecksumFile.expectedHash(in: "\(abc)  \(name)\n", forFile: asked) == nil)
    }

    @Test func aLongerNameInTheFileDoesNotMatchAShorterOne() {
        #expect(ChecksumFile.expectedHash(in: "\(abc)  \(name).zip\n", forFile: name) == nil)
        #expect(ChecksumFile.expectedHash(in: "\(abc)  x\(name)\n", forFile: name) == nil)
    }

    @Test(arguments: [
        String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "a", count: 32), "",
        String(repeating: "g", count: 64), String(repeating: "a", count: 63) + "z", String(repeating: "a", count: 63) + " ",
        String(repeating: "\u{ff41}", count: 64),
    ])
    func aHashThatIsNotSixtyFourHexDigitsGivesNothing(hash: String) {
        #expect(ChecksumFile.expectedHash(in: "\(hash)  \(name)\n", forFile: name) == nil)
    }

    @Test func aSixtyFiveDigitHashDoesNotLeakItsFirstSixtyFour() {
        #expect(ChecksumFile.expectedHash(in: "\(abc)b  \(name)\n", forFile: name) == nil)
    }

    // MARK: Parsing: the separator

    @Test(arguments: ["", "   ", "\t", " \t", "\t\t", "\u{a0}", "\u{3000}", ":", " = ", ","])
    func onlyOneOrTwoSpacesSeparate(separator: String) {
        #expect(ChecksumFile.expectedHash(in: "\(abc)\(separator)\(name)\n", forFile: name) == nil)
    }

    @Test func aStarAfterThreeSpacesIsNotASeparator() {
        #expect(ChecksumFile.expectedHash(in: "\(abc)   *\(name)\n", forFile: name) == nil)
    }

    @Test func aLeadingSpaceOnTheLineIsMalformed() {
        #expect(ChecksumFile.expectedHash(in: " \(abc)  \(name)\n", forFile: name) == nil)
    }

    @Test func aLineWithoutANameIsMalformed() {
        #expect(ChecksumFile.expectedHash(in: "\(abc)\n", forFile: name) == nil)
        #expect(ChecksumFile.expectedHash(in: "\(abc)  \n", forFile: name) == nil)
        #expect(ChecksumFile.expectedHash(in: "\(abc)  *\n", forFile: name) == nil)
    }

    // MARK: Parsing: extra lines

    @Test func findsTheLineAmongOthers() {
        let text = """
        \(other)  Other-1.0.0.dmg
        \(abc)  \(name)
        \(nothing)  Another.zip

        """
        #expect(ChecksumFile.expectedHash(in: text, forFile: name) == abc)
    }

    @Test func blankLinesAndGarbageLinesAreSkipped() {
        let text = "\n\n# checksums\nnot a checksum line\n\n\(abc)  \(name)\n\ntrailing words\n"
        #expect(ChecksumFile.expectedHash(in: text, forFile: name) == abc)
    }

    @Test func theSameLineTwiceIsFine() {
        #expect(ChecksumFile.expectedHash(in: "\(abc)  \(name)\n\(abc.uppercased()) *\(name)\n", forFile: name) == abc)
    }

    @Test func twoDifferentHashesForTheSameNameAreAmbiguous() {
        #expect(ChecksumFile.expectedHash(in: "\(abc)  \(name)\n\(other)  \(name)\n", forFile: name) == nil)
    }

    @Test func aMalformedLineForTheNameDoesNotCountAsAnEntry() {
        let text = "\(String(abc.dropLast()))  \(name)\n"
        #expect(ChecksumFile.expectedHash(in: text, forFile: name) == nil)
        #expect(ChecksumFile.expectedHash(in: text + "\(other)  \(name)\n", forFile: name) == other)
    }

    // MARK: Parsing: malformed text

    @Test(arguments: ["", "\n", "   \n", "garbage", "hello world", "{\"sha256\": \"abc\"}", "<html>404</html>", "\0\0\0"])
    func malformedTextGivesNothing(text: String) {
        #expect(ChecksumFile.expectedHash(in: text, forFile: name) == nil)
    }

    @Test func theBSDStyleIsNotUnderstood() {
        #expect(ChecksumFile.expectedHash(in: "SHA256 (\(name)) = \(abc)\n", forFile: name) == nil)
    }

    @Test func theRealFilesShape() {
        // 64 hex, two spaces, the file name, a newline: 86 bytes for this name, as the release's file is.
        let line = "\(String(repeating: "7", count: 64))  \(name)\n"
        #expect(line.utf8.count == 64 + 2 + name.utf8.count + 1)
        #expect(ChecksumFile.expectedHash(in: line, forFile: name) == String(repeating: "7", count: 64))
    }

    // MARK: Hashing data

    @Test func hashesKnownData() {
        #expect(ChecksumFile.sha256(of: Data("abc".utf8)) == abc)
        #expect(ChecksumFile.sha256(of: Data()) == nothing)
    }

    @Test func hashesAreSixtyFourLowerCaseHexDigits() {
        let hash = ChecksumFile.sha256(of: Data([0, 1, 2, 3, 250, 251, 252, 253, 254, 255]))
        #expect(hash.count == 64)
        #expect(hash.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func matchesTheRightHashAndNoOther() {
        let data = Data("abc".utf8)
        #expect(ChecksumFile.matches(data, expectedHash: abc))
        #expect(ChecksumFile.matches(data, expectedHash: abc.uppercased()))
        #expect(!ChecksumFile.matches(data, expectedHash: other))
        #expect(!ChecksumFile.matches(data, expectedHash: nothing))
        #expect(!ChecksumFile.matches(data, expectedHash: ""))
        #expect(!ChecksumFile.matches(data, expectedHash: String(abc.dropLast())))
        #expect(!ChecksumFile.matches(data, expectedHash: abc + "0"))
        #expect(!ChecksumFile.matches(Data("abd".utf8), expectedHash: abc))
    }

    // MARK: Hashing files

    /// A scratch folder under the temporary directory, removed afterwards.
    @discardableResult
    func withScratchFolder<T>(_ body: (URL) throws -> T) throws -> T {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CSUpdateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try body(folder)
    }

    /// Deterministic bytes that don't repeat on a power-of-two boundary, so a chunking mistake changes the hash.
    func pattern(count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 8) ^ ($0 >> 17)) })
    }

    @Test func hashesAFileLikeTheSameBytesInMemory() throws {
        try withScratchFolder { folder in
            let url = folder.appendingPathComponent("small.bin")
            try Data("abc".utf8).write(to: url)
            #expect(try ChecksumFile.sha256(ofFileAt: url) == abc)
        }
    }

    @Test func hashesAnEmptyFile() throws {
        try withScratchFolder { folder in
            let url = folder.appendingPathComponent("empty.bin")
            try Data().write(to: url)
            #expect(try ChecksumFile.sha256(ofFileAt: url) == nothing)
        }
    }

    @Test(arguments: [1, 65_535, 65_536, 65_537, 1_048_575, 1_048_576, 1_048_577, 2_621_443, 5_000_000])
    func streamsFilesOfAnySizeToTheSameHash(size: Int) throws {
        try withScratchFolder { folder in
            let bytes = pattern(count: size)
            let url = folder.appendingPathComponent("blob.bin")
            try bytes.write(to: url)
            #expect(try ChecksumFile.sha256(ofFileAt: url) == ChecksumFile.sha256(of: bytes))
        }
    }

    @Test func aMissingFileThrows() throws {
        try withScratchFolder { folder in
            #expect(throws: (any Error).self) { try ChecksumFile.sha256(ofFileAt: folder.appendingPathComponent("nope.dmg")) }
            #expect(throws: (any Error).self) { try ChecksumFile.matches(fileAt: folder.appendingPathComponent("nope.dmg"), expectedHash: abc) }
        }
    }

    @Test func aFolderIsNotAFile() throws {
        try withScratchFolder { folder in
            #expect(throws: (any Error).self) { try ChecksumFile.sha256(ofFileAt: folder) }
        }
    }

    // MARK: The two together

    @Test func aFileMatchesItsPublishedChecksum() throws {
        try withScratchFolder { folder in
            let bytes = pattern(count: 1_500_000)
            let dmg = folder.appendingPathComponent(name)
            try bytes.write(to: dmg)
            let published = "\(ChecksumFile.sha256(of: bytes))  \(name)\n"
            let expected = try #require(ChecksumFile.expectedHash(in: published, forFile: name))
            #expect(try ChecksumFile.matches(fileAt: dmg, expectedHash: expected))
        }
    }

    @Test func oneChangedByteBreaksTheMatch() throws {
        try withScratchFolder { folder in
            var bytes = pattern(count: 1_500_000)
            let published = "\(ChecksumFile.sha256(of: bytes))  \(name)\n"
            let expected = try #require(ChecksumFile.expectedHash(in: published, forFile: name))
            bytes[1_234_567] ^= 0x01
            let dmg = folder.appendingPathComponent(name)
            try bytes.write(to: dmg)
            #expect(try !ChecksumFile.matches(fileAt: dmg, expectedHash: expected))
        }
    }

    @Test func aTruncatedFileDoesNotMatch() throws {
        try withScratchFolder { folder in
            let bytes = pattern(count: 1_500_000)
            let expected = ChecksumFile.sha256(of: bytes)
            let dmg = folder.appendingPathComponent(name)
            try bytes.dropLast().write(to: dmg)
            #expect(try !ChecksumFile.matches(fileAt: dmg, expectedHash: expected))
        }
    }
}
