import CoreGraphics
import Foundation
@testable import CSScrolling

/// A deterministic page for the stitching tests, rows from the top, `width` px wide: a body of "text" lines between an
/// optional sticky header and footer band, each with patterns of its own. A text line is 26 px tall, one every 44 px;
/// it is a row of words of seeded random widths, each word a run of 3-px glyph cells that are dark or not per pixel row,
/// so every row of a line differs. Every 7th line is left out (a paragraph gap), and `blank` body rows are left empty.
///
/// Frames are windows into it: the header, the body scrolled by some position, the footer. A horizontal frame is the
/// same picture turned a quarter, so its lines are columns and its header is on the left.
struct SyntheticPage: Sendable {
    static let lineSpacing = 44
    static let lineHeight = 26
    /// BGRA words as little-endian `UInt32`s: 0xAARRGGBB.
    static let paper: UInt32 = 0xFFFF_FFFF
    static let ink: UInt32 = 0xFF30_3030
    static let headerColor: UInt32 = 0xFF28_64C8
    static let footerColor: UInt32 = 0xFFE6_E6E6
    static let footerInk: UInt32 = 0xFF50_5050

    /// 9 000 rows, no sticky bands.
    static let plain = SyntheticPage(length: 9000)
    /// 9 000 rows with an 80-row header and a 60-row footer.
    static let sticky = SyntheticPage(length: 9000, header: 80, footer: 60)
    /// A narrow, very long page for the output cap.
    static let narrow = SyntheticPage(width: 160, length: 36_000)

    let width: Int
    let header: Int
    let footer: Int
    let bodyLength: Int
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let body: [UInt32]
    private let headerRows: [UInt32]
    private let footerRows: [UInt32]

    /// `length` is the whole page: header, body and footer.
    init(width: Int = 800, length: Int, header: Int = 0, footer: Int = 0, blank: Range<Int> = 0..<0, seed: UInt64 = 1) {
        self.width = width
        self.header = header
        self.footer = footer
        let bodyLength = length - header - footer
        self.bodyLength = bodyLength
        var body = [UInt32](repeating: Self.paper, count: bodyLength * width)
        body.withUnsafeMutableBufferPointer { pixels in
            for y in 0..<bodyLength where !blank.contains(y) {
                let line = y / Self.lineSpacing
                let rowInLine = y % Self.lineSpacing - (Self.lineSpacing - Self.lineHeight) / 2
                guard line % 7 != 6, (0..<Self.lineHeight).contains(rowInLine) else { continue }
                Self.drawWords(into: UnsafeMutableBufferPointer(rebasing: pixels[y * width..<(y + 1) * width]),
                               lineSeed: Self.mix(seed ^ UInt64(line) &* 0x2545_F491_4F6C_DD1D), row: rowInLine, ink: Self.ink)
            }
        }
        self.body = body
        headerRows = Self.band(width: width, rows: header, color: Self.headerColor, ink: Self.paper, seed: Self.mix(seed ^ 0x4EAD))
        footerRows = Self.band(width: width, rows: footer, color: Self.footerColor, ink: Self.footerInk, seed: Self.mix(seed ^ 0xF007))
    }

    /// The frame `length` lines long with the body scrolled `position` rows: the header, body rows
    /// `position ..< position + length − header − footer`, the footer. `across` picks the page columns shown.
    func frame(at position: Int, length: Int, axis: ScrollAxis = .vertical, across: Range<Int>? = nil) -> StitchFrame {
        let bodyRows = position..<(position + length - header - footer)
        return image(lines: lines(body: bodyRows, across: across ?? 0..<width), axis: axis, across: (across ?? 0..<width).count)
    }

    /// What stitching frames scrolled from `start` to `end` must give, as tight BGRA laid out like the frames: the
    /// header, body rows `start ..< end + length − header − footer`, the footer.
    func expected(from start: Int = 0, to end: Int, length: Int, axis: ScrollAxis = .vertical) -> [UInt8] {
        image(lines: lines(body: start..<(end + length - header - footer), across: 0..<width), axis: axis, across: width).pixels
    }

    /// Header, body rows and footer, a row per line, `across.count` px each.
    private func lines(body rows: Range<Int>, across: Range<Int>) -> [UInt32] {
        precondition(rows.lowerBound >= 0 && rows.upperBound <= bodyLength, "body rows \(rows) aren't all on the page")
        var lines: [UInt32] = []
        lines.reserveCapacity((header + rows.count + footer) * across.count)
        func append(_ source: [UInt32], rows: Range<Int>) {
            for y in rows {
                lines.append(contentsOf: source[(y * width + across.lowerBound)..<(y * width + across.upperBound)])
            }
        }
        append(headerRows, rows: 0..<header)
        append(body, rows: rows)
        append(footerRows, rows: 0..<footer)
        return lines
    }

