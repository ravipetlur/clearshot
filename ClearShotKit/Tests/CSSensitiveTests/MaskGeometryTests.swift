import CoreGraphics
import Testing
@testable import CSSensitive

/// How a mask is sized from a finding: its box plus a margin, kept inside the image, and a Pixelate intensity whose blocks
/// are at least as tall as the text.
struct MaskGeometryTests {
    private let image = CGSize(width: 500, height: 400)

    // MARK: The rectangle

    @Test func aMaskIsTheFindingPlusAMarginOnEverySide() {
        // 20 px tall: 2 px above and below, 4 px (a fifth of the height) to each side.
        let mask = MaskGeometry.maskRect(for: CGRect(x: 100, y: 100, width: 50, height: 20), imageSize: image)
        #expect(mask == CGRect(x: 96, y: 98, width: 58, height: 24))
    }

    @Test(arguments: [
        // height, vertical margin: a tenth of the height rounded up, at least 2 px, so it grows with the text
        (8.0, 2.0), (20.0, 2.0), (40.0, 4.0), (60.0, 6.0), (200.0, 20.0),
        (0.0, 2.0), (10.0, 2.0), (21.0, 3.0), (30.0, 3.0), (100.0, 10.0), (101.0, 11.0),
    ])
    func theVerticalMarginIsATenthOfTheHeightRoundedUpFromTwoPixels(height: Double, margin: Double) {
        #expect(MaskGeometry.verticalMargin(forHeight: CGFloat(height)) == CGFloat(margin))
        let mask = MaskGeometry.maskRect(for: CGRect(x: 1000, y: 1000, width: 300, height: CGFloat(height)), imageSize: CGSize(width: 3000, height: 3000))
        #expect(mask.minY == 1000 - CGFloat(margin) && mask.maxY == 1000 + CGFloat(height) + CGFloat(margin), "height \(height)")
    }

    @Test(arguments: [
        // height, horizontal margin: a fifth of the height rounded up, at least 2 and at most 16 px
        (8.0, 2.0), (20.0, 4.0), (40.0, 8.0), (60.0, 12.0), (200.0, 16.0),
        (0.0, 2.0), (10.0, 2.0), (11.0, 3.0), (80.0, 16.0), (81.0, 16.0), (33.0, 7.0),
    ])
    func theHorizontalMarginIsAFifthOfTheHeightRoundedUpFromTwoToSixteen(height: Double, margin: Double) {
        #expect(MaskGeometry.horizontalMargin(forHeight: CGFloat(height)) == CGFloat(margin))
        let mask = MaskGeometry.maskRect(for: CGRect(x: 1000, y: 1000, width: 300, height: CGFloat(height)), imageSize: CGSize(width: 3000, height: 3000))
        #expect(mask.minX == 1000 - CGFloat(margin) && mask.maxX == 1300 + CGFloat(margin), "height \(height)")
    }

    @Test(arguments: [
        // height, a block's vertical margin: the same tenth, but 16 px at most
        (8.0, 2.0), (20.0, 2.0), (40.0, 4.0), (60.0, 6.0), (160.0, 16.0), (161.0, 16.0), (200.0, 16.0), (300.0, 16.0), (1000.0, 16.0),
    ])
    func aBlocksVerticalMarginIsTheSameTenthButStopsAtSixteen(height: Double, margin: Double) {
        #expect(MaskGeometry.verticalMargin(forHeight: CGFloat(height), ofBlock: true) == CGFloat(margin))
        let box = CGRect(x: 1000, y: 1000, width: 300, height: CGFloat(height))
        let mask = MaskGeometry.maskRect(for: box, imageSize: CGSize(width: 3000, height: 3000), isBlock: true)
        #expect(mask.minY == 1000 - CGFloat(margin) && mask.maxY == 1000 + CGFloat(height) + CGFloat(margin), "height \(height)")
        // A line that tall keeps the tenth.
        #expect(MaskGeometry.verticalMargin(forHeight: CGFloat(height)) == max(2, (CGFloat(height) / 10).rounded(.up)))
    }

