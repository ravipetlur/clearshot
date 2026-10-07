import CoreGraphics
import CSTestSupport
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import CSRecording

extension MediaTests {
    /// `StreamingGIFEncoder` on intermediates written with `RecordingWriter` (frames whose colour encodes their index),
    /// with ImageIO reading the GIF, in a temporary folder.
    final class GIFEncoderTests {
        typealias Media = SyntheticMedia

        let folder = FileManager.default.temporaryDirectory.appending(path: "gif-encoder-\(UUID().uuidString)",
                                                                      directoryHint: .isDirectory)
        var source: URL { folder.appending(path: "recording.mp4") }
        var gif: URL { folder.appending(path: "recording.gif") }
        let settings = GIFConversionSettings(framesPerSecond: 30, quality: 100, optimize: true)

        init() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
        }

        /// A GIF intermediate `seconds` long at 30 fps, `width` × `height`, without audio, as Record GIF writes one.
        func makeIntermediate(seconds: Double, width: Int = 320, height: Int = 180) async throws {
            let plan = EncoderPlan.make(regionPoints: CGSize(width: width, height: height), scale: 1, scaleRetinaTo1x: true,
                                        maxResolution: .original, framesPerSecond: 30, hardwareEncoding: true,
                                        purpose: .gifIntermediate(maxWidth: 800))
            let writer = try Media.writer(source, width: width, height: height, plan: plan)
            writer.start(at: t(Media.origin))
            Media.feed(writer, from: Media.origin, to: Media.origin + seconds, width: width, height: height)
            _ = try await writer.finish(at: t(Media.origin + seconds))
        }

        /// The index the centre pixel of GIF frame `index` encodes.
        func frameIndex(_ source: CGImageSource, at index: Int) -> Int {
            let decoded = GIFFixtures.decoded(source, at: index)
            let center = (decoded.height / 2 * decoded.width + decoded.width / 2) * 4
            return Media.index(red: decoded.rgba[center], green: decoded.rgba[center + 1], blue: decoded.rgba[center + 2])
        }

        @Test(.enabled(if: HardwareEncoders.available, "needs a hardware video encoder"))
        func anIntermediateBecomesAGIFWithTheScheduledTiming() async throws {
            try await makeIntermediate(seconds: 2)
            let result = try await StreamingGIFEncoder().convert(source, to: gif, settings: settings) { _ in }
            let data = try Data(contentsOf: gif)
            let gifSource = GIFFixtures.source(data)
            let delays = GIFFixtures.delays(gifSource)
            #expect(abs(delays.reduce(0, +) - 200) <= 2)
            #expect(delays.count == result.frameCount)
            #expect(CGImageSourceGetCount(gifSource) == result.frameCount)
            // Every source frame differs, so the carried 3, 4, 3 rounding shows.
            #expect(result.frameCount == 60)
            #expect(Array(delays.prefix(3)) == [3, 4, 3])
            #expect(GIFFixtures.loopCount(gifSource) == 0)
            #expect(abs(result.duration - 2) <= 0.02)
            #expect(result.pixelWidth == 320)
            #expect(result.pixelHeight == 180)
            #expect(result.byteCount == Int64(data.count))
            #expect(result.url == gif)
            #expect(frameIndex(gifSource, at: 0) == 0)
            #expect(frameIndex(gifSource, at: 59) == 59)
        }

        @Test(.enabled(if: HardwareEncoders.available, "needs a hardware video encoder"))
        func aTrimmedConversionCoversOnlyTheRange() async throws {
            try await makeIntermediate(seconds: 2)
            var trimmed = settings
            trimmed.trim = TrimRange(start: 0.5, end: 1.5, duration: 2, framesPerSecond: 30)
            let result = try await StreamingGIFEncoder().convert(source, to: gif, settings: trimmed) { _ in }
            let gifSource = GIFFixtures.source(try Data(contentsOf: gif))
            #expect(abs(GIFFixtures.delays(gifSource).reduce(0, +) - 100) <= 2)
            #expect(abs(result.duration - 1) <= 0.02)
            #expect(result.frameCount == 30)
            #expect(frameIndex(gifSource, at: 0) == 15)
            #expect(frameIndex(gifSource, at: result.frameCount - 1) == 44)
        }

        @Test(.enabled(if: HardwareEncoders.available, "needs a hardware video encoder"))
        func cancellingRemovesThePartialFile() async throws {
            try await makeIntermediate(seconds: 6, width: 640, height: 360)
            let (reports, continuation) = AsyncStream<Void>.makeStream()
            let (source, gif, settings) = (source, gif, settings)
            let conversion = Task {
                try await StreamingGIFEncoder().convert(source, to: gif, settings: settings) { progress in
                    if progress.bytesWritten > 0 { continuation.yield() }
                }
            }
            // Under way in the second pass: the file has its header and some frames.
            for await _ in reports { break }
            conversion.cancel()
            await #expect(throws: CancellationError.self) { try await conversion.value }
            #expect(!FileManager.default.fileExists(atPath: gif.path(percentEncoded: false)))
        }

        @Test(.enabled(if: HardwareEncoders.available, "needs a hardware video encoder"))
        func progressReachesOne() async throws {
            try await makeIntermediate(seconds: 2)
            let reports = Mutex<[GIFProgress]>([])
            let result = try await StreamingGIFEncoder().convert(source, to: gif, settings: settings) { progress in
                reports.withLock { $0.append(progress) }
            }
            let all = reports.withLock { $0 }
            #expect(all.count >= 2)
            #expect(zip(all, all.dropFirst()).allSatisfy { $0.fraction <= $1.fraction && $0.bytesWritten <= $1.bytesWritten })
            #expect(all.last == GIFProgress(fraction: 1, bytesWritten: result.byteCount))
            // The palette pass counts too, with nothing written yet, so the progress doesn't sit at 0 through it.
            let first = try #require(all.first)
            #expect(first.bytesWritten == 0)
            #expect(first.fraction <= StreamingGIFEncoder.paletteShare)
        }

        /// A file without video, and a source that is the destination, leave no GIF behind.
        @Test func aFileWithoutVideoIsRefused() async throws {
            try await Media.makeAudioOnlySource(at: source, seconds: 1)
            await #expect(throws: VideoFileError.noVideoTrack) {
                try await StreamingGIFEncoder().convert(self.source, to: self.gif, settings: self.settings) { _ in }
            }
            #expect(!FileManager.default.fileExists(atPath: gif.path(percentEncoded: false)))
        }
    }
}
