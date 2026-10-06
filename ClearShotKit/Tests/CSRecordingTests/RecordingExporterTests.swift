import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import CSRecording

extension MediaTests {
    /// Trims, mutes, remixes and re-encodes of a synthetic 6 s 640 × 360 recording at 30 fps with a stereo "system" track
    /// (440/660 Hz) and a mono "mic" track (220 Hz), in a temporary folder.
    final class RecordingExporterTests {
        typealias Media = SyntheticMedia

        let folder = FileManager.default.temporaryDirectory.appending(path: "recording-exporter-\(UUID().uuidString)",
                                                                      directoryHint: .isDirectory)
        var source: URL { folder.appending(path: "source.mp4") }
        var output: URL { folder.appending(path: "exported.mp4") }
        let frame = 1.0 / Double(SyntheticMedia.framesPerSecond)

        init() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
        }

        /// Writes the source and reads its facts.
        func makeSource(seconds: Double = 6, width: Int = 640, height: Int = 360, systemTone: SyntheticMedia.Tone = .system,
                        microphone: Bool = true) async throws -> VideoSourceInfo {
            try await Media.makeSource(at: source, seconds: seconds, width: width, height: height, systemTone: systemTone,
                                       microphone: microphone)
            return try await VideoThumbnail.info(of: source)
        }

        func plan(_ info: VideoSourceInfo, _ change: (inout VideoEdit) -> Void) -> VideoEditPlan {
            var edit = VideoEdit()
            change(&edit)
            return VideoEditPlan.make(edit: edit, source: info)
        }

        func duration(_ url: URL) async throws -> Double {
            try await AVURLAsset(url: url).load(.duration).seconds
        }

        @Test func aPassthroughTrimIsFrameAccurate() async throws {
            let info = try await makeSource()
            let trim = TrimRange(start: 1.37, end: 4.21, duration: info.duration, framesPerSecond: info.framesPerSecond)
            let plan = plan(info) { $0.trim = trim }
            #expect(plan.path == .passthrough)
            try await RecordingExporter.export(source, to: output, plan: plan)

            let ranges = try await Media.trackRanges(output, .video) + Media.trackRanges(output, .audio)
            #expect(ranges.count == 3)
            #expect(ranges.allSatisfy { abs($0.duration.seconds - 2.84) <= frame })
            let frames = try await Media.decodedFrames(output)
            let first = try #require(frames.first)
            #expect(first.index == 41)
            #expect(abs(first.time) < 0.001)
        }

        @Test func muteLeavesNoAudioTrack() async throws {
            let info = try await makeSource()
            try await RecordingExporter.export(source, to: output, plan: .mute(info))

            #expect(try await Media.audioChannelCounts(output).isEmpty)
            let video = try await Media.trackRanges(output, .video)
            #expect(video.count == 1)
            #expect(abs((video.first?.duration.seconds ?? 0) - 6) <= 0.001)
        }

        @Test func mergingGivesOneTrack() async throws {
            let info = try await makeSource()
            let plan = plan(info) { $0.trackVolumes = [1, 1] }
            #expect(plan.path == .audioRemix)
            #expect(plan.mergesTracks)
            try await RecordingExporter.export(source, to: output, plan: plan)

            #expect(try await Media.audioChannelCounts(output) == [2])
            #expect(abs(try await duration(output) - 6) <= frame)
            let audio = try #require(try await Media.trackRanges(output, .audio).first)
            #expect(abs(audio.duration.seconds - 6) <= 0.05)
        }

        @Test func monoGivesOneChannel() async throws {
            let info = try await makeSource()
            let plan = plan(info) { $0.mono = true }
            #expect(plan.path == .audioRemix)
            try await RecordingExporter.export(source, to: output, plan: plan)

            // Both tracks kept, in order, each mono.
            #expect(try await Media.audioChannelCounts(output) == [1, 1])
            #expect(try await Media.trackRanges(output, .video).count == 1)
        }

        @Test func volumeTwoDoublesTheRMS() async throws {
            let info = try await makeSource()
            let plan = plan(info) { $0.volume = 2 }
            #expect(plan.trackVolumes == [2, 2])
            try await RecordingExporter.export(source, to: output, plan: plan)

            for track in 0..<2 {
                let ratio = try await Media.rms(output, audioTrack: track) / Media.rms(source, audioTrack: track)
                #expect(abs(ratio - 2) <= 2 * 0.05)
            }
        }

