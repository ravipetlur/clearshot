import CoreGraphics

/// How an image is cut into pieces Vision can read, and how their results are put back together.
///
/// Vision reads almost nothing of a large image recognized whole (3 of 186 lines on a 6720 × 3780 capture, none at
/// 3000 × 3000 or 16 000 × 1200, about a third on wide bands), while tiles of about 2 048 px read everything. So only
/// moderate images are read whole; the rest are cut into a grid of overlapping tiles, each vertical cut moved to the
/// emptiest column nearby so text lines rarely cross it.
///
/// Neighbouring tiles overlap, so a line crossing a cut is read by both, each up to its edge. `merge` puts the two
/// readings together where they overlap: one held within the other is dropped, otherwise their text is stitched
/// through the stretch both read.
public enum OCRTiling {
    public static let maximumWholePixels = 6_500_000, maximumWholeAspect = 3.0
    public static let maximumTileHeight = 2_048, maximumTileWidth = 2_560
    public static let verticalOverlap = 160, horizontalOverlap = 400, cutSearch = 256

    /// A line's box this close to a tile's inner edge (or past it) is cut off there. Vision's box for a line cut by a
    /// tile's right or bottom edge stops short of the edge by about 0.2% of the tile's size (4.3 px on a 2 560 × 2 048
    /// tile, measured), so a tighter margin keeps the slivers it reads there ("E" where a tile ends just inside a column
    /// of text). The vertical overlap still holds any line less than about 140 px tall whole in the row beside.
    private static let innerEdgeMargin: CGFloat = 8
    /// The same text this close (centre to centre, on both axes) is the same line read again in an overlap.
    private static let duplicateDistance: CGFloat = 12
    /// How far past its own rows a tile still keeps a line. Vision's boxes for one line differ by up to 3.6 px between
    /// neighbouring tiles (measured), so with a strict boundary a line centred on it could be kept by neither row. With
    /// this, it is kept by both, and the de-duplication drops the second reading.
    static let ownershipTolerance: CGFloat = 6
    /// The widest gap, in line heights, between two readings in neighbouring tiles that carry one line on. Vision's word
    /// boxes nearly touch (3–4 px apart at a 30 px line), so this only has to stay under a narrow gutter between
    /// columns (30 px is 1.0).
    private static let joinGap: CGFloat = 0.8
    /// How far one reading's box may stick out of another's and still lie within it: Vision's boxes for the same text
    /// differ by up to 2.5 px between tiles.
    private static let containTolerance: CGFloat = 3

    /// The tallest piece a row of tiles is cut into: with the overlap on both sides, a row is at most
    /// `maximumTileHeight` tall.
    private static let rowPiece = maximumTileHeight - verticalOverlap
    /// The widest piece a row is cut into across, before its cuts move: moved up to `cutSearch` px apart and with the
    /// overlap on both sides, a tile is at most `maximumTileWidth` wide. (2 560 − 2 × 256 − 400 = 2 048 − 400.)
    private static let columnPiece = maximumTileWidth - 2 * cutSearch - horizontalOverlap

    /// Whether the image is too big, or too long for its width, to be read whole.
    public static func needsTiling(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let long = Double(max(width, height)), short = Double(min(width, height))
        return width * height > maximumWholePixels || long > maximumWholeAspect * short
    }

    /// How many tiles `tiles(width:height:columnInk:)` cuts the image into: 1 when it is read whole, and also when it is
    /// too long for its width but still fits one tile (a one-line strip). Needs no ink, since moving a cut never changes
    /// how many there are. More than one tile is what makes a recognition slow.
    public static func tileCount(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        guard needsTiling(width: width, height: height) else { return 1 }
        let rows = evenCuts(length: height, piece: rowPiece).count + 1
        let columns = evenCuts(length: width, piece: columnPiece).count + 1
        return rows * columns
    }

