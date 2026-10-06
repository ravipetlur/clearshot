import CoreGraphics
import CoreMedia
import CoreVideo
import CSCore
import Foundation
import ScreenCaptureKit

/// Where a region stream looks: an AppKit region snapped outward to whole pixels of its display.
public struct RegionStreamGeometry: Equatable, Sendable {
    /// Display-local points (top-left origin), on whole pixels: what `SCStreamConfiguration.sourceRect` takes.
    public let sourceRect: CGRect
    public let pixelWidth: Int, pixelHeight: Int
    /// The snapped region, AppKit global points.
    public let globalRect: CGRect

    public static func make(region: CGRect, display: DisplayInfo, layout: DisplayLayout) -> RegionStreamGeometry {
        let pixels = layout.pixelRect(region, in: display)
        let scale = display.scale
        let source = CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
        return RegionStreamGeometry(sourceRect: source, pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height),
                                    globalRect: layout.appKitRect(fromLocal: source, in: display))
    }
}

/// One frame of the region, copied out of ScreenCaptureKit's buffer: rows from the top, `width × 4` bytes each.
public struct RegionFrame: Sendable {
    public let width: Int, height: Int, bytesPerRow: Int
    /// BGRA, premultiplied first, little-endian (`kCVPixelFormatType_32BGRA`).
    public let pixels: [UInt8]
    public let colorSpace: CGColorSpace
}

public enum RegionStreamEvent: Sendable {
    /// The region changed.
    case frame(RegionFrame)
    /// The region didn't change since the last frame.
    case idle
    /// The stream ended by itself (the error says why); nothing follows.
    case stopped((any Error)?)
}

/// A live stream of one screen region, leaving out every ClearShot window: pins, the HUD, thumbnails and the scrolling
/// capture's own windows, including ones that open after the stream starts. (Leaving out pins is the deliberate
/// exception to the rule that pins stay in captures: a scrolling capture stitches what is under them.)
///
/// A stream runs once: `start`, then `stop`. A second `start`, or one after `stop` (or after a `start` that threw), does
/// nothing; make a new stream to try again.
///
/// `handler` never runs on the main actor: frames and idles come on the stream's private serial queue, `.stopped` on
/// ScreenCaptureKit's delegate queue, and calls never overlap. It runs while the stream holds the lock `stop` takes
/// first, so it must return quickly and must never wait on the thread calling `stop` (no `DispatchQueue.main.sync`
/// when the main actor stops the stream). Once `stop` begins it is never called again.
public final class RegionStream: NSObject, @unchecked Sendable {
    private let geometry: RegionStreamGeometry
    private let display: DisplayInfo
    private let ownBundleID: String
    private let handler: @Sendable (RegionStreamEvent) -> Void
    private let queue = DispatchQueue(label: CSCore.identifier("region-stream"), qos: .userInitiated)
    /// Start once, stop, and `handler` called only under its lock with the stream not stopped, so no event can slip out
    /// after `stop` has stopped it.
    private let runner = StreamRunner(name: "Region stream", log: Log.capture, state: ())

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public init(geometry: RegionStreamGeometry, display: DisplayInfo, ownBundleID: String,
                handler: @escaping @Sendable (RegionStreamEvent) -> Void) {
        self.geometry = geometry
        self.display = display
        self.ownBundleID = ownBundleID
        self.handler = handler
    }

    /// Starts streaming. Show ClearShot's windows for the capture first: an app with no window can be missing from the
    /// shareable content (see `filter(on:content:)`).
    public func start() async throws {
        try await runner.start(display: display.id, permissionDenied: CaptureError.permissionDenied,
                               displayNotFound: .displayNotFound, mapError: ScreenCaptureService.map) { content, scDisplay in
            let stream = SCStream(filter: filter(on: scDisplay, content: content), configuration: configuration(),
                                  delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            return stream
        }
    }

    /// Stops the stream and waits until ScreenCaptureKit has. Frames still in flight are dropped.
    public func stop() async {
        await runner.stop()
    }

    // MARK: Private

    /// Leaves out the whole ClearShot app, so windows it opens later are left out too. Should ClearShot be missing from
    /// the applications, its windows of this moment are left out by ID instead.
    private func filter(on display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let clearShot = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        if !clearShot.isEmpty {
            return SCContentFilter(display: display, excludingApplications: clearShot, exceptingWindows: [])
        }
        let windows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleID }
        Log.capture.warning("Region stream: \(ownBundleID) isn't among the shareable applications; "
            + "leaving out its \(windows.count) current windows by ID instead")
        return SCContentFilter(display: display, excludingWindows: windows)
    }

    private func configuration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = geometry.sourceRect
        configuration.width = geometry.pixelWidth
        configuration.height = geometry.pixelHeight
        configuration.scalesToFit = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return configuration
    }

    /// Hands `event` to the handler unless the stream has stopped; `ends` marks it stopped at the same moment.
    private func deliver(_ event: RegionStreamEvent, ends: Bool = false) {
        runner.deliver(ending: ends) { _ in handler(event) }
    }

    static func status(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    /// The buffer's pixels in tight rows (Core Video pads its rows). Keep nothing of ScreenCaptureKit's buffer past the
    /// callback: holding one starves the stream's pool and frames stop coming.
    static func frame(from buffer: CVPixelBuffer) -> RegionFrame? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytesPerRow = width * 4
        let pixels: [UInt8]? = CVPixelBufferGetBaseAddress(buffer).flatMap { base in
            guard width > 0, height > 0, sourceBytesPerRow >= bytesPerRow else { return nil }
            return [UInt8](unsafeUninitializedCapacity: bytesPerRow * height) { copy, count in
                let destination = UnsafeMutableRawPointer(copy.baseAddress!)
                for row in 0..<height {
                    (destination + row * bytesPerRow).copyMemory(from: base + row * sourceBytesPerRow, byteCount: bytesPerRow)
                }
                count = bytesPerRow * height
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        guard let pixels else { return nil }
        let colorSpace = CVBufferCopyAttachments(buffer, .shouldPropagate)
            .flatMap { CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue() } ?? sRGB
        return RegionFrame(width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels, colorSpace: colorSpace)
    }
}

extension RegionStream: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !runner.hasStopped, let status = Self.status(of: sampleBuffer) else { return }
        switch status {
        // A started frame is the stream's first, and as new as a complete one.
        case .complete, .started:
            if let frame = CMSampleBufferGetImageBuffer(sampleBuffer).flatMap(Self.frame(from:)) { deliver(.frame(frame)) }
        case .idle:
            deliver(.idle)
        default:
            break
        }
    }
}

extension RegionStream: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Log.capture.error("Region stream stopped: \(error.localizedDescription)")
        deliver(.stopped(ScreenCaptureService.map(error)), ends: true)
    }
}
