import Accelerate
import CoreGraphics
import CSCapture
import Foundation

/// Erase: an area filled from the pixels around it, so what was there is gone and the picture reads as if it never had it.
/// It is made from a ring `ringDepth` pixels deep just outside the area and nothing else, so no pixel under the area can
/// show in it. Where the ring is all one colour (within `flatTolerance`), the area is that colour, flat. Otherwise each
/// pixel blends two straight-line fills: across its row, from the ring on the left to the ring on the right, and down its
/// column, from the ring above to the ring below, each weighted by how near the pixel is to that pair's sides, so the
/// fill meets the ring without a seam. Deterministic: the same picture and area always give the same pixels.
///
/// Ring pixels beyond the picture's edge, or inside one of the `excluded` areas, are missing: a row or column whose ring is
/// missing on one side takes the other side's, and one missing on both sides is filled from the other direction alone.
/// A pixel with neither takes the mean of the ring that remains, and an area with no ring left at all is black.
///
/// The picture it reads must already hide whatever the other redactions hide (`Renderer.redactionInput`): the ring is
/// outside the area, so it can lie under another redaction. A function of that picture and an area only, so it can fill
/// any area: a redaction's, or each word's.
enum EraseFill {
    /// How many pixels deep the ring read around the area is.
    static let ringDepth = 2
    /// The most a channel (0 to 255) may vary across the ring for the area to be filled flat with the ring's mean.
    static let flatTolerance = 8

