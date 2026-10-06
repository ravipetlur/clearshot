/// Matching by pieces of lines, for when whole lines don't settle a frame. Content that doesn't scroll with the page, a
/// sidebar that sticks, a floating button or a chat bubble, spoils every whole line it crosses, but only the pieces it
/// covers, so each line is also hashed in pieces across it (`LineHashes.pieceKeys`). An offset `d` pairs piece `p` of
/// current line `r` with piece `p` of previous line `r + d`.
///
/// **Each piece of the current frame is classified per pair:**
/// - **static** when it is equal in place (offset 0); a static piece that also matches at `d` is periodic and
///   **neutral**, one that doesn't is **fixed** content;
/// - otherwise it **supports** `d` when it matches at `d`, and **contradicts** it when it doesn't;
/// - a blank piece paired with reference content that didn't stay put also **contradicts** `d`: `d` says
///   that content is here, and it isn't. Other blank pieces count for nothing.
///
/// **`d` verifies (`verify`) only when all of these hold:**
/// - (a) the support covers at least `distinctLines` lines, each bringing a matching piece not seen before;
/// - (b) every contradiction of a current piece lies in the shapes a floating element leaves: within at most two
///   intervals of lines, each at most `runLimit` lines (or one that is two such meeting, up to `runLimit` +
///   min(|`d`|, `runLimit`)); the lines between need not contradict, since an element shows only where what scrolls
///   under it differs. And the contradictions no fixed element explains span, within those intervals, at most a
///   quarter of the overlap's lines with content in either frame. A fixed element explains a
///   contradiction beside one of its pieces, equal in place, in the line or in the reference's line it is paired with:
///   the page under its edge, or the page it hid in the reference;
/// - (c) the support is a clear majority (`majority`) of the content: of the supporting, contradicting and fixed
///   pieces, so a sidebar scrolled inside a still page (whose page is fixed) is never taken for a page move.
///
/// For (a) and (b) the pieces are hashed without the positions across the line unchanged in place since the frame just
/// before (`Pieces.masked`), so a piece where a sticky sidebar meets the page compares only the page; (c) counts every
/// piece, so the content that stayed put still weighs against a minority that moved.
///
/// Whether an offset is the answer is decided over every offset that verifies (`OffsetMatcher.compare`); `possible`
/// finds the offsets that could, by an exact count that never leaves one out. **Still** (`standsStill`) when nothing
/// verifies and what changed in place since the reference fits the shapes of (b): explained, like an animation.
struct PieceMatcher: Sendable {
    let distinctLines: Int
    let maximumOffsetFraction: Double
    /// The tallest floating element whose rows are tolerated, in lines.
    let runLimit: Int
    /// A piece repeated more often than this in the band is counted as supporting every offset (`possible`), and
    /// nominates none (`votes`).
    static let maximumRepeats = 64
    /// More offsets than this that could verify is too many to weigh: the frame is decided as ambiguous.
    static let maximumPossible = 256
    /// The share of the content (supporting, contradicting and fixed pieces) the support must reach: a clear majority,
    /// three to two, since half moving and half staying put could be either a page beside a sidebar or a sidebar beside
    /// a page.
    static let majority = 0.6

    init(configuration: StitchConfiguration) {
        distinctLines = configuration.minimumDistinctiveLines
        maximumOffsetFraction = configuration.maximumOffsetFraction
        runLimit = max(1, Int((configuration.floatingElementPoints * configuration.pixelsPerPoint).rounded()))
    }

    /// The pieces of a pair of frames, as hashed and with what stayed put since the frame before left out.
    struct Pieces {
        let previous: LineHashes
        let current: LineHashes
        let maskedPrevious: LineHashes
        let maskedCurrent: LineHashes

        init(previous: LineHashes, current: LineHashes,
             masked: (previous: LineHashes, current: LineHashes)? = nil) {
            self.previous = previous
            self.current = current
            maskedPrevious = masked?.previous ?? previous
            maskedCurrent = masked?.current ?? current
        }

        var isUsable: Bool {
            current.pieceCount > 0 && [previous, maskedPrevious, maskedCurrent].allSatisfy {
                $0.pieceCount == current.pieceCount && $0.count == current.count
            }
        }
    }

