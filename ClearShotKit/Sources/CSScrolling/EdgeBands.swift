/// The sticky bands of an accepted pair of frames, generalised: the lines at the top and the bottom where some pieces
/// stayed put while the rest scrolled, so strips are taken from between them and the bottom band is drawn once, at the
/// end, as a sticky footer is. (Whole lines unchanged in place, a header or a footer, are the stitcher's own sticky
/// bands; these are the lines between them.)
///
/// A piece stayed put when it is equal in place in both frames (not flat) and the offset doesn't explain it (its partner
/// at the offset differs, or there is none). A floating button does, and so does a partial-width bar. Lines with such
/// pieces count in runs (gaps of up to `runGap` lines bridged: text passing through a piece hides the element there) of
/// at least `minimumRun` lines, so a piece equal by chance doesn't make a band. A band reaches from its edge to the
/// farthest run within `limit` lines of it, plus `pad` lines for an element's top rows hidden the same way.
///
/// A column of pieces that stays put in the middle of the frame, or along half of it or more, is a fixture (a sidebar
/// that sticks), not an element near an edge: it is left out with its neighbours (the piece where a fixture meets the
/// page holds both). A band can't take a fixture out of the strips:
/// a known limit, such a sidebar's slice repeats in each strip. An element that has just appeared isn't in place in the
/// frame before, so its first frame draws it where it is (a known limit); from the next frame on it is a band.
enum EdgeBands {
    static let runGap = 12
    static let minimumRun = 8
    static let pad = 4

    /// The top and bottom bands in lines from the frame's edges, for `current` against `previous` at `offset`, whose
    /// matched band (the lines between whole lines unchanged in place) is `band`. 0 where nothing near an edge stayed
    /// put.
    static func bands(previous: LineHashes, current: LineHashes, offset: Int, band: Range<Int>, limit: Int) -> (top: Int, bottom: Int) {
        let count = current.count
        let pieces = current.pieceCount
        guard pieces > 0, previous.pieceCount == pieces, limit > 0, !band.isEmpty else { return (0, 0) }
        let previousKeys = previous.pieceKeys
        let currentKeys = current.pieceKeys
        func stayedPut(_ piece: Int, _ line: Int) -> Bool {
            let index = piece * count + line
            let key = currentKeys[index]
            guard key != 0, key == previousKeys[index] else { return false }
            return !(band.contains(line + offset) && key == previousKeys[index + offset])
        }
        let middle = max(band.lowerBound, limit)..<max(max(band.lowerBound, limit), min(band.upperBound, count - limit))
        var excluded = Set<Int>()
        for piece in 0..<pieces {
            var first: Int?
            var last = 0
            var inMiddle = false
            for line in band where stayedPut(piece, line) {
                if first == nil { first = line }
                last = line
                if middle.contains(line) { inMiddle = true }
            }
            if let first, inMiddle || last - first + 1 >= band.count / 2 {
                excluded.formUnion([piece - 1, piece, piece + 1])
            }
        }
        let columns = (0..<pieces).filter { !excluded.contains($0) }
        guard !columns.isEmpty else { return (0, 0) }
        func hasStatic(_ line: Int) -> Bool { columns.contains { stayedPut($0, line) } }
        let topLines = band.lowerBound..<max(band.lowerBound, min(limit, band.upperBound))
        let bottomLines = min(band.upperBound, max(band.lowerBound, count - limit))..<band.upperBound
        let top = runs(in: topLines, where: hasStatic).last.map { min(limit, $0.upperBound + pad) } ?? 0
        let bottom = runs(in: bottomLines, where: hasStatic).first.map { min(limit, count - $0.lowerBound + pad) } ?? 0
        return (top, bottom)
    }

    /// The top and bottom bands, from the frame's edges, that cover the runs of lines a match by pieces forgave where
    /// a floating element is (one over content that scrolls under it, of which no piece stays put) within `limit` lines
    /// of an edge, plus `pad`. An element fixed in both frames leaves two runs: its rows in this frame, and the lines of
    /// this frame paired with its rows in the frame before, `offset` above them (one run when they meet). So a run
    /// counts as the element's own rows where a forgiven run, `offset` lines further on, lands on it, or where it
    /// reaches the last line that has a partner at the offset (`pairedEnd`: the element goes on below it, unpaired).
    /// And where a run, `offset` lines further on, lands past `pairedEnd`, that is where the element is, though none of
    /// its rows had a partner to contradict. Mismatches that a fixed element doesn't explain don't make a band.
    static func bands(forgiven runs: [Range<Int>], offset: Int, pairedEnd: Int, length: Int,
                      limit: Int) -> (top: Int, bottom: Int) {
        var own = runs.filter { run in
            run.upperBound >= pairedEnd
                || runs.contains { (($0.lowerBound + offset)..<($0.upperBound + offset)).overlaps(run) }
        }
        for run in runs where run.upperBound + offset > pairedEnd {
            let element = max(0, run.lowerBound + offset)..<min(length, run.upperBound + offset)
            if !element.isEmpty { own.append(element) }
        }
        let top = own.filter { $0.upperBound <= limit }.map { min(limit, $0.upperBound + pad) }.max() ?? 0
        let bottom = own.filter { $0.lowerBound >= length - limit }.map { min(limit, length - $0.lowerBound + pad) }.max() ?? 0
        return (top, bottom)
    }

    /// The runs of lines in `lines` where `isStatic` holds, gaps of up to `runGap` bridged, at least `minimumRun` long.
    private static func runs(in lines: Range<Int>, where isStatic: (Int) -> Bool) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var run: Range<Int>?
        for line in lines where isStatic(line) {
            if let current = run, line - current.upperBound <= runGap {
                run = current.lowerBound..<(line + 1)
            } else {
                if let current = run, current.count >= minimumRun { runs.append(current) }
                run = line..<(line + 1)
            }
        }
        if let current = run, current.count >= minimumRun { runs.append(current) }
        return runs
    }
}
