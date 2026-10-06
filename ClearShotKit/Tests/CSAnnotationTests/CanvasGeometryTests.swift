import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

private func box(_ rect: CGRect) -> AnnotationObject {
    AnnotationObject(kind: .filledRectangle(rect), style: ObjectStyle(color: .black, lineWidth: 2, shadow: false))
}

private func isFinite(_ rect: CGRect) -> Bool {
    [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
}

/// Whole pixels, and standardized: `CGRect.width` is always positive, so the stored size is checked.
private func isWhole(_ rect: CGRect) -> Bool {
    [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy { $0.isFinite && $0 == $0.rounded() }
        && rect.size.width >= 0 && rect.size.height >= 0
}

struct CropRatioTests {
    @Test func theMenuListsTheRatiosInOrder() {
        #expect(CropRatio.presets.map(\.title) == ["Freeform", "Original", "1:1", "5:4", "7:5", "4:3", "3:2", "16:10", "16:9",
                                                   "2.35:1", "1.85:1", "4:5", "3:4", "2:3", "9:16"])
        #expect(CropRatio.custom(width: 3, height: 1).title == "Custom")
    }

    @Test func aspectsComeFromTheRatioOrThePicture() {
        let picture = CGSize(width: 100, height: 50)
        #expect(CropRatio.freeform.aspect(pictureSize: picture) == nil)
        #expect(CropRatio.original.aspect(pictureSize: picture) == 2)
        #expect(CropRatio.fixed(width: 16, height: 9).aspect(pictureSize: picture) == 16.0 / 9)
        #expect(CropRatio.custom(width: 3, height: 1).aspect(pictureSize: picture) == 3)
        #expect(CropRatio.custom(width: 0, height: 9).aspect(pictureSize: picture) == nil)
    }

    @Test func aRatioWithoutTwoPositiveFiniteSidesIsFreeform() {
        let picture = CGSize(width: 100, height: 50)
        let sides: [(Double, Double)] = [(3, 0), (0, 0), (-3, 1), (3, -1), (-3, -1), (.nan, 9), (3, .nan), (.infinity, 9), (3, .infinity)]
        for (width, height) in sides {
            #expect(CropRatio.custom(width: width, height: height).aspect(pictureSize: picture) == nil, "custom \(width):\(height)")
            #expect(CropRatio.fixed(width: width, height: height).aspect(pictureSize: picture) == nil, "fixed \(width):\(height)")
        }
    }

    @Test func theOriginalRatioNeedsAPictureWithASize() {
        let sizes = [CGSize(width: 0, height: 50), CGSize(width: 100, height: 0), CGSize(width: -100, height: 50),
                     CGSize(width: 100, height: -50), CGSize(width: Double.nan, height: 50), CGSize(width: Double.infinity, height: 50),
                     CGSize(width: 100, height: Double.infinity), CGSize(width: 1e300, height: 1e-300)]
        for size in sizes {
            #expect(CropRatio.original.aspect(pictureSize: size) == nil, "\(size)")
        }
    }

    @Test func customRatiosStayWithinOneToAHundred() {
        let picture = CGSize(width: 100, height: 50)
        #expect(CropRatio.custom(width: 1, height: 100).aspect(pictureSize: picture) == 0.01)
        #expect(CropRatio.custom(width: 100, height: 1).aspect(pictureSize: picture) == 100)
        #expect(CropRatio.custom(width: 1, height: 101).aspect(pictureSize: picture) == nil)
        #expect(CropRatio.custom(width: 101, height: 1).aspect(pictureSize: picture) == nil)
        #expect(CropRatio.custom(width: 1e300, height: 1e-300).aspect(pictureSize: picture) == nil)
        #expect(CropRatio.custom(width: 1e-320, height: 1).aspect(pictureSize: picture) == nil)
        #expect(CropRatio.custom(width: 1e-300, height: 1e300).aspect(pictureSize: picture) == nil)
    }

    @Test func titlesNeverTrap() {
        #expect(CropRatio.fixed(width: 1e30, height: 1).title == "1e+30:1")
        #expect(CropRatio.fixed(width: Double.nan, height: 1).title == "Custom")
        #expect(CropRatio.fixed(width: 4, height: Double.infinity).title == "Custom")
        #expect(CropRatio.fixed(width: 2.35, height: 1).title == "2.35:1")
    }
}

struct CropGeometryTests {
    let rect = CGRect(x: 10, y: 10, width: 100, height: 50)

