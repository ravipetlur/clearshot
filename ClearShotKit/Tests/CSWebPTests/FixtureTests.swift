import Testing

/// The fixtures promise properties the encoder's tests rely on (colour counts, long runs, repeats); check them here so
/// a change to a generator cannot quietly weaken a test.
struct FixtureTests {
    @Test func theScreenshotHasMoreThan256ColoursAndTheFlatOneDoesNot() {
        #expect(Fixtures.uiScreenshot(640, 360).distinctColors.count > 256)
        #expect(Fixtures.uiScreenshotFlat(640, 360).distinctColors.count <= 256)
        #expect(Fixtures.uiScreenshotFlat(640, 360).distinctColors.count > 8)
    }

    @Test func theFixturesAreDeterministic() {
        #expect(Fixtures.noise(30, 20, seed: 4) == Fixtures.noise(30, 20, seed: 4))
        #expect(Fixtures.noise(30, 20, seed: 4) != Fixtures.noise(30, 20, seed: 5))
        #expect(Fixtures.uiScreenshot(200, 120) == Fixtures.uiScreenshot(200, 120))
        #expect(Fixtures.repeatedTiles(64, 40) == Fixtures.repeatedTiles(64, 40))
    }

    @Test func noiseIsOpaque() {
        for image in [Fixtures.noise(50, 50, seed: 1), Fixtures.randomNoise(50, 50, seed: 1)] {
            #expect(stride(from: 3, to: image.rgba.count, by: 4).allSatisfy { image.rgba[$0] == 255 })
        }
    }

    /// The mean absolute difference between horizontal neighbours, over the three colour channels.
    private func meanStep(_ image: RGBAImage) -> Double {
        var total = 0, count = 0
        for y in 0..<image.height {
            for x in 1..<image.width {
                let a = image[x - 1, y], b = image[x, y]
                total += abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b))
                count += 3
            }
        }
        return Double(total) / Double(count)
    }

    @Test func noiseIsASmoothFieldWithALittleGrainNotRandomPixels() {
        let image = Fixtures.noise(200, 160, seed: 1)
        // Neighbours differ by the field's slope (a few levels) and the grain (up to 6): far below random pixels' 85.
        let step = meanStep(image)
        #expect(step > 1, "it still has grain: \(step)")
        #expect(step < 10, "neighbours are close: \(step)")
        // The field spans a wide range of colour, and the grain keeps nearly every pixel's colour its own.
        #expect(image.distinctColors.count > 12_000, "\(image.distinctColors.count) colours in 32 000 pixels")
        let reds = Set(stride(from: 0, to: image.rgba.count, by: 4).map { image.rgba[$0] })
        #expect(reds.count > 100)
    }

    @Test func randomNoiseIsUncorrelatedAndKeepsAnotherNameForIt() {
        let image = Fixtures.randomNoise(50, 50, seed: 1)
        #expect(image.distinctColors.count > 2000)
        #expect(meanStep(image) > 70, "uniform random channels differ by 85 on average")
        #expect(Fixtures.randomNoise(30, 20, seed: 4) == Fixtures.randomNoise(30, 20, seed: 4))
        #expect(Fixtures.randomNoise(30, 20, seed: 4) != Fixtures.randomNoise(30, 20, seed: 5))
        #expect(Fixtures.randomNoise(30, 20, seed: 4) != Fixtures.noise(30, 20, seed: 4))
    }

    @Test func alphaGradientCoversTheWholeAlphaRange() {
        let image = Fixtures.alphaGradient(256, 8)
        let alphas = Set(stride(from: 3, to: image.rgba.count, by: 4).map { image.rgba[$0] })
        #expect(alphas.count == 256)
    }

    @Test func binaryAlphaIsOnlyZeroOrFullAndHasBoth() {
        let alphas = Set(Fixtures.binaryAlpha(40, 40).distinctColors.map(\.a))
        #expect(alphas == [0, 255])
    }

    @Test func allTransparentIsTransparentWithVariedColour() {
        let colors = Fixtures.allTransparent(30, 30).distinctColors
        #expect(colors.allSatisfy { $0.a == 0 })
        #expect(colors.count > 100)
    }

    @Test(arguments: [1, 2, 3, 4, 5, 16, 17, 256, 257])
    func aPaletteHasExactlyThatManyColours(_ colors: Int) {
        let image = Fixtures.palette(colors, 40, 30)
        #expect(image.distinctColors.count == colors)
        if colors >= 2 { #expect(image.distinctColors.contains { $0.a < 255 }, "some colours are translucent") }
        #expect(!image.distinctColors.contains { $0.a == 0 })
    }

    @Test func runsHaveARasterRunLongerThan4096() {
        let image = Fixtures.runs(200, 150)
        var longest = 1, current = 1
        var previous = image[0, 0]
        for index in 1..<(200 * 150) {
            let pixel = image[index % 200, index / 200]
            current = pixel == previous ? current + 1 : 1
            longest = max(longest, current)
            previous = pixel
        }
        #expect(longest > 4096)
    }

    @Test func repeatedTilesRepeatTheirTileAtSeveralOffsets() {
        let image = Fixtures.repeatedTiles(64, 40)
        // The lattice puts the tile at (0, 0), (11, 0), (22, 0) and (0, 9) among others.
        for (originX, originY) in [(11, 0), (22, 0), (0, 9), (11, 9)] {
            for row in 0..<5 {
                for column in 0..<7 { #expect(image[originX + column, originY + row] == image[column, row]) }
            }
        }
        #expect(image.distinctColors.count > 4)
    }
}
