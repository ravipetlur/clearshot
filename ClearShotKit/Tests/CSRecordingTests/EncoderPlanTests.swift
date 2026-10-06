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

    @Test func theMeasuredCeilingsAndPicksAreTheDecidedOnes() {
        #expect(EncoderPlan.h264MaxSide == 4096)
        #expect(EncoderPlan.h264PixelsPerSecond == 450_000_000)
        #expect(EncoderPlan.hevcPixelsPerSecond == 760_000_000)
        #expect(EncoderPlan.headroom == 0.85)
        #expect(EncoderPlan.gifMaximumFramesPerSecond == 50)
        #expect(EncoderPlan.h264BitsPerPixel == 0.08)
        #expect(EncoderPlan.hevcBitsPerPixel == 0.05)
        #expect(EncoderPlan.intermediateBitsPerPixel == 0.25)
        #expect(EncoderPlan.minimumBitRate == 1_000_000)
    }

    @Test func theMainDisplayAt1xIsH264At60() {
        let plan = plan(3360, 1890, retinaTo1x: true)
        #expect(plan.codec == .h264)
        #expect(plan.width == 3360)
        #expect(plan.height == 1890)
        #expect(plan.framesPerSecond == 60)
        #expect(plan.requestedFramesPerSecond == 60)
        #expect(plan.requiresHardware)
        #expect(!plan.isFrameRateCapped)
        #expect(plan.readyNote == nil)
    }

    @Test func theNativeMainDisplayIsHEVCAt25() {
        let plan = plan(3360, 1890)
        #expect(plan.codec == .hevc)
        #expect(plan.width == 6720)
        #expect(plan.height == 3780)
        #expect(plan.framesPerSecond == 25)
        #expect(plan.requestedFramesPerSecond == 60)
        #expect(plan.isFrameRateCapped)
        #expect(plan.readyNote == "6720 × 3780 · 25 fps")
    }

    @Test func theNativePortraitDisplayIsHEVCAt28() {
        let plan = plan(1800, 3200)
        #expect(plan.codec == .hevc)
        #expect(plan.width == 3600)
        #expect(plan.height == 6400)
        #expect(plan.framesPerSecond == 28)
        #expect(plan.readyNote == "3600 × 6400 · 28 fps")
    }

    /// The hardware H.264 encoder fails above 4096 a side (−12903), however low the rate.
    @Test func aSideOver4096ForcesHEVCEvenAtLowRates() {
        let plan = plan(4112, 2160, scale: 1, fps: 15)
        #expect(plan.codec == .hevc)
        #expect(plan.framesPerSecond == 15)
        #expect(plan.readyNote == nil)
    }

    /// 3840 × 2160 × 30 is 249 Mpx/s, inside 85% of 450; at 60 it is 498 Mpx/s, which goes to HEVC, uncapped there.
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

    @Test func softwareEncodingIsUncappedH264() {
        let plan = plan(3360, 1890, hardware: false)
        #expect(plan.codec == .h264)
        #expect(plan.width == 6720)
        #expect(plan.height == 3780)
        #expect(plan.framesPerSecond == 60)
        #expect(!plan.requiresHardware)
        #expect(plan.readyNote == nil)
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
