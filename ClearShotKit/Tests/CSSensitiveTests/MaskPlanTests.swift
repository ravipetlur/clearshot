import CoreGraphics
import Testing
@testable import CSSensitive

/// Which masks Mask All adds: one per finding, sized by `MaskGeometry`, placed in the annotation document's own
/// coordinates (base pixels, never points) however the capture has been turned, resized or cropped since.
struct MaskPlanTests {
    private let image = CGSize(width: 1000, height: 800)

    private func finding(_ rect: CGRect, _ kind: SensitiveKind = .contact) -> ImageFinding {
        ImageFinding(kind: kind, rect: rect)
    }

    // MARK: A capture nothing has changed: the image's pixels are the base's

    @Test func eachFindingGetsOnePixelateMaskOverItsBoxPlusTheMargin() {
        let findings = [finding(CGRect(x: 200, y: 100, width: 120, height: 28)), finding(CGRect(x: 40, y: 500, width: 300, height: 20), .keyOrToken)]
        let masks = MaskPlan.masks(for: findings, imageSize: image, toBase: .identity, baseSize: image, pixelScale: 1)
        #expect(masks.count == 2)
        for (mask, finding) in zip(masks, findings) {
            #expect(mask.rect == MaskGeometry.maskRect(for: finding.rect, imageSize: image))
        }
    }

    @Test func theIntensityComesFromTheMasksHeightAndTheCapturesPixelScale() {
        let box = CGRect(x: 200, y: 100, width: 120, height: 28)
        for scale in [1.0, 2.0, 3.0] {
            let masks = MaskPlan.masks(for: [finding(box)], imageSize: image, toBase: .identity, baseSize: image, pixelScale: scale)
            let rect = MaskGeometry.maskRect(for: box, imageSize: image)
            #expect(masks.first?.intensity == Int(MaskGeometry.pixelateIntensity(forHeight: rect.height, pixelScale: scale)), "scale \(scale)")
        }
        // Spelled out for a Retina capture: a 28 px box has a 32 px mask, and the smallest block of 3 × 2 px per step
        // that reaches 32 px is the sixth.
        #expect(MaskPlan.masks(for: [finding(box)], imageSize: image, toBase: .identity, baseSize: image, pixelScale: 2).first?.intensity == 6)
        // On a 1x capture it needs a 32 px block, more than the strongest setting's 30 px: the strongest it is.
        #expect(MaskPlan.masks(for: [finding(box)], imageSize: image, toBase: .identity, baseSize: image, pixelScale: 1).first?.intensity == 10)
    }

    @Test func aRetinaCapturesMasksAreInPixelsNotPoints() {
        // The finding is in the image's pixels and the document's objects are in base pixels, which on a 2x capture are
        // twice the points: the scale reaches the intensity only, never the rectangle.
        let box = CGRect(x: 200, y: 100, width: 120, height: 28)
        let mask = MaskPlan.masks(for: [finding(box)], imageSize: image, toBase: .identity, baseSize: image, pixelScale: 2)[0]
        #expect(mask.rect == MaskGeometry.maskRect(for: box, imageSize: image))
        #expect(mask.rect.origin.x > 150 && mask.rect.origin.y > 90, "not halved into points")
        #expect(mask.rect.contains(box))
    }

    @Test func theIntensityIsAWholeNumberFromOneToTen() {
        for height in [1.0, 6, 12, 20, 28, 60, 400] as [CGFloat] {
            let masks = MaskPlan.masks(for: [finding(CGRect(x: 100, y: 100, width: 80, height: height))], imageSize: image,
                                       toBase: .identity, baseSize: image, pixelScale: 2)
            #expect((1...10).contains(masks.first?.intensity ?? 0), "height \(height)")
        }
    }

    @Test func noFindingsAreNoMasks() {
        #expect(MaskPlan.masks(for: [], imageSize: image, toBase: .identity, baseSize: image, pixelScale: 1).isEmpty)
    }

    @Test func masksKeepTheOrderOfTheFindings() {
        let findings = (0..<5).map { finding(CGRect(x: 10, y: 100 * $0 + 10, width: 50, height: 16)) }
        let masks = MaskPlan.masks(for: findings, imageSize: image, toBase: .identity, baseSize: image, pixelScale: 1)
        #expect(masks.map(\.rect.minY) == masks.map(\.rect.minY).sorted())
        #expect(masks.count == 5)
    }

