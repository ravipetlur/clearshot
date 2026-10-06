import CoreGraphics

/// The pieces of a scrolling capture, kept apart until they are drawn into the result once: the first frame whole (of
/// which only the lines above its bottom band are content), the new content lines of each later accepted frame, and the
/// latest accepted frame's bottom band (a footer, a floating button and what is around it), which is drawn once at the
/// end. Composing draws them in order and lets each go as soon as it's drawn.
struct StripStore: Sendable {
    private(set) var first: StitchFrame?
    /// How many of the first frame's lines are content; nil while nothing moved (the first frame is all of it).
    private(set) var firstContent: Int?
    private(set) var strips: [StitchFrame] = []
    /// The latest accepted frame's bottom band; nil when it has none.
    private(set) var band: StitchFrame?

    var isEmpty: Bool {
        first == nil && strips.isEmpty && band == nil
    }

    mutating func keepFirst(_ frame: StitchFrame) {
        first = frame
    }

    /// Only the first `lines` of the first frame are content; the rest was its band.
    mutating func setFirstContent(_ lines: Int) {
        firstContent = lines
    }

    /// Lets go of the last `lines` lines of the last strip (they will be stitched again from a later frame).
    mutating func retractLastStrip(by lines: Int, along axis: ScrollAxis) {
        guard lines > 0, let last = strips.last else { return }
        let kept = last.length(along: axis) - lines
        precondition(kept >= 0, "can't take back more than the last strip")
        strips.removeLast()
        if kept > 0 { strips.append(last.lines(0..<kept, along: axis)) }
    }

    /// Keeps `newLines` of `frame`, an accepted frame, as content, and its lines `band` as the band to end with.
    mutating func append(_ frame: StitchFrame, along axis: ScrollAxis, newLines: Range<Int>, band: Range<Int>) {
        if !newLines.isEmpty { strips.append(frame.lines(newLines, along: axis)) }
        self.band = band.isEmpty ? nil : frame.lines(band, along: axis)
    }

    /// The capture: the first frame's content (all of it while nothing moved), each strip, then the band. Source pixels,
    /// in the first frame's colour space and layout (BGRA, premultiplied first, little-endian). Empties the store; nil
    /// when it was empty.
    mutating func compose(along axis: ScrollAxis) -> CGImage? {
        // No binding to the first frame or a strip outlives its drawing: each is taken out of the store and goes as
        // soon as it's drawn, so the capture is never held twice over.
        guard let length = first?.length(along: axis), let cross = first?.crossLength(along: axis),
              let colorSpace = first?.colorSpace
        else { return nil }
        let firstLines = firstContent ?? length
        let total = firstLines + strips.reduce(0) { $0 + $1.length(along: axis) } + (band?.length(along: axis) ?? 0)
        let (width, height) = axis == .vertical ? (cross, total) : (total, cross)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: StitchFrame.bitmapInfo.rawValue),
              let bitmap = context.data
        else { return nil }
        let bytesPerRow = context.bytesPerRow
        if let first = first.take() {
            first.copyLines(0..<firstLines, along: axis, into: bitmap, bytesPerRow: bytesPerRow, at: 0)
        }
        var position = firstLines
        var pending: [StitchFrame?] = strips
        strips = []
        for index in pending.indices {
            guard let strip = pending[index].take() else { continue }
            let lines = strip.length(along: axis)
            strip.copyLines(0..<lines, along: axis, into: bitmap, bytesPerRow: bytesPerRow, at: position)
            position += lines
        }
        if let band = band.take() {
            let lines = band.length(along: axis)
            band.copyLines(0..<lines, along: axis, into: bitmap, bytesPerRow: bytesPerRow, at: position)
            position += lines
        }
        firstContent = nil
        assert(position == total)
        return context.makeImage()
    }
}