    @Test func aBlocksCapAppliesInTheReadingAxesOfTurnedText() {
        // Text running down the image, in a block 300 px thick (its lines' direction across): the capped margin goes to each side.
        let mask = MaskGeometry.maskRect(for: CGRect(x: 1000, y: 1000, width: 300, height: 100), imageSize: CGSize(width: 3000, height: 3000),
                                         textRunsVertically: true, isBlock: true)
        #expect(mask.minX == 984 && mask.maxX == 1316, "\(mask)")
        #expect(mask.minY == 984 && mask.maxY == 1116, "\(mask)")
    }

    @Test func aTallerTextGetsAMarginAboveAndBelowThatGrowsWithIt() {
        // The 2 px that did for a line of text leave a block of lines, or big type, with its first and last row barely covered.
        let small = MaskGeometry.maskRect(for: CGRect(x: 100, y: 100, width: 200, height: 20), imageSize: image)
        let block = MaskGeometry.maskRect(for: CGRect(x: 100, y: 100, width: 200, height: 200), imageSize: image)
        #expect(small.minY == 98 && small.maxY == 122)
        #expect(block.minY == 80 && block.maxY == 320)
    }

    @Test func aFractionalBoxKeepsItsFractions() {
        let mask = MaskGeometry.maskRect(for: CGRect(x: 10.5, y: 10.25, width: 20.5, height: 8.75), imageSize: image)
        #expect(mask == CGRect(x: 8.5, y: 8.25, width: 24.5, height: 12.75))
    }

