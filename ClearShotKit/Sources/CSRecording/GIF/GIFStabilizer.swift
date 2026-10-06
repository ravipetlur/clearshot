/// One decoded source frame: BGRA, 8 bits a channel, rows `bytesPerRow` apart (the alpha is ignored).
public struct GIFFrame: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bgra: [UInt8]

    public init(width: Int, height: Int, bytesPerRow: Int, bgra: [UInt8]) {
        precondition(width > 0 && height > 0 && bytesPerRow >= width * 4 && bgra.count >= (height - 1) * bytesPerRow + width * 4,
                     "The frame's bytes don't cover its size")
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bgra = bgra
    }
}

/// A rectangle of the GIF's canvas, in pixels from its top left.
public struct GIFRect: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// What a frame changes: the rectangle around every change, and which of its pixels changed (row by row).
public struct GIFDiff: Sendable {
    public let rect: GIFRect
    public let changed: [Bool]

    public init(rect: GIFRect, changed: [Bool]) {
        precondition(changed.count == rect.width * rect.height, "The mask doesn't cover the rectangle")
        self.rect = rect
        self.changed = changed
    }
}

/// Keeps a GIF small over a lossy intermediate: a pixel is unchanged while every channel is within `threshold` of the
/// colour the viewer shows there, its palette colour after the frames so far. Unchanged pixels are left transparent, so
/// the decode noise of an unmoving screen never reaches the file. The viewer state (3 bytes a pixel) is all it keeps
/// between frames.
///
/// The loops walk raw pointers with `while`: they run over every pixel of every frame, and stay quick in unoptimised
/// builds too (the tests').
public struct GIFStabilizer: Sendable {
    public let width: Int
    public let height: Int
    public let threshold: Int
    /// What the viewer shows, RGB, row by row.
    private var shown: [UInt8]
    /// Nothing is shown before the first commit, so the first frame changes everything.
    private var hasShown = false

    public init(width: Int, height: Int, threshold: Int) {
        self.width = width
        self.height = height
        self.threshold = max(0, threshold)
        shown = [UInt8](repeating: 0, count: width * height * 3)
    }

    /// What `frame` changes; nil when no pixel moved past the threshold. The first frame changes every pixel.
    public mutating func diff(_ frame: GIFFrame) -> GIFDiff? {
        precondition(frame.width == width && frame.height == height, "The frame isn't the GIF's size")
        guard hasShown else {
            return GIFDiff(rect: GIFRect(x: 0, y: 0, width: width, height: height),
                           changed: [Bool](repeating: true, count: width * height))
        }
        let (width, height, bytesPerRow, threshold) = (width, height, frame.bytesPerRow, threshold)
        return frame.bgra.withUnsafeBufferPointer { sourceBuffer -> GIFDiff? in
            shown.withUnsafeBufferPointer { shownBuffer -> GIFDiff? in
                let source = sourceBuffer.baseAddress!
                let shown = shownBuffer.baseAddress!
                // The bounding rectangle first, then the mask inside it.
                var (minX, minY, maxX, maxY) = (width, height, -1, -1)
                var y = 0
                while y < height {
                    let row = source + y * bytesPerRow
                    let shownRow = shown + y * width * 3
                    var first = 0
                    while first < width, !Self.moved(row + first * 4, shownRow + first * 3, threshold) { first += 1 }
                    if first < width {
                        var last = width - 1
                        while last > first, !Self.moved(row + last * 4, shownRow + last * 3, threshold) { last -= 1 }
                        if first < minX { minX = first }
                        if last > maxX { maxX = last }
                        if minY == height { minY = y }
                        maxY = y
                    }
                    y += 1
                }
                guard maxX >= 0 else { return nil }
                let rect = GIFRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
                var changed = [Bool](repeating: false, count: rect.width * rect.height)
                changed.withUnsafeMutableBufferPointer { maskBuffer in
                    let mask = maskBuffer.baseAddress!
                    var row = 0
                    while row < rect.height {
                        let sourceRow = source + (rect.y + row) * bytesPerRow + rect.x * 4
                        let shownRow = shown + ((rect.y + row) * width + rect.x) * 3
                        let maskRow = mask + row * rect.width
                        var column = 0
                        while column < rect.width {
                            if Self.moved(sourceRow + column * 4, shownRow + column * 3, threshold) { maskRow[column] = true }
                            column += 1
                        }
                        row += 1
                    }
                }
                return GIFDiff(rect: rect, changed: changed)
            }
        }
    }

    /// Whether the BGRA pixel at `source` is more than `threshold` from the RGB one at `shown` on some channel.
    private static func moved(_ source: UnsafePointer<UInt8>, _ shown: UnsafePointer<UInt8>, _ threshold: Int) -> Bool {
        let red = Int(source[2]) - Int(shown[0])
        let green = Int(source[1]) - Int(shown[1])
        let blue = Int(source[0]) - Int(shown[2])
        return red > threshold || red < -threshold || green > threshold || green < -threshold
            || blue > threshold || blue < -threshold
    }

