import AVFoundation
import CoreMedia
import CSCore
import Foundation

/// How a video becomes a GIF: Settings › Screen Recording › GIF, and the part of the video to convert.
public struct GIFConversionSettings: Sendable, Equatable {
    /// The "Frame rate" setting; 60 plays at 50 (`GIFSchedule.effectiveFramesPerSecond`).
    public var framesPerSecond: Int
    /// 0…100.
    public var quality: Int
    /// "Optimize GIFs".
    public var optimize: Bool
    /// The part of the video to convert; nil converts it whole.
    public var trim: TrimRange?

    public init(framesPerSecond: Int, quality: Int, optimize: Bool, trim: TrimRange? = nil) {
        self.framesPerSecond = framesPerSecond
        self.quality = quality
        self.optimize = optimize
        self.trim = trim
    }
}

public extension GIFConversionSettings {
    /// The GIF settings as they are now, for `trim` (Trim the GIF… converts again with them).
    @MainActor
    init(preferences: Preferences, trim: TrimRange? = nil) {
        self.init(framesPerSecond: preferences[Prefs.gifFrameRate], quality: preferences[Prefs.gifQuality],
                  optimize: preferences[Prefs.gifOptimize], trim: trim)
    }
}

/// How far a conversion has come: the share of the trim written, and the GIF's size so far.
public struct GIFProgress: Sendable, Equatable {
    public let fraction: Double
    public let bytesWritten: Int64

    public init(fraction: Double, bytesWritten: Int64) {
        self.fraction = fraction
        self.bytesWritten = bytesWritten
    }
}

/// A finished GIF.
public struct GIFConversionResult: Sendable, Equatable {
    public let url: URL
    public let frameCount: Int
    /// Seconds: the sum of its frames' delays.
    public let duration: Double
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteCount: Int64

    public init(url: URL, frameCount: Int, duration: Double, pixelWidth: Int, pixelHeight: Int, byteCount: Int64) {
        self.url = url
        self.frameCount = frameCount
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
    }
}

/// Converts a video to a GIF. `StreamingGIFEncoder` is ClearShot's own; another encoder could stand behind the protocol.
public protocol GIFEncoder: Sendable {
    /// Writes `source`'s trimmed range as a GIF at `destination` (replacing any file there), reporting progress from
    /// any thread. Cancelling the task stops it with `CancellationError` and removes the partial file; any other error
    /// is a `VideoFileError` and leaves nothing either. Never runs on the caller's actor.
    @concurrent
    func convert(_ source: URL, to destination: URL, settings: GIFConversionSettings,
                 progress: @escaping @Sendable (GIFProgress) -> Void) async throws -> GIFConversionResult
}

/// ClearShot's own GIF encoder: the video is read twice with `AVAssetReader` (BGRA, the trimmed range, frame by frame).
/// The first pass counts the colours of frames spread over the trim for one global palette; the second runs each frame
/// through the schedule (`GIFScheduler`), the stabiliser, the quantiser and the writer, which streams to the file.
/// Memory holds the frame being read, the frame the schedule may still show, the viewer state and the frame the writer
/// holds back, whatever the length. The GIF is the video's size: the intermediate was recorded at it. Progress counts
/// both passes (`paletteShare`).
///
/// `AVAssetReaderOutput.Provider.next()` blocks its thread until the reader has a frame, so both passes run on a
/// dispatch queue of their own as the task executor, never on the shared pool (as `RecordingExporter` pumps).
public struct StreamingGIFEncoder: GIFEncoder {
    /// Frames sampled for the palette, spread over the trim: every frame of a clip shorter than twice this, else every
    /// n-th, 48 to 95 of them.
    static let paletteSamples = 48
    /// A sampled frame with more pixels is counted one pixel in a stride × stride square.
    static let palettePixels = 600_000
    /// At most ten progress reports a second.
    static let progressInterval = Duration.milliseconds(100)
    /// The share of the progress the palette pass takes: it only decodes, the second pass encodes too.
    static let paletteShare = 0.2

    public init() {}

    @concurrent
    public func convert(_ source: URL, to destination: URL, settings: GIFConversionSettings,
                        progress: @escaping @Sendable (GIFProgress) -> Void) async throws -> GIFConversionResult {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw VideoFileError.exportFailed("The destination is the source file.")
        }
        try? FileManager.default.removeItem(at: destination)
        do {
            let video = try await Video.load(source)
            let trim = settings.trim ?? TrimRange(start: 0, end: video.duration, duration: video.duration, framesPerSecond: nil)
            let plan = GIFQualityPlan(quality: settings.quality, optimize: settings.optimize)
            let queue = DispatchQueue(label: CSCore.identifier("gif-encoder"), qos: .userInitiated)
            let reporter = Reporter(progress)
            return try await withTaskExecutorPreference(queue) {
                let (palette, size) = try await Self.palette(of: video, trim: trim, plan: plan, reporter: reporter)
                return try await Self.write(video, trim: trim, settings: settings, plan: plan, palette: palette, size: size,
                                            to: destination, reporter: reporter)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw RecordingExporter.mapped(error)
        }
    }

