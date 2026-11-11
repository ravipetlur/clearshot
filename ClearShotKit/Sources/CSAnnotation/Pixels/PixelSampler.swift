import CoreGraphics
import Foundation

/// A direction across a picture as it is shown: x grows to the right, y downward.
public enum PixelDirection: CaseIterable, Sendable {
    case left, right, up, down

    /// One pixel's step in this direction.
    public var step: (dx: Int, dy: Int) {
        switch self {
        case .left: (-1, 0)
        case .right: (1, 0)
        case .up: (0, -1)
        case .down: (0, 1)
        }
    }
}

/// An immutable copy of a picture's pixels, made once from a `CGImage`, for the tools that read the picture: the color at a
/// point, the average or darkest color of an area, the distance to an edge, the extent of a flat-colored region.
///
/// **Pixels.** Each pixel is four bytes, red, green, blue, alpha, in sRGB with **premultiplied** alpha, rows top first: the
/// layout Core Graphics draws into, so the copy is one draw and colors are converted to sRGB on the way in (a Display P3
/// picture reads as the sRGB colors that show the same). Colors come out un-premultiplied, as `RGBAColor`s. Comparisons
/// (edges, flood fills) use the stored bytes, so a fully transparent pixel matches every other fully transparent one.
///
/// **Coordinates** are the sampler's own pixels: x to the right, y down, from the top-left corner; pixel (x, y) covers the
/// square from (x, y) to (x + 1, y + 1). A point falls in the pixel under it (its coordinates rounded down), and a rect is
/// rounded out to the whole pixels it touches and cut to the picture. `PicturePixels` puts a document's base pixels on top.
///
/// **Tolerance** is how far a color may be from the reference color and still count as the same: the largest difference in
/// any one of the four channels, 0...255 (0 is the exact color).
///
/// Every call reads the buffer only: no Core Graphics work after `init`, and nothing allocated but the flood fill's own
/// bookkeeping. Sendable, so it can be made off the main actor and read anywhere.
public struct PixelSampler: Sendable {
    public let width: Int
    public let height: Int
    /// The pixels, `width * height * 4` bytes, laid out as described above.
    private let bytes: [UInt8]

    /// The most pixels a sampler holds: 16 384 × 16 384, a gigabyte of bytes. A larger picture gets no sampler.
    public static let maximumPixelCount = 16_384 * 16_384

