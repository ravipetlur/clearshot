import CoreGraphics
import Dispatch
import Synchronization
import Testing
@testable import CSScrolling

struct StitchSessionTests {
    let page = SyntheticPage.plain
    let configuration = StitchConfiguration(pixelsPerPoint: 2)

    private typealias Delivery = (update: StitchUpdate, preview: CGImage?)

    /// A session whose updates arrive on the returned stream, in order.
    private func session(estimator: any OffsetEstimator = NoOffsetEstimate(), configuration: StitchConfiguration? = nil,
                         previewSide: Int = 400) -> (StitchSession, AsyncStream<Delivery>.Iterator) {
        let (deliveries, continuation) = AsyncStream.makeStream(of: Delivery.self)
        let session = StitchSession(stitcher: Stitcher(configuration: configuration ?? self.configuration, estimator: estimator),
                                    previewSide: previewSide) { update, preview in
            continuation.yield((update, preview))
        }
        return (session, deliveries.makeAsyncIterator())
    }

    @Test func framesSubmittedFromAnotherQueueAreStitchedAndComposed() async {
        let (session, deliveries) = session()
        var updates = deliveries
        let frames = [0, 120, 260, 400, 520].map { page.frame(at: $0, length: 1000) }
        func submit(_ frames: ArraySlice<StitchFrame>) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    for frame in frames { session.submit(frame) }
                    done.resume()
                }
            }
        }
        // The first frame is where the capture starts; the rest come as fast as they can: a frame still waiting may
        // be replaced, but every pair that is stitched overlaps.
        await submit(frames[..<1])
        #expect(await updates.next()?.update.accepted == true)
        await submit(frames[1...])
        let image = await session.finish()
        #expect(image?.width == 800 && image?.height == 1520)
        if let image {
            #expect(firstDifferentRow(tightBytes(of: image), page.expected(to: 520, length: 1000), rowBytes: 3200) == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aFrameArrivingWhileOneWaitsReplacesIt() async {
        let gate = GateEstimator()
        let (session, deliveries) = session(estimator: gate,
                                            configuration: StitchConfiguration(pixelsPerPoint: 2, axis: .vertical))
        var updates = deliveries
        session.submit(page.frame(at: 0, length: 1000))
        let first = await updates.next()
        #expect(first?.update.offset == 0)
        // The next frame holds the queue in the estimator while two more arrive: the second replaces the first.
        session.submit(page.frame(at: 100, length: 1000))
        #expect(gate.waitUntilHeld())
        session.submit(page.frame(at: 200, length: 1000))
        session.submit(page.frame(at: 300, length: 1000))
        gate.letGo()
        let second = await updates.next()
        let third = await updates.next()
        #expect(second?.update.offset == 100)
        #expect(third?.update.offset == 200)
        let image = await session.finish()
        #expect(image?.height == 1300)
    }

    @Test func thePreviewGrowsByEachAcceptedStrip() async {
        let (session, deliveries) = session(previewSide: 400)
        var updates = deliveries
        var preview: CGImage?
        for position in [0, 150, 330, 500, 640] {
            session.submit(page.frame(at: position, length: 1000))
            let delivery = await updates.next()
            #expect(delivery?.update.accepted == true)
            preview = delivery?.preview
            let expected = Int((Double(1000 + position) * 400 / 800).rounded())
            #expect(preview?.width == 400)
            #expect(abs((preview?.height ?? 0) - expected) <= 1, "after \(position)")
        }
        // A frame that isn't accepted brings no new preview.
        session.submit(page.frame(at: 640, length: 1000))
        let still = await updates.next()
        #expect(still?.update.accepted == false && still?.preview == nil)
        // The preview shows the page: paper above the first text line, ink in it (rows 9–34 of the page, 4–17 at half size).
        if let preview {
            let bytes = tightBytes(of: preview)
            #expect(bytes[0..<(400 * 4)].allSatisfy { $0 > 0xF0 })
            #expect(bytes[(10 * 1600)..<(11 * 1600)].contains { $0 < 0xC0 })
        }
        _ = await session.finish()
    }

    @Test func aHorizontalCapturesPreviewGrowsAcross() async {
        let (session, deliveries) = session(previewSide: 400)
        var updates = deliveries
        for position in [0, 200, 450] {
            session.submit(page.frame(at: position, length: 1000, axis: .horizontal))
            let preview = await updates.next()?.preview
            // Before the axis is known the preview is laid out vertically; once it locks horizontal it turns.
            if position > 0 {
                #expect(preview?.height == 400)
                #expect(abs((preview?.width ?? 0) - Int((Double(1000 + position) / 2).rounded())) <= 1)
            }
        }
        _ = await session.finish()
    }

    @Test(arguments: [ScrollAxis.vertical, .horizontal])
    func aNarrowRegionsPreviewIsNeverLargerThanTheCapture(axis: ScrollAxis) async {
        // 120 pt at 2 px a point is 240 px across, under the 400 px preview: the preview is the capture as it is, never
        // blown up, as many pixels across as the frames and exactly as long as what is stitched so far.
        let narrow = SyntheticPage(width: 240, length: 9000)
        let (session, deliveries) = session(previewSide: 400)
        var updates = deliveries
        for position in [0, 150, 330, 500] {
            session.submit(narrow.frame(at: position, length: 1000, axis: axis))
            let delivery = await updates.next()
            #expect(delivery?.update.accepted == true)
            // Before the first move the axis isn't known and the preview is laid out vertically.
            guard position > 0 || axis == .vertical else { continue }
            let preview = delivery?.preview
            let (across, along) = axis == .vertical ? (preview?.width, preview?.height) : (preview?.height, preview?.width)
            #expect(across == 240, "after \(position)")
            #expect(along == 1000 + position, "after \(position)")
            if let preview {
                let difference = firstDifferentRow(tightBytes(of: preview),
                                                   narrow.expected(to: position, length: 1000, axis: axis),
                                                   rowBytes: preview.width * 4)
                #expect(difference == nil, "after \(position): first differing row \(difference ?? -1)")
            }
        }
        _ = await session.finish()
    }

    @Test func cancelThenFinishGivesNothing() async {
        let (session, deliveries) = session()
        var updates = deliveries
        session.submit(page.frame(at: 0, length: 1000))
        _ = await updates.next()
        session.submit(page.frame(at: 300, length: 1000))
        _ = await updates.next()
        session.cancel()
        session.submit(page.frame(at: 600, length: 1000))
        #expect(await session.finish() == nil)
    }
}

/// Holds the stitching queue inside its first estimate until released; passes every later one through.
private final class GateEstimator: OffsetEstimator, @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let isFirst = Mutex(true)

    /// Waits (up to 20 s) until the queue is held in the first estimate.
    func waitUntilHeld() -> Bool {
        entered.wait(timeout: .now() + 20) == .success
    }

    func letGo() {
        release.signal()
    }

    func estimate(from previous: StitchFrame, to current: StitchFrame, band: Range<Int>, axis: ScrollAxis) -> Int? {
        let first = isFirst.withLock { isFirst in
            defer { isFirst = false }
            return isFirst
        }
        if first {
            entered.signal()
            release.wait()
        }
        return nil
    }
}
