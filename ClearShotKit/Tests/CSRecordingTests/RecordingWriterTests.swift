import AVFoundation
import CoreMedia
import CSTestSupport
import Foundation
import Synchronization
import Testing
@testable import CSRecording

extension MediaTests {
    /// The recording writer, fed synthetic 320 × 180 frames at 30 fps and sine tones with host-like times from 1000 s, in a
    /// temporary folder.
    @Suite(.enabled(if: HardwareEncoders.available, "needs a hardware video encoder"))
    final class RecordingWriterTests {
        typealias Media = SyntheticMedia

        let folder = FileManager.default.temporaryDirectory.appending(path: "recording-writer-\(UUID().uuidString)",
                                                                      directoryHint: .isDirectory)
        var movie: URL { folder.appending(path: RecordingFolder.movieFileName) }
        let origin = SyntheticMedia.origin
        let frame = 1.0 / Double(SyntheticMedia.framesPerSecond)

        init() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }

        // MARK: Time

        @Test func aStillEndingLastsUntilTheStop() async throws {
            let writer = try Media.writer(movie)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 4)
            let result = try await writer.finish(at: t(origin + 5))

            let video = try #require(try await Media.trackRanges(movie, .video).first)
            #expect(abs(video.start.seconds) < 0.001)
            #expect(abs(video.end.seconds - 5) <= 0.001)
            #expect(abs(result.duration - 5) <= 0.001)
            // The last frame stays on screen through the still second.
            let frames = try await Media.decodedFrames(movie)
            #expect(frames.last?.index == 119)
        }

        @Test func pauseLeavesNoGapAndShiftsLaterFrames() async throws {
            let writer = try Media.writer(movie, systemAudio: true)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 2, systemAudio: .system)
            writer.pause(at: t(origin + 2))
            // Frames 60–104 and their audio arrive while paused.
            Media.feed(writer, from: origin + 2, to: origin + 3.5, systemAudio: .system)
            writer.resume(at: t(origin + 3.5))
            Media.feed(writer, from: origin + 3.5, to: origin + 5.5, systemAudio: .system)
            let result = try await writer.finish(at: t(origin + 5.5))

            #expect(abs(result.duration - 4) <= 0.001)
            let video = try #require(try await Media.trackRanges(movie, .video).first)
            #expect(abs(video.end.seconds - 4) <= 0.001)
            let audio = try #require(try await Media.trackRanges(movie, .audio).first)
            #expect(abs(audio.end.seconds - 4) <= 0.03)

            let frames = try await Media.decodedFrames(movie)
            let largestGap = zip(frames, frames.dropFirst()).map { $1.time - $0.time }.max() ?? 0
            #expect(largestGap <= frame + 0.001)
            // Nothing delivered while paused shows, except the last frame, held and shown from the resume…
            let shown = Set(frames.map(\.index))
            #expect(shown.isDisjoint(with: 60..<104))
            #expect(shown.contains(104))
            // …and every later frame plays 1.5 s earlier than it was delivered (one 1/600 s step for the frame that met the
            // held one at the resume).
            let later = frames.filter { $0.index >= 105 }
            #expect(later.count == 60)
            #expect(later.allSatisfy { abs($0.time - (Double($0.index) * frame - 1.5)) <= 0.002 })
        }

        /// Each pause begins 1 ms into a chunk and ends on a chunk boundary, the worst case: the chunk that straddles the
        /// pause start arrives after the pause (as the stream delivers a chunk once it has been captured), and the
        /// first chunk after the resume starts exactly at it. Kept whole, each straddling chunk would push every later
        /// chunk 20.3 ms past the video, 0.1 s after five pauses; dropped, it would leave a gap. The audio stops half a
        /// second before the stop, so its track end shows where it really ends rather than where the session cuts it.
        /// Both channel layouts: ScreenCaptureKit's system audio is non-interleaved.
        @Test(arguments: [Media.AudioLayout.interleaved, .nonInterleaved])
        func fivePausesKeepTheAudioInStepWithTheVideo(layout: Media.AudioLayout) async throws {
            let chunk = Double(Media.chunk) / Double(Media.sampleRate)
            func chunkStart(_ index: Int) -> Double { origin + Double(index) * chunk }
            let writer = try Media.writer(movie, systemAudio: true)
            writer.start(at: t(origin))
            var resumed = origin
            for cycle in 0..<5 {
                let straddling = chunkStart(24 + 38 * cycle)
                let pause = straddling + 0.001
                let resume = chunkStart(38 + 38 * cycle)
                Media.feed(writer, from: resumed, to: straddling, systemAudio: .system, systemAudioLayout: layout)
                writer.pause(at: t(pause))
                Media.feed(writer, from: straddling, to: resume, systemAudio: .system, systemAudioLayout: layout)
                writer.resume(at: t(resume))
                resumed = resume
            }
            let audioEnd = chunkStart(214)
            Media.feed(writer, from: resumed, to: audioEnd, systemAudio: .system, systemAudioLayout: layout)
            Media.feed(writer, from: audioEnd, to: audioEnd + 0.5)
            let result = try await writer.finish(at: t(audioEnd + 0.5))

            // Every chunk was written, the cut ones included: 24 whole ones and the cut one before each pause, then the
            // last 24.
            #expect(result.statistics.droppedAudioChunks == 0)
            #expect(result.statistics.systemAudioChunks == 5 * 25 + 24)
            // Five pauses of 14 chunks less 1 ms each.
            let paused = 5 * (14 * chunk - 0.001)
            let video = try #require(try await Media.trackRanges(movie, .video).first)
            let audio = try #require(try await Media.trackRanges(movie, .audio).first)
            #expect(abs(result.duration - (audioEnd + 0.5 - origin - paused)) <= 0.001)
            #expect(abs(video.end.seconds - result.duration) <= 0.001)
            // Measured 0.3 ms; a regression of even a few milliseconds a pause fails.
            #expect(abs(audio.end.seconds - (video.end.seconds - 0.5)) <= 0.002)
        }

        @Test func aStopWhilePausedEndsWhereThePauseBegan() async throws {
            let writer = try Media.writer(movie, systemAudio: true)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 2, systemAudio: .system)
            writer.pause(at: t(origin + 2))
            // Frames 60–89 and their audio arrive while paused; the stop comes before any resume.
            Media.feed(writer, from: origin + 2, to: origin + 3, systemAudio: .system)
            let result = try await writer.finish(at: t(origin + 3))

            #expect(abs(result.duration - 2) <= 0.001)
            let video = try #require(try await Media.trackRanges(movie, .video).first)
            #expect(abs(video.end.seconds - 2) <= 0.001)
            let audio = try #require(try await Media.trackRanges(movie, .audio).first)
            #expect(audio.end.seconds <= 2.001)
            #expect(audio.end.seconds >= 2 - 0.03)
            // Nothing delivered while paused shows.
            let frames = try await Media.decodedFrames(movie)
            #expect(frames.filter { $0.time < 2 - 0.001 }.allSatisfy { $0.index < 60 })
            #expect(frames.last(where: { $0.time < 2 - 0.001 })?.index == 59)
        }

        @Test func aChangeWhilePausedShowsFromTheResume() async throws {
            let writer = try Media.writer(movie)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 1, frameIndex: { _ in 1 })
            writer.pause(at: t(origin + 1))
            Media.feed(writer, from: origin + 1.5, to: origin + 1.6, frameIndex: { _ in 2 })
            writer.resume(at: t(origin + 2))
            _ = try await writer.finish(at: t(origin + 3))

            // The resume is at 1.0 s in the file.
            let frames = try await Media.decodedFrames(movie)
            #expect(frames.first?.index == 1)
            #expect(frames.last(where: { $0.time <= 1.5 })?.index == 2)
            let video = try #require(try await Media.trackRanges(movie, .video).first)
            #expect(abs(video.end.seconds - 2) <= 0.001)
        }

        @Test func theFirstFrameIsAtZero() async throws {
            // Nothing held at the start: the session starts at the first frame.
            let writer = try Media.writer(movie)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin + 0.1, to: origin + 1)
            let result = try await writer.finish(at: t(origin + 1))

            let frames = try await Media.decodedFrames(movie)
            let first = try #require(frames.first)
            #expect(abs(first.time) < 0.000_001)
            #expect(first.index == 3)
            #expect(abs(result.duration - 0.9) <= 0.001)
        }

        @Test func aHeldFrameStartsTheSessionAtTheCountdownEnd() async throws {
            let writer = try Media.writer(movie)
            // One frame during the countdown, then a still screen.
            Media.feed(writer, from: origin - 1, to: origin - 1 + frame / 2, frameIndex: { _ in 7 })
            writer.start(at: t(origin))
            let result = try await writer.finish(at: t(origin + 2))

            let video = try #require(try await Media.trackRanges(movie, .video).first)
            #expect(abs(video.start.seconds) < 0.001)
            #expect(abs(video.end.seconds - 2) <= 0.001)
            #expect(abs(result.duration - 2) <= 0.001)
            let frames = try await Media.decodedFrames(movie)
            #expect(abs((frames.first?.time ?? 1)) < 0.000_001)
            #expect(!frames.isEmpty)
            #expect(frames.allSatisfy { $0.index == 7 })
        }

        // MARK: Audio

        @Test func audioBeforeTheStartIsDropped() async throws {
            let writer = try Media.writer(movie, systemAudio: true)
            Media.feed(writer, from: origin - frame, to: origin, frameIndex: { _ in 0 })
            writer.start(at: t(origin))
            // Chunks stamped before the start, delivered after it.
            Media.feed(writer, from: origin - 0.2, to: origin, video: false, systemAudio: .system)
            Media.feed(writer, from: origin, to: origin + 2, systemAudio: .system)
            let result = try await writer.finish(at: t(origin + 2))

            // 94 chunks start in 0..<2 s.
            #expect(result.statistics.systemAudioChunks == 94)
            #expect(result.statistics.droppedAudioChunks == 0)
            #expect(result.hasSystemAudio)
            let audio = try #require(try await Media.trackRanges(movie, .audio).first)
            #expect(abs(audio.start.seconds) < 0.001)
            #expect(audio.end.seconds <= 2.001)
        }

        @Test func overlappingAudioIsAcceptedWithoutFailures() async throws {
            let writer = try Media.writer(movie, systemAudio: true, microphone: true)
            let failures = Mutex(0)
            writer.onFailure = { _ in failures.withLock { $0 += 1 } }
            writer.start(at: t(origin))
            // Every other chunk is stamped 21 ms early, overlapping the one before by 21 ms on both tracks.
            Media.feed(writer, from: origin, to: origin + 2, systemAudio: .system, microphone: true,
                       audioOffset: { $0 % 2 == 1 ? -0.021 : 0 })
            let result = try await writer.finish(at: t(origin + 2))

            #expect(failures.withLock { $0 } == 0)
            #expect(result.statistics.droppedAudioChunks == 0)
            #expect(result.statistics.systemAudioChunks == 94)
            #expect(result.statistics.microphoneChunks == 94)
            let audio = try await Media.trackRanges(movie, .audio)
            #expect(audio.count == 2)
            #expect(audio.allSatisfy { abs($0.end.seconds - 2) <= 0.03 })
        }

        /// Measured: without the real-time flag a writer refuses audio after about 3.5 s without frames, so this audio
        /// track would end near 4 s. (Real-time mode drops what an encoder busy with other tests can't take, hence the
        /// margin.)
        @Test func aStillScreenNeverHoldsBackTheAudio() async throws {
            let writer = try Media.writer(movie, systemAudio: true, appendMode: .realTime)
            Media.feed(writer, from: origin - frame, to: origin, frameIndex: { _ in 0 })
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 8, video: false, systemAudio: .system, pacing: 0.005)
            _ = try await writer.finish(at: t(origin + 8))

            let audio = try #require(try await Media.trackRanges(movie, .audio).first)
            #expect(audio.end.seconds >= 6)
        }

        /// Measured: without the real-time flag a writer refuses video after about 1 s without audio buffers, and stops
        /// taking frames that come with pauses between them after about 35 of them. (Real-time mode drops what an encoder
        /// busy with other tests can't take, hence the margin.)
        @Test func anAudioTrackWithoutSamplesNeverHoldsBackTheVideo() async throws {
            let writer = try Media.writer(movie, systemAudio: true, appendMode: .realTime)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 0.5, systemAudio: .system, pacing: 0.008)
            Media.feed(writer, from: origin + 0.5, to: origin + 4, pacing: 0.008)
            let result = try await writer.finish(at: t(origin + 4))

            // 121 frames delivered, with the stop's.
            #expect(result.statistics.appendedFrames >= 70)
        }

        // MARK: Takes

        @Test func restartDiscardsTheFirstTake() async throws {
            let writer = try Media.writer(movie)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 1)
            try await writer.restart(at: t(origin + 1))
            Media.feed(writer, from: origin + 1, to: origin + 2)
            let result = try await writer.finish(at: t(origin + 2))

            #expect(abs(result.duration - 1) <= 0.001)
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            #expect(files == [RecordingFolder.movieFileName])
            // The new take starts with the held frame (the first take's last), then frames 30–59 and the stop's; the
            // counts start again.
            let frames = try await Media.decodedFrames(movie)
            #expect(frames.first?.index == 29)
            #expect(frames.allSatisfy { $0.index >= 29 })
            #expect(result.statistics.appendedFrames == 32)
        }

        /// A microphone ended in the first take (lost, or "Continue Without Audio") stays ended: the new take has no
        /// microphone track, and microphone samples after the restart are ignored.
        @Test func aMicrophoneEndedBeforeARestartStaysEnded() async throws {
            let writer = try Media.writer(movie, systemAudio: true, microphone: true)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 1, systemAudio: .system, microphone: true)
            writer.endMicrophoneTrack()
            try await writer.restart(at: t(origin + 1))
            Media.feed(writer, from: origin + 1, to: origin + 2, systemAudio: .system, microphone: true)
            let result = try await writer.finish(at: t(origin + 2))

            #expect(!result.hasMicrophone)
            #expect(result.statistics.microphoneChunks == 0)
            #expect(result.hasSystemAudio)
            #expect(try await Media.audioChannelCounts(movie) == [2])
        }

        @Test func aFailedWriterReportsOnceAndKeepsItsFile() async throws {
            // Hardware H.264 fails outright above 4096 pixels a side on Apple Silicon (−12903).
            let plan = EncoderPlan(codec: .h264, width: 4112, height: 2160, framesPerSecond: 30, requestedFramesPerSecond: 30,
                                   averageBitRate: 10_000_000, keyFrameInterval: 2, requiresHardware: true)
            let writer = try Media.writer(movie, plan: plan)
            let failures = Mutex(0)
            writer.onFailure = { _ in failures.withLock { $0 += 1 } }
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 0.2, width: 4112, height: 2160)
            // The report follows the delivering call on the queue.
            writer.queue.sync {}

            #expect(failures.withLock { $0 } == 1)
            #expect(writer.statistics.appendedFrames == 0)
            await #expect(throws: (any Error).self) { try await writer.finish(at: t(origin + 0.2)) }
            // Left for recovery.
            #expect(exists(movie))
        }

        /// The failure is reported once the call that delivered the failing frame has returned. That call runs inside the
        /// stream's sample handler, under the stream's lock, so a handler that read the stream's clock there would
        /// deadlock.
        @Test func aFailureIsReportedAfterTheDeliveringCallReturns() async throws {
            // Hardware H.264 fails outright above 4096 pixels a side on Apple Silicon (−12903).
            let plan = EncoderPlan(codec: .h264, width: 4112, height: 2160, framesPerSecond: 30, requestedFramesPerSecond: 30,
                                   averageBitRate: 10_000_000, keyFrameInterval: 2, requiresHardware: true)
            let writer = try Media.writer(movie, plan: plan)
            final class Calls: Sendable {
                let delivering = Mutex(false)
                /// For each report, whether the delivering call was still running.
                let reports = Mutex<[Bool]>([])
            }
            let calls = Calls()
            writer.onFailure = { _ in
                let inside = calls.delivering.withLock { $0 }
                calls.reports.withLock { $0.append(inside) }
            }
            writer.start(at: t(origin))
            writer.queue.sync {
                calls.delivering.withLock { $0 = true }
                for index in 0..<6 {
                    writer.appendVideo(Media.frame(index, width: 4112, height: 2160), at: t(origin + Double(index) * frame))
                }
                calls.delivering.withLock { $0 = false }
            }
            writer.queue.sync {}

            #expect(calls.reports.withLock { $0 } == [false])
        }

        /// A take's failure reported after a restart queued while it failed belongs to the old take: the new take never
        /// hears it, so the recording isn't stopped (and recovered) for a file the restart already threw away.
        @Test func anOldTakesFailureNeverReachesTheTakeARestartMade() async throws {
            let writer = try Media.writer(movie, plan: Self.failingPlan)
            let failures = Mutex(0)
            writer.onFailure = { _ in failures.withLock { $0 += 1 } }
            writer.start(at: t(origin))
            writer.queue.sync {
                // The restart is queued while the frames that fail are delivered, so the report comes after it.
                writer.restart(at: t(origin + 1)) { _ in }
                for index in 0..<6 {
                    writer.appendVideo(Media.frame(index, width: 4112, height: 2160), at: t(origin + Double(index) * frame))
                }
            }
            writer.queue.sync {}

            #expect(failures.withLock { $0 } == 0)
            await writer.cancel()
        }

        /// The counter only drops an old take's report: a failure in the take a restart made is still reported, once.
        @Test func aFailureInTheTakeARestartMadeIsStillReported() async throws {
            let writer = try Media.writer(movie, plan: Self.failingPlan)
            let failures = Mutex(0)
            writer.onFailure = { _ in failures.withLock { $0 += 1 } }
            writer.start(at: t(origin))
            try await writer.restart(at: t(origin + 1))
            writer.queue.sync {
                for index in 0..<6 {
                    writer.appendVideo(Media.frame(index, width: 4112, height: 2160), at: t(origin + 1 + Double(index) * frame))
                }
            }
            writer.queue.sync {}

            #expect(failures.withLock { $0 } == 1)
            await writer.cancel()
        }

        /// The same for a cancel queued while the take failed: nothing is reported after it.
        @Test func aFailureAfterAQueuedCancelIsNotReported() async throws {
            let writer = try Media.writer(movie, plan: Self.failingPlan)
            let failures = Mutex(0)
            writer.onFailure = { _ in failures.withLock { $0 += 1 } }
            writer.start(at: t(origin))
            writer.queue.sync {
                writer.cancel {}
                for index in 0..<6 {
                    writer.appendVideo(Media.frame(index, width: 4112, height: 2160), at: t(origin + Double(index) * frame))
                }
            }
            writer.queue.sync {}

            #expect(failures.withLock { $0 } == 0)
            #expect(!exists(movie))
        }

        /// Hardware H.264 fails outright above 4096 pixels a side on Apple Silicon (−12903).
        static let failingPlan = EncoderPlan(codec: .h264, width: 4112, height: 2160, framesPerSecond: 30,
                                             requestedFramesPerSecond: 30, averageBitRate: 10_000_000, keyFrameInterval: 2,
                                             requiresHardware: true)

        @Test func cancelRemovesTheFile() async throws {
            let writer = try Media.writer(movie, systemAudio: true)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 1, systemAudio: .system)
            #expect(exists(movie))
            await writer.cancel()
            #expect(!exists(movie))
            // Later samples are ignored and finishing has nothing to finish.
            Media.feed(writer, from: origin + 1, to: origin + 1.5, systemAudio: .system)
            await #expect(throws: CancellationError.self) { try await writer.finish(at: t(origin + 1.5)) }
            #expect(!exists(movie))
        }

        // MARK: The file

        @Test func theFileIsFragmentedWhileWritingAndDefragmentedWhenFinished() async throws {
            let writer = try Media.writer(movie, systemAudio: true)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 2.5, systemAudio: .system)
            let openCopy = folder.appending(path: "open-copy.mp4")
            try await Media.copyWhenSettled(movie, to: openCopy)
            #expect(try Media.topLevelBoxes(openCopy).contains("moof"))

            _ = try await writer.finish(at: t(origin + 2.5))
            #expect(try Media.topLevelBoxes(movie) == ["ftyp", "mdat", "moov"])
        }

        @Test func colourTagsAre709() async throws {
            let writer = try Media.writer(movie)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 0.5)
            _ = try await writer.finish(at: t(origin + 0.5))

            let format = try await Media.videoFormat(movie)
            func tag(_ key: CFString) -> String? {
                CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
            }
            let (primaries, transfer, matrix) = (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
                                                 kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
                                                 kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
            #expect(tag(kCMFormatDescriptionExtension_ColorPrimaries) == primaries)
            #expect(tag(kCMFormatDescriptionExtension_TransferFunction) == transfer)
            #expect(tag(kCMFormatDescriptionExtension_YCbCrMatrix) == matrix)
        }

        @Test func hevcPlansWriteHvc1() async throws {
            let plan = EncoderPlan(codec: .hevc, width: 320, height: 180, framesPerSecond: 30, requestedFramesPerSecond: 30,
                                   averageBitRate: 1_000_000, keyFrameInterval: 2, requiresHardware: true)
            let writer = try Media.writer(movie, plan: plan)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 0.5)
            _ = try await writer.finish(at: t(origin + 0.5))

            let format = try await Media.videoFormat(movie)
            #expect(format.mediaSubType.rawValue == kCMVideoCodecType_HEVC)
        }

        @Test func tracksFollowTheConfiguration() async throws {
            // System audio and the microphone: two tracks, the system audio's stereo first, the microphone's mono second.
            let both = try Media.writer(movie, systemAudio: true, microphone: true)
            both.start(at: t(origin))
            Media.feed(both, from: origin, to: origin + 1, systemAudio: .system, microphone: true)
            let withAudio = try await both.finish(at: t(origin + 1))
            #expect(try await Media.audioChannelCounts(movie) == [2, 1])
            #expect(withAudio.hasSystemAudio)
            #expect(withAudio.hasMicrophone)

            // Neither: video only.
            let silentMovie = folder.appending(path: "silent.mp4")
            let silent = try Media.writer(silentMovie)
            silent.start(at: t(origin))
            Media.feed(silent, from: origin, to: origin + 1)
            let withoutAudio = try await silent.finish(at: t(origin + 1))
            #expect(try await Media.audioChannelCounts(silentMovie).isEmpty)
            #expect(try await Media.trackRanges(silentMovie, .video).count == 1)
            #expect(!withoutAudio.hasSystemAudio)
            #expect(!withoutAudio.hasMicrophone)
        }

        /// A microphone that ends before its first chunk (unplugged, or it wouldn't start) leaves no empty track: the file
        /// has the system audio alone, in the countdown and once recording alike.
        @Test(arguments: [false, true])
        func aMicrophoneEndedBeforeItsFirstChunkLeavesNoTrack(duringTheCountdown: Bool) async throws {
            let writer = try Media.writer(movie, systemAudio: true, microphone: true)
            if duringTheCountdown { writer.endMicrophoneTrack() }
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 0.5, systemAudio: .system)
            if !duringTheCountdown { writer.endMicrophoneTrack() }
            Media.feed(writer, from: origin + 0.5, to: origin + 1, systemAudio: .system, microphone: true)
            let result = try await writer.finish(at: t(origin + 1))

            #expect(!result.hasMicrophone)
            #expect(result.hasSystemAudio)
            #expect(try await Media.audioChannelCounts(movie) == [2])
            #expect(abs(result.duration - 1) <= 0.001)
            #expect(try await Media.trackRanges(movie, .video).count == 1)
        }

        @Test func aMicrophoneTrackEndedEarlyStillFinishes() async throws {
            let writer = try Media.writer(movie, systemAudio: true, microphone: true)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 1, systemAudio: .system, microphone: true)
            writer.endMicrophoneTrack()
            // Microphone chunks after the end are ignored.
            Media.feed(writer, from: origin + 1, to: origin + 2, systemAudio: .system, microphone: true)
            let result = try await writer.finish(at: t(origin + 2))

            #expect(result.hasMicrophone)
            #expect(result.statistics.microphoneChunks == 47)
            #expect(result.statistics.systemAudioChunks == 94)
            let audio = try await Media.trackRanges(movie, .audio)
            #expect(audio.count == 2)
            #expect(abs((audio.first?.end.seconds ?? 0) - 2) <= 0.03)
            #expect(abs((audio.last?.end.seconds ?? 0) - 1) <= 0.03)
        }
    }
}

