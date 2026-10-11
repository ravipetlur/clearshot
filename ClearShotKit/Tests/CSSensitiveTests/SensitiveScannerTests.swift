import CoreGraphics
import CSOCR
import CSTestSupport
import Foundation
import Testing
@testable import CSSensitive

/// The scanner on rendered images, read by Vision. Vision's output changes with the OS, and even with the executable, so the
/// boxes are held to about half a character (Vision places the ends of a range by estimate). The tests that run recognition are
/// skipped on a Mac where Vision's text recognition throws (see `VisionTextRecognition`); the ones that don't run it run
/// everywhere. The first recognition after the test target is rebuilt takes about half a minute while Vision loads its models:
/// slow, not hung.
@Suite(.serialized, .timeLimit(.minutes(5)))
struct SensitiveScannerTests {
    private let email = "jane@example.com"
    private let card = "4242 4242 4242 4242"
    /// Letters and digits that Vision can't confuse into other characters, 40 in all: `ghp_` and 36 of them.
    private var token: String { "gh" + "p_" + "aBcDeFgHjKmNpQrStUvWxYz23456789aBcDe".prefix(36) }

    /// How far, in pixels, a finding's box may lie from the pixels of the text: Vision's ends of a range are up to about half a
    /// character out (12 px in 56 px type), and the mask adds its margin.
    private func tolerance(_ scale: Int) -> CGFloat { CGFloat(7 * scale) }

