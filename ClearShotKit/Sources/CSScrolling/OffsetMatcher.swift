/// How the content moved from the reference to a new frame, along one axis.
enum Movement: Sendable, Equatable {
    /// Every line is the same.
    case identical
    /// At least 80% of the lines are unchanged in place (or, by pieces, only a small part changed in place): something
    /// changed inside the region, nothing scrolled.
    case animation
    /// A verified offset: positive, scrolled down or right by that many lines; 0, still; negative, scrolled back.
    case moved(Int)
    /// No offset fits well enough to trust, or several do and nothing tells them apart.
    case noMatch
}

/// Finds how far the content moved between two frames, and gives a movement only when the answer is unambiguous. An
/// offset `o` (positive: the content moved toward the start, i.e. scrolled down or right) pairs current line `r` with
/// previous line `r + o`.
///
/// **Every offset in the search range (up to `maximumOffsetFraction` of the band either way) that verifies is
/// collected:** by whole lines (at least `matchThreshold` of the pairs that aren't both blank equal, with at least
/// `minimumDistinctiveLines` different equal lines), and by pieces of lines (`PieceMatcher.verify`, tried on every
/// offset `PieceMatcher.possible` can't rule out). Offsets next to each other count as one. Then:
/// - **one verifies:** it is the movement. Within `previousReach` of the previous movement (a steady scroll) Vision
///   isn't asked; otherwise it is, and when only pieces verify the offset, an estimate that falls nowhere near
///   (beyond ± 2 of) it makes it a no-match: an alias of what the frames can't show. Whole lines that verify it are
///   taken whatever Vision says (exact line matching is the verifier, Vision only proposes), unless they are sparse
///   (`WholeLineEvidence.isSparse`, what one repeated element and whitespace can give): then only with Vision agreeing;
/// - **a scroll back by sparse whole lines** is a no-match, however it was settled: the stitch never follows it;
/// - **several do:** the one Vision's estimate (asked then) falls within ± 2 of; without one that falls by exactly one,
///   the one the pieces that tell them apart favour (`favoured`: discriminating evidence, with no line that either
///   pairs speaking for another); else a no-match;
/// - **none does:** an animation when, by pieces, only a small part changed in place (`PieceMatcher.standsStill`),
///   else a no-match.
struct OffsetMatcher: Sendable {
    /// Lines unchanged in place, as a fraction of the frame, from which a change is an animation, not a scroll.
    static let animationFraction = 0.8
    /// How far from an offset that verifies Vision's estimate may fall to pick it.
    static let candidateReach = 2
    /// The most offsets that verify the pieces that tell them apart are weighed for (each against each); more go
    /// straight to Vision.
    static let maximumWeighed = 16
    /// A match by whole lines rests on little (`WholeLineEvidence.isSparse`) with fewer different equal lines than
    /// this, or equal lines under this share of the lines it pairs. Measured: plain text never comes under 66 lines or
    /// 0.39; one 40-row banner and whitespace is 40 lines at 0.09–0.27.
    static let sparseDistinct = 64
    static let sparseShare = 0.25

    /// How far around the previous movement a lone answer is taken without asking Vision: half the movement, at least 8.
    static func previousReach(_ previous: Int) -> Int {
        max(8, abs(previous) / 2)
    }

    let matchThreshold: Double
    let minimumDistinctiveLines: Int
    let maximumOffsetFraction: Double
    let pieces: PieceMatcher

    init(configuration: StitchConfiguration) {
        matchThreshold = configuration.matchThreshold
        minimumDistinctiveLines = configuration.minimumDistinctiveLines
        maximumOffsetFraction = configuration.maximumOffsetFraction
        pieces = PieceMatcher(configuration: configuration)
    }

    /// How a movement was settled.
    enum Decision: Sendable, Equatable {
        /// The only offset that verifies.
        case unique
        /// One of several, favoured by the pieces that tell them apart.
        case evidence
        /// One of several, picked by Vision's estimate.
        case estimate
    }

    struct Comparison: Sendable, Equatable {
        var movement: Movement
        /// Leading lines equal at the same position in both frames.
        var top: Int
        /// Trailing lines equal at the same position in both frames (none of them counted in `top`).
        var bottom: Int
        /// Vision's candidate, when it was asked (for the log).
        var estimate: Int?
        /// How the pieces verified the movement, when whole lines didn't.
        var byPieces: PieceMatcher.Match?
        /// An animation because no offset verifies and, by pieces, only a small part changed in place.
        var stoodStill = false
        /// The offsets that verify (one of each group of neighbours) when several do; empty when one or none does.
        var verified: [Int] = []
        /// How a movement was settled.
        var decidedBy: Decision?
        /// A no-match because Vision's estimate, asked for, fell nowhere near the one offset that verifies, by pieces
        /// only; or because a match by whole lines rested on too little (`sparse`): that offset.
        var overruled: Int?
        /// What the overruled match by whole lines rested on: too little to move at a new pace without Vision agreeing,
        /// or to follow back.
        var sparse: WholeLineEvidence?
    }

