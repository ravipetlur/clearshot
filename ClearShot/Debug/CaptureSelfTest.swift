#if DEBUG
import AppKit
import CoreGraphics
import CoreMedia
import CoreText
import CSCapture
import CSCore
import CSOCR
import CSRecording
import Foundation
import ImageIO
import Synchronization

/// Exercises the real capture pipeline with real permissions. Debug builds only; run it after changing the capture
/// pipeline.
enum CaptureSelfTest {
    /// Largest mean per-channel difference (0–255) allowed between an area capture and the same crop of a display capture.
    private static let areaTolerance = 12.0

    /// What selftest.txt starts with: when, which build, and the displays the checks ran against.
    static func header(date: Date = Date()) -> [String] {
        var lines = ["ClearShot capture self-test \(date.formatted(.iso8601))", "ClearShot \(Bundle.main.versionString)"]
        for display in DisplayLayout.current().displays {
            let size = display.pixelSize
            let frame = display.frame
            lines.append("display \(display.id) (\(display.name)): scale \(number(display.scale)), "
                + "\(number(size.width))×\(number(size.height)) px, "
                + "frame \(number(frame.minX)),\(number(frame.minY)) \(number(frame.width))×\(number(frame.height)) pt")
        }
        return lines
    }

    static func run(service: ScreenCaptureService) async -> [String] {
        var lines: [String] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            lines.append("\(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
        let layout = DisplayLayout.current()
        let rules = ExclusionRules(ownBundleID: CSCore.bundleIdentifier, keepOwnWindowIDs: [], hideDesktopIcons: true)

        for display in layout.displays {
            let expectedWidth = pixels(display.pixelSize.width)
            let expectedHeight = pixels(display.pixelSize.height)

            // Display: right size, and not a blank frame.
            var displayImage: CGImage?
            let displayName = "display \(display.id) (\(display.name))"
            do {
                let image = try await service.captureDisplay(display, rules: rules, showsCursor: false)
                displayImage = image
                let blank = !ImageProbe.hasContent(image)
                check(displayName, image.width == expectedWidth && image.height == expectedHeight && !blank,
                      detail("\(image.width)×\(image.height), expected \(expectedWidth)×\(expectedHeight)", blank: blank))
            } catch {
                check(displayName, false, "\(error)")
            }

            // Area: off-centre, so a top-left/bottom-left mix-up lands on different pixels; compared with the same
            // rectangle cropped out of a display capture.
            let areaName = "area on display \(display.id)"
            let local = CGRect(x: display.frame.width * 0.1, y: display.frame.height * 0.15, width: 400, height: 300)
            if CGRect(origin: .zero, size: display.frame.size).contains(local) {
                let pixelArea = layout.pixelRect(layout.appKitRect(fromLocal: local, in: display), in: display)
                let areaWidth = pixels(local.width * display.scale)
                let areaHeight = pixels(local.height * display.scale)
                func measureArea(against reference: CGImage) async throws -> (image: CGImage, difference: Double?) {
                    let area = try await service.captureArea(local, on: display, rules: rules, showsCursor: false)
                    let difference = PostProcessor.cropped(reference, to: pixelArea).flatMap {
                        ImageProbe.meanAbsoluteDifference(of: area, and: $0)
                    }
                    return (area, difference)
                }
                do {
                    let reference: CGImage
                    if let displayImage {
                        reference = displayImage
                    } else {
                        reference = try await service.captureDisplay(display, rules: rules, showsCursor: false)
                    }
                    var measured = try await measureArea(against: reference)
                    if measured.difference.map({ $0 > areaTolerance }) ?? true {
                        // The screen may have changed between the two captures: look once more, with both taken afresh.
                        let fresh = try await service.captureDisplay(display, rules: rules, showsCursor: false)
                        measured = try await measureArea(against: fresh)
                    }
                    let image = measured.image
                    let blank = !ImageProbe.hasContent(image)
                    let differenceDetail = measured.difference.map { "MAD \(String(format: "%.1f", $0)) against the display capture (max \(Int(areaTolerance)))" }
                        ?? "could not compare with the display capture"
                    check(areaName, image.width == areaWidth && image.height == areaHeight
                            && (measured.difference ?? .infinity) <= areaTolerance && !blank,
                          detail("\(image.width)×\(image.height), expected \(areaWidth)×\(areaHeight), \(differenceDetail)", blank: blank))
                } catch {
                    check(areaName, false, "\(error)")
                }
            } else {
                check(areaName, false, "display too small for the 400×300 pt test area")
            }

            // Wallpaper: the display's own size, and not a blank frame.
            let wallpaperName = "wallpaper for display \(display.id)"
            do {
                if let wallpaper = try await service.captureWallpaper(displayCGFrame: layout.cgRect(fromAppKit: display.frame)) {
                    let blank = !ImageProbe.hasContent(wallpaper)
                    check(wallpaperName, wallpaper.width == expectedWidth && wallpaper.height == expectedHeight && !blank,
                          detail("\(wallpaper.width)×\(wallpaper.height), expected \(expectedWidth)×\(expectedHeight)", blank: blank))
                } else {
                    check(wallpaperName, false, "none")
                }
            } catch {
                check(wallpaperName, false, "\(error)")
            }
        }

        // Window: without a shadow it is the window's own size in pixels, with one it is larger in both directions.
        let windows = WindowList.onScreen()
        let target = windows.first {
            $0.layer == 0 && $0.alpha >= 0.99 && !($0.title ?? "").isEmpty
                && $0.ownerBundleID != CSCore.bundleIdentifier && $0.frame.width > 100
        }
        if let target {
            let windowName = "window \(target.ownerName)"
            let scale = layout.display(bestMatching: layout.appKitRect(fromCG: target.frame))?.scale ?? 2
            let expectedWidth = pixels(target.frame.width * scale)
            let expectedHeight = pixels(target.frame.height * scale)
            do {
                let withShadow = try await service.captureWindow(id: target.id, includeShadow: true)
                let without = try await service.captureWindow(id: target.id, includeShadow: false)
                let sizeMatches = abs(without.width - expectedWidth) <= 2 && abs(without.height - expectedHeight) <= 2
                let shadowAdds = withShadow.width > without.width && withShadow.height > without.height
                let blank = !(ImageProbe.hasContent(withShadow) && ImageProbe.hasContent(without))
                var text = "with shadow \(withShadow.width)×\(withShadow.height), without \(without.width)×\(without.height), "
                    + "expected without \(expectedWidth)×\(expectedHeight) (\(number(target.frame.width))×\(number(target.frame.height)) pt × \(number(scale)))"
                if !sizeMatches { text += "; without shadow is not the window's size" }
                if !shadowAdds { text += "; with shadow is not larger in both directions" }
                check(windowName, sizeMatches && shadowAdds && !blank, detail(text, blank: blank))
            } catch {
                check(windowName, false, "\(error)")
            }
        } else {
            check("window", false, "no titled, opaque, normal window on screen")
        }

        let sample = try? await service.captureArea(CGRect(x: 0, y: 0, width: 200, height: 100), on: layout.main, rules: rules, showsCursor: false)
        for format in ImageFormat.allCases {
            guard let sample, let data = try? ImageEncoder.encode(sample, as: format, quality: 0.9),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                check("encode \(format.title)", false)
                continue
            }
            check("encode \(format.title)", decoded.width == sample.width, "\(data.count) bytes")
        }
        if let sample {
            let directory = FileManager.default.temporaryDirectory.appending(path: "ClearShotSelfTest", directoryHint: .isDirectory)
            do {
                let tag = ScreenCaptureTag(kind: .selection, globalRect: CGRect(x: 0, y: 0, width: 200, height: 100))
                let url = try Exporter.save(ExportRequest(image: sample, format: .png, quality: 1,
                                                          pixelsPerPoint: Double(layout.main.scale), directory: directory,
                                                          template: .standard, nameContext: FileNameContext(),
                                                          retinaSuffix: false, screenCapture: tag))
                check("export and metadata", ScreenCaptureMetadata.isScreenCapture(url)
                      && ScreenCaptureMetadata.globalRect(url) == tag.globalRect, url.lastPathComponent)
            } catch {
                check("export and metadata", false, "\(error)")
            }
        }

        // OCR: a drawn line reads back, with fixed language options so the check doesn't depend on Settings.
        if let page = textPage("ClearShot self-test 12345") {
            do {
                let options = TextRecognitionOptions(automaticallyDetectsLanguage: true, primaryLanguage: "en-US")
                let read = TextOutput.text(for: try await TextRecognizer.recognize(page, options: options), keepLineBreaks: false)
                let passed = read.contains("12345")
                check("ocr", passed, passed ? "" : (read.isEmpty ? "no text read" : "“\(read)”"))
            } catch {
                check("ocr", false, "\(error)")
            }
        } else {
            check("ocr", false, "couldn't draw the test text")
        }

        for result in await regionStreamResults(service: service, layout: layout) {
            check(result.name, result.passed, result.detail)
        }
        for result in await recordingResults(layout: layout) {
            check(result.name, result.passed, result.detail)
        }
        return lines
    }

