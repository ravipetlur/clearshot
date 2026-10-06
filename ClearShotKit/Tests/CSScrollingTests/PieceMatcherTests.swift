import Testing
@testable import CSScrolling

/// The piece matching rule on lines made of hand-picked piece keys: 8 pieces a line, 400-line frames, a page of keys
/// that are all different, the current frame 50 lines further on. At 0.25 px a point the tallest floating element is
/// 80 pt × 0.25 = 20 lines.
struct PieceMatcherTests {
    let matcher = PieceMatcher(configuration: StitchConfiguration(pixelsPerPoint: 0.25))
    static let pieces = 8
    static let length = 400
    static let offset = 50

    /// The page's key for piece `piece` of page row `row`.
    private func key(_ piece: Int, _ row: Int, seed: UInt64 = 1) -> UInt64 {
        SyntheticPage.mix(seed &* 1_000_003 &+ UInt64(piece * 100_000 + row)) | 1
    }

    /// The frame showing page rows `top ..< top + length`, with `change` deciding a piece's key instead where it returns
    /// one (piece, frame line).
    private func frame(at top: Int, seed: UInt64 = 1, change: (Int, Int) -> UInt64? = { _, _ in nil }) -> LineHashes {
        LineHashes(pieces: (0..<Self.pieces).map { piece in
            (0..<Self.length).map { line in change(piece, line) ?? key(piece, top + line, seed: seed) }
        })
    }

    private var previous: LineHashes { frame(at: 0) }

    private func match(_ current: LineHashes, candidates: [Int] = []) -> PieceMatcher.Match? {
        matcher.match(from: previous, to: current, in: 0..<Self.length, candidates: candidates)
    }

    @Test func piecesEqualInPlaceAreLeftOut() throws {
        // Column 0 stays put in both frames (a sidebar): its pieces are the same keys at the same lines.
        let sidebar: (Int, Int) -> UInt64? = { piece, line in piece == 0 ? self.key(0, line, seed: 9) : nil }
        let previous = frame(at: 0, change: sidebar)
        let current = frame(at: Self.offset, change: sidebar)
        let found = try #require(matcher.match(from: previous, to: current, in: 0..<Self.length, candidates: []))
        #expect(found.offset == Self.offset && found.fixed > 0 && found.forgivenRuns.isEmpty)
    }

    @Test func twoShortRunsOfMismatchesAreForgiven() throws {
        // Every piece of lines 250–269 and 300–319 is something else (a floating element's rows in each frame): 320 of
        // about 2 800 pairs, more than a tenth, so only forgiving them lets the offset through.
        let current = frame(at: Self.offset) { piece, line in
            (250..<270).contains(line) || (300..<320).contains(line) ? self.key(piece, line, seed: 5) : nil
        }
        let found = try #require(match(current))
        #expect(found.offset == Self.offset && found.forgivenRuns == [250..<270, 300..<320])
    }

    @Test func aRunTallerThanTheBoundIsNotForgiven() {
        // One run may be 20 + min(50, 20) = 40 lines (a floating element whose rows in both frames merge).
        func changed(_ lines: Range<Int>) -> LineHashes {
            frame(at: Self.offset) { piece, line in lines.contains(line) ? self.key(piece, line, seed: 5) : nil }
        }
        #expect(match(changed(250..<290))?.forgivenRuns == [250..<290])
        #expect(match(changed(250..<291)) == nil)
    }

    @Test func aColumnThatDisagreesAlongTheOverlapIsNoMatch() {
        // A column of pieces that matches neither in place nor at the offset on any line is a contradiction everywhere,
        // beside something static (where a sidebar meets the page, as hashed) or not: no columns are set aside. (The
        // stitcher hashes such a pair's pieces without the pixels both frames have unchanged along the band, so a
        // sticky sidebar's edge compares only the page; see PageContentTests.)
        func sidebar(edge seed: UInt64) -> (Int, Int) -> UInt64? {
            { piece, line in
                switch piece {
                case 0: self.key(0, line, seed: 9)
                case 1: self.key(1, line, seed: seed)
                default: nil
                }
            }
        }
        let previous = frame(at: 0, change: sidebar(edge: 7))
        let current = frame(at: Self.offset, change: sidebar(edge: 8))
        #expect(matcher.match(from: previous, to: current, in: 0..<Self.length, candidates: []) == nil)
        let lone = frame(at: Self.offset) { piece, line in piece == 3 ? self.key(3, line, seed: 7) : nil }
        #expect(match(lone) == nil)
    }

    @Test func columnsCantBeSetAsideToLetAnAliasThrough() throws {
        // 16 pieces: 12 columns repeat every 40 lines, 4 are different on every line. The truth is 50; 90 is an alias
        // for the 12, and setting the 4 aside would have let it through.
        let pieces = 16
        func frame(at top: Int) -> LineHashes {
            LineHashes(pieces: (0..<pieces).map { piece in
                (0..<Self.length).map { line in piece < 12 ? self.key(piece, (top + line) % 40) : self.key(piece, top + line) }
            })
        }
        let found = try #require(matcher.match(from: frame(at: 0), to: frame(at: 50), in: 0..<Self.length, candidates: [90]))
        #expect(found.offset == 50 && found.contradictions == 0)
    }

    @Test func eightEqualPiecesOnOneLineAreNotEnough() {
        // All flat but one line, whose 8 pieces are all different: the evidence of one line, not of 8.
        func frame(line: Int) -> LineHashes {
            LineHashes(pieces: (0..<Self.pieces).map { piece in
                (0..<Self.length).map { $0 == line ? self.key(piece, 7) : 0 }
            })
        }
        #expect(matcher.match(from: frame(line: 150), to: frame(line: 100), in: 0..<Self.length, candidates: []) == nil)
    }

    @Test func aWrongOffsetIsRejected() throws {
        // The estimate says 55; the pieces there don't agree, and the truth (50) is found by its votes instead.
        let current = frame(at: Self.offset) { piece, line in
            (300..<320).contains(line) ? self.key(piece, line, seed: 5) : nil
        }
        #expect(try #require(match(current, candidates: [55])).offset == Self.offset)
        // Another page altogether, but for two short runs of lines it shares with this one 50 further on: nothing.
        let other = frame(at: Self.offset, seed: 2) { piece, line in
            (100..<120).contains(line) || (200..<220).contains(line) ? self.key(piece, Self.offset + line) : nil
        }
        #expect(match(other) == nil)
    }
}