    /// The tiles to read, top row first and left to right in each row: the whole image as one tile when it needs no
    /// tiling. `columnInk(rows)` gives, for those image rows, how much ink each image column has (one count per column);
    /// it is asked once for each row of tiles that is cut across.
    public static func tiles(width: Int, height: Int, columnInk: (Range<Int>) -> [Int]) -> [OCRTile] {
        guard width > 0, height > 0 else { return [] }
        guard needsTiling(width: width, height: height) else {
            return [OCRTile(rect: CGRect(x: 0, y: 0, width: width, height: height), innerEdges: [])]
        }
        let rows = spans(length: height, cuts: evenCuts(length: height, piece: rowPiece), overlap: verticalOverlap)
        let evenColumnCuts = evenCuts(length: width, piece: columnPiece)
        var tiles: [OCRTile] = []
        for (rowIndex, row) in rows.enumerated() {
            let cuts = evenColumnCuts.isEmpty ? [] : clearestCuts(near: evenColumnCuts, ink: columnInk(row), width: width)
            let columns = spans(length: width, cuts: cuts, overlap: horizontalOverlap)
            for (columnIndex, column) in columns.enumerated() {
                var inner: OCRTile.Edges = []
                if rowIndex > 0 { inner.insert(.top) }
                if rowIndex < rows.count - 1 { inner.insert(.bottom) }
                if columnIndex > 0 { inner.insert(.left) }
                if columnIndex < columns.count - 1 { inner.insert(.right) }
                let rect = CGRect(x: column.lowerBound, y: row.lowerBound, width: column.count, height: row.count)
                tiles.append(OCRTile(rect: rect, innerEdges: inner))
            }
        }
        return tiles
    }

    /// Puts the tiles' results together, with each tile's lines given in its own pixels (top-left origin) as Vision
    /// read them. A line touching one of its tile's inner edges is dropped (the overlap holds it whole in the
    /// neighbour). The recognizer itself keeps such lines and stitches them (`merge(pieces:)`), which also reads lines
    /// longer than the overlap.
    public static func merge(_ parts: [(tile: OCRTile, lines: [OCRLine], qrPayloads: [String])]) -> OCRResult {
        merge(pieces: parts.map { part in
            (tile: part.tile,
             pieces: part.lines.filter { !touchesInnerEdge($0.box, of: part.tile, sides: true) }.map { OCRPiece(line: $0) },
             qrPayloads: part.qrPayloads)
        })
    }

    /// Puts the tiles' lines together, each given in its tile's pixels (top-left origin) as `ownedPart` keeps it.
    ///
    /// Lines are moved into image pixels; one touching its tile's top or bottom inner edge is dropped. Where a line
    /// read by one tile meets a line read by the tile to its left (on the same text row, overlapping, or less than
    /// `joinGap` line heights apart):
    /// - a reading lying within the other is dropped, and so is a sliver (`isSliver`);
    /// - overlapping readings are stitched (`OCRPiece.stitched`);
    /// - readings that only meet are joined (`OCRPiece.joined`).
    ///
    /// Then a line repeating the text of a kept line at the same place (read by both rows of tiles) is dropped. The
    /// lines of a single tile stay in Vision's order. Lines from several tiles come in reading order
    /// (`OCRReadingOrder`). QR payloads come in tile order (rows top to bottom, tiles left to right), each once.
    static func merge(pieces parts: [(tile: OCRTile, pieces: [OCRPiece], qrPayloads: [String])]) -> OCRResult {
        let ordered = parts.enumerated().sorted { first, second in
            (first.element.tile.rect.minY, first.element.tile.rect.minX, first.offset)
                < (second.element.tile.rect.minY, second.element.tile.rect.minX, second.offset)
        }.map(\.element)

        var lines: [OCRPiece?] = []
        var payloads: [String] = []
        // The tile just read and the lines it last added to: the ones a line in the next tile can meet.
        var previous: (tile: OCRTile, lines: [Int])?
        for part in ordered {
            let tile = part.tile
            var meetable: [Int] = []
            if let previous, previous.tile.rect.minY == tile.rect.minY, previous.tile.innerEdges.contains(.right),
               tile.innerEdges.contains(.left) {
                meetable = previous.lines
            }
            var added: [Int] = []
            for owned in part.pieces where !touchesInnerEdge(owned.line.box, of: tile, sides: false) {
                var piece = owned.offsetBy(dx: tile.rect.minX, dy: tile.rect.minY)
                var heldElsewhere = false
                let meeting = meetable.filter { lines[$0].map { meet($0.line.box, piece.line.box) } ?? false }
                    .sorted { lines[$0]!.line.box.minX < lines[$1]!.line.box.minX }
                for index in meeting {
                    guard let line = lines[index], let leftTile = previous?.tile else { continue }
                    if lies(piece.line.box, within: line.line.box) || isSliver(piece, at: .left, of: tile, beside: line) {
                        heldElsewhere = true
                        break
                    }
                    if !lies(line.line.box, within: piece.line.box) && !isSliver(line, at: .right, of: leftTile, beside: piece) {
                        let (first, second) = line.line.box.minX <= piece.line.box.minX ? (line, piece) : (piece, line)
                        piece = OCRPiece.shareAStretch(first, second)
                            ? OCRPiece.stitched(first, second) : OCRPiece.joined(first, second)
                    }
                    lines[index] = nil
                }
                if !heldElsewhere {
                    lines.append(piece)
                    added.append(lines.count - 1)
                }
            }
            previous = (tile, added)
            for payload in part.qrPayloads where !payloads.contains(payload) {
                payloads.append(payload)
            }
        }

        var kept: [OCRLine] = []
        for line in lines.compactMap({ $0?.line }) {
            let repeated = kept.contains { other in
                other.text == line.text
                    && abs(other.box.midX - line.box.midX) <= duplicateDistance
                    && abs(other.box.midY - line.box.midY) <= duplicateDistance
            }
            if !repeated { kept.append(line) }
        }
        return OCRResult(lines: parts.count > 1 ? OCRReadingOrder.ordered(kept) : kept, qrPayloads: payloads)
    }