    /// The region stream on the main display, streamed for about a second over a 400 × 300 pt region. Once it runs, a
    /// red ClearShot panel 200 × 200 pt opens in the region's middle (app-level exclusion must leave out windows that
    /// open later). A screenshot that keeps the panel must show it, so a panel that never appeared can't pass; the last
    /// frame must be the region's pixel size and match a capture of the region without ClearShot's windows, which proves
    /// placement, byte order and colour as well as exclusion.
    private static func regionStreamResults(service: ScreenCaptureService,
                                            layout: DisplayLayout) async -> [(name: String, passed: Bool, detail: String)] {
        let sizeName = "region stream size"
        let exclusionName = "region stream leaves out ClearShot windows"
        let display = layout.main
        let local = CGRect(x: 200, y: 200, width: 400, height: 300)
        let region = layout.appKitRect(fromLocal: local, in: display)
        let geometry = RegionStreamGeometry.make(region: region, display: display, layout: layout)

        let probe = RegionStreamProbe()
        let stream = RegionStream(geometry: geometry, display: display, ownBundleID: CSCore.bundleIdentifier) { probe.receive($0) }
        do {
            try await stream.start()
        } catch {
            return [(sizeName, false, "\(error)"), (exclusionName, false, "\(error)")]
        }
        let panel = redPanel(frame: CGRect(x: region.midX - 100, y: region.midY - 100, width: 200, height: 200))
        panel.orderFrontRegardless()
        defer { panel.close() }
        // Let the window server draw it.
        try? await Task.sleep(for: .milliseconds(200))
        let keepPanel = ExclusionRules(ownBundleID: CSCore.bundleIdentifier, keepOwnWindowIDs: [UInt32(panel.windowNumber)],
                                       hideDesktopIcons: false)
        let shown = try? await service.captureArea(local, on: display, rules: keepPanel, showsCursor: false)
        try? await Task.sleep(for: .milliseconds(800))
        // Taken just before the stream stops. Desktop icons stay, as they do in the stream.
        let withoutClearShot = ExclusionRules(ownBundleID: CSCore.bundleIdentifier, keepOwnWindowIDs: [], hideDesktopIcons: false)
        let reference = try? await service.captureArea(local, on: display, rules: withoutClearShot, showsCursor: false)
        await stream.stop()
        let received = probe.received
        let stopped = received.error.map { "; the stream stopped: \($0)" } ?? ""

        guard let last = received.last else {
            return [(sizeName, false, "no frames\(stopped)"), (exclusionName, false, "no frames\(stopped)")]
        }
        let sizeMatches = last.width == geometry.pixelWidth && last.height == geometry.pixelHeight
        let colorSpace = (last.colorSpace.name as String?) ?? "unnamed"
        let size = (sizeName, sizeMatches,
                    "\(received.frames) frames of \(last.width)×\(last.height), expected \(geometry.pixelWidth)×\(geometry.pixelHeight), "
                        + "colour space \(colorSpace)\(stopped)")

        let streamed = regionFrameImage(last)
        let shownCentre = shown.flatMap(centreColour)
        let streamedCentre = streamed.flatMap(centreColour)
        let difference = streamed.flatMap { streamed in reference.flatMap { ImageProbe.meanAbsoluteDifference(of: streamed, and: $0) } }
        let exclusion: (String, Bool, String)
        if let shownCentre, !isRed(shownCentre) {
            exclusion = (exclusionName, false, "the test panel didn't show: its centre is \(rgb(shownCentre)) in a screenshot that keeps it")
        } else if let shownCentre, let streamedCentre, let difference {
            let passed = difference <= areaTolerance && !isRed(streamedCentre)
            exclusion = (exclusionName, passed,
                         "MAD \(String(format: "%.1f", difference)) against a capture without ClearShot's windows (max \(Int(areaTolerance))); "
                            + "the panel's centre is \(rgb(streamedCentre)) streamed, \(rgb(shownCentre)) in a screenshot that keeps it")
        } else {
            exclusion = (exclusionName, false, "couldn't capture the region to compare with the stream")
        }
        return [size, exclusion]
    }