    /// Compares `current` with `previous` (the reference's lines). Only lines between the unchanged leading and
    /// trailing ones are matched. `masked` gives the pieces without what stayed put since the frame before (for the
    /// pieces' evidence), and `estimate` gives Vision's candidate for that band; each is asked only when needed.
    func compare(_ previous: LineHashes, _ current: LineHashes, previousOffset: Int?,
                 masked: ((Range<Int>) -> (previous: LineHashes, current: LineHashes))? = nil,
                 estimate: (Range<Int>) -> Int?) -> Comparison {
        precondition(previous.count == current.count, "frames of different sizes can't be matched")
        let count = current.count
        var top = 0
        while top < count, previous.hashes[top] == current.hashes[top] { top += 1 }
        guard top < count else { return Comparison(movement: .identical, top: count, bottom: 0) }
        var bottom = 0
        while bottom < count - top, previous.hashes[count - 1 - bottom] == current.hashes[count - 1 - bottom] { bottom += 1 }
        guard Double(top + bottom) < Self.animationFraction * Double(count) else {
            return Comparison(movement: .animation, top: top, bottom: bottom)
        }
        let band = top..<(count - bottom)
        let limit = Int(maximumOffsetFraction * Double(band.count))
        // Every offset that verifies by whole lines, then by pieces: those the pieces can't rule out, past the ones
        // whole lines verify (and their neighbours).
        let byLines = verifiedByLines(previous, current, in: band, limit: limit)
        let pair = PieceMatcher.Pieces(previous: previous, current: current)
        lazy var maskedPair = PieceMatcher.Pieces(previous: previous, current: current, masked: masked?(band))
        var byPieces: [PieceMatcher.Match] = []
        // More offsets could verify by pieces than can be weighed: the frame is ambiguous, whatever else verifies.
        var tooMany = false
        if pair.isUsable {
            if let possible = pieces.possible(pair, in: band) {
                for offset in possible where !byLines.contains(where: { abs($0.offset - offset) <= 1 }) {
                    if let match = pieces.verify(maskedPair, in: band, at: offset) { byPieces.append(match) }
                }
            } else {
                tooMany = true
            }
        }
        /// The offset of a group of neighbours to take: the best by whole lines, else the best supported by pieces.
        func representative(_ group: [Int]) -> Int {
            if let line = byLines.filter({ group.contains($0.offset) }).max(by: { $0.score < $1.score }) {
                return line.offset
            }
            return byPieces.filter { group.contains($0.offset) }.max { $0.support < $1.support }?.offset ?? group[0]
        }
        let groups = Self.clusters(byLines.map(\.offset) + byPieces.map(\.offset))
        let representatives = groups.map(representative)
        let verifiedSeveral = { representatives.count > 1 ? representatives : [] }
        func moved(_ offset: Int, _ decision: Decision, estimate: Int?) -> Comparison {
            let byWholeLines = byLines.contains(where: { $0.offset == offset })
            if offset < 0, byWholeLines {
                // A scroll back is followed: never on what one repeated element and whitespace can give.
                let evidence = Self.wholeLineEvidence(previous, current, in: band, at: offset)
                if evidence.isSparse {
                    return Comparison(movement: .noMatch, top: top, bottom: bottom, estimate: estimate,
                                      verified: verifiedSeveral(), overruled: offset, sparse: evidence)
                }
            }
            let match = byWholeLines ? nil : byPieces.first(where: { $0.offset == offset })
            return Comparison(movement: .moved(offset), top: top, bottom: bottom, estimate: estimate, byPieces: match,
                              verified: verifiedSeveral(), decidedBy: decision)
        }
        if !tooMany {
            switch representatives.count {
            case 0:
                if pair.isUsable, pieces.standsStill(pair, in: band) {
                    return Comparison(movement: .animation, top: top, bottom: bottom, stoodStill: true)
                }
                return Comparison(movement: .noMatch, top: top, bottom: bottom)
            case 1:
                let offset = representatives[0]
                let steady = previousOffset.map { abs(offset - $0) <= Self.previousReach($0) } ?? false
                guard !steady else { return moved(offset, .unique, estimate: nil) }
                // Not the pace before: Vision is asked. When only pieces verify the offset, an estimate that falls
                // nowhere near it says it is an alias of something the frames can't show. Whole lines that verify it
                // are the verifier itself, Vision only proposes; unless they rest on what one repeated element and
                // whitespace can give, which moves only with Vision agreeing.
                let estimated = estimate(band)
                let agrees = estimated.map { estimated in groups[0].contains { abs($0 - estimated) <= Self.candidateReach } }
                if byLines.contains(where: { groups[0].contains($0.offset) }) {
                    let evidence = Self.wholeLineEvidence(previous, current, in: band, at: offset)
                    if evidence.isSparse, agrees != true {
                        return Comparison(movement: .noMatch, top: top, bottom: bottom, estimate: estimated,
                                          overruled: offset, sparse: evidence)
                    }
                } else if agrees == false {
                    return Comparison(movement: .noMatch, top: top, bottom: bottom, estimate: estimated,
                                      overruled: offset)
                }
                return moved(offset, .unique, estimate: estimated)
            default:
                break
            }
        }
        // Several verify: Vision's estimate first, when it falls by exactly one of them.
        let estimated = estimate(band)
        if let estimated {
            var near: [Int]
            if tooMany {
                // Not every offset could be weighed: only those by the estimate are tried.
                var found: [Int] = []
                for offset in (estimated - Self.candidateReach)...(estimated + Self.candidateReach) where abs(offset) <= limit {
                    if byLines.contains(where: { $0.offset == offset }) {
                        found.append(offset)
                    } else if offset != 0, let match = pieces.verify(maskedPair, in: band, at: offset) {
                        byPieces.append(match)
                        found.append(offset)
                    }
                }
                near = Self.clusters(found).map(representative)
            } else {
                near = zip(groups, representatives).filter { group, _ in
                    group.contains { abs($0 - estimated) <= Self.candidateReach }
                }.map(\.1)
            }
            if near.count == 1 { return moved(near[0], .estimate, estimate: estimated) }
        }
        // No usable estimate: the one the pieces that tell them apart favour, the others' evidence weighed over every line
        // they pair.
        if !tooMany {
            let keys = pair.isUsable ? (previous.pieceKeys, current.pieceKeys) : (previous.matchKeys, current.matchKeys)
            if let favoured = Self.favoured(representatives, keys: keys, perLine: pair.isUsable ? current.pieceCount : 1,
                                            count: count, in: band, distinctLines: minimumDistinctiveLines) {
                return moved(favoured, .evidence, estimate: estimated)
            }
        }
        return Comparison(movement: .noMatch, top: top, bottom: bottom, estimate: estimated, verified: representatives)
    }

