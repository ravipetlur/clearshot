import AVFoundation
import CoreMedia
import CSCore
import Foundation
import Synchronization

/// Carries out a `VideoEditPlan`: trims and mutes copy the samples; remixes decode and mix the audio again; re-encodes
/// also decode and encode the video. Writes the plan's container (an MP4, or a QuickTime movie for video copied from a
/// codec MP4 can't carry), with the video track's rotation (a phone stores a portrait video on its side) as the source
/// had it.
public enum RecordingExporter {
    /// Exports `source` to `destination` (replacing any file there; named with the plan's `container.fileExtension`) as
    /// `plan` says. `progress` gets fractions that only grow, the last one 1, from any thread. Errors are
    /// `VideoFileError`s (`.noVideoTrack` for a file without video), or `CancellationError` when the task is cancelled;
    /// the partial destination is removed.
    @concurrent
    public static func export(_ source: URL, to destination: URL, plan: VideoEditPlan,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw VideoFileError.exportFailed("The destination is the source file.")
        }
        let reporter = ProgressReporter(progress)
        try? FileManager.default.removeItem(at: destination)
        do {
            let asset = AVURLAsset(url: source)
            let tracks = try await SourceTracks.load(asset)
            let range = plan.timeRange.map {
                CMTimeRange(start: CMTime(seconds: $0.start, preferredTimescale: 600),
                            end: CMTime(seconds: $0.end, preferredTimescale: 600))
            } ?? CMTimeRange(start: .zero, duration: tracks.duration)
            let fileType = fileType(of: plan.container)
            switch plan.path {
            case .nothing, .passthrough:
                let composition = try composition(of: tracks, over: range, includesAudio: plan.includesAudio)
                try await exportPassthrough(composition, to: destination, as: fileType, progress: reporter)
            case .audioRemix, .reencode:
                try await rewrite(asset, tracks: tracks, over: range, plan: plan, to: destination, as: fileType,
                                  progress: reporter)
            }
            reporter(1)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw mapped(error)
        }
    }

    // MARK: Shared with RecoveryExporter

    /// An `AVAssetExportSession` passthrough of `asset` to a `fileType` file (an MP4 unless said) at `destination`.
    static func exportPassthrough(_ asset: AVAsset, to destination: URL, as fileType: AVFileType = .mp4,
                                  progress: ProgressReporter?) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoFileError.exportFailed("Passthrough export isn't available for this file.")
        }
        let states = session.states(updateInterval: 0.1)
        let watcher = Task {
            for await state in states {
                if case let .exporting(fraction) = state {
                    progress?(fraction.fractionCompleted)
                }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: destination, as: fileType)
    }

    /// The file type AVFoundation writes for `container`.
    static func fileType(of container: VideoContainer) -> AVFileType {
        switch container {
        case .mp4: .mp4
        case .mov: .mov
        }
    }

    /// `VideoFileError`s and cancellation as they are; anything else as `.exportFailed`.
    static func mapped(_ error: any Error) -> any Error {
        switch error {
        case let error as VideoFileError: error
        case let error as CancellationError: error
        default: VideoFileError.exportFailed(error.localizedDescription)
        }
    }

    // MARK: Private

    /// A source's video track with its display rotation, and its audio tracks in file order (system audio, then
    /// microphone, for a recording).
    private struct SourceTracks {
        let duration: CMTime
        let video: AVAssetTrack
        let transform: CGAffineTransform
        let audio: [AVAssetTrack]

        static func load(_ asset: AVURLAsset) async throws -> SourceTracks {
            let duration: CMTime
            let video: AVAssetTrack?
            let audio: [AVAssetTrack]
            do {
                duration = try await asset.load(.duration)
                video = try await asset.loadTracks(withMediaType: .video).first
                audio = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                throw VideoFileError.unreadable(error.localizedDescription)
            }
            guard let video else { throw VideoFileError.noVideoTrack }
            let transform: CGAffineTransform
            do {
                transform = try await video.load(.preferredTransform)
            } catch {
                throw VideoFileError.unreadable(error.localizedDescription)
            }
            return SourceTracks(duration: duration, video: video, transform: transform, audio: audio)
        }
    }

    /// The video track with its rotation, plus the audio tracks when kept, over `range`, starting at zero.
    private static func composition(of tracks: SourceTracks, over range: CMTimeRange,
                                    includesAudio: Bool) throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        for track in [tracks.video] + (includesAudio ? tracks.audio : []) {
            guard let copy = composition.addMutableTrack(withMediaType: track.mediaType,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VideoFileError.exportFailed("Couldn't add a \(track.mediaType.rawValue) track.")
            }
            try copy.insertTimeRange(range, of: track, at: .zero)
            if track === tracks.video { copy.preferredTransform = tracks.transform }
        }
        return composition
    }

    /// A reader and a writer of `fileType` over `range`: the video copied (remix) or decoded and encoded at the plan's
    /// size, codec and bitrate (re-encode); the audio decoded to PCM, mixed at the plan's volumes and encoded to AAC.
    ///
    /// Each track is pumped in its own child task, so a writer holding one track back for the others to catch up never
    /// deadlocks. `Provider.next()` blocks its thread until the reader has a sample, and the reader may wait for
    /// another output to be drained, so each child runs on a dispatch queue of its own: on the shared pool, pumps
    /// blocked this way could take every thread (and starve the app) while the one they wait for never runs. The first
    /// failure cancels the reading, which releases any pump still blocked.
    private static func rewrite(_ asset: AVURLAsset, tracks: SourceTracks, over range: CMTimeRange, plan: VideoEditPlan,
                                to destination: URL, as fileType: AVFileType, progress: ProgressReporter) async throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)

        let videoOutput: AVAssetReaderTrackOutput
        let videoInput: AVAssetWriterInput
        if plan.path == .reencode {
            videoOutput = AVAssetReaderTrackOutput(track: tracks.video, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            let frameRate = try await tracks.video.load(.nominalFrameRate)
            var settings = RecordingWriterSettings.video(codec: plan.codec, width: plan.outputWidth, height: plan.outputHeight,
                                                         bitRate: plan.videoBitRate ?? EncoderPlan.minimumBitRate,
                                                         framesPerSecond: frameRate > 0 ? Double(frameRate)
                                                             : VideoEditPlan.fallbackFramesPerSecond,
                                                         keyFrameInterval: 2)
            settings[AVVideoScalingModeKey] = AVVideoScalingModeResize
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        } else {
            videoOutput = AVAssetReaderTrackOutput(track: tracks.video, outputSettings: nil)
            let formatHint = try await tracks.video.load(.formatDescriptions).first
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
        }
        // The frames are read as stored; the rotation that shows them upright goes on the written track as it was.
        videoInput.transform = tracks.transform
        let audio = try await audioRoutes(tracks.audio, plan: plan)
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput),
              audio.allSatisfy({ reader.canAdd($0.output) && writer.canAdd($0.input) }) else {
            throw VideoFileError.exportFailed("Couldn't set up the reader and the writer.")
        }

        do {
            try await withThrowingTaskGroup { group in
                // Each track's provider and receiver are sent to their own child task, so each pair is kept in a
                // variable of its own (at most two audio tracks: system audio, then the microphone).
                let video: TrackPipe = (reader.outputProvider(for: videoOutput), writer.inputReceiver(for: videoInput))
                var firstAudio: TrackPipe?
                var secondAudio: TrackPipe?
                if audio.count > 0 {
                    firstAudio = (reader.outputProvider(for: audio[0].output), writer.inputReceiver(for: audio[0].input))
                }
                if audio.count > 1 {
                    secondAudio = (reader.outputProvider(for: audio[1].output), writer.inputReceiver(for: audio[1].input))
                }
                try reader.start()
                try writer.start()
                writer.startSession(atSourceTime: range.start)

                group.addTask(executorPreference: pumpQueue("video")) {
                    try await pump(video, over: range, progress: progress)
                }
                if let firstAudio {
                    group.addTask(executorPreference: pumpQueue("audio-1")) {
                        try await pump(firstAudio, over: range, progress: progress)
                    }
                }
                if let secondAudio {
                    group.addTask(executorPreference: pumpQueue("audio-2")) {
                        try await pump(secondAudio, over: range, progress: progress)
                    }
                }
                do {
                    try await group.waitForAll()
                } catch {
                    reader.cancelReading()
                    throw error
                }
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        writer.endSession(atSourceTime: range.end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoFileError.exportFailed(writer.error?.localizedDescription ?? "The writer didn't complete.")
        }
    }

    private typealias AudioRoute = (output: AVAssetReaderAudioMixOutput, input: AVAssetWriterInput)

    private typealias TrackPipe = (provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>,
                                   receiver: AVAssetWriterInput.SampleBufferReceiver)

    /// A serial queue for one track's pump to run on, as its task executor.
    private static func pumpQueue(_ track: String) -> DispatchQueue {
        DispatchQueue(label: CSCore.identifier("export.\(track)"), qos: .userInitiated)
    }

    /// Moves every sample from the pipe's provider to its receiver, waiting while the writer isn't ready, and finishes
    /// the receiver however it ends, so the other tracks are never held back waiting for this one. Stops when the task
    /// is cancelled.
    private static func pump(_ pipe: TrackPipe, over range: CMTimeRange, progress: ProgressReporter) async throws {
        let (provider, receiver) = pipe
        defer { receiver.finish() }
        let length = range.duration.seconds
        while let sample = try await provider.next() {
            try Task.checkCancellation()
            try await receiver.append(sample)
            var end = sample.presentationTimeStamp
            if sample.duration.isNumeric {
                end = end + sample.duration
            }
            if end.isNumeric, length > 0 {
                progress((end - range.start).seconds / length)
            }
        }
    }

    /// One reader output and one writer input per written audio track. Merged (or a single source track): one track
    /// mixing every source track, with the plan's channels. Otherwise one per source track, in order, each with 1
    /// channel for mono, else its own count. Each source track at its plan volume. The plan merges a file with more than
    /// the two separate tracks written here (`VideoEditPlan.mergesTracks`); one planned without knowing of them is merged
    /// all the same.
    private static func audioRoutes(_ tracks: [AVAssetTrack], plan: VideoEditPlan) async throws -> [AudioRoute] {
        guard plan.includesAudio, !tracks.isEmpty else { return [] }
        let indexed = Array(tracks.enumerated())
        if plan.mergesTracks || tracks.count == 1 || tracks.count > 2 {
            return [route(indexed, channels: plan.audioChannels, volumes: plan.trackVolumes)]
        }
        var routes: [AudioRoute] = []
        for entry in indexed {
            let channels = plan.audioChannels == 1 ? 1 : try await VideoThumbnail.channelCount(of: entry.element)
            routes.append(route([entry], channels: channels, volumes: plan.trackVolumes))
        }
        return routes
    }

    private static func route(_ tracks: [(offset: Int, element: AVAssetTrack)], channels: Int, volumes: [Double]) -> AudioRoute {
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks.map(\.element),
                                                 audioSettings: RecordingWriterSettings.pcm(channels: channels))
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { index, track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(Float(index < volumes.count ? volumes[index] : 1), at: .zero)
            return parameters
        }
        output.audioMix = mix
        let bitRate = channels > 1 ? VideoEditPlan.stereoAudioBitRate : VideoEditPlan.monoAudioBitRate
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingWriterSettings.audio(
            AudioTrackSettings(channels: channels, bitRate: Int(bitRate))))
        return (output, input)
    }
}

/// Reports fractions that only grow (in steps of at least 1%, and 1 at the end), one at a time, from any thread.
final class ProgressReporter: Sendable {
    private let report: @Sendable (Double) -> Void
    private let last = Mutex(-1.0)

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func callAsFunction(_ fraction: Double) {
        let fraction = min(max(fraction, 0), 1)
        last.withLock { last in
            guard fraction > last, fraction == 1 || fraction - last >= 0.01 else { return }
            last = fraction
            report(fraction)
        }
    }
}
