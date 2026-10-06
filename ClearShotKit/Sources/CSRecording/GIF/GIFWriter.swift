/// Where a `GIFWriter` puts its bytes: a file, or a test's counter.
public protocol GIFByteSink {
    mutating func write(_ bytes: UnsafeRawBufferPointer) throws
}

/// Why a GIF couldn't be written.
public enum GIFWriterError: Error, Equatable {
    /// The canvas is empty or larger than GIF allows (65 535 a side).
    case invalidSize
    /// A frame's rectangle leaves the canvas, or its indices don't cover it.
    case invalidFrame
    /// A frame has no colour table: no local one and no global one.
    case missingPalette
    /// An empty frame came before any frame it could extend.
    case nothingToExtend
}

/// A streaming GIF89a writer: the header, the logical screen, the global colour table if any and a NETSCAPE2.0
/// extension that loops forever, then for each frame a graphic control extension (disposal "do not dispose", the
/// transparent index, the delay), an image descriptor for its rectangle, its local table if any, and its LZW data in
/// 255-byte sub-blocks; the trailer last.
///
/// It holds exactly one frame back, already LZW-coded, until the next one comes: an empty frame (nil) adds its delay to
/// it instead of being written. Nothing else stays in memory, so a GIF of any length takes the same.
public struct GIFWriter<Sink: GIFByteSink> {
    /// GIF's longest delay, in centiseconds; a longer one goes on in empty frames.
    static var maximumDelay: Int { 0xFFFF }

    private struct Pending {
        var rect: GIFRect
        var localPalette: GIFPalette?
        var transparentIndex: Int?
        var delay: Int
        /// The minimum code size byte, the sub-blocks and their terminator.
        var data: [UInt8]
    }

    private var sink: Sink
    private let width: Int
    private let height: Int
    private let globalPalette: GIFPalette?
    private var pending: Pending?
    private var lzw = GIFLZW()
    /// Reused for each frame's bytes, so a frame reaches the sink in one write.
    private var output: [UInt8] = []
    /// The last frame's data buffer, emptied, for the next one.
    private var spare: [UInt8] = []
    /// Frames written to the sink so far.
    private(set) var framesWritten = 0