    // MARK: The passes

    /// The source's video track, length and frame rate, for the conversion that loaded it.
    private struct Video {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let duration: Double
        let framesPerSecond: Double

        static func load(_ url: URL) async throws -> Video {
            let asset = AVURLAsset(url: url)
            do {
                let duration = try await asset.load(.duration)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw VideoFileError.noVideoTrack
                }
                let rate = try await track.load(.nominalFrameRate)
                return Video(asset: asset, track: track, duration: duration.seconds, framesPerSecond: Double(rate))
            } catch let error as VideoFileError {
                throw error
            } catch {
                throw VideoFileError.unreadable(error.localizedDescription)
            }
        }
    }

    /// Progress over both passes, at most ten reports a second, never going back, 1 at the end: the palette pass takes
    /// the first `paletteShare` of it, the writing pass the rest, each by its frames' time over the trim's length. Used
    /// by one conversion, on its queue.
    private final class Reporter {
        private let report: @Sendable (GIFProgress) -> Void
        private let clock = ContinuousClock()
        private var last: ContinuousClock.Instant?
        private var fraction = 0.0

        init(_ report: @escaping @Sendable (GIFProgress) -> Void) {
            self.report = report
        }

        /// Frame `time` of `trim` in the palette pass (`writing` false) or the writing pass, with `bytes` written.
        func frame(at time: Double, of trim: TrimRange, writing: Bool, bytes: Int64) {
            let done = min(max((time - trim.start) / max(trim.end - trim.start, 0.001), 0), 1)
            let fraction = max(self.fraction, writing ? paletteShare + (1 - paletteShare) * done : paletteShare * done)
            let now = clock.now
            guard last.map({ now - $0 >= progressInterval }) ?? true else { return }
            last = now
            self.fraction = fraction
            report(GIFProgress(fraction: fraction, bytesWritten: bytes))
        }

        func finished(bytes: Int64) {
            report(GIFProgress(fraction: 1, bytesWritten: bytes))
        }
    }

    /// The first pass: one global palette from frames spread over the trim, and the frames' size.
    private static func palette(of video: Video, trim: TrimRange, plan: GIFQualityPlan, reporter: Reporter) async throws
        -> (GIFPalette, (width: Int, height: Int)) {
        let rate = video.framesPerSecond > 0 ? video.framesPerSecond : 30
        let expected = max(1, Int(((trim.end - trim.start) * rate).rounded()))
        let every = max(1, expected / paletteSamples)
        var histogram = GIFHistogram()
        var size: (width: Int, height: Int)?
        var index = 0
        try await readFrames(of: video, trim: trim) { time, pixels in
            defer { index += 1 }
            reporter.frame(at: time, of: trim, writing: false, bytes: 0)
            guard index % every == 0 else { return }
            let frame = gifFrame(pixels)
            size = size ?? (frame.width, frame.height)
            let pixelCount = frame.width * frame.height
            let step = pixelCount > palettePixels ? Int((Double(pixelCount) / Double(palettePixels)).squareRoot().rounded(.up)) : 1
            histogram.add(frame, step: step)
        }
        guard let size else { throw VideoFileError.exportFailed("The video has no frames to convert.") }
        return (histogram.palette(colors: plan.paletteColors, mergingWithin: plan.threshold), size)
    }

    /// The second pass: every frame through the schedule, the stabiliser, the quantiser and the writer, into the file.
    private static func write(_ video: Video, trim: TrimRange, settings: GIFConversionSettings, plan: GIFQualityPlan,
                              palette: GIFPalette, size: (width: Int, height: Int), to destination: URL,
                              reporter: Reporter) async throws -> GIFConversionResult {
        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil) else {
            throw VideoFileError.exportFailed("The GIF file couldn't be created.")
        }
        let file = try GIFFileOutput(destination)
        defer { file.close() }
        var writer = try GIFWriter(sink: GIFFileSink(output: file), width: size.width, height: size.height,
                                   globalPalette: palette)
        var frames = GIFFrameEncoder(width: size.width, height: size.height, palette: palette, plan: plan)
        var scheduler = GIFScheduler(framesPerSecond: settings.framesPerSecond, trim: trim.start...trim.end)
        // The frame read before the current one, which the schedule shows if no frame comes before its next sample.
        var held: (index: Int, pixels: CVReadOnlyPixelBuffer)?
        // The schedule's last entry so far, already through the stabiliser and the quantiser, waiting for its delay.
        var encoded: (source: Int, frame: GIFFrameEncoder.Encoded?)?
        var totalDelay = 0

        func pixels(of source: Int, current: (index: Int, pixels: CVReadOnlyPixelBuffer)?) throws -> CVReadOnlyPixelBuffer {
            if let current, current.index == source { return current.pixels }
            guard let held, held.index == source else {
                throw VideoFileError.exportFailed("The GIF's schedule asked for a frame it no longer has.")
            }
            return held.pixels
        }
        func encode(_ source: Int, current: (index: Int, pixels: CVReadOnlyPixelBuffer)?) throws {
            let frame = gifFrame(try pixels(of: source, current: current))
            guard frame.width == size.width, frame.height == size.height else {
                throw VideoFileError.exportFailed("The video's frames change size.")
            }
            encoded = (source, frames.encode(frame))
        }
        func show(_ picks: [GIFPick], current: (index: Int, pixels: CVReadOnlyPixelBuffer)?) throws {
            for pick in picks {
                if encoded?.source != pick.sourceIndex { try encode(pick.sourceIndex, current: current) }
                let frame = encoded?.frame
                try writer.add(frame?.diff, indices: frame?.indices ?? [], localPalette: frame?.localPalette,
                               delayCentiseconds: pick.delayCentiseconds)
                totalDelay += pick.delayCentiseconds
            }
            // The entry the schedule ends with now goes through while its frame is at hand.
            if let source = scheduler.pendingSourceIndex, encoded?.source != source {
                try encode(source, current: current)
            }
        }

        var index = 0
        try await readFrames(of: video, trim: trim) { time, pixels in
            let current = (index: index, pixels: pixels)
            try show(scheduler.add(frameAt: time), current: current)
            held = current
            index += 1
            reporter.frame(at: time, of: trim, writing: true, bytes: file.bytesWritten)
        }
        try show(scheduler.finish(), current: nil)
        guard writer.framesWritten > 0 || totalDelay > 0 else {
            throw VideoFileError.exportFailed("The video has no frames to convert.")
        }
        _ = try writer.finish()
        reporter.finished(bytes: file.bytesWritten)
        return GIFConversionResult(url: destination, frameCount: writer.framesWritten, duration: Double(totalDelay) / 100,
                                   pixelWidth: size.width, pixelHeight: size.height, byteCount: file.bytesWritten)
    }

    /// Reads the trimmed range's frames as BGRA, in order, with each one's time in seconds (the first may start before
    /// the trim: it is the frame showing at its start). Stops when the task is cancelled.
    private static func readFrames(of video: Video, trim: TrimRange,
                                   _ body: (Double, CVReadOnlyPixelBuffer) throws -> Void) async throws {
        let reader = try AVAssetReader(asset: video.asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: trim.start, preferredTimescale: 600),
                                       end: CMTime(seconds: trim.end, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: video.track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        guard reader.canAdd(output) else { throw VideoFileError.exportFailed("Couldn't set up the reader.") }
        let provider = reader.outputProvider(for: output)
        try reader.start()
        do {
            while let sample = try await provider.next() {
                try Task.checkCancellation()
                guard case let .pixelBuffer(pixels) = sample.content else { continue }
                try body(sample.presentationTimeStamp.seconds, pixels)
            }
            try Task.checkCancellation()
        } catch {
            reader.cancelReading()
            throw error
        }
    }

    /// A copy of a decoded frame's pixels.
    private static func gifFrame(_ pixels: CVReadOnlyPixelBuffer) -> GIFFrame {
        pixels.accessUnsafeRawPlaneBytes { planes in
            let plane = planes[0]
            return GIFFrame(width: plane.properties.size.width, height: plane.properties.size.height,
                            bytesPerRow: plane.properties.bytesPerRow, bgra: Array(plane.bytes))
        }
    }
}

