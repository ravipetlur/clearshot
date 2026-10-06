import CoreGraphics
import CoreMedia
import CoreVideo
import CSCore
import Foundation
import ScreenCaptureKit

/// How a recording stream captures: where, at what size and rate, and with or without system audio. The size and rate
/// are the encoder plan's (CSCapture can't see `EncoderPlan`, so the caller passes its values).
public struct RecordingStreamSettings: Sendable, Equatable {
    public let display: DisplayInfo
    /// Display-local points (top-left origin) on whole pixels, what `SCStreamConfiguration.sourceRect` takes; nil
    /// records the whole display.
    public let sourceRect: CGRect?
    /// The recorded region in AppKit global points: the snapped area, or the display's frame.
    public let globalRect: CGRect
    public let width: Int, height: Int, framesPerSecond: Int
    public let showsCursor: Bool
    public let capturesSystemAudio: Bool
    /// 1 with "Record in mono", else 2.
    public let systemAudioChannels: Int

    /// The frames ScreenCaptureKit keeps in flight. The writer holds one of them, the latest.
    public static let queueDepth = 8
    public static let systemAudioSampleRate = 48_000

    /// An area snaps outward to whole pixels (`RegionStreamGeometry`); nil records the whole display.
    public static func make(region: CGRect?, display: DisplayInfo, layout: DisplayLayout, width: Int, height: Int,
                            framesPerSecond: Int, showsCursor: Bool, systemAudio: Bool, mono: Bool) -> RecordingStreamSettings {
        var sourceRect: CGRect?
        var globalRect = display.frame
        if let region {
            let geometry = RegionStreamGeometry.make(region: region, display: display, layout: layout)
            sourceRect = geometry.sourceRect
            globalRect = geometry.globalRect
        }
        return RecordingStreamSettings(display: display, sourceRect: sourceRect, globalRect: globalRect, width: width,
                                       height: height, framesPerSecond: framesPerSecond, showsCursor: showsCursor,
                                       capturesSystemAudio: systemAudio, systemAudioChannels: mono ? 1 : 2)
    }

    /// The recorded region's size in points.
    var pointSize: CGSize {
        sourceRect?.size ?? display.frame.size
    }

    /// Whether ScreenCaptureKit scales the region (keeping its aspect ratio): the output size differs from the region's
    /// pixels.
    public var scalesToFit: Bool {
        width != Int((pointSize.width * display.scale).rounded()) || height != Int((pointSize.height * display.scale).rounded())
    }

    /// Whether the display is captured at its point resolution (`.nominal`): the output is no larger than the region in
    /// points, as with Retina scaled to 1x. Otherwise at its pixels (`.best`).
    public var capturesAtNominalResolution: Bool {
        CGFloat(width) <= pointSize.width && CGFloat(height) <= pointSize.height
    }

    /// The minimum frame interval: 1/fps, or a frame a second while paused.
    public func frameInterval(paused: Bool) -> CMTime {
        paused ? CMTime(value: 1, timescale: 1) : CMTime(value: 1, timescale: CMTimeScale(max(1, framesPerSecond)))
    }
}

/// What a recording stream delivers, on its sample queue, stamped in the stream's clock.
public enum RecordingStreamOutput: Sendable {
    /// A new picture: a complete frame, or the stream's first. ScreenCaptureKit's own buffer, not a copy, so hold only
    /// the latest: holding more starves the stream's pool of `queueDepth` buffers.
    case frame(CVReadOnlyPixelBuffer, presentationTime: CMTime)
    /// A chunk of system audio: float PCM at 48 kHz.
    case systemAudio(CMReadySampleBuffer<CMSampleBuffer.DynamicContent>)
}

/// Why ScreenCaptureKit ended a recording stream by itself (`SCError.h`).
public enum RecordingStreamStop: Sendable, Equatable {
    /// −3817: stopped from the system, outside ClearShot.
    case userStopped
    /// −3821
    case systemStopped
    /// −3822
    case insufficientStorage
    /// −3818, −3819: system audio failed, and ScreenCaptureKit stopped the whole stream with it.
    case audioFailed
    case failed(code: Int, message: String)

    init(_ error: any Error) {
        let error = error as NSError
        guard error.domain == SCStreamErrorDomain else {
            self = .failed(code: error.code, message: error.localizedDescription)
            return
        }
        switch error.code {
        case SCStreamError.Code.userStopped.rawValue: self = .userStopped
        case SCStreamError.Code.systemStoppedStream.rawValue: self = .systemStopped
        case SCStreamError.Code.insufficientStorage.rawValue: self = .insufficientStorage
        case SCStreamError.Code.failedToStartAudioCapture.rawValue, SCStreamError.Code.failedToStopAudioCapture.rawValue:
            self = .audioFailed
        default: self = .failed(code: error.code, message: error.localizedDescription)
        }
    }
}

