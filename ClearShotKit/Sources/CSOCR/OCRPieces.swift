import CoreGraphics

/// A word of a recognized line, located: where its characters start among the line's non-space characters, how many
/// there are, and its box.
struct OCRWord: Equatable, Sendable {
    var start: Int
    var count: Int
    var box: CGRect
}

/// A line one tile read, as `OCRTiling.merge(pieces:)` puts neighbouring tiles' readings together.
struct OCRPiece: Equatable, Sendable {
    var line: OCRLine
    /// Its words, for a line reaching into the overlap with a neighbouring tile, where that tile reads it too: they
    /// say which characters are where. Nil otherwise (positions are then estimated across the whole line).
    var words: [OCRWord]?

    init(line: OCRLine, words: [OCRWord]? = nil) {
        self.line = line
        self.words = words
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> OCRPiece {
        var moved = self
        moved.line.box = line.box.offsetBy(dx: dx, dy: dy)
        moved.words = words?.map { OCRWord(start: $0.start, count: $0.count, box: $0.box.offsetBy(dx: dx, dy: dy)) }
        return moved
    }

    // MARK: - Two readings of one line

    /// The line read by two neighbouring tiles, `left` and `right` (`left` starting further left), whose readings
    /// overlap: the stretch they share they both read, each up to where its tile ends.
    ///
    /// The two texts are aligned character by character, spaces included (`overlapAlignment`), pairing only
    /// characters within the shared stretch. What lies beyond it in one reading alone (the start of `left`, the end of
    /// `right`) costs nothing, so the stretch itself decides the pairing however few characters it holds. Each tile reads the stretch differently: Vision,
    /// correcting language in a crop that ends mid-line, may drop a "." or put a space inside a path or URL. So in
    /// the stretch:
    /// - a character both read, a space included, is kept once;
    /// - a character only one read is kept, but a space only one read is not;
    /// - where one read a space and the other a character, the character is kept;
    /// - where they read different characters, the reading of the tile it is deeper inside wins.
    ///
    /// Within two characters of where a reading's tile ends, it is cut off and partly misread, so the other reading
    /// is taken there.
    static func stitched(_ left: OCRPiece, _ right: OCRPiece) -> OCRPiece {
        let a = Letters(left.line.text), b = Letters(right.line.text)
        guard a.nonSpaceCount > 0, b.nonSpaceCount > 0 else { return joined(left, right) }
        // The shared stretch runs from where `right`'s tile begins to where `left`'s ends.
        let from = right.line.box.minX, to = left.line.box.maxX, middle = (from + to) / 2
        let characterWidth = min(left.line.box.width / CGFloat(a.nonSpaceCount), right.line.box.width / CGFloat(b.nonSpaceCount))
        let edge = 2 * characterWidth
        // Bounds a little past the stretch's estimated ends, so it surely lies within them; what lies past it is free.
        let aStart = a.index(ofNonSpace: max(left.characterIndex(at: from, of: a.nonSpaceCount) - stitchMargin, 0))
        let bEnd = b.index(ofNonSpace: min(right.characterIndex(at: to, of: b.nonSpaceCount) + stitchMargin, b.nonSpaceCount))

        var characters = Array(a.characters[..<aStart])
        let xsA = (aStart..<a.characters.count).map { a.x(of: $0, in: left) }, xsB = (0..<bEnd).map { b.x(of: $0, in: right) }
        // `right`'s tile saw nothing left of the stretch and `left`'s nothing right of it. The estimated places drift by
        // a character or two in a long word, so pairs reach to the far side of each edge zone (where the other reading
        // wins anyway). But only a pair of equal characters estimated within the stretch counts as a match: one
        // outside it scores below leaving both unpaired. So a drifted pair still pairs (no letter kept twice), while in
        // a run of one character ("=====") pairing characters the other tile never saw gains nothing. A reading's
        // characters where its tile cuts it off go unpaired for half the usual cost: the other reading has them. (For
        // nothing, runs come out a character long or short far more often; at half, no letter is doubled either.)
        let slack = characterWidth / 2
        let columns = overlapAlignment(
            Array(a.characters[aStart...]), Array(b.characters[..<bEnd]),
            pairScore: { i, j in
                guard xsA[i] >= from - edge, xsB[j] <= to + edge, abs(xsA[i] - xsB[j]) <= pairingReach * characterWidth else {
                    return nil
                }
                guard a.characters[i + aStart] == b.characters[j] else { return -2 }
                return xsA[i] >= from - slack && xsB[j] <= to + slack ? 2 : -1
            },
            unpairedCostA: { xsA[$0] > to - edge ? 1 : 2 },
            unpairedCostB: { xsB[$0] < from + edge ? 1 : 2 })
        for column in columns {
            let i = column.a.map { $0 + aStart }, j = column.b
            let x = i.map { a.x(of: $0, in: left) } ?? b.x(of: j!, in: right)
            let leftHolds = x < from + edge, rightHolds = x > to - edge
            switch (i, j) {
            case let (i?, j?):
                let (p, q) = (a.characters[i], b.characters[j])
                if p == q || leftHolds {
                    characters.append(p)
                } else if rightHolds {
                    characters.append(q)
                } else if p == " " || q == " " {
                    characters.append(p == " " ? q : p)
                } else {
                    characters.append(x < middle ? p : q)
                }
            case let (i?, nil) where leftHolds || (!rightHolds && a.characters[i] != " "):
                characters.append(a.characters[i])
            case let (nil, j?) where rightHolds || (!leftHolds && b.characters[j] != " "):
                characters.append(b.characters[j])
            default:
                break
            }
        }
        let shift = Letters(String(characters)).nonSpaceCount - b.nonSpaceIndex(bEnd)
        characters += b.characters[bEnd...]

        let words = (left.words?.filter { $0.start + $0.count <= a.nonSpaceIndex(aStart) } ?? [])
            + (right.words?.filter { $0.start >= b.nonSpaceIndex(bEnd) }.map { OCRWord(start: $0.start + shift, count: $0.count, box: $0.box) } ?? [])
        let text = String(characters).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return OCRPiece(line: OCRLine(text: text, box: left.line.box.union(right.line.box)), words: words.isEmpty ? nil : words)
    }

    /// How many characters past the shared stretch's estimated ends the alignment takes in: the estimate spreads a
    /// word's characters evenly, so in proportional type it can be a few characters out.
    private static let stitchMargin = 10

    /// How far apart, in characters, two characters' estimated places may be and still be paired: the estimate can be
    /// a few characters out where a word is cut off in one reading.
    private static let pairingReach: CGFloat = 5

    /// The best overlap alignment of `a`, a reading's end, with `b`, the next reading's start, as columns: positions
    /// in each, or nil where one has a character the other lacks.
    ///
    /// A pair scores what `pairScore` says (nil: not made), and a character left unpaired loses what `unpairedCostA`
    /// or `unpairedCostB` says. `a`'s leading characters and `b`'s trailing ones may go unpaired for nothing, as they
    /// lie beyond the stretch both read: pairing nothing scores 0, and the stretch both read, however short, scores
    /// more.
    private static func overlapAlignment(_ a: [Character], _ b: [Character], pairScore: (Int, Int) -> Int?,
                                         unpairedCostA: (Int) -> Int, unpairedCostB: (Int) -> Int) -> [(a: Int?, b: Int?)] {
        let n = a.count, m = b.count
        let ruledOut = Int.min / 4
        let costA = (0..<n).map(unpairedCostA), costB = (0..<m).map(unpairedCostB)
        var score = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if m > 0 {
            for j in 1...m { score[0][j] = score[0][j - 1] - costB[j - 1] }
        }
        func pairing(_ i: Int, _ j: Int) -> Int {
            pairScore(i - 1, j - 1).map { score[i - 1][j - 1] + $0 } ?? ruledOut
        }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    score[i][j] = max(pairing(i, j), score[i - 1][j] - costA[i - 1], score[i][j - 1] - costB[j - 1])
                }
            }
        }
        // `a` is used up; `b` may stop anywhere (the further, of equal scores).
        let end = (0...m).max { (score[n][$0], $0) < (score[n][$1], $1) } ?? m
        var columns: [(a: Int?, b: Int?)] = []
        var i = n, j = end
        while i > 0, j > 0 {
            if score[i][j] == pairing(i, j) {
                columns.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if score[i][j] == score[i - 1][j] - costA[i - 1] {
                columns.append((i - 1, nil))
                i -= 1
            } else {
                columns.append((nil, j - 1))
                j -= 1
            }
        }
        while j > 0 { j -= 1; columns.append((nil, j)) }
        while i > 0 { i -= 1; columns.append((i, nil)) }
        return columns.reversed() + (end..<m).map { (a: nil, b: $0) }
    }

    /// Whether `left` and `right` (`left` starting further left) overlap by more than a character and a half: then
    /// both read the stretch they share. Less is box jitter between readings that only meet.
    static func shareAStretch(_ left: OCRPiece, _ right: OCRPiece) -> Bool {
        let characters = (Letters(left.line.text).nonSpaceCount, Letters(right.line.text).nonSpaceCount)
        guard characters.0 > 0, characters.1 > 0 else { return false }
        let characterWidth = min(left.line.box.width / CGFloat(characters.0), right.line.box.width / CGFloat(characters.1))
        return left.line.box.maxX - right.line.box.minX > 1.5 * characterWidth
    }

    /// `left` followed by `right`, which carries it on with nothing read twice: a space between them, except between
    /// Han or Kana, which are written without spaces (Hangul isn't).
    static func joined(_ left: OCRPiece, _ right: OCRPiece) -> OCRPiece {
        let spaced = spacedBetween(left.line.text.last, right.line.text.first)
        let shift = Letters(left.line.text).nonSpaceCount
        let words = (left.words ?? []) + (right.words?.map { OCRWord(start: $0.start + shift, count: $0.count, box: $0.box) } ?? [])
        return OCRPiece(line: OCRLine(text: left.line.text + (spaced ? " " : "") + right.line.text,
                                      box: left.line.box.union(right.line.box)),
                        words: words.isEmpty ? nil : words)
    }

    /// Whether two readings meeting with these characters take a space between them: yes, except between Han or Kana.
    private static func spacedBetween(_ before: Character?, _ after: Character?) -> Bool {
        !(before?.isHanOrKana == true && after?.isHanOrKana == true)
    }

    /// Where the line's non-space character `index` (of `count`) is across: by its word, spreading the word's characters
    /// evenly across its box; without words, across the line's.
    fileprivate func x(ofCharacter index: Int, of count: Int) -> CGFloat {
        if let word = words?.first(where: { $0.start <= index && index < $0.start + $0.count }) {
            return word.box.minX + (CGFloat(index - word.start) + 0.5) / CGFloat(word.count) * word.box.width
        }
        return line.box.minX + (CGFloat(index) + 0.5) / CGFloat(max(count, 1)) * line.box.width
    }

    /// Which of the line's `count` non-space characters is at `x`: by the word there (or nearest), spreading its
    /// characters evenly across its box; without words, across the line's.
    fileprivate func characterIndex(at x: CGFloat, of count: Int) -> Int {
        func position(in box: CGRect, characters: Int) -> Int {
            guard box.width > 0 else { return characters / 2 }
            return min(max(Int(((x - box.minX) / box.width * CGFloat(characters)).rounded()), 0), characters)
        }
        func distance(_ box: CGRect) -> CGFloat { x < box.minX ? box.minX - x : max(x - box.maxX, 0) }
        guard let word = words?.min(by: { distance($0.box) < distance($1.box) }) else {
            return position(in: line.box, characters: count)
        }
        return min(word.start + position(in: word.box, characters: word.count), count)
    }
}

