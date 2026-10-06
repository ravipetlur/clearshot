import Foundation

/// A GIF colour table: up to 255 colours (0x00RRGGBB) and, after them, the index left transparent.
public struct GIFPalette: Sendable, Equatable {
    public let colors: [UInt32]
    public let transparentIndex: Int?

    public init(colors: [UInt32], transparentIndex: Int?) {
        precondition(!colors.isEmpty && colors.count <= 256, "A GIF colour table holds 1 to 256 colours")
        precondition(transparentIndex.map { $0 >= 0 && $0 < 256 } ?? true, "The transparent index is outside the table")
        self.colors = colors
        self.transparentIndex = transparentIndex
    }

    /// The table's size in the file: the smallest power of two, at least 2, that holds the colours and the transparent
    /// index.
    var tableSize: Int {
        let needed = max(colors.count, (transparentIndex ?? -1) + 1, 2)
        var size = 2
        while size < needed { size *= 2 }
        return size
    }

    /// The table's bits a code: log2 of `tableSize`.
    var tableBits: Int {
        tableSize.trailingZeroBitCount
    }
}

/// The GIF's colours. A palette comes from a histogram over 6 bits a channel: an image with no more colours than asked
/// for keeps them exactly; otherwise the colours are split, box by box, where the split removes the most squared error
/// (Wu's criterion, on the histogram's cells), then refined by a few rounds of k-means. With `mergingWithin`, boxes no
/// wider than that aren't split, so decode noise around a colour costs one entry, not many. Each pixel maps to its
/// nearest colour at full precision; ordered dithering (Bayer 8 × 8, fixed to the canvas, so a still area stays
/// identical) mixes the two colours either side of it, never touching a colour the palette has.
public enum GIFQuantizer {
    /// Dithering mixes in a second colour only when it is at most this far from the source (root mean square a
    /// channel): mixing colours further apart is noise, not a gradient.
    static let maximumDitherDistance = 16.0

    /// A palette of at most `colors` (1…255) colours for `frames` (sampled frames, or one), with the transparent index
    /// after them.
    public static func palette(from frames: [GIFFrame], colors: Int) -> GIFPalette {
        palette(from: frames, colors: colors, mergingWithin: 0)
    }

    /// `palette(from:colors:)` that spends no entries on differences up to `mergingWithin` levels a channel (the
    /// stabiliser's threshold), which a GIF made with that threshold never shows anyway.
    public static func palette(from frames: [GIFFrame], colors: Int, mergingWithin noise: Int) -> GIFPalette {
        var histogram = GIFHistogram()
        for frame in frames {
            histogram.add(frame)
        }
        return histogram.palette(colors: colors, mergingWithin: noise)
    }

    /// The palette indices of `diff.rect`: each changed pixel's colour (dithered when `dither`), the transparent index
    /// for the rest.
    public static func indices(for frame: GIFFrame, diff: GIFDiff, palette: GIFPalette, dither: Bool) -> [UInt8] {
        indices(for: frame, diff: diff, map: GIFColorMap(palette), dither: dither, ditherFloor: 0)
    }

