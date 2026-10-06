import Testing
@testable import CSRecording

/// Quality and "Optimize GIFs": the stabiliser's threshold, the palette size and dithering.
struct GIFQualityPlanTests {
    @Test func optimizeOffKeepsEveryChange() {
        for quality in stride(from: 0, through: 100, by: 10) {
            let plan = GIFQualityPlan(quality: quality, optimize: false)
            #expect(plan.threshold == 0)
            #expect(plan.paletteColors == 255)
            #expect(plan.dithers)
        }
    }

    /// Quality 100 with Optimize on: ±2 decode noise must not grow the GIF.
    @Test func qualityHundredWithOptimizeStillAbsorbsDecodeNoise() {
        let plan = GIFQualityPlan(quality: 100, optimize: true)
        #expect(plan.threshold == 6)
        #expect(plan.paletteColors == 255)
        #expect(plan.dithers)
    }

    @Test func lowerQualityRaisesTheThreshold() {
        #expect(GIFQualityPlan(quality: 0, optimize: true).threshold == 12)
        #expect(GIFQualityPlan(quality: 50, optimize: true).threshold == 9)
        let thresholds = stride(from: 0, through: 100, by: 10).map { GIFQualityPlan(quality: $0, optimize: true).threshold }
        #expect(zip(thresholds, thresholds.dropFirst()).allSatisfy { $0 >= $1 })
        // Out of range clamps.
        #expect(GIFQualityPlan(quality: -20, optimize: true) == GIFQualityPlan(quality: 0, optimize: true))
        #expect(GIFQualityPlan(quality: 140, optimize: true) == GIFQualityPlan(quality: 100, optimize: true))
    }

    @Test func paletteShrinksWithQuality() {
        #expect(GIFQualityPlan(quality: 0, optimize: true).paletteColors == 64)
        #expect(GIFQualityPlan(quality: 50, optimize: true).paletteColors == 159)
        let colors = stride(from: 0, through: 100, by: 10).map { GIFQualityPlan(quality: $0, optimize: true).paletteColors }
        #expect(zip(colors, colors.dropFirst()).allSatisfy { $0 < $1 })
        // Dithering from quality 70.
        #expect(!GIFQualityPlan(quality: 60, optimize: true).dithers)
        #expect(GIFQualityPlan(quality: 70, optimize: true).dithers)
    }
}