    /// The picture's pixels, drawn once into an sRGB RGBA8 premultiplied buffer. Nil when the image is empty, larger than
    /// `maximumPixelCount`, or can't be drawn.
    public init?(image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= Self.maximumPixelCount,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var drawn = false
        let bytes = [UInt8](unsafeUninitializedCapacity: width * height * 4) { buffer, count in
            count = width * height * 4
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                buffer.initialize(repeating: 0)
                return
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            // The context is y-up with its first byte at the top-left, so drawing the image unflipped gives rows top first.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            drawn = true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, premultipliedRGBA: bytes)
    }

    /// A sampler over bytes already in the sampler's layout (`width * height * 4` bytes, sRGB, premultiplied RGBA, rows top
    /// first). Nil when the count doesn't match or a side isn't positive.
    public init?(width: Int, height: Int, premultipliedRGBA bytes: [UInt8]) {
        guard width > 0, height > 0, width * height <= Self.maximumPixelCount, bytes.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public var size: CGSize { CGSize(width: width, height: height) }

    /// The whole picture, in the sampler's pixels.
    public var bounds: CGRect { CGRect(origin: .zero, size: size) }

    // MARK: Single pixels

    /// One pixel's stored bytes: sRGB, premultiplied by alpha.
    public struct Pixel: Equatable, Hashable, Sendable {
        public var red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// The color, un-premultiplied. A fully transparent pixel is transparent black.
        public var color: RGBAColor {
            guard alpha > 0 else { return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0) }
            let a = Double(alpha)
            return RGBAColor(red: min(Double(red) / a, 1), green: min(Double(green) / a, 1), blue: min(Double(blue) / a, 1),
                             alpha: a / 255)
        }

        /// Whether `other` is within `tolerance` of this pixel in every channel.
        public func matches(_ other: Pixel, tolerance: Int) -> Bool {
            abs(Int(red) - Int(other.red)) <= tolerance && abs(Int(green) - Int(other.green)) <= tolerance
                && abs(Int(blue) - Int(other.blue)) <= tolerance && abs(Int(alpha) - Int(other.alpha)) <= tolerance
        }
    }

    /// Whether (x, y) is a pixel of the picture.
    public func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    /// The pixel at (x, y), or nil outside the picture.
    public func pixel(x: Int, y: Int) -> Pixel? {
        guard contains(x: x, y: y) else { return nil }
        return unchecked(x: x, y: y)
    }

    /// The pixel at a point (the one under it), or nil outside the picture or for a point that isn't finite.
    public func pixel(at point: CGPoint) -> Pixel? {
        guard let (x, y) = Self.index(of: point) else { return nil }
        return pixel(x: x, y: y)
    }

    /// The color of the pixel under `point`, or nil outside the picture.
    public func color(at point: CGPoint) -> RGBAColor? {
        pixel(at: point)?.color
    }

    // MARK: Areas

    /// The pixels `rect` touches, inside the picture, as whole-pixel bounds; nil when that is none.
    public func pixelRange(of rect: CGRect) -> (x: Range<Int>, y: Range<Int>)? {
        guard !rect.isNull, [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite) else { return nil }
        let minX = max(0, Int(rect.minX.rounded(.down))), maxX = min(width, Int(rect.maxX.rounded(.up)))
        let minY = max(0, Int(rect.minY.rounded(.down))), maxY = min(height, Int(rect.maxY.rounded(.up)))
        // A rect of no width still touches the pixels its line runs through.
        let endX = maxX == minX && minX < width ? minX + 1 : maxX
        let endY = maxY == minY && minY < height ? minY + 1 : maxY
        guard minX < endX, minY < endY else { return nil }
        return (minX..<endX, minY..<endY)
    }

    /// The average color of the pixels in `rect`, weighted by alpha (a transparent pixel adds nothing to the color, only to
    /// the transparency). Nil when `rect` holds no pixel of the picture.
    public func average(in rect: CGRect) -> RGBAColor? {
        guard let range = pixelRange(of: rect) else { return nil }
        var sums = (red: 0, green: 0, blue: 0, alpha: 0)
        bytes.withUnsafeBufferPointer { buffer in
            for y in range.y {
                var index = (y * width + range.x.lowerBound) * 4
                for _ in range.x {
                    sums.red += Int(buffer[index])
                    sums.green += Int(buffer[index + 1])
                    sums.blue += Int(buffer[index + 2])
                    sums.alpha += Int(buffer[index + 3])
                    index += 4
                }
            }
        }
        guard sums.alpha > 0 else { return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0) }
        let count = Double(range.x.count * range.y.count)
        let alpha = Double(sums.alpha)
        return RGBAColor(red: min(Double(sums.red) / alpha, 1), green: min(Double(sums.green) / alpha, 1),
                         blue: min(Double(sums.blue) / alpha, 1), alpha: alpha / 255 / count)
    }

    /// The color of the darkest pixel in `rect`, by relative luminance (WCAG's): a block of text's ink, under a cursor. Fully
    /// transparent pixels have no color and are skipped. The first such pixel, reading rows top first, wins a tie. Nil when
    /// `rect` holds no pixel of the picture, or only transparent ones.
    public func darkest(in rect: CGRect) -> RGBAColor? {
        guard let range = pixelRange(of: rect) else { return nil }
        let linear = Self.linearTable
        var best: (luminance: Double, pixel: Pixel)?
        bytes.withUnsafeBufferPointer { buffer in
            for y in range.y {
                var index = (y * width + range.x.lowerBound) * 4
                for _ in range.x {
                    defer { index += 4 }
                    let alpha = Int(buffer[index + 3])
                    guard alpha > 0 else { continue }
                    func channel(_ offset: Int) -> Double {
                        // Un-premultiplied, back to a byte, then linear light.
                        linear[min(255, (Int(buffer[index + offset]) * 255 + alpha / 2) / alpha)]
                    }
                    let luminance = 0.2126 * channel(0) + 0.7152 * channel(1) + 0.0722 * channel(2)
                    if let current = best, current.luminance <= luminance { continue }
                    best = (luminance, Pixel(red: buffer[index], green: buffer[index + 1], blue: buffer[index + 2],
                                             alpha: buffer[index + 3]))
                }
            }
        }
        return best?.pixel.color
    }

    // MARK: Edges and regions