    // MARK: - Planning

    /// The cuts splitting `length` into the fewest even pieces of at most `piece`.
    private static func evenCuts(length: Int, piece: Int) -> [Int] {
        let count = (length + piece - 1) / piece
        return (1..<max(count, 1)).map { $0 * length / count }
    }

    /// Each cut moved to the column with the least ink within `cutSearch` px of it; of equally clear columns, the one
    /// nearest the cut (then the leftmost).
    private static func clearestCuts(near cuts: [Int], ink: [Int], width: Int) -> [Int] {
        precondition(ink.count == width, "columnInk must give one count per image column")
        return cuts.map { cut in
            let window = max(cut - cutSearch, 1)...min(cut + cutSearch, width - 1)
            return window.min { a, b in (ink[a], abs(a - cut), a) < (ink[b], abs(b - cut), b) } ?? cut
        }
    }

    /// The pieces between `cuts`, each reaching half the overlap past every cut it borders.
    private static func spans(length: Int, cuts: [Int], overlap: Int) -> [Range<Int>] {
        let bounds = [0] + cuts + [length]
        return (0..<bounds.count - 1).map { index in
            let lower = index == 0 ? 0 : bounds[index] - overlap / 2
            let upper = index == bounds.count - 2 ? length : bounds[index + 1] + overlap / 2
            return lower..<upper
        }
    }

    // MARK: - Merging

    /// Whether two readings in neighbouring tiles meet: on the same text row (sharing at least half the shorter one's
    /// height), and overlapping or less than `joinGap` line heights apart.
    private static func meet(_ a: CGRect, _ b: CGRect) -> Bool {
        let sharedHeight = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
        return sharedHeight >= min(a.height, b.height) / 2 && gap < joinGap * max(a.height, b.height)
    }

    /// Whether `piece` is a sliver at its tile's `side` edge beside `other`, the neighbour's reading of the same row:
    /// a character or two cut off by the edge, which the neighbour reads inside a longer word carrying on past that
    /// edge (Vision boxing the sliver too loosely for `lies(_:within:)`). A whole short word ("12" before "items") is
    /// never one: the neighbour has no longer word there.
    private static func isSliver(_ piece: OCRPiece, at side: OCRTile.Edges, of tile: OCRTile, beside other: OCRPiece) -> Bool {
        let characters = piece.line.text.filter { !$0.isWhitespace }.count
        let box = piece.line.box
        guard characters <= 2 else { return false }
        let words = other.words?.map { (box: $0.box, count: $0.count) }
            ?? [(box: other.line.box, count: other.line.text.filter { !$0.isWhitespace }.count)]
        if side == .left {
            return box.minX <= tile.rect.minX + innerEdgeMargin && words.contains { word in
                word.count > characters && word.box.minX < tile.rect.minX && word.box.maxX >= box.maxX - innerEdgeMargin
            }
        }
        return box.maxX >= tile.rect.maxX - innerEdgeMargin && words.contains { word in
            word.count > characters && word.box.maxX > tile.rect.maxX && word.box.minX <= box.minX + innerEdgeMargin
        }
    }

    /// Whether `box` lies across within `other`, allowing `containTolerance`.
    private static func lies(_ box: CGRect, within other: CGRect) -> Bool {
        box.minX >= other.minX - containTolerance && box.maxX <= other.maxX + containTolerance
    }

    /// Whether `box` comes within `innerEdgeMargin` of the tile's inner edges: the top and bottom ones, and with
    /// `sides`, the left and right ones.
    private static func touchesInnerEdge(_ box: CGRect, of tile: OCRTile, sides: Bool) -> Bool {
        let size = tile.rect.size
        let inner = tile.innerEdges
        return (inner.contains(.top) && box.minY <= innerEdgeMargin)
            || (inner.contains(.bottom) && size.height - box.maxY <= innerEdgeMargin)
            || (sides && inner.contains(.left) && box.minX <= innerEdgeMargin)
            || (sides && inner.contains(.right) && size.width - box.maxX <= innerEdgeMargin)
    }
}