    @Test func theMaskIsKeptInsideTheImage() {
        // At the top left: the margin that would leave the image is cut.
        #expect(MaskGeometry.maskRect(for: CGRect(x: 1, y: 1, width: 10, height: 10), imageSize: image)
                == CGRect(x: 0, y: 0, width: 13, height: 13))
        // At the bottom right.
        #expect(MaskGeometry.maskRect(for: CGRect(x: 490, y: 390, width: 10, height: 10), imageSize: image)
                == CGRect(x: 488, y: 388, width: 12, height: 12))
        // Along the top edge only, and along the left edge only (20 px tall: 4 px at the sides).
        #expect(MaskGeometry.maskRect(for: CGRect(x: 100, y: 0, width: 50, height: 20), imageSize: image)
                == CGRect(x: 96, y: 0, width: 58, height: 22))
        #expect(MaskGeometry.maskRect(for: CGRect(x: 0, y: 100, width: 50, height: 20), imageSize: image)
                == CGRect(x: 0, y: 98, width: 54, height: 24))
    }

    @Test func aBoxThatSticksOutOfTheImageIsCutToIt() {
        // Vision's boxes can reach a little past the image.
        // 30 px tall: 6 px at the sides, 3 above and below.
        #expect(MaskGeometry.maskRect(for: CGRect(x: -5, y: -3, width: 60, height: 30), imageSize: image)
                == CGRect(x: 0, y: 0, width: 61, height: 30))
        // 40 px tall: 8 px at the sides, 4 above and below.
        #expect(MaskGeometry.maskRect(for: CGRect(x: 480, y: 380, width: 40, height: 40), imageSize: image)
                == CGRect(x: 472, y: 376, width: 28, height: 24))
        #expect(MaskGeometry.maskRect(for: CGRect(x: -50, y: -50, width: 700, height: 600), imageSize: image)
                == CGRect(origin: .zero, size: image))
    }

    @Test func aBoxOutsideTheImageHasNoMask() {
        #expect(MaskGeometry.maskRect(for: CGRect(x: 600, y: 100, width: 50, height: 20), imageSize: image) == .zero)
        #expect(MaskGeometry.maskRect(for: CGRect(x: 100, y: 450, width: 50, height: 20), imageSize: image) == .zero)
        // Within the margin of the image's edge it still reaches in.
        #expect(MaskGeometry.maskRect(for: CGRect(x: 501, y: 100, width: 50, height: 20), imageSize: image)
                == CGRect(x: 497, y: 98, width: 3, height: 24))
    }

    @Test(arguments: [CGRect.null, CGRect.infinite, CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)])
    func aBoxThatIsNotARealRectangleHasNoMask(box: CGRect) {
        #expect(MaskGeometry.maskRect(for: box, imageSize: image) == .zero)
    }

    @Test func anImageWithNoAreaHasNoMask() {
        #expect(MaskGeometry.maskRect(for: CGRect(x: 0, y: 0, width: 10, height: 10), imageSize: .zero) == .zero)
    }

    // MARK: Text that runs down the picture

    /// A box and an image with x and y swapped: what the picture looks like turned a quarter and mirrored along its diagonal.
    private func transposed(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
    }

    @Test func textThatRunsDownThePictureGetsItsWideMarginAlongItAndTwoPixelsAcross() {
        // 12 px thick and 120 px long, reading from top to bottom: the margin along the text is a fifth of the thickness rounded
        // up (3), above and below; across it, 2 px, at each side.
        let mask = MaskGeometry.maskRect(for: CGRect(x: 100, y: 100, width: 12, height: 120), imageSize: image, textRunsVertically: true)
        #expect(mask == CGRect(x: 98, y: 97, width: 16, height: 126))
        // Horizontally the same text, turned, gets the same margins along and across it.
        let flat = MaskGeometry.maskRect(for: CGRect(x: 100, y: 100, width: 120, height: 12), imageSize: image)
        #expect(flat == CGRect(x: 97, y: 98, width: 126, height: 16))
    }

    @Test(arguments: [8.0, 20, 40, 60, 80, 200] as [CGFloat])
    func theMarginAlongTheTextFollowsItsThicknessNotItsLength(thickness: CGFloat) {
        let box = CGRect(x: 1000, y: 1000, width: thickness, height: 300)
        let mask = MaskGeometry.maskRect(for: box, imageSize: CGSize(width: 3000, height: 3000), textRunsVertically: true)
        let along = MaskGeometry.horizontalMargin(forHeight: thickness)
        let across = MaskGeometry.verticalMargin(forHeight: thickness)
        #expect(mask.minY == 1000 - along && mask.maxY == 1300 + along, "thickness \(thickness)")
        #expect(mask.minX == 1000 - across && mask.maxX == 1000 + thickness + across, "thickness \(thickness)")
    }

    @Test func theVerticalRuleIsTheHorizontalOneInTheTransposedPicture() {
        let size = CGSize(width: 500, height: 400)
        let boxes = [CGRect(x: 100, y: 100, width: 12, height: 120), CGRect(x: 1, y: 1, width: 14, height: 40),
                     CGRect(x: 480, y: 300, width: 30, height: 150), CGRect(x: -5, y: -3, width: 30, height: 60),
                     CGRect(x: 10.5, y: 10.25, width: 8.75, height: 20.5)]
        for box in boxes {
            let vertical = MaskGeometry.maskRect(for: box, imageSize: size, textRunsVertically: true)
            let horizontal = MaskGeometry.maskRect(for: transposed(box), imageSize: CGSize(width: size.height, height: size.width))
            #expect(vertical == transposed(horizontal), "\(box)")
        }
    }

    @Test func theVerticalMaskIsKeptInsideTheImageAndNothingOutsideItIsMasked() {
        #expect(MaskGeometry.maskRect(for: CGRect(x: 1, y: 1, width: 10, height: 50), imageSize: image, textRunsVertically: true)
                == CGRect(x: 0, y: 0, width: 13, height: 53)) // 10 px thick: 2 px along, cut at the top; 2 px across, cut at the left
        #expect(MaskGeometry.maskRect(for: CGRect(x: 100, y: 450, width: 12, height: 50), imageSize: image, textRunsVertically: true) == .zero)
        #expect(MaskGeometry.maskRect(for: .null, imageSize: image, textRunsVertically: true) == .zero)
        #expect(MaskGeometry.maskRect(for: CGRect(x: 0, y: 0, width: 10, height: 10), imageSize: .zero, textRunsVertically: true) == .zero)
    }

    @Test func textRunsAcrossByDefault() {
        let box = CGRect(x: 100, y: 100, width: 50, height: 20)
        #expect(MaskGeometry.maskRect(for: box, imageSize: image) == MaskGeometry.maskRect(for: box, imageSize: image, textRunsVertically: false))
    }

    // MARK: The intensity

    /// Pixelate's block as `Redaction` makes it from an intensity (1…10) and the render's scale.
    private func block(intensity: Double, scale: Double) -> Int {
        max(3, Int((intensity * 3 * scale).rounded()))
    }

    @Test(arguments: [
        // height, scale, the intensity, the block that makes
        (8.0, 1.0, 4.0, 12),
        (8.0, 2.0, 2.0, 12),
        (20.0, 1.0, 7.0, 21),
        (20.0, 2.0, 4.0, 24),
        (60.0, 1.0, 10.0, 30),
        (60.0, 2.0, 10.0, 60),
    ])
    func theIntensityMakesTheBlockAsTallAsTheTextAtLeastTwelve(height: Double, scale: Double, intensity: Double, block: Int) {
        #expect(MaskGeometry.pixelateIntensity(forHeight: height, pixelScale: scale) == intensity)
        #expect(self.block(intensity: intensity, scale: scale) == block)
    }

    @Test func theBlockIsNeverUnderTwelvePixelsHoweverShortTheText() {
        for height in [0.0, 1, 4, 8, 11.9, 12] {
            let intensity = MaskGeometry.pixelateIntensity(forHeight: height, pixelScale: 1)
            #expect(intensity == 4, "height \(height)")
            #expect(block(intensity: intensity, scale: 1) >= 12)
        }
    }

    @Test(arguments: [1.0, 1.5, 2.0, 3.0])
    func theIntensityIsTheSmallestWholeOneWhoseBlockIsAsTallAsTheText(scale: Double) {
        for height in stride(from: 1.0, through: 150.0, by: 0.5) {
            let intensity = MaskGeometry.pixelateIntensity(forHeight: height, pixelScale: scale)
            let wanted = max(height, 12)
            // A whole number of the redaction's range.
            #expect(intensity == intensity.rounded() && (1...10).contains(intensity), "height \(height) at \(scale)×")
            if Double(block(intensity: 10, scale: scale)) >= wanted {
                // Within the range, the block is tall enough and one step less would not be.
                #expect(Double(block(intensity: intensity, scale: scale)) >= wanted, "height \(height) at \(scale)×")
                if intensity > 1 {
                    #expect(Double(block(intensity: intensity - 1, scale: scale)) < wanted, "height \(height) at \(scale)×")
                }
            } else {
                // Taller than the strongest block: the strongest intensity.
                #expect(intensity == 10, "height \(height) at \(scale)×")
            }
        }
    }

    @Test func aTallerBoxNeverGetsAGentlerIntensity() {
        for scale in [1.0, 2.0] {
            let intensities = stride(from: 1.0, through: 150.0, by: 1).map { MaskGeometry.pixelateIntensity(forHeight: $0, pixelScale: scale) }
            #expect(intensities == intensities.sorted())
        }
    }

    @Test(arguments: [0.0, -1, Double.nan, Double.infinity, -Double.infinity])
    func aScaleThatIsNotUsableCountsAsOne(scale: Double) {
        #expect(MaskGeometry.pixelateIntensity(forHeight: 20, pixelScale: scale) == 7)
    }

    @Test(arguments: [-5.0, Double.nan, -Double.infinity])
    func aHeightThatIsNotUsableCountsAsNothing(height: Double) {
        #expect(MaskGeometry.pixelateIntensity(forHeight: height, pixelScale: 1) == 4)
    }

    @Test func anInfiniteHeightIsTheStrongest() {
        #expect(MaskGeometry.pixelateIntensity(forHeight: Double.infinity, pixelScale: 2) == 10)
    }
}
