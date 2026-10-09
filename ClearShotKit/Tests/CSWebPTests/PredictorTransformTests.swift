import Foundation
import Testing
@testable import CSWebP

/// The predictor transform (RFC 9649, section 3.5.1): the fourteen predictions, the rules at the image's edges, the
/// choice of a mode for each 16 x 16 tile, and the residuals.
struct PredictorTransformTests {
    // MARK: The fourteen predictions, by hand

    /// Three neighbourhoods and what each mode predicts for them, worked out by hand from Table 2. The channels are
    /// A, R, G, B.
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var l: UInt32, t: UInt32, tl: UInt32, tr: UInt32
        var expected: [UInt32]
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        // L (255, 100, 200, 30), T (255, 120, 180, 50), TL (255, 90, 210, 20), TR (255, 140, 160, 75).
        // Average2 drops the half: R of mode 5 is avg(avg(100, 140) = 120, 120) = 120; B is avg(avg(30, 75) = 52, 50) = 51.
        // Select: pL = |T - TL| summed = 0 + 30 + 30 + 30 = 90, pT = |L - TL| summed = 10 + 10 + 10 = 30: T is closer.
        // Full: R 100 + 120 - 90 = 130, G 200 + 180 - 210 = 170, B 30 + 50 - 20 = 60. Half: avg(L, T) = (110, 190, 40),
        // and 110 + (110 - 90) / 2 = 120, 190 + (190 - 210) / 2 = 180, 40 + (40 - 20) / 2 = 50.
        Case(name: "ordinary", l: 0xFF64_C81E, t: 0xFF78_B432, tl: 0xFF5A_D214, tr: 0xFF8C_A04B, expected: [
            0xFF00_0000,  // 0: black
            0xFF64_C81E,  // 1: L
            0xFF78_B432,  // 2: T
            0xFF8C_A04B,  // 3: TR
            0xFF5A_D214,  // 4: TL
            0xFF78_B433,  // 5: Average2(Average2(L, TR), T)  = (255, 120, 180, 51)
            0xFF5F_CD19,  // 6: Average2(L, TL) = (255, 95, 205, 25)
            0xFF6E_BE28,  // 7: Average2(L, T) = (255, 110, 190, 40)
            0xFF69_C323,  // 8: Average2(TL, T) = (255, 105, 195, 35)
            0xFF82_AA3E,  // 9: Average2(T, TR) = (255, 130, 170, 62)
            0xFF70_BB2B,  // 10: Average2((95, 205, 25), (130, 170, 62)) = (112, 187, 43)
            0xFF78_B432,  // 11: Select: T
            0xFF82_AA3C,  // 12: Clamp(L + T - TL) = (255, 130, 170, 60)
            0xFF78_B432,  // 13: ClampAddSubtractHalf(Average2(L, T), TL) = (255, 120, 180, 50)
        ]),
        // L (200, 250, 10, 128), T (100, 240, 5, 130), TL (50, 10, 250, 126), TR (10, 20, 30, 40).
        // Select: pL = |T - TL| summed = 50 + 230 + 245 + 4 = 529 < pT = |L - TL| summed = 150 + 240 + 240 + 2 = 632: L.
        // Full: A 200 + 100 - 50 = 250; R 250 + 240 - 10 = 480 -> 255; G 10 + 5 - 250 = -235 -> 0; B 128 + 130 - 126 = 132.
        // Half: avg(L, T) = (150, 245, 7, 129); A 150 + 100 / 2 = 200; R 245 + 235 / 2 = 362 -> 255;
        // G 7 + (7 - 250) / 2 = 7 - 121 = -114 -> 0; B 129 + 3 / 2 = 130.
        Case(name: "clamped", l: 0xC8FA_0A80, t: 0x64F0_0582, tl: 0x320A_FA7E, tr: 0x0A14_1E28, expected: [
            0xFF00_0000,
            0xC8FA_0A80,
            0x64F0_0582,
            0x0A14_1E28,
            0x320A_FA7E,
            // 5: avg(L, TR) = (105, 135, 20, 84); avg((105, 135, 20, 84), T (100, 240, 5, 130)) = (102, 187, 12, 107)
            0x66BB_0C6B,
            // 6: avg(L, TL) = (125, 130, 130, 127)
            0x7D82_827F,
            // 7: avg(L, T) = (150, 245, 7, 129)
            0x96F5_0781,
            // 8: avg(TL, T) = (75, 125, 127, 128)
            0x4B7D_7F80,
            // 9: avg(T, TR) = (55, 130, 17, 85)
            0x3782_1155,
            // 10: avg((125, 130, 130, 127), (55, 130, 17, 85)) = (90, 130, 73, 106)
            0x5A82_496A,
            0xC8FA_0A80,  // 11: Select: L
            0xFAFF_0084,  // 12: (250, 255, 0, 132)
            0xC8FF_0082,  // 13: (200, 255, 0, 130)
        ]),
        // L = T = (100, 100, 100, 100) and TL (101, 111, 121, 131): Select is a tie and takes T; Half is
        // 100 + (100 - 101) / 2 = 100 (division truncates toward zero: -1 / 2 is 0, not -1), 100 + (-11) / 2 = 95,
        // 100 + (-21) / 2 = 90, 100 + (-31) / 2 = 85. TR (100, 100, 100, 101) shows Average2 truncating: avg(100, 101) = 100.
        Case(name: "truncation", l: 0x6464_6464, t: 0x6464_6464, tl: 0x656F_7983, tr: 0x6464_6465, expected: [
            0xFF00_0000,
            0x6464_6464,
            0x6464_6464,
            0x6464_6465,
            0x656F_7983,
            0x6464_6464,  // 5: avg(avg(L, TR) = (100, 100, 100, 100), T)
            0x6469_6E73,  // 6: avg(L, TL) = (100, 105, 110, 115)
            0x6464_6464,  // 7
            0x6469_6E73,  // 8: avg(TL, T) = (100, 105, 110, 115)
            0x6464_6464,  // 9: avg(T, TR) = (100, 100, 100, 100)
            0x6466_696B,  // 10: avg((100, 105, 110, 115), (100, 100, 100, 100)) = (100, 102, 105, 107)
            0x6464_6464,  // 11: a tie goes to T
            0x6359_4F45,  // 12: L + T - TL = (99, 89, 79, 69)
            0x645F_5A55,  // 13: (100, 95, 90, 85)
        ]),
        // L (255, 110, 100, 100), T (255, 90, 100, 100), TL = TR (255, 100, 100, 100).
        // Select: the estimate is (255, 100, 100, 100); its distance to L is 10 (red) and to T is 10 (red): pL = pT = 10.
        // The RFC's code is `if (pL < pT) return L; else return T;`, so a tie, with L and T different, is T.
        // Average2: avg(avg(L, TR), T) = avg((105, 100, 100), (90, 100, 100)) = 97 in red; avg(L, TL) = 105,
        // avg(TL, T) = 95, avg(T, TR) = 95, and avg of (105, 95) is 100.
        Case(name: "select tie", l: 0xFF6E_6464, t: 0xFF5A_6464, tl: 0xFF64_6464, tr: 0xFF64_6464, expected: [
            0xFF00_0000,
            0xFF6E_6464,
            0xFF5A_6464,
            0xFF64_6464,
            0xFF64_6464,
            0xFF61_6464,  // 5: red 97
            0xFF69_6464,  // 6: red 105
            0xFF64_6464,  // 7: red 100
            0xFF5F_6464,  // 8: red 95
            0xFF5F_6464,  // 9: red 95
            0xFF64_6464,  // 10: red 100
            0xFF5A_6464,  // 11: a tie goes to T, not L
            0xFF64_6464,  // 12: red 110 + 90 - 100
            0xFF64_6464,  // 13: avg(L, T) is (255, 100, 100, 100) = TL: unchanged
        ]),
    ]

    @Test(arguments: Self.cases)
    func everyModePredictsWhatTheTableSays(_ item: Case) {
        for mode in 0..<14 {
            let got = PredictorTransform.predict(mode: mode, left: item.l, top: item.t, topLeft: item.tl,
                                                 topRight: item.tr)
            #expect(got == item.expected[mode],
                    "\(item.name), mode \(mode): got \(String(got, radix: 16)), expected \(String(item.expected[mode], radix: 16))")
        }
    }

    @Test(arguments: Self.cases)
    func theModelAgreesWithTheHandWork(_ item: Case) {
        // The hand-worked values above are also what the separately written model gives, which pins the model.
        for mode in 0..<14 {
            #expect(TransformModels.predict(mode: mode, l: item.l, t: item.t, tl: item.tl, tr: item.tr)
                == item.expected[mode], "\(item.name), mode \(mode)")
        }
    }

    @Test func everyModeAgreesWithTheModelOnRandomNeighbours() {
        var rng = SeededGenerator(seed: 77)
        for round in 0..<20_000 {
            // Some rounds use few distinct channel values so that ties and the clamps are common.
            let small = round % 4 == 0
            func random() -> UInt32 {
                if !small { return UInt32.random(in: 0...UInt32.max, using: &rng) }
                var pixel: UInt32 = 0
                for shift in stride(from: 0, to: 32, by: 8) {
                    pixel |= UInt32.random(in: 0...3, using: &rng) * 85 << UInt32(shift)
                }
                return pixel
            }
            let l = random(), t = random(), tl = random(), tr = random()
            for mode in 0..<14 {
                let got = PredictorTransform.predict(mode: mode, left: l, top: t, topLeft: tl, topRight: tr)
                let expected = TransformModels.predict(mode: mode, l: l, t: t, tl: tl, tr: tr)
                if got != expected {
                    Issue.record("mode \(mode) of L \(l) T \(t) TL \(tl) TR \(tr): \(got), the model says \(expected)")
                    return
                }
            }
        }
    }

    // MARK: Residuals and the edges

    /// A 4 x 3 image whose pixels all differ in every channel.
    private static let small: (width: Int, height: Int, pixels: [UInt32]) = {
        var pixels: [UInt32] = []
        for i in 0..<12 {
            let alpha = UInt32(255 - i), red = UInt32((i * 37 + 11) & 255)
            let green = UInt32((i * 53 + 5) & 255), blue = UInt32((i * 91 + 3) & 255)
            pixels.append(alpha << 24 | red << 16 | green << 8 | blue)
        }
        return (4, 3, pixels)
    }()

    private static func uniformModes(_ mode: Int, width: Int, height: Int) -> [UInt8] {
        let tiles = ((width + 15) / 16) * ((height + 15) / 16)
        return [UInt8](repeating: UInt8(mode), count: tiles)
    }

    @Test(arguments: 0..<14)
    func theEdgesFollowTheRulesWhateverTheMode(_ mode: Int) {
        let (width, height, pixels) = Self.small
        let modes = Self.uniformModes(mode, width: width, height: height)
        let residuals = PredictorTransform.residuals(pixels: pixels, width: width, height: height, sizeBits: 4,
                                                     modes: modes)
        func residual(_ x: Int, _ y: Int, minus prediction: UInt32) -> UInt32 {
            let a = TransformModels.channels(pixels[y * width + x]), p = TransformModels.channels(prediction)
            return TransformModels.pixel((0..<4).map { (a[$0] - p[$0]) & 0xFF })
        }
        // The top-left pixel is predicted as opaque black, the rest of the top row from the pixel on the left, the
        // rest of the left column from the pixel above.
        #expect(residuals[0] == residual(0, 0, minus: 0xFF00_0000))
        for x in 1..<width { #expect(residuals[x] == residual(x, 0, minus: pixels[x - 1]), "top row, x \(x)") }
        for y in 1..<height {
            #expect(residuals[y * width] == residual(0, y, minus: pixels[(y - 1) * width]), "left column, y \(y)")
        }
        // Inside, the tile's mode; and in the rightmost column the top right is the leftmost pixel of the pixel's own row.
        for y in 1..<height {
            for x in 1..<width {
                let tr = x == width - 1 ? pixels[y * width] : pixels[(y - 1) * width + x + 1]
                let prediction = TransformModels.predict(
                    mode: mode, l: pixels[y * width + x - 1], t: pixels[(y - 1) * width + x],
                    tl: pixels[(y - 1) * width + x - 1], tr: tr)
                #expect(residuals[y * width + x] == residual(x, y, minus: prediction), "mode \(mode), pixel (\(x), \(y))")
            }
        }
    }

    @Test func theTopRightOfTheRightmostColumnIsTheLeftmostPixelOfTheSameRow() {
        let (width, height, pixels) = Self.small
        // Mode 3 predicts TR itself, so the residual says which pixel was TR.
        let residuals = PredictorTransform.residuals(
            pixels: pixels, width: width, height: height, sizeBits: 4,
            modes: Self.uniformModes(3, width: width, height: height))
        for y in 1..<height {
            // residual + TR = pixel, so TR = pixel - residual.
            let a = TransformModels.channels(pixels[y * width + width - 1])
            let r = TransformModels.channels(residuals[y * width + width - 1])
            let tr = TransformModels.pixel((0..<4).map { (a[$0] - r[$0]) & 0xFF })
            #expect(tr == pixels[y * width], "row \(y): TR is the leftmost pixel of the row")
        }
    }

    @Test func aOnePixelWideImageHasOnlyEdgePixels() {
        let pixels: [UInt32] = [0xFF10_2030, 0xFF11_2231, 0xFF50_6070, 0x8000_0001]
        let residuals = PredictorTransform.residuals(pixels: pixels, width: 1, height: 4, sizeBits: 4, modes: [7])
        #expect(residuals[0] == 0x0010_2030)  // minus opaque black
        for y in 1..<4 { #expect(residuals[y] == TransformModels.add(pixels[y], negated(pixels[y - 1])), "T, row \(y)") }
    }

    private func negated(_ pixel: UInt32) -> UInt32 {
        TransformModels.pixel(TransformModels.channels(pixel).map { (256 - $0) & 0xFF })
    }

    @Test func aOnePixelHighImageIsPredictedFromTheLeft() {
        let pixels: [UInt32] = [0xFF10_2030, 0xFF11_2231, 0xFF50_6070, 0x8000_0001, 0x0000_0000]
        let residuals = PredictorTransform.residuals(pixels: pixels, width: 5, height: 1, sizeBits: 4, modes: [12])
        #expect(residuals[0] == 0x0010_2030)
        for x in 1..<5 { #expect(residuals[x] == TransformModels.add(pixels[x], negated(pixels[x - 1])), "L, x \(x)") }
    }

    // MARK: The inverse, as a decoder does it

    static let images: [Fixture] = [
        Fixture("noise 100x80") { Fixtures.noise(100, 80, seed: 3) },
        Fixture("random 70x40") { Fixtures.randomNoise(70, 40, seed: 5) },
        Fixture("ui 300x200") { Fixtures.uiScreenshot(300, 200) },
        Fixture("ui 17x33") { Fixtures.uiScreenshot(17, 33) },
        Fixture("noise 16x16") { Fixtures.noise(16, 16, seed: 6) },
        Fixture("noise 17x16") { Fixtures.noise(17, 16, seed: 7) },
        Fixture("noise 33x1") { Fixtures.noise(33, 1, seed: 8) },
        Fixture("noise 1x33") { Fixtures.noise(1, 33, seed: 9) },
        Fixture("noise 1x1") { Fixtures.noise(1, 1, seed: 10) },
        Fixture("alpha 90x20") { Fixtures.alphaGradient(90, 20) },
        Fixture("binary alpha 50x40") { Fixtures.binaryAlpha(50, 40) },
        Fixture("tiles 64x40") { Fixtures.repeatedTiles(64, 40) },
    ]

    @Test(arguments: images)
    func theInverseOfTheChosenTransformIsTheOriginal(_ fixture: Fixture) {
        let name = fixture.name, image = fixture.make()
        let original = image.argbPixels
        var pixels = original
        SubtractGreenTransform.apply(to: &pixels)  // the order the encoder writes them in
        let modes = PredictorTransform.chooseModes(pixels: pixels, width: image.width, height: image.height, sizeBits: 4)
        let residuals = PredictorTransform.residuals(pixels: pixels, width: image.width, height: image.height,
                                                     sizeBits: 4, modes: modes)
        let rebuilt = TransformModels.inversePredictor(
            residuals: residuals, width: image.width, height: image.height, sizeBits: 4,
            modeImage: PredictorTransform.modeImage(modes: modes))
        #expect(rebuilt == pixels, "\(name): predictor")
        #expect(TransformModels.inverseSubtractGreen(rebuilt) == original, "\(name): subtract green")
    }

    @Test(arguments: 0..<14)
    func everyModeOnItsOwnRoundTrips(_ mode: Int) {
        for image in [Fixtures.noise(50, 37, seed: 11), Fixtures.uiScreenshot(90, 60)] {
            let pixels = image.argbPixels
            let modes = Self.uniformModes(mode, width: image.width, height: image.height)
            let residuals = PredictorTransform.residuals(pixels: pixels, width: image.width, height: image.height,
                                                         sizeBits: 4, modes: modes)
            #expect(TransformModels.inversePredictor(
                residuals: residuals, width: image.width, height: image.height, sizeBits: 4,
                modeImage: PredictorTransform.modeImage(modes: modes)) == pixels, "mode \(mode)")
        }
    }

    // MARK: Residuals in place

    @Test(arguments: images)
    func replacingThePixelsWithTheirResidualsInPlaceIsTheOutOfPlaceResult(_ fixture: Fixture) {
        let image = fixture.make()
        var pixels = image.argbPixels
        SubtractGreenTransform.apply(to: &pixels)
        let modes = PredictorTransform.chooseModes(pixels: pixels, width: image.width, height: image.height, sizeBits: 4)
        let expected = TransformModels.forwardPredictor(
            pixels: pixels, width: image.width, height: image.height, sizeBits: 4,
            modeImage: PredictorTransform.modeImage(modes: modes))
        var inPlace = pixels
        PredictorTransform.replaceWithResiduals(&inPlace, width: image.width, height: image.height, sizeBits: 4,
                                                modes: modes)
        #expect(inPlace == expected, "\(fixture.name)")
        #expect(PredictorTransform.residuals(pixels: pixels, width: image.width, height: image.height, sizeBits: 4,
                                             modes: modes) == expected, "\(fixture.name), the copying form")
    }

    @Test(arguments: 0..<14)
    func everyModeInPlaceIsTheOutOfPlaceResult(_ mode: Int) {
        for image in [Fixtures.noise(50, 37, seed: 11), Fixtures.uiScreenshot(90, 60), Fixtures.noise(1, 20, seed: 2),
                      Fixtures.noise(20, 1, seed: 3), Fixtures.randomNoise(17, 17, seed: 4)] {
            let pixels = image.argbPixels
            let modes = Self.uniformModes(mode, width: image.width, height: image.height)
            let expected = TransformModels.forwardPredictor(
                pixels: pixels, width: image.width, height: image.height, sizeBits: 4,
                modeImage: PredictorTransform.modeImage(modes: modes))
            var inPlace = pixels
            PredictorTransform.replaceWithResiduals(&inPlace, width: image.width, height: image.height, sizeBits: 4,
                                                    modes: modes)
            #expect(inPlace == expected, "mode \(mode), \(image.width)x\(image.height)")
        }
    }

    // MARK: The tile image

    @Test func theTileImageHoldsTheModeInGreenAndNothingElse() {
        #expect(PredictorTransform.modeImage(modes: [0, 1, 13, 7]) == [0xFF00_0000, 0xFF00_0100, 0xFF00_0D00, 0xFF00_0700])
    }

    @Test func theTilesAre16x16AndTheEdgeOnesAreCutShort() {
        #expect(PredictorTransform.sizeBits == 4)
        #expect(PredictorTransform.tileCount(width: 1, height: 1, sizeBits: 4) == (across: 1, down: 1))
        #expect(PredictorTransform.tileCount(width: 16, height: 16, sizeBits: 4) == (across: 1, down: 1))
        #expect(PredictorTransform.tileCount(width: 17, height: 33, sizeBits: 4) == (across: 2, down: 3))
        #expect(PredictorTransform.tileCount(width: 1440, height: 900, sizeBits: 4) == (across: 90, down: 57))
        #expect(PredictorTransform.tileCount(width: 16383, height: 1, sizeBits: 4) == (across: 1024, down: 1))
        let image = Fixtures.noise(50, 37, seed: 12)
        let modes = PredictorTransform.chooseModes(pixels: image.argbPixels, width: 50, height: 37, sizeBits: 4)
        #expect(modes.count == 4 * 3)
        #expect(modes.allSatisfy { $0 < 14 })
    }

    // MARK: The choice of a mode

    /// The cost of `mode` over the pixels of one tile that the mode decides (the pixels away from the top row and the
    /// left column), by the model: for each channel of each residual, the bit length of the residual's distance from
    /// zero read as a signed byte, so 0 costs 0, +-1 costs 1, +-2 and +-3 cost 2, up to 8 for 128.
    private static func modelCost(
        mode: Int, pixels: [UInt32], width: Int, height: Int, tileX: Int, tileY: Int
    ) -> Int {
        var total = 0
        for y in max(1, tileY * 16)..<min(height, tileY * 16 + 16) {
            for x in max(1, tileX * 16)..<min(width, tileX * 16 + 16) {
                let tr = x == width - 1 ? pixels[y * width] : pixels[(y - 1) * width + x + 1]
                let prediction = TransformModels.predict(
                    mode: mode, l: pixels[y * width + x - 1], t: pixels[(y - 1) * width + x],
                    tl: pixels[(y - 1) * width + x - 1], tr: tr)
                let a = TransformModels.channels(pixels[y * width + x]), p = TransformModels.channels(prediction)
                for channel in 0..<4 {
                    let r = (a[channel] - p[channel]) & 0xFF
                    let distance = min(r, 256 - r)
                    total += distance == 0 ? 0 : String(distance, radix: 2).count
                }
            }
        }
        return total
    }

    @Test func aResidualCostsTheBitLengthOfItsDistanceFromZero() {
        let table = PredictorTransform.residualBits
        #expect(table.count == 256)
        #expect(table[0] == 0)
        for (residual, bits) in [(1, 1), (255, 1), (2, 2), (3, 2), (254, 2), (253, 2), (4, 3), (7, 3), (252, 3), (249, 3),
                                 (8, 4), (100, 7), (127, 7), (129, 7), (128, 8), (156, 7), (160, 7), (192, 7), (193, 6), (64, 7), (63, 6)] {
            #expect(Int(table[residual]) == bits, "residual \(residual)")
        }
    }

    static let costImages: [Fixture] = [
        Fixture("noise 100x80") { Fixtures.noise(100, 80, seed: 3) },
        Fixture("random 70x40") { Fixtures.randomNoise(70, 40, seed: 5) },
        Fixture("ui 120x90") { Fixtures.uiScreenshot(120, 90) },
        Fixture("alpha 90x20") { Fixtures.alphaGradient(90, 20) },
        Fixture("noise 33x17") { Fixtures.noise(33, 17, seed: 7) },
    ]

    @Test(arguments: costImages)
    func eachTilesCostsAreTheBitLengthsOfTheResidualsOfEachMode(_ fixture: Fixture) {
        let name = fixture.name, image = fixture.make()
        let pixels = image.argbPixels
        let across = (image.width + 15) / 16, down = (image.height + 15) / 16
        for tileY in 0..<down {
            for tileX in 0..<across {
                let costs = PredictorTransform.modeCosts(pixels: pixels, width: image.width, height: image.height,
                                                         tileX: tileX, tileY: tileY, sizeBits: 4)
                #expect(costs.count == 14)
                for mode in 0..<14 {
                    #expect(costs[mode] == Self.modelCost(mode: mode, pixels: pixels, width: image.width,
                                                         height: image.height, tileX: tileX, tileY: tileY),
                            "\(name), tile (\(tileX), \(tileY)), mode \(mode)")
                }
            }
        }
    }

    @Test func theChosenModeHasTheLowestCostInItsTile() {
        for image in [Fixtures.noise(100, 80, seed: 3), Fixtures.uiScreenshot(120, 90), Fixtures.randomNoise(40, 40, seed: 2)] {
            let pixels = image.argbPixels
            let modes = PredictorTransform.chooseModes(pixels: pixels, width: image.width, height: image.height, sizeBits: 4)
            let across = (image.width + 15) / 16
            for (tile, mode) in modes.enumerated() {
                let costs = PredictorTransform.modeCosts(pixels: pixels, width: image.width, height: image.height,
                                                         tileX: tile % across, tileY: tile / across, sizeBits: 4)
                #expect(costs[Int(mode)] == costs.min(), "tile \(tile): mode \(mode) of costs \(costs)")
            }
        }
    }

    @Test func aTieGoesToTheModeOfTheTileBeforeAndOtherwiseTheLowest() {
        // One flat colour: every mode but 0 predicts it exactly, so 1 to 13 tie at zero. The first tile takes the
        // lowest of them, and each tile after it keeps what the one before had.
        let flat = RGBAImage(width: 50, height: 40, fill: Pixel(200, 100, 50)).argbPixels
        #expect(PredictorTransform.chooseModes(pixels: flat, width: 50, height: 40, sizeBits: 4)
            == [UInt8](repeating: 1, count: 4 * 3))
        // Black, all fourteen tie at zero: the lowest is 0.
        let black = [UInt32](repeating: 0xFF00_0000, count: 50 * 40)
        #expect(PredictorTransform.chooseModes(pixels: black, width: 50, height: 40, sizeBits: 4)
            == [UInt8](repeating: 0, count: 4 * 3))
    }

    @Test func theTileBeforeKeepsItsModeAmongTiedModesEvenWhenItIsNotTheLowest() {
        // Diagonal stripes: the colour depends on d = x - y alone, a different colour for each d up to 3 and one
        // colour from 4 up. In the left tile only TL (mode 4) is exact. In the middle tile every pixel and all its
        // neighbours have d of 4 or more, so it is flat and modes 1 to 13 tie at zero: mode 4 is one of them but the
        // lowest is mode 1. In the right tile the top right of the last column is the first pixel of its row, which
        // is not flat, so the modes that read it (3, 5, 9, 10) drop out of the tie, and 4 is still in it.
        let width = 48, height = 12
        var pixels = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let d = x - y
                if d >= 4 {
                    pixels[y * width + x] = 0xFF90_9090
                } else {
                    let k = UInt32(d + 12)
                    pixels[y * width + x] = 0xFF00_0000 | (40 + 13 * k) << 16 | (200 - 9 * k) << 8 | (7 * k) % 256
                }
            }
        }
        func zeroCostModes(_ tileX: Int) -> [Int] {
            let costs = PredictorTransform.modeCosts(pixels: pixels, width: width, height: height, tileX: tileX,
                                                     tileY: 0, sizeBits: 4)
            return (0..<14).filter { costs[$0] == 0 }
        }
        #expect(zeroCostModes(0) == [4], "only TL is exact on the stripes")
        #expect(zeroCostModes(1) == Array(1...13), "the flat tile ties")
        #expect(zeroCostModes(2) == [1, 2, 4, 6, 7, 8, 11, 12, 13])
        #expect(PredictorTransform.chooseModes(pixels: pixels, width: width, height: height, sizeBits: 4) == [4, 4, 4],
                "the lowest of the tied modes would give [4, 1, 1]")
    }

    @Test func theRuleForTiedModesPicksTheTileBeforeThenTheLowest() {
        // Modes 1, 2 and 4 tie at the lowest cost.
        let costs = [9, 4, 4, 7, 4, 9, 9, 9, 9, 9, 9, 9, 9, 9]
        #expect(PredictorTransform.bestMode(costs: costs, previous: nil) == 1)
        #expect(PredictorTransform.bestMode(costs: costs, previous: 4) == 4, "the tile before had 4, which is tied")
        #expect(PredictorTransform.bestMode(costs: costs, previous: 2) == 2)
        #expect(PredictorTransform.bestMode(costs: costs, previous: 1) == 1)
        #expect(PredictorTransform.bestMode(costs: costs, previous: 3) == 1, "3 is not tied, so the lowest")
        #expect(PredictorTransform.bestMode(costs: costs, previous: 0) == 1)
        // A single lowest cost wins whatever came before.
        var unique = costs
        unique[7] = 1
        #expect(PredictorTransform.bestMode(costs: unique, previous: 4) == 7)
        #expect(PredictorTransform.bestMode(costs: unique, previous: nil) == 7)
        // Mode 0 is the lowest when it ties.
        #expect(PredictorTransform.bestMode(costs: [Int](repeating: 0, count: 14), previous: nil) == 0)
        #expect(PredictorTransform.bestMode(costs: [Int](repeating: 0, count: 14), previous: 6) == 6)
    }

    @Test func aRampAcrossTheImageIsPredictedFromAbove() {
        // Red rises 3 per pixel to the right and is the same on every row: T, Select and the full clamp are exact;
        // the lowest is 2.
        var image = RGBAImage(width: 64, height: 48, fill: Pixel(0, 40, 60))
        for y in 0..<48 { for x in 0..<64 { image[x, y] = Pixel(UInt8(x * 3), 40, 60) } }
        let modes = PredictorTransform.chooseModes(pixels: image.argbPixels, width: 64, height: 48, sizeBits: 4)
        #expect(modes == [UInt8](repeating: 2, count: 4 * 3))
    }

    @Test func aRampDownTheImageIsPredictedFromTheLeft() {
        var image = RGBAImage(width: 64, height: 48, fill: Pixel(0, 40, 60))
        for y in 0..<48 { for x in 0..<64 { image[x, y] = Pixel(UInt8(y * 3), 40, 60) } }
        let modes = PredictorTransform.chooseModes(pixels: image.argbPixels, width: 64, height: 48, sizeBits: 4)
        #expect(modes == [UInt8](repeating: 1, count: 4 * 3))
    }

    @Test func aTileWithNoInteriorPixelHasNothingToChooseAndTakesTheNeighbours() {
        // 1 pixel wide: every pixel is on the left column or the top row, so all the costs are 0.
        let pixels = Fixtures.noise(1, 40, seed: 3).argbPixels
        #expect(PredictorTransform.modeCosts(pixels: pixels, width: 1, height: 40, tileX: 0, tileY: 1, sizeBits: 4)
            == [Int](repeating: 0, count: 14))
        #expect(PredictorTransform.chooseModes(pixels: pixels, width: 1, height: 40, sizeBits: 4) == [0, 0, 0])
    }
}
