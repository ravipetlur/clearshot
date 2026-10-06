import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import CSRecording

/// The GIF tests' frames and oracles. The scene: a light background, a 60 px gradient bar along the top, lines of
/// "text", and a white card with a soft shadow and a translucent red dot moving 4 px a frame. ImageIO decodes what the
/// encoder wrote; nothing here records the screen.
enum GIFFixtures {
    static let width = 800
    static let height = 450
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Frames

    /// Frame `index` of the scene, as BGRA, with ±`noise` added to every channel (seeded by the index) when asked, like
    /// the decode noise of a lossy intermediate.
    static func scene(_ index: Int, width: Int = width, height: Int = height, noise: Int = 0) -> GIFFrame {
        frame(width: width, height: height) { context in
            let s = CGFloat(width) / 800
            let (w, h) = (CGFloat(width), CGFloat(height))
            context.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let gradient = CGGradient(colorsSpace: sRGB, colors: [CGColor(red: 0.30, green: 0.45, blue: 0.85, alpha: 1),
                                                                  CGColor(red: 0.55, green: 0.25, blue: 0.75, alpha: 1)] as CFArray,
                                      locations: [0, 1])!
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: h - 60 * s, width: w, height: 60 * s))
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: 0), options: [])
            context.restoreGState()
            context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.2, alpha: 1))
            var (y, row) = (h - 90 * s, 0)
            while y > 20 * s {
                context.fill(CGRect(x: 40 * s, y: y, width: CGFloat(180 + (row * 7919) % 400) * s, height: 7 * s))
                y -= 18 * s
                row += 1
            }
            let x = (CGFloat(index) * 4 * s).truncatingRemainder(dividingBy: w - 260 * s)
            context.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 18 * s, color: CGColor(gray: 0, alpha: 0.35))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.addPath(CGPath(roundedRect: CGRect(x: 200 * s + x, y: 120 * s, width: 240 * s, height: 150 * s),
                                   cornerWidth: 12 * s, cornerHeight: 12 * s, transform: nil))
            context.fillPath()
            context.setShadow(offset: .zero, blur: 0)
            context.setFillColor(CGColor(red: 0.95, green: 0.3, blue: 0.2, alpha: 0.6))
            context.fillEllipse(in: CGRect(x: 300 * s + x, y: 180 * s, width: 30 * s, height: 30 * s))
        }.adding(noise: noise, seed: UInt64(index) &+ 1)
    }

    /// `frame` with a still 300 × 200 photo-like patch at (450, 100): a smooth blend on every channel, thousands of
    /// colours, more than a palette holds, so some pixels quantise past the stabiliser's threshold.
    static func withPhoto(_ frame: GIFFrame) -> GIFFrame {
        var bytes = frame.bgra
        for y in 0..<200 {
            for x in 0..<300 {
                let offset = (100 + y) * frame.bytesPerRow + (450 + x) * 4
                bytes[offset + 2] = UInt8(40 + x * 180 / 300)
                bytes[offset + 1] = UInt8(60 + y * 150 / 200)
                bytes[offset] = UInt8(200 - (x + y) * 120 / 500)
            }
        }
        return GIFFrame(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, bgra: bytes)
    }

    /// `frame` with the colour `color(x, y)` (0x00RRGGBB, or nil to leave the pixel) over `rect` (x, y, width, height).
    static func painted(_ frame: GIFFrame, _ rect: (x: Int, y: Int, width: Int, height: Int),
                        _ color: (Int, Int) -> UInt32?) -> GIFFrame {
        var bytes = frame.bgra
        for y in max(0, rect.y)..<min(frame.height, rect.y + rect.height) {
            for x in max(0, rect.x)..<min(frame.width, rect.x + rect.width) {
                guard let rgb = color(x - rect.x, y - rect.y) else { continue }
                let offset = y * frame.bytesPerRow + x * 4
                bytes[offset] = UInt8(rgb & 0xFF)
                bytes[offset + 1] = UInt8(rgb >> 8 & 0xFF)
                bytes[offset + 2] = UInt8(rgb >> 16 & 0xFF)
            }
        }
        return GIFFrame(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, bgra: bytes)
    }

    /// A smooth blend over `width` × `height` from `from` to `to` (each 0xRRGGBB) along x and y: photo-like, more
    /// colours than a palette holds.
    static func blend(_ x: Int, _ y: Int, width: Int, height: Int, from: UInt32, to: UInt32) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let (a, b) = (Double(from >> shift & 0xFF), Double(to >> shift & 0xFF))
            let t = (Double(x) / Double(max(width - 1, 1)) + Double(y) / Double(max(height - 1, 1))) / 2
            let u = shift == 8 ? Double(y) / Double(max(height - 1, 1)) : t
            return UInt32((a + (b - a) * u).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }

    /// The GIF's last frame as ImageIO composes it, against `source`: how many pixels are more than `limit` off on
    /// their farthest channel.
    static func pixelsOff(_ data: Data, against source: GIFFrame, by limit: Int) -> Int {
        let gif = self.source(data)
        let decoded = decoded(gif, at: CGImageSourceGetCount(gif) - 1).rgba
        var off = 0
        for y in 0..<source.height {
            for x in 0..<source.width {
                let s = y * source.bytesPerRow + x * 4
                let t = (y * source.width + x) * 4
                let difference = max(abs(Int(source.bgra[s + 2]) - Int(decoded[t])),
                                     abs(Int(source.bgra[s + 1]) - Int(decoded[t + 1])),
                                     abs(Int(source.bgra[s]) - Int(decoded[t + 2])))
                if difference > limit { off += 1 }
            }
        }
        return off
    }

    /// `frames` through the encoder's pipeline with `palette`, each 10 cs, into memory.
    static func encode(_ frames: [GIFFrame], palette: GIFPalette, plan: GIFQualityPlan) throws -> Data {
        let first = frames[0]
        var encoder = GIFFrameEncoder(width: first.width, height: first.height, palette: palette, plan: plan)
        var writer = try GIFWriter(sink: MemorySink(), width: first.width, height: first.height, globalPalette: palette)
        for frame in frames {
            let encoded = encoder.encode(frame)
            try writer.add(encoded?.diff, indices: encoded?.indices ?? [], localPalette: encoded?.localPalette,
                           delayCentiseconds: 10)
        }
        return Data(try writer.finish().bytes)
    }

    /// A frame drawn by `draw` into an opaque BGRA context.
    static func frame(width: Int, height: Int, draw: (CGContext) -> Void) -> GIFFrame {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: sRGB,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue)!
            draw(context)
        }
        return GIFFrame(width: width, height: height, bytesPerRow: width * 4, bgra: bytes)
    }

    /// A frame whose pixel (x, y) is `color(x, y)` (0x00RRGGBB).
    static func frame(width: Int, height: Int, color: (Int, Int) -> UInt32) -> GIFFrame {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let rgb = color(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(rgb & 0xFF)
                bytes[offset + 1] = UInt8(rgb >> 8 & 0xFF)
                bytes[offset + 2] = UInt8(rgb >> 16 & 0xFF)
            }
        }
        return GIFFrame(width: width, height: height, bytesPerRow: width * 4, bgra: bytes)
    }

    // MARK: Encoding through the encoder's own pipeline

    /// A GIF of `count` frames (`frame(i)` makes frame i; each lasts `delay` centiseconds) through the stabiliser, the
    /// quantiser and the writer as the encoder runs them, with the palette from every tenth frame, into `sink`.
    /// `afterFrame` sees the writer after each frame is added. Frames are made as needed, never all kept.
    static func encode<Sink: GIFByteSink>(count: Int, plan: GIFQualityPlan, delay: Int = 3, into sink: Sink,
                                          afterFrame: (Int, GIFWriter<Sink>) -> Void = { _, _ in },
                                          frame: (Int) -> GIFFrame) throws -> Sink {
        let samples = stride(from: 0, to: count, by: 10).map(frame)
        let palette = GIFQuantizer.palette(from: samples, colors: plan.paletteColors, mergingWithin: plan.threshold)
        let first = samples[0]
        var encoder = GIFFrameEncoder(width: first.width, height: first.height, palette: palette, plan: plan)
        var writer = try GIFWriter(sink: sink, width: first.width, height: first.height, globalPalette: palette)
        for index in 0..<count {
            let encoded = encoder.encode(frame(index))
            try writer.add(encoded?.diff, indices: encoded?.indices ?? [], localPalette: encoded?.localPalette,
                           delayCentiseconds: delay)
            afterFrame(index, writer)
        }
        return try writer.finish()
    }

    /// `encode(count:…)` into memory.
    static func encode(count: Int, plan: GIFQualityPlan, delay: Int = 3, frame: (Int) -> GIFFrame) throws -> Data {
        Data(try encode(count: count, plan: plan, delay: delay, into: MemorySink(), frame: frame).bytes)
    }

    // MARK: Reading GIFs with ImageIO (the oracle)

    static func source(_ data: Data) -> CGImageSource {
        CGImageSourceCreateWithData(data as CFData, nil)!
    }

    /// Frame `index` as ImageIO composes it, as RGBA bytes in the image's own colour space (no colour conversion).
    static func decoded(_ source: CGImageSource, at index: Int) -> (width: Int, height: Int, rgba: [UInt8]) {
        let image = CGImageSourceCreateImageAtIndex(source, index, nil)!
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: image.colorSpace ?? sRGB,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (width, height, bytes)
    }

    /// Each frame's delay in centiseconds, as ImageIO reads it (unclamped).
    static func delays(_ source: CGImageSource) -> [Int] {
        (0..<CGImageSourceGetCount(source)).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let seconds = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            return Int((seconds * 100).rounded())
        }
    }

    /// The file's loop count (0 loops forever); nil without a NETSCAPE2.0 extension.
    static func loopCount(_ source: CGImageSource) -> Int? {
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
    }

    /// The PSNR of a decoded RGBA frame against the BGRA frame it came from, over the three colour channels.
    static func psnr(_ original: GIFFrame, _ decoded: [UInt8]) -> Double {
        var squares = 0
        original.bgra.withUnsafeBufferPointer { sourceBuffer in
            decoded.withUnsafeBufferPointer { decodedBuffer in
                let (source, target) = (sourceBuffer.baseAddress!, decodedBuffer.baseAddress!)
                var y = 0
                while y < original.height {
                    var x = 0
                    while x < original.width {
                        let s = source + y * original.bytesPerRow + x * 4
                        let t = target + (y * original.width + x) * 4
                        let red = Int(s[2]) - Int(t[0]), green = Int(s[1]) - Int(t[1]), blue = Int(s[0]) - Int(t[2])
                        squares += red * red + green * green + blue * blue
                        x += 1
                    }
                    y += 1
                }
            }
        }
        let mean = Double(squares) / Double(original.width * original.height * 3)
        return mean == 0 ? .infinity : 10 * log10(255 * 255 / mean)
    }
}