    /// `indices(for:diff:palette:dither:)` through a colour map kept across frames. Errors of at most `ditherFloor`
    /// levels a channel aren't dithered (decode noise would otherwise speckle flat areas).
    static func indices(for frame: GIFFrame, diff: GIFDiff, map: GIFColorMap, dither: Bool, ditherFloor: Int) -> [UInt8] {
        let rect = diff.rect
        let transparent = map.palette.transparentIndex
        let mapsEveryPixel = transparent == nil
        var indices = [UInt8](repeating: UInt8(transparent ?? 0), count: rect.width * rect.height)
        let bayer = GIFBayer.matrix
        let (table, bytesPerRow) = (map.table, frame.bytesPerRow)
        let ditherReach = Int(3 * maximumDitherDistance * maximumDitherDistance)
        frame.bgra.withUnsafeBufferPointer { sourceBuffer in
            diff.changed.withUnsafeBufferPointer { changedBuffer in
                indices.withUnsafeMutableBufferPointer { indexBuffer in
                    map.colors.withUnsafeBufferPointer { colorBuffer in
                        bayer.withUnsafeBufferPointer { bayerBuffer in
                            let (source, changed, indices) = (sourceBuffer.baseAddress!, changedBuffer.baseAddress!,
                                                              indexBuffer.baseAddress!)
                            let (colors, bayer) = (colorBuffer.baseAddress!, bayerBuffer.baseAddress!)
                            var row = 0
                            while row < rect.height {
                                let y = rect.y + row
                                let line = source + y * bytesPerRow + rect.x * 4
                                let bayerRow = bayer + (y & 7) * 8
                                var column = 0
                                while column < rect.width {
                                    let i = row * rect.width + column
                                    if changed[i] || mapsEveryPixel {
                                        let pixel = line + column * 4
                                        let (r, g, b) = (Int(pixel[2]), Int(pixel[1]), Int(pixel[0]))
                                        let known = Int(table[r << 16 | g << 8 | b])
                                        let first = known != 0 ? known - 1 : map.index(r, g, b)
                                        var chosen = first
                                        if dither {
                                            let near = colors[first]
                                            let er = r - Int(near >> 16), eg = g - Int(near >> 8 & 0xFF), eb = b - Int(near & 0xFF)
                                            if er > ditherFloor || er < -ditherFloor || eg > ditherFloor || eg < -ditherFloor
                                                || eb > ditherFloor || eb < -ditherFloor {
                                                // The colour on the other side of the source from the first, and how far
                                                // along the way to it the source lies, against the Bayer threshold.
                                                let second = map.beyond(r, g, b, from: first)
                                                let far = colors[second]
                                                let (fr, fg, fb) = (r - Int(far >> 16), g - Int(far >> 8 & 0xFF),
                                                                    b - Int(far & 0xFF))
                                                // Never a colour beyond the dither's reach: that would be noise.
                                                if second != first, fr * fr + fg * fg + fb * fb <= ditherReach {
                                                    let dr = Int(far >> 16) - Int(near >> 16)
                                                    let dg = Int(far >> 8 & 0xFF) - Int(near >> 8 & 0xFF)
                                                    let db = Int(far & 0xFF) - Int(near & 0xFF)
                                                    let along = er * dr + eg * dg + eb * db
                                                    let threshold = 2 * bayerRow[(rect.x + column) & 7] + 1
                                                    if along * 128 > threshold * (dr * dr + dg * dg + db * db) { chosen = second }
                                                }
                                            }
                                        }
                                        indices[i] = UInt8(chosen)
                                    }
                                    column += 1
                                }
                                row += 1
                            }
                        }
                    }
                }
            }
        }
        return indices
    }

    /// Each pixel's distance on its farthest channel (as the stabiliser measures) from the colour `indices` in `palette`
    /// give it, over `diff.rect`; `Int.max` for an index past the colours (the transparent one).
    static func distances(_ frame: GIFFrame, diff: GIFDiff, indices: [UInt8], palette: GIFPalette) -> [Int] {
        let rect = diff.rect
        var distances = [Int](repeating: .max, count: rect.width * rect.height)
        frame.bgra.withUnsafeBufferPointer { sourceBuffer in
            indices.withUnsafeBufferPointer { indexBuffer in
                palette.colors.withUnsafeBufferPointer { colorBuffer in
                    distances.withUnsafeMutableBufferPointer { distanceBuffer in
                        let (source, indices) = (sourceBuffer.baseAddress!, indexBuffer.baseAddress!)
                        let (colors, count, distances) = (colorBuffer.baseAddress!, colorBuffer.count,
                                                          distanceBuffer.baseAddress!)
                        var row = 0
                        while row < rect.height {
                            let line = source + (rect.y + row) * frame.bytesPerRow + rect.x * 4
                            var column = 0
                            while column < rect.width {
                                let i = row * rect.width + column
                                let index = Int(indices[i])
                                if index < count {
                                    let pixel = line + column * 4
                                    let color = colors[index]
                                    let red = Int(pixel[2]) - Int(color >> 16)
                                    let green = Int(pixel[1]) - Int(color >> 8 & 0xFF)
                                    let blue = Int(pixel[0]) - Int(color & 0xFF)
                                    let (r, g, b) = (red < 0 ? -red : red, green < 0 ? -green : green, blue < 0 ? -blue : blue)
                                    let rg = r > g ? r : g
                                    distances[i] = rg > b ? rg : b
                                }
                                column += 1
                            }
                            row += 1
                        }
                    }
                }
            }
        }
        return distances
    }

