import Foundation
import ImageIO
import Testing
@testable import CSRecording

/// The streaming GIF89a writer with the stabiliser and the quantiser in front, on the fixtures' scene at 800 × 450,
/// with ImageIO decoding the result.
struct GIFWriterTests {
    typealias Fixtures = GIFFixtures

    /// Quality 100 with Optimize on.
    let bestPlan = GIFQualityPlan(quality: 100, optimize: true)

    @Test func framesDelaysAndLoopRoundTrip() throws {
        let colors: [UInt32] = (0..<30).map { (index: Int) -> UInt32 in
            let red = UInt32(index * 8) << 16
            let green = UInt32(240 - index * 8) << 8
            return red | green | 0x40
        }
        let palette = GIFPalette(colors: colors, transparentIndex: 30)
        let delays = (0..<30).map { [3, 4, 3, 2, 10, 25][$0 % 6] }
        var writer = try GIFWriter(sink: MemorySink(), width: 40, height: 30, globalPalette: palette)
        for index in 0..<30 {
            // Each frame repaints a different square in its own colour.
            let rect = GIFRect(x: index % 5 * 8, y: index / 5 % 3 * 10, width: 8, height: 10)
            try writer.add(GIFDiff(rect: rect, changed: Array(repeating: true, count: 80)),
                           indices: Array(repeating: UInt8(index), count: 80), localPalette: nil,
                           delayCentiseconds: delays[index])
        }
        let source = Fixtures.source(Data(try writer.finish().bytes))
        #expect(CGImageSourceGetCount(source) == 30)
        #expect(Fixtures.delays(source) == delays)
        #expect(Fixtures.loopCount(source) == 0)
    }

    /// Planner note "PSNR oracle": at least 42 dB, against the prototype's 39.3 (ImageIO's own: 46.7). Measured on frames
    /// the palette wasn't sampled from (it takes every tenth from 0).
    @Test func qualityBeatsThePrototype() throws {
        let plan = GIFQualityPlan(threshold: 0, paletteColors: 255, dithers: false)
        let data = try Fixtures.encode(count: 120, plan: plan) { Fixtures.scene($0) }
        let source = Fixtures.source(data)
        #expect(CGImageSourceGetCount(source) == 120)
        let values = [15, 65, 115].map { Fixtures.psnr(Fixtures.scene($0), Fixtures.decoded(source, at: $0).rgba) }
        let mean = values.reduce(0, +) / Double(values.count)
        print("GIF quality: PSNR \(values.map { String(format: "%.2f", $0) }) dB, mean \(String(format: "%.2f", mean)) dB, "
            + "\(data.count) bytes for 120 frames")
        #expect(mean >= 42)
    }

    @Test func ditheringBreaksUpBanding() {
        let gradient = Fixtures.frame(width: 800, height: 8) { x, _ in
            let level = UInt32(x * 255 / 799)
            return level << 16 | level << 8 | level
        }
        let palette = GIFQuantizer.palette(from: [gradient], colors: 32)
        let diff = GIFDiff(rect: GIFRect(x: 0, y: 0, width: 800, height: 8), changed: Array(repeating: true, count: 6400))
        func longestRun(_ indices: [UInt8]) -> Int {
            var (longest, run) = (1, 1)
            for x in 1..<800 {
                run = indices[x] == indices[x - 1] ? run + 1 : 1
                longest = max(longest, run)
            }
            return longest
        }
        let plain = longestRun(GIFQuantizer.indices(for: gradient, diff: diff, palette: palette, dither: false))
        let dithered = longestRun(GIFQuantizer.indices(for: gradient, diff: diff, palette: palette, dither: true))
        #expect(dithered * 2 <= plain)
    }

