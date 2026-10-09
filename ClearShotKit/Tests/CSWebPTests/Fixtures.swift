import Foundation
import Testing

/// A small deterministic generator, so a fixture is the same on every run and every machine.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var mixed = state
        mixed ^= mixed >> 33
        mixed = mixed &* 0xFF51_AFD7_ED55_8CCD
        mixed ^= mixed >> 29
        return mixed
    }
}

/// A named, generated image: the unit the parameterised round-trip tests run over.
struct Fixture: Sendable, CustomTestStringConvertible {
    let name: String
    let make: @Sendable () -> RGBAImage

    init(_ name: String, make: @escaping @Sendable () -> RGBAImage) {
        self.name = name
        self.make = make
    }

    var testDescription: String { name }
}

extension RGBAImage {
    /// Fills a rectangle, clipped to the image.
    mutating func fill(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int, _ color: Pixel) {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + rectWidth), y1 = min(height, y + rectHeight)
        guard x0 < x1, y0 < y1 else { return }
        for row in y0..<y1 { for column in x0..<x1 { self[column, row] = color } }
    }

    /// Copies `source` into the image with its top left corner at (`x`, `y`), clipped to the image.
    mutating func paste(_ source: RGBAImage, x: Int, y: Int) {
        for row in 0..<source.height {
            for column in 0..<source.width where (0..<width).contains(x + column) && (0..<height).contains(y + row) {
                self[x + column, y + row] = source[column, row]
            }
        }
    }

    /// A 1-pixel outline of a rectangle, clipped to the image.
    mutating func outline(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int, _ color: Pixel) {
        fill(x: x, y: y, width: rectWidth, height: 1, color)
        fill(x: x, y: y + rectHeight - 1, width: rectWidth, height: 1, color)
        fill(x: x, y: y, width: 1, height: rectHeight, color)
        fill(x: x + rectWidth - 1, y: y, width: 1, height: rectHeight, color)
    }
}

/// The generated test images. Everything here is deterministic and lives in code: there are no fixture files.
enum Fixtures {
    // MARK: Screenshot-like

    /// A window-like image: flat fills and 1-pixel borders, "text" of dark strokes on light in repeated glyph-like
    /// patterns, a 2-colour checkbox grid and a horizontal gradient bar. More than 256 colours once it is about 300
    /// pixels wide, because of the gradient.
    static func uiScreenshot(_ width: Int, _ height: Int) -> RGBAImage {
        ui(width, height, gradient: true)
    }

    /// `uiScreenshot` without the gradient bar: 256 colours or fewer.
    static func uiScreenshotFlat(_ width: Int, _ height: Int) -> RGBAImage {
        ui(width, height, gradient: false)
    }