    /// How far the changed pixels of `diff.rect` are from the colours `indices` gives them: how many there are, and
    /// the mean squared difference per channel.
    static func error(of frame: GIFFrame, diff: GIFDiff, indices: [UInt8], palette: GIFPalette) -> (pixels: Int, meanSquared: Double) {
        let rect = diff.rect
        var (pixels, squares) = (0, 0)
        frame.bgra.withUnsafeBufferPointer { sourceBuffer in
            diff.changed.withUnsafeBufferPointer { changedBuffer in
                indices.withUnsafeBufferPointer { indexBuffer in
                    palette.colors.withUnsafeBufferPointer { colorBuffer in
                        let (source, changed, indices) = (sourceBuffer.baseAddress!, changedBuffer.baseAddress!,
                                                          indexBuffer.baseAddress!)
                        let (colors, count) = (colorBuffer.baseAddress!, colorBuffer.count)
                        var row = 0
                        while row < rect.height {
                            let line = source + (rect.y + row) * frame.bytesPerRow + rect.x * 4
                            var column = 0
                            while column < rect.width {
                                let i = row * rect.width + column
                                let index = Int(indices[i])
                                if changed[i], index < count {
                                    let pixel = line + column * 4
                                    let color = colors[index]
                                    let red = Int(pixel[2]) - Int(color >> 16)
                                    let green = Int(pixel[1]) - Int(color >> 8 & 0xFF)
                                    let blue = Int(pixel[0]) - Int(color & 0xFF)
                                    squares += red * red + green * green + blue * blue
                                    pixels += 1
                                }
                                column += 1
                            }
                            row += 1
                        }
                    }
                }
            }
        }
        return (pixels, pixels > 0 ? Double(squares) / Double(pixels * 3) : 0)
    }
}

/// The 8 × 8 Bayer matrix, 0…63.
enum GIFBayer {
    static let matrix: [Int] = {
        var matrix = [0]
        var size = 1
        while size < 8 {
            var next = [Int](repeating: 0, count: size * size * 4)
            for y in 0..<size {
                for x in 0..<size {
                    let value = matrix[y * size + x] * 4
                    next[y * size * 2 + x] = value
                    next[y * size * 2 + x + size] = value + 2
                    next[(y + size) * size * 2 + x] = value + 3
                    next[(y + size) * size * 2 + x + size] = value + 1
                }
            }
            matrix = next
            size *= 2
        }
        return matrix
    }()
}

/// The nearest palette colour for any colour, remembered at full precision: a 16 M entry table that only the colours
/// looked up ever touch (it is allocated zeroed, page by page, on demand). One per palette; not shared between tasks.
final class GIFColorMap {
    let palette: GIFPalette
    let colors: [UInt32]
    private let reds: [Int]
    private let greens: [Int]
    private let blues: [Int]
    /// Index + 1 for each 0xRRGGBB looked up so far; 0 for not yet. Read directly by the quantiser's loop.
    let table: UnsafeMutablePointer<UInt8>
    /// The same for `beyond`, for the colours dithered so far.
    private let beyondTable: UnsafeMutablePointer<UInt8>