    /// What a match by whole lines rests on.
    struct WholeLineEvidence: Sendable, Equatable {
        /// The lines it pairs that are equal and not blank, and how many of them are different.
        var equal: Int
        var distinct: Int
        /// The lines it pairs, but those paired with a line that isn't blank and is equal in place at the frame's ends
        /// (a sticky header or footer, which can't be compared): blank margins count, as the whitespace they are.
        var open: Int

        /// Fewer than `sparseDistinct` different equal lines, or equal lines under `sparseShare` of `open`: what one
        /// repeated element and whitespace can give.
        var isSparse: Bool {
            distinct < OffsetMatcher.sparseDistinct || Double(equal) < OffsetMatcher.sparseShare * Double(open)
        }
    }

    /// What the match by whole lines at `offset` rests on, within `band`.
    static func wholeLineEvidence(_ previous: LineHashes, _ current: LineHashes, in band: Range<Int>,
                                  at offset: Int) -> WholeLineEvidence {
        let previousKeys = previous.matchKeys
        let currentKeys = current.matchKeys
        let count = current.count
        var equal = 0
        var distinct = Set<UInt64>()
        for line in max(band.lowerBound, band.lowerBound - offset)..<min(band.upperBound, band.upperBound - offset)
        where currentKeys[line] != 0 && currentKeys[line] == previousKeys[line + offset] {
            equal += 1
            distinct.insert(currentKeys[line])
        }
        var open = 0
        for line in max(0, -offset)..<min(count, count - offset) {
            let stuck = (!band.contains(line) && currentKeys[line] != 0)
                || (!band.contains(line + offset) && previousKeys[line + offset] != 0)
            if !stuck { open += 1 }
        }
        return WholeLineEvidence(equal: equal, distinct: distinct.count, open: open)
    }

    /// Every offset within `limit` either way that verifies by whole lines, with its score.
    func verifiedByLines(_ previous: LineHashes, _ current: LineHashes, in band: Range<Int>,
                         limit: Int) -> [(offset: Int, score: Double)] {
        let previousKeys = previous.matchKeys
        let currentKeys = current.matchKeys
        return previousKeys.withUnsafeBufferPointer { previousKeys in
            currentKeys.withUnsafeBufferPointer { currentKeys in
                let scorer = Scorer(previous: previousKeys, current: currentKeys, band: band, threshold: matchThreshold,
                                    distinctLines: minimumDistinctiveLines)
                return (-limit...limit).compactMap { offset in scorer.score(offset).map { (offset, $0) } }
            }
        }
    }