    /// Checks that `finding` lies on `expected` to within `tolerance` at both ends, and sits on the same text: it overlaps the
    /// line's height by at least 60% and is no more than 1.6 times as tall (Vision's box for a range takes in the descenders of
    /// the letters in it, so it can lie a few pixels lower than the font's own metrics). And, the check that matters most,
    /// that its **mask** (`MaskGeometry.maskRect`) covers the pixels the text is drawn on, from its first to its last, which
    /// `expected` gives from the font's own metrics, not from Vision.
    private func expect(_ finding: ImageFinding, covers expected: CGRect, in page: ScanFixture, tolerance: CGFloat, _ note: String = "",
                        sourceLocation: SourceLocation = #_sourceLocation) {
        let rect = finding.rect
        #expect(abs(rect.minX - expected.minX) <= tolerance && abs(rect.maxX - expected.maxX) <= tolerance,
                "x \(rect.minX)…\(rect.maxX) for \(expected.minX)…\(expected.maxX) \(note)", sourceLocation: sourceLocation)
        let overlap = min(rect.maxY, expected.maxY) - max(rect.minY, expected.minY)
        #expect(overlap >= expected.height * 0.6 && rect.height <= expected.height * 1.6,
                "y \(rect.minY)…\(rect.maxY) for \(expected.minY)…\(expected.maxY) \(note)", sourceLocation: sourceLocation)
        expectMask(of: finding, coversAcross: expected, in: page, note, sourceLocation: sourceLocation)
    }

    /// Checks that the mask for `finding` reaches from at or before `expected`'s left edge to at or after its right edge: no part
    /// of the text, however far Vision's box is out at either end, stays outside the mask.
    private func expectMask(of finding: ImageFinding, coversAcross expected: CGRect, in page: ScanFixture, _ note: String = "",
                            sourceLocation: SourceLocation = #_sourceLocation) {
        let mask = MaskGeometry.maskRect(for: finding.rect, imageSize: CGSize(width: page.width, height: page.height))
        #expect(mask.minX <= expected.minX && mask.maxX >= expected.maxX,
                "mask \(mask.minX)…\(mask.maxX) for text \(expected.minX)…\(expected.maxX) \(note)", sourceLocation: sourceLocation)
    }

    /// The mask that Mask All and Annotate's command would add for `finding` on this page, upright and unscaled: through
    /// `MaskPlan`, so it has the margins the finding's kind of shape gets there.
    private func realMask(of finding: ImageFinding, in page: ScanFixture) -> CGRect {
        let size = CGSize(width: page.width, height: page.height)
        return MaskPlan.masks(for: [finding], imageSize: size, toBase: .identity, baseSize: size, pixelScale: 1).first?.rect ?? .zero
    }

    /// Checks the mask for `finding` against the pixels the text is drawn on, which `ink` is the box of:
    /// - **must hold:** every pixel of the ink lies inside the mask (`MaskGeometry.maskRect`, rounded out to whole pixels), so no
    ///   part of the secret stays readable, however far Vision's box is out;
    /// - **bounded:** the mask lies within the ink widened by the largest side margin (16 px) and 14 px more across, and up and
    ///   down by 30 px for a block of lines (its 16 px cap and the same 14 more) or by the vertical margin for the line's height
    ///   and 14 more: a mask that covered a good deal more than the secret would pass the first check by being large.
    private func expectMask(of finding: ImageFinding, coversInk ink: CGRect, in page: ScanFixture, bounded: Bool = true, _ note: String = "",
                            sourceLocation: SourceLocation = #_sourceLocation) {
        let mask = realMask(of: finding, in: page)
        #expect(mask.integral.contains(ink), "ink \(ink) is not inside the mask \(mask) \(note)", sourceLocation: sourceLocation)
        guard bounded else { return }
        // Up and down, a block of lines is held to its own cap (16) and the same 14 px more as across, from the numbers, not from
        // the margin function: Vision's box is a few pixels outside the ink, and a margin of a tenth of the block (29 px on the
        // six-line key) would pass a bound made from the same function. Where Vision's box lies moves with the font smoothing
        // by a few pixels, so the tolerance isn't cut to the measurements; that the cap is applied at all is the pure tests'
        // (`MaskPlanTests`, `MaskGeometryTests`), which fail with it removed. A single line keeps its tenth.
        let vertical: CGFloat = finding.spansLines ? 16 + 14 : MaskGeometry.verticalMargin(forHeight: finding.rect.height) + 14
        let reach = ink.insetBy(dx: -(16 + 14), dy: -vertical)
        #expect(reach.contains(mask), "the mask \(mask) reaches far past the ink \(ink) \(note)", sourceLocation: sourceLocation)
    }

    // MARK: Three kinds of finding, at 1× and 2×

    @Test(.needsVisionTextRecognition, arguments: [1, 2], [true, false])
    func anEmailATokenAndACardAreThreeFindingsBoxedOnTheirOwnText(scale: Int, smoothing: Bool) async throws {
        let size = CGFloat(28 * scale)
        let page = ScanFixture(width: 900 * scale, height: 300 * scale, smoothing: smoothing)
        let mail = page.text("mail me at \(email)", x: CGFloat(40 * scale), top: CGFloat(40 * scale), size: size)
        let key = page.text("paste \(token) here", x: CGFloat(40 * scale), top: CGFloat(110 * scale), size: size)
        let pay = page.text("card \(card)", x: CGFloat(40 * scale), top: CGFloat(180 * scale), size: size)

        let found = try await SensitiveScanner.scan(page.image(), kinds: .all)

        #expect(found.map(\.kind) == [.contact, .keyOrToken, .card], "\(found)")
        guard found.count == 3 else { return }
        expect(found[0], covers: mail.rect(of: email), in: page, tolerance: tolerance(scale), "email at \(scale)×")
        expect(found[1], covers: key.rect(of: token), in: page, tolerance: tolerance(scale), "token at \(scale)×")
        expect(found[2], covers: pay.rect(of: card), in: page, tolerance: tolerance(scale), "card at \(scale)×")
        // The pixels of each secret itself are inside its mask (the line's other words aren't asked for). The region the ink is
        // looked for in is the secret's own box, past which a letter can reach: the hook of a "j" hangs left of its advance. A few
        // pixels more each side is still within the spaces around the secret.
        for (finding, span, name) in [(found[0], mail.rect(of: email), "email"), (found[1], key.rect(of: token), "token"),
                                      (found[2], pay.rect(of: card), "card")] {
            guard let ink = page.inkBox(in: span.insetBy(dx: CGFloat(-4 * scale), dy: 0)) else { Issue.record("no ink for the \(name)"); continue }
            expectMask(of: finding, coversInk: ink, in: page, bounded: false, "\(name) at \(scale)×, smoothing \(smoothing)")
        }
        // Not the line's other words: "mail me at" ends before the address, "here" begins after the token.
        #expect(found[0].rect.minX > mail.rect(of: "mail me at").maxX)
        #expect(found[1].rect.minX > key.rect(of: "paste").maxX && found[1].rect.maxX < key.rect(of: "here").minX + tolerance(scale))
        #expect(found[2].rect.minX > pay.rect(of: "card").maxX)
    }

    @Test(.needsVisionTextRecognition) func onlyTheKindsAskedForAreFound() async throws {
        let page = ScanFixture(width: 900, height: 300)
        page.text("mail me at \(email)", x: 40, top: 40, size: 28)
        page.text("paste \(token) here", x: 40, top: 110, size: 28)
        let pay = page.text("card \(card)", x: 40, top: 180, size: 28)

        let cards = try await SensitiveScanner.scan(page.image(), kinds: .cards)
        #expect(cards.map(\.kind) == [.card])
        if let first = cards.first { expect(first, covers: pay.rect(of: card), in: page, tolerance: tolerance(1)) }
        #expect(try await SensitiveScanner.scan(page.image(), kinds: [.contact, .ipAddresses]).map(\.kind) == [.contact])
        #expect(try await SensitiveScanner.scan(page.image(), kinds: []).isEmpty)
    }

    @Test(.needsVisionTextRecognition) func anImageWithNothingSensitiveGivesNothing() async throws {
        let plain = ScanFixture(width: 900, height: 300)
        plain.text("Meeting notes for the week", x: 40, top: 40, size: 28)
        plain.text("Nothing in here is a secret at all", x: 40, top: 110, size: 28)
        #expect(try await SensitiveScanner.scan(plain.image(), kinds: .all).isEmpty)
        #expect(try await SensitiveScanner.scan(ScanFixture(width: 900, height: 300).image(), kinds: .all).isEmpty)
    }

    // MARK: Private keys

    /// A private key's lines, drawn one under another: the header, `body` lines of 64 characters and the END line.
    private func drawKey(on page: ScanFixture, body: Int = 4, header: Bool = true, top: CGFloat = 30, spacing: CGFloat = 50)
        -> [ScanFixture.Drawn] {
        var texts: [String] = []
        if header { texts.append(Fake.privateKeyBegin()) }
        texts += (1...body).map { Fake.privateKeyBody(64, line: $0) }
        texts.append(Fake.privateKeyEnd())
        return texts.enumerated().map { page.text($1, x: 40, top: top + spacing * CGFloat($0), size: 28) }
    }

    /// The box of all of `lines` together.
    private func union(_ lines: [ScanFixture.Drawn]) -> CGRect {
        lines.map(\.rect).reduce(CGRect.null) { $0.union($1) }
    }

    @Test(.needsVisionTextRecognition, arguments: [true, false])
    func aPrivateKeyIsOneFindingOverAllSixOfItsLines(smoothing: Bool) async throws {
        let page = ScanFixture(width: 1400, height: 440, smoothing: smoothing)
        _ = drawKey(on: page)

        let found = try await SensitiveScanner.scan(page.image(), kinds: .all)

        #expect(found.count == 1 && found.first?.kind == .keyOrToken && found.first?.spansLines == true, "\(found)")
        guard let finding = found.first else { return }
        // The page holds nothing but the key's six lines, so every pixel that isn't white is theirs.
        let ink = try #require(page.inkBox(in: CGRect(x: 0, y: 0, width: page.width, height: page.height)))
        expectMask(of: finding, coversInk: ink, in: page, "smoothing \(smoothing)")
    }

    @Test(.needsVisionTextRecognition) func theSameLinesWithoutAHeaderAreNotFindings() async throws {
        let page = ScanFixture(width: 1400, height: 400)
        _ = drawKey(on: page, header: false)
        #expect(try await SensitiveScanner.scan(page.image(), kinds: .all).isEmpty)
    }

    @Test(.needsVisionTextRecognition, arguments: [true, false])
    func aKeyIsMaskedFromTheHeaderOnNotFromTheWordsBeforeIt(smoothing: Bool) async throws {
        let page = ScanFixture(width: 1400, height: 440, smoothing: smoothing)
        let label = "Private key: "
        let header = page.text(label + Fake.privateKeyBegin(), x: 40, top: 30, size: 28)
        let labelWidth = header.rect(of: label).width
        for line in 1...3 { page.text(Fake.privateKeyBody(64, line: line), x: 40 + labelWidth, top: 30 + 50 * CGFloat(line), size: 28) }
        page.text(Fake.privateKeyEnd(), x: 40 + labelWidth, top: 30 + 50 * 4, size: 28)

        let found = try await SensitiveScanner.scan(page.image(), kinds: .all)

        #expect(found.count == 1 && found.first?.kind == .keyOrToken, "\(found)")
        guard let finding = found.first else { return }
        // The key's own pixels: everything from where the header starts, past the label, across the whole page.
        let keyStart = 40 + labelWidth
        let keyInk = try #require(page.inkBox(in: CGRect(x: keyStart, y: 0, width: CGFloat(page.width) - keyStart, height: CGFloat(page.height))))
        expectMask(of: finding, coversInk: keyInk, in: page, "smoothing \(smoothing)")
        // The words before it are left alone: no pixel of "Private" is under the mask.
        let mask = realMask(of: finding, in: page).integral
        let word = try #require(page.inkBox(in: header.rect(of: "Private")))
        #expect(!mask.intersects(word), "the mask \(mask) covers \"Private\" at \(word)")
    }

    /// A key as a JSON file has it: on one line, its lines joined by a backslash and an n.
    private var jsonKey: String {
        let escape = "\\n"
        return "\"private_key\": \"" + Fake.privateKeyBegin() + escape + (1...4).map { Fake.privateKeyBody(64, line: $0) }.joined(separator: escape)
            + escape + Fake.privateKeyEnd() + escape + "\","
    }

    /// Column widths, in characters, at which the key's lines break between a backslash and its n and inside the END marker, as
    /// well as inside the header.
    private static let narrowColumns = [30, 36, 41, 45, 48]

    @Test(.needsVisionTextRecognition, arguments: narrowColumns)
    func aKeyOnOneLineWrappedInANarrowColumnIsOneFindingOverEveryLine(width: Int) async throws {
        let json = jsonKey
        let pieces = TextWrapping.chunks(of: json, width: width)
        // The wrap falls inside an escape and inside the END marker, not only between them.
        let characters = Array(json)
        let breaks = Array(stride(from: width, to: characters.count, by: width))
        let marker = try #require(json.range(of: Fake.privateKeyEnd()))
        let (markerStart, markerEnd) = (json.distance(from: json.startIndex, to: marker.lowerBound), json.distance(from: json.startIndex, to: marker.upperBound))
        #expect(breaks.contains { characters[$0 - 1] == "\\" && characters[$0] == "n" }, "no break inside an escape at \(width)")
        #expect(breaks.contains { markerStart < $0 && $0 < markerEnd }, "no break inside the END marker at \(width)")
        let lastKeyPiece = (markerEnd - 1) / width

        let page = ScanFixture(width: 1000, height: 70 + 46 * (pieces.count + 2))
        let drawn = pieces.enumerated().map { page.text($1, x: 40, top: CGFloat(30 + 46 * $0), size: 26) }
        let prose = page.text("Some prose under the key follows right here.", x: 40, top: CGFloat(30 + 46 * (pieces.count + 1)), size: 26)

        let found = try await SensitiveScanner.scan(page.image(), kinds: .all)

        #expect(found.count == 1 && found.first?.kind == .keyOrToken, "width \(width): \(found)")
        guard let finding = found.first else { return }
        let tolerance = tolerance(1)
        for index in 0...lastKeyPiece {
            let line = drawn[index].rect.insetBy(dx: 0, dy: 6)
            #expect(finding.rect.minY <= line.minY && finding.rect.maxY >= line.maxY, "width \(width): line \(index) \(pieces[index])")
            // The header's own line starts at the header; every other line is taken whole.
            if index > 1 { #expect(finding.rect.minX <= line.minX + tolerance && finding.rect.maxX >= line.maxX - tolerance, "width \(width): line \(index)") }
        }
        // Not the prose under the key.
        #expect(finding.rect.maxY < prose.rect.minY, "width \(width)")
    }

    // MARK: Large images

    @Test(.needsVisionTextRecognition) func findingsAtATileSeamOfATallImageAreNotDuplicated() async throws {
        // A 1 400 × 5 000 capture is read in three rows of tiles, the first cut at about 1 666: the two rows overlap by 160 px
        // from 1 586, and a line in that stretch is read by both.
        let page = ScanFixture(width: 1400, height: 5000)
        #expect(OCRTiling.needsTiling(width: page.width, height: page.height))
        let mail = page.text("mail me at \(email)", x: 40, top: 1560, size: 28)
        let key = page.text("paste \(token) here", x: 40, top: 1650, size: 28)
        let pay = page.text("card \(card)", x: 40, top: 1740, size: 28)

        let found = try await SensitiveScanner.scan(page.image(), kinds: .all)

        #expect(found.map(\.kind) == [.contact, .keyOrToken, .card], "\(found)")
        guard found.count == 3 else { return }
        expect(found[0], covers: mail.rect(of: email), in: page, tolerance: tolerance(1))
        expect(found[1], covers: key.rect(of: token), in: page, tolerance: tolerance(1))
        expect(found[2], covers: pay.rect(of: card), in: page, tolerance: tolerance(1))
    }

    @Test(.needsVisionTextRecognition) func aPrivateKeyAcrossATileSeamIsOneFinding() async throws {
        let page = ScanFixture(width: 1400, height: 5000)
        #expect(OCRTiling.needsTiling(width: page.width, height: page.height))
        // Header above the seam, the END line below it, the lines in the overlap read by both rows of tiles.
        let key = drawKey(on: page, top: 1500, spacing: 50)

        let found = try await SensitiveScanner.scan(page.image(), kinds: .all)

        #expect(found.count == 1 && found.first?.kind == .keyOrToken, "\(found)")
        guard let finding = found.first else { return }
        let whole = union(key)
        #expect(finding.rect.minY <= whole.minY + tolerance(1) && finding.rect.maxY >= whole.maxY - tolerance(1), "\(finding.rect) for \(whole)")
        #expect(finding.rect.height <= whole.height + 2 * tolerance(1))
    }

    @Test(.needsVisionTextRecognition) func aTokenAcrossAColumnCutIsOneFindingOverAllOfIt() async throws {
        // A 3 300 × 300 capture is cut into three columns at about 1 100 and 2 200, through the emptiest column nearby. The
        // token, 1 300 px wide in 56 px type, runs through the first cut, and neither tile reads more than part of it.
        let page = ScanFixture(width: 3300, height: 300)
        #expect(OCRTiling.needsTiling(width: page.width, height: page.height))
        let key = page.text("paste \(token) here", x: 40, top: 100, size: 56)
        let wholeToken = key.rect(of: token)
        #expect(wholeToken.minX < 900 && wholeToken.maxX > 1300)

        let found = try await SensitiveScanner.scan(page.image(), kinds: .all)

        #expect(found.map(\.kind) == [.keyOrToken], "\(found)")
        guard let finding = found.first else { return }
        // All of the token, and not much besides: read again on its own, it is boxed as exactly as any other.
        expect(finding, covers: wholeToken, in: page, tolerance: tolerance(2))
    }

    @Test(.needsVisionTextRecognition) func aTokenRepeatedOnNeighbouringLinesAcrossACutIsBoxedOnEachLine() async throws {
        // The part of the image read again for one line takes in parts of the lines above and below it, and the same token, aligned
        // in a column, is on each: each line's finding must take its own line's box.
        let page = ScanFixture(width: 3300, height: 360)
        #expect(OCRTiling.needsTiling(width: page.width, height: page.height))
        let lines = (0..<3).map { page.text("paste \(token) here", x: 40, top: CGFloat(30 + 100 * $0), size: 56) }

        let found = try await SensitiveScanner.scan(page.image(), kinds: .all)

        #expect(found.map(\.kind) == [.keyOrToken, .keyOrToken, .keyOrToken], "\(found)")
        guard found.count == 3 else { return }
        for (finding, line) in zip(found, lines) {
            expect(finding, covers: line.rect(of: token), in: page, tolerance: tolerance(2), "line at \(line.top)")
            // On its own line: it doesn't reach the next one's.
            #expect(finding.rect.minY >= line.top - 20 && finding.rect.maxY <= line.top + line.rect.height + 20, "\(finding.rect) for the line at \(line.top)")
        }
    }

    // MARK: Cancelling

    @Test func aScanOfACancelledTaskThrowsBeforeReadingAnything() async throws {
        // No recognition is run: the task is cancelled before the scan starts, so it runs where Vision can't too.
        let image = ScanFixture(width: 900, height: 300).image()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await SensitiveScanner.scan(image, kinds: .all)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.needsVisionTextRecognition) func cancellingAScanOfALargeImageStopsItBetweenTiles() async throws {
        // 15 tiles of dense text, each taking a good part of a second to read.
        let page = ScanFixture(width: 6720, height: 3780)
        for column in 0..<6 {
            for row in 0..<31 {
                page.text("Entry \(column * 31 + row) of sample words", x: CGFloat(60 + 1100 * column), top: CGFloat(80 + 120 * row), size: 26)
            }
        }
        let image = page.image()
        let task = Task { try await SensitiveScanner.scan(image, kinds: .all) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