/// Why a recording stream didn't start.
public enum RecordingStartError: Error, Equatable {
    /// No Screen Recording permission (also −3801).
    case permissionDenied
    case displayNotFound
    /// −3818: system audio didn't start.
    case audioFailed
    /// Anything else. Protected (DRM) content on screen fails the start with −3802 or −3811.
    case failed(code: Int)

    init(_ error: any Error) {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (SCStreamErrorDomain, SCStreamError.Code.userDeclined.rawValue): self = .permissionDenied
        case (SCStreamErrorDomain, SCStreamError.Code.failedToStartAudioCapture.rawValue): self = .audioFailed
        default: self = .failed(code: error.code)
        }
    }
}

/// A live stream of a region or a whole display for recording. It leaves out ClearShot and Notification Center as whole
/// apps, so windows of theirs that open later are left out too, except ClearShot's kept windows (the click overlay, the
/// pins of the moment); and the desktop icons while Hide Desktop Icons or the cover is on (`RecordingContentRules`).
/// ScreenCaptureKit's own microphone capture isn't used: a microphone that fails to start would fail the whole stream
/// (−3820). `MicrophoneCapture` records it instead, converting its times with `streamTime(converting:from:)`.
///
/// A stream runs once: `start`, then `stop`. A second `start`, or one after `stop` (or after a `start` that threw), does
/// nothing; make a new stream to try again.
///
/// `onOutput` runs on `sampleQueue` (the writer's queue); `onStop` on ScreenCaptureKit's delegate queue, only when the
/// stream ends by itself, never after `stop`. Neither runs on the main actor, and calls never overlap. Both run while the
/// stream holds the lock that `stop`, `currentTime` and `streamTime` take, so they must return quickly, never wait on a
/// thread calling into the stream, and never call into the stream themselves. Once `stop` begins neither is called.
public final class ScreenRecordingStream: NSObject, @unchecked Sendable {
    /// What the stream keeps under its runner's lock.
    struct State {
        /// The stream's synchronization clock, set once it started.
        var clock: CMClock?
        /// The latest presentation time ScreenCaptureKit handed over: every screen sample that shows the screen (complete,
        /// the first, and idle ones on a still screen; never suspended, blank or stopped ones), and every audio chunk.
        var lastSampleTime: CMTime?

        mutating func note(_ time: CMTime) {
            if time.isNumeric, lastSampleTime.map({ time > $0 }) ?? true {
                lastSampleTime = time
            }
        }
    }

    private let settings: RecordingStreamSettings
    private let rules: RecordingContentRules
    private let sampleQueue: DispatchQueue
    private let onOutput: @Sendable (RecordingStreamOutput) -> Void
    private let onStop: @Sendable (RecordingStreamStop, CMTime?) -> Void
    /// Start once, stop, and the handlers called only under its lock with the stream not stopped, so nothing slips out
    /// after `stop` has stopped it. Its lock also guards `State`.
    private let runner = StreamRunner(name: "Recording stream", log: Log.recording, state: State())
    private let pauseUpdates = SerialUpdates()

    /// `onStop` gets the reason and the latest presentation time ScreenCaptureKit handed over (every screen sample that
    /// shows the screen, idle ones on a still screen included, and every system audio chunk; nil when nothing came):
    /// where a recording the stream ended by itself ends, since no live clock is read then. The stream never sees the
    /// microphone's samples, so the recording ends at the later of this and the newest microphone time forwarded to the
    /// writer.
    public init(settings: RecordingStreamSettings, rules: RecordingContentRules, sampleQueue: DispatchQueue,
                onOutput: @escaping @Sendable (RecordingStreamOutput) -> Void,
                onStop: @escaping @Sendable (RecordingStreamStop, _ lastSampleTime: CMTime?) -> Void) {
        self.settings = settings
        self.rules = rules
        self.sampleQueue = sampleQueue
        self.onOutput = onOutput
        self.onStop = onStop
    }

    /// The stream's synchronization clock now; nil before the stream started. Read the stop time here before `stop`.
    public var currentTime: CMTime? {
        runner.withState { $0.clock?.time }
    }

    /// `time` on `source` (the microphone session's synchronization clock) converted into the stream's clock; nil
    /// before the stream started. The conversion runs under the stream's lock, so its clock never leaves it.
    public func streamTime(converting time: CMTime, from source: CMClock) -> CMTime? {
        runner.withState { state in state.clock.map { source.convertTime(time, to: $0) } }
    }