    /// The writer's memory doesn't grow with the frame count (ImageIO's took 3.9 GB here).
    @Test func aThousandFramesStayWithinABoundedBuffer() throws {
        var buffered: [Int: Int] = [:]
        let sink = try Fixtures.encode(count: 1000, plan: bestPlan, delay: 2, into: CountingSink(),
                                       afterFrame: { index, writer in
                                           if index == 9 || index == 999 { buffered[index + 1] = writer.bufferedBytes }
                                       }, frame: { Fixtures.scene($0) })
        let (early, late) = (try #require(buffered[10]), try #require(buffered[1000]))
        #expect(sink.count > 0)
        #expect(abs(late - early) < 64 * 1024)
        #expect(max(early, late) <= 3 * 800 * 450 + 1_048_576)
    }

    /// ±2 noise on every channel grew ImageIO's GIF 43×; the threshold at quality 100 keeps it near the clean one.
    ///
    /// Little headroom: this seeded fixture measured 1.86× when written, and other noise seeds 1.92–1.99×, against the
    /// bar of 2×. What noise costs is the moving shadow ramp's indices turning random. A change to the palette or the
    /// stabiliser may tip it; then the bar is reconsidered, never a retuned seed.
    @Test func decodeNoiseDoesNotBlowUpTheFile() throws {
        let clean = try Fixtures.encode(count: 120, plan: bestPlan) { Fixtures.scene($0) }
        let noisy = try Fixtures.encode(count: 120, plan: bestPlan) { Fixtures.scene($0, noise: 2) }
        #expect(noisy.count <= 2 * clean.count)
    }

    /// A colourful area that appears after the frames the palette was sampled from (a photo, a video, a dialog) gets a
    /// local table instead of the global palette's nearest colours.
    @Test func coloursThePaletteMissedGetALocalTable() throws {
        let first = Fixtures.scene(0)
        var bytes = first.bgra
        for y in 100..<300 {
            for x in 400..<700 {
                let hue = Double(x - 400) / 300 * 3.1
                let offset = y * first.bytesPerRow + x * 4
                bytes[offset + 2] = UInt8(abs(sin(hue)) * 255)
                bytes[offset + 1] = UInt8(abs(sin(hue + 2.1)) * 255)
                bytes[offset] = UInt8(abs(sin(hue + 4.2)) * 255)
            }
        }
        let late = GIFFrame(width: 800, height: 450, bytesPerRow: first.bytesPerRow, bgra: bytes)
        let palette = GIFQuantizer.palette(from: [first], colors: bestPlan.paletteColors, mergingWithin: bestPlan.threshold)
        var encoder = GIFFrameEncoder(width: 800, height: 450, palette: palette, plan: bestPlan)
        var writer = try GIFWriter(sink: MemorySink(), width: 800, height: 450, globalPalette: palette)
        var localTables: [Bool] = []
        for frame in [first, late] {
            let encoded = encoder.encode(frame)
            localTables.append(encoded?.localPalette != nil)
            try writer.add(encoded?.diff, indices: encoded?.indices ?? [], localPalette: encoded?.localPalette,
                           delayCentiseconds: 10)
        }
        #expect(localTables == [false, true])
        let source = Fixtures.source(Data(try writer.finish().bytes))
        #expect(Fixtures.psnr(late, Fixtures.decoded(source, at: 1).rgba) >= 40)
    }

    /// A still screen with colourful content settles: written once when the global palette has its colours, the same as
    /// without local tables; when it misses them, the first frame takes a table fitted to it and one repaint follows at
    /// most (that table is coarser than the global palette on what the global palette has), and nothing after, with
    /// Optimize on or off.
    @Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
    func aStillColourfulFrameSettlesAfterAtMostOneRepaint(paletteHasItsColours: Bool, optimize: Bool) throws {
        let plan = GIFQualityPlan(quality: 100, optimize: optimize)
        let still = Fixtures.withPhoto(Fixtures.scene(0))
        let sample = paletteHasItsColours ? still : Fixtures.scene(0)
        let palette = GIFQuantizer.palette(from: [sample], colors: plan.paletteColors, mergingWithin: plan.threshold)
        func encode(frames: Int, localTables: Bool) throws -> (written: [Bool], frameCount: Int, bytes: Int) {
            var encoder = GIFFrameEncoder(width: 800, height: 450, palette: palette, plan: plan, localTables: localTables)
            var writer = try GIFWriter(sink: MemorySink(), width: 800, height: 450, globalPalette: palette)
            var written: [Bool] = []
            for _ in 0..<frames {
                let encoded = encoder.encode(still)
                written.append(encoded != nil)
                try writer.add(encoded?.diff, indices: encoded?.indices ?? [], localPalette: encoded?.localPalette,
                               delayCentiseconds: 2)
            }
            let data = Data(try writer.finish().bytes)
            return (written, CGImageSourceGetCount(Fixtures.source(data)), data.count)
        }
        let settled = try encode(frames: 16, localTables: true)
        let once = try encode(frames: 1, localTables: true)
        #expect(settled.written.first == true)
        #expect(settled.written.dropFirst(2).allSatisfy { !$0 })
        if paletteHasItsColours {
            #expect(settled.written == [true] + Array(repeating: false, count: 15))
            #expect(settled.frameCount == 1)
            #expect(settled.bytes <= once.bytes + 16)
            let off = try encode(frames: 16, localTables: false)
            #expect(Double(settled.bytes) <= Double(off.bytes) * 1.1)
        } else {
            #expect(settled.frameCount <= 2)
            #expect(Double(settled.bytes) <= Double(once.bytes) * 1.2)
        }
    }

    /// A colourful region painted with a local table, then gone again (a dialog closing), is repainted with what is
    /// under it, even where the local table would give the new pixels the colour shown: that colour is wrong for them.
    @Test func aRegionThatGoesIsRepaintedOverItsLocalTable() throws {
        let scene = Fixtures.scene(0)
        let palette = GIFQuantizer.palette(from: [scene], colors: bestPlan.paletteColors, mergingWithin: bestPlan.threshold)
        var encoder = GIFFrameEncoder(width: 800, height: 450, palette: palette, plan: bestPlan)
        var writer = try GIFWriter(sink: MemorySink(), width: 800, height: 450, globalPalette: palette)
        var localTables: [Bool] = []
        for frame in [scene, Fixtures.withPhoto(scene), scene] {
            let result = encoder.encode(frame)
            let encoded = try #require(result)
            localTables.append(encoded.localPalette != nil)
            try writer.add(encoded.diff, indices: encoded.indices, localPalette: encoded.localPalette, delayCentiseconds: 10)
        }
        #expect(localTables == [false, true, false])
        let source = Fixtures.source(Data(try writer.finish().bytes))
        let first = Fixtures.decoded(source, at: 0).rgba
        let last = Fixtures.decoded(source, at: 2).rgba
        #expect(first == last)
    }

    /// A caller's bad frame is refused rather than written undecodable: an index past the colour table, or a delay no
    /// frame can carry (over 655.35 s with no transparent index to go on in empty frames).
    @Test func badFramesAreRefused() throws {
        let whole = GIFDiff(rect: GIFRect(x: 0, y: 0, width: 4, height: 4), changed: Array(repeating: true, count: 16))
        // Two colours and the transparent index: a table of 4.
        let palette = GIFPalette(colors: [0xFF_0000, 0x00_FF00], transparentIndex: 2)
        var writer = try GIFWriter(sink: MemorySink(), width: 4, height: 4, globalPalette: palette)
        #expect(throws: GIFWriterError.invalidFrame) {
            try writer.add(whole, indices: Array(repeating: 4, count: 16), localPalette: nil, delayCentiseconds: 3)
        }
        try writer.add(whole, indices: Array(repeating: 3, count: 16), localPalette: nil, delayCentiseconds: 3)

        let opaque = GIFPalette(colors: [0xFF_0000, 0x00_FF00], transparentIndex: nil)
        var opaqueWriter = try GIFWriter(sink: MemorySink(), width: 4, height: 4, globalPalette: opaque)
        #expect(throws: GIFWriterError.invalidFrame) {
            try opaqueWriter.add(whole, indices: Array(repeating: 0, count: 16), localPalette: nil, delayCentiseconds: 70_000)
        }
        try opaqueWriter.add(whole, indices: Array(repeating: 0, count: 16), localPalette: nil, delayCentiseconds: 60_000)
        #expect(throws: GIFWriterError.invalidFrame) {
            try opaqueWriter.add(nil, indices: [], localPalette: nil, delayCentiseconds: 10_000)
        }
    }

    /// With a transparent index, a delay longer than one frame can carry goes on in 1 × 1 frames that change nothing.
    @Test func aLongDelayGoesOnInEmptyFrames() throws {
        let palette = GIFPalette(colors: [0xFF_0000, 0x00_FF00], transparentIndex: 2)
        var writer = try GIFWriter(sink: MemorySink(), width: 4, height: 4, globalPalette: palette)
        let whole = GIFDiff(rect: GIFRect(x: 0, y: 0, width: 4, height: 4), changed: Array(repeating: true, count: 16))
        try writer.add(whole, indices: Array(repeating: 0, count: 16), localPalette: nil, delayCentiseconds: 70_000)
        let source = Fixtures.source(Data(try writer.finish().bytes))
        #expect(Fixtures.delays(source) == [65_535, 4_465])
    }

    @Test func anEmptyDiffExtendsThePendingFrame() throws {
        let palette = GIFPalette(colors: [0xFF_0000, 0x00_FF00], transparentIndex: 2)
        var writer = try GIFWriter(sink: MemorySink(), width: 4, height: 4, globalPalette: palette)
        let whole = GIFDiff(rect: GIFRect(x: 0, y: 0, width: 4, height: 4), changed: Array(repeating: true, count: 16))
        try writer.add(whole, indices: Array(repeating: 0, count: 16), localPalette: nil, delayCentiseconds: 3)
        try writer.add(nil, indices: [], localPalette: nil, delayCentiseconds: 4)
        try writer.add(whole, indices: Array(repeating: 1, count: 16), localPalette: nil, delayCentiseconds: 3)
        let source = Fixtures.source(Data(try writer.finish().bytes))
        #expect(CGImageSourceGetCount(source) == 2)
        #expect(Fixtures.delays(source) == [7, 3])
        // With nothing before it, an empty frame has nothing to extend.
        var empty = try GIFWriter(sink: MemorySink(), width: 4, height: 4, globalPalette: palette)
        #expect(throws: GIFWriterError.nothingToExtend) {
            try empty.add(nil, indices: [], localPalette: nil, delayCentiseconds: 4)
        }
    }
}
