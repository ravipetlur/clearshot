import CSCapture
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CSRecording

/// What an opened GIF's item records, read from files ImageIO writes.
final class GIFFileInfoTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "gif-info-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func frame(width: Int, height: Int, gray: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Writes `delays.count` frames of `type`, each with its delay in seconds (GIF only).
    func write(_ name: String, type: UTType, delays: [Double], width: Int = 30, height: Int = 20) throws -> URL {
        let url = folder.appending(path: name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString,
                                                                       delays.count, nil))
        for (index, delay) in delays.enumerated() {
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(destination, frame(width: width, height: height, gray: CGFloat(index) / 3),
                                       type == .gif ? properties : nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func readsSizeFramesAndDuration() throws {
        let url = try write("Opened.gif", type: .gif, delays: [0.1, 0.2, 0.3])
        let info = try #require(GIFFileInfo.read(url))
        #expect(info.pixelWidth == 30)
        #expect(info.pixelHeight == 20)
        #expect(info.frameCount == 3)
        #expect(abs(info.duration - 0.6) < 0.001)
    }

    /// Many older GIFs store no delay (0) or 1 cs. Browsers and macOS play those frames for 10 cs, so the duration
    /// counts them as 10 cs, not 0:00.
    @Test func aFrameWithNoDelayCountsAsTenHundredths() throws {
        let zero = try write("Old.gif", type: .gif, delays: [0, 0, 0])
        let info = try #require(GIFFileInfo.read(zero))
        #expect(abs(info.duration - 0.3) < 0.001)
        let mixed = try write("Mixed.gif", type: .gif, delays: [0, 0.01, 0.2])
        let mixedInfo = try #require(GIFFileInfo.read(mixed))
        #expect(abs(mixedInfo.duration - 0.4) < 0.001)
    }

    /// The rule: the unclamped delay when it is at least 0.011 s (2 cs), else 0.1 s; with neither, 0.1 s.
    @Test func theFrameDelayRule() {
        #expect(GIFFileInfo.frameDelay(unclamped: 0.05, clamped: 0.05) == 0.05)
        #expect(GIFFileInfo.frameDelay(unclamped: 0.02, clamped: 0.02) == 0.02)
        #expect(GIFFileInfo.frameDelay(unclamped: 0, clamped: 0.1) == 0.1)
        #expect(GIFFileInfo.frameDelay(unclamped: 0.01, clamped: 0.1) == 0.1)
        #expect(GIFFileInfo.frameDelay(unclamped: nil, clamped: 0.07) == 0.07)
        #expect(GIFFileInfo.frameDelay(unclamped: nil, clamped: 0) == 0.1)
        #expect(GIFFileInfo.frameDelay(unclamped: nil, clamped: nil) == 0.1)
    }

    @Test func aPNGIsNotAGIF() throws {
        let png = try write("Picture.png", type: .png, delays: [0])
        #expect(GIFFileInfo.read(png) == nil)
        // Nor is a PNG named like a GIF, or a file that isn't there.
        let renamed = folder.appending(path: "Renamed.gif")
        try FileManager.default.copyItem(at: png, to: renamed)
        #expect(GIFFileInfo.read(renamed) == nil)
        #expect(GIFFileInfo.read(folder.appending(path: "Missing.gif")) == nil)
    }

    /// What opening a file asks before it makes a GIF item: a GIF by its contents, whatever its name says. A PNG or
    /// WebP downloaded under a `.gif` name opens as an image again.
    @Test func aFileIsAGIFByItsContentsNotItsName() throws {
        let gif = try write("Opened.gif", type: .gif, delays: [0.1, 0.2])
        #expect(GIFFileInfo.isGIF(gif))
        let gifNamedPNG = folder.appending(path: "Really a GIF.png")
        try FileManager.default.copyItem(at: gif, to: gifNamedPNG)
        #expect(GIFFileInfo.isGIF(gifNamedPNG))

        let png = try write("Picture.png", type: .png, delays: [0])
        let pngNamedGIF = folder.appending(path: "Download.gif")
        try FileManager.default.copyItem(at: png, to: pngNamedGIF)
        #expect(!GIFFileInfo.isGIF(pngNamedGIF))

        let webp = try ImageEncoder.encode(frame(width: 30, height: 20, gray: 0.5), as: .webp, quality: 0.9)
        let webpNamedGIF = folder.appending(path: "Sticker.gif")
        try webp.write(to: webpNamedGIF)
        #expect(!GIFFileInfo.isGIF(webpNamedGIF))

        #expect(!GIFFileInfo.isGIF(folder.appending(path: "Missing.gif")))
    }
}