    /// `offsets` sorted, in groups of neighbours (each within 1 of the next).
    static func clusters(_ offsets: [Int]) -> [[Int]] {
        var groups: [[Int]] = []
        for offset in offsets.sorted() {
            if let last = groups.last?.last, offset - last <= 1 {
                groups[groups.count - 1].append(offset)
            } else {
                groups.append([offset])
            }
        }
        return groups
    }

    /// Of `offsets`, the one the pieces that tell them apart favour, or nil: against each other one, at least
    /// `distinctLines` of the lines both pair speak for it, and not one line either pairs speaks for the other. So the
    /// other's evidence is weighed over every line it pairs, never only those both pair: a wrong winner always meets
    /// the truth's. Its own is weighed only where both pair: pairing more lines of repeating content isn't evidence. A
    /// line speaks for `a` over `b` where a piece that didn't stay put matches at `a` and not at `b` (another piece, or
    /// none), or where a blank piece is paired at `b` with reference content that didn't stay put and isn't at `a`.
    /// Pieces equal in place say nothing. `keys` are the previous and current frames' pieces, `perLine` of them a line
    /// (`p × count + r`; the lines' own keys when `perLine` is 1). Nil too for more than `maximumWeighed` offsets.
    static func favoured(_ offsets: [Int], keys: (previous: [UInt64], current: [UInt64]), perLine: Int, count: Int,
                         in band: Range<Int>, distinctLines: Int) -> Int? {
        guard offsets.count <= maximumWeighed else { return nil }
        /// The lines both pair that speak for `a` over `b`, and the lines either pairs that speak for `b` over `a`.
        func apart(_ a: Int, _ b: Int) -> (a: Int, b: Int) {
            var onlyA = 0
            var onlyB = 0
            for line in band {
                let pairsA = band.contains(line + a)
                let pairsB = band.contains(line + b)
                guard pairsA || pairsB else { continue }
                var lineA = false
                var lineB = false
                for piece in 0..<perLine {
                    let index = piece * count + line
                    let key = keys.current[index]
                    if key != 0 {
                        guard key != keys.previous[index] else { continue }
                        let atA = pairsA && key == keys.previous[index + a]
                        let atB = pairsB && key == keys.previous[index + b]
                        if atA && !atB { lineA = true }
                        if atB && !atA { lineB = true }
                    } else {
                        // Blank here: the reference's content an offset pairs with it says that offset is wrong.
                        let againstA = pairsA && PieceMatcher.moved(keys.previous, keys.current, index + a)
                        let againstB = pairsB && PieceMatcher.moved(keys.previous, keys.current, index + b)
                        if againstB && !againstA { lineA = true }
                        if againstA && !againstB { lineB = true }
                    }
                }
                if lineA, pairsA, pairsB { onlyA += 1 }
                if lineB { onlyB += 1 }
            }
            return (onlyA, onlyB)
        }
        let winners = offsets.filter { candidate in
            offsets.allSatisfy { other in
                guard other != candidate else { return true }
                let (mine, theirs) = apart(candidate, other)
                return mine >= distinctLines && theirs == 0
            }
        }
        return winners.count == 1 ? winners[0] : nil
    }
}

/// Scores offsets over one pair of frames' match keys.
private struct Scorer {
    let previous: UnsafeBufferPointer<UInt64>
    let current: UnsafeBufferPointer<UInt64>
    let band: Range<Int>
    let threshold: Double
    let distinctLines: Int

    /// The share of equal pairs at `offset`, or nil when it doesn't match: below the threshold, or fewer distinct
    /// equal lines than required. Gives up as soon as the mismatches rule the threshold out.
    func score(_ offset: Int) -> Double? {
        let lower = max(band.lowerBound, band.lowerBound - offset)
        let upper = min(band.upperBound, band.upperBound - offset)
        let pairs = upper - lower
        guard pairs >= distinctLines else { return nil }
        // Equal pairs ÷ compared pairs ≥ threshold needs mismatches ≤ (1 − threshold) × compared ≤ (1 − threshold) × pairs.
        let allowedMismatches = Int(((1 - threshold) * Double(pairs) + 1e-9).rounded(.down))
        var equal = 0
        var mismatches = 0
        for line in lower..<upper {
            let a = current[line]
            let b = previous[line + offset]
            if a != b {
                mismatches += 1
                if mismatches > allowedMismatches { return nil }
            } else if a != 0 {
                equal += 1
            }
        }
        let compared = equal + mismatches
        guard compared > 0 else { return nil }
        let score = Double(equal) / Double(compared)
        guard score >= threshold else { return nil }
        var distinct = Set<UInt64>()
        for line in lower..<upper where current[line] != 0 && current[line] == previous[line + offset] {
            distinct.insert(current[line])
            if distinct.count >= distinctLines { return score }
        }
        return nil
    }
}