/// A line's text as characters, a run of white space as one space, with where each stands among the non-space ones.
private struct Letters {
    let characters: [Character]
    /// For each character, how many non-space characters come before it; one more entry for the end.
    private let nonSpaceBefore: [Int]

    init(_ text: String) {
        var characters: [Character] = []
        for character in text {
            if character.isWhitespace {
                if let last = characters.last, last != " " { characters.append(" ") }
            } else {
                characters.append(character)
            }
        }
        if characters.last == " " { characters.removeLast() }
        self.characters = characters
        var counts = [0]
        for character in characters { counts.append(counts[counts.count - 1] + (character == " " ? 0 : 1)) }
        nonSpaceBefore = counts
    }

    var nonSpaceCount: Int { nonSpaceBefore[characters.count] }

    func nonSpaceIndex(_ index: Int) -> Int { nonSpaceBefore[index] }

    /// The position of the non-space character `n` (the end, past the last).
    func index(ofNonSpace n: Int) -> Int {
        characters.indices.first { characters[$0] != " " && nonSpaceBefore[$0] == n } ?? characters.count
    }

    /// Where character `index` is across in `piece`'s reading: by its word (a space halfway between its neighbours),
    /// or without words, spreading all the characters, spaces too, evenly across the line.
    func x(of index: Int, in piece: OCRPiece) -> CGFloat {
        guard piece.words != nil else {
            return piece.line.box.minX + (CGFloat(index) + 0.5) / CGFloat(characters.count) * piece.line.box.width
        }
        guard characters[index] == " " else { return piece.x(ofCharacter: nonSpaceBefore[index], of: nonSpaceCount) }
        let before = piece.x(ofCharacter: nonSpaceBefore[index] - 1, of: nonSpaceCount)
        let after = piece.x(ofCharacter: nonSpaceBefore[index], of: nonSpaceCount)
        return (before + after) / 2
    }
}