        @Test func aLeftOnlyVoiceLandsInTheCentreInMono() async throws {
            // A voice on the left channel only (0.177 RMS there), mixed to mono at −3 dB.
            let info = try await makeSource(systemTone: .leftOnly, microphone: false)
            try await RecordingExporter.export(source, to: output, plan: plan(info) { $0.mono = true })

            #expect(try await Media.audioChannelCounts(output) == [1])
            let level = try await Media.rms(output, audioTrack: 0)
            #expect(abs(level - 0.125) <= 0.125 * 0.05)
        }

        @Test func reencodingToHalfSizeGivesEvenHalfDimensions() async throws {
            // 480p's 854 is half of 1710 × 962 rounded down to even sides: 854 × 480.
            let info = try await makeSource(seconds: 2, width: 1710, height: 962)
            let plan = plan(info) { $0.resolution = .res480p }
            #expect(plan.path == .reencode)
            #expect(plan.outputWidth == 854)
            #expect(plan.outputHeight == 480)
            try await RecordingExporter.export(source, to: output, plan: plan)

            let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
            let size = try await track.load(.naturalSize)
            #expect(size == CGSize(width: 854, height: 480))
            #expect(abs(try await duration(output) - 2) <= frame)
            let frames = try await Media.decodedFrames(output)
            #expect(frames.first?.index == 0)
            #expect(frames.count == 60)
            #expect(try await Media.audioChannelCounts(output) == [2, 1])
        }

