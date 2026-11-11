import Accelerate
import CoreGraphics
import CSCapture
import Foundation

/// Erase: an area filled from the pixels around it, so what was there is gone and the picture reads as if it never had it.
/// It is made from a ring `ringDepth` pixels deep just outside the area and nothing else, so no pixel under the area can
/// show in it. Where the ring is all one colour (within `flatTolerance`), the area is that colour, flat. Otherwise each
/// pixel blends two straight-line fills: across its row, from the ring on the left to the ring on the right, and down its
/// column, from the ring above to the ring below, each weighted by how near the pixel is to that pair's sides, so the
/// fill meets the ring without a seam. At the picture's edge only the sides that exist are used. Deterministic: the same
/// picture and area always give the same pixels.
///
/// A function of the picture and an area only, so it can fill any area: a redaction's, or each word's.
enum EraseFill {
    /// How many pixels deep the ring read around the area is.
    static let ringDepth = 2
    /// The most a channel (0 to 255) may vary across the ring for the area to be filled flat with the ring's mean.
    static let flatTolerance = 8

    /// The fill for `region` (base pixels, y down, as the other effects take it), the size of the part of it on the
    /// picture, premultiplied, in the picture's colour space where it is RGB. Nil when the region misses the picture or
    /// a bitmap can't be made.
    static func image(_ base: CGImage, region: CGRect) -> CGImage? {
        let width = base.width
        let height = base.height
        let area = region.standardized.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        let x0 = Int(area.minX), y0 = Int(area.minY), w = Int(area.width), h = Int(area.height)
        guard let context = ImageOps.bitmapContext(width: w, height: h, preferring: base.colorSpace),
              let space = context.colorSpace, let data = context.data else { return nil }
        let depth = (left: min(ringDepth, x0), right: min(ringDepth, width - x0 - w),
                     top: min(ringDepth, y0), bottom: min(ringDepth, height - y0 - h))
        var stats = RingStats()
        // Each side as one value per row (left, right) or per column (top, bottom): the mean of the ring pixels there.
        func side(_ rect: CGRect, perRow: Bool) -> [Float]? {
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            return means(of: base, in: rect, perRow: perRow, space: space, stats: &stats)
        }
        let left = side(CGRect(x: x0 - depth.left, y: y0, width: depth.left, height: h), perRow: true)
        let right = side(CGRect(x: x0 + w, y: y0, width: depth.right, height: h), perRow: true)
        let top = side(CGRect(x: x0, y: y0 - depth.top, width: w, height: depth.top), perRow: false)
        let bottom = side(CGRect(x: x0, y: y0 + h, width: w, height: depth.bottom), perRow: false)
        // A ring that couldn't be read leaves the area black, as a failed effect does; it never shows the picture.
        if (depth.left > 0 && left == nil) || (depth.right > 0 && right == nil) || (depth.top > 0 && top == nil)
            || (depth.bottom > 0 && bottom == nil) {
            return nil
        }

        let rowBytes = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: rowBytes * h)
        if stats.count == 0 || stats.isFlat(within: flatTolerance) {
            // No ring at all (the area is the whole picture) is filled black.
            fillFlat(pixels, width: w, height: h, rowBytes: rowBytes, color: stats.count == 0 ? [0, 0, 0, 255] : stats.mean)
        } else {
            fillInterpolated(pixels, width: w, height: h, rowBytes: rowBytes,
                             horizontal: Pair(first: left, second: right, firstDepth: depth.left, secondDepth: depth.right),
                             vertical: Pair(first: top, second: bottom, firstDepth: depth.top, secondDepth: depth.bottom))
        }
        return context.makeImage()
    }

    /// The minimum, maximum and sum of every channel over every ring pixel read.
    private struct RingStats {
        var low: [Int] = [255, 255, 255, 255]
        var high: [Int] = [0, 0, 0, 0]
        var sums: [Int] = [0, 0, 0, 0]
        var count = 0

        func isFlat(within tolerance: Int) -> Bool {
            (0..<4).allSatisfy { high[$0] - low[$0] <= tolerance }
        }

        var mean: [UInt8] {
            (0..<4).map { UInt8((sums[$0] + count / 2) / count) }
        }
    }

    /// The pixels of `rect` (y down) averaged across the strip: four floats a row when `perRow`, else four a column.
    private static func means(of base: CGImage, in rect: CGRect, perRow: Bool, space: CGColorSpace,
                              stats: inout RingStats) -> [Float]? {
        guard let crop = base.cropping(to: rect) else { return nil }
        let width = Int(rect.width), height = Int(rect.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let count = perRow ? height : width
        let across = perRow ? width : height
        var sums = [Int](repeating: 0, count: count * 4)
        var low = stats.low, high = stats.high, total = stats.sums
        bytes.withUnsafeBufferPointer { bytes in
            sums.withUnsafeMutableBufferPointer { sums in
                for y in 0..<height {
                    for x in 0..<width {
                        let source = (y * width + x) * 4
                        let target = (perRow ? y : x) * 4
                        for channel in 0..<4 {
                            let value = Int(bytes[source + channel])
                            sums[target + channel] += value
                            total[channel] += value
                            low[channel] = min(low[channel], value)
                            high[channel] = max(high[channel], value)
                        }
                    }
                }
            }
        }
        stats.low = low
        stats.high = high
        stats.sums = total
        stats.count += width * height
        return sums.map { Float($0) / Float(across) }
    }

    private static func fillFlat(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, rowBytes: Int, color: [UInt8]) {
        for x in 0..<width {
            for channel in 0..<4 { pixels[x * 4 + channel] = color[channel] }
        }
        for y in 1..<max(height, 1) {
            (pixels + y * rowBytes).update(from: pixels, count: width * 4)
        }
    }

    /// The ring on two opposite sides of the area (either may be missing, at the picture's edge), and how deep each is.
    private struct Pair {
        var first: [Float]?
        var second: [Float]?
        var firstDepth: Int
        var secondDepth: Int

        var exists: Bool { first != nil || second != nil }

        /// For each of `length` pixels along the axis between the sides: where it lies from the first side's ring to the
        /// second's (0 to 1), and its distance to the nearer side there is.
        func positions(_ length: Int) -> (fraction: [Float], distance: [Float]) {
            // The middle of each side's ring, measured from the area's first edge.
            let start = -Float(firstDepth) / 2
            let end = Float(length) + Float(secondDepth) / 2
            var fraction = [Float](repeating: 0, count: length)
            var distance = [Float](repeating: 0, count: length)
            for index in 0..<length {
                let centre = Float(index) + 0.5
                fraction[index] = (centre - start) / (end - start)
                switch (first != nil, second != nil) {
                case (true, true): distance[index] = min(centre, Float(length) - centre)
                case (true, false): distance[index] = centre
                default: distance[index] = Float(length) - centre
                }
            }
            return (fraction, distance)
        }

        /// The ring at `index` along the sides, `fraction` of the way from the first side to the second (one side alone
        /// is used as it is).
        func value(_ index: Int, _ channel: Int, _ fraction: Float) -> Float {
            switch (first, second) {
            case (let first?, let second?):
                let a = first[index * 4 + channel]
                return a + (second[index * 4 + channel] - a) * fraction
            case (let first?, nil): return first[index * 4 + channel]
            case (nil, let second?): return second[index * 4 + channel]
            case (nil, nil): return 0
            }
        }
    }

    /// Every pixel of the area: the row's fill between `horizontal`'s sides and the column's between `vertical`'s,
    /// weighted toward the pair whose side is nearer (or the one that exists). A row at a time, with vector operations,
    /// so a 6K-wide area takes milliseconds.
    private static func fillInterpolated(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, rowBytes: Int,
                                         horizontal: Pair, vertical: Pair) {
        let count = width * 4
        let length = vDSP_Length(count)
        let columns = horizontal.positions(width)
        let rows = vertical.positions(height)
        let hasRowFill = horizontal.exists, hasColumnFill = vertical.exists
        // The top and bottom rings, a missing one standing in for the other (its fraction then doesn't matter).
        let top = vertical.first ?? vertical.second ?? [Float](repeating: 0, count: count)
        let bottom = vertical.second ?? vertical.first ?? [Float](repeating: 0, count: count)
        // Each pixel's distance to the nearer left or right side, once per channel.
        let xDistance = columns.distance.flatMap { [$0, $0, $0, $0] }
        // This row's fill across it, the fill down the columns at this row, and the row's weight at each pixel.
        var rowFill = [Float](repeating: 0, count: count)
        var columnFill = [Float](repeating: 0, count: count)
        var weight = [Float](repeating: 0, count: count)
        var blended = [Float](repeating: 0, count: count)
        var clipped = [Float](repeating: 0, count: count)
        for y in 0..<height {
            if hasRowFill {
                for channel in 0..<4 {
                    var start = horizontal.value(y, channel, 0)
                    var slope = horizontal.value(y, channel, 1) - start
                    rowFill.withUnsafeMutableBufferPointer { rowFill in
                        vDSP_vsmsa(columns.fraction, 1, &slope, &start, rowFill.baseAddress! + channel, 4, vDSP_Length(width))
                    }
                }
            }
            if hasColumnFill {
                var fraction = rows.fraction[y]
                vDSP_vintb(top, 1, bottom, 1, &fraction, &columnFill, 1, length)
            }
            let output: [Float]
            if hasRowFill, hasColumnFill {
                // The row's fill counts for more near the left and right sides, the column's near the top and bottom:
                // its weight is the distance to the top or bottom over the sum of both distances.
                var yDistance = rows.distance[y]
                vDSP_vsadd(xDistance, 1, &yDistance, &weight, 1, length)
                vDSP_svdiv(&yDistance, weight, 1, &weight, 1, length)
                // columnFill + weight × (rowFill − columnFill)
                vDSP_vsub(columnFill, 1, rowFill, 1, &blended, 1, length)
                vDSP_vma(blended, 1, weight, 1, columnFill, 1, &blended, 1, length)
                output = blended
            } else {
                output = hasRowFill ? rowFill : columnFill
            }
            // Rounded to bytes. Every input is premultiplied and the weights are positive, so no channel exceeds alpha.
            var low: Float = 0, high: Float = 255
            vDSP_vclip(output, 1, &low, &high, &clipped, 1, length)
            vDSP_vfixru8(clipped, 1, pixels + y * rowBytes, 1, length)
        }
    }
}