    @Test func aFreeCornerDragMovesOnlyThatCorner() {
        #expect(CropGeometry.dragging(.corner(.bottomRight), of: rect, to: CGPoint(x: 150, y: 90), aspect: nil)
            == CGRect(x: 10, y: 10, width: 140, height: 80))
    }

    @Test func eachCornerKeepsItsOppositeCorner() {
        let drags: [(Corner, CGPoint, CGRect)] = [
            (.topLeft, CGPoint(x: 0, y: 0), CGRect(x: 0, y: 0, width: 110, height: 60)),
            (.topRight, CGPoint(x: 130, y: 0), CGRect(x: 10, y: 0, width: 120, height: 60)),
            (.bottomLeft, CGPoint(x: 0, y: 90), CGRect(x: 0, y: 10, width: 110, height: 80)),
            (.bottomRight, CGPoint(x: 150, y: 90), CGRect(x: 10, y: 10, width: 140, height: 80)),
        ]
        for (corner, point, expected) in drags {
            #expect(CropGeometry.dragging(.corner(corner), of: rect, to: point, aspect: nil) == expected, "\(corner)")
        }
        // Held to 2:1, the larger pull wins and the opposite corner still stays.
        let ratioDrags: [(Corner, CGPoint, CGRect)] = [
            (.topLeft, CGPoint(x: 0, y: 0), CGRect(x: -10, y: 0, width: 120, height: 60)),
            (.topRight, CGPoint(x: 130, y: 0), CGRect(x: 10, y: 0, width: 120, height: 60)),
            (.bottomLeft, CGPoint(x: 0, y: 90), CGRect(x: -50, y: 10, width: 160, height: 80)),
            (.bottomRight, CGPoint(x: 150, y: 90), CGRect(x: 10, y: 10, width: 160, height: 80)),
        ]
        for (corner, point, expected) in ratioDrags {
            #expect(CropGeometry.dragging(.corner(corner), of: rect, to: point, aspect: 2) == expected, "\(corner) at 2:1")
        }
    }

    @Test func aRatioCornerDragKeepsTheRatioAboutTheOppositeCorner() {
        // 1:1 from the top-left corner: the larger pull wins.
        #expect(CropGeometry.dragging(.corner(.bottomRight), of: rect, to: CGPoint(x: 70, y: 110), aspect: 1)
            == CGRect(x: 10, y: 10, width: 100, height: 100))
    }

    @Test func aRatioEdgeDragGrowsTheOtherSideAboutTheMiddle() {
        // 2:1 from the right edge to x = 130: 120 wide, so 60 high about the middle (y 35).
        #expect(CropGeometry.dragging(.edge(.right), of: rect, to: CGPoint(x: 130, y: 0), aspect: 2)
            == CGRect(x: 10, y: 5, width: 120, height: 60))
        // From the left edge: the right edge (110) stays.
        #expect(CropGeometry.dragging(.edge(.left), of: rect, to: CGPoint(x: -90, y: 0), aspect: 2)
            == CGRect(x: -90, y: -15, width: 200, height: 100))
    }

    @Test func aRatioDragOnTheTopOrBottomEdgeGrowsTheWidthAboutTheMiddle() {
        // 2:1 from the bottom edge to y = 110: 100 high, so 200 wide about the middle (x 60).
        #expect(CropGeometry.dragging(.edge(.bottom), of: rect, to: CGPoint(x: 0, y: 110), aspect: 2)
            == CGRect(x: -40, y: 10, width: 200, height: 100))
        // From the top edge: the bottom edge (60) stays.
        #expect(CropGeometry.dragging(.edge(.top), of: rect, to: CGPoint(x: 0, y: -40), aspect: 2)
            == CGRect(x: -40, y: -40, width: 200, height: 100))
    }

    @Test func aCropStaysAtLeastEightPixels() {
        let dragged = CropGeometry.dragging(.edge(.right), of: rect, to: CGPoint(x: 12, y: 0), aspect: nil)
        #expect(dragged.width == 8)
        #expect(dragged.height == 50)
        #expect(dragged.minX == 10)
        #expect(dragged.minY == 10)
    }

    @Test func shrinkingToTheFloorKeepsTheOppositeEdge() {
        // However far the right edge is pulled in, the left edge stays at 10.
        for x in [18.0, 16, 12, 10, 8, 5] {
            let dragged = CropGeometry.dragging(.edge(.right), of: rect, to: CGPoint(x: x, y: 0), aspect: nil)
            if x >= 10 {
                #expect(dragged == CGRect(x: 10, y: 10, width: 8, height: 50), "right edge at \(x)")
            } else {
                // Past the opposite edge the crop flips, and that edge is still where it was.
                #expect(dragged == CGRect(x: 2, y: 10, width: 8, height: 50), "right edge at \(x)")
            }
        }
        // And the left edge pulled in keeps the right edge at 110.
        #expect(CropGeometry.dragging(.edge(.left), of: rect, to: CGPoint(x: 109, y: 0), aspect: nil)
            == CGRect(x: 102, y: 10, width: 8, height: 50))
        #expect(CropGeometry.dragging(.edge(.bottom), of: rect, to: CGPoint(x: 0, y: 11), aspect: nil)
            == CGRect(x: 10, y: 10, width: 100, height: 8))
        #expect(CropGeometry.dragging(.corner(.bottomRight), of: rect, to: CGPoint(x: 11, y: 11), aspect: nil)
            == CGRect(x: 10, y: 10, width: 8, height: 8))
        #expect(CropGeometry.dragging(.corner(.topLeft), of: rect, to: CGPoint(x: 110, y: 60), aspect: nil)
            == CGRect(x: 102, y: 52, width: 8, height: 8))
    }

    @Test func growingPastTheLimitKeepsTheOppositeEdge() {
        let wide = CGRect(x: 0, y: 0, width: 10_000, height: 100)
        #expect(CropGeometry.dragging(.edge(.right), of: wide, to: CGPoint(x: 20_000, y: 0), aspect: nil)
            == CGRect(x: 0, y: 0, width: 16_383, height: 100))
        let shifted = CGRect(x: 10_000, y: 0, width: 10_000, height: 100)
        #expect(CropGeometry.dragging(.edge(.left), of: shifted, to: CGPoint(x: -5_000, y: 0), aspect: nil)
            == CGRect(x: 3_617, y: 0, width: 16_383, height: 100))
        // A new crop dragged from its anchor.
        #expect(CropGeometry.dragging(.corner(.bottomRight), of: CGRect(origin: .zero, size: .zero),
                                      to: CGPoint(x: 20_000, y: 5_000), aspect: nil)
            == CGRect(x: 0, y: 0, width: 16_383, height: 5_000))
    }

    @Test func aRatioDragPastTheLimitKeepsItsRatio() {
        let wide = CGRect(x: 0, y: 0, width: 160, height: 90)
        let sixteenNine = CropGeometry.dragging(.corner(.bottomRight), of: wide, to: CGPoint(x: 20_000, y: 11_250), aspect: 16.0 / 9)
        #expect(sixteenNine.minX == 0)
        #expect(sixteenNine.minY == 0)
        #expect(sixteenNine.width == 16_383)
        #expect(abs(sixteenNine.width / sixteenNine.height - 16.0 / 9) < 0.01)
        let tall = CGRect(x: 0, y: 0, width: 90, height: 160)
        let nineSixteen = CropGeometry.dragging(.corner(.bottomRight), of: tall, to: CGPoint(x: 11_250, y: 20_000), aspect: 9.0 / 16)
        #expect(nineSixteen.minX == 0)
        #expect(nineSixteen.minY == 0)
        #expect(nineSixteen.height == 16_383)
        #expect(abs(nineSixteen.width / nineSixteen.height - 9.0 / 16) < 0.01)
        // Dragged up and to the left, the anchored corner is the bottom right one.
        let flipped = CropGeometry.dragging(.corner(.topLeft), of: CGRect(x: 100, y: 100, width: 160, height: 90),
                                            to: CGPoint(x: -20_000, y: -11_000), aspect: 16.0 / 9)
        #expect(flipped.maxX == 260)
        #expect(flipped.maxY == 190)
        #expect(flipped.width == 16_383)
        #expect(abs(flipped.width / flipped.height - 16.0 / 9) < 0.01)
        // An edge drag keeps the ratio by growing the other side about the middle.
        let edge = CropGeometry.dragging(.edge(.right), of: CGRect(x: 0, y: 0, width: 100, height: 50), to: CGPoint(x: 20_000, y: 0), aspect: 2)
        #expect(edge.minX == 0)
        #expect(edge.width == 16_383)
        #expect(abs(edge.width / edge.height - 2) < 0.01)
        #expect(abs(edge.midY - 25) <= 0.5)
    }

    @Test func aRatioDragDownToTheFloorKeepsTheRatioToo() {
        let start = CGRect(x: 0, y: 0, width: 160, height: 90)
        let wide = CropGeometry.dragging(.corner(.bottomRight), of: start, to: CGPoint(x: 12, y: 5), aspect: 16.0 / 9)
        #expect(wide == CGRect(x: 0, y: 0, width: 14, height: 8))
        let tall = CropGeometry.dragging(.corner(.bottomRight), of: start, to: CGPoint(x: 3, y: 3), aspect: 9.0 / 16)
        #expect(tall == CGRect(x: 0, y: 0, width: 8, height: 14))
    }

    @Test func cropsAreWholePixelsAndAtMost16383() {
        let clamped = CropGeometry.clamped(CGRect(x: 0.4, y: 0.6, width: 20_000, height: 10.2))
        #expect(clamped.minX == 0)
        #expect(clamped.width == 16_383)
        #expect(clamped.minY == 1)
        #expect(clamped.height == 10)
        // Too short grows from the origin too, and a flipped rect is standardized first.
        #expect(CropGeometry.clamped(CGRect(x: 5.4, y: 5.6, width: 2, height: 3)) == CGRect(x: 5, y: 6, width: 8, height: 8))
        #expect(CropGeometry.clamped(CGRect(x: 110, y: 60, width: -100, height: -50)) == CGRect(x: 10, y: 10, width: 100, height: 50))
    }

    @Test func draggingGivesWholePixelsAndLeavesAnotherHandleAlone() {
        #expect(CropGeometry.dragging(.corner(.bottomRight), of: rect, to: CGPoint(x: 150.4, y: 89.6), aspect: nil)
            == CGRect(x: 10, y: 10, width: 140, height: 80))
        #expect(CropGeometry.dragging(.start, of: rect, to: CGPoint(x: 150, y: 90), aspect: nil) == rect)
        #expect(CropGeometry.dragging(.end, of: CGRect(x: 10.4, y: 10.6, width: 3, height: 50), to: .zero, aspect: nil)
            == CGRect(x: 10, y: 11, width: 8, height: 50))
    }

    @Test func aNewCropGrowsFromItsAnchorInAnyDirection() {
        let anchor = CGRect(origin: CGPoint(x: 20, y: 30), size: .zero)
        #expect(CropGeometry.dragging(.corner(.bottomRight), of: anchor, to: CGPoint(x: 120, y: 80), aspect: nil)
            == CGRect(x: 20, y: 30, width: 100, height: 50))
        #expect(CropGeometry.dragging(.corner(.bottomRight), of: anchor, to: CGPoint(x: 5, y: 10), aspect: nil)
            == CGRect(x: 5, y: 10, width: 15, height: 20))
        #expect(CropGeometry.dragging(.corner(.bottomRight), of: anchor, to: CGPoint(x: 22, y: 31), aspect: nil)
            == CGRect(x: 20, y: 30, width: 8, height: 8))
        #expect(CropGeometry.dragging(.corner(.bottomRight), of: anchor, to: CGPoint(x: 120, y: 80), aspect: 1)
            == CGRect(x: 20, y: 30, width: 100, height: 100))
    }

    @Test func aCropWithFractionalEdgesAnchorsOnWholePixels() {
        // Its edges round to x 10 to 111 and y 11 to 61.
        let fractional = CGRect(x: 10.4, y: 10.6, width: 100.2, height: 50)
        #expect(CropGeometry.dragging(.corner(.bottomRight), of: fractional, to: CGPoint(x: 150, y: 90), aspect: nil)
            == CGRect(x: 10, y: 11, width: 140, height: 79))
        #expect(CropGeometry.dragging(.corner(.topLeft), of: fractional, to: CGPoint(x: 0, y: 0), aspect: nil)
            == CGRect(x: 0, y: 0, width: 111, height: 61))
        #expect(CropGeometry.dragging(.edge(.right), of: fractional, to: CGPoint(x: 150, y: 0), aspect: nil)
            == CGRect(x: 10, y: 11, width: 140, height: 50))
        // The other side of a ratio drag is centred on the crop's middle (y 35.6), on whole pixels.
        #expect(CropGeometry.dragging(.edge(.right), of: fractional, to: CGPoint(x: 150, y: 0), aspect: 2)
            == CGRect(x: 10, y: 1, width: 140, height: 70))
    }

    @Test func theWidestRatioACropCanHaveIsStillARatio() {
        // 16 383 × 8 is as long as a crop can be at 2 047.875 : 1, so that ratio holds right up to the limits.
        #expect(CropGeometry.dragging(.corner(.bottomRight), of: rect, to: CGPoint(x: 20_000, y: 20_000), aspect: 16_383.0 / 8)
            == CGRect(x: 10, y: 10, width: 16_383, height: 8))
    }

    @Test func aRatioEdgeDragThatEndsOnItsAnchorStaysOnItsOwnSide() {
        // A pull of no length leaves the smallest crop of the ratio (16 × 8 at 2:1), on the handle's own side.
        #expect(CropGeometry.dragging(.edge(.right), of: rect, to: CGPoint(x: 10, y: 0), aspect: 2) == CGRect(x: 10, y: 31, width: 16, height: 8))
        #expect(CropGeometry.dragging(.edge(.left), of: rect, to: CGPoint(x: 110, y: 0), aspect: 2) == CGRect(x: 94, y: 31, width: 16, height: 8))
        #expect(CropGeometry.dragging(.edge(.bottom), of: rect, to: CGPoint(x: 0, y: 10), aspect: 2) == CGRect(x: 52, y: 10, width: 16, height: 8))
        #expect(CropGeometry.dragging(.edge(.top), of: rect, to: CGPoint(x: 0, y: 60), aspect: 2) == CGRect(x: 52, y: 52, width: 16, height: 8))
    }

    @Test func aFlippedRectIsDraggedLikeItsStandardizedSelf() {
        let flipped = CGRect(x: 110, y: 60, width: -100, height: -50)
        #expect(CropGeometry.dragging(.corner(.bottomRight), of: flipped, to: CGPoint(x: 150, y: 90), aspect: nil)
            == CGRect(x: 10, y: 10, width: 140, height: 80))
        #expect(CropGeometry.dragging(.edge(.right), of: flipped, to: CGPoint(x: 130, y: 0), aspect: 2)
            == CGRect(x: 10, y: 5, width: 120, height: 60))
        #expect(CropGeometry.dragging(.edge(.bottom), of: flipped, to: CGPoint(x: 0, y: 90), aspect: nil)
            == CGRect(x: 10, y: 10, width: 100, height: 80))
    }

    @Test func aDragThatEndsOnTheAnchorStaysOnItsOwnSide() {
        #expect(CropGeometry.dragging(.corner(.bottomRight), of: rect, to: CGPoint(x: 10, y: 10), aspect: nil)
            == CGRect(x: 10, y: 10, width: 8, height: 8))
        #expect(CropGeometry.dragging(.corner(.topLeft), of: rect, to: CGPoint(x: 110, y: 60), aspect: nil)
            == CGRect(x: 102, y: 52, width: 8, height: 8))
    }

    @Test func everyDragStaysWholeWithinTheLimitsAndAnchored() {
        let coordinates: [Double] = [-30_000, -100, 0, 9, 10, 12, 60, 110, 111, 5_000, 20_000, 40_000]
        var failures: [String] = []
        for handle in CropGeometry.handles {
            for aspect in [nil, 1, 16.0 / 9, 9.0 / 16, 2.35] as [Double?] {
                for x in coordinates {
                    for y in coordinates {
                        let dragged = CropGeometry.dragging(handle, of: rect, to: CGPoint(x: x, y: y), aspect: aspect)
                        let label = "\(handle) \(aspect.map { "\($0)" } ?? "free") to (\(x), \(y)) gave \(dragged)"
                        let anchored: Bool
                        switch handle {
                        case .corner(let corner):
                            let anchorX = corner == .topLeft || corner == .bottomLeft ? rect.maxX : rect.minX
                            let anchorY = corner == .topLeft || corner == .topRight ? rect.maxY : rect.minY
                            anchored = [dragged.minX, dragged.maxX].contains(anchorX) && [dragged.minY, dragged.maxY].contains(anchorY)
                        case .edge(.left): anchored = [dragged.minX, dragged.maxX].contains(rect.maxX)
                        case .edge(.right): anchored = [dragged.minX, dragged.maxX].contains(rect.minX)
                        case .edge(.top): anchored = [dragged.minY, dragged.maxY].contains(rect.maxY)
                        case .edge(.bottom): anchored = [dragged.minY, dragged.maxY].contains(rect.minY)
                        case .start, .end, .control: anchored = true
                        }
                        var held = true
                        if let aspect {
                            held = abs(dragged.width - aspect * dragged.height) <= (1 + aspect) / 2 + 1e-9
                            if case .edge(let edge) = handle {
                                let keptMiddle = edge == .left || edge == .right ? abs(dragged.midY - rect.midY) : abs(dragged.midX - rect.midX)
                                held = held && keptMiddle <= 0.5
                            }
                        } else if case .edge(let edge) = handle {
                            // A free edge drag leaves the other axis as it was.
                            held = edge == .left || edge == .right ? (dragged.minY == rect.minY && dragged.height == rect.height)
                                : (dragged.minX == rect.minX && dragged.width == rect.width)
                        }
                        let inRange = [dragged.width, dragged.height].allSatisfy { $0 >= 8 && $0 <= 16_383 }
                        if !(isWhole(dragged) && inRange && anchored && held && CropGeometry.clamped(dragged) == dragged) {
                            failures.append(label)
                        }
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) bad drags, for example \(failures.prefix(4))")
    }

    @Test func absurdInputsGiveFiniteCrops() {
        let bad: [CGRect] = [
            CGRect(x: Double.nan, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: Double.nan, height: 10),
            CGRect(x: 0, y: Double.infinity, width: 10, height: 10), CGRect(x: 0, y: 0, width: 10, height: -Double.infinity),
            .null, .infinite, CGRect(x: 1e308, y: 0, width: 1e308, height: 10), CGRect(x: 0, y: 1e308, width: 10, height: 1e308),
        ]
        for rect in bad {
            let clamped = CropGeometry.clamped(rect)
            #expect(clamped == CGRect(x: 0, y: 0, width: 8, height: 8), "clamped \(rect) gave \(clamped)")
            for handle in CropGeometry.handles {
                let dragged = CropGeometry.dragging(handle, of: rect, to: CGPoint(x: 50, y: 50), aspect: 2)
                #expect(isFinite(dragged), "\(handle) of \(rect) gave \(dragged)")
            }
            #expect(CropGeometry.conformed(rect, aspect: 2) == CGRect(x: 0, y: 0, width: 8, height: 8), "conformed \(rect)")
        }
        // A pointer that isn't a number leaves the crop as it was.
        for point in [CGPoint(x: Double.nan, y: 50), CGPoint(x: 50, y: Double.infinity), CGPoint(x: -Double.infinity, y: Double.nan)] {
            #expect(CropGeometry.dragging(.corner(.bottomRight), of: rect, to: point, aspect: nil) == rect)
            #expect(CropGeometry.dragging(.edge(.right), of: rect, to: point, aspect: 2) == rect)
        }
        // Huge but finite numbers still give a valid crop.
        let huge = CropGeometry.dragging(.corner(.bottomRight), of: rect, to: CGPoint(x: 1e300, y: -1e300), aspect: nil)
        #expect(huge == CGRect(x: 10, y: 10 - 16_383, width: 16_383, height: 16_383))
        // A ratio no crop can have is no ratio.
        for aspect in [0, -1, .nan, .infinity, 1e-300, 1e300, 1.0 / 5_000, 5_000] as [Double] {
            let dragged = CropGeometry.dragging(.corner(.bottomRight), of: rect, to: CGPoint(x: 150, y: 90), aspect: aspect)
            #expect(dragged == CGRect(x: 10, y: 10, width: 140, height: 80), "aspect \(aspect)")
        }
        // Conforming to one does nothing worse than limiting the crop.
        for aspect in [.nan, .infinity, 1e-300, 1e300] as [Double] {
            let conformed = CropGeometry.conformed(rect, aspect: aspect)
            #expect(isFinite(conformed) && isWhole(conformed) && conformed.width >= 8 && conformed.height >= 8, "aspect \(aspect)")
        }
        // The viewport ignores a crop that isn't a rect.
        let document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        for crop in [CGRect(x: Double.nan, y: 0, width: 10, height: 10), CGRect(x: Double.nan, y: -500, width: 10, height: 10),
                     CGRect(x: 0, y: 0, width: Double.infinity, height: 10), CGRect(x: 1e308, y: 0, width: 1e308, height: 10)] {
            #expect(CropGeometry.viewport(for: document, crop: crop) == CGRect(x: -50, y: -50, width: 300, height: 200), "\(crop)")
        }
    }

    @Test func edgesSnapWithinTheThreshold() {
        let targets = CropGeometry.SnapTargets(x: [0, 200], y: [0, 100])
        #expect(CropGeometry.snapped(CGPoint(x: 195, y: 50), to: targets, threshold: 8) == CGPoint(x: 200, y: 50))
        #expect(CropGeometry.snapped(CGPoint(x: 180, y: 97), to: targets, threshold: 8) == CGPoint(x: 180, y: 100))
        #expect(CropGeometry.snapped(CGPoint(x: 180, y: 50), to: .empty, threshold: 8) == CGPoint(x: 180, y: 50))
    }

    @Test func snappingReachesTheThresholdAndTakesTheNearestTarget() {
        #expect(CropGeometry.snapped(192, to: [200], threshold: 8) == 200)
        #expect(CropGeometry.snapped(191.5, to: [200], threshold: 8) == 191.5)
        #expect(CropGeometry.snapped(7, to: [0, 10, 20], threshold: 8) == 10)
        #expect(CropGeometry.snapped(13, to: [20, 10, 0], threshold: 8) == 10)
        #expect(CropGeometry.snapped(1, to: [], threshold: 8) == 1)
    }

    @Test func aMovedCropSnapsItsNearestEdge() {
        let targets = CropGeometry.SnapTargets(x: [0, 200], y: [0, 100])
        // The right edge is 3 from 200, the left 47 from 0: the right one snaps.
        #expect(CropGeometry.snappedMove(CGRect(x: 47, y: 20, width: 150, height: 50), to: targets, threshold: 8)
            == CGRect(x: 50, y: 20, width: 150, height: 50))
        // Both edges in range: the nearer one wins. Left 2 from 0, right 5 from 200.
        #expect(CropGeometry.snappedMove(CGRect(x: 2, y: 20, width: 193, height: 50), to: targets, threshold: 8)
            == CGRect(x: 0, y: 20, width: 193, height: 50))
        // Left 5 from 0, right 3 from 200.
        #expect(CropGeometry.snappedMove(CGRect(x: 5, y: 20, width: 192, height: 50), to: targets, threshold: 8)
            == CGRect(x: 8, y: 20, width: 192, height: 50))
        // The same on the other axis: top 4 from 0, bottom 3 from 100.
        #expect(CropGeometry.snappedMove(CGRect(x: 40, y: 4, width: 100, height: 93), to: targets, threshold: 8)
            == CGRect(x: 40, y: 7, width: 100, height: 93))
        // 8 away is in range, 9 is not.
        #expect(CropGeometry.snappedMove(CGRect(x: 45, y: 20, width: 147, height: 50), to: targets, threshold: 8)
            == CGRect(x: 53, y: 20, width: 147, height: 50))
        #expect(CropGeometry.snappedMove(CGRect(x: 44, y: 20, width: 147, height: 50), to: targets, threshold: 8)
            == CGRect(x: 44, y: 20, width: 147, height: 50))
        // Both axes at once, and nothing in range, and no targets.
        #expect(CropGeometry.snappedMove(CGRect(x: 47, y: 4, width: 150, height: 93), to: targets, threshold: 8)
            == CGRect(x: 50, y: 7, width: 150, height: 93))
        #expect(CropGeometry.snappedMove(CGRect(x: 40, y: 20, width: 100, height: 50), to: targets, threshold: 8)
            == CGRect(x: 40, y: 20, width: 100, height: 50))
        #expect(CropGeometry.snappedMove(CGRect(x: 47, y: 4, width: 150, height: 93), to: .empty, threshold: 8)
            == CGRect(x: 47, y: 4, width: 150, height: 93))
    }

    @Test func anAlignedEdgeStaysAlignedWhileTheOtherIsNearATarget() {
        let targets = CropGeometry.SnapTargets(x: [0, 200], y: [0, 100])
        // The left edge is on 0; the right, 3 short of 200, doesn't pull it off.
        let leftAligned = CGRect(x: 0, y: 20, width: 197, height: 50)
        #expect(CropGeometry.snappedMove(leftAligned, to: targets, threshold: 8) == leftAligned)
        // The right edge is on 200; the left, 3 from 0, doesn't pull it off.
        let rightAligned = CGRect(x: 3, y: 20, width: 197, height: 50)
        #expect(CropGeometry.snappedMove(rightAligned, to: targets, threshold: 8) == rightAligned)
        // The same on the other axis.
        let topAligned = CGRect(x: 40, y: 0, width: 100, height: 97)
        #expect(CropGeometry.snappedMove(topAligned, to: targets, threshold: 8) == topAligned)
        let bottomAligned = CGRect(x: 40, y: 3, width: 100, height: 97)
        #expect(CropGeometry.snappedMove(bottomAligned, to: targets, threshold: 8) == bottomAligned)
        // Dragging across, the crop moves from one alignment to the other without a pop in between.
        for (proposed, snapped) in [(4.0, 3.0), (3, 3), (2, 3), (1, 0), (0, 0), (-1, 0)] {
            #expect(CropGeometry.snappedMove(CGRect(x: proposed, y: 20, width: 197, height: 50), to: targets, threshold: 8)
                == CGRect(x: snapped, y: 20, width: 197, height: 50), "proposed x \(proposed)")
        }
    }

    @Test func snapTargetsAreThePictureAndTheObjects() {
        var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        document.objects = [box(CGRect(x: 20, y: 30, width: 40, height: 10))]
        let targets = CropGeometry.snapTargets(for: document)
        #expect(Set(targets.x) == [0, 200, 20, 60])
        #expect(Set(targets.y) == [0, 100, 30, 40])
    }

    @Test func snapTargetsAreInOutputPixels() {
        var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        document.imageOps = [.rotateRight] // the picture is 100×200; (x, y) maps to (100 − y, x)
        document.objects = [box(CGRect(x: 20, y: 30, width: 40, height: 10))]
        let targets = CropGeometry.snapTargets(for: document)
        #expect(Set(targets.x) == [0, 100, 60, 70])
        #expect(Set(targets.y) == [0, 200, 20, 60])
    }

    @Test func snapTargetsSkipObjectsWithoutRealBounds() {
        var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        let nothing = AnnotationObject(kind: .stroke(StrokeObject(points: [], smoothed: false)),
                                       style: ObjectStyle(color: .black, lineWidth: 2, shadow: false))
        document.objects = [box(CGRect(x: Double.nan, y: 0, width: 10, height: 10)), box(CGRect(x: Double.nan, y: -500, width: 10, height: 10)), box(CGRect(x: 1e308, y: 10, width: 1e308, height: 10)), nothing,
                            box(CGRect(x: 20, y: 30, width: 40, height: 10))]
        let targets = CropGeometry.snapTargets(for: document)
        #expect(Set(targets.x) == [0, 200, 20, 60])
        #expect(Set(targets.y) == [0, 100, 30, 40])
    }

    @Test func aRatioReshapesTheCropAboutItsCentre() {
        #expect(CropGeometry.conformed(CGRect(x: 0, y: 0, width: 100, height: 80), aspect: 1) == CGRect(x: 10, y: 0, width: 80, height: 80))
        // The other way round: a tall crop keeps its width.
        #expect(CropGeometry.conformed(CGRect(x: 0, y: 0, width: 80, height: 100), aspect: 2) == CGRect(x: 0, y: 30, width: 80, height: 40))
    }

    @Test func conformingNeverLeavesTheLimits() {
        let tiny = CropGeometry.conformed(CGRect(x: 0, y: 0, width: 10, height: 5), aspect: 1)
        #expect(tiny.width == 8 && tiny.height == 8)
        #expect(abs(tiny.midX - 5) <= 4 && abs(tiny.midY - 2.5) <= 4)
        let degenerate = CGRect(x: 3, y: 4, width: 0, height: 50)
        #expect(CropGeometry.conformed(degenerate, aspect: 2) == CropGeometry.clamped(degenerate))
        #expect(CropGeometry.conformed(rect, aspect: 0) == rect)
        #expect(CropGeometry.conformed(rect, aspect: Double.infinity) == rect)
        let flat = CGRect(x: 3, y: 4, width: 50, height: 0)
        #expect(CropGeometry.conformed(flat, aspect: 2) == CropGeometry.clamped(flat))
    }

    @Test func theViewportLeavesRoomToDragOutward() {
        let document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        #expect(CropGeometry.viewport(for: document, crop: document.canvasBounds) == CGRect(x: -50, y: -50, width: 300, height: 200))
    }

    @Test func theViewportCoversACropLargerThanThePicture() {
        let document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        // The crop spans (-100, -20) to (400, 280): 500 × 300, so 125 spare.
        #expect(CropGeometry.viewport(for: document, crop: CGRect(x: -100, y: -20, width: 500, height: 300))
            == CGRect(x: -225, y: -145, width: 750, height: 550))
    }

    @Test func theViewportCoversTheCanvasAndObjectsOutsideThePicture() {
        var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        document.canvasRect = CGRect(x: -40, y: -40, width: 300, height: 200)
        // The canvas spans (-40, -40) to (260, 160): 300 × 200, so 75 spare.
        #expect(CropGeometry.viewport(for: document, crop: CGRect(x: 0, y: 0, width: 50, height: 50))
            == CGRect(x: -115, y: -115, width: 450, height: 350))
        var withObject = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        withObject.objects = [box(CGRect(x: 300, y: 50, width: 20, height: 10)), box(CGRect(x: Double.nan, y: 0, width: 10, height: 10)),
                              box(CGRect(x: Double.nan, y: -500, width: 10, height: 10)), box(CGRect(x: 1e308, y: 10, width: 1e308, height: 10))]
        // The picture and the object span (0, 0) to (320, 100): 320 wide, so 80 spare.
        #expect(CropGeometry.viewport(for: withObject, crop: withObject.canvasBounds) == CGRect(x: -80, y: -80, width: 480, height: 260))
    }

    @Test func theViewportCoversThePictureEvenWhenTheCanvasIsCut() {
        var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        document.canvasRect = CGRect(x: 50, y: 20, width: 60, height: 40)
        #expect(CropGeometry.viewport(for: document, crop: document.canvasBounds) == CGRect(x: -50, y: -50, width: 300, height: 200))
    }

    @Test func theViewportsSpareIsAWholeNumberOfPixels() {
        // A quarter of 201 is 50.25: 50 spare.
        let document = AnnotationDocument(baseSize: CGSize(width: 201, height: 101), pixelScale: 1)
        #expect(CropGeometry.viewport(for: document, crop: document.canvasBounds) == CGRect(x: -50, y: -50, width: 301, height: 201))
    }

    @Test func aViewportLimitedToItsMiddleRoundsDown() {
        let document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        // 45 001 wide with its middle at 15 000.5: the limited viewport starts at 15 000.5 − 16 384, rounded down.
        #expect(CropGeometry.viewport(for: document, crop: CGRect(x: 0, y: 0, width: 30_001, height: 100))
            == CGRect(x: -1_384, y: -7_500, width: 32_768, height: 15_100))
        #expect(CropGeometry.viewport(for: document, crop: CGRect(x: 0, y: 0, width: 100, height: 30_001))
            == CGRect(x: -7_500, y: -1_384, width: 15_200, height: 32_768))
    }

    @Test func theViewportIsWholePixelsAndAtMost32768() {
        let document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 1)
        let fractional = CropGeometry.viewport(for: document, crop: CGRect(x: -10.4, y: 3.3, width: 50.5, height: 50.5))
        #expect(fractional == fractional.integral)
        // 30 000 wide: 7 500 spare would make 45 000, so it is limited about its middle (15 000).
        #expect(CropGeometry.viewport(for: document, crop: CGRect(x: 0, y: 0, width: 30_000, height: 100))
            == CGRect(x: -1_384, y: -7_500, width: 32_768, height: 15_100))
        #expect(CropGeometry.viewport(for: document, crop: CGRect(x: 0, y: 0, width: 100, height: 30_000))
            == CGRect(x: -7_500, y: -1_384, width: 15_200, height: 32_768))
    }

    @Test func theCropsHandlesAreTheFourCornersThenTheFourEdges() {
        #expect(CropGeometry.handles == [.corner(.topLeft), .corner(.topRight), .corner(.bottomLeft), .corner(.bottomRight),
                                         .edge(.top), .edge(.bottom), .edge(.left), .edge(.right)])
        #expect(ObjectGeometry.point(of: .corner(.topRight), in: rect) == CGPoint(x: 110, y: 10))
        #expect(ObjectGeometry.point(of: .edge(.bottom), in: rect) == CGPoint(x: 60, y: 60))
    }
}