    /// Lines of `across` px each as a frame along `axis`: rows as they are, or turned into columns.
    private func image(lines: [UInt32], axis: ScrollAxis, across: Int) -> StitchFrame {
        let count = lines.count / across
        switch axis {
        case .vertical:
            return StitchFrame(width: across, height: count, bytesPerRow: across * 4, pixels: Self.bytes(lines),
                               colorSpace: colorSpace)
        case .horizontal:
            var turned = [UInt32](repeating: 0, count: lines.count)
            turned.withUnsafeMutableBufferPointer { turned in
                lines.withUnsafeBufferPointer { lines in
                    for line in 0..<count {
                        for x in 0..<across { turned[x * count + line] = lines[line * across + x] }
                    }
                }
            }
            return StitchFrame(width: count, height: across, bytesPerRow: count * 4, pixels: Self.bytes(turned),
                               colorSpace: colorSpace)
        }
    }

    private static func band(width: Int, rows: Int, color: UInt32, ink: UInt32, seed: UInt64) -> [UInt32] {
        var band = [UInt32](repeating: color, count: rows * width)
        band.withUnsafeMutableBufferPointer { pixels in
            for y in 0..<rows {
                drawWords(into: UnsafeMutableBufferPointer(rebasing: pixels[y * width..<(y + 1) * width]), lineSeed: seed, row: y, ink: ink)
            }
        }
        return band
    }

    /// One pixel row of a text line: the line's words (the same for every row of the line) with this row's glyph cells.
    private static func drawWords(into row: UnsafeMutableBufferPointer<UInt32>, lineSeed: UInt64, row rowIndex: Int, ink: UInt32) {
        var layout = SplitMix64(state: lineSeed)
        var x = 24 + Int(layout.next() % 24)
        let end = row.count * Int(55 + layout.next() % 40) / 100
        while x + 3 <= end {
            let wordWidth = 18 + Int(layout.next() % 90)
            let wordSeed = layout.next()
            for cell in 0..<(min(wordWidth, end - x) / 3)
            where mix(wordSeed &+ UInt64(rowIndex) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(cell)) & 1 == 1 {
                let start = x + cell * 3
                for pixel in start..<(start + 3) { row[pixel] = ink }
            }
            x += wordWidth + 8 + Int(layout.next() % 10)
        }
    }

    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    static func bytes(_ words: [UInt32]) -> [UInt8] {
        words.withUnsafeBytes { Array($0) }
    }
}

struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return SyntheticPage.mix(state)
    }
}

extension StitchFrame {
    /// This frame with `rect` (pixels, from the top left) filled with `color` (a BGRA word, 0xAARRGGBB).
    func painting(_ rect: CGRect, color: UInt32) -> StitchFrame {
        var pixels = pixels
        pixels.withUnsafeMutableBytes { bytes in
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    bytes.storeBytes(of: color.littleEndian, toByteOffset: y * bytesPerRow + x * 4, as: UInt32.self)
                }
            }
        }
        return StitchFrame(width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels, colorSpace: colorSpace)
    }
}

/// The tight BGRA bytes of `image`, rows from the top.
func tightBytes(of image: CGImage) -> [UInt8] {
    guard let data = image.dataProvider?.data as Data? else { return [] }
    let rowBytes = image.width * 4
    var bytes = [UInt8]()
    bytes.reserveCapacity(rowBytes * image.height)
    for y in 0..<image.height {
        bytes.append(contentsOf: data[(y * image.bytesPerRow)..<(y * image.bytesPerRow + rowBytes)])
    }
    return bytes
}

/// The first row (of `rowBytes` bytes) where `a` and `b` differ, or nil when they're equal; a size difference counts as
/// a difference at the shorter one's end. Keeps a failing comparison of megabytes readable.
func firstDifferentRow(_ a: [UInt8], _ b: [UInt8], rowBytes: Int) -> Int? {
    let common = min(a.count, b.count)
    let mismatch = a.withUnsafeBufferPointer { a in
        b.withUnsafeBufferPointer { b in
            (0..<common).first { a[$0] != b[$0] }
        }
    }
    if let mismatch { return mismatch / rowBytes }
    return a.count == b.count ? nil : common / rowBytes
}