    /// How far the color under `point` reaches in `direction`: the distance in pixels from that pixel to the first pixel whose
    /// color differs from it by more than `tolerance`. 1 when the neighbouring pixel already differs. When every pixel up to
    /// the picture's border matches, the distance is to the first pixel past the border, as if it differed.
    ///
    /// So the run of matching pixels from the start pixel that way is `distance` pixels long, the start included; the
    /// boundary lies `distance` pixels from the start pixel's near side (right or down) and `distance - 1` from its far side
    /// (left or up). Measuring both ways along one axis, the run between the two edges is `left + right - 1` pixels wide.
    /// Nil when `point` is outside the picture.
    public func edge(from point: CGPoint, direction: PixelDirection, tolerance: Int) -> Int? {
        guard let (x, y) = Self.index(of: point), contains(x: x, y: y) else { return nil }
        let reference = unchecked(x: x, y: y)
        let (dx, dy) = direction.step
        var distance = 1
        var cx = x + dx, cy = y + dy
        while contains(x: cx, y: cy), unchecked(x: cx, y: cy).matches(reference, tolerance: tolerance) {
            distance += 1
            cx += dx
            cy += dy
        }
        return distance
    }

    /// The bounds of the region of pixels connected to the one under `point` (sharing a side, not only a corner) whose colors
    /// are within `tolerance` of that pixel's: a flat-colored button, a panel, a text field. In whole pixels.
    ///
    /// The fill stops counting at `maxPixels`: a region larger than that returns nil, as does a `point` outside the picture,
    /// so a click on a large background costs at most that much work. Every pixel is compared with the start pixel, not
    /// with its neighbour, so a gradient doesn't carry the region across the picture.
    public func floodFillBounds(from point: CGPoint, tolerance: Int, maxPixels: Int) -> CGRect? {
        guard let (startX, startY) = Self.index(of: point), contains(x: startX, y: startY), maxPixels > 0 else { return nil }
        let reference = unchecked(x: startX, y: startY)
        // One bit per pixel. calloc's zeroed pages are only committed when written, so a fill near one spot of a 16k picture
        // touches only the rows it reaches.
        let words = (width * height + 63) / 64
        guard let visited = calloc(words, MemoryLayout<UInt64>.size)?.bindMemory(to: UInt64.self, capacity: words) else { return nil }
        defer { free(visited) }
        func isVisited(_ index: Int) -> Bool { visited[index >> 6] & (1 << UInt64(index & 63)) != 0 }
        func visit(_ index: Int) { visited[index >> 6] |= 1 << UInt64(index & 63) }

        return bytes.withUnsafeBufferPointer { buffer -> CGRect? in
            func matches(_ x: Int, _ y: Int) -> Bool {
                let index = (y * width + x) * 4
                return abs(Int(buffer[index]) - Int(reference.red)) <= tolerance
                    && abs(Int(buffer[index + 1]) - Int(reference.green)) <= tolerance
                    && abs(Int(buffer[index + 2]) - Int(reference.blue)) <= tolerance
                    && abs(Int(buffer[index + 3]) - Int(reference.alpha)) <= tolerance
            }
            func open(_ x: Int, _ y: Int) -> Bool { !isVisited(y * width + x) && matches(x, y) }

            // A scanline fill: each seed grows into the whole run of its row, and seeds the runs touching it above and below.
            var seeds = [(startX, startY)]
            var count = 0
            var minX = startX, maxX = startX, minY = startY, maxY = startY
            while let (x, y) = seeds.popLast() {
                guard open(x, y) else { continue }
                var left = x, right = x
                while left > 0, open(left - 1, y) { left -= 1 }
                while right < width - 1, open(right + 1, y) { right += 1 }
                for column in left...right { visit(y * width + column) }
                count += right - left + 1
                if count > maxPixels { return nil }
                minX = min(minX, left); maxX = max(maxX, right)
                minY = min(minY, y); maxY = max(maxY, y)
                for row in [y - 1, y + 1] where row >= 0 && row < height {
                    var inRun = false
                    for column in left...right {
                        if open(column, row) {
                            if !inRun { seeds.append((column, row)) }
                            inRun = true
                        } else {
                            inRun = false
                        }
                    }
                }
            }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }

    // MARK: Helpers

    /// The pixel a point falls in, or nil for a point that isn't finite or lies beyond any picture.
    static func index(of point: CGPoint) -> (Int, Int)? {
        guard point.x.isFinite, point.y.isFinite, abs(point.x) < 1e9, abs(point.y) < 1e9 else { return nil }
        return (Int(point.x.rounded(.down)), Int(point.y.rounded(.down)))
    }

    private func unchecked(x: Int, y: Int) -> Pixel {
        let index = (y * width + x) * 4
        return bytes.withUnsafeBufferPointer { buffer in
            Pixel(red: buffer[index], green: buffer[index + 1], blue: buffer[index + 2], alpha: buffer[index + 3])
        }
    }

    /// Each sRGB byte in linear light, for luminance.
    private static let linearTable: [Double] = (0...255).map { byte in
        let value = Double(byte) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