struct CanvasDocumentTests {
    @Test func outputBoundsFollowTheImageOperations() {
        var document = AnnotationDocument(baseSize: CGSize(width: 100, height: 80), pixelScale: 1)
        document.imageOps = [.rotateRight]
        // rotateRight maps (x, y) to (80 − y, x).
        #expect(document.outputBounds(of: box(CGRect(x: 10, y: 0, width: 20, height: 10))) == CGRect(x: 70, y: 10, width: 10, height: 20))
        #expect(document.pictureBounds == CGRect(x: 0, y: 0, width: 80, height: 100))
        document.imageOps = [.resize(width: 200, height: 160)]
        #expect(document.outputBounds(of: box(CGRect(x: 10, y: 5, width: 20, height: 10))) == CGRect(x: 20, y: 10, width: 40, height: 20))
        #expect(document.pictureBounds == CGRect(x: 0, y: 0, width: 200, height: 160))
    }

    @Test func anObjectThatPaintsNothingHasNullBounds() {
        let document = AnnotationDocument(baseSize: CGSize(width: 100, height: 80), pixelScale: 1)
        let nothing = AnnotationObject(kind: .stroke(StrokeObject(points: [], smoothed: false)),
                                       style: ObjectStyle(color: .black, lineWidth: 2, shadow: false))
        #expect(document.outputBounds(of: nothing).isNull)
    }