    /// Starts streaming. Show the windows the recording keeps (the click overlay) and the recording's own windows first:
    /// the content is fetched here, and a window or an app that isn't on screen yet can be missing from it.
    public func start() async throws(RecordingStartError) {
        try await runner.start(display: settings.display.id, permissionDenied: RecordingStartError.permissionDenied,
                               displayNotFound: .displayNotFound, mapError: RecordingStartError.init) { content, display in
            let stream = SCStream(filter: filter(on: display, content: content), configuration: configuration(paused: false),
                                  delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if settings.capturesSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            return stream
        } started: { stream, state in
            state.clock = stream.synchronizationClock ?? {
                Log.recording.warning("Recording stream: no synchronization clock; using the host time clock")
                return CMClock.hostTimeClock
            }()
        }
    }

    /// Stops the stream and waits until ScreenCaptureKit has. Samples still in flight are dropped.
    public func stop() async {
        await runner.stop()
    }

    /// Slows the stream to a frame a second while paused, and back to the plan's rate. Samples keep coming; the writer
    /// drops them while paused. Calls run one at a time in the order they arrive, so a quick pause and resume end at
    /// the resume's rate even when the pause's update is slow.
    public func setPaused(_ paused: Bool) async {
        await pauseUpdates.run { [self] in
            guard let running = runner.runningStream() else { return }
            do {
                try await running.updateConfiguration(configuration(paused: paused))
            } catch {
                Log.recording.error("Recording stream: couldn't change the frame rate (paused \(paused)): "
                    + error.localizedDescription)
            }
        }
    }

    // MARK: Samples and stops (internal for tests, which feed synthetic sample buffers)

    /// One sample ScreenCaptureKit handed over, on `sampleQueue`.
    func receive(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !runner.hasStopped else { return }
        let time = sampleBuffer.presentationTimeStamp
        switch type {
        case .screen:
            // Only new pictures are handed on: idle samples (nothing changed) and the other statuses are skipped, since
            // the writer's held frame covers them. An idle sample's time is noted too, so a stop on a still screen ends
            // the recording at the latest one rather than at the last change; a suspended, blank or stopped one shows
            // nothing, so its time isn't.
            let status = RegionStream.status(of: sampleBuffer)
            var frame: RecordingStreamOutput?
            if status == .complete || status == .started, let imageBuffer = sampleBuffer.imageBuffer {
                // ScreenCaptureKit's buffer, read-only from here on; nothing else here keeps it.
                nonisolated(unsafe) let pixels = imageBuffer
                frame = .frame(CVReadOnlyPixelBuffer(unsafeBuffer: pixels), presentationTime: time)
            }
            let showsTheScreen = status == .complete || status == .started || status == .idle
            runner.deliver { state in
                if showsTheScreen {
                    state.note(time)
                }
                if let frame {
                    onOutput(frame)
                }
            }
        case .audio:
            guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
            nonisolated(unsafe) let chunk = sampleBuffer
            let output = RecordingStreamOutput.systemAudio(CMReadySampleBuffer(unsafeBuffer: chunk))
            runner.deliver { state in
                state.note(time)
                onOutput(output)
            }
        default:
            break
        }
    }

    /// ScreenCaptureKit ended the stream by itself.
    func ended(_ reason: RecordingStreamStop) {
        runner.deliver(ending: true) { state in
            onStop(reason, state.lastSampleTime)
        }
    }

    // MARK: Private

    /// Excludes ClearShot and Notification Center and lists the windows the rules except. Should ClearShot be missing
    /// from the applications, its windows of this moment that aren't kept are left out by ID instead.
    private func filter(on display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let excludedIDs = Set(rules.excludedBundleIDs)
        let excludedApplications = content.applications.filter { excludedIDs.contains($0.bundleIdentifier) }
        let ownAppExcluded = excludedApplications.contains { $0.bundleIdentifier == rules.ownBundleID }
        if !ownAppExcluded {
            Log.recording.warning("Recording stream: \(rules.ownBundleID) isn't among the shareable applications; "
                + "leaving out its current windows by ID instead")
        }
        let excepted = rules.exceptedWindowIDs(from: content.windows.map(WindowRecord.init), ownAppExcluded: ownAppExcluded)
        return SCContentFilter(display: display, excludingApplications: excludedApplications,
                               exceptingWindows: content.windows.filter { excepted.contains($0.windowID) })
    }

    private func configuration(paused: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        if let sourceRect = settings.sourceRect {
            configuration.sourceRect = sourceRect
        }
        configuration.width = settings.width
        configuration.height = settings.height
        configuration.scalesToFit = settings.scalesToFit
        configuration.preservesAspectRatio = settings.scalesToFit
        configuration.captureResolution = settings.capturesAtNominalResolution ? .nominal : .best
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        // The Core Video string, identical to the display stream's (`CGDisplayStream.h`).
        configuration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        configuration.minimumFrameInterval = settings.frameInterval(paused: paused)
        configuration.queueDepth = RecordingStreamSettings.queueDepth
        configuration.showsCursor = settings.showsCursor
        configuration.capturesAudio = settings.capturesSystemAudio
        if settings.capturesSystemAudio {
            configuration.sampleRate = RecordingStreamSettings.systemAudioSampleRate
            configuration.channelCount = settings.systemAudioChannels
            configuration.excludesCurrentProcessAudio = true
        }
        return configuration
    }
}

extension ScreenRecordingStream: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        receive(sampleBuffer, of: type)
    }
}

extension ScreenRecordingStream: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let reason = RecordingStreamStop(error)
        Log.recording.error("Recording stream stopped: \(error.localizedDescription) (\(reason))")
        ended(reason)
    }
}