    /// A verified offset by pieces, and the evidence for it.
    struct Match: Sendable, Equatable {
        var offset: Int
        /// Pieces not equal in place that match at the offset, and that match at neither 0 nor it.
        var support: Int
        var contradictions: Int
        /// Pieces equal in place that don't match at the offset (content that stayed put), and that do (periodic).
        var fixed: Int
        var neutral: Int
        /// Current-frame lines holding the contradictions (a floating element's rows, in each frame).
        var forgivenRuns: [Range<Int>]
    }

    /// The offsets (not 0) whose support could meet (a) and (c): the count of moving pieces matching at each, never
    /// below the true one (a piece repeated more than `maximumRepeats` times counted as matching at every offset),
    /// against the least the content can be there (the pieces in the overlap but the static ones). It never leaves out
    /// an offset that would verify. Nil when more than `maximumPossible` could.
    func possible(_ pieces: Pieces, in band: Range<Int>) -> [Int]? {
        guard pieces.isUsable, band.count >= distinctLines else { return [] }
        let limit = Int(maximumOffsetFraction * Double(band.count))
        let count = pieces.current.count
        let pieceCount = pieces.current.pieceCount
        let current = pieces.current.pieceKeys
        let previous = pieces.previous.pieceKeys
        // Per line in the band: its pieces that aren't blank, and those that are static.
        var content = [Int](repeating: 0, count: count + 1)
        var stayed = [Int](repeating: 0, count: count + 1)
        var linesByKey: [UInt64: [Int]] = [:]
        linesByKey.reserveCapacity(pieceCount * band.count)
        for line in 0..<count {
            var lineContent = 0
            var lineStayed = 0
            if band.contains(line) {
                for piece in 0..<pieceCount {
                    let index = piece * count + line
                    if current[index] != 0 {
                        lineContent += 1
                        if current[index] == previous[index] { lineStayed += 1 }
                    }
                    if previous[index] != 0 {
                        linesByKey[Self.salted(previous[index], piece), default: []].append(line)
                    }
                }
            }
            content[line + 1] = content[line] + lineContent
            stayed[line + 1] = stayed[line] + lineStayed
        }
        var tally = [Int](repeating: 0, count: 2 * limit + 1)
        var everywhere = 0
        for piece in 0..<pieceCount {
            for line in band {
                let index = piece * count + line
                let key = current[index]
                guard key != 0, key != previous[index], let matches = linesByKey[Self.salted(key, piece)] else { continue }
                guard matches.count <= Self.maximumRepeats else {
                    everywhere += 1
                    continue
                }
                for match in matches where abs(match - line) <= limit {
                    tally[match - line + limit] += 1
                }
            }
        }
        var offsets: [Int] = []
        for offset in -limit...limit where offset != 0 {
            let support = tally[offset + limit] + everywhere
            // (a) needs `distinctLines` moving pieces that support or contradict, and (c) the support to be at least
            // `majority` of them: so at least `majority` × `distinctLines` supporting.
            guard Double(support) >= Self.majority * Double(distinctLines) else { continue }
            let lower = max(band.lowerBound, band.lowerBound - offset)
            let upper = min(band.upperBound, band.upperBound - offset)
            guard upper > lower else { continue }
            let least = (content[upper] - content[lower]) - (stayed[upper] - stayed[lower])
            guard Double(support) >= Self.majority * Double(least) else { continue }
            offsets.append(offset)
            if offsets.count > Self.maximumPossible { return nil }
        }
        return offsets
    }

    /// A piece's key, told apart by its column (so one table holds every column).
    private static func salted(_ key: UInt64, _ piece: Int) -> UInt64 {
        key ^ (UInt64(piece + 1) &* 0x9E37_79B9_7F4A_7C15)
    }

    /// The pieces' decision on their own, for lines compared as hashed: every offset that verifies; one, or of several
    /// the one of `candidates` (each ± 2) falls by, or else the one the pieces that tell them apart favour
    /// (`OffsetMatcher.favoured`). Nil otherwise.
    func match(from previous: LineHashes, to current: LineHashes, in band: Range<Int>, candidates: [Int]) -> Match? {
        let pieces = Pieces(previous: previous, current: current)
        guard let possible = possible(pieces, in: band) else { return nil }
        let verified = possible.compactMap { verify(pieces, in: band, at: $0) }
        let clusters = OffsetMatcher.clusters(verified.map(\.offset))
        let near = clusters.filter { cluster in candidates.contains { candidate in cluster.contains { abs($0 - candidate) <= 2 } } }
        let chosen: Int?
        if clusters.count == 1 {
            chosen = clusters[0].first
        } else if near.count == 1 {
            chosen = near[0].first
        } else {
            chosen = OffsetMatcher.favoured(clusters.map { $0[0] }, keys: (previous.pieceKeys, current.pieceKeys),
                                            perLine: current.pieceCount, count: current.count, in: band,
                                            distinctLines: distinctLines)
        }
        return chosen.flatMap { offset in verified.first { $0.offset == offset } }
    }