    @Test func revertingDropsImageChangesButKeepsObjects() {
        var document = AnnotationDocument(baseSize: CGSize(width: 100, height: 80), pixelScale: 1)
        #expect(!document.canRevertToOriginal)
        document.objects = [box(CGRect(x: 10, y: 10, width: 20, height: 20))]
        document.imageOps = [.flipVertical]
        document.canvasRect = CGRect(x: 0, y: 0, width: 50, height: 50)
        document.canvasFill = .transparent
        #expect(document.canRevertToOriginal)
        let reverted = document.revertedToOriginal()
        #expect(reverted.imageOps.isEmpty)
        #expect(reverted.canvasRect == nil)
        #expect(reverted.canvasFill == .auto)
        #expect(reverted.objects == document.objects)
        #expect(!reverted.canRevertToOriginal)
    }

    @Test func eachImageChangeAloneEnablesRevert() {
        let plain = AnnotationDocument(baseSize: CGSize(width: 100, height: 80), pixelScale: 1)
        #expect(!plain.canRevertToOriginal)
        var withObjects = plain
        withObjects.objects = [box(CGRect(x: 10, y: 10, width: 20, height: 20))]
        #expect(!withObjects.canRevertToOriginal)
        var operated = plain
        operated.imageOps = [.rotateLeft]
        #expect(operated.canRevertToOriginal)
        var resized = plain
        resized.imageOps = [.resize(width: 50, height: 40)]
        #expect(resized.canRevertToOriginal)
        var cropped = plain
        cropped.canvasRect = CGRect(x: 0, y: 0, width: 50, height: 50)
        #expect(cropped.canRevertToOriginal)
        var transparent = plain
        transparent.canvasFill = .transparent
        #expect(transparent.canRevertToOriginal)
        var coloured = plain
        coloured.canvasFill = .color(RGBAColor(red: 1, green: 0, blue: 0))
        #expect(coloured.canRevertToOriginal)
        // Each is undone, and reverting a document with nothing to undo changes nothing.
        for document in [operated, resized, cropped, transparent, coloured] {
            #expect(document.revertedToOriginal() == plain)
        }
        #expect(plain.revertedToOriginal() == plain)
    }

