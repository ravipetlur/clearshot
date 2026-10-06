import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import CSRecording

/// The suites that encode and decode media (the writer's, recovery's, the exporter's and the thumbnail's) run one test
/// at a time. In parallel they keep some thirty hardware encoder sessions and as many blocked threads busy at once, and
/// VideoToolbox stalls under that: writers wait seconds for the encoder, and sessions fail with -17691
/// (`kVTSessionMalfunctionErr`).
@Suite(.serialized) enum MediaTests {}

/// Synthetic media for the writer, recovery, exporter and thumbnail tests: frames whose colour encodes their index,
/// sine tones, source files built with `RecordingWriter`, and readers of what a file holds. Nothing here records the
/// screen, the microphone or system audio.
///
/// Times are host-like, from `origin` (1000 s), as the stream delivers them.
enum SyntheticMedia {
    static let framesPerSecond = 30
    static let sampleRate = 48_000
    /// Samples per audio chunk (21.3 ms).
    static let chunk = 1024
    static let origin = 1000.0
    /// Each tone's peak; its RMS is 0.177 per sounding channel.
    static let amplitude = 0.25

    // MARK: Frames

    /// A solid BGRA frame whose colour encodes `index` (0..<512): each channel takes one of eight levels 32 apart,
    /// 16…240, so the index survives encoding and decoding.
    static func frame(_ index: Int, width: Int = 320, height: Int = 180) -> CVReadOnlyPixelBuffer {
        var attributes = CVPixelBufferCreationAttributes(pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                                                         size: CVImageSize(width: width, height: height))
        attributes.backing = .ioSurface
        var buffer = try! CVMutablePixelBuffer(attributes)
        // BGRA in memory is one little-endian UInt32: alpha, red, green, blue from the high byte down.
        let (red, green, blue) = (UInt32(level(index % 8)), UInt32(level(index / 8 % 8)), UInt32(level(index / 64 % 8)))
        let pixel = 0xFF00_0000 | red << 16 | green << 8 | blue
        buffer.accessUnsafeMutableRawPlaneBytes { planes in
            let bytes = planes[0].bytes
            bytes.baseAddress?.initializeMemory(as: UInt32.self, repeating: pixel, count: bytes.count / 4)
        }
        return CVReadOnlyPixelBuffer(buffer)
    }

    /// The index a decoded colour encodes.
    static func index(red: UInt8, green: UInt8, blue: UInt8) -> Int {
        digit(red) + 8 * digit(green) + 64 * digit(blue)
    }

    private static func level(_ digit: Int) -> UInt8 { UInt8(16 + 32 * digit) }

    private static func digit(_ level: UInt8) -> Int { min(7, max(0, Int(((Double(level) - 16) / 32).rounded()))) }

    /// The frame index of the frame delivered at host time `seconds`.
    static func frameIndex(at seconds: Double) -> Int {
        Int(((seconds - origin) * Double(framesPerSecond)).rounded())
    }

    // MARK: Tones

    enum Tone {
        /// Stereo: 440 Hz left, 660 Hz right.
        case system
        /// Mono 220 Hz.
        case microphone
        /// Stereo: 440 Hz left, the right silent (a voice on input 1 of an interface).
        case leftOnly

        var channels: Int { self == .microphone ? 1 : 2 }

        func value(channel: Int, sample: Int) -> Float {
            let frequency: Double
            switch (self, channel) {
            case (.system, 0), (.leftOnly, 0): frequency = 440
            case (.system, _): frequency = 660
            case (.microphone, _): frequency = 220
            case (.leftOnly, _): return 0
            }
            return Float(amplitude * sin(2 * .pi * frequency * Double(sample) / Double(sampleRate)))
        }
    }

    /// How a chunk's channels are laid out.
    enum AudioLayout: Sendable, CustomTestStringConvertible {
        /// One buffer, the channels' samples alternating (the microphone's, and these tests' default).
        case interleaved
        /// One buffer per channel, as ScreenCaptureKit delivers system audio.
        case nonInterleaved

        var testDescription: String { self == .interleaved ? "interleaved" : "non-interleaved" }
    }