    /// For the log: offsets by how many moving pieces nominate them, the most first.
    func votes(from previous: LineHashes, to current: LineHashes, in band: Range<Int>) -> [(offset: Int, votes: Int)] {
        let pieces = Pieces(previous: previous, current: current)
        guard pieces.isUsable else { return [] }
        return nominated(pieces, in: band, limit: Int(maximumOffsetFraction * Double(band.count)))
    }

    // MARK: Private

    /// Offsets by how many moving pieces (the masked ones not equal in place) find an equal piece there, the most
    /// first (then the smallest movement, then forward). Only nominations, for the log.
    private func nominated(_ pieces: Pieces, in band: Range<Int>, limit: Int) -> [(offset: Int, votes: Int)] {
        let previous = pieces.maskedPrevious.pieceKeys
        let current = pieces.maskedCurrent.pieceKeys
        let count = pieces.current.count
        var votes: [Int: Int] = [:]
        for piece in 0..<pieces.current.pieceCount {
            let base = piece * count
            var linesByKey: [UInt64: [Int]] = [:]
            for line in band where previous[base + line] != 0 && previous[base + line] != current[base + line] {
                linesByKey[previous[base + line], default: []].append(line)
            }
            for line in band where current[base + line] != 0 && current[base + line] != previous[base + line] {
                guard let matches = linesByKey[current[base + line]], matches.count <= Self.maximumRepeats else {
                    continue
                }
                for match in matches where abs(match - line) <= limit {
                    votes[match - line, default: 0] += 1
                }
            }
        }
        return votes.map { (offset: $0.key, votes: $0.value) }
            .sorted { ($0.votes, -abs($0.offset), $0.offset) > ($1.votes, -abs($1.offset), $1.offset) }
    }

    /// The match at `offset` when (a)–(c) hold, else nil.
    func verify(_ pieces: Pieces, in band: Range<Int>, at offset: Int) -> Match? {
        let lower = max(band.lowerBound, band.lowerBound - offset)
        let upper = min(band.upperBound, band.upperBound - offset)
        guard upper - lower >= distinctLines else { return nil }
        let count = pieces.current.count
        let pieceCount = pieces.current.pieceCount
        let previous = pieces.previous.pieceKeys
        let current = pieces.current.pieceKeys
        let maskedPrevious = pieces.maskedPrevious.pieceKeys
        let maskedCurrent = pieces.maskedCurrent.pieceKeys
        var support = 0
        var contradictions = 0
        var fixed = 0
        var neutral = 0
        var seen = Set<UInt64>()
        var distinct = 0
        var contradicted: [Int] = []
        // The overlap's lines with something on them in either frame, and those with a contradiction no fixed element
        // explains: the second span a quarter of the first at most (b).
        var contentLines = 0
        var unexplained: [Int] = []
        // Per line, the masked pieces equal in place, as bits: a fixed element's (the paper is blank).
        var stayed = [UInt32](repeating: 0, count: count)
        for line in band {
            var bits: UInt32 = 0
            for piece in 0..<pieceCount {
                let key = maskedCurrent[piece * count + line]
                if key != 0, key == maskedPrevious[piece * count + line] { bits |= 1 << UInt32(piece) }
            }
            stayed[line] = bits
        }
        for line in lower..<upper {
            var lineContradicted = false
            var lineUnexplained = false
            var lineHasContent = false
            var bringsNew = false
            // A fixed element in this line, or in the reference's line it is paired with.
            let besideFixed = stayed[line] | stayed[line + offset]
            for piece in 0..<pieceCount {
                let index = piece * count + line
                let partner = index + offset
                // Every piece, for the majority (c).
                let key = current[index]
                if key != 0 {
                    let inPlace = key == previous[index]
                    let atOffset = key == previous[partner]
                    switch (inPlace, atOffset) {
                    case (true, true): neutral += 1
                    case (true, false): fixed += 1
                    case (false, true): support += 1
                    case (false, false): contradictions += 1
                    }
                } else if Self.moved(previous, current, partner) {
                    // Reference content that didn't stay put, paired with blank: the offset says it is here, and it
                    // isn't.
                    contradictions += 1
                }
                // The masked pieces, for the evidence (a) and the shapes (b).
                let masked = maskedCurrent[index]
                if masked != 0 || maskedPrevious[partner] != 0 { lineHasContent = true }
                guard masked != 0, masked != maskedPrevious[index] else { continue }
                if masked == maskedPrevious[partner] {
                    if distinct < distinctLines, seen.insert(masked).inserted { bringsNew = true }
                } else {
                    lineContradicted = true
                    // Beside a piece of a fixed element, in either frame: the page under its edge, or the page it hid
                    // in the reference.
                    if besideFixed & ((UInt32(0b111) << UInt32(piece)) >> 1) == 0 { lineUnexplained = true }
                }
            }
            if bringsNew { distinct += 1 }
            if lineContradicted { contradicted.append(line) }
            if lineUnexplained { unexplained.append(line) }
            if lineHasContent { contentLines += 1 }
        }
        guard distinct >= distinctLines,
              let runs = shapes(covering: contradicted, offset: offset),
              Self.span(of: unexplained, within: runs) <= contentLines / 4,
              Double(support) >= Self.majority * Double(support + contradictions + fixed)
        else { return nil }
        return Match(offset: offset, support: support, contradictions: contradictions, fixed: fixed, neutral: neutral,
                     forgivenRuns: runs)
    }