    /// Writes the header, the logical screen, `globalPalette`'s table (when given) and the loop extension.
    public init(sink: Sink, width: Int, height: Int, globalPalette: GIFPalette?) throws {
        guard (1...0xFFFF).contains(width), (1...0xFFFF).contains(height) else { throw GIFWriterError.invalidSize }
        self.sink = sink
        self.width = width
        self.height = height
        self.globalPalette = globalPalette
        var header = [UInt8]("GIF89a".utf8)
        header += Self.little(width) + Self.little(height)
        if let globalPalette {
            // A global table, 8 bits of colour resolution, unsorted, and its size.
            header += [0x80 | 0x70 | UInt8(globalPalette.tableBits - 1), 0, 0]
            header += Self.table(globalPalette)
        } else {
            header += [0x70, 0, 0]
        }
        header += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]
        try header.withUnsafeBytes { try self.sink.write($0) }
    }

    /// The next frame: `diff`'s rectangle with `indices` over it (row by row) in `localPalette`, or the global table
    /// without one, lasting `delayCentiseconds`. A nil `diff` (nothing changed) lengthens the frame before instead.
    /// Throws `invalidFrame` for a rectangle off the canvas, indices that don't cover it or point past the colour table,
    /// and a delay no frame can carry: over 655.35 s with no transparent index to go on in empty frames.
    public mutating func add(_ diff: GIFDiff?, indices: [UInt8], localPalette: GIFPalette?, delayCentiseconds: Int) throws {
        let delay = max(0, delayCentiseconds)
        guard let diff else {
            guard let held = pending else { throw GIFWriterError.nothingToExtend }
            guard held.transparentIndex != nil || held.delay + delay <= Self.maximumDelay else {
                throw GIFWriterError.invalidFrame
            }
            pending?.delay += delay
            return
        }
        let rect = diff.rect
        guard rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0, rect.x + rect.width <= width,
              rect.y + rect.height <= height, indices.count == rect.width * rect.height else {
            throw GIFWriterError.invalidFrame
        }
        guard let palette = localPalette ?? globalPalette else { throw GIFWriterError.missingPalette }
        guard palette.transparentIndex != nil || delay <= Self.maximumDelay,
              Self.largest(indices) < palette.tableSize else {
            throw GIFWriterError.invalidFrame
        }
        try flushPending()
        var data = spare
        spare = []
        data.removeAll(keepingCapacity: true)
        let codeSize = max(2, palette.tableBits)
        data.append(UInt8(codeSize))
        indices.withUnsafeBufferPointer { lzw.encode($0, minimumCodeSize: codeSize, into: &data) }
        pending = Pending(rect: rect, localPalette: localPalette, transparentIndex: palette.transparentIndex, delay: delay,
                          data: data)
    }

    /// Writes the frame held back and the trailer, and hands the sink back.
    public mutating func finish() throws -> Sink {
        try flushPending()
        pending = nil
        try [UInt8(0x3B)].withUnsafeBytes { try sink.write($0) }
        return sink
    }

    /// The bytes the writer itself holds now: the frame held back, its reusable buffers and the LZW tables.
    public var bufferedBytes: Int {
        (pending?.data.capacity ?? 0) + spare.capacity + output.capacity + lzw.bufferedBytes
    }

    // MARK: Writing

    private mutating func flushPending() throws {
        guard let frame = pending else { return }
        pending = nil
        output.removeAll(keepingCapacity: true)
        var remaining = frame.delay
        appendFrame(frame, delay: min(remaining, Self.maximumDelay))
        remaining -= Self.maximumDelay
        // A delay too long for one frame goes on in 1 × 1 frames that change nothing.
        if remaining > 0, let transparent = frame.transparentIndex,
           let palette = frame.localPalette ?? globalPalette {
            let codeSize = max(2, palette.tableBits)
            var data = [UInt8(codeSize)]
            [UInt8(transparent)].withUnsafeBufferPointer { lzw.encode($0, minimumCodeSize: codeSize, into: &data) }
            let still = Pending(rect: GIFRect(x: 0, y: 0, width: 1, height: 1), localPalette: frame.localPalette,
                                transparentIndex: transparent, delay: 0, data: data)
            while remaining > 0 {
                appendFrame(still, delay: min(remaining, Self.maximumDelay))
                remaining -= Self.maximumDelay
            }
        }
        try output.withUnsafeBytes { try sink.write($0) }
        // Its buffer is kept for the next frame.
        spare = frame.data
    }

    private mutating func appendFrame(_ frame: Pending, delay: Int) {
        // Graphic control extension: disposal 1 (do not dispose), the transparency flag, the delay, the index.
        output += [0x21, 0xF9, 0x04, 0x04 | (frame.transparentIndex == nil ? 0 : 0x01)]
        output += Self.little(delay)
        output += [UInt8(frame.transparentIndex ?? 0), 0x00]
        // Image descriptor, with the local table's flag and size.
        output.append(0x2C)
        output += Self.little(frame.rect.x) + Self.little(frame.rect.y)
        output += Self.little(frame.rect.width) + Self.little(frame.rect.height)
        if let local = frame.localPalette {
            output.append(0x80 | UInt8(local.tableBits - 1))
            output += Self.table(local)
        } else {
            output.append(0x00)
        }
        output += frame.data
        framesWritten += 1
    }

    /// The largest index (a quick loop, as the frame's pixels go through it).
    private static func largest(_ indices: [UInt8]) -> Int {
        indices.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            var largest: UInt8 = 0
            var i = 0
            while i < buffer.count {
                if base[i] > largest { largest = base[i] }
                i += 1
            }
            return Int(largest)
        }
    }

    private static func little(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
    }

    /// The colour table, padded with black to its size.
    private static func table(_ palette: GIFPalette) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: palette.tableSize * 3)
        for (index, color) in palette.colors.enumerated() {
            bytes[index * 3] = UInt8(color >> 16 & 0xFF)
            bytes[index * 3 + 1] = UInt8(color >> 8 & 0xFF)
            bytes[index * 3 + 2] = UInt8(color & 0xFF)
        }
        return bytes
    }
}
