import CoreGraphics

/// The order in which the lines of a tiled image are copied. Tiles cut a page into bands, so taking them tile by tile
/// would interleave its columns band by band. Instead, the columns are found from the page's gutters.
enum OCRReadingOrder {
    /// `lines` in reading order:
    /// - columns left to right, where a gutter separates them: an x range at least a line height wide (the median
    ///   line's) that no line crosses, top to bottom of the page;
    /// - inside a column, rows top to bottom and the lines of a row left to right.
    ///
    /// A page with no such gutter is one column, read row by row.
    static func ordered(_ lines: [OCRLine]) -> [OCRLine] {
        guard lines.count > 1 else { return lines }
        let heights = lines.map(\.box.height).sorted()
        let gutter = heights[heights.count / 2]

        var columns: [[OCRLine]] = []
        var columnEnd = -CGFloat.infinity
        for line in stablySorted(lines, by: { $0.box.minX }) {
            if let last = columns.indices.last, line.box.minX - columnEnd < gutter {
                columns[last].append(line)
                columnEnd = max(columnEnd, line.box.maxX)
            } else {
                columns.append([line])
                columnEnd = line.box.maxX
            }
        }
        return columns.flatMap(rowByRow)
    }

    /// Rows top to bottom, each row's lines left to right. A line is in the row of the line above it when they share
    /// at least half the shorter one's height.
    private static func rowByRow(_ lines: [OCRLine]) -> [OCRLine] {
        var rows: [[OCRLine]] = []
        for line in stablySorted(lines, by: { $0.box.midY }) {
            if let first = rows.last?.first,
               min(first.box.maxY, line.box.maxY) - max(first.box.minY, line.box.minY) >= min(first.box.height, line.box.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { stablySorted($0, by: { $0.box.minX }) }
    }

    private static func stablySorted(_ lines: [OCRLine], by key: (OCRLine) -> CGFloat) -> [OCRLine] {
        lines.enumerated().sorted { (key($0.element), $0.offset) < (key($1.element), $1.offset) }.map(\.element)
    }
}