    /// The viewer now shows `indices` (over `diff.rect`) in `palette`'s colours; the transparent index leaves a pixel as
    /// it was.
    public mutating func commit(_ diff: GIFDiff, indices: [UInt8], palette: GIFPalette) {
        let rect = diff.rect
        precondition(indices.count == rect.width * rect.height, "The indices don't cover the rectangle")
        let transparent = palette.transparentIndex ?? -1
        let rgb = Self.channels(palette)
        let width = width
        shown.withUnsafeMutableBufferPointer { shownBuffer in
            indices.withUnsafeBufferPointer { indexBuffer in
                rgb.withUnsafeBufferPointer { rgbBuffer in
                    let (shown, indices, rgb) = (shownBuffer.baseAddress!, indexBuffer.baseAddress!, rgbBuffer.baseAddress!)
                    let count = rgbBuffer.count / 3
                    var row = 0
                    while row < rect.height {
                        let shownRow = shown + ((rect.y + row) * width + rect.x) * 3
                        let indexRow = indices + row * rect.width
                        var column = 0
                        while column < rect.width {
                            let index = Int(indexRow[column])
                            if index != transparent, index < count {
                                let pixel = shownRow + column * 3
                                pixel[0] = rgb[index * 3]
                                pixel[1] = rgb[index * 3 + 1]
                                pixel[2] = rgb[index * 3 + 2]
                            }
                            column += 1
                        }
                        row += 1
                    }
                }
            }
        }
        hasShown = true
    }

    /// Each pixel's distance on its farthest channel (the threshold's measure) from the colour shown there, over
    /// `diff.rect`; nil before the first commit, when nothing is shown.
    func shownDistances(_ frame: GIFFrame, diff: GIFDiff) -> [Int]? {
        guard hasShown else { return nil }
        let rect = diff.rect
        var distances = [Int](repeating: 0, count: rect.width * rect.height)
        let (width, bytesPerRow) = (width, frame.bytesPerRow)
        frame.bgra.withUnsafeBufferPointer { sourceBuffer in
            shown.withUnsafeBufferPointer { shownBuffer in
                distances.withUnsafeMutableBufferPointer { distanceBuffer in
                    let (source, shown, distances) = (sourceBuffer.baseAddress!, shownBuffer.baseAddress!,
                                                      distanceBuffer.baseAddress!)
                    var row = 0
                    while row < rect.height {
                        let sourceRow = source + (rect.y + row) * bytesPerRow + rect.x * 4
                        let shownRow = shown + ((rect.y + row) * width + rect.x) * 3
                        var column = 0
                        while column < rect.width {
                            let (pixel, viewed) = (sourceRow + column * 4, shownRow + column * 3)
                            let red = Int(pixel[2]) - Int(viewed[0])
                            let green = Int(pixel[1]) - Int(viewed[1])
                            let blue = Int(pixel[0]) - Int(viewed[2])
                            let (r, g, b) = (red < 0 ? -red : red, green < 0 ? -green : green, blue < 0 ? -blue : blue)
                            let rg = r > g ? r : g
                            distances[row * rect.width + column] = rg > b ? rg : b
                            column += 1
                        }
                        row += 1
                    }
                }
            }
        }
        return distances
    }

    /// `indices` over `diff.rect` with every pixel outside `mask` made `transparentIndex`, cropped to the mask's
    /// bounds; nil when the mask is empty.
    static func masked(_ diff: GIFDiff, to mask: [Bool], indices: [UInt8], transparentIndex: UInt8)
        -> (diff: GIFDiff, indices: [UInt8])? {
        let rect = diff.rect
        var kept = indices
        var (minX, minY, maxX, maxY) = (rect.width, rect.height, -1, -1)
        mask.withUnsafeBufferPointer { maskBuffer in
            kept.withUnsafeMutableBufferPointer { keptBuffer in
                let (mask, kept) = (maskBuffer.baseAddress!, keptBuffer.baseAddress!)
                var row = 0
                while row < rect.height {
                    var column = 0
                    while column < rect.width {
                        let i = row * rect.width + column
                        if mask[i] {
                            if column < minX { minX = column }
                            if column > maxX { maxX = column }
                            if row < minY { minY = row }
                            maxY = row
                        } else {
                            kept[i] = transparentIndex
                        }
                        column += 1
                    }
                    row += 1
                }
            }
        }
        guard maxX >= 0 else { return nil }
        let cropped = GIFRect(x: rect.x + minX, y: rect.y + minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard cropped != rect else { return (GIFDiff(rect: rect, changed: mask), kept) }
        var croppedIndices = [UInt8](repeating: 0, count: cropped.width * cropped.height)
        var croppedMask = [Bool](repeating: false, count: cropped.width * cropped.height)
        for row in 0..<cropped.height {
            let from = (row + minY) * rect.width + minX
            let to = row * cropped.width
            croppedIndices[to..<(to + cropped.width)] = kept[from..<(from + cropped.width)]
            croppedMask[to..<(to + cropped.width)] = mask[from..<(from + cropped.width)]
        }
        return (GIFDiff(rect: cropped, changed: croppedMask), croppedIndices)
    }

    /// The palette's colours as R, G, B bytes.
    private static func channels(_ palette: GIFPalette) -> [UInt8] {
        palette.colors.flatMap { [UInt8($0 >> 16 & 0xFF), UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF)] }
    }
}