    @Test func resizeNumbersStayInRange() {
        #expect(ImageResize.clamped(0) == 1)
        #expect(ImageResize.clamped(40_000) == 16_383)
        let half = ImageResize.scaled(CGSize(width: 1001, height: 500), percent: 50)
        #expect(half.width == 501)
        #expect(half.height == 250)
        #expect(ImageResize.scaled(CGSize(width: 10_000, height: 10), percent: 200).width == 16_383)
        #expect(ImageResize.height(forWidth: 300, keeping: CGSize(width: 1200, height: 800)) == 200)
        #expect(ImageResize.width(forHeight: 300, keeping: CGSize(width: 1200, height: 800)) == 450)
    }

    @Test func resizeNumbersRoundToTheNearestPixelAndClamp() {
        // 500 × 333 ÷ 1000 = 166.5, which rounds up; 167 × 1000 ÷ 333 = 501.5…, which rounds to 502.
        #expect(ImageResize.height(forWidth: 500, keeping: CGSize(width: 1000, height: 333)) == 167)
        #expect(ImageResize.width(forHeight: 167, keeping: CGSize(width: 1000, height: 333)) == 502)
        #expect(ImageResize.height(forWidth: 1, keeping: CGSize(width: 1000, height: 1)) == 1)
        #expect(ImageResize.width(forHeight: 1, keeping: CGSize(width: 1, height: 1000)) == 1)
        #expect(ImageResize.height(forWidth: 16_000, keeping: CGSize(width: 100, height: 200)) == 16_383)
        #expect(ImageResize.width(forHeight: 16_000, keeping: CGSize(width: 200, height: 100)) == 16_383)
        #expect(ImageResize.scaled(CGSize(width: 10, height: 10), percent: 1).width == 1)
        #expect(ImageResize.scaled(CGSize(width: 10, height: 10), percent: 1).height == 1)
        // A picture without a size keeps the number typed.
        #expect(ImageResize.height(forWidth: 300, keeping: CGSize(width: 0, height: 100)) == 300)
        #expect(ImageResize.width(forHeight: 300, keeping: CGSize(width: 100, height: 0)) == 300)
        #expect(ImageResize.height(forWidth: 40_000, keeping: .zero) == 16_383)
        #expect(ImageResize.width(forHeight: 0, keeping: .zero) == 1)
    }