    private static let glyphs: [[UInt8]] = [
        [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        [0b11110, 0b10001, 0b11110, 0b10001, 0b10001, 0b10001, 0b11110],
        [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110],
        [0b11111, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000, 0b11111],
        [0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001, 0b10001],
        [0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
        [0b00000, 0b01110, 0b00001, 0b01111, 0b10001, 0b10011, 0b01101],
        [0b00000, 0b10110, 0b11001, 0b10001, 0b10001, 0b11001, 0b10110],
    ]

    private static func ui(_ width: Int, _ height: Int, gradient: Bool) -> RGBAImage {
        let paper = Pixel(244, 244, 246), ink = Pixel(28, 28, 32), rule = Pixel(176, 176, 182)
        var image = RGBAImage(width: width, height: height, fill: paper)
        image.outline(x: 0, y: 0, width: width, height: height, Pixel(70, 70, 76))

        // Title bar with three buttons.
        image.fill(x: 1, y: 1, width: width - 2, height: 22, Pixel(226, 226, 232))
        image.fill(x: 1, y: 23, width: width - 2, height: 1, rule)
        for (index, color) in [Pixel(255, 95, 87), Pixel(254, 188, 46), Pixel(40, 200, 64)].enumerated() {
            image.fill(x: 8 + index * 16, y: 6, width: 10, height: 10, color)
        }

        // Sidebar.
        let sidebar = min(width / 5, 160)
        image.fill(x: 1, y: 24, width: sidebar, height: height - 25, Pixel(214, 219, 230))
        image.fill(x: sidebar + 1, y: 24, width: 1, height: height - 25, rule)

        // Text: rows of 5x7 glyphs, a letter every 7 pixels with a gap now and then.
        var rng = SeededGenerator(seed: 7)
        var top = 40
        while top + 7 < height - 110 {
            var left = sidebar + 16
            while left + 6 < width - 16 {
                if Int.random(in: 0..<6, using: &rng) != 0 {
                    let glyph = glyphs[Int.random(in: 0..<glyphs.count, using: &rng)]
                    for (row, bits) in glyph.enumerated() {
                        for column in 0..<5 where bits & (1 << (4 - column)) != 0 {
                            image.fill(x: left + column, y: top + row, width: 1, height: 1, ink)
                        }
                    }
                }
                left += 7
            }
            top += 14
        }

        // A checkbox grid of two colours with a thin grid line.
        let gridLeft = sidebar + 16, gridTop = height - 96
        for row in 0..<4 {
            for column in 0..<16 {
                let checked = (column * 7 + row * 3 + column * row) % 5 < 2
                image.fill(x: gridLeft + column * 13, y: gridTop + row * 13, width: 12, height: 12,
                           checked ? Pixel(30, 120, 240) : Pixel(255, 255, 255))
            }
        }

        if gradient {
            let barWidth = max(1, width - 20)
            for column in 0..<barWidth {
                let t = Double(column) / Double(max(1, barWidth - 1))
                let color = Pixel(UInt8(20 + 220 * t), UInt8(40 + 160 * t * t), UInt8(200 - 170 * t))
                image.fill(x: 10 + column, y: height - 30, width: 1, height: 20, color)
            }
        }
        return image
    }

    // MARK: Screenshots with photographs in them

    /// A window with a banner photograph across it: the `uiScreenshot` with a photo-like block (`noise`) over 90% of
    /// its width and 22% of its height, from 40% of the way down. The rest is flat content and the photograph is a
    /// single band of rows in the middle, so an estimate made from a few bands of rows at the top, the middle thirds'
    /// edges and the bottom does not see it (at 1200 x 800 the old sample's bands were rows 0-53, 248-301, 497-550
    /// and 746-799, and the photograph is rows 320-495).
    static func uiScreenshotWithPhoto(_ width: Int, _ height: Int) -> RGBAImage {
        var image = uiScreenshot(width, height)
        image.paste(noise(width * 9 / 10, height * 22 / 100, seed: 21), x: width / 20, y: height * 40 / 100)
        return image
    }

    /// A tall article: the flat UI with three photographs in it, each 85% of the width and 12% of the height, from
    /// 10%, 40% and 70% of the way down. At 400 x 3200 the old sample's bands were rows 0-162, 1012-1174, 2024-2186
    /// and 3037-3199, none of which touches a photograph.
    static func articleWithPhotos(_ width: Int, _ height: Int) -> RGBAImage {
        var image = uiScreenshotFlat(width, height)
        for (index, top) in [10, 40, 70].enumerated() {
            image.paste(noise(width * 85 / 100, height * 12 / 100, seed: UInt64(30 + index)), x: width * 7 / 100,
                        y: height * top / 100)
        }
        return image
    }

    // MARK: Noise, alpha, palettes

    /// Photo-like content, opaque: a smooth field with a little noise on every pixel, the way a photograph is. The
    /// field is a brightness and a small colour cast for each channel, each on a coarse lattice (one point every 40
    /// pixels) and blended bilinearly, so the three channels move together and neighbouring pixels differ by a few
    /// levels. The noise is mostly shared by the channels (up to 2 levels) with a little of its own in each (1), as a
    /// camera sensor's brightness noise is. The colours are still nearly all different. Deterministic from `seed`.
    static func noise(_ width: Int, _ height: Int, seed: UInt64) -> RGBAImage {
        var rng = SeededGenerator(seed: seed)
        let cell = 40
        let columns = (width - 1) / cell + 2, rows = (height - 1) / cell + 2
        // Four values to a lattice point: the brightness, then the red, green and blue casts.
        let lattice = (0..<(columns * rows * 4)).map { index in
            index % 4 == 0 ? Int.random(in: 50...205, using: &rng) : Int.random(in: -25...25, using: &rng)
        }
        func blend(_ row: Int, _ column: Int, _ fx: Int, _ fy: Int, _ value: Int) -> Int {
            let topLeft = lattice[(row * columns + column) * 4 + value]
            let topRight = lattice[(row * columns + column + 1) * 4 + value]
            let bottomLeft = lattice[((row + 1) * columns + column) * 4 + value]
            let bottomRight = lattice[((row + 1) * columns + column + 1) * 4 + value]
            let top = topLeft * (cell - fx) + topRight * fx
            let bottom = bottomLeft * (cell - fx) + bottomRight * fx
            return (top * (cell - fy) + bottom * fy + cell * cell / 2) / (cell * cell)
        }
        var image = RGBAImage(width: width, height: height)
        for y in 0..<height {
            let row = y / cell, fy = y % cell
            for x in 0..<width {
                let column = x / cell, fx = x % cell
                let brightness = blend(row, column, fx, fy, 0)
                let shared = Int.random(in: -2...2, using: &rng)
                var channels = [0, 0, 0]
                for channel in 0..<3 {
                    let value = brightness + blend(row, column, fx, fy, channel + 1) + shared
                        + Int.random(in: -1...1, using: &rng)
                    channels[channel] = min(255, max(0, value))
                }
                image[x, y] = Pixel(UInt8(channels[0]), UInt8(channels[1]), UInt8(channels[2]))
            }
        }
        return image
    }

    /// Uniform random RGB, opaque: no neighbour tells anything about the next, and hardly a colour comes twice. The
    /// worst case for every model the encoder has.
    static func randomNoise(_ width: Int, _ height: Int, seed: UInt64) -> RGBAImage {
        var rng = SeededGenerator(seed: seed)
        var image = RGBAImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                image[x, y] = Pixel(UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng),
                                    UInt8.random(in: 0...255, using: &rng))
            }
        }
        return image
    }

    /// Alpha rising from 0 on the left edge to 255 on the right (every 8-bit value on a wide image), with RGB varying
    /// in both directions.
    static func alphaGradient(_ width: Int, _ height: Int) -> RGBAImage {
        var image = RGBAImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let alpha = width > 1 ? x * 255 / (width - 1) : 128
                image[x, y] = Pixel(UInt8((x * 3 + y * 5) & 255), UInt8((y * 11 + 40) & 255),
                                    UInt8(((x ^ y) * 7) & 255), UInt8(alpha))
            }
        }
        return image
    }

    /// Alpha only ever 0 or 255, in blocks, with varied RGB (also where it is invisible).
    static func binaryAlpha(_ width: Int, _ height: Int) -> RGBAImage {
        var image = RGBAImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let visible = (x / 3 + y / 2) % 3 != 0
                image[x, y] = Pixel(UInt8((x * 13 + 7) & 255), UInt8((y * 29 + 3) & 255), UInt8((x + y * 5) & 255),
                                    visible ? 255 : 0)
            }
        }
        return image
    }

    /// Every pixel alpha 0, with varied RGB.
    static func allTransparent(_ width: Int, _ height: Int) -> RGBAImage {
        var image = RGBAImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                image[x, y] = Pixel(UInt8((x * 31 + 1) & 255), UInt8((y * 17 + 9) & 255), UInt8((x * y) & 255), 0)
            }
        }
        return image
    }

    /// Exactly `colors` distinct colours (some translucent, none fully transparent) laid out so that neighbours differ
    /// and no run is long. Needs `width * height >= colors`.
    static func palette(_ colors: Int, _ width: Int, _ height: Int) -> RGBAImage {
        precondition(colors >= 1 && width * height >= colors)
        let table: [Pixel] = (0..<colors).map { index in
            let alpha: UInt8 = index % 3 == 1 ? UInt8(64 + (index * 29) % 160) : 255
            return Pixel(UInt8(index & 255), UInt8((index * 53 + (index >> 8) * 17) & 255),
                         UInt8((index * 91 + (index >> 8) * 40) & 255), alpha)
        }
        // A step coprime with `colors` visits every colour in the first `colors` pixels; after that the arrangement
        // mixes in the row so it is not a plain repetition.
        var step = 7
        while colors > 1, gcd(step, colors) != 1 { step += 2 }
        var image = RGBAImage(width: width, height: height)
        for index in 0..<(width * height) {
            let slot = index < colors ? (index * step) % colors : (index * step + index / width * 3) % colors
            image[index % width, index / width] = table[slot]
        }
        return image
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    // MARK: Repetition

    /// Long runs of one colour, in raster order, some longer than 4 096 pixels so that maximum-length matches occur.
    static func runs(_ width: Int, _ height: Int) -> RGBAImage {
        let lengths = [5000, 4097, 9000, 1, 6000, 7000, 3, 4096]
        let colors = [Pixel(250, 250, 250), Pixel(20, 60, 180), Pixel(250, 250, 250), Pixel(200, 30, 30),
                      Pixel(0, 0, 0, 0), Pixel(30, 160, 80, 128), Pixel(255, 255, 0), Pixel(90, 90, 90)]
        var image = RGBAImage(width: width, height: height)
        var segment = 0, left = lengths[0]
        for index in 0..<(width * height) {
            if left == 0 {
                segment = (segment + 1) % lengths.count
                left = lengths[segment]
            }
            image[index % width, index / width] = colors[segment]
            left -= 1
        }
        return image
    }

    /// The same 7x5 tile stamped at many offsets over a flat background, clipped at the edges (so the narrow widths
    /// 1, 2, 3 and 8 cut it too).
    static func repeatedTiles(_ width: Int, _ height: Int) -> RGBAImage {
        var rng = SeededGenerator(seed: 99)
        let inks = [Pixel(20, 20, 24), Pixel(200, 40, 40), Pixel(40, 90, 200), Pixel(250, 190, 30),
                    Pixel(60, 160, 90, 160)]
        var tile: [Pixel] = []
        for _ in 0..<(7 * 5) { tile.append(inks[Int.random(in: 0..<inks.count, using: &rng)]) }
        var image = RGBAImage(width: width, height: height, fill: Pixel(250, 250, 250))
        func stamp(at originX: Int, _ originY: Int) {
            for row in 0..<5 {
                for column in 0..<7 {
                    image.fill(x: originX + column, y: originY + row, width: 1, height: 1, tile[row * 7 + column])
                }
            }
        }
        // A scatter of odd offsets first, then a regular lattice on top (the same horizontal and vertical distances
        // recur, and nothing overwrites a lattice tile).
        for index in 0..<60 {
            stamp(at: (index * 13) % (width + 6) - 3, (index * 9) % (height + 4) - 2)
        }
        for originY in stride(from: 0, to: height, by: 9) {
            for originX in stride(from: 0, to: width, by: 11) { stamp(at: originX, originY) }
        }
        return image
    }

    // MARK: The catalogue every round-trip test runs over

    /// Every kind of image the encoder meets, at a size that keeps a literal-only encode quick. The two longest shapes
    /// are in `shapes`.
    static let catalogue: [Fixture] = {
        var list: [Fixture] = [
            Fixture("ui 640x360") { uiScreenshot(640, 360) },
            Fixture("ui flat 640x360") { uiScreenshotFlat(640, 360) },
            Fixture("ui 17x33") { uiScreenshot(17, 33) },
            Fixture("noise 100x80") { noise(100, 80, seed: 1) },
            Fixture("noise 31x7") { noise(31, 7, seed: 2) },
            Fixture("random noise 100x80") { randomNoise(100, 80, seed: 1) },
            Fixture("random noise 310x70") { randomNoise(310, 70, seed: 2) },
            Fixture("alpha gradient 256x64") { alphaGradient(256, 64) },
            Fixture("alpha gradient 50x1") { alphaGradient(50, 1) },
            Fixture("binary alpha 97x61") { binaryAlpha(97, 61) },
            Fixture("all transparent 33x17") { allTransparent(33, 17) },
            Fixture("runs 200x150") { runs(200, 150) },
            Fixture("runs 1x9000") { runs(1, 9000) },
        ]
        for colors in [1, 2, 3, 4, 5, 16, 17, 256, 257] {
            list.append(Fixture("palette \(colors) 40x30") { palette(colors, 40, 30) })
        }
        // An odd width with each bundle size (8, 4 and 2 indices to a pixel), so the last pixel of a row holds fewer
        // indices than the rest and the rows have to be packed apart; 40 is a multiple of every bundle size.
        for colors in [2, 3, 4, 5, 16] {
            list.append(Fixture("palette \(colors) 17x9") { palette(colors, 17, 9) })
        }
        for width in [1, 2, 3, 8, 64] {
            list.append(Fixture("repeated tiles \(width)x40") { repeatedTiles(width, 40) })
        }
        return list
    }()

    /// The shapes: 1x1, 1xN, Nx1, 17x33, 1001x999 and the two longest the encoder writes, 16383x1 and 1x16383.
    static let shapes: [Fixture] = [
        Fixture("1x1 opaque") { noise(1, 1, seed: 5) },
        Fixture("1x1 translucent") { alphaGradient(1, 1) },
        Fixture("1x1 transparent") { allTransparent(1, 1) },
        Fixture("1x37 noise") { noise(1, 37, seed: 6) },
        Fixture("1x37 alpha") { alphaGradient(1, 37) },
        Fixture("37x1 noise") { noise(37, 1, seed: 7) },
        Fixture("37x1 alpha") { alphaGradient(37, 1) },
        Fixture("17x33 noise") { noise(17, 33, seed: 8) },
        Fixture("17x33 alpha") { alphaGradient(17, 33) },
        Fixture("1001x999 ui") { uiScreenshot(1001, 999) },
        Fixture("1001x999 noise") { noise(1001, 999, seed: 9) },
        Fixture("1001x999 random") { randomNoise(1001, 999, seed: 12) },
        Fixture("16383x1 noise") { noise(16383, 1, seed: 10) },
        Fixture("16383x1 random") { randomNoise(16383, 1, seed: 13) },
        Fixture("16383x1 alpha") { alphaGradient(16383, 1) },
        Fixture("1x16383 noise") { noise(1, 16383, seed: 11) },
        Fixture("1x16383 random") { randomNoise(1, 16383, seed: 14) },
        Fixture("1x16383 alpha") { alphaGradient(1, 16383) },
    ]
}