    init(_ palette: GIFPalette) {
        precondition(palette.colors.count <= 255, "A colour map holds at most 255 colours")
        self.palette = palette
        colors = palette.colors
        reds = palette.colors.map { Int($0 >> 16 & 0xFF) }
        greens = palette.colors.map { Int($0 >> 8 & 0xFF) }
        blues = palette.colors.map { Int($0 & 0xFF) }
        table = calloc(1 << 24, 1)!.assumingMemoryBound(to: UInt8.self)
        beyondTable = calloc(1 << 24, 1)!.assumingMemoryBound(to: UInt8.self)
    }

    deinit {
        free(table)
        free(beyondTable)
    }

    /// The index of the colour nearest (r, g, b).
    @inline(__always)
    func index(_ r: Int, _ g: Int, _ b: Int) -> Int {
        let key = r << 16 | g << 8 | b
        let known = table[key]
        if known != 0 { return Int(known) - 1 }
        let found = nearest(r, g, b)
        table[key] = UInt8(found + 1)
        return found
    }

    /// The colour nearest (r, g, b) on its far side from palette colour `first` (its nearest): the one to mix with
    /// `first` to make it; `first` itself when there is none.
    func beyond(_ r: Int, _ g: Int, _ b: Int, from first: Int) -> Int {
        let key = r << 16 | g << 8 | b
        let known = beyondTable[key]
        if known != 0 { return Int(known) - 1 }
        let (er, eg, eb) = (r - reds[first], g - greens[first], b - blues[first])
        var best = first
        var bestDistance = Int.max
        for index in 0..<reds.count where index != first {
            // On the source's side of the first colour.
            let along = (reds[index] - reds[first]) * er + (greens[index] - greens[first]) * eg
                + (blues[index] - blues[first]) * eb
            guard along > 0 else { continue }
            let (dr, dg, db) = (reds[index] - r, greens[index] - g, blues[index] - b)
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        beyondTable[key] = UInt8(best + 1)
        return best
    }

    private func nearest(_ r: Int, _ g: Int, _ b: Int) -> Int {
        var best = 0
        var bestDistance = Int.max
        reds.withUnsafeBufferPointer { reds in
            greens.withUnsafeBufferPointer { greens in
                blues.withUnsafeBufferPointer { blues in
                    for index in 0..<reds.count {
                        let dr = reds[index] - r
                        let dg = greens[index] - g
                        let db = blues[index] - b
                        let distance = dr * dr + dg * dg + db * db
                        if distance < bestDistance {
                            bestDistance = distance
                            best = index
                            if distance == 0 { break }
                        }
                    }
                }
            }
        }
        return best
    }
}

/// Colours counted over 6 bits a channel, with each cell's mean, and the exact colours while there are few.
struct GIFHistogram {
    private static let cells = 1 << 18
    /// At most this many exact colours are followed; beyond it the image is quantised anyway.
    private static let exactLimit = 256
    /// A cell's count stops here, so its sums fit 32 bits; it is dominant by then.
    private static let countLimit: UInt32 = 1 << 24

    private var counts = [UInt32](repeating: 0, count: cells)
    private var sums = [UInt32](repeating: 0, count: cells * 3)
    /// Each cell's first exact colour + 1 (0: empty).
    private var firsts = [UInt32](repeating: 0, count: cells)
    /// The other exact colours of cells that have more than one, while `exactColorCount` ≤ `exactLimit`.
    private var others: [Int: Set<UInt32>] = [:]
    private var exactColorCount = 0

