import CoreGraphics
import Testing
@testable import CSRecording

struct EncoderPlanTests {
    /// A 6K main display, 3360 × 1890 points at 2x, and a portrait display, 1800 × 3200 points at 2x.
    func plan(_ width: CGFloat, _ height: CGFloat, scale: CGFloat = 2, retinaTo1x: Bool = false,
              maxResolution: RecordingMaxResolution = .original, fps: Int = 60, hardware: Bool = true,
              purpose: EncoderPlan.Purpose = .video) -> EncoderPlan {
        EncoderPlan.make(regionPoints: CGSize(width: width, height: height), scale: scale, scaleRetinaTo1x: retinaTo1x,
                         maxResolution: maxResolution, framesPerSecond: fps, hardwareEncoding: hardware, purpose: purpose)
    }

    /// A region and how it is to be recorded, and the plan expected for it. A nil expectation is not checked.
    struct Pick: Sendable, CustomTestStringConvertible {
        let name: String
        let plan: @Sendable (EncoderPlanTests) -> EncoderPlan
        let codec: VideoCodec
        var size: (width: Int, height: Int)?
        let framesPerSecond: Int
        var requestedFramesPerSecond: Int?
        var isFrameRateCapped: Bool?
        var requiresHardware: Bool?
        let readyNote: String?
        var testDescription: String { name }
    }

    static let picks: [Pick] = [
        Pick(name: "the main display at 1x is H.264 at 60", plan: { $0.plan(3360, 1890, retinaTo1x: true) },
             codec: .h264, size: (3360, 1890), framesPerSecond: 60, requestedFramesPerSecond: 60,
             isFrameRateCapped: false, requiresHardware: true, readyNote: nil),
        Pick(name: "the native main display is HEVC at 25", plan: { $0.plan(3360, 1890) },
             codec: .hevc, size: (6720, 3780), framesPerSecond: 25, requestedFramesPerSecond: 60,
             isFrameRateCapped: true, readyNote: "6720 × 3780 · 25 fps"),
        Pick(name: "the native portrait display is HEVC at 28", plan: { $0.plan(1800, 3200) },
             codec: .hevc, size: (3600, 6400), framesPerSecond: 28, readyNote: "3600 × 6400 · 28 fps"),
        // The hardware H.264 encoder fails above 4096 a side (−12903), however low the rate.
        Pick(name: "a side over 4096 forces HEVC even at low rates", plan: { $0.plan(4112, 2160, scale: 1, fps: 15) },
             codec: .hevc, framesPerSecond: 15, readyNote: nil),
        Pick(name: "software encoding is uncapped H.264", plan: { $0.plan(3360, 1890, hardware: false) },
             codec: .h264, size: (6720, 3780), framesPerSecond: 60, requiresHardware: false, readyNote: nil),
    ]

    @Test(arguments: picks)
    func theCodecSizeAndRateArePicked(_ pick: Pick) {
        let plan = pick.plan(self)
        #expect(plan.codec == pick.codec)
        if let size = pick.size {
            #expect(plan.width == size.width)
            #expect(plan.height == size.height)
        }
        #expect(plan.framesPerSecond == pick.framesPerSecond)
        if let requested = pick.requestedFramesPerSecond { #expect(plan.requestedFramesPerSecond == requested) }
        if let capped = pick.isFrameRateCapped { #expect(plan.isFrameRateCapped == capped) }
        if let hardware = pick.requiresHardware { #expect(plan.requiresHardware == hardware) }
        #expect(plan.readyNote == pick.readyNote)
    }

    @Test func h264StopsAtEightyFivePercentOf450() {
        let at30 = plan(3840, 2160, scale: 1, fps: 30)
        #expect(at30.codec == .h264)
        #expect(at30.framesPerSecond == 30)
        let at60 = plan(3840, 2160, scale: 1, fps: 60)
        #expect(at60.codec == .hevc)
        #expect(at60.framesPerSecond == 60)
        #expect(!at60.isFrameRateCapped)
    }

    @Test func maximumResolutionFitsTheLongSide() {
        #expect(RecordingMaxResolution.allCases.map(\.longSide) == [nil, 3840, 2560, 1920, 1280, 854])
        let main = plan(3360, 1890, retinaTo1x: true, maxResolution: .res1080p)
        #expect(main.width == 1920)
        #expect(main.height == 1080)
        let portrait = plan(1800, 3200, retinaTo1x: true, maxResolution: .res1080p)
        #expect(portrait.width == 1080)
        #expect(portrait.height == 1920)
        // Never upscaled.
        let small = plan(800, 600, retinaTo1x: true, maxResolution: .res1080p)
        #expect(small.width == 800)
        #expect(small.height == 600)
        // From the native size too: the Retina pixels are fitted, not the points.
        let native = plan(3360, 1890, maxResolution: .res4K)
        #expect(native.width == 3840)
        #expect(native.height == 2160)
        #expect(native.codec == .hevc)
    }

    @Test func sizesAreEven() {
        let odd = plan(1001, 667, scale: 1)
        #expect(odd.width == 1000)
        #expect(odd.height == 666)
        // A side too thin to halve keeps two pixels.
        let thin = plan(1, 1, scale: 1)
        #expect(thin.width == 2)
        #expect(thin.height == 2)
    }

    @Test func bitrateComesFromBitsPerPixel() {
        #expect(plan(1920, 1080, scale: 1).averageBitRate == 9_953_280)
        // HEVC at 0.05: 6720 × 3780 × 25 × 0.05.
        #expect(plan(3360, 1890).averageBitRate == 31_752_000)
        // Never under 1 Mbit/s.
        #expect(plan(100, 100, scale: 1, fps: 15).averageBitRate == 1_000_000)
        // An intermediate at 0.25: 800 × 450 × 50 × 0.25.
        #expect(plan(1600, 900, scale: 1, purpose: .gifIntermediate(maxWidth: 800)).averageBitRate == 4_500_000)
    }

    @Test func keyframesEveryTwoSecondsOrOneForAnIntermediate() {
        #expect(plan(1920, 1080, scale: 1).keyFrameInterval == 2)
        #expect(plan(1920, 1080, scale: 1, purpose: .gifIntermediate(maxWidth: 800)).keyFrameInterval == 1)
    }

    /// GIF's own limit is applied before the encoder's rule, so the note reports only an encoder cap.
    @Test func aGIFIntermediateIsAtMost800WideAnd50fps() {
        let gif = plan(1440, 900, purpose: .gifIntermediate(maxWidth: 800))
        #expect(gif.width == 800)
        #expect(gif.height == 500)
        #expect(gif.framesPerSecond == 50)
        #expect(gif.requestedFramesPerSecond == 50)
        #expect(gif.codec == .h264)
        #expect(gif.readyNote == nil)
        // A narrower region isn't upscaled, and a lower rate is kept.
        let narrow = plan(300, 200, fps: 15, purpose: .gifIntermediate(maxWidth: 800))
        #expect(narrow.width == 600)
        #expect(narrow.height == 400)
        #expect(narrow.framesPerSecond == 15)
        // "Original": no width limit, and the maximum resolution, a video setting, doesn't apply.
        let original = plan(1440, 900, maxResolution: .res720p, purpose: .gifIntermediate(maxWidth: nil))
        #expect(original.width == 2880)
        #expect(original.height == 1800)
        #expect(original.framesPerSecond == 50)
    }
}