/// The stabiliser and the quantiser over a GIF's frames, in the order the GIF shows them: what each one changes, as the
/// writer takes it, and the viewer state that follows. Shared by the encoder and its tests.
///
/// The viewer state is the colour shown at each pixel. A pixel needs repainting when what is shown is more than the
/// threshold T from its source on some channel (`GIFStabilizer`; T is 0 with Optimize off). It is repainted with the
/// frame palette's colour for it (dithered as the plan says), and only when that colour is closer to the source than
/// what is shown by more than `repaintMargin` on the farthest channel. So each repaint makes a pixel better, and once
/// content stops every pixel is within the best the frame palettes offer plus the margin: within T plus the margin
/// wherever they reach T. Nothing that went can leave a ghost.
///
/// The frame palette is the global one, unless the global palette leaves at least `localPalettePixels` of the pixels
/// to repaint more than T + margin from their nearest colour (a colour that showed only between the sampled frames).
/// Then the local table last fitted, or one fitted now to the pixels the frame repaints, is weighed against it, and the
/// frame takes the palette that improves what it repaints the most, written as its local table. Only the global
/// palette's lookup and one local table are kept. A table is fitted at most once for the same frame content, so a still
/// screen settles after one repaint at most (where the global palette improves on the table its first frame took); and
/// while content changes, a new table is fitted only when the last one no longer reaches what is repainted.
struct GIFFrameEncoder {
    struct Encoded {
        let diff: GIFDiff
        let indices: [UInt8]
        let localPalette: GIFPalette?
    }

