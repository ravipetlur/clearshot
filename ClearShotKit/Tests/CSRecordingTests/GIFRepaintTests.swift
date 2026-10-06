import Foundation
import Testing
@testable import CSRecording

/// What the stabiliser repaints when content changes: a pixel whose shown colour is more than T from its source is
/// repainted with the frame palette's colour when that is closer by more than the margin, so nothing that went leaves a
/// ghost. Each case (400 × 225, the global palette sampled from the scene without the event) ends as a GIF in which the
/// event never happened would: no more pixels past T + margin from the source.
struct GIFRepaintTests {
    typealias Fixtures = GIFFixtures

    static let width = 400
    static let height = 225

    /// The scene, or the scene with a photo where `photo` (the colours the palette is sampled with).
    func scene(photo: Bool = false) -> GIFFrame {
        let scene = Fixtures.scene(0, width: Self.width, height: Self.height)
        guard photo else { return scene }
        return Fixtures.painted(scene, (200, 50, 150, 100)) { x, y in
            Fixtures.blend(x, y, width: 150, height: 100, from: 0x28_5AC8, to: 0xDC_C850)
        }
    }

    /// Pixels more than T + margin off at the end of `frames`, and at the end of as many frames of the last one alone.
    func ghost(_ frames: [GIFFrame], paletteFrom sample: GIFFrame, plan: GIFQualityPlan) throws -> (event: Int, never: Int) {
        let palette = GIFQuantizer.palette(from: [sample], colors: plan.paletteColors, mergingWithin: plan.threshold)
        let last = frames[frames.count - 1]
        let limit = plan.threshold + GIFFrameEncoder.repaintMargin
        let event = try Fixtures.encode(frames, palette: palette, plan: plan)
        let never = try Fixtures.encode(Array(repeating: last, count: frames.count), palette: palette, plan: plan)
        return (Fixtures.pixelsOff(event, against: last, by: limit), Fixtures.pixelsOff(never, against: last, by: limit))
    }

    /// A sheet or popover whose body is close to the window behind it, with a photo inset in colours the scene hasn't
    /// (so it takes a local table, which holds the body's colour too), opens for 3 frames and closes: nothing of it stays.
    @Test(arguments: [(13, true), (9, true), (13, false)])
    func aClosedDialogLeavesNoGhost(bodyOffset: Int, optimize: Bool) throws {
        let plan = GIFQualityPlan(quality: 100, optimize: optimize)
        let scene = scene()
        let body = UInt32(245 - bodyOffset) << 16 | UInt32(245 - bodyOffset) << 8 | UInt32(247 - bodyOffset)
        let dialog = Fixtures.painted(Fixtures.painted(scene, (100, 50, 200, 120)) { _, _ in body }, (130, 80, 80, 60)) {
            Fixtures.blend($0, $1, width: 80, height: 60, from: 0x8C_1E50, to: 0x1E_8C50)
        }
        let frames = [scene, scene] + Array(repeating: dialog, count: 3) + Array(repeating: scene, count: 8)
        let result = try ghost(frames, paletteFrom: scene, plan: plan)
        #expect(result.event <= result.never)
        if optimize { #expect(result.event == 0) }
    }

    /// A photo card with a soft 10 px shadow crosses the scene, 2 px a frame, and goes: no trail stays.
    @Test func aMovingCardLeavesNoTrail() throws {
        let plan = GIFQualityPlan(quality: 100, optimize: true)
        let scene = scene()
        func card(at left: Int) -> GIFFrame {
            // The shadow darkens what is under it, fading out over 10 px; the card covers its middle.
            let shadowed = Fixtures.painted(scene, (left - 10, 90, 100, 70)) { x, y in
                let (dx, dy) = (max(0, max(10 - x, x - 89)), max(0, max(10 - y, y - 59)))
                let fade = 0.35 * (1 - min(1, Double(max(dx, dy)) / 10))
                let offset = (90 + y) * scene.bytesPerRow + (left - 10 + x) * 4
                guard offset >= 0, offset + 2 < scene.bgra.count else { return nil }
                let darken = { (value: UInt8) in UInt32((Double(value) * (1 - fade)).rounded()) }
                return darken(scene.bgra[offset + 2]) << 16 | darken(scene.bgra[offset + 1]) << 8 | darken(scene.bgra[offset])
            }
            return Fixtures.painted(shadowed, (left, 100, 80, 50)) {
                Fixtures.blend($0, $1, width: 80, height: 50, from: 0xF0_8C3C, to: 0x3C_B4F0)
            }
        }
        let frames = [scene] + (0..<40).map { card(at: 20 + 2 * $0) } + Array(repeating: scene, count: 6)
        let result = try ghost(frames, paletteFrom: scene, plan: plan)
        #expect(result.event <= result.never)
        #expect(result.event == 0)
    }

    /// A cursor whose soft shadow darkens the photo under it (colours the palette hasn't) crosses a photo the global
    /// palette has, then leaves: the photo is as it was.
    @Test func aCursorOverAPhotoLeavesNoTrail() throws {
        let plan = GIFQualityPlan(quality: 100, optimize: true)
        let photo = scene(photo: true)
        func cursor(at point: (x: Int, y: Int)) -> GIFFrame {
            Fixtures.painted(photo, (point.x - 12, point.y - 12, 25, 25)) { x, y in
                let distance = (Double((x - 12) * (x - 12) + (y - 12) * (y - 12))).squareRoot()
                if distance <= 5 { return 0xFF_FFFF }
                guard distance <= 12 else { return nil }
                // The shadow: the photo darkened by up to half, fading out.
                let offset = (point.y - 12 + y) * photo.bytesPerRow + (point.x - 12 + x) * 4
                let shade = 0.5 * (12 - distance) / 7
                let darken = { (value: UInt8) in UInt32((Double(value) * (1 - min(shade, 0.5))).rounded()) }
                return darken(photo.bgra[offset + 2]) << 16 | darken(photo.bgra[offset + 1]) << 8 | darken(photo.bgra[offset])
            }
        }
        let frames = [photo, photo] + (0..<45).map { cursor(at: (205 + 3 * $0, 55 + 2 * $0)) } + Array(repeating: photo, count: 5)
        let result = try ghost(frames, paletteFrom: photo, plan: plan)
        #expect(result.event <= result.never)
    }
}