/// Cutting a PCM chunk at a pause keeps its first samples, whatever the channel layout.
struct PCMPrefixTests {
    /// Each channel's samples, from a chunk's buffers (one buffer interleaved, one per channel otherwise).
    func channels(_ sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) throws -> [[Float]] {
        try sample.withUnsafeSampleBuffer { buffer in
            try buffer.withAudioBufferList { buffers, _ in
                let floats = buffers.map { channel in
                    Array(UnsafeBufferPointer(start: channel.mData!.assumingMemoryBound(to: Float.self),
                                              count: Int(channel.mDataByteSize) / 4))
                }
                guard floats.count == 1 else { return floats }
                return (0..<2).map { channel in stride(from: channel, to: floats[0].count, by: 2).map { floats[0][$0] } }
            }
        }
    }

    @Test(arguments: [SyntheticMedia.AudioLayout.interleaved, .nonInterleaved])
    func theFirstFramesOfEachChannelAreKept(layout: SyntheticMedia.AudioLayout) throws {
        let chunk = SyntheticMedia.tone(.system, firstSample: 4096, at: t(1001), layout: layout)
        let prefix = try RecordingWriter.pcmPrefix(of: chunk, frames: 48)

        #expect(prefix.sampleCount == 48)
        #expect(prefix.presentationTimeStamp == chunk.presentationTimeStamp)
        #expect(abs(prefix.duration.seconds - 0.001) < 1e-9)
        let kept = try channels(prefix)
        let whole = try channels(chunk)
        #expect(kept.count == 2)
        #expect(kept[0] == Array(whole[0].prefix(48)))
        #expect(kept[1] == Array(whole[1].prefix(48)))
        #expect(kept[0] != kept[1])
    }
}