        @Test func anAudioOnlySourceThrowsNoVideoTrack() async throws {
            let audioOnly = folder.appending(path: "audio-only.mp4")
            try await Media.makeAudioOnlySource(at: audioOnly, seconds: 1)
            let info = VideoSourceInfo(duration: 1, pixelWidth: 640, pixelHeight: 360, framesPerSecond: 30,
                                       videoBitRate: 1_000_000, codec: .h264, audioChannelCounts: [2])

            await #expect(throws: VideoFileError.noVideoTrack) {
                try await RecordingExporter.export(audioOnly, to: self.output, plan: .mute(info))
            }
            await #expect(throws: VideoFileError.noVideoTrack) {
                try await RecordingExporter.export(audioOnly, to: self.output, plan: self.plan(info) { $0.mono = true })
            }
            #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
            #expect(VideoFileError.noVideoTrack.errorDescription == "The source file does not contain a video track.")
        }

        /// Every path that reports progress: the reader-writer paths (remix, re-encode) report as their pumps go; the
        /// passthrough (trim) reports the session's states every 0.1 s, but its export of even a 30 s source took 14 ms
        /// (measured), so it ends before its first update and reports only its ends.
        @Test func progressReachesOne() async throws {
            let info = try await makeSource()
            let trim = TrimRange(start: 1, end: 5, duration: info.duration, framesPerSecond: info.framesPerSecond)
            let plans = [("remix", plan(info) { $0.volume = 0.5 }), ("reencode", plan(info) { $0.quality = .low }),
                         ("trim", plan(info) { $0.trim = trim })]
            #expect(plans.map(\.1.path) == [.audioRemix, .reencode, .passthrough])
            for (name, plan) in plans {
                let reported = Mutex<[Double]>([])
                let destination = folder.appending(path: "\(name).mp4")
                try await RecordingExporter.export(source, to: destination, plan: plan) { fraction in
                    reported.withLock { $0.append(fraction) }
                }
                let fractions = reported.withLock { $0 }
                #expect(fractions.last == 1, "\(name)")
                #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 < $1 }, "\(name)")
                if plan.path != .passthrough {
                    #expect(fractions.filter { $0 > 0 && $0 < 1 }.count >= 10, "\(name): \(fractions)")
                }
            }
        }

        /// A trim plus a volume change, the common editor edit: the reader-writer path over the trimmed range.
        @Test func aRemixWithATrimKeepsTheRangeAtTheNewVolume() async throws {
            let info = try await makeSource()
            let plan = plan(info) {
                $0.trim = TrimRange(start: 1, end: 4, duration: info.duration, framesPerSecond: info.framesPerSecond)
                $0.volume = 0.5
            }
            #expect(plan.path == .audioRemix)
            try await RecordingExporter.export(source, to: output, plan: plan)

            #expect(abs(try await duration(output) - 3) <= frame)
            let video = try #require(try await Media.trackRanges(output, .video).first)
            #expect(abs(video.duration.seconds - 3) <= frame)
            let audio = try await Media.trackRanges(output, .audio)
            #expect(audio.count == 2)
            #expect(audio.allSatisfy { abs($0.duration.seconds - 3) <= 0.05 })
            let frames = try await Media.decodedFrames(output)
            let first = try #require(frames.first)
            #expect(first.index == 30)
            #expect(abs(first.time) < 0.001)
            for track in 0..<2 {
                let ratio = try await Media.rms(output, audioTrack: track) / Media.rms(source, audioTrack: track)
                #expect(abs(ratio - 0.5) <= 0.5 * 0.05)
            }
        }

        /// An opened phone video is stored on its side with a rotation for display; every path keeps that rotation, so
        /// the edit isn't shown sideways.
        @Test func everyPathKeepsTheVideosRotation() async throws {
            _ = try await makeSource(seconds: 2, microphone: false)
            let quarterTurn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
            // The source turned a quarter, as a phone writes a portrait video.
            let rotated = folder.appending(path: "rotated.mp4")
            let asset = AVURLAsset(url: source)
            let length = try await asset.load(.duration)
            let composition = AVMutableComposition()
            for track in try await asset.load(.tracks) {
                let copy = try #require(composition.addMutableTrack(withMediaType: track.mediaType,
                                                                    preferredTrackID: kCMPersistentTrackID_Invalid))
                try copy.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: .zero)
                if track.mediaType == .video { copy.preferredTransform = quarterTurn }
            }
            try await RecordingExporter.exportPassthrough(composition, to: rotated, progress: nil)
            #expect(try await Self.videoTransform(rotated) == quarterTurn)

            let info = try await VideoThumbnail.info(of: rotated)
            // Stored landscape, shown portrait: the editor's window takes the shown size.
            #expect(info.pixelWidth == 640)
            #expect(info.pixelHeight == 360)
            #expect(info.displayWidth == 360)
            #expect(info.displayHeight == 640)
            let trim = TrimRange(start: 0.5, end: 1.5, duration: info.duration, framesPerSecond: info.framesPerSecond)
            let plans = [("trim", plan(info) { $0.trim = trim }), ("remix", plan(info) { $0.volume = 0.5 }),
                         ("reencode", plan(info) { $0.quality = .low })]
            #expect(plans.map(\.1.path) == [.passthrough, .audioRemix, .reencode])
            for (name, plan) in plans {
                let destination = folder.appending(path: "rotated-\(name).mp4")
                try await RecordingExporter.export(rotated, to: destination, plan: plan)
                #expect(try await Self.videoTransform(destination) == quarterTurn, "\(name)")
            }
        }

        /// A file with three audio tracks (not one ClearShot writes): a remix merges them into one, as its plan says; a
        /// trim copies all three.
        @Test func moreThanTwoAudioTracksAreMergedWhenRewrittenAndKeptOnATrim() async throws {
            _ = try await makeSource(seconds: 2)
            // The source's system track, its microphone track, and the system track again.
            let threeTracks = folder.appending(path: "three-tracks.mp4")
            let asset = AVURLAsset(url: source)
            let length = try await asset.load(.duration)
            let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            #expect(audio.count == 2)
            let composition = AVMutableComposition()
            for track in [video] + audio + [audio[0]] {
                let copy = try #require(composition.addMutableTrack(withMediaType: track.mediaType,
                                                                    preferredTrackID: kCMPersistentTrackID_Invalid))
                try copy.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: .zero)
            }
            try await RecordingExporter.exportPassthrough(composition, to: threeTracks, progress: nil)
            let info = try await VideoThumbnail.info(of: threeTracks)
            #expect(info.audioChannelCounts == [2, 1, 2])

            let louder = plan(info) { $0.volume = 1.5 }
            #expect(louder.path == .audioRemix)
            #expect(louder.mergesTracks)
            let remixed = folder.appending(path: "three-remixed.mp4")
            try await RecordingExporter.export(threeTracks, to: remixed, plan: louder)
            #expect(try await Media.audioChannelCounts(remixed) == [louder.audioChannels])

            let trim = TrimRange(start: 0.5, end: 1.5, duration: info.duration, framesPerSecond: info.framesPerSecond)
            let trimmed = folder.appending(path: "three-trimmed.mp4")
            try await RecordingExporter.export(threeTracks, to: trimmed, plan: plan(info) { $0.trim = trim })
            #expect(try await Media.audioChannelCounts(trimmed) == [2, 1, 2])
        }

        /// An opened ProRes movie: MP4 can't carry ProRes, so every edit that copies the video as stored (Mute, a trim,
        /// a remix) keeps the QuickTime container, ProRes and all, and its frames; a re-encode writes H.264 or HEVC, so
        /// it is an MP4 as ever.
        @Test func aCopiedProResVideoStaysAQuickTimeMovie() async throws {
            let prores = folder.appending(path: "prores.mov")
            try await Self.makeProResSource(at: prores, seconds: 2)
            let info = try await VideoThumbnail.info(of: prores)
            #expect(info.videoCodecType == kCMVideoCodecType_AppleProRes422)
            let trim = TrimRange(start: 0.5, end: 1.5, duration: info.duration, framesPerSecond: info.framesPerSecond)
            let plans = [("mute", VideoEditPlan.mute(info)), ("trim", plan(info) { $0.trim = trim }),
                         ("remix", plan(info) { $0.volume = 0.5 })]
            #expect(plans.map(\.1.path) == [.passthrough, .passthrough, .audioRemix])
            #expect(plans.allSatisfy { $0.1.container == .mov })
            for (name, plan) in plans {
                let destination = folder.appending(path: "prores-\(name).\(plan.container.fileExtension)")
                try await RecordingExporter.export(prores, to: destination, plan: plan)
                #expect(try Self.majorBrand(destination) == "qt  ", "\(name)")
                #expect(try await Media.videoFormat(destination).mediaSubType == .proRes422, "\(name)")
                // By length and count: ProRes's colour conversion moves a saturated frame's colour a level, so the index
                // a trimmed frame's colour encodes doesn't survive it.
                let seconds = name == "trim" ? 1.0 : 2.0
                let video = try #require(try await Media.trackRanges(destination, .video).first)
                #expect(abs(video.duration.seconds - seconds) <= frame, "\(name)")
                #expect(try await Media.decodedFrames(destination).count == Int(seconds) * Media.framesPerSecond, "\(name)")
            }
            #expect(try await Media.audioChannelCounts(folder.appending(path: "prores-mute.mov")).isEmpty)
            #expect(try await Media.audioChannelCounts(folder.appending(path: "prores-remix.mov")) == [2])
        }

        @Test func aReencodedProResVideoIsAnMP4() async throws {
            let prores = folder.appending(path: "prores.mov")
            try await Self.makeProResSource(at: prores, seconds: 1)
            let info = try await VideoThumbnail.info(of: prores)
            let plan = plan(info) { $0.quality = .low }
            #expect(plan.path == .reencode)
            #expect(plan.container == .mp4)
            try await RecordingExporter.export(prores, to: output, plan: plan)
            #expect(try Self.majorBrand(output) != "qt  ")
            #expect(try await Media.videoFormat(output).mediaSubType == .h264)
        }

        /// A `seconds`-long 320 × 180 ProRes 422 QuickTime movie at 30 fps whose frames encode their index, with a
        /// stereo AAC track: a codec MP4 can't carry.
        static func makeProResSource(at url: URL, seconds: Double) async throws {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            ])
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Media.sampleRate, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            // Each track in a task of its own: the writer holds one back for the other to catch up, so feeding both from
            // one loop stalls (measured: at 1.17 s in). Each receiver is sent to its own task, as in the exporter.
            try await withThrowingTaskGroup { group in
                let pixels = writer.inputPixelBufferReceiver(for: video, pixelBufferAttributes: nil)
                let sound = writer.inputReceiver(for: audio)
                try writer.start()
                writer.startSession(atSourceTime: .zero)
                group.addTask {
                    for frame in 0..<Int(seconds * Double(Media.framesPerSecond)) {
                        try await pixels.append(Media.frame(frame), with: CMTime(value: CMTimeValue(frame),
                                                                                 timescale: CMTimeScale(Media.framesPerSecond)))
                    }
                    pixels.finish()
                }
                group.addTask {
                    var sample = 0
                    while Double(sample) < seconds * Double(Media.sampleRate) {
                        try await sound.append(Media.tone(.system, firstSample: sample,
                                                          at: CMTime(value: CMTimeValue(sample),
                                                                     timescale: CMTimeScale(Media.sampleRate))))
                        sample += Media.chunk
                    }
                    sound.finish()
                }
                try await group.waitForAll()
            }
            await writer.finishWriting()
            #expect(writer.status == .completed, "\(String(describing: writer.error))")
        }

        /// The file's major brand: "qt  " for a QuickTime movie, "mp42" or "isom" for an MP4.
        static func majorBrand(_ url: URL) throws -> String {
            let data = try Data(contentsOf: url)
            guard data.count >= 12 else { return "" }
            return String(decoding: data[8..<12], as: UTF8.self)
        }

        static func videoTransform(_ url: URL) async throws -> CGAffineTransform {
            let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
            return try await track.load(.preferredTransform)
        }
    }
}