    static let localPalettePixels = 256
    /// Levels on the farthest channel a repaint must gain. The intermediate's decode noise is about ±2, so a smaller
    /// gain is noise, not content; and since every repaint takes at least this off a pixel's error, repaints stop.
    static let repaintMargin = 2

    /// A palette, the indices it gives a frame's rectangle, and each pixel's distance from its source with them.
    private struct Choice {
        let map: GIFColorMap
        let indices: [UInt8]
        let distances: [Int]
    }

    private var stabilizer: GIFStabilizer
    private let global: GIFColorMap
    /// The local table last fitted, and a key to the frame it was fitted on.
    private var local: (content: UInt64, map: GIFColorMap)?
    private let plan: GIFQualityPlan
    private let usesLocalTables: Bool
    /// Local tables fitted so far (reused ones aren't counted again).
    private(set) var localTablesFitted = 0

    /// `localTables` false keeps to the global palette (tests compare with it).
    init(width: Int, height: Int, palette: GIFPalette, plan: GIFQualityPlan, localTables: Bool = true) {
        stabilizer = GIFStabilizer(width: width, height: height, threshold: plan.threshold)
        global = GIFColorMap(palette)
        self.plan = plan
        usesLocalTables = localTables
    }

    /// What `frame` changes on screen, now shown; nil when nothing visible changes.
    mutating func encode(_ frame: GIFFrame) -> Encoded? {
        guard let diff = stabilizer.diff(frame) else { return nil }
        let shown = stabilizer.shownDistances(frame, diff: diff)
        let globalChoice = choice(global, for: frame, over: diff)
        var best = (choice: globalChoice, score: Self.score(globalChoice.distances, diff.changed, shown))
        if usesLocalTables, reachesTooFew(global, frame, diff) {
            func weigh(_ map: GIFColorMap) {
                let candidate = choice(map, for: frame, over: diff)
                let score = Self.score(candidate.distances, diff.changed, shown)
                if score > best.score { best = (candidate, score) }
            }
            if let local { weigh(local.map) }
            // A new table only for content not fitted before, when the last one doesn't reach what is repainted.
            let content = Self.contentKey(frame)
            if local.map({ $0.content != content && reachesTooFew($0.map, frame, diff) }) ?? true {
                var histogram = GIFHistogram()
                histogram.add(frame, changedIn: diff)
                let fitted = GIFColorMap(histogram.palette(colors: plan.paletteColors, mergingWithin: plan.threshold))
                // The table before goes: only one is kept.
                local = (content, fitted)
                localTablesFitted += 1
                weigh(fitted)
            }
        }
        let chosen = best.choice
        let palette = chosen.map.palette
        let paint = shown.map { Self.improving(diff.changed, distances: chosen.distances, over: $0) } ?? diff.changed
        guard let kept = GIFStabilizer.masked(diff, to: paint, indices: chosen.indices,
                                              transparentIndex: UInt8(palette.transparentIndex ?? 0)) else { return nil }
        stabilizer.commit(kept.diff, indices: kept.indices, palette: palette)
        return Encoded(diff: kept.diff, indices: kept.indices, localPalette: chosen.map === global ? nil : palette)
    }

    private func choice(_ map: GIFColorMap, for frame: GIFFrame, over diff: GIFDiff) -> Choice {
        let indices = GIFQuantizer.indices(for: frame, diff: diff, map: map, dither: plan.dithers,
                                           ditherFloor: plan.threshold / 2)
        return Choice(map: map, indices: indices,
                      distances: GIFQuantizer.distances(frame, diff: diff, indices: indices, palette: map.palette))
    }