extension GIFFrame {
    /// The frame with ±`noise` added to each colour channel, uniformly (deterministic per `seed`; SplitMix64 inline, so
    /// it stays quick unoptimised).
    func adding(noise: Int, seed: UInt64) -> GIFFrame {
        guard noise > 0 else { return self }
        var bytes = bgra
        var state = seed
        let span = UInt64(2 * noise + 1)
        bytes.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            var offset = 0
            while offset < buffer.count {
                if offset & 3 != 3 {
                    state &+= 0x9E37_79B9_7F4A_7C15
                    var z = state
                    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                    z ^= z >> 31
                    let value = Int(base[offset]) + Int(z % span) - noise
                    base[offset] = UInt8(value < 0 ? 0 : value > 255 ? 255 : value)
                }
                offset += 1
            }
        }
        return GIFFrame(width: width, height: height, bytesPerRow: bytesPerRow, bgra: bytes)
    }

    /// The colour at (x, y), 0x00RRGGBB.
    func color(x: Int, y: Int) -> UInt32 {
        let offset = y * bytesPerRow + x * 4
        return UInt32(bgra[offset + 2]) << 16 | UInt32(bgra[offset + 1]) << 8 | UInt32(bgra[offset])
    }
}

/// Keeps every byte written.
struct MemorySink: GIFByteSink {
    var bytes: [UInt8] = []

    mutating func write(_ buffer: UnsafeRawBufferPointer) throws {
        bytes.append(contentsOf: buffer)
    }
}

/// Counts the bytes written and keeps none.
struct CountingSink: GIFByteSink {
    var count = 0

    mutating func write(_ buffer: UnsafeRawBufferPointer) throws {
        count += buffer.count
    }
}
