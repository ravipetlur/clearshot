/// One 64-bit hash per line of a frame along an axis (rows for vertical, columns for horizontal): FNV-1a over every
/// 2nd pixel's whole BGRA word along the line, leaving out `margin` pixels at both ends, where overlay scroll bars come
/// and go. A line whose sampled pixels are all the same is blank: it can't tell one offset from another.
///
/// The same pass hashes each line in pieces across it too (`pieceKeys`): content that doesn't scroll with the page, a
/// sidebar that sticks or a floating button, spoils every whole line it crosses but only the pieces it covers.
struct LineHashes: Sendable, Equatable {
    static let offsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325
    static let prime: UInt64 = 0x0000_0100_0000_01B3
    /// The most pieces a line is cut into, and the fewest samples a piece has (fewer pieces on a short line).
    static let maximumPieces = 16
    static let minimumPieceSamples = 24

    let hashes: [UInt64]
    let blank: [Bool]
    /// How many pieces each line is cut into; 0 for lines made from hashes alone.
    let pieceCount: Int
    /// Piece `p` of line `r` at `p × count + r`: the hash of the line's samples in that piece, or 0 when they are all
    /// one colour (flat). Never 0 otherwise.
    let pieceKeys: [UInt64]

    var count: Int { hashes.count }

    init(hashes: [UInt64], blank: [Bool]) {
        precondition(hashes.count == blank.count)
        self.hashes = hashes
        self.blank = blank
        pieceCount = 0
        pieceKeys = []
    }

    /// Lines made from their pieces' keys alone (`pieces[p][r]`, 0 for flat): each line's hash combines its pieces,
    /// and a line is blank when every piece is flat.
    init(pieces: [[UInt64]]) {
        let count = pieces.first?.count ?? 0
        precondition(pieces.allSatisfy { $0.count == count })
        hashes = (0..<count).map { line in
            pieces.reduce(Self.offsetBasis) { ($0 ^ $1[line]) &* Self.prime }
        }
        blank = (0..<count).map { line in pieces.allSatisfy { $0[line] == 0 } }
        pieceCount = pieces.count
        pieceKeys = pieces.flatMap { $0 }
    }

    /// Only the pieces of `frame`'s lines along `axis`, cut as `init(_:axis:margin:)` cuts them, leaving out the samples
    /// at the positions across the line that `ignored` marks: what a pair of frames compares once the pixels both
    /// have unchanged in place along the whole band (a sticky sidebar, the paper beside the text) are set apart, so a
    /// piece where a sidebar meets the page holds only the page. A piece with nothing left is flat. The whole-line
    /// hashes are left empty (0, blank): matching by whole lines never uses these.
    init(piecesOf frame: StitchFrame, axis: ScrollAxis, margin requestedMargin: Int, ignoring ignored: [Bool]) {
        let count = axis == .vertical ? frame.height : frame.width
        let lineLength = axis == .vertical ? frame.width : frame.height
        precondition(ignored.count == lineLength)
        let margin = max(0, min(requestedMargin, lineLength / 4))
        let samples = Array(stride(from: margin, to: lineLength - margin, by: 2))
        let pieces = max(1, min(Self.maximumPieces, samples.count / Self.minimumPieceSamples))
        let span = max(1, lineLength - 2 * margin)
        // The kept samples, in order, and the piece each falls in.
        let kept = samples.filter { !ignored[$0] }
        let pieceOf = kept.map { ($0 - margin) * pieces / span }
        var keys = [UInt64](repeating: 0, count: pieces * count)
        // Each piece's hash over its kept samples; 0 when they are all one colour or there are none.
        func hash(_ word: (Int) -> UInt32, line: Int) {
            var index = 0
            while index < kept.count {
                let piece = pieceOf[index]
                let first = word(kept[index])
                var value = Self.offsetBasis
                var flat = true
                while index < kept.count, pieceOf[index] == piece {
                    let sample = word(kept[index])
                    value = (value ^ UInt64(sample)) &* Self.prime
                    flat = flat && sample == first
                    index += 1
                }
                keys[piece * count + line] = flat ? 0 : value | 1
            }
        }
        frame.pixels.withUnsafeBytes { pixels in
            for line in 0..<count {
                switch axis {
                case .vertical:
                    let row = line * frame.bytesPerRow
                    hash({ pixels.loadUnaligned(fromByteOffset: row + $0 * 4, as: UInt32.self) }, line: line)
                case .horizontal:
                    hash({ pixels.loadUnaligned(fromByteOffset: $0 * frame.bytesPerRow + line * 4, as: UInt32.self) },
                         line: line)
                }
            }
        }
        hashes = [UInt64](repeating: 0, count: count)
        blank = [Bool](repeating: true, count: count)
        pieceCount = pieces
        pieceKeys = keys
    }

