import CoreMedia
import CoreVideo
import CSCore
import Foundation
import ScreenCaptureKit
import Synchronization
import Testing
@testable import CSCapture

/// What a recording stream hands on, fed synthetic sample buffers shaped like ScreenCaptureKit's: screen samples with a
/// frame status attachment and float PCM audio. No stream is started.
struct RecordingStreamDeliveryTests {
    /// What the handlers saw: each output's kind and time, and each stop.
    final class Received: Sendable {
        let outputs = Mutex<[(kind: String, time: Double)]>([])
        let stops = Mutex<[(reason: RecordingStreamStop, time: Double?)]>([])
    }

    let received = Received()
    let stream: ScreenRecordingStream

    init() {
        let display = DisplayInfo(id: 3, name: "Main", frame: CGRect(x: 0, y: 0, width: 3360, height: 1890), scale: 2,
                                  isBuiltIn: false, safeAreaTop: 0)
        let settings = RecordingStreamSettings.make(region: nil, display: display, layout: DisplayLayout(displays: [display]),
                                                    width: 64, height: 36, framesPerSecond: 30, showsCursor: false,
                                                    systemAudio: true, mono: false)
        let rules = RecordingContentRules(ownBundleID: "test.clearshot", keptOwnWindowIDs: [],
                                          exclusion: ExclusionRules(ownBundleID: "test.clearshot", keepOwnWindowIDs: [],
                                                                    hideDesktopIcons: false))
        let received = received
        stream = ScreenRecordingStream(settings: settings, rules: rules, sampleQueue: DispatchQueue(label: "tests.samples"),
                                       onOutput: { output in
                                           let entry: (String, Double) = switch output {
                                           case let .frame(_, time): ("frame", time.seconds)
                                           case let .systemAudio(chunk): ("audio", chunk.presentationTimeStamp.seconds)
                                           }
                                           received.outputs.withLock { $0.append(entry) }
                                       },
                                       onStop: { reason, time in received.stops.withLock { $0.append((reason, time?.seconds)) } })
    }

    /// A 64 × 36 BGRA screen sample at `seconds` with ScreenCaptureKit's frame status attachment.
    static func screenSample(_ status: SCFrameStatus, at seconds: Double) throws -> CMSampleBuffer {
        var created: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_32BGRA, nil, &created) == kCVReturnSuccess)
        let pixels = try #require(created)
        let format = try CMVideoFormatDescription(imageBuffer: pixels)
        let timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        let sample = try CMSampleBuffer(imageBuffer: pixels, formatDescription: format, sampleTiming: timing)
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true))
        let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        let key = SCStreamFrameInfo.status.rawValue as NSString
        let value = NSNumber(value: status.rawValue)
        withExtendedLifetime((key, value)) {
            CFDictionarySetValue(first, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(value).toOpaque())
        }
        #expect(RegionStream.status(of: sample) == status)
        return sample
    }

    /// 1024 frames of silent stereo float PCM at 48 kHz, stamped `seconds`.
    static func audioSample(at seconds: Double) -> CMSampleBuffer {
        let description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let format = try! CMAudioFormatDescription(audioStreamBasicDescription: description)
        let ready = CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>(
            audioDataBuffer: CMReadOnlyDataBlockBuffer(Data(count: 1024 * 8)), formatDescription: format, sampleCount: 1024,
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000))
        nonisolated(unsafe) var sample: CMSampleBuffer?
        CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(ready).withUnsafeSampleBuffer { sample = $0 }
        return sample!
    }

    /// On a still screen, ScreenCaptureKit keeps handing over idle samples while nothing changes, and a stop it makes
    /// itself reports the latest of those, not the last change, so the recording isn't cut back to it.
    @Test func aStopByScreenCaptureKitReportsTheLatestSampleIdleOnesIncluded() throws {
        stream.receive(try Self.screenSample(.complete, at: 1), of: .screen)
        stream.receive(try Self.screenSample(.idle, at: 4), of: .screen)
        stream.receive(try Self.screenSample(.idle, at: 5), of: .screen)
        stream.ended(.userStopped)

        // Only the change is handed on.
        #expect(received.outputs.withLock { $0.map(\.kind) } == ["frame"])
        let stops = received.stops.withLock { $0 }
        #expect(stops.count == 1)
        #expect(stops.first?.reason == .userStopped)
        #expect(stops.first?.time == 5)
    }

    /// Only samples that show the screen as it is count toward the stop time: a complete, first or idle one. A suspended
    /// stream (or a blank or stopped sample) shows nothing new, and its time would stretch the held frame past the end.
    @Test func samplesThatShowNothingDoNotMoveTheStopTime() throws {
        stream.receive(try Self.screenSample(.complete, at: 1), of: .screen)
        stream.receive(try Self.screenSample(.idle, at: 2), of: .screen)
        stream.receive(try Self.screenSample(.suspended, at: 5), of: .screen)
        stream.receive(try Self.screenSample(.blank, at: 6), of: .screen)
        stream.receive(try Self.screenSample(.stopped, at: 7), of: .screen)
        stream.ended(.systemStopped)

        #expect(received.outputs.withLock { $0.map(\.kind) } == ["frame"])
        #expect(received.stops.withLock { $0.first?.time } == 2)
    }

    @Test func audioCountsTowardTheStopTime() throws {
        stream.receive(try Self.screenSample(.started, at: 1), of: .screen)
        stream.receive(Self.audioSample(at: 2.5), of: .audio)
        stream.receive(try Self.screenSample(.idle, at: 2), of: .screen)
        stream.ended(.systemStopped)

        #expect(received.outputs.withLock { $0.map(\.kind) } == ["frame", "audio"])
        #expect(received.stops.withLock { $0.first?.time } == 2.5)
    }

    @Test func nothingIsHandedOnAfterTheStreamEnds() async throws {
        stream.receive(try Self.screenSample(.complete, at: 1), of: .screen)
        stream.ended(.insufficientStorage)
        stream.receive(try Self.screenSample(.complete, at: 2), of: .screen)
        stream.receive(Self.audioSample(at: 2), of: .audio)
        stream.ended(.userStopped)
        await stream.stop()

        #expect(received.outputs.withLock { $0.count } == 1)
        #expect(received.stops.withLock { $0.map(\.reason) } == [.insufficientStorage])
    }

    @Test func nothingIsHandedOnAfterStop() async throws {
        await stream.stop()
        stream.receive(try Self.screenSample(.complete, at: 1), of: .screen)
        stream.ended(.userStopped)

        #expect(received.outputs.withLock { $0.isEmpty })
        #expect(received.stops.withLock { $0.isEmpty })
    }
}