    /// Counts every pixel of `frame`, or one in `step` × `step` of a large one.
    mutating func add(_ frame: GIFFrame, step: Int = 1) {
        let step = max(1, step)
        let (width, height, bytesPerRow) = (frame.width, frame.height, frame.bytesPerRow)
        let countLimit = Self.countLimit
        frame.bgra.withUnsafeBufferPointer { sourceBuffer in
            counts.withUnsafeMutableBufferPointer { countBuffer in
                sums.withUnsafeMutableBufferPointer { sumBuffer in
                    firsts.withUnsafeMutableBufferPointer { firstBuffer in
                        let (source, counts) = (sourceBuffer.baseAddress!, countBuffer.baseAddress!)
                        let (sums, firsts) = (sumBuffer.baseAddress!, firstBuffer.baseAddress!)
                        var y = 0
                        while y < height {
                            let line = source + y * bytesPerRow
                            var x = 0
                            while x < width {
                                let pixel = line + x * 4
                                let (r, g, b) = (UInt32(pixel[2]), UInt32(pixel[1]), UInt32(pixel[0]))
                                let cell = Int(r >> 2) << 12 | Int(g >> 2) << 6 | Int(b >> 2)
                                if counts[cell] < countLimit {
                                    counts[cell] += 1
                                    sums[cell * 3] += r
                                    sums[cell * 3 + 1] += g
                                    sums[cell * 3 + 2] += b
                                }
                                let color = r << 16 | g << 8 | b
                                let first = firsts[cell]
                                if first == 0 {
                                    firsts[cell] = color + 1
                                    exactColorCount += 1
                                } else if first != color + 1, exactColorCount <= Self.exactLimit {
                                    // A second (third…) exact colour in the cell, while the exact colours are followed.
                                    if others[cell, default: []].insert(color).inserted { exactColorCount += 1 }
                                    if exactColorCount > Self.exactLimit { others = [:] }
                                }
                                x += step
                            }
                            y += step
                        }
                    }
                }
            }
        }
    }

    /// Counts the changed pixels of `diff.rect` in `frame`.
    mutating func add(_ frame: GIFFrame, changedIn diff: GIFDiff) {
        let rect = diff.rect
        var pixels: [UInt8] = []
        pixels.reserveCapacity(rect.width * rect.height * 4)
        for row in 0..<rect.height {
            let line = (rect.y + row) * frame.bytesPerRow + rect.x * 4
            for column in 0..<rect.width where diff.changed[row * rect.width + column] {
                pixels += frame.bgra[(line + column * 4)..<(line + column * 4 + 4)]
            }
        }
        guard !pixels.isEmpty else { return }
        add(GIFFrame(width: pixels.count / 4, height: 1, bytesPerRow: pixels.count, bgra: pixels))
    }

    /// At most `colors` (1…255) colours and the transparent index after them. With `noise`, each cell takes in the
    /// lighter cells within half of it (on every channel) around it, heaviest first, and the splitter never parts them.
    func palette(colors requested: Int, mergingWithin noise: Int) -> GIFPalette {
        let limit = min(max(requested, 1), 255)
        let used = (0..<Self.cells).filter { counts[$0] > 0 }
        guard !used.isEmpty else { return GIFPalette(colors: [0], transparentIndex: 1) }
        if exactColorCount <= limit {
            var exact = used.map { (color: firsts[$0] - 1, count: counts[$0]) }
            for cell in used {
                for color in others[cell] ?? [] { exact.append((color, 0)) }
            }
            // By count, ties by colour: the same frames always give the same order (a `Set` iterates as it likes).
            let colors = exact.sorted { $0.count != $1.count ? $0.count > $1.count : $0.color < $1.color }.map(\.color)
            return GIFPalette(colors: colors, transparentIndex: colors.count)
        }
        let points = noise > 0 ? merged(used, radius: Double(noise) / 2) : used.map(point)
        let colors = GIFColorSplitter.colors(for: points, count: limit)
        return GIFPalette(colors: colors, transparentIndex: colors.count)
    }

    private func mean(_ cell: Int) -> (r: Double, g: Double, b: Double) {
        let weight = Double(counts[cell])
        return (Double(sums[cell * 3]) / weight, Double(sums[cell * 3 + 1]) / weight, Double(sums[cell * 3 + 2]) / weight)
    }

    private func point(_ cell: Int) -> GIFColorPoint {
        let (r, g, b) = mean(cell)
        return GIFColorPoint(r: r, g: g, b: b, weight: Double(counts[cell]))
    }