    @Test func resizeNumbersNeverTrap() {
        let size = CGSize(width: 1000, height: 500)
        let huge = ImageResize.scaled(size, percent: 1e30)
        #expect(huge.width == 16_383 && huge.height == 16_383)
        let negative = ImageResize.scaled(size, percent: -50)
        #expect(negative.width == 1 && negative.height == 1)
        // A percentage that isn't a number leaves the size as it is.
        for percent in [Double.nan, .infinity, -.infinity] {
            let same = ImageResize.scaled(size, percent: percent)
            #expect(same.width == 1000 && same.height == 500, "\(percent)")
        }
        let broken = ImageResize.scaled(CGSize(width: Double.nan, height: Double.infinity), percent: 50)
        #expect(broken.width == 1 && broken.height == 16_383)
        #expect(ImageResize.height(forWidth: Int.max, keeping: CGSize(width: 800, height: 1200)) == 16_383)
        #expect(ImageResize.width(forHeight: Int.max, keeping: CGSize(width: 1200, height: 800)) == 16_383)
        #expect(ImageResize.height(forWidth: Int.min, keeping: CGSize(width: 800, height: 1200)) == 1)
        #expect(ImageResize.width(forHeight: Int.min, keeping: CGSize(width: 1200, height: 800)) == 1)
        for size in [CGSize(width: Double.nan, height: 800), CGSize(width: Double.infinity, height: 800),
                     CGSize(width: 1200, height: Double.nan), CGSize(width: 1200, height: Double.infinity)] {
            #expect(ImageResize.height(forWidth: 300, keeping: size) == 300, "\(size)")
            #expect(ImageResize.width(forHeight: 300, keeping: size) == 300, "\(size)")
        }
        #expect(ImageResize.height(forWidth: 300, keeping: CGSize(width: 1e-300, height: 1e300)) == 16_383)
        #expect(ImageResize.clamped(Int.min) == 1)
        #expect(ImageResize.clamped(Int.max) == 16_383)
    }
}

