import CoreGraphics
import CoreMedia
import CSCore
import Foundation
import ScreenCaptureKit
import Testing
@testable import CSCapture

/// A recording stream's settings, from the region and the encoder plan's values (literals here: CSCapture can't see
/// `EncoderPlan`). Nothing here starts a stream.
struct RecordingStreamSettingsTests {
    // Two displays in AppKit global points: the main display, and a portrait display left of and below it.
    static let main = DisplayInfo(id: 3, name: "Main Display", frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
                                  scale: 2, isBuiltIn: false, safeAreaTop: 0)
    static let portrait = DisplayInfo(id: 2, name: "Portrait Display",
                                      frame: CGRect(x: -1800, y: -819, width: 1800, height: 3200),
                                      scale: 2, isBuiltIn: false, safeAreaTop: 0)
    let layout = DisplayLayout(displays: [Self.main, Self.portrait])

    func settings(region: CGRect?, display: DisplayInfo = Self.main, width: Int = 640, height: Int = 480,
                  framesPerSecond: Int = 60, systemAudio: Bool = false, mono: Bool = false) -> RecordingStreamSettings {
        .make(region: region, display: display, layout: layout, width: width, height: height,
              framesPerSecond: framesPerSecond, showsCursor: true, systemAudio: systemAudio, mono: mono)
    }

    @Test func anAreaOnThePortraitDisplayUsesDisplayLocalPoints() {
        // 100 pt in from the portrait display's left edge; its top is 2 381 − 680 = 1 701 pt below the display's top
        // edge.
        let region = CGRect(x: -1700, y: 200, width: 640, height: 480)
        let settings = settings(region: region, display: Self.portrait)
        #expect(settings.display == Self.portrait)
        #expect(settings.sourceRect == CGRect(x: 100, y: 1701, width: 640, height: 480))
        #expect(settings.globalRect == region)
    }

    @Test func fullscreenHasNoSourceRect() {
        let settings = settings(region: nil, width: 3360, height: 1890)
        #expect(settings.sourceRect == nil)
        #expect(settings.globalRect == Self.main.frame)
    }

    @Test func monoAsksForOneChannel() {
        let mono = settings(region: nil, systemAudio: true, mono: true)
        #expect(mono.capturesSystemAudio)
        #expect(mono.systemAudioChannels == 1)
        let stereo = settings(region: nil, systemAudio: true)
        #expect(stereo.systemAudioChannels == 2)
        #expect(!settings(region: nil).capturesSystemAudio)
    }

    @Test func thePlansSizeAndRateAreUsed() {
        let settings = settings(region: CGRect(x: 100, y: 100, width: 640, height: 480), width: 1278, height: 958,
                                framesPerSecond: 25)
        #expect(settings.width == 1278)
        #expect(settings.height == 958)
        #expect(settings.framesPerSecond == 25)
        #expect(settings.showsCursor)
        #expect(settings.frameInterval(paused: false) == CMTime(value: 1, timescale: 25))
        // While paused the stream slows to a frame a second.
        #expect(settings.frameInterval(paused: true) == CMTime(value: 1, timescale: 1))
        #expect(RecordingStreamSettings.queueDepth == 8)
    }

    /// Scaled when the output differs from the source's pixels; captured at the display's point resolution when the
    /// output is no larger than the region in points (Retina scaled to 1x), else at its best.
    @Test func theOutputSizeDecidesScalingAndResolution() {
        let area = CGRect(x: 100, y: 100, width: 640, height: 480)
        let atPoints = settings(region: area, width: 640, height: 480)
        #expect(atPoints.scalesToFit)
        #expect(atPoints.capturesAtNominalResolution)
        let atPixels = settings(region: area, width: 1280, height: 960)
        #expect(!atPixels.scalesToFit)
        #expect(!atPixels.capturesAtNominalResolution)
        let fitted = settings(region: area, width: 1278, height: 958)
        #expect(fitted.scalesToFit)
        #expect(!fitted.capturesAtNominalResolution)
        let fullscreenAt1x = settings(region: nil, width: 3360, height: 1890)
        #expect(fullscreenAt1x.scalesToFit)
        #expect(fullscreenAt1x.capturesAtNominalResolution)
        let fullscreenNative = settings(region: nil, width: 6720, height: 3780)
        #expect(!fullscreenNative.scalesToFit)
        #expect(!fullscreenNative.capturesAtNominalResolution)
    }
}

/// ScreenCaptureKit's error codes (`SCError.h`), mapped to the stream's stops and start errors.
struct RecordingStreamErrorTests {
    func streamError(_ code: Int) -> NSError {
        NSError(domain: SCStreamErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "code \(code)"])
    }

    @Test func stopsMapToTheirReasons() {
        #expect(RecordingStreamStop(streamError(-3817)) == .userStopped)
        #expect(RecordingStreamStop(streamError(-3821)) == .systemStopped)
        #expect(RecordingStreamStop(streamError(-3822)) == .insufficientStorage)
        #expect(RecordingStreamStop(streamError(-3818)) == .audioFailed)
        #expect(RecordingStreamStop(streamError(-3819)) == .audioFailed)
        #expect(RecordingStreamStop(streamError(-3811)) == .failed(code: -3811, message: "code -3811"))
        let other = NSError(domain: NSOSStatusErrorDomain, code: -3817, userInfo: [NSLocalizedDescriptionKey: "other"])
        #expect(RecordingStreamStop(other) == .failed(code: -3817, message: "other"))
    }

    @Test func startErrorsMapToTheirReasons() {
        #expect(RecordingStartError(streamError(-3801)) == .permissionDenied)
        #expect(RecordingStartError(streamError(-3818)) == .audioFailed)
        // The DRM case (protected content on screen) fails to start with either of these.
        #expect(RecordingStartError(streamError(-3802)) == .failed(code: -3802))
        #expect(RecordingStartError(streamError(-3811)) == .failed(code: -3811))
        #expect(RecordingStartError(NSError(domain: NSCocoaErrorDomain, code: 4)) == .failed(code: 4))
    }
}
