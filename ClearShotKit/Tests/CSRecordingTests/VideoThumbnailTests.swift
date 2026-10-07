import CoreGraphics
import CSTestSupport
import Foundation
import Testing
@testable import CSRecording

extension MediaTests {
    /// A video's facts and its thumbnail, from synthetic recordings in a temporary folder.
    @Suite(.enabled(if: HardwareEncoders.available, "needs a hardware video encoder"))
    final class VideoThumbnailTests {
        typealias Media = SyntheticMedia

        let folder = FileManager.default.temporaryDirectory.appending(path: "video-thumbnail-\(UUID().uuidString)",
                                                                      directoryHint: .isDirectory)
        var source: URL { folder.appending(path: "source.mp4") }

        init() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
        }

        @Test func infoReadsDurationSizeRateAndAudioTracks() async throws {
            try await Media.makeSource(at: source, seconds: 2)
            let info = try await VideoThumbnail.info(of: source)
            #expect(abs(info.duration - 2) <= 0.001)
            #expect(info.pixelWidth == 640)
            #expect(info.pixelHeight == 360)
            // Not rotated: shown at its stored size.
            #expect(info.displayWidth == 640)
            #expect(info.displayHeight == 360)
            #expect(abs(info.framesPerSecond - 30) < 0.5)
            #expect(info.videoBitRate > 0)
            #expect(info.codec == .h264)
            // The system audio's stereo track, then the microphone's mono one.
            #expect(info.audioChannelCounts == [2, 1])

            let audioOnly = folder.appending(path: "audio-only.mp4")
            try await Media.makeAudioOnlySource(at: audioOnly, seconds: 0.5)
            await #expect(throws: VideoFileError.noVideoTrack) { try await VideoThumbnail.info(of: audioOnly) }
            let garbage = folder.appending(path: "garbage.mp4")
            try Data(repeating: 0x5A, count: 4_096).write(to: garbage)
            let error = await #expect(throws: VideoFileError.self) { try await VideoThumbnail.info(of: garbage) }
            #expect(error.map { if case .unreadable = $0 { true } else { false } } == true)
        }

        @Test func theThumbnailIsAtMost640() async throws {
            try await Media.makeSource(at: source, seconds: 0.5, width: 1280, height: 720, systemTone: nil, microphone: false)
            let image = try await VideoThumbnail.image(of: source)
            #expect(image.width == 640)
            #expect(image.height == 360)
            let smaller = try await VideoThumbnail.image(of: source, maximumPixel: 200)
            #expect(max(smaller.width, smaller.height) == 200)
        }

        /// A trimmed GIF's thumbnail is its source video's frame at the trim's start.
        @Test func theThumbnailCanBeTakenAtATime() async throws {
            try await Media.makeSource(at: source, seconds: 2, systemTone: nil, microphone: false)
            let first = try await VideoThumbnail.image(of: source)
            #expect(try Self.frameIndex(of: first) == 0)
            let later = try await VideoThumbnail.image(of: source, at: 1.37)
            #expect(try Self.frameIndex(of: later) == 41)
        }

        /// The index a synthetic frame's colour encodes, read from the image's middle pixel.
        static func frameIndex(of image: CGImage) throws -> Int {
            var pixel = [UInt8](repeating: 0, count: 4)
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            try pixel.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                     bytesPerRow: 4, space: space,
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.interpolationQuality = .none
                let middle = CGRect(x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2), width: CGFloat(image.width),
                                    height: CGFloat(image.height))
                context.draw(image, in: middle)
            }
            return SyntheticMedia.index(red: pixel[0], green: pixel[1], blue: pixel[2])
        }
    }
}