extension OCRTiling {
    /// The line recognized in `tile` (`box` in the tile's pixels) as the tile contributes it, or nil when it isn't
    /// the tile's: a line belongs to the row of tiles holding its centre, allowing `ownershipTolerance` (a line centred
    /// on the boundary is kept by both rows, and the de-duplication keeps one).
    ///
    /// Across, the tile keeps all it read: where it meets a neighbour, `merge(pieces:)` puts the two readings together.
    /// A line reaching into such an overlap carries its words, with `boxFor` giving the box of a word of `text` (nil
    /// if Vision has none: positions are then estimated across the whole line).
    static func ownedPart(of text: String, box: CGRect, in tile: OCRTile,
                          boxFor: (Range<String.Index>) -> CGRect?) -> OCRPiece? {
        let inner = tile.innerEdges
        let size = tile.rect.size
        let rowOverlap = CGFloat(verticalOverlap / 2)
        let top = inner.contains(.top) ? rowOverlap - ownershipTolerance : -.infinity
        let bottom = inner.contains(.bottom) ? size.height - rowOverlap + ownershipTolerance : .infinity
        guard box.midY >= top, box.midY < bottom else { return nil }

        let overlap = CGFloat(horizontalOverlap)
        let meetsLeft = inner.contains(.left) && box.minX < overlap
        let meetsRight = inner.contains(.right) && box.maxX > size.width - overlap
        guard meetsLeft || meetsRight else { return OCRPiece(line: OCRLine(text: text, box: box)) }

        var words: [OCRWord] = []
        var start = 0
        for range in wordRanges(in: text) {
            let count = text[range].count
            guard let wordBox = boxFor(range) else { return OCRPiece(line: OCRLine(text: text, box: box)) }
            words.append(OCRWord(start: start, count: count, box: wordBox))
            start += count
        }
        return OCRPiece(line: OCRLine(text: text, box: box), words: words)
    }

    /// The words of `text` whose boxes locate its characters: runs of non-space characters, except that each CJK
    /// character is a word of its own (CJK is written without spaces).
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in text.indices {
            let character = text[index]
            guard character.isWhitespace || character.isCJK else {
                if start == nil { start = index }
                continue
            }
            if let wordStart = start {
                ranges.append(wordStart..<index)
                start = nil
            }
            if character.isCJK { ranges.append(index..<text.index(after: index)) }
        }
        if let start { ranges.append(start..<text.endIndex) }
        return ranges
    }
}