struct AutoExpandGeometryTests {
    let base = AnnotationDocument(baseSize: CGSize(width: 100, height: 80), pixelScale: 1)

    @Test func nothingChangesWhenEverythingFits() {
        var document = base
        document.objects = [box(CGRect(x: 10, y: 10, width: 20, height: 20))]
        #expect(document.expandedToFit() == document)
        #expect(document.expandedToFit().canvasRect == nil)
    }

    @Test func anObjectAHairPastTheEdgeDoesNotGrowTheCanvas() {
        // Arithmetic that rounds can leave a bound a few ULP past the edge; that is on the canvas, not outside it.
        var document = base
        document.objects = [box(CGRect(x: 80.000000000001, y: 10, width: 20.000000000002, height: 20))]
        #expect(document.expandedToFit().canvasRect == nil)
        document.objects = [box(CGRect(x: -0.000000000001, y: 70.00000000001, width: 20, height: 10.0000000001))]
        #expect(document.expandedToFit().canvasRect == nil)
        // A thousandth of a pixel is a real overhang.
        document.objects = [box(CGRect(x: 80, y: 10, width: 20.001, height: 20))]
        #expect(document.expandedToFit().canvasRect == CGRect(x: 0, y: 0, width: 117, height: 80))
    }

    @Test func anObjectPastOneSideGrowsThatSideOnly() {
        var document = base
        document.objects = [box(CGRect(x: 90, y: 10, width: 30, height: 20))]
        #expect(document.expandedToFit().canvasRect == CGRect(x: 0, y: 0, width: 136, height: 80))
    }

    @Test func anObjectPastTheBottomGrowsDownwardOnly() {
        var document = base
        document.objects = [box(CGRect(x: 10, y: 70, width: 20, height: 30))]
        #expect(document.expandedToFit().canvasRect == CGRect(x: 0, y: 0, width: 100, height: 116))
    }

    @Test func anObjectPastTheLeftOrTopGrowsThatSideToItsEdgePlusTheMargin() {
        var left = base
        left.objects = [box(CGRect(x: -30, y: 10, width: 20, height: 20))]
        #expect(left.expandedToFit().canvasRect == CGRect(x: -46, y: 0, width: 146, height: 80))
        var top = base
        top.objects = [box(CGRect(x: 10, y: -25, width: 20, height: 20))]
        #expect(top.expandedToFit().canvasRect == CGRect(x: 0, y: -41, width: 100, height: 121))
    }

    @Test func anObjectAcrossBothSidesOfAnAxisGrowsBoth() {
        var document = base
        document.objects = [box(CGRect(x: -30, y: 10, width: 200, height: 20))]
        #expect(document.expandedToFit().canvasRect == CGRect(x: -46, y: 0, width: 232, height: 80))
    }

    @Test func fractionalBoundsGrowToWholePixelsOutward() {
        var left = base
        left.objects = [box(CGRect(x: -30.3, y: 10, width: 10, height: 10))]
        #expect(left.expandedToFit().canvasRect == CGRect(x: -47, y: 0, width: 147, height: 80))
        var right = base
        right.objects = [box(CGRect(x: 95.3, y: 10, width: 10, height: 10))]
        #expect(right.expandedToFit().canvasRect == CGRect(x: 0, y: 0, width: 122, height: 80))
        var top = base
        top.objects = [box(CGRect(x: 10, y: -5.2, width: 10, height: 10))]
        #expect(top.expandedToFit().canvasRect == CGRect(x: 0, y: -22, width: 100, height: 102))
        var bottom = base
        bottom.objects = [box(CGRect(x: 10, y: 70.2, width: 10, height: 10))]
        #expect(bottom.expandedToFit().canvasRect == CGRect(x: 0, y: 0, width: 100, height: 97))
    }

    @Test func anObjectInsideTheCanvasNeverGrowsIt() {
        // Within 16 pixels of an edge is still inside; only crossing the edge grows the canvas.
        for rect in [CGRect(x: 70, y: 10, width: 25, height: 20), CGRect(x: 10, y: 60, width: 20, height: 15),
                     CGRect(x: 2, y: 2, width: 20, height: 20), CGRect(x: 80, y: 60, width: 20, height: 20),
                     CGRect(x: 0, y: 0, width: 100, height: 80)] {
            var document = base
            document.objects = [box(rect)]
            #expect(document.expandedToFit() == document, "\(rect)")
        }
    }