    /// The cells grouped around their heaviest: each one not yet taken takes the cells within `radius` of its mean
    /// (decode noise around one colour lands in a few neighbouring cells), and the group is one point.
    private func merged(_ used: [Int], radius: Double) -> [GIFColorPoint] {
        var taken = [Bool](repeating: false, count: Self.cells)
        // A cell is 4 levels wide, so cells within the radius are at most this many cells away on each channel.
        let reach = Int(radius / 4) + 1
        var points: [GIFColorPoint] = []
        for peak in used.sorted(by: { counts[$0] > counts[$1] }) where !taken[peak] {
            taken[peak] = true
            let center = mean(peak)
            var (weight, r, g, b) = (Double(counts[peak]), 0.0, 0.0, 0.0)
            r = center.r * weight
            g = center.g * weight
            b = center.b * weight
            let (pr, pg, pb) = (peak >> 12, peak >> 6 & 63, peak & 63)
            for nr in max(0, pr - reach)...min(63, pr + reach) {
                for ng in max(0, pg - reach)...min(63, pg + reach) {
                    for nb in max(0, pb - reach)...min(63, pb + reach) {
                        let cell = nr << 12 | ng << 6 | nb
                        guard counts[cell] > 0, !taken[cell] else { continue }
                        let other = mean(cell)
                        guard abs(other.r - center.r) <= radius, abs(other.g - center.g) <= radius,
                              abs(other.b - center.b) <= radius else { continue }
                        taken[cell] = true
                        let w = Double(counts[cell])
                        weight += w
                        r += other.r * w
                        g += other.g * w
                        b += other.b * w
                    }
                }
            }
            points.append(GIFColorPoint(r: r / weight, g: g / weight, b: b / weight, weight: weight))
        }
        return points
    }
}

/// A histogram cell: its mean colour and how many pixels it holds.
struct GIFColorPoint {
    var r: Double
    var g: Double
    var b: Double
    var weight: Double

    func value(_ axis: Int) -> Double {
        axis == 0 ? r : axis == 1 ? g : b
    }
}

/// Splits weighted colours into boxes, each time the box and the cut that remove the most squared error, then moves the
/// boxes' means a few rounds of k-means. The darkest and the lightest colours are kept as they are, so a gradient's ends
/// have a colour beyond them to dither with, and black and white stay exact.
enum GIFColorSplitter {
    static let refinementRounds = 4

    private struct Box {
        var lower: Int
        var upper: Int
        var error: Double
        var splittable: Bool
    }

    private struct Moments {
        var weight = 0.0
        var r = 0.0, g = 0.0, b = 0.0
        var squares = 0.0

        mutating func add(_ point: GIFColorPoint) {
            weight += point.weight
            r += point.r * point.weight
            g += point.g * point.weight
            b += point.b * point.weight
            squares += (point.r * point.r + point.g * point.g + point.b * point.b) * point.weight
        }

        var error: Double {
            weight > 0 ? max(0, squares - (r * r + g * g + b * b) / weight) : 0
        }

        static func - (a: Moments, b: Moments) -> Moments {
            Moments(weight: a.weight - b.weight, r: a.r - b.r, g: a.g - b.g, b: a.b - b.b, squares: a.squares - b.squares)
        }
    }

    private typealias Center = (r: Double, g: Double, b: Double)

    /// At most `count` colours for `input`.
    static func colors(for input: [GIFColorPoint], count: Int) -> [UInt32] {
        guard input.count > count else { return unique(input.map { ($0.r, $0.g, $0.b) }) }
        var points = input
        func luma(_ point: GIFColorPoint) -> Double { 0.299 * point.r + 0.587 * point.g + 0.114 * point.b }
        var anchors: [Center] = []
        if count > 2, let darkest = points.min(by: { luma($0) < luma($1) }),
           let lightest = points.max(by: { luma($0) < luma($1) }) {
            anchors = [(darkest.r, darkest.g, darkest.b), (lightest.r, lightest.g, lightest.b)]
        }
        var boxes = [box(points, 0, points.count)]
        while boxes.count < count - anchors.count {
            guard let chosen = boxes.indices.filter({ boxes[$0].splittable }).max(by: { boxes[$0].error < boxes[$1].error }),
                  boxes[chosen].error > 0 else { break }
            guard let cut = split(&points, boxes[chosen]) else {
                boxes[chosen].splittable = false
                continue
            }
            let parent = boxes[chosen]
            boxes[chosen] = box(points, parent.lower, cut)
            boxes.append(box(points, cut, parent.upper))
        }
        var centers: [Center] = boxes.map { box in
            var moments = Moments()
            for index in box.lower..<box.upper { moments.add(points[index]) }
            return (moments.r / moments.weight, moments.g / moments.weight, moments.b / moments.weight)
        }
        refine(&centers, anchors: anchors, points: points)
        return unique(anchors + centers)
    }

