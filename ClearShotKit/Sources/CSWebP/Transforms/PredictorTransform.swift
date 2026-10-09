/// The predictor transform (RFC 9649, section 3.5.1): each pixel is replaced by what it differs from a prediction by,
/// the prediction made from the pixels already seen (the one on the left, the three above), per channel, modulo 256.
/// Where neighbours resemble each other the residuals are small or zero, which the prefix codes make cheap.
///
/// The image is cut into square tiles, `1 << sizeBits` on a side (16 here), and a tile has one of the 14 prediction
/// modes of Table 2 for all its pixels. The modes are the tile image: one pixel per tile with the mode in its green
/// channel. The pixels on the top row and the left column are not part of the choice: they are predicted by a fixed
/// rule whatever the mode (black for the first pixel, the left neighbour along the top row, the pixel above down the
/// left column), and the rightmost column's top-right neighbour is the leftmost pixel of its own row.
///
/// The residuals are made from the original pixels. A decoder has the rebuilt ones, which are the same because the
/// transform loses nothing.
///
/// A tile's mode is the one with the lowest cost, which is the sum, over the tile's pixels and their four channels, of
/// the bit length of the residual read as a signed byte (0 for 0, 1 for ±1, 2 for ±2 and ±3, up to 8 for 128). The
/// plain sum of the absolute residuals was the first measure, but it prices a residual of 100 as 100 times a residual
/// of 1, where a prefix code sees both as one more symbol; the bit length follows the cost in bits, and gave files
/// 13% smaller on a UI-like image, 0.4% on a photograph-like one, and half the size on a smooth alpha gradient.
enum PredictorTransform {
    /// The tile side is `1 << sizeBits`: 16 pixels. The format stores `sizeBits - 2` in 3 bits (so 2 to 9).
    static let sizeBits = 4
    /// The number of prediction modes.
    static let modeCount = 14
    static let black: UInt32 = 0xFF00_0000

    /// The tiles across and down for an image.
    static func tileCount(width: Int, height: Int, sizeBits: Int) -> (across: Int, down: Int) {
        let side = 1 << sizeBits
        return ((width + side - 1) >> sizeBits, (height + side - 1) >> sizeBits)
    }

    // MARK: Channel arithmetic

    /// `a - b` for each of the four channels, modulo 256, without a borrow from one channel into the next.
    @inline(__always)
    static func subtract(_ a: UInt32, _ b: UInt32) -> UInt32 {
        // The low seven bits of each channel are subtracted with a guard bit set above them; the top bit of each
        // channel is then fixed up by its own xor, so nothing crosses a channel boundary.
        ((a | 0x8080_8080) &- (b & 0x7F7F_7F7F)) ^ ((a ^ ~b) & 0x8080_8080)
    }

    /// `(a + b) / 2` for each channel, rounded down: the sum of the halves and the carry of the low bits.
    @inline(__always)
    static func average2(_ a: UInt32, _ b: UInt32) -> UInt32 {
        (((a ^ b) & 0xFEFE_FEFE) >> 1) &+ (a & b)
    }

    /// The cost of each possible channel residual: the bit length of its distance from zero, reading it as a signed
    /// byte (1 and 255 are one away, 128 is the farthest at 128). Entry `r` for the residual byte `r`.
    static let residualBits: [UInt8] = (0..<256).map { residual in
        let distance = min(residual, 256 - residual)
        return UInt8(distance == 0 ? 0 : Int.bitWidth - distance.leadingZeroBitCount)
    }

    /// The sum over the four channels of `|a - b|`.
    @inline(__always)
    private static func distance(_ a: UInt32, _ b: UInt32) -> Int {
        abs(Int(a >> 24) - Int(b >> 24)) + abs(Int((a >> 16) & 0xFF) - Int((b >> 16) & 0xFF))
            + abs(Int((a >> 8) & 0xFF) - Int((b >> 8) & 0xFF)) + abs(Int(a & 0xFF) - Int(b & 0xFF))
    }

    // MARK: The predictors

    /// Select: the left or the top pixel, whichever is closer (summed over the channels) to the estimate L + T - TL, and
    /// the top one on a tie. The estimate's distance to L is the distance of T to TL, and its distance to T is that of L
    /// to TL, which saves forming the estimate.
    @inline(__always)
    static func select(_ left: UInt32, _ top: UInt32, _ topLeft: UInt32) -> UInt32 {
        distance(top, topLeft) < distance(left, topLeft) ? left : top
    }

    /// Clamp(L + T - TL) for each channel.
    @inline(__always)
    static func clampAddSubtractFull(_ left: UInt32, _ top: UInt32, _ topLeft: UInt32) -> UInt32 {
        @inline(__always) func channel(_ shift: UInt32) -> UInt32 {
            let value = Int((left >> shift) & 0xFF) + Int((top >> shift) & 0xFF) - Int((topLeft >> shift) & 0xFF)
            return UInt32(truncatingIfNeeded: min(max(value, 0), 255)) << shift
        }
        return channel(24) | channel(16) | channel(8) | channel(0)
    }