    /// How many lines `lines` (sorted) span, from the first to the last of them in each of `runs` (sorted, covering them).
    private static func span(of lines: [Int], within runs: [Range<Int>]) -> Int {
        runs.reduce(0) { total, run in
            guard let first = lines.first(where: { run.contains($0) }),
                  let last = lines.last(where: { run.contains($0) }) else { return total }
            return total + last - first + 1
        }
    }

    /// Whether the reference's piece at `index` is content that didn't stay put: not blank, and not equal in place in
    /// the current frame.
    static func moved(_ previous: [UInt64], _ current: [UInt64], _ index: Int) -> Bool {
        previous[index] != 0 && previous[index] != current[index]
    }

    /// The shapes floating elements leave, covering `lines` (sorted): at most two intervals, each at most `runLimit` lines
    /// (or one that is two such meeting, up to `runLimit` + min(|`offset`|, `runLimit`)), each from the first line it
    /// covers to the last. Nil when they can't cover them. Lines between covered ones need not be contradicted: a
    /// floating element shows only where what scrolls under it differs.
    private func shapes(covering lines: [Int], offset: Int) -> [Range<Int>]? {
        guard let first = lines.first, let last = lines.last else { return [] }
        if last - first + 1 <= runLimit + min(abs(offset), runLimit) { return [first..<(last + 1)] }
        // Two: the first from `first` as far as `runLimit` reaches (the greedy cover, the fewest intervals), the second
        // the rest.
        let split = lines.firstIndex { $0 >= first + runLimit } ?? lines.count
        guard split > 0, split < lines.count else { return nil }
        let trailing = lines[split]..<(last + 1)
        guard trailing.count <= runLimit else { return nil }
        return [first..<(lines[split - 1] + 1), trailing]
    }

    /// Whether only the tolerated shapes changed in place since the reference: the lines with a piece not equal in place,
    /// a quarter of the lines with something on them at most.
    func standsStill(_ pieces: Pieces, in band: Range<Int>) -> Bool {
        // Against the reference as hashed: what the masked pieces leave out stayed put since the frame just before,
        // which says nothing about whether the page moved since the reference.
        let count = pieces.current.count
        let previous = pieces.previous.pieceKeys
        let current = pieces.current.pieceKeys
        var comparedLines = 0
        var changedLines: [Int] = []
        for line in band {
            var stayed = false
            var changed = false
            for piece in 0..<pieces.current.pieceCount {
                let index = piece * count + line
                guard current[index] != 0 || previous[index] != 0 else { continue }
                if current[index] == previous[index] { stayed = true } else { changed = true }
            }
            if stayed || changed { comparedLines += 1 }
            if changed { changedLines.append(line) }
        }
        guard let runs = shapes(covering: changedLines, offset: 0) else { return false }
        return runs.reduce(0) { $0 + $1.count } <= comparedLines / 4
    }
}