    @Test func growthIsMeasuredAfterImageOperations() {
        var document = base
        document.imageOps = [.rotateRight] // the picture is 80×100
        // rotateRight maps (x, y) to (80 − y, x): a box above the base's top lands past the output's right side.
        document.objects = [box(CGRect(x: 10, y: -20, width: 20, height: 10))]
        #expect(document.expandedToFit().canvasRect == CGRect(x: 0, y: 0, width: 116, height: 100))
        var resized = base
        resized.imageOps = [.resize(width: 200, height: 160)] // everything doubles
        resized.objects = [box(CGRect(x: 90, y: 10, width: 30, height: 20))]
        #expect(resized.expandedToFit().canvasRect == CGRect(x: 0, y: 0, width: 256, height: 160))
        var flipped = base
        flipped.imageOps = [.flipHorizontal] // x maps to 100 − x
        flipped.objects = [box(CGRect(x: 90, y: 10, width: 30, height: 20))]
        #expect(flipped.expandedToFit().canvasRect == CGRect(x: -36, y: 0, width: 136, height: 80))
    }

    @Test func theCanvasNeverShrinks() {
        var document = base
        document.canvasRect = CGRect(x: -50, y: -50, width: 300, height: 200)
        document.objects = [box(CGRect(x: 0, y: 0, width: 10, height: 10))]
        #expect(document.expandedToFit() == document)
    }

    @Test func anExistingCanvasGrowsFromItsOwnEdges() {
        var document = base
        document.canvasRect = CGRect(x: 10, y: 10, width: 50, height: 50)
        document.objects = [box(CGRect(x: 50, y: 50, width: 30, height: 30))]
        // The object crosses the canvas's right and bottom edges (60), not its left or top.
        #expect(document.expandedToFit().canvasRect == CGRect(x: 10, y: 10, width: 86, height: 86))
    }

    @Test func onlyObjectsChangedSinceThePreviousDocumentCount() {
        var cut = base
        cut.canvasRect = CGRect(x: 0, y: 0, width: 70, height: 80)
        cut.objects = [box(CGRect(x: 60, y: 10, width: 30, height: 20))] // a crop cut through it
        var added = cut
        added.objects.append(box(CGRect(x: 5, y: 5, width: 10, height: 10)))
        #expect(added.expandedToFit(since: cut) == added)
        var moved = cut
        moved.objects[0] = ObjectGeometry.translated(cut.objects[0], by: CGVector(dx: 1, dy: 0))
        #expect(moved.expandedToFit(since: cut).canvasRect == CGRect(x: 0, y: 0, width: 107, height: 80))
        var deleted = cut
        deleted.objects = []
        #expect(deleted.expandedToFit(since: cut) == deleted)
    }

    @Test func aNewObjectCountsEvenWhenAnotherIsCut() {
        var cut = base
        cut.canvasRect = CGRect(x: 0, y: 0, width: 70, height: 80)
        cut.objects = [box(CGRect(x: 60, y: 10, width: 30, height: 20))]
        var added = cut
        added.objects.append(box(CGRect(x: 60, y: 60, width: 20, height: 40)))
        // Only the new box (to x 80, y 100) counts: 96 wide, 116 high.
        #expect(added.expandedToFit(since: cut).canvasRect == CGRect(x: 0, y: 0, width: 96, height: 116))
    }

    @Test func anAxisThatWouldPassTheLimitKeepsItsExtent() {
        var document = base
        document.objects = [box(CGRect(x: 20_000, y: 90, width: 10, height: 10))]
        // Too far to follow sideways; downward it still grows.
        #expect(document.expandedToFit().canvasRect == CGRect(x: 0, y: 0, width: 100, height: 116))
    }

    @Test func everyAxisKeepsItsExtentPastTheLimit() {
        // Too far down: it still grows sideways.
        var down = base
        down.objects = [box(CGRect(x: 90, y: 20_000, width: 30, height: 10))]
        #expect(down.expandedToFit().canvasRect == CGRect(x: 0, y: 0, width: 136, height: 80))
        // Too far left, up, and (with another object) every side at once: the canvas stays as it was.
        var left = base
        left.objects = [box(CGRect(x: -20_000, y: 10, width: 10, height: 10))]
        #expect(left.expandedToFit() == left)
        var up = base
        up.objects = [box(CGRect(x: 10, y: -20_000, width: 10, height: 10))]
        #expect(up.expandedToFit() == up)
        // Too far left, but the object also grows the top.
        var both = base
        both.objects = [box(CGRect(x: -20_000, y: -30, width: 10, height: 10))]
        #expect(both.expandedToFit().canvasRect == CGRect(x: 0, y: -46, width: 100, height: 126))
    }

    @Test func theLimitAllowsExactly16383PixelsOnAnAxis() {
        // The canvas reaches the object's far edge plus 16: 16 367 + 16 is 16 383 across, which is allowed; one more is not.
        var right = base
        right.objects = [box(CGRect(x: 16_357, y: 10, width: 10, height: 10))]
        #expect(right.expandedToFit().canvasRect == CGRect(x: 0, y: 0, width: 16_383, height: 80))
        var tooFarRight = base
        tooFarRight.objects = [box(CGRect(x: 16_358, y: 10, width: 10, height: 10))]
        #expect(tooFarRight.expandedToFit() == tooFarRight)
        var bottom = base
        bottom.objects = [box(CGRect(x: 10, y: 16_357, width: 10, height: 10))]
        #expect(bottom.expandedToFit().canvasRect == CGRect(x: 0, y: 0, width: 100, height: 16_383))
        var tooFarDown = base
        tooFarDown.objects = [box(CGRect(x: 10, y: 16_358, width: 10, height: 10))]
        #expect(tooFarDown.expandedToFit() == tooFarDown)
        var left = base
        left.objects = [box(CGRect(x: -16_267, y: 10, width: 10, height: 10))]
        #expect(left.expandedToFit().canvasRect == CGRect(x: -16_283, y: 0, width: 16_383, height: 80))
        var tooFarLeft = base
        tooFarLeft.objects = [box(CGRect(x: -16_268, y: 10, width: 10, height: 10))]
        #expect(tooFarLeft.expandedToFit() == tooFarLeft)
        var up = base
        up.objects = [box(CGRect(x: 10, y: -16_287, width: 10, height: 10))]
        #expect(up.expandedToFit().canvasRect == CGRect(x: 0, y: -16_303, width: 100, height: 16_383))
        var tooFarUp = base
        tooFarUp.objects = [box(CGRect(x: 10, y: -16_288, width: 10, height: 10))]
        #expect(tooFarUp.expandedToFit() == tooFarUp)
    }

    @Test func objectsWithoutRealBoundsAreIgnored() {
        var document = base
        let nothing = AnnotationObject(kind: .stroke(StrokeObject(points: [], smoothed: false)),
                                       style: ObjectStyle(color: .black, lineWidth: 2, shadow: false))
        document.objects = [box(CGRect(x: Double.nan, y: 10, width: 10, height: 10)), box(CGRect(x: Double.nan, y: -500, width: 10, height: 10)), box(CGRect(x: 1e308, y: 10, width: 1e308, height: 10)), nothing,
                            box(CGRect(x: 10, y: Double.infinity, width: 10, height: 10)), box(CGRect(x: 90, y: 10, width: 30, height: 20))]
        #expect(document.expandedToFit().canvasRect == CGRect(x: 0, y: 0, width: 136, height: 80))
    }
}