    /// The fill for `region` (base pixels, y down, as the other effects take it), the size of the part of it on the
    /// picture, premultiplied, in the picture's colour space where it is RGB. `excluded` are areas (base pixels, y down)
    /// whose pixels the ring leaves out. Nil when the region misses the picture or a bitmap can't be made.
    static func image(_ picture: CGImage, region: CGRect, excluding excluded: [CGRect] = []) -> CGImage? {
        let width = picture.width
        let height = picture.height
        let area = region.standardized.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        let x0 = Int(area.minX), y0 = Int(area.minY), w = Int(area.width), h = Int(area.height)
        guard let context = ImageOps.bitmapContext(width: w, height: h, preferring: picture.colorSpace),
              let space = context.colorSpace, let data = context.data else { return nil }
        let depth = (left: min(ringDepth, x0), right: min(ringDepth, width - x0 - w),
                     top: min(ringDepth, y0), bottom: min(ringDepth, height - y0 - h))
        // Only the excluded areas that reach the ring matter, in whole pixels.
        let ringBounds = area.insetBy(dx: -Double(ringDepth), dy: -Double(ringDepth))
        let holes = excluded.map { $0.standardized.integral }.filter { !$0.isNull && $0.intersects(ringBounds) }
        var stats = RingStats()
        // Each side as one value per row (left, right) or per column (top, bottom): the mean of its ring pixels there.
        func side(_ rect: CGRect, perRow: Bool) -> Side? {
            guard rect.width >= 1, rect.height >= 1 else { return Side(count: perRow ? h : w) }
            return means(of: picture, in: rect, perRow: perRow, space: space, holes: holes, stats: &stats)
        }
        // A ring that couldn't be read leaves the area black, as a failed effect does; it never shows the picture.
        guard let left = side(CGRect(x: x0 - depth.left, y: y0, width: depth.left, height: h), perRow: true),
              let right = side(CGRect(x: x0 + w, y: y0, width: depth.right, height: h), perRow: true),
              let top = side(CGRect(x: x0, y: y0 - depth.top, width: w, height: depth.top), perRow: false),
              let bottom = side(CGRect(x: x0, y: y0 + h, width: w, height: depth.bottom), perRow: false)
        else { return nil }

        let rowBytes = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: rowBytes * h)
        if stats.count == 0 {
            fillFlat(pixels, width: w, height: h, rowBytes: rowBytes, color: [0, 0, 0, 255])
        } else if stats.isFlat(within: flatTolerance) {
            fillFlat(pixels, width: w, height: h, rowBytes: rowBytes, color: stats.mean.map { UInt8($0.rounded()) })
        } else {
            fillInterpolated(pixels, width: w, height: h, rowBytes: rowBytes, mean: stats.mean,
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

        var mean: [Float] {
            (0..<4).map { Float(sums[$0]) / Float(count) }
        }
    }

    /// One side of the ring: four floats a row or column, and whether it has any ring pixel there.
    private struct Side {
        var values: [Float]
        var present: [Bool]

        /// A side with nothing: beyond the picture's edge.
        init(count: Int) {
            values = [Float](repeating: 0, count: count * 4)
            present = [Bool](repeating: false, count: count)
        }

        init(values: [Float], present: [Bool]) {
            self.values = values
            self.present = present
        }
    }

    /// The pixels of `rect` (y down) averaged across the strip, leaving out those in `holes`: four floats a row when
    /// `perRow`, else four a column.
    private static func means(of picture: CGImage, in rect: CGRect, perRow: Bool, space: CGColorSpace, holes: [CGRect],
                              stats: inout RingStats) -> Side? {
        guard let crop = picture.cropping(to: rect) else { return nil }
        let width = Int(rect.width), height = Int(rect.height)
        let originX = Int(rect.minX), originY = Int(rect.minY)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let pixelCount = width * height
        // The strip as floats, and which of its pixels are read (1) or in a hole (0). With vector operations: a side
        // of a 6K area is tens of thousands of values.
        var floats = [Float](repeating: 0, count: pixelCount * 4)
        vDSP_vfltu8(bytes, 1, &floats, 1, vDSP_Length(pixelCount * 4))
        var keep = [Float](repeating: 1, count: pixelCount)
        if !holes.isEmpty {
            for y in 0..<height {
                for x in 0..<width {
                    let point = CGPoint(x: Double(originX + x) + 0.5, y: Double(originY + y) + 0.5)
                    guard holes.contains(where: { $0.contains(point) }) else { continue }
                    keep[y * width + x] = 0
                    for channel in 0..<4 { floats[(y * width + x) * 4 + channel] = 0 }
                }
            }
        }
        let count = perRow ? height : width
        var sums = [Float](repeating: 0, count: count * 4)
        var counts = [Float](repeating: 0, count: count)
        if perRow {
            // A column of the strip at a time, down its rows.
            for x in 0..<width {
                keep.withUnsafeBufferPointer { keep in
                    vDSP_vadd(keep.baseAddress! + x, vDSP_Stride(width), counts, 1, &counts, 1, vDSP_Length(height))
                }
                for channel in 0..<4 {
                    floats.withUnsafeBufferPointer { floats in
                        sums.withUnsafeMutableBufferPointer { sums in
                            vDSP_vadd(floats.baseAddress! + x * 4 + channel, vDSP_Stride(width * 4), sums.baseAddress! + channel, 4,
                                      sums.baseAddress! + channel, 4, vDSP_Length(height))
                        }
                    }
                }
            }
        } else {
            // A row of the strip at a time, across it.
            for y in 0..<height {
                floats.withUnsafeBufferPointer { floats in
                    vDSP_vadd(floats.baseAddress! + y * width * 4, 1, sums, 1, &sums, 1, vDSP_Length(width * 4))
                }
                keep.withUnsafeBufferPointer { keep in
                    vDSP_vadd(keep.baseAddress! + y * width, 1, counts, 1, &counts, 1, vDSP_Length(width))
                }
            }
        }
        // The flatness check and the mean, over the pixels read.
        var read: Float = 0
        vDSP_sve(keep, 1, &read, vDSP_Length(pixelCount))
        if read > 0 {
            // A hole's pixels count as the strip's first pixel read, which changes neither end of the range.
            var ranged = floats
            if !holes.isEmpty, let first = keep.firstIndex(of: 1) {
                for index in 0..<pixelCount where keep[index] == 0 {
                    for channel in 0..<4 { ranged[index * 4 + channel] = floats[first * 4 + channel] }
                }
            }
            for channel in 0..<4 {
                var low: Float = 0, high: Float = 0, sum: Float = 0
                ranged.withUnsafeBufferPointer { ranged in
                    vDSP_minv(ranged.baseAddress! + channel, 4, &low, vDSP_Length(pixelCount))
                    vDSP_maxv(ranged.baseAddress! + channel, 4, &high, vDSP_Length(pixelCount))
                }
                floats.withUnsafeBufferPointer { floats in
                    vDSP_sve(floats.baseAddress! + channel, 4, &sum, vDSP_Length(pixelCount))
                }
                stats.low[channel] = min(stats.low[channel], Int(low))
                stats.high[channel] = max(stats.high[channel], Int(high))
                stats.sums[channel] += Int(sum)
            }
            stats.count += Int(read)
        }
        var values = [Float](repeating: 0, count: count * 4)
        if holes.isEmpty {
            var across = Float(perRow ? width : height)
            vDSP_vsdiv(sums, 1, &across, &values, 1, vDSP_Length(count * 4))
            return Side(values: values, present: [Bool](repeating: true, count: count))
        }
        let present = counts.map { $0 > 0 }
        for position in 0..<count where present[position] {
            for channel in 0..<4 { values[position * 4 + channel] = sums[position * 4 + channel] / counts[position] }
        }
        return Side(values: values, present: present)
    }

    private static func fillFlat(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, rowBytes: Int, color: [UInt8]) {
        memset_pattern4(pixels, color, width * 4)
        for y in 1..<max(height, 1) {
            (pixels + y * rowBytes).update(from: pixels, count: width * 4)
        }
    }

    /// The ring on two opposite sides of the area, and how deep each is.
    private struct Pair {
        var first: Side
        var second: Side
        var firstDepth: Int
        var secondDepth: Int

        /// For each of `length` pixels along the axis between the sides: where it lies from the first side's ring to the
        /// second's (0 to 1), and one over its distance to the nearer side when both are there, to the first alone, and
        /// to the second alone.
        func positions(_ length: Int) -> (fraction: [Float], both: [Float], first: [Float], second: [Float]) {
            // The middle of each side's ring, measured from the area's first edge.
            let start = -Float(max(firstDepth, 1)) / 2
            let end = Float(length) + Float(max(secondDepth, 1)) / 2
            var fraction = [Float](repeating: 0, count: length)
            var both = fraction, first = fraction, second = fraction
            for index in 0..<length {
                let centre = Float(index) + 0.5
                fraction[index] = (centre - start) / (end - start)
                both[index] = 1 / min(centre, Float(length) - centre)
                first[index] = 1 / centre
                second[index] = 1 / (Float(length) - centre)
            }
            return (fraction, both, first, second)
        }
    }

    /// How little a pixel with no ring on any side leans on the ring's mean: so little that it changes no other pixel.
    private static let meanWeight: Float = 1e-9

    /// Every pixel of the area: the row's fill between `horizontal`'s sides and the column's between `vertical`'s,
    /// each weighted by one over the distance to its nearer side that is there (nothing when neither is), so the nearer
    /// pair leads; the ring's `mean` stands in where there is neither. A row at a time, with vector operations, so a
    /// 6K-wide area takes milliseconds.
    private static func fillInterpolated(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, rowBytes: Int,
                                         mean: [Float], horizontal: Pair, vertical: Pair) {
        let count = width * 4
        let length = vDSP_Length(count)
        let columns = horizontal.positions(width)
        let rows = vertical.positions(height)
        let expand = { (values: [Float]) -> [Float] in
            var expanded = [Float](repeating: 0, count: values.count * 4)
            for channel in 0..<4 {
                expanded.withUnsafeMutableBufferPointer { expanded in
                    cblas_scopy(Int32(values.count), values, 1, expanded.baseAddress! + channel, 4)
                }
            }
            return expanded
        }
        // Down the columns: each column's top and bottom ring, a missing side standing in for the other, and which
        // of the three cases (both, top only, bottom only) it is, as 1 or 0 per channel.
        var top = vertical.first.values, bottom = vertical.second.values
        let everyBoth = !vertical.first.present.contains(false) && !vertical.second.present.contains(false)
        var hasBoth = [Float](repeating: everyBoth ? 1 : 0, count: count)
        var hasTop = [Float](repeating: 0, count: count), hasBottom = hasTop
        for x in 0..<width where !everyBoth {
            let up = vertical.first.present[x], down = vertical.second.present[x]
            for channel in 0..<4 {
                let index = x * 4 + channel
                if !up { top[index] = bottom[index] }
                if !down { bottom[index] = top[index] }
                hasBoth[index] = up && down ? 1 : 0
                hasTop[index] = up && !down ? 1 : 0
                hasBottom[index] = !up && down ? 1 : 0
            }
        }
        let anyColumn = vertical.first.present.contains(true) || vertical.second.present.contains(true)
        // Across the rows: one over the distance to the nearer side, for each case, per channel.
        let rowBoth = expand(columns.both), rowFirst = expand(columns.first), rowSecond = expand(columns.second)
        var meanRow = [Float](repeating: 0, count: count)
        for channel in 0..<4 {
            var value = mean[channel]
            meanRow.withUnsafeMutableBufferPointer { meanRow in
                vDSP_vfill(&value, meanRow.baseAddress! + channel, 4, vDSP_Length(width))
            }
        }

        var rowFill = [Float](repeating: 0, count: count)
        var columnFill = [Float](repeating: 0, count: count)
        var columnWeight = [Float](repeating: 0, count: count)
        var numerator = [Float](repeating: 0, count: count)
        var denominator = [Float](repeating: 0, count: count)
        let everyColumn = (0..<width).allSatisfy { vertical.first.present[$0] || vertical.second.present[$0] }
        // Rounded to bytes. Every value is a weighted mean of ring values (0 to 255, premultiplied) with positive weights,
        // so it needs no clamping, and no channel exceeds alpha.
        func write(_ values: [Float], row y: Int) {
            vDSP_vfixru8(values, 1, pixels + y * rowBytes, 1, length)
        }
        for y in 0..<height {
            let left = horizontal.first.present[y], right = horizontal.second.present[y]
            let hasRow = left || right
            if hasRow {
                for channel in 0..<4 {
                    let a = horizontal.first.values[y * 4 + channel], b = horizontal.second.values[y * 4 + channel]
                    var start = left ? a : b
                    var slope = left && right ? b - a : 0
                    rowFill.withUnsafeMutableBufferPointer { rowFill in
                        vDSP_vsmsa(columns.fraction, 1, &slope, &start, rowFill.baseAddress! + channel, 4, vDSP_Length(width))
                    }
                }
            }
            if anyColumn {
                var fraction = rows.fraction[y]
                vDSP_vintb(top, 1, bottom, 1, &fraction, &columnFill, 1, length)
            }
            // A row with one direction's fill alone, everywhere along it, is that fill (an area across the picture, say).
            if hasRow, !anyColumn {
                write(rowFill, row: y)
                continue
            }
            if !hasRow, everyColumn {
                write(columnFill, row: y)
                continue
            }
            var weight = meanWeight
            vDSP_vsmul(meanRow, 1, &weight, &numerator, 1, length)
            vDSP_vfill(&weight, &denominator, 1, length)
            if hasRow {
                let rowWeight = left && right ? rowBoth : left ? rowFirst : rowSecond
                vDSP_vma(rowFill, 1, rowWeight, 1, numerator, 1, &numerator, 1, length)
                vDSP_vadd(rowWeight, 1, denominator, 1, &denominator, 1, length)
            }
            if anyColumn {
                var both = rows.both[y], first = rows.first[y], second = rows.second[y]
                vDSP_vsmul(hasBoth, 1, &both, &columnWeight, 1, length)
                vDSP_vsma(hasTop, 1, &first, columnWeight, 1, &columnWeight, 1, length)
                vDSP_vsma(hasBottom, 1, &second, columnWeight, 1, &columnWeight, 1, length)
                vDSP_vma(columnFill, 1, columnWeight, 1, numerator, 1, &numerator, 1, length)
                vDSP_vadd(columnWeight, 1, denominator, 1, &denominator, 1, length)
            }
            // numerator / denominator: vDSP_vdiv divides its second vector by its first.
            vDSP_vdiv(denominator, 1, numerator, 1, &numerator, 1, length)
            write(numerator, row: y)
        }
    }
}