    @Test func aFindingOutsideTheImageHasNoMask() {
        let outside = finding(CGRect(x: 5000, y: 5000, width: 50, height: 16))
        let inside = finding(CGRect(x: 10, y: 10, width: 50, height: 16))
        let masks = MaskPlan.masks(for: [outside, inside], imageSize: image, toBase: .identity, baseSize: image, pixelScale: 1)
        #expect(masks.count == 1)
        #expect(masks.first?.rect == MaskGeometry.maskRect(for: inside.rect, imageSize: image))
    }

    // MARK: A capture that has been turned, resized or cropped: the image is a render of the document

    /// A 400 x 200 base with a line of text 120 px long and 12 px thick at (100, 50), which reads horizontally there: a capture's
    /// text does. Turned a quarter, the render is 200 x 400 and the text runs down it.
    private let baseText = CGRect(x: 100, y: 50, width: 120, height: 12)
    private let turnedSize = CGSize(width: 200, height: 400)
    private let baseOfTurned = CGSize(width: 400, height: 200)

    /// The four ways a 400 x 200 base is turned a quarter, as `Renderer.baseMapping` has them: render pixel → base pixel.
    private var quarterTurns: [(name: String, toBase: CGAffineTransform)] {
        [
            // Turned right: output (x, y) is base (y, 200 − x).
            ("90°", CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 200)),
            // Turned left: output (x, y) is base (400 − y, x).
            ("270°", CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 400, ty: 0)),
            // Turned right and flipped: output (x, y) is base (y, x).
            ("90° flipped", CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)),
            // Turned left and flipped: output (x, y) is base (400 − y, 200 − x).
            ("270° flipped", CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 400, ty: 200)),
        ]
    }

    @Test func aTurnedPicturesMasksHaveTheWideMarginAlongTheTextInTheBase() {
        // Where the text is in the turned render: tall and thin (12 wide, 120 tall). Whatever the turn, the mask in the base is
        // the text's own box plus a margin of 3 px (a fifth of 12, rounded up) along its length and 2 px above and below.
        for (name, toBase) in quarterTurns {
            let inRender = baseText.applying(toBase.inverted()).standardized
            #expect(inRender.width == 12 && inRender.height == 120, "\(name): the text runs down the render")
            let mask = MaskPlan.masks(for: [finding(inRender)], imageSize: turnedSize, toBase: toBase, baseSize: baseOfTurned, pixelScale: 1)[0]
            #expect(mask.rect == baseText.insetBy(dx: -3, dy: -2), "\(name): \(mask.rect)")
            #expect(mask.rect.width == 126 && mask.rect.height == 16, "\(name)")
            // The block is chosen for the text's height in the base, 16 px with its margin, not for the 126 px it is long.
            #expect(mask.intensity == Int(MaskGeometry.pixelateIntensity(forHeight: 16, pixelScale: 1)), "\(name)")
            #expect(mask.intensity != Int(MaskGeometry.pixelateIntensity(forHeight: 126, pixelScale: 1)), "\(name)")
        }
    }

    @Test func aThickerLineGetsAWiderMarginAlongItInEveryTurn() {
        // The margin along the text is a fifth of its thickness, up to 16 px: for a line 40 px thick, 8 px, where the old
        // behaviour left the 2 px that were meant for above and below. The mask reaches 8 px past each end of the text, and a
        // tenth of its thickness, 4 px, above and below.
        let text = CGRect(x: 100, y: 50, width: 200, height: 40)
        for (name, toBase) in quarterTurns {
            let inRender = text.applying(toBase.inverted()).standardized
            let mask = MaskPlan.masks(for: [finding(inRender)], imageSize: turnedSize, toBase: toBase, baseSize: baseOfTurned, pixelScale: 1)[0]
            #expect(mask.rect == text.insetBy(dx: -8, dy: -4), "\(name): \(mask.rect)")
        }
    }

    // MARK: Text that runs down the base itself

    /// A finding, as the scanner has it: on one line, or over several (a private key's block).
    private func finding(_ rect: CGRect, _ kind: SensitiveKind = .contact, spansLines: Bool) -> ImageFinding {
        ImageFinding(kind: kind, rect: rect, spansLines: spansLines)
    }

    @Test func aSingleLineFindingTallerThanWideRunsDownThePictureWhateverTheMapping() {
        // A capture turned from the thumbnail's menu is turned itself: its text runs down the base, and the mapping to the base
        // is the identity. The box is 12 wide and 120 tall, so its text runs down it: the wide margin (3, from the 12 px
        // thickness) goes above and below, 2 px to each side.
        let box = CGRect(x: 100, y: 100, width: 12, height: 120)
        let mask = MaskPlan.masks(for: [finding(box)], imageSize: image, toBase: .identity, baseSize: image, pixelScale: 1)[0]
        #expect(mask.rect == box.insetBy(dx: -2, dy: -3))
        // Its block is chosen for the text's thickness in the base (16 px with its margin), not for the 126 px it is long.
        #expect(mask.intensity == Int(MaskGeometry.pixelateIntensity(forHeight: 16, pixelScale: 1)))
        #expect(mask.intensity != Int(MaskGeometry.pixelateIntensity(forHeight: 126, pixelScale: 1)))
        // The same text on a line across the picture keeps the old margins.
        let across = CGRect(x: 100, y: 100, width: 120, height: 12)
        #expect(MaskPlan.masks(for: [finding(across)], imageSize: image, toBase: .identity, baseSize: image, pixelScale: 1)[0].rect
                == across.insetBy(dx: -3, dy: -2))
    }

    @Test func aBlocksShapeSaysNothingAboutWhichWayItsTextRuns() {
        // Taller than wide because it has many lines, not because it is turned: its margins are the horizontal ones, from its
        // height (a fifth to each side, and a tenth above and below, each to 16 px at most).
        let block = CGRect(x: 100, y: 100, width: 100, height: 300)
        let mask = MaskPlan.masks(for: [finding(block, .keyOrToken, spansLines: true)], imageSize: image, toBase: .identity,
                                  baseSize: image, pixelScale: 1)[0]
        #expect(mask.rect == block.insetBy(dx: -16, dy: -16))
        // The same box as a single line, more than twice as tall as wide, would be text running down the picture: the wide
        // margin from its thickness (100, so 16) above and below, a tenth of the thickness (10) to each side.
        let strip = MaskPlan.masks(for: [finding(block, .keyOrToken, spansLines: false)], imageSize: image, toBase: .identity,
                                   baseSize: image, pixelScale: 1)[0]
        #expect(strip.rect == block.insetBy(dx: -10, dy: -16))
    }

    @Test func aBlocksMarginAboveAndBelowStopsAtSixteenPixels() {
        // 300 px tall: a tenth would be 30. A single line that tall would get it; a block of lines gets 16.
        let box = CGRect(x: 100, y: 100, width: 300, height: 300)
        let block = MaskPlan.masks(for: [finding(box, .keyOrToken, spansLines: true)], imageSize: image, toBase: .identity,
                                   baseSize: image, pixelScale: 1)[0]
        #expect(block.rect == box.insetBy(dx: -16, dy: -16))
        let line = MaskPlan.masks(for: [finding(box, .keyOrToken, spansLines: false)], imageSize: image, toBase: .identity,
                                  baseSize: image, pixelScale: 1)[0]
        #expect(line.rect == box.insetBy(dx: -16, dy: -30))
        // Small blocks keep what they had: 40 px tall, 4.
        let small = CGRect(x: 100, y: 100, width: 300, height: 40)
        #expect(MaskPlan.masks(for: [finding(small, .keyOrToken, spansLines: true)], imageSize: image, toBase: .identity,
                               baseSize: image, pixelScale: 1)[0].rect == small.insetBy(dx: -8, dy: -4))
    }

    @Test func aBlockInATurnedPicturesCapIsInTheReadingAxes() {
        // The block's lines run down a quarter-turned render; its height in the base is the render's width. The cap is on the
        // margin along that height, which lies to each side in the render: 16, not a tenth of 300.
        // A square 400 x 400 base turned right: output (x, y) is base (y, 400 − x).
        let toBase = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 400)
        let block = CGRect(x: 20, y: 40, width: 300, height: 100)
        let mask = MaskPlan.masks(for: [finding(block, .keyOrToken, spansLines: true)], imageSize: CGSize(width: 400, height: 400),
                                  toBase: toBase, baseSize: CGSize(width: 400, height: 400), pixelScale: 1)[0]
        let placed = block.insetBy(dx: -16, dy: -16).applying(toBase).standardized
        #expect(mask.rect == placed)
    }

    @Test func aSingleLineIsOnlyTakenForVerticalTextWhenItIsClearlyLongerThanWide() {
        // A short narrow value ("ijl" at 16 px: 14 wide, 20 tall) isn't text running down the picture; at more than twice as
        // tall as wide it is. Just twice is not.
        func mask(_ box: CGRect) -> CGRect {
            MaskPlan.masks(for: [finding(box)], imageSize: image, toBase: .identity, baseSize: image, pixelScale: 1)[0].rect
        }
        let narrow = CGRect(x: 100, y: 100, width: 14, height: 20)
        #expect(mask(narrow) == MaskGeometry.maskRect(for: narrow, imageSize: image))
        let twice = CGRect(x: 100, y: 100, width: 10, height: 20)
        #expect(mask(twice) == MaskGeometry.maskRect(for: twice, imageSize: image))
        let clearly = CGRect(x: 100, y: 100, width: 10, height: 21)
        #expect(mask(clearly) == MaskGeometry.maskRect(for: clearly, imageSize: image, textRunsVertically: true))
        #expect(mask(clearly) != MaskGeometry.maskRect(for: clearly, imageSize: image))
    }

    @Test func aBlockInATurnedPictureStillFollowsTheTurn() {
        // The turn, not the shape, says where a block's lines run: the toBase of a quarter turn puts the margins the other way.
        let (_, toBase) = quarterTurns[0]
        let block = CGRect(x: 40, y: 20, width: 100, height: 300)
        let mask = MaskPlan.masks(for: [finding(block, .keyOrToken, spansLines: true)], imageSize: turnedSize, toBase: toBase,
                                  baseSize: baseOfTurned, pixelScale: 1)[0]
        let expected = MaskGeometry.maskRect(for: block, imageSize: turnedSize, textRunsVertically: true, isBlock: true)
            .applying(toBase).standardized
        #expect(mask.rect == expected)
    }

    @Test func aSingleLineThatReadsAcrossATurnedPictureKeepsTheAcrossMargins() {
        // Turned from the thumbnail and turned back in Annotate: the mapping is a quarter turn, but the text reads across the
        // render, and it is the shape that says so.
        for (name, toBase) in quarterTurns {
            let text = CGRect(x: 40, y: 100, width: 120, height: 12)
            let mask = MaskPlan.masks(for: [finding(text)], imageSize: turnedSize, toBase: toBase, baseSize: baseOfTurned, pixelScale: 1)
            let expected = MaskGeometry.maskRect(for: text, imageSize: turnedSize).applying(toBase).standardized
            #expect(mask.first?.rect == expected, "\(name)")
        }
    }

    @Test func aTurnedAndShrunkPicturesMarginsScaleToTheBase() {
        // Turned right and halved: output (x, y) is base (2y, 200 − 2x), a render of 100 x 200 for the same 400 x 200 base.
        let toBase = CGAffineTransform(a: 0, b: -2, c: 2, d: 0, tx: 0, ty: 200)
        let inRender = baseText.applying(toBase.inverted()).standardized
        #expect(inRender == CGRect(x: 69, y: 50, width: 6, height: 60))
        let mask = MaskPlan.masks(for: [finding(inRender)], imageSize: CGSize(width: 100, height: 200), toBase: toBase,
                                  baseSize: baseOfTurned, pixelScale: 2)[0]
        // In the render: 2 px along (a fifth of 6, rounded up, at least 2) and 2 across. Each render pixel is 2 base pixels.
        #expect(mask.rect == CGRect(x: 96, y: 46, width: 128, height: 20))
        #expect(mask.intensity == Int(MaskGeometry.pixelateIntensity(forHeight: 20, pixelScale: 2)))
    }

    @Test func aFlipAloneOrNoTurnKeepsTheMarginsWhereTheyWere() {
        // Not a quarter turn: the text runs across the render and the base alike.
        let mirrored = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 400, ty: 0)
        let upsideDown = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 200)
        for toBase in [CGAffineTransform.identity, mirrored, upsideDown] {
            let inRender = baseText.applying(toBase.inverted()).standardized
            let mask = MaskPlan.masks(for: [finding(inRender)], imageSize: baseOfTurned, toBase: toBase, baseSize: baseOfTurned, pixelScale: 1)[0]
            #expect(mask.rect == baseText.insetBy(dx: -3, dy: -2))
        }
    }

    @Test func aShrunkPicturesMasksAreInTheBasesLargerPixels() {
        // A resize to half: output px are two base px.
        let toBase = CGAffineTransform(scaleX: 2, y: 2)
        let rendered = CGSize(width: 500, height: 400)
        let box = CGRect(x: 100, y: 50, width: 60, height: 10)
        let mask = MaskPlan.masks(for: [finding(box)], imageSize: rendered, toBase: toBase, baseSize: image, pixelScale: 2)[0]
        let inRendered = MaskGeometry.maskRect(for: box, imageSize: rendered)
        #expect(mask.rect == CGRect(x: inRendered.minX * 2, y: inRendered.minY * 2, width: inRendered.width * 2, height: inRendered.height * 2))
        #expect(mask.intensity == Int(MaskGeometry.pixelateIntensity(forHeight: inRendered.height * 2, pixelScale: 2)))
    }

    @Test func aCroppedOrFramedPicturesMasksAreShiftedBackToTheBase() {
        // The render starts 40 px left of and 30 px above the base (a background frame, say): its pixel (0, 0) is base (−40, −30).
        let toBase = CGAffineTransform(translationX: -40, y: -30)
        let rendered = CGSize(width: 600, height: 500)
        let box = CGRect(x: 140, y: 130, width: 100, height: 20)
        let mask = MaskPlan.masks(for: [finding(box)], imageSize: rendered, toBase: toBase, baseSize: CGSize(width: 520, height: 440),
                                  pixelScale: 1)[0]
        let inRendered = MaskGeometry.maskRect(for: box, imageSize: rendered)
        #expect(mask.rect == inRendered.offsetBy(dx: -40, dy: -30))
    }

    @Test func whatLiesOutsideTheBaseCantBeMaskedByARedactionAndIsLeftOut() {
        // A render with a 40 px frame: a finding in the frame (wallpaper text) isn't in the base at all.
        let toBase = CGAffineTransform(translationX: -40, y: -40)
        let rendered = CGSize(width: 480, height: 380)
        let base = CGSize(width: 400, height: 300)
        let inFrame = finding(CGRect(x: 5, y: 5, width: 20, height: 12))
        let inside = finding(CGRect(x: 100, y: 100, width: 80, height: 14))
        // Half in the frame, half in the picture: what is in the picture is masked.
        let straddling = finding(CGRect(x: 20, y: 100, width: 60, height: 14))
        let masks = MaskPlan.masks(for: [inFrame, inside, straddling], imageSize: rendered, toBase: toBase, baseSize: base, pixelScale: 1)
        #expect(masks.count == 2)
        for mask in masks {
            #expect(CGRect(origin: .zero, size: base).contains(mask.rect))
        }
        #expect(masks[1].rect.minX == 0)
    }

    @Test func aMirroredPictureStillGivesRealRectangles() {
        // Flipped horizontally: output x is 400 − base x.
        let toBase = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 400, ty: 0)
        let box = CGRect(x: 50, y: 20, width: 100, height: 20)
        let mask = MaskPlan.masks(for: [finding(box)], imageSize: CGSize(width: 400, height: 100), toBase: toBase,
                                  baseSize: CGSize(width: 400, height: 100), pixelScale: 1)[0]
        let inRendered = MaskGeometry.maskRect(for: box, imageSize: CGSize(width: 400, height: 100))
        #expect(mask.rect == CGRect(x: 400 - inRendered.maxX, y: inRendered.minY, width: inRendered.width, height: inRendered.height))
        #expect(mask.rect.width > 0 && mask.rect.height > 0)
    }

    @Test func numbersThatArentNumbersMakeNoMasksAndDontCrash() {
        let box = finding(CGRect(x: 10, y: 10, width: 50, height: 16))
        let broken = CGAffineTransform(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0)
        #expect(MaskPlan.masks(for: [box], imageSize: image, toBase: broken, baseSize: image, pixelScale: 1).isEmpty)
        #expect(MaskPlan.masks(for: [box], imageSize: image, toBase: .identity, baseSize: .zero, pixelScale: 1).isEmpty)
        // A scale that isn't a positive number counts as 1, as the redaction takes it.
        let nan = MaskPlan.masks(for: [box], imageSize: image, toBase: .identity, baseSize: image, pixelScale: .nan)
        #expect(nan == MaskPlan.masks(for: [box], imageSize: image, toBase: .identity, baseSize: image, pixelScale: 1))
        // Nothing that can't be inverted (all of the picture on one line) is a rectangle.
        let flat = CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 5, ty: 5)
        #expect(MaskPlan.masks(for: [box], imageSize: image, toBase: flat, baseSize: image, pixelScale: 1).isEmpty)
    }
}