    /// The colours rounded, each once.
    private static func unique(_ centers: [Center]) -> [UInt32] {
        var seen = Set<UInt32>()
        return centers.compactMap { center in
            func channel(_ value: Double) -> UInt32 { UInt32(min(max(value.rounded(), 0), 255)) }
            let color = channel(center.r) << 16 | channel(center.g) << 8 | channel(center.b)
            return seen.insert(color).inserted ? color : nil
        }
    }

    /// A box over `points[lower..<upper]`: its squared error, and whether it has two cells or more to cut between.
    private static func box(_ points: [GIFColorPoint], _ lower: Int, _ upper: Int) -> Box {
        var moments = Moments()
        for index in lower..<upper { moments.add(points[index]) }
        return Box(lower: lower, upper: upper, error: moments.error, splittable: upper - lower > 1)
    }

    /// Sorts the box's points along its widest-spread channel and returns the cut (the first index of the upper part)
    /// that leaves the least squared error on both sides; nil when every cut leaves a side empty.
    private static func split(_ points: inout [GIFColorPoint], _ box: Box) -> Int? {
        var spread = [Double](repeating: 0, count: 3)
        var total = Moments()
        for index in box.lower..<box.upper { total.add(points[index]) }
        for axis in 0..<3 {
            var sum = 0.0, squares = 0.0
            for index in box.lower..<box.upper {
                let value = points[index].value(axis)
                sum += value * points[index].weight
                squares += value * value * points[index].weight
            }
            spread[axis] = squares - sum * sum / total.weight
        }
        let axis = spread.indices.max { spread[$0] < spread[$1] } ?? 0
        points[box.lower..<box.upper].sort { $0.value(axis) < $1.value(axis) }
        var left = Moments()
        var best: (cut: Int, error: Double)?
        for index in box.lower..<(box.upper - 1) {
            left.add(points[index])
            // Never between equal values: they would land on both sides.
            guard points[index].value(axis) < points[index + 1].value(axis) else { continue }
            let error = left.error + (total - left).error
            if best == nil || error < best!.error { best = (index + 1, error) }
        }
        return best?.cut
    }

    /// Lloyd's rounds: each point to its nearest centre or anchor, each centre to its points' mean; anchors stay. A
    /// centre left without points stays where it was.
    private static func refine(_ centers: inout [Center], anchors: [Center], points: [GIFColorPoint]) {
        let fixed = anchors.count
        for _ in 0..<refinementRounds {
            let all = anchors + centers
            var moments = [Moments](repeating: Moments(), count: all.count)
            all.withUnsafeBufferPointer { all in
                for point in points {
                    var best = 0
                    var bestDistance = Double.infinity
                    for index in 0..<all.count {
                        let dr = all[index].r - point.r
                        let dg = all[index].g - point.g
                        let db = all[index].b - point.b
                        let distance = dr * dr + dg * dg + db * db
                        if distance < bestDistance {
                            bestDistance = distance
                            best = index
                        }
                    }
                    moments[best].add(point)
                }
            }
            for index in centers.indices where moments[fixed + index].weight > 0 {
                let m = moments[fixed + index]
                centers[index] = (m.r / m.weight, m.g / m.weight, m.b / m.weight)
            }
        }
    }
}

