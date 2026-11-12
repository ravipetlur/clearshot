import Foundation
import Testing
import CSUpdate

struct ChecksumFileTests {
    let name = Self.fileName
    /// SHA-256 of the three bytes "abc" (FIPS 180-4 example).
    let abc = Self.abcHash
    /// SHA-256 of nothing.
    let nothing = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let other = Self.otherHash

    static let fileName = "ClearShot-1.2.0.dmg"
    static let abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    static let otherHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    // MARK: Parsing: a good line

    /// The shasum format, with or without a final newline, one space or two, a star for binary mode (ignored), upper or
    /// mixed case hex (returned in lower case), and Windows line endings.
    static let goodLines: [String] = {
        let (abc, name, other) = (abcHash, fileName, otherHash)
        let mixed = String(abc.prefix(30)).uppercased() + String(abc.dropFirst(30))
        return [
            "\(abc)  \(name)\n", "\(abc)  \(name)", "\(abc) \(name)\n", "\(abc) *\(name)\n", "\(abc)  *\(name)\n",
            "\(abc.uppercased())  \(name)\n", "\(mixed)  \(name)\n", "\(abc)  \(name)\r\n", "\(other)  Other.dmg\r\n\(abc)  \(name)\r\n",
        ]
    }()

    @Test(arguments: goodLines)
    func readsTheHashFromAGoodLine(text: String) {
        #expect(ChecksumFile.expectedHash(in: text, forFile: name) == abc)
    }

    // MARK: Parsing: the wrong name or hash

    @Test(arguments: ["ClearShot-1.2.1.dmg", "clearshot-1.2.0.dmg", "ClearShot-1.2.0.dmg.sha256", "ClearShot-1.2.0", "learShot-1.2.0.dmg", "ClearShot-1.2.0.dmg ", "./ClearShot-1.2.0.dmg", "dist/ClearShot-1.2.0.dmg", ""])
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

    // MARK: Parsing: the separator

    @Test(arguments: ["", "   ", "\t", " \t", "\t\t", "\u{a0}", "\u{3000}", ":", " = ", ","])
    func onlyOneOrTwoSpacesSeparate(separator: String) {
        #expect(ChecksumFile.expectedHash(in: "\(abc)\(separator)\(name)\n", forFile: name) == nil)
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

    /// Text that isn't a checksum line, and lines that are nearly one: a 65-digit hash (its first 64 must not leak), a
    /// star after three spaces (not a separator), a leading space on the line, and the BSD style.
    static let malformed: [String] = {
        let (abc, name) = (abcHash, fileName)
        return [
            "", "\n", "   \n", "garbage", "hello world", "{\"sha256\": \"abc\"}", "<html>404</html>", "\0\0\0",
            "\(abc)b  \(name)\n", "\(abc)   *\(name)\n", " \(abc)  \(name)\n", "SHA256 (\(name)) = \(abc)\n",
        ]
    }()

    @Test(arguments: malformed)
    func malformedTextGivesNothing(text: String) {
        #expect(ChecksumFile.expectedHash(in: text, forFile: name) == nil)
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

    /// A file is read a megabyte at a time. Empty, a few bytes, and either side of the 64 KiB and 1 MiB boundaries all
    /// hash as the same bytes in memory do (which `hashesKnownData` ties to the known hashes).
    @Test(arguments: [0, 1, 3, 65_535, 65_536, 65_537, 1_048_575, 1_048_576, 1_048_577])
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

    /// Just over the megabyte the file is read in, so these files take two reads, the second a short one.
    static let pastOneChunk = 1_048_576 + 4_096
    static let inTheSecondChunk = 1_048_576 + 1_000

    @Test func aFileMatchesItsPublishedChecksum() throws {
        try withScratchFolder { folder in
            let bytes = pattern(count: Self.pastOneChunk)
            let dmg = folder.appendingPathComponent(name)
            try bytes.write(to: dmg)
            let published = "\(ChecksumFile.sha256(of: bytes))  \(name)\n"
            let expected = try #require(ChecksumFile.expectedHash(in: published, forFile: name))
            #expect(try ChecksumFile.matches(fileAt: dmg, expectedHash: expected))
        }
    }

    @Test func oneChangedByteBreaksTheMatch() throws {
        try withScratchFolder { folder in
            var bytes = pattern(count: Self.pastOneChunk)
            let published = "\(ChecksumFile.sha256(of: bytes))  \(name)\n"
            let expected = try #require(ChecksumFile.expectedHash(in: published, forFile: name))
            bytes[Self.inTheSecondChunk] ^= 0x01
            let dmg = folder.appendingPathComponent(name)
            try bytes.write(to: dmg)
            #expect(try !ChecksumFile.matches(fileAt: dmg, expectedHash: expected))
        }
    }

    @Test func aTruncatedFileDoesNotMatch() throws {
        try withScratchFolder { folder in
            let bytes = pattern(count: Self.pastOneChunk)
            let expected = ChecksumFile.sha256(of: bytes)
            let dmg = folder.appendingPathComponent(name)
            try bytes.dropLast().write(to: dmg)
            #expect(try !ChecksumFile.matches(fileAt: dmg, expectedHash: expected))
        }
    }
}
