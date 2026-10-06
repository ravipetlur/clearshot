import AVFoundation
import CoreMedia
import CoreVideo
import CSCore
import Foundation
import Synchronization

/// What a recording writer has done so far.
public struct RecordingStatistics: Sendable, Equatable {
    /// Video frames the writer took.
    public var appendedFrames = 0
    /// Video frames the writer refused because it wasn't ready (real-time mode). Frames before the start or inside a
    /// pause are held, not appended, and not counted.
    public var droppedFrames = 0
    public var systemAudioChunks = 0
    public var microphoneChunks = 0
    /// Audio chunks the writer refused because it wasn't ready. Chunks before the start or inside a pause aren't
    /// counted.
    public var droppedAudioChunks = 0
    /// Seconds of video written: from the session start to the last frame appended.
    public var writtenDuration = 0.0
}

public struct RecordingWriterResult: Sendable, Equatable {
    public let fileURL: URL
    /// The video track's length in seconds: from the session start to the stop, pauses excluded.
    public let duration: Double
    /// Whether the system audio track got any samples.
    public let hasSystemAudio: Bool
    /// Whether the microphone track got any samples.
    public let hasMicrophone: Bool
    public let statistics: RecordingStatistics

    /// The app makes one for a failed take it finalized itself (`RecoveryExporter.finalize`).
    public init(fileURL: URL, duration: Double, hasSystemAudio: Bool, hasMicrophone: Bool, statistics: RecordingStatistics) {
        self.fileURL = fileURL
        self.duration = duration
        self.hasSystemAudio = hasSystemAudio
        self.hasMicrophone = hasMicrophone
        self.statistics = statistics
    }
}

/// Writes a recording to a fragmented MP4 through the macOS 27 writer receivers.
///
/// Everything happens on `queue`: the writer and its receivers, the pause timeline, the held frame and the counts live
/// there. The stream delivers its samples there; the microphone's handler hops onto it; the commands (`start`, `pause`,
/// `resume`, `restart`, `endMicrophoneTrack`, `finish`, `cancel`) may be called from any thread and run there in order.
/// `statistics` is a snapshot under a lock. In real-time mode nothing blocks the queue (it is ScreenCaptureKit's
/// sample queue): a sample the writer isn't ready for is dropped and counted.
///
/// The latest video frame is always held (and the one before released, so at most one stream buffer is kept besides the
/// one being appended): before `start` it is the only thing kept; `start` begins the session with it; `resume` shows it
/// from the resume, so a change made while paused appears there; `finish` appends it again at the stop, so a still
/// ending lasts until the stop (`endSession` alone doesn't stretch the last frame).
public final class RecordingWriter: @unchecked Sendable {
    /// Every sample and command runs here.
    public let queue = DispatchQueue(label: CSCore.identifier("recording-writer"), qos: .userInitiated)

    private enum Phase {
        /// Before `start`: frames are held, nothing is written.
        case holding
        case recording
        case finishing
        case finished
        case failed
        case cancelled
    }

    /// The writer and the receivers it attached its inputs through.
    private struct Output {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput.PixelBufferReceiver
        let systemAudio: AVAssetWriterInput.SampleBufferReceiver?
        let microphone: AVAssetWriterInput.SampleBufferReceiver?
    }

    /// How long waitWhenBusy waits for the writer to take a sample before dropping it.
    private static let waitWhenBusyLimit = Duration.seconds(2)
    /// How long the stop's frame may wait in real-time mode; the stream has stopped by then.
    private static let finalFrameWaitLimit = Duration.seconds(1)

    private let configuration: RecordingWriterConfiguration
    private let counts = Mutex(RecordingStatistics())
    private let failureHandler = Mutex<(@Sendable (any Error) -> Void)?>(nil)

    // Confined to `queue` (and to `init`, before the writer is shared).
    private var output: Output?
    private var phase = Phase.holding
    private var timeline = PauseTimeline()
    private var heldFrame: CVReadOnlyPixelBuffer?
    /// Where the writer's session starts, in the stream's clock; nil until the first frame is appended.
    private var sessionStart: CMTime?
    private var microphoneEnded = false
    /// The microphone's receiver was finished: once the session has started, never before (an input finished before
    /// the session starts fails the whole writer, −12142, measured).
    private var microphoneFinished = false
    private var failure: (any Error)?
    /// Counts the takes: a restart or a cancel starts a new one, so a failure report queued in an earlier take is dropped
    /// rather than reaching the take that replaced it.
    private var take = 0