    /// The recording pipeline (stream, writer, file) on the main display, without audio. A red ClearShot panel 200 ×
    /// 200 pt opens 200 pt in from the display's top-left, before the stream starts, as the click overlay does. A 3 s
    /// recording of the 400 × 300 pt region around it, keeping the panel's window, must have at least two frames, last
    /// 3 s and be the planned size, and its first frame must show the panel; a 1 s recording that doesn't keep it must
    /// not. The files go to a temporary folder that is removed afterwards.
    private static func recordingResults(layout: DisplayLayout) async -> [(name: String, passed: Bool, detail: String)] {
        let sizeName = "recording stream size"
        let keptName = "recording keeps an excepted ClearShot window"
        let leftOutName = "recording leaves out other ClearShot windows"
        let display = layout.main
        let panelLocal = CGRect(x: 200, y: 200, width: 200, height: 200)
        let regionLocal = panelLocal.insetBy(dx: -100, dy: -50)
        let plan = EncoderPlan.make(regionPoints: regionLocal.size, scale: display.scale, scaleRetinaTo1x: false,
                                    maxResolution: .original, framesPerSecond: 30, hardwareEncoding: true)
        let region = layout.appKitRect(fromLocal: regionLocal, in: display)
        let settings = RecordingStreamSettings.make(region: region, display: display, layout: layout, width: plan.width,
                                                    height: plan.height, framesPerSecond: plan.framesPerSecond,
                                                    showsCursor: false, systemAudio: false, mono: false)
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClearShotRecordingSelfTest-\(UUID().uuidString)",
                                                                      directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return [(sizeName, false, "\(error)"), (keptName, false, "\(error)"), (leftOutName, false, "\(error)")]
        }