    /// `count` samples of `tone` from sample `firstSample`, as 32-bit float PCM stamped `time`.
    static func tone(_ tone: Tone, firstSample: Int, at time: CMTime, count: Int = chunk,
                     layout: AudioLayout = .interleaved) -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        let channels = tone.channels
        var samples = [Float](repeating: 0, count: count * channels)
        for frame in 0..<count {
            for channel in 0..<channels {
                let index = layout == .interleaved ? frame * channels + channel : channel * count + frame
                samples[index] = tone.value(channel: channel, sample: firstSample + frame)
            }
        }
        let interleaved = layout == .interleaved
        let bytesPerFrame = UInt32(interleaved ? 4 * channels : 4)
        let layoutFlag = interleaved ? 0 : kAudioFormatFlagIsNonInterleaved
        let description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | layoutFlag,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        let format = try! CMAudioFormatDescription(audioStreamBasicDescription: description)
        let data = samples.withUnsafeBytes { Data($0) }
        let typed = CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>(audioDataBuffer: CMReadOnlyDataBlockBuffer(data),
                                                                   formatDescription: format, sampleCount: count,
                                                                   presentationTimeStamp: time)
        return CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(typed)
    }

    /// The host time of audio sample `sample` counted from the origin, exactly.
    static func audioTime(_ sample: Int) -> CMTime {
        CMTime(value: CMTimeValue(origin) * CMTimeValue(sampleRate) + CMTimeValue(sample), timescale: CMTimeScale(sampleRate))
    }

    // MARK: Feeding a writer

    /// Delivers frames (`frameIndex` picks each one's colour, by default its frame number) and tone chunks whose times
    /// fall in `start..<end`, on the 30 fps and 1024-sample grids from the origin, interleaved in timestamp order (a
    /// frame first at equal times), on the writer's queue, as the stream would. `audioOffset` moves chunk n's stamp by
    /// that many seconds; `pacing` sleeps that many seconds after each sample, for real-time mode. `systemAudioLayout`
    /// lays out the system audio's channels.
    static func feed(_ writer: RecordingWriter, from start: Double, to end: Double, video: Bool = true,
                     systemAudio: Tone? = nil, systemAudioLayout: AudioLayout = .interleaved, microphone: Bool = false,
                     width: Int = 320, height: Int = 180, frameIndex: (Double) -> Int = SyntheticMedia.frameIndex(at:),
                     audioOffset: (Int) -> Double = { _ in 0 }, pacing: Double? = nil) {
        enum Event {
            case frame(Double)
            case audio(Int)
        }
        var events: [(time: Double, order: Int, event: Event)] = []
        if video {
            // The first grid time at or after `start`, allowing for floating-point noise (0.1 × 30 is 3.0000000000000004).
            var index = Int(((start - origin) * Double(framesPerSecond) - 1e-6).rounded(.up))
            while origin + Double(index) / Double(framesPerSecond) < end - 1e-9 {
                let time = origin + Double(index) / Double(framesPerSecond)
                events.append((time, 0, .frame(time)))
                index += 1
            }
        }
        if systemAudio != nil || microphone {
            var sample = Int(((start - origin) * Double(sampleRate) / Double(chunk) - 1e-6).rounded(.up)) * chunk
            while origin + Double(sample) / Double(sampleRate) < end - 1e-9 {
                events.append((origin + Double(sample) / Double(sampleRate), 1, .audio(sample)))
                sample += chunk
            }
        }
        events.sort { ($0.time, $0.order) < ($1.time, $1.order) }
        writer.queue.sync {
            for (_, _, event) in events {
                switch event {
                case let .frame(time):
                    writer.appendVideo(frame(frameIndex(time), width: width, height: height), at: t(time))
                case let .audio(sample):
                    let time = audioTime(sample) + CMTime(seconds: audioOffset(sample / chunk), preferredTimescale: 1_000_000_000)
                    if let systemAudio {
                        writer.appendSystemAudio(tone(systemAudio, firstSample: sample, at: time, layout: systemAudioLayout))
                    }
                    if microphone {
                        writer.appendMicrophone(tone(.microphone, firstSample: sample, at: time))
                    }
                }
                if let pacing {
                    Thread.sleep(forTimeInterval: pacing)
                }
            }
        }
    }

    /// A writer for a 320 × 180 (or `width` × `height`) H.264 recording at 30 fps into `url`, waiting while busy.
    static func writer(_ url: URL, width: Int = 320, height: Int = 180, systemAudio: Bool = false, microphone: Bool = false,
                       appendMode: RecordingWriterConfiguration.AppendMode = .waitWhenBusy,
                       plan: EncoderPlan? = nil) throws -> RecordingWriter {
        let plan = plan ?? EncoderPlan.make(regionPoints: CGSize(width: width, height: height), scale: 1, scaleRetinaTo1x: true,
                                            maxResolution: .original, framesPerSecond: framesPerSecond, hardwareEncoding: true)
        var configuration = RecordingWriterConfiguration(
            fileURL: url, plan: plan, systemAudio: systemAudio ? AudioTrackSettings(channels: 2, bitRate: 192_000) : nil,
            microphone: microphone ? AudioTrackSettings(channels: 1, bitRate: 128_000) : nil)
        configuration.appendMode = appendMode
        return try RecordingWriter(configuration: configuration)
    }

    // MARK: Source files

    /// A finished recording `seconds` long: frames encoding their index, a stereo "system" track with `systemTone`
    /// (none: no track) and, with `microphone`, a mono "mic" track.
    static func makeSource(at url: URL, seconds: Double, width: Int = 640, height: Int = 360, systemTone: Tone? = .system,
                           microphone: Bool = true) async throws {
        let writer = try writer(url, width: width, height: height, systemAudio: systemTone != nil, microphone: microphone)
        writer.start(at: t(origin))
        feed(writer, from: origin, to: origin + seconds, systemAudio: systemTone, microphone: microphone, width: width,
             height: height)
        _ = try await writer.finish(at: t(origin + seconds))
    }

    /// An MP4 with one stereo AAC track and no video.
    static func makeAudioOnlySource(at url: URL, seconds: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        let receiver = writer.inputReceiver(for: input)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        var sample = 0
        while Double(sample) < seconds * Double(sampleRate) {
            try await receiver.append(tone(.system, firstSample: sample, at: CMTime(value: CMTimeValue(sample),
                                                                                     timescale: CMTimeScale(sampleRate))))
            sample += chunk
        }
        receiver.finish()
        await writer.finishWriting()
    }

    // MARK: Reading files

    struct DecodedFrame: Equatable {
        /// Seconds in the file.
        let time: Double
        let index: Int
    }

    /// Every frame the file shows, decoded, with the index its colour encodes.
    static func decodedFrames(_ url: URL) async throws -> [DecodedFrame] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]))
        try reader.start()
        return try await onReaderQueue {
            var frames: [DecodedFrame] = []
            while let sample = try await provider.next() {
                guard case let .pixelBuffer(pixels) = sample.content else { continue }
                let (red, green, blue) = pixels.accessUnsafeRawPlaneBytes { planes in
                    let plane = planes[0]
                    let (size, bytesPerRow) = (plane.properties.size, plane.properties.bytesPerRow)
                    let offset = size.height / 2 * bytesPerRow + size.width / 2 * 4
                    return (plane.bytes[offset + 2], plane.bytes[offset + 1], plane.bytes[offset])
                }
                frames.append(DecodedFrame(time: sample.presentationTimeStamp.seconds,
                                           index: index(red: red, green: green, blue: blue)))
            }
            return frames
        }
    }

    /// Runs `read` with a dispatch queue of its own as the task executor: `Provider.next()` blocks its thread until
    /// the reader has a sample, and many tests reading at once on the shared pool would take every thread.
    private static func onReaderQueue<T>(_ read: () async throws -> T) async throws -> T {
        try await withTaskExecutorPreference(DispatchQueue(label: "test.clearshot.reader")) {
            try await read()
        }
    }

    /// Each track's time range, video first, then audio in file order.
    static func trackRanges(_ url: URL, _ mediaType: AVMediaType) async throws -> [CMTimeRange] {
        var ranges: [CMTimeRange] = []
        for track in try await AVURLAsset(url: url).loadTracks(withMediaType: mediaType) {
            ranges.append(try await track.load(.timeRange))
        }
        return ranges
    }

    /// Each audio track's channel count, in file order.
    static func audioChannelCounts(_ url: URL) async throws -> [Int] {
        var counts: [Int] = []
        for track in try await AVURLAsset(url: url).loadTracks(withMediaType: .audio) {
            let format = try await track.load(.formatDescriptions)[0]
            counts.append(Int(format.audioStreamBasicDescription?.mChannelsPerFrame ?? 0))
        }
        return counts
    }

    /// The video track's format description.
    static func videoFormat(_ url: URL) async throws -> CMFormatDescription {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0]
        return try await track.load(.formatDescriptions)[0]
    }

    /// The RMS of audio track `index`, decoded to float PCM, over every sample of every channel.
    static func rms(_ url: URL, audioTrack index: Int) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio)[index]
        let reader = try AVAssetReader(asset: asset)
        let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]))
        try reader.start()
        return try await onReaderQueue {
            var (sum, count) = (0.0, 0)
            while let sample = try await provider.next() {
                guard case let .dataBuffer(block) = sample.content else { continue }
                Data(block).withUnsafeBytes { bytes in
                    for value in bytes.bindMemory(to: Float.self) {
                        sum += Double(value * value)
                    }
                    count += bytes.count / 4
                }
            }
            return (sum / Double(max(count, 1))).squareRoot()
        }
    }

    /// The file's top-level box types, in order.
    static func topLevelBoxes(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        func integer(at offset: Int, bytes: Int) -> Int {
            data[offset..<(offset + bytes)].reduce(0) { $0 << 8 | Int($1) }
        }
        var (boxes, offset) = ([String](), 0)
        while offset + 8 <= data.count {
            var size = integer(at: offset, bytes: 4)
            boxes.append(String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self))
            if size == 1, offset + 16 <= data.count {
                size = integer(at: offset + 8, bytes: 8)
            } else if size == 0 {
                size = data.count - offset
            }
            guard size >= 8 else { break }
            offset += size
        }
        return boxes
    }

    /// Waits until the file stops growing (its size polled every 50 ms, for at most 2 s), then copies it to `copy`:
    /// what a kill would leave of a writer still open.
    static func copyWhenSettled(_ url: URL, to copy: URL) async throws {
        var size = -1
        for _ in 0..<40 {
            let current = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
            if current == size, current > 0 { break }
            size = current
            try await Task.sleep(for: .milliseconds(50))
        }
        try FileManager.default.copyItem(at: url, to: copy)
    }
}