    /// The lines of `frame` along `axis`. The margin shrinks on a narrow frame so at least half of each line counts.
    init(_ frame: StitchFrame, axis: ScrollAxis, margin requestedMargin: Int) {
        let count = axis == .vertical ? frame.height : frame.width
        let lineLength = axis == .vertical ? frame.width : frame.height
        let margin = max(0, min(requestedMargin, lineLength / 4))  // so the first sample, at `margin`, is on the line
        let samples = Array(stride(from: margin, to: lineLength - margin, by: 2))
        let pieces = max(1, min(Self.maximumPieces, samples.count / Self.minimumPieceSamples))
        let span = max(1, lineLength - 2 * margin)
        // The piece each sample falls in: equal parts of the line between the margins.
        let pieceOfSample = samples.map { ($0 - margin) * pieces / span }
        var hashes = [UInt64](repeating: Self.offsetBasis, count: count)
        var blank = [Bool](repeating: true, count: count)
        var pieceKeys = [UInt64](repeating: 0, count: pieces * count)
        frame.pixels.withUnsafeBytes { pixels in
            hashes.withUnsafeMutableBufferPointer { hashes in
                blank.withUnsafeMutableBufferPointer { blank in
                    pieceKeys.withUnsafeMutableBufferPointer { pieceKeys in
                        pieceOfSample.withUnsafeBufferPointer { pieceOfSample in
                            switch axis {
                            case .vertical:
                                for y in 0..<count {
                                    let row = y * frame.bytesPerRow
                                    let first = pixels.loadUnaligned(fromByteOffset: row + margin * 4, as: UInt32.self)
                                    var hash = Self.offsetBasis
                                    var uniform = true
                                    var piece = 0
                                    var pieceHash = Self.offsetBasis
                                    var pieceFirst = first
                                    var pieceFlat = true
                                    for (index, x) in samples.enumerated() {
                                        let word = pixels.loadUnaligned(fromByteOffset: row + x * 4, as: UInt32.self)
                                        if pieceOfSample[index] != piece {
                                            pieceKeys[piece * count + y] = pieceFlat ? 0 : pieceHash | 1
                                            piece = pieceOfSample[index]
                                            pieceHash = Self.offsetBasis
                                            pieceFirst = word
                                            pieceFlat = true
                                        }
                                        hash = (hash ^ UInt64(word)) &* Self.prime
                                        pieceHash = (pieceHash ^ UInt64(word)) &* Self.prime
                                        uniform = uniform && word == first
                                        pieceFlat = pieceFlat && word == pieceFirst
                                    }
                                    if !samples.isEmpty { pieceKeys[piece * count + y] = pieceFlat ? 0 : pieceHash | 1 }
                                    hashes[y] = hash
                                    blank[y] = uniform
                                }
                            case .horizontal:
                                // Row by row, every column's hash at once: the same words in the same order as walking
                                // each column, read in memory order.
                                let first = (0..<count).map { x in
                                    pixels.loadUnaligned(fromByteOffset: margin * frame.bytesPerRow + x * 4, as: UInt32.self)
                                }
                                var pieceHash = [UInt64](repeating: Self.offsetBasis, count: count)
                                var pieceFirst = first
                                var pieceFlat = [Bool](repeating: true, count: count)
                                var piece = -1
                                for (index, y) in samples.enumerated() {
                                    let row = y * frame.bytesPerRow
                                    if pieceOfSample[index] != piece {
                                        if piece >= 0 {
                                            for x in 0..<count { pieceKeys[piece * count + x] = pieceFlat[x] ? 0 : pieceHash[x] | 1 }
                                        }
                                        piece = pieceOfSample[index]
                                        for x in 0..<count {
                                            pieceHash[x] = Self.offsetBasis
                                            pieceFirst[x] = pixels.loadUnaligned(fromByteOffset: row + x * 4, as: UInt32.self)
                                            pieceFlat[x] = true
                                        }
                                    }
                                    for x in 0..<count {
                                        let word = pixels.loadUnaligned(fromByteOffset: row + x * 4, as: UInt32.self)
                                        hashes[x] = (hashes[x] ^ UInt64(word)) &* Self.prime
                                        pieceHash[x] = (pieceHash[x] ^ UInt64(word)) &* Self.prime
                                        if word != first[x] { blank[x] = false }
                                        if word != pieceFirst[x] { pieceFlat[x] = false }
                                    }
                                }
                                if piece >= 0 {
                                    for x in 0..<count { pieceKeys[piece * count + x] = pieceFlat[x] ? 0 : pieceHash[x] | 1 }
                                }
                            }
                        }
                    }
                }
            }
        }
        self.hashes = hashes
        self.blank = blank
        pieceCount = pieces
        self.pieceKeys = pieceKeys
    }

    /// What offset matching compares: 0 for a blank line, the hash (made odd, so never 0) for any other.
    var matchKeys: [UInt64] {
        zip(hashes, blank).map { $1 ? 0 : $0 | 1 }
    }
}
