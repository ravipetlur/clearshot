import CoreGraphics
import Testing
@testable import CSScrolling

struct AutoScrollStepTests {
    let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start + .milliseconds(milliseconds)
    }

    private func update(accepted: Bool = false, offset: Int = 0, noMatch: Bool = false) -> StitchUpdate {
        StitchUpdate(accepted: accepted, noMatch: noMatch, offset: offset, axis: .vertical,
                     outputSize: CGSize(width: 800, height: 1000), warnings: noMatch ? [.slowDown] : [], reachedLimit: false)
    }

    @Test func theStepSettlesAHundredMillisecondsAfterTheLastFrame() {
        var step = AutoScrollStep(startedAt: start)
        step.note(update(accepted: true, offset: 300), at: at(40))
        step.note(update(), at: at(90))
        #expect(!step.isSettled(at: at(189)))
        #expect(step.isSettled(at: at(190)))
    }

    @Test func withoutAFrameTheStepSettlesAfterThreeHundredMilliseconds() {
        let step = AutoScrollStep(startedAt: start)
        // No frame came at all: the page didn't change (the stream sends idles), so there is no quiet time to wait for.
        #expect(!step.isSettled(at: at(150)))
        #expect(!step.isSettled(at: at(299)))
        #expect(step.isSettled(at: at(300)))
        #expect(step.movedPoints(pixelsPerPoint: 2) == 0)
    }

    @Test func framesThatKeepComingSettleAtThreeHundredMilliseconds() {
        var step = AutoScrollStep(startedAt: start)
        // An animation on the page sends a frame every 33 ms; the step doesn't wait for it forever.
        for time in stride(from: 0, through: 330, by: 33) {
            step.note(update(), at: at(time))
            #expect(step.isSettled(at: at(time)) == (time >= 300))
        }
    }

    @Test func acceptedOffsetsAddUpInPoints() {
        var step = AutoScrollStep(startedAt: start)
        step.note(update(accepted: true, offset: 300), at: at(30))
        step.note(update(), at: at(60))
        step.note(update(accepted: true, offset: 101), at: at(90))
        // 401 source pixels at 2 px a point.
        #expect(step.movedPoints(pixelsPerPoint: 2) == 201)
        #expect(step.movedPoints(pixelsPerPoint: 1) == 401)
    }

    @Test func stillsAndAnimationsMoveNothing() {
        var step = AutoScrollStep(startedAt: start)
        step.note(update(), at: at(30))
        step.note(update(), at: at(60))
        #expect(step.movedPoints(pixelsPerPoint: 2) == 0)
    }

    @Test func aStepWhoseLastFrameHadNoMatchMovedAnUnknownDistance() {
        var step = AutoScrollStep(startedAt: start)
        step.note(update(noMatch: true), at: at(30))
        #expect(step.movedPoints(pixelsPerPoint: 2) == nil)
        // Even after an accepted move: the page ended up where the stitch can't follow it.
        var overshot = AutoScrollStep(startedAt: start)
        overshot.note(update(accepted: true, offset: 300), at: at(30))
        overshot.note(update(noMatch: true), at: at(60))
        #expect(overshot.movedPoints(pixelsPerPoint: 2) == nil)
    }

    @Test func aNoMatchThatAMoveFollowsCountsTheMove() {
        var step = AutoScrollStep(startedAt: start)
        step.note(update(noMatch: true), at: at(30))
        step.note(update(accepted: true, offset: 240), at: at(60))
        #expect(step.movedPoints(pixelsPerPoint: 2) == 120)
    }
}