    /// Whether `map`'s nearest colours leave at least `localPalettePixels` of the pixels to repaint more than T + margin
    /// from their source.
    private func reachesTooFew(_ map: GIFColorMap, _ frame: GIFFrame, _ diff: GIFDiff) -> Bool {
        let nearest = GIFQuantizer.indices(for: frame, diff: diff, map: map, dither: false, ditherFloor: 0)
        let distances = GIFQuantizer.distances(frame, diff: diff, indices: nearest, palette: map.palette)
        return Self.count(diff.changed, distances, beyond: plan.threshold + Self.repaintMargin) >= Self.localPalettePixels
    }

    /// How much a palette (`distances`) improves the pixels to repaint: the levels it gains beyond the margin over what
    /// is `shown`, summed; before anything is shown, the less far it leaves them the better.
    private static func score(_ distances: [Int], _ needed: [Bool], _ shown: [Int]?) -> Int {
        needed.withUnsafeBufferPointer { neededBuffer in
            distances.withUnsafeBufferPointer { distanceBuffer in
                let (needed, distances) = (neededBuffer.baseAddress!, distanceBuffer.baseAddress!)
                var (score, i) = (0, 0)
                if let shown {
                    shown.withUnsafeBufferPointer { shownBuffer in
                        let shown = shownBuffer.baseAddress!
                        while i < neededBuffer.count {
                            if needed[i] {
                                let gain = shown[i] - distances[i] - repaintMargin
                                if gain > 0 { score += gain }
                            }
                            i += 1
                        }
                    }
                } else {
                    while i < neededBuffer.count {
                        if needed[i] { score -= distances[i] }
                        i += 1
                    }
                }
                return score
            }
        }
    }

    /// The pixels to repaint that the new colour (`distances`) brings closer to the source than what is `shown`, by
    /// more than the margin.
    private static func improving(_ needed: [Bool], distances: [Int], over shown: [Int]) -> [Bool] {
        var paint = needed
        paint.withUnsafeMutableBufferPointer { paintBuffer in
            distances.withUnsafeBufferPointer { distanceBuffer in
                shown.withUnsafeBufferPointer { shownBuffer in
                    let (paint, distances, shown) = (paintBuffer.baseAddress!, distanceBuffer.baseAddress!,
                                                     shownBuffer.baseAddress!)
                    var i = 0
                    while i < paintBuffer.count {
                        if paint[i], distances[i] >= shown[i] - repaintMargin { paint[i] = false }
                        i += 1
                    }
                }
            }
        }
        return paint
    }

    /// How many of `needed` are more than `limit` away (`distances`).
    private static func count(_ needed: [Bool], _ distances: [Int], beyond limit: Int) -> Int {
        needed.withUnsafeBufferPointer { neededBuffer in
            distances.withUnsafeBufferPointer { distanceBuffer in
                let (needed, distances) = (neededBuffer.baseAddress!, distanceBuffer.baseAddress!)
                var (count, i) = (0, 0)
                while i < neededBuffer.count {
                    if needed[i], distances[i] > limit { count += 1 }
                    i += 1
                }
                return count
            }
        }
    }

    /// A key to the whole frame's pixels (FNV-1a over 8-byte words), so a table is fitted once for the same content.
    private static func contentKey(_ frame: GIFFrame) -> UInt64 {
        frame.bgra.withUnsafeBytes { bytes in
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            let words = bytes.count / 8
            var i = 0
            while i < words {
                hash = (hash ^ bytes.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) &* 0x100_0000_01B3
                i += 1
            }
            i = words * 8
            while i < bytes.count {
                hash = (hash ^ UInt64(bytes[i])) &* 0x100_0000_01B3
                i += 1
            }
            return hash
        }
    }
}

/// The GIF file, and how much has been written to it. Used by one conversion at a time, on its queue.
final class GIFFileOutput {
    private let handle: FileHandle
    private(set) var bytesWritten: Int64 = 0

    init(_ url: URL) throws {
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw VideoFileError.exportFailed(error.localizedDescription)
        }
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        try handle.write(contentsOf: Data(bytes))
        bytesWritten += Int64(bytes.count)
    }

    func close() {
        try? handle.close()
    }
}

/// The writer's sink for a `GIFFileOutput`.
struct GIFFileSink: GIFByteSink {
    let output: GIFFileOutput

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        try output.write(bytes)
    }
}
