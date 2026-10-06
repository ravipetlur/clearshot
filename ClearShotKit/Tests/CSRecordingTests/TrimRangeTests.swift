import Testing
@testable import CSRecording

struct TrimRangeTests {
    func isClose(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

    @Test func clampsToTheDuration() {
        let range = TrimRange(start: -1, end: 12, duration: 10, framesPerSecond: nil)
        #expect(range.start == 0)
        #expect(range.end == 10)
        let inside = TrimRange(start: 2, end: 6, duration: 10, framesPerSecond: nil)
        #expect(inside.start == 2)
        #expect(inside.end == 6)
    }

    @Test func neverShorterThanATenth() {
        #expect(TrimRange.minimumLength == 0.1)
        let short = TrimRange(start: 5, end: 5.02, duration: 10, framesPerSecond: nil)
        #expect(short.start == 5)
        #expect(isClose(short.end, 5.1))
        // At the end the start moves back instead.
        let atEnd = TrimRange(start: 9.98, end: 10, duration: 10, framesPerSecond: nil)
        #expect(isClose(atEnd.start, 9.9))
        #expect(atEnd.end == 10)
        // Snapped to 24 fps frames, it is still at least a tenth, in whole frames.
        let snapped = TrimRange(start: 1, end: 1.05, duration: 10, framesPerSecond: 24)
        #expect(snapped.end - snapped.start >= 0.1)
        #expect(isClose(snapped.start, 1))
        #expect(isClose(snapped.end, 27.0 / 24))
        // A clip shorter than a tenth is kept whole.
        let tiny = TrimRange(start: 0.01, end: 0.02, duration: 0.05, framesPerSecond: nil)
        #expect(tiny.start == 0)
        #expect(tiny.end == 0.05)
    }

    /// A 1.37 s start at 30 fps begins on frame 41.
    @Test func snapsToFrames() {
        let range = TrimRange(start: 1.37, end: 4.01, duration: 10, framesPerSecond: 30)
        #expect(isClose(range.start, 1.3667))
        #expect(isClose(range.end, 4))
        // The duration is a boundary too, even off the frame grid.
        let toTheEnd = TrimRange(start: 2, end: 10.02, duration: 10.02, framesPerSecond: 30)
        #expect(toTheEnd.end == 10.02)
    }
}