    /// Clamp(a + (a - b) / 2) for each channel, with the division truncating toward zero as in the RFC's C.
    @inline(__always)
    static func clampAddSubtractHalf(_ a: UInt32, _ b: UInt32) -> UInt32 {
        @inline(__always) func channel(_ shift: UInt32) -> UInt32 {
            let x = Int((a >> shift) & 0xFF), y = Int((b >> shift) & 0xFF)
            return UInt32(truncatingIfNeeded: min(max(x + (x - y) / 2, 0), 255)) << shift
        }
        return channel(24) | channel(16) | channel(8) | channel(0)
    }

    /// What mode `mode` (0 to 13) predicts from the four neighbours (Table 2).
    @inline(__always)
    static func predict(mode: Int, left: UInt32, top: UInt32, topLeft: UInt32, topRight: UInt32) -> UInt32 {
        switch mode {
        case 0: black
        case 1: left
        case 2: top
        case 3: topRight
        case 4: topLeft
        case 5: average2(average2(left, topRight), top)
        case 6: average2(left, topLeft)
        case 7: average2(left, top)
        case 8: average2(topLeft, top)
        case 9: average2(top, topRight)
        case 10: average2(average2(left, topLeft), average2(top, topRight))
        case 11: select(left, top, topLeft)
        case 12: clampAddSubtractFull(left, top, topLeft)
        case 13: clampAddSubtractHalf(average2(left, top), topLeft)
        default: preconditionFailure("prediction modes are 0 through 13")
        }
    }

    // MARK: Choosing a mode for each tile