        let panel = redPanel(frame: layout.appKitRect(fromLocal: panelLocal, in: display))
        panel.orderFrontRegardless()
        defer { panel.close() }
        // Windows first, then the content the stream fetches.
        try? await Task.sleep(for: .milliseconds(200))
        let panelID = UInt32(panel.windowNumber)

        var results: [(name: String, passed: Bool, detail: String)] = []
        do {
            let take = try await recordTestTake(settings: settings, plan: plan, keeping: [panelID], seconds: 3,
                                                to: folder.appending(path: "kept.mp4"))
            let sizeMatches = take.info.pixelWidth == plan.width && take.info.pixelHeight == plan.height
            let frames = take.result.statistics.appendedFrames
            let passed = sizeMatches && frames >= 2 && abs(take.info.duration - 3) <= 0.2
            let seconds = { String(format: "%.3f", $0) }
            results.append((sizeName, passed,
                            "\(frames) frames of \(take.info.pixelWidth)×\(take.info.pixelHeight) over "
                                + "\(seconds(take.info.duration)) s (written \(seconds(take.result.duration)) s), "
                                + "expected ≥ 2 of \(plan.width)×\(plan.height) over 3.0 ± 0.2 s\(take.stopNote)"))
            let centre = centreColour(of: take.firstFrame)
            results.append((keptName, centre.map(isRed) ?? false,
                            centre.map { "the panel's centre is \(rgb($0)) in the recording" }
                                ?? "couldn't read the recording's centre"))
        } catch {
            results.append((sizeName, false, "\(error)"))
            results.append((keptName, false, "\(error)"))
        }
        do {
            let take = try await recordTestTake(settings: settings, plan: plan, keeping: [], seconds: 1,
                                                to: folder.appending(path: "left-out.mp4"))
            let centre = centreColour(of: take.firstFrame)
            results.append((leftOutName, centre.map { !isRed($0) } ?? false,
                            centre.map { "the panel's centre is \(rgb($0)) in the recording\(take.stopNote)" }
                                ?? "couldn't read the recording's centre"))
        } catch {
            results.append((leftOutName, false, "\(error)"))
        }
        return results
    }

    /// What a test recording wrote.
    private struct RecordingTake {
        let result: RecordingWriterResult
        let info: VideoSourceInfo
        let firstFrame: CGImage
        /// Why the stream ended by itself, if it did.
        let stopNote: String
    }

    /// Records `seconds` of the region into `url` through `ScreenRecordingStream` and `RecordingWriter`, keeping the
    /// ClearShot windows `kept`, as a recording does: the session starts at the stream's clock once it runs; the stop
    /// time is read before the stream stops, and the writer finishes after it has.
    private static func recordTestTake(settings: RecordingStreamSettings, plan: EncoderPlan, keeping kept: Set<UInt32>,
                                       seconds: Double, to url: URL) async throws -> RecordingTake {
        let writer = try RecordingWriter(configuration: RecordingWriterConfiguration(fileURL: url, plan: plan, systemAudio: nil,
                                                                                     microphone: nil))
        let rules = RecordingContentRules(ownBundleID: CSCore.bundleIdentifier, keptOwnWindowIDs: kept,
                                          exclusion: ExclusionRules(ownBundleID: CSCore.bundleIdentifier, keepOwnWindowIDs: [],
                                                                    hideDesktopIcons: false))
        let stops = RecordingStopProbe()
        let stream = ScreenRecordingStream(settings: settings, rules: rules, sampleQueue: writer.queue, onOutput: { output in
            switch output {
            case let .frame(frame, presentationTime): writer.appendVideo(frame, at: presentationTime)
            case let .systemAudio(chunk): writer.appendSystemAudio(chunk)
            }
        }, onStop: { reason, _ in stops.record(reason) })
        do {
            try await stream.start()
        } catch {
            await writer.cancel()
            throw error
        }
        guard let start = stream.currentTime else {
            await stream.stop()
            await writer.cancel()
            throw SelfTestError("the stream has no clock")
        }
        writer.start(at: start)
        try? await Task.sleep(for: .seconds(seconds))
        let stop = stream.currentTime ?? start + CMTime(seconds: seconds, preferredTimescale: 600)
        await stream.stop()
        let result = try await writer.finish(at: stop)
        let info = try await VideoThumbnail.info(of: url)
        let firstFrame = try await VideoThumbnail.image(of: url, maximumPixel: max(plan.width, plan.height))
        return RecordingTake(result: result, info: info, firstFrame: firstFrame,
                             stopNote: stops.reason.map { "; the stream stopped: \($0)" } ?? "")
    }

    private struct SelfTestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func redPanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        panel.isOpaque = true
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    /// A region frame as an image in its own colour space.
    private static func regionFrameImage(_ frame: RegionFrame) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(frame.pixels) as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: frame.bytesPerRow, space: frame.colorSpace, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The image's centre pixel in sRGB, as RGBA bytes.
    private static func centreColour(of image: CGImage) -> [UInt8]? {
        image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1))
            .flatMap { ImageProbe.thumbnail($0, width: 1, height: 1) }
    }

    /// Red enough to be the test panel, allowing for colour management on the way to the screen and back.
    private static func isRed(_ rgba: [UInt8]) -> Bool {
        rgba[0] >= 180 && rgba[1] <= 90 && rgba[2] <= 90
    }

    private static func rgb(_ rgba: [UInt8]) -> String {
        "rgb(\(rgba[0]), \(rgba[1]), \(rgba[2]))"
    }

    /// `string` in black Helvetica 48 pt on an 800 × 200 white picture.
    private static func textPage(_ string: String) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 800, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 200))
        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]))
        context.textPosition = CGPoint(x: 40, y: 84)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    private static func pixels(_ value: CGFloat) -> Int {
        Int(value.rounded())
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%g", Double(value))
    }

    private static func detail(_ text: String, blank: Bool) -> String {
        blank ? "\(text); blank image" : text
    }
}

/// Why a self-test recording's stream ended by itself: written on ScreenCaptureKit's delegate queue, read after the
/// stream has stopped.
nonisolated private final class RecordingStopProbe: Sendable {
    private let state = Mutex<RecordingStreamStop?>(nil)

    var reason: RecordingStreamStop? {
        state.withLock { $0 }
    }

    func record(_ reason: RecordingStreamStop) {
        state.withLock { $0 = reason }
    }
}

/// What the region stream delivered during the self-test: written on the stream's queue, read once it has stopped.
nonisolated private final class RegionStreamProbe: Sendable {
    private let state = Mutex<(frames: Int, last: RegionFrame?, error: (any Error)?)>((0, nil, nil))

    var received: (frames: Int, last: RegionFrame?, error: (any Error)?) {
        state.withLock { $0 }
    }

    func receive(_ event: RegionStreamEvent) {
        state.withLock { state in
            switch event {
            case .frame(let frame):
                state.frames += 1
                state.last = frame
            case .idle:
                break
            case .stopped(let error):
                state.error = error
            }
        }
    }
}
#endif