    /// Creates the file and starts the writer. Throws `VideoFileError.cannotConfigureWriter`.
    public init(configuration: RecordingWriterConfiguration) throws {
        self.configuration = configuration
        output = try Self.makeOutput(configuration)
    }

    /// A snapshot of the counts, readable from any thread.
    public var statistics: RecordingStatistics {
        counts.withLock { $0 }
    }

    /// Called once, on `queue`, when a receiver throws or the writer fails while recording; later samples are ignored
    /// and the file is left as written, for recovery. It runs after the call that hit the failure has returned, so
    /// never inside the stream's sample handler (which holds the stream's lock). Set it before `start`; a restart arms
    /// it again. A failure whose report is still queued when a restart or a cancel runs is never reported: it belongs
    /// to the take they replaced.
    public var onFailure: (@Sendable (any Error) -> Void)? {
        get { failureHandler.withLock { $0 } }
        set { failureHandler.withLock { $0 = newValue } }
    }

    // MARK: Samples (on `queue`)

    /// A video frame at `time` in the stream's clock. It becomes the held frame; while recording and not paused it is
    /// also appended where the pause timeline places it.
    public func appendVideo(_ frame: CVReadOnlyPixelBuffer, at time: CMTime) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch phase {
        case .holding:
            heldFrame = frame
        case .recording:
            heldFrame = frame
            appendPlaced(frame, at: time, waitLimit: appendWaitLimit)
        case .finishing, .finished, .failed, .cancelled:
            break
        }
    }

    /// A system audio chunk in the stream's clock.
    public func appendSystemAudio(_ sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) {
        dispatchPrecondition(condition: .onQueue(queue))
        appendAudio(sample, to: .systemAudio)
    }

    /// A microphone chunk, already converted to the stream's clock. The microphone delivers on its own queue, so its
    /// handler hops onto `queue` first. Ignored after `endMicrophoneTrack`.
    public func appendMicrophone(_ sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !microphoneEnded else { return }
        appendAudio(sample, to: .microphone)
    }

    // MARK: Commands (any thread)

    /// Begins the recording at `time`. With a held frame the session starts at `time` showing it; otherwise it starts
    /// at the first frame's time. Audio before the session start is dropped.
    public func start(at time: CMTime) {
        queue.async { [self] in
            begin(at: time)
        }
    }

    public func pause(at time: CMTime) {
        queue.async { [self] in
            guard phase == .recording else { return }
            timeline.pause(at: time)
        }
    }

    /// Resumes, showing the held frame from the resume.
    public func resume(at time: CMTime) {
        queue.async { [self] in
            guard phase == .recording, timeline.isPaused else { return }
            timeline.resume(at: time)
            if let heldFrame {
                appendPlaced(heldFrame, at: time, waitLimit: appendWaitLimit)
            }
        }
    }

    /// Throws the take away and starts again at `time` with the held frame: the writer is cancelled (its file deleted),
    /// a new one made at the same URL with the same settings, the timeline and the counts reset. A microphone track
    /// ended before stays ended: the new take has no microphone track. Throws `VideoFileError.cannotConfigureWriter`.
    /// Does nothing once the recording is finishing, finished or cancelled.
    public func restart(at time: CMTime) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            restart(at: time) { continuation.resume(with: $0) }
        }
    }

    /// `restart(at:)`, queued before this returns; `completion` runs on `queue`. Tests queue it between other work.
    func restart(at time: CMTime, completion: @escaping @Sendable (Result<Void, any Error>) -> Void) {
        queue.async { [self] in
            completion(Result { try restartNow(at: time) })
        }
    }

    /// Finishes the microphone track; later microphone samples are ignored. Before the session starts (the countdown)
    /// the track is finished as the session starts. A track that got no sample leaves nothing in the file.
    public func endMicrophoneTrack() {
        queue.async { [self] in
            guard !microphoneEnded else { return }
            microphoneEnded = true
            if phase == .recording, sessionStart != nil {
                finishMicrophone()
            }
        }
    }

    /// Ends the recording at `time` (a stop while paused ends where the pause began) and finishes the file, which
    /// defragments it. Throws the writer's error when it failed (the file is left for recovery),
    /// `VideoFileError.noVideoTrack` when no frame was ever written (the file is deleted), and `CancellationError`
    /// after `cancel` or a second `finish`.
    ///
    /// Stop the stream first. In real-time mode the stop's frame may wait on `queue` up to 1 s for the writer, which
    /// would hold up the samples of a stream still delivering there; and a sample arriving after `finish` is ignored.
    public func finish(at time: CMTime) async throws -> RecordingWriterResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                finishNow(at: time) { continuation.resume(with: $0) }
            }
        }
    }

    /// Stops writing and deletes the file. Does nothing after a successful `finish`: the file is the caller's then.
    public func cancel() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cancel { continuation.resume() }
        }
    }

    /// `cancel()`, queued before this returns; `completion` runs on `queue`. Tests queue it between other work.
    func cancel(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if phase != .finished {
                take += 1
                phase = .cancelled
                heldFrame = nil
                discardOutput()
            }
            completion()
        }
    }

    // MARK: Private (on `queue`)

    /// How long a sample may wait for the writer in this append mode; nil: not at all.
    private var appendWaitLimit: Duration? {
        configuration.appendMode == .waitWhenBusy ? Self.waitWhenBusyLimit : nil
    }

    private func begin(at time: CMTime) {
        guard phase == .holding else { return }
        phase = .recording
        timeline.begin(at: time)
        if let heldFrame {
            appendPlaced(heldFrame, at: time, waitLimit: appendWaitLimit)
        }
    }

    /// Appends `frame` where the timeline places `time`, starting the session with it when none has started. Nothing
    /// happens before the start or inside a pause.
    private func appendPlaced(_ frame: CVReadOnlyPixelBuffer, at time: CMTime, waitLimit: Duration?) {
        guard let output, let placed = timeline.place(.video, at: time, duration: .zero) else { return }
        if sessionStart == nil {
            output.writer.startSession(atSourceTime: placed)
            sessionStart = placed
            // Ended during the countdown: finished now that it safely can be.
            if microphoneEnded { finishMicrophone() }
        }
        guard let appended = append(waitLimit: waitLimit, { try output.video.appendImmediately(frame, with: placed) }) else {
            return
        }
        let written = sessionStart.map { (placed - $0).seconds } ?? 0
        counts.withLock { counts in
            if appended {
                counts.appendedFrames += 1
                counts.writtenDuration = max(counts.writtenDuration, written)
            } else {
                counts.droppedFrames += 1
            }
        }
    }

    /// Appends a chunk where the timeline places it, cut at a pause that starts inside it.
    private func appendAudio(_ sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>, to track: RecordingTrack) {
        guard phase == .recording, let output, let sessionStart,
              let receiver = track == .microphone ? output.microphone : output.systemAudio else { return }
        let time = sample.presentationTimeStamp
        let kept = timeline.keptDuration(at: time, duration: sample.duration)
        guard let placed = timeline.place(track, at: time, duration: kept), placed >= sessionStart else { return }
        let adjusted: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?
        do {
            adjusted = try Self.adjusted(sample, keeping: kept, movingBy: placed - time)
        } catch {
            counts.withLock { $0.droppedAudioChunks += 1 }
            return
        }
        // Less than half a sample came before the pause.
        guard let adjusted else { return }
        guard let appended = append(waitLimit: appendWaitLimit, { try receiver.appendImmediately(adjusted) }) else { return }
        counts.withLock { counts in
            switch (appended, track) {
            case (false, _): counts.droppedAudioChunks += 1
            case (true, .microphone): counts.microphoneChunks += 1
            case (true, _): counts.systemAudioChunks += 1
            }
        }
    }

    /// Appends with `attempt`; while the writer isn't ready, tries again every millisecond for at most `waitLimit`
    /// (none: drops at once). True when appended, false when dropped, nil when the writer failed (reported).
    private func append(waitLimit: Duration?, _ attempt: () throws -> Bool) -> Bool? {
        do {
            let deadline = waitLimit.map { ContinuousClock.now + $0 }
            while true {
                if try attempt() { return true }
                if output?.writer.status == .failed {
                    fail(output?.writer.error ?? VideoFileError.exportFailed("The writer failed."))
                    return nil
                }
                guard let deadline, ContinuousClock.now < deadline else { return false }
                Thread.sleep(forTimeInterval: 0.001)
            }
        } catch {
            fail(error)
            return nil
        }
    }

    /// The chunk cut to its first `kept` (whole frames, PCM only) and moved by `offset`; the chunk itself when neither
    /// applies, nil when less than half a frame is kept.
    private static func adjusted(_ sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>, keeping kept: CMTime,
                                 movingBy offset: CMTime) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent>? {
        let count = sample.sampleCount
        let isPCM = sample.formatDescription?.audioStreamBasicDescription?.mFormatID == kAudioFormatLinearPCM
        let keptCount = kept < sample.duration && count > 1 && isPCM
            ? Int((Double(count) * kept.seconds / sample.duration.seconds).rounded())
            : count
        guard keptCount > 0 else { return nil }
        var adjusted = sample
        if keptCount < count {
            adjusted = try pcmPrefix(of: adjusted, frames: keptCount)
        }
        if offset != .zero {
            adjusted = try adjusted.withUnsafeSampleBuffer { buffer in
                // A new buffer nothing else refers to, so handing it to the ready wrapper can't race.
                nonisolated(unsafe) let moved = try buffer.moved(by: offset)
                return CMReadySampleBuffer(unsafeBuffer: moved)
            }
        }
        return adjusted
    }

    /// The first `frames` of a PCM chunk, copied out of each of its buffers: one for interleaved audio, one per channel
    /// for non-interleaved, as ScreenCaptureKit delivers system audio. (`CMSampleBuffer(copying:forRange:)` can't
    /// subdivide non-interleaved audio: −12735, measured.)
    static func pcmPrefix(of sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>,
                          frames: Int) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        let count = sample.sampleCount
        guard let format = sample.formatDescription, count > 0, (1...count).contains(frames) else {
            throw VideoFileError.exportFailed("Can't cut an audio chunk of \(count) frames to \(frames).")
        }
        let data = try sample.withUnsafeSampleBuffer { buffer in
            try buffer.withAudioBufferList { buffers, _ in
                var data = Data()
                for channel in buffers {
                    let bytes = Int(channel.mDataByteSize) / count * frames
                    guard let base = channel.mData, bytes > 0 else {
                        throw VideoFileError.exportFailed("An audio chunk has an empty buffer.")
                    }
                    data.append(base.assumingMemoryBound(to: UInt8.self), count: bytes)
                }
                return data
            }
        }
        let prefix = CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>(audioDataBuffer: CMReadOnlyDataBlockBuffer(data),
                                                                    formatDescription: format, sampleCount: frames,
                                                                    presentationTimeStamp: sample.presentationTimeStamp)
        return CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(prefix)
    }

    private func fail(_ error: any Error) {
        guard phase != .failed else { return }
        let wasRecording = phase == .holding || phase == .recording
        phase = .failed
        failure = error
        heldFrame = nil
        if wasRecording, let handler = onFailure {
            // After the call that hit the failure returns: that call can run inside the stream's sample handler. A restart
            // or cancel queued meanwhile has moved on to another take, which this failure isn't about.
            let failedTake = take
            queue.async { [self] in
                guard take == failedTake else { return }
                handler(error)
            }
        }
    }

    /// Finishes the microphone's receiver, once.
    private func finishMicrophone() {
        guard !microphoneFinished, let microphone = output?.microphone else { return }
        microphoneFinished = true
        microphone.finish()
    }

    private func restartNow(at time: CMTime) throws {
        switch phase {
        case .holding, .recording, .failed: break
        case .finishing, .finished, .cancelled: return
        }
        take += 1
        discardOutput()
        timeline = PauseTimeline()
        sessionStart = nil
        microphoneFinished = false
        failure = nil
        counts.withLock { $0 = RecordingStatistics() }
        var settings = configuration
        if microphoneEnded {
            settings.microphone = nil
        }
        do {
            output = try Self.makeOutput(settings)
        } catch {
            phase = .failed
            failure = error
            throw error
        }
        phase = .holding
        begin(at: time)
    }

    private func finishNow(at time: CMTime, completion: @escaping @Sendable (Result<RecordingWriterResult, any Error>) -> Void) {
        switch phase {
        case .holding, .recording: break
        case .failed:
            completion(.failure(failure ?? VideoFileError.exportFailed("The writer failed.")))
            return
        case .finishing, .finished, .cancelled:
            completion(.failure(CancellationError()))
            return
        }
        guard let output, let sessionStart else {
            phase = .cancelled
            heldFrame = nil
            discardOutput()
            completion(.failure(VideoFileError.noVideoTrack))
            return
        }
        phase = .finishing
        if timeline.isPaused {
            timeline.resume(at: time)
        }
        let end = max(timeline.outputTime(at: time), sessionStart)
        if let heldFrame {
            appendPlaced(heldFrame, at: time, waitLimit: appendWaitLimit ?? Self.finalFrameWaitLimit)
        }
        heldFrame = nil
        if phase == .failed {
            completion(.failure(failure ?? VideoFileError.exportFailed("The writer failed.")))
            return
        }
        output.writer.endSession(atSourceTime: end)
        output.video.finish()
        output.systemAudio?.finish()
        finishMicrophone()
        let duration = (end - sessionStart).seconds
        output.writer.finishWriting { [self] in
            queue.async { [self] in
                completeFinish(duration: duration, completion: completion)
            }
        }
    }

    private func completeFinish(duration: Double, completion: @Sendable (Result<RecordingWriterResult, any Error>) -> Void) {
        // `cancel` ran while the file was finishing.
        guard phase == .finishing, let output else {
            completion(.failure(CancellationError()))
            return
        }
        guard output.writer.status == .completed else {
            let error = output.writer.error ?? VideoFileError.exportFailed("The writer didn't complete.")
            phase = .failed
            failure = error
            completion(.failure(error))
            return
        }
        phase = .finished
        self.output = nil
        let statistics = self.statistics
        completion(.success(RecordingWriterResult(fileURL: configuration.fileURL, duration: duration,
                                                  hasSystemAudio: statistics.systemAudioChunks > 0,
                                                  hasMicrophone: statistics.microphoneChunks > 0, statistics: statistics)))
    }

    /// Cancels the writer, which deletes its file, and deletes the file in any case (a failed writer's cancel does
    /// nothing).
    private func discardOutput() {
        output?.writer.cancelWriting()
        output = nil
        try? FileManager.default.removeItem(at: configuration.fileURL)
    }

    private static func makeOutput(_ configuration: RecordingWriterConfiguration) throws -> Output {
        do {
            let writer = try AVAssetWriter(outputURL: configuration.fileURL, fileType: .mp4)
            writer.movieFragmentInterval = CMTime(seconds: configuration.fragmentInterval, preferredTimescale: 600)
            func input(_ mediaType: AVMediaType, _ settings: [String: Any]) throws -> AVAssetWriterInput {
                let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: settings)
                guard writer.canAdd(input) else { throw VideoFileError.cannotConfigureWriter }
                // In both append modes (`RealTimeMediaInput`). Measured without it: no frames after ~35 gapped ones,
                // no audio after ~3.5 s of a still screen, no video after ~1 s without audio.
                let realTime: any RealTimeMediaInput = input
                realTime.expectsMediaDataInRealTime = true
                return input
            }
            let video = writer.inputPixelBufferReceiver(for: try input(.video, RecordingWriterSettings.video(configuration.plan)),
                                                        pixelBufferAttributes: nil)
            let systemAudio = try configuration.systemAudio.map {
                writer.inputReceiver(for: try input(.audio, RecordingWriterSettings.audio($0)))
            }
            let microphone = try configuration.microphone.map {
                writer.inputReceiver(for: try input(.audio, RecordingWriterSettings.audio($0)))
            }
            try writer.start()
            return Output(writer: writer, video: video, systemAudio: systemAudio, microphone: microphone)
        } catch {
            throw VideoFileError.cannotConfigureWriter
        }
    }
}

extension CMSampleBuffer {
    /// A copy with every timing entry moved by `offset`, decode times included (`CMSampleBuffer(copying:withNewTiming:)`).
    func moved(by offset: CMTime) throws -> CMSampleBuffer {
        let timings = try sampleTimingInfos().map { timing in
            var timing = timing
            timing.presentationTimeStamp = timing.presentationTimeStamp + offset
            if timing.decodeTimeStamp.isValid {
                timing.decodeTimeStamp = timing.decodeTimeStamp + offset
            }
            return timing
        }
        return try CMSampleBuffer(copying: self, withNewTiming: timings)
    }
}