    /// Adds, for each mode, the cost of the pixels of one tile that the mode decides: the pixels below the first row
    /// and right of the first column. A mode's cost is the sum over those pixels of the residual's channels' bit
    /// lengths (`residualBits`, passed as `bits`). `costs` has room for 14 and is added to.
    private static func addCosts(
        into costs: UnsafeMutablePointer<Int>, pixels: UnsafeBufferPointer<UInt32>, width: Int, height: Int,
        tileX: Int, tileY: Int, sizeBits: Int, bits: UnsafePointer<UInt8>
    ) {
        @inline(__always) func cost(_ residual: UInt32) -> Int {
            Int(bits[Int(residual & 0xFF)]) + Int(bits[Int((residual >> 8) & 0xFF)])
                + Int(bits[Int((residual >> 16) & 0xFF)]) + Int(bits[Int(residual >> 24)])
        }
        let side = 1 << sizeBits
        let x0 = max(1, tileX << sizeBits), x1 = min(width, (tileX << sizeBits) + side)
        let y0 = max(1, tileY << sizeBits), y1 = min(height, (tileY << sizeBits) + side)
        guard x0 < x1, y0 < y1 else { return }
        var c0 = 0, c1 = 0, c2 = 0, c3 = 0, c4 = 0, c5 = 0, c6 = 0, c7 = 0, c8 = 0, c9 = 0, c10 = 0, c11 = 0, c12 = 0
        var c13 = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y * width + x
                let actual = pixels[i]
                let left = pixels[i - 1], top = pixels[i - width], topLeft = pixels[i - width - 1]
                // The top right of the rightmost column is the first pixel of this row, which this index reaches.
                let topRight = pixels[i - width + 1]
                if actual == left, actual == top, actual == topLeft, actual == topRight {
                    // A flat patch: every mode but the first predicts it exactly, and costs nothing.
                    c0 += cost(subtract(actual, black))
                    continue
                }
                c0 += cost(subtract(actual, black))
                c1 += cost(subtract(actual, left))
                c2 += cost(subtract(actual, top))
                c3 += cost(subtract(actual, topRight))
                c4 += cost(subtract(actual, topLeft))
                let averageLeftTop = average2(left, top)
                c5 += cost(subtract(actual, average2(average2(left, topRight), top)))
                c6 += cost(subtract(actual, average2(left, topLeft)))
                c7 += cost(subtract(actual, averageLeftTop))
                c8 += cost(subtract(actual, average2(topLeft, top)))
                c9 += cost(subtract(actual, average2(top, topRight)))
                c10 += cost(subtract(actual, average2(average2(left, topLeft), average2(top, topRight))))
                c11 += cost(subtract(actual, select(left, top, topLeft)))
                c12 += cost(subtract(actual, clampAddSubtractFull(left, top, topLeft)))
                c13 += cost(subtract(actual, clampAddSubtractHalf(averageLeftTop, topLeft)))
            }
        }
        costs[0] += c0; costs[1] += c1; costs[2] += c2; costs[3] += c3; costs[4] += c4; costs[5] += c5
        costs[6] += c6; costs[7] += c7; costs[8] += c8; costs[9] += c9; costs[10] += c10; costs[11] += c11
        costs[12] += c12; costs[13] += c13
    }

    /// The cost of each of the 14 modes on one tile: the sum, over the pixels of the tile that a mode decides and the
    /// four channels, of the bit length of the residual's distance from zero (`residualBits`).
    static func modeCosts(
        pixels: [UInt32], width: Int, height: Int, tileX: Int, tileY: Int, sizeBits: Int
    ) -> [Int] {
        var costs = [Int](repeating: 0, count: modeCount)
        pixels.withUnsafeBufferPointer { buffer in
            costs.withUnsafeMutableBufferPointer { out in
                residualBits.withUnsafeBufferPointer { bits in
                    addCosts(into: out.baseAddress!, pixels: buffer, width: width, height: height, tileX: tileX,
                             tileY: tileY, sizeBits: sizeBits, bits: bits.baseAddress!)
                }
            }
        }
        return costs
    }

    /// The mode with the lowest of `costs`. Where several modes tie, the mode of the tile before (`previous`) is kept
    /// when it is one of them, so that a flat or an even area gives one long run in the tile image, which costs next
    /// to nothing to write; otherwise the lowest mode.
    static func bestMode<Costs: RandomAccessCollection>(costs: Costs, previous: Int?) -> Int
    where Costs.Element == Int, Costs.Index == Int {
        var best = 0
        for mode in 1..<modeCount where costs[mode] < costs[best] { best = mode }
        if let previous, costs[previous] == costs[best] { return previous }
        return best
    }

    /// The mode of each tile, left to right and top to bottom: the one with the lowest cost (`modeCosts`), and among
    /// ties the one `bestMode` picks.
    static func chooseModes(pixels: [UInt32], width: Int, height: Int, sizeBits: Int) -> [UInt8] {
        let (across, down) = tileCount(width: width, height: height, sizeBits: sizeBits)
        var modes = [UInt8]()
        modes.reserveCapacity(across * down)
        var costs = [Int](repeating: 0, count: modeCount)
        pixels.withUnsafeBufferPointer { buffer in
            costs.withUnsafeMutableBufferPointer { out in
                residualBits.withUnsafeBufferPointer { table in
                    let costs = out.baseAddress!
                    var previous = -1
                    for tileY in 0..<down {
                        for tileX in 0..<across {
                            for mode in 0..<modeCount { costs[mode] = 0 }
                            addCosts(into: costs, pixels: buffer, width: width, height: height, tileX: tileX,
                                     tileY: tileY, sizeBits: sizeBits, bits: table.baseAddress!)
                            let best = bestMode(costs: UnsafeBufferPointer(start: costs, count: modeCount),
                                                previous: previous >= 0 ? previous : nil)
                            modes.append(UInt8(best))
                            previous = best
                        }
                    }
                }
            }
        }
        return modes
    }

    // MARK: The residuals

    /// Replaces each pixel by its residual: the pixel less its prediction, per channel, with the tile's mode inside
    /// the image and the rule for the edges outside it. `modes` is one per tile, as `chooseModes` gives.
    ///
    /// It works in place, with no second buffer: every neighbour a prediction reads (left, top left, top, top right)
    /// comes earlier in scan order than the pixel, so going from the last pixel to the first the originals are always
    /// read before they are overwritten. (The top right of the rightmost column is the first pixel of its own row,
    /// which is only replaced after the rest of the row.)
    static func replaceWithResiduals(_ pixels: inout [UInt32], width: Int, height: Int, sizeBits: Int, modes: [UInt8]) {
        let (across, down) = tileCount(width: width, height: height, sizeBits: sizeBits)
        precondition(modes.count == across * down, "one mode for each tile")
        precondition(pixels.count == width * height)
        pixels.withUnsafeMutableBufferPointer { p in
            for y in stride(from: height - 1, through: 1, by: -1) {
                let row = y * width
                let modeRow = (y >> sizeBits) * across
                for x in stride(from: width - 1, through: 1, by: -1) {
                    let i = row + x
                    let prediction = predict(
                        mode: Int(modes[modeRow + (x >> sizeBits)]), left: p[i - 1], top: p[i - width],
                        topLeft: p[i - width - 1], topRight: p[i - width + 1])
                    p[i] = subtract(p[i], prediction)
                }
                p[row] = subtract(p[row], p[row - width])
            }
            for x in stride(from: width - 1, through: 1, by: -1) { p[x] = subtract(p[x], p[x - 1]) }
            p[0] = subtract(p[0], black)
        }
    }

    /// The tile image: one pixel per tile, opaque, with the mode in the green channel.
    static func modeImage(modes: [UInt8]) -> [UInt32] {
        modes.map { black | UInt32($0) << 8 }
    }
}
