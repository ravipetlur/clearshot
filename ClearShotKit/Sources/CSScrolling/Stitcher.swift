import CoreGraphics

/// What the person is told while capturing: "Please slow down…" and "Screenshot is very large".
public enum StitchWarning: Sendable, Hashable {
    case slowDown, veryLarge

    /// The slow-down warning's text.
    public static let slowDownText = "Please slow down…"

    /// What to do about it: slowing down alone doesn't bring the stitch back, going back to where it can follow again
    /// does. Up for a vertical capture (and before the axis is known), left for a horizontal one.
    public static func slowDownHint(along axis: ScrollAxis?) -> String {
        "Scroll back \(axis == .horizontal ? "left" : "up") a little to continue"
    }
}

/// How a scrolling capture is stitched.
public struct StitchConfiguration: Sendable, Equatable {
    /// The display's pixels per point (for the edge margins).
    public var pixelsPerPoint: Double
    /// Output pixels per source pixel: 1, or 1 ÷ pixelsPerPoint with Scale Retina to 1x.
    public var outputScale: Double
    /// Fixed by Auto-Scroll; nil: the first movement decides.
    public var axis: ScrollAxis?
    /// The longest output along the axis (output pixels); the capture stops there.
    public var maximumOutputLength = 16_383
    /// From this share of the maximum, the capture is very large.
    public var veryLargeFraction = 0.85
    /// Left out at both ends of each line when hashing, where overlay scroll bars appear.
    public var edgeMarginPoints = 16.0
    /// The share of compared lines (or pieces of lines) that must be equal for an offset to match.
    public var matchThreshold = 0.9
    /// How many different equal lines a match needs.
    public var minimumDistinctiveLines = 8
    /// The largest offset searched, as a share of the band matched.
    public var maximumOffsetFraction = 0.9
    /// The largest sticky band (a header, a footer, a floating button near an edge), as a share of the frame.
    public var maximumStickyFraction = 0.4
    /// The tallest floating element (a back-to-top button, a chat bubble, with its shadow) whose rows a match by pieces
    /// forgives: common ones are 40–64 pt.
    public var floatingElementPoints = 80.0

    public init(pixelsPerPoint: Double, outputScale: Double = 1, axis: ScrollAxis? = nil) {
        self.pixelsPerPoint = pixelsPerPoint
        self.outputScale = outputScale
        self.axis = axis
    }

    /// The edge margin in pixels.
    var edgeMarginPixels: Int {
        max(0, Int((edgeMarginPoints * pixelsPerPoint).rounded()))
    }
}

/// What adding a frame did.
public struct StitchUpdate: Sendable, Equatable {
    public var accepted: Bool
    /// This frame was compared and no movement could be verified (what sets `slowDown`; the warning itself stays
    /// until the next accepted frame).
    public var noMatch: Bool
    /// Source px moved since the last accepted frame; 0 unless accepted.
    public var offset: Int
    public var axis: ScrollAxis?
    /// Output px the file will have so far.
    public var outputSize: CGSize
    public var warnings: Set<StitchWarning>
    public var reachedLimit: Bool
    /// What the stitcher saw in this frame, for the capture log.
    public var trace: StitchTrace?
}

/// The sticky header and footer, as lines at the start and end of the frame along the axis: the running minimum,
/// over every accepted move, of the whole lines unchanged in place (each pair's count is never below the true band).
struct StickyBands: Sendable, Equatable {
    var leading: Int
    var trailing: Int
}

/// Stitches the frames of a scrolling capture into one picture. Each frame is compared with the reference, the last
/// verified frame, by exact line matching: by whole lines or, when content that doesn't scroll spoils them, by pieces
/// of lines (`PieceMatcher`). The position only moves on an unambiguous answer (`OffsetMatcher`): the one offset that
/// verifies (unless Vision's registration, the estimator, asked for it, falls elsewhere when only pieces verify it, or
/// doesn't agree when whole lines verify it on little), or, of several, the one Vision's estimate or else the frames
/// tell apart. The first forward movement locks the axis. No such answer asks the person to slow down.
///
/// The capture keeps a frontier: the content lines stitched so far. A frame that moved forward past it adds the lines
/// between the frontier and its bottom band (`EdgeBands`: a footer, a floating button near the edge), and its band
/// becomes the capture's end, drawn once. A frame verified scrolled back or catching up adds nothing but becomes the
/// reference, so a block that changed after its frame was stitched stops blocking once the person scrolls back past
/// it, and nothing repeats or goes missing; not a scroll back that only Vision picked among several, nor one that rests
/// on few whole lines (one repeated element and whitespace). A frame standing still, or an animation, adds nothing and
/// leaves the reference as it is, and the capture stops at the output cap.
public struct Stitcher: Sendable {
    public private(set) var acceptedFrames = 0

    private let configuration: StitchConfiguration
    private let estimator: any OffsetEstimator
    private let matcher: OffsetMatcher
    /// The longest capture in source lines whose output stays within the cap.
    private let maximumSourceLength: Int
    /// Fixed by the configuration, or by the first accepted move.
    private var axis: ScrollAxis?
    /// The last verified frame.
    private var reference: Reference?
    /// Where the reference's first line is, in source lines along the axis from the first frame's first line.
    private var referencePosition = 0
    /// Where the last accepted frame's first line is.
    private var acceptedPosition = 0
    /// The content lines stitched so far, from the first frame's first line; nil until something moved forward.
    private var frontier: Int?
    /// Where the last strip's lines begin in the capture (the most the frontier can be taken back to); nil before one.
    private var lastStripStart: Int?
    private var frameSize: (width: Int, height: Int)?
    /// The frame added last, whatever became of it: what tells what stayed put (`maskedPieces`).
    private var lastFrame: StitchFrame?
    private(set) var stripStore = StripStore()
    /// Nil until something moved.
    private(set) var stickyBands: StickyBands?
    /// The last forward movement verified.
    private var previousOffset: Int?
    /// The capture's length so far in source lines along the axis (the vertical one until the axis is known).
    private var sourceLength = 0
    private var slowDown = false
    private var reachedLimit = false
    private var composed = false
    /// The most the live preview is across the axis; nil: no preview.
    private var previewSide: Int?
    private var preview: StitchPreview?

    public init(configuration: StitchConfiguration, estimator: any OffsetEstimator = VisionOffsetEstimator()) {
        self.configuration = configuration
        self.estimator = estimator
        matcher = OffsetMatcher(configuration: configuration)
        axis = configuration.axis
        maximumSourceLength = Self.maximumSourceLength(cap: configuration.maximumOutputLength, scale: configuration.outputScale)
    }

    /// Keeps a live preview `side` px across the axis (the frames' own size when they are narrower: it is never scaled
    /// up), drawn as frames are accepted (`StitchSession`).
    mutating func showPreview(side: Int) {
        previewSide = side
    }

    /// The live preview as it is now, or nil without one.
    func previewImage() -> CGImage? {
        guard let preview, let colorSpace = reference?.frame.colorSpace else { return nil }
        return preview.image(colorSpace: colorSpace)
    }

    /// Adds the next frame of the stream. The first is always accepted; each later one is compared with the reference
    /// and accepted when the content verifiably moved forward past what is stitched. A frame of another size than the
    /// first is ignored, and so is everything after the cap or `compose`.
    public mutating func add(_ frame: StitchFrame) -> StitchUpdate {
        var trace = StitchTrace(previousOffset: previousOffset)
        guard !composed, !reachedLimit else {
            trace.ignored = .finished
            return update(accepted: false, trace: trace)
        }
        guard var reference else { return acceptFirst(frame) }
        guard frame.width == reference.frame.width, frame.height == reference.frame.height else {
            trace.ignored = .otherSize
            return update(accepted: false, trace: trace)
        }
        let referenceFrame = reference.frame
        let margin = configuration.edgeMarginPixels
        // What stayed put is told by the frame just before this one (the reference may be older): a sidebar that has
        // stuck since the reference was stitched is left out of the comparison with it.
        let frameBefore = lastFrame ?? referenceFrame
        defer { lastFrame = frame }
        // Before the axis is locked a frame is tried on both axes: a no-match on one is only reported when the other
        // didn't explain the frame either (still, scrolling back, or an animation).
        var explained = false
        var unmatched = false
        var followed: (reference: Reference, position: Int)?
        for axis in axis.map({ [$0] }) ?? [.vertical, .horizontal] {
            let previous = reference.lines(along: axis, margin: margin)
            let current = LineHashes(frame, axis: axis, margin: margin)
            let comparison = matcher.compare(previous, current, previousOffset: previousOffset,
                                             masked: { band in
                                                 Self.maskedPieces(referenceFrame, frame, before: frameBefore,
                                                                   along: axis, margin: margin,
                                                                   band: band) ?? (previous, current)
                                             }) { band in
                estimator.estimate(from: referenceFrame, to: frame, band: band, axis: axis)
            }
            trace.comparisons.append(traced(comparison, along: axis, lines: (previous, current), frames: (referenceFrame, frame),
                                            margin: margin))
            switch comparison.movement {
            case .moved(let offset) where offset > 0:
                if let update = moveForward(frame, lines: (previous, current), along: axis, offset: offset,
                                            comparison: comparison, trace: trace) {
                    return update
                }
                trace.outcome = .tooFar
                unmatched = true
            case .moved where comparison.decidedBy == .estimate:
                // Scrolled back or still only by Vision's pick among several that verify: not followed, the frame is
                // ambiguous (a misread estimate on repeating content would lose what lies between).
                unmatched = true
            case .moved(0):
                // Still: explained like an animation, and the reference stays. What is equal in place (a sidebar, the
                // paper) speaks for standing still even when the page moved by more than can be verified.
                explained = true
            case .moved(let offset):
                // Scrolled back, the one offset that verifies (or the one the pieces that tell them apart favour): the
                // frame is the new reference, and the frontier stays where it is. Only once the axis is known.
                if self.axis != nil {
                    followed = (Reference(frame: frame, axis: axis, lines: current), referencePosition + offset)
                    trace.outcome = .followed
                }
                explained = true
            case .animation:
                // Something changed in place (or, by pieces, only a small part did): nothing to add, nothing wrong, and
                // the reference stays, so later frames are measured from a frame whose position is known.
                explained = true
            case .noMatch:
                unmatched = true
            case .identical:
                self.reference = reference
                return update(accepted: false, trace: trace)
            }
        }
        if let followed {
            // The stitch follows the page again: the warning has been heeded.
            self.reference = followed.reference
            referencePosition = followed.position
            slowDown = false
        } else {
            self.reference = reference
        }
        let noMatch = unmatched && !explained
        if noMatch { slowDown = true }
        return update(accepted: false, noMatch: noMatch, trace: trace)
    }

    /// The capture: source pixels in the first frame's colour space and layout (BGRA, premultiplied first,
    /// little-endian). Ends the capture and lets go of every frame; nil when nothing was accepted or it was composed
    /// already.
    public mutating func compose() -> CGImage? {
        guard !composed else { return nil }
        composed = true
        reference = nil
        lastFrame = nil
        preview = nil
        return stripStore.compose(along: axis ?? .vertical)
    }

    private mutating func acceptFirst(_ frame: StitchFrame) -> StitchUpdate {
        stripStore.keepFirst(frame)
        lastFrame = frame
        reference = Reference(frame: frame)
        frameSize = (frame.width, frame.height)
        let axis = axis ?? .vertical
        sourceLength = frame.length(along: axis)
        if sourceLength >= maximumSourceLength { reachedLimit = true }
        acceptedFrames = 1
        if let previewSide {
            preview = StitchPreview(side: previewSide, axis: axis, crossLength: frame.crossLength(along: axis))
            preview?.draw(frame, lines: 0..<sourceLength, at: 0, captureLength: sourceLength)
        }
        return update(accepted: true, trace: StitchTrace())
    }

    /// `frame` moved `offset` lines forward from the reference. Past the frontier, it is accepted: the lines between
    /// the frontier and its bottom band are stitched and its band becomes the capture's end. Not past it, it becomes the
    /// reference. Nil when it moved so far that the lines after the frontier are hidden under its top band or gone.
    private mutating func moveForward(_ frame: StitchFrame, lines: (previous: LineHashes, current: LineHashes),
                                      along axis: ScrollAxis, offset: Int, comparison: OffsetMatcher.Comparison,
                                      trace: StitchTrace) -> StitchUpdate? {
        let length = frame.length(along: axis)
        let position = referencePosition + offset
        let largestSticky = Int(configuration.maximumStickyFraction * Double(length))
        let edges = EdgeBands.bands(previous: lines.previous, current: lines.current, offset: offset,
                                    band: comparison.top..<(length - comparison.bottom), limit: largestSticky)
        let sticky = StickyBands(leading: min(stickyBands?.leading ?? largestSticky, comparison.top),
                                 trailing: min(stickyBands?.trailing ?? largestSticky, comparison.bottom))
        let forgiven = EdgeBands.bands(forgiven: comparison.byPieces?.forgivenRuns ?? [], offset: offset,
                                       pairedEnd: length - comparison.bottom - offset, length: length,
                                       limit: largestSticky)
        // This pair's own unchanged trailing lines: a button over a stretch blank in both frames is whole lines equal in
        // place, below what the running minimum reaches.
        let bottomBand = min(largestSticky, max(comparison.bottom, edges.bottom, forgiven.bottom))
        let topBand = max(comparison.top, edges.top, forgiven.top)
        // Before anything moved forward, the first frame's content ends where this pair's bottom band starts. After, a
        // band that reaches higher than the last accepted frame's did is an element that had just appeared there (not
        // yet in place, so not a band then): what that frame stitched under it is taken again from this one, where the
        // page under it shows above the band. Only the last strip can be taken back.
        var frontier = self.frontier ?? (length - bottomBand)
        if self.frontier != nil, let lastStripStart {
            frontier = max(lastStripStart, min(frontier, acceptedPosition + length - bottomBand))
        }
        // This frame's line where what isn't stitched yet begins, and how many lines of it are above its band.
        let start = frontier - position
        let newLines = length - bottomBand - start
        var trace = trace
        if newLines <= 0 || position <= acceptedPosition {
            reference = Reference(frame: frame, axis: axis, lines: lines.current)
            referencePosition = position
            previousOffset = offset
            slowDown = false
            trace.outcome = .followed
            return update(accepted: false, trace: trace)
        }
        guard start >= topBand else { return nil }
        if self.axis == nil {
            self.axis = axis
            sourceLength = length
            if let first = stripStore.first, let previewSide, preview?.axis != axis {
                preview = StitchPreview(side: previewSide, axis: axis, crossLength: first.crossLength(along: axis))
                preview?.draw(first, lines: 0..<length, at: 0, captureLength: length)
            }
        }
        if let stitched = self.frontier, frontier < stitched {
            stripStore.retractLastStrip(by: stitched - frontier, along: axis)
        }
        if self.frontier == nil { stripStore.setFirstContent(frontier) }
        lastStripStart = frontier
        stickyBands = sticky
        // At the cap the band (the end) is kept first, then as many new lines as still fit.
        let room = max(0, maximumSourceLength - frontier)
        let keptBand = min(bottomBand, room)
        let kept = min(newLines, room - keptBand)
        let newRange = start..<(start + kept)
        let bandRange = (length - keptBand)..<length
        stripStore.append(frame, along: axis, newLines: newRange, band: bandRange)
        let captureLength = frontier + kept + keptBand
        preview?.draw(frame, lines: newRange, at: frontier, captureLength: captureLength)
        preview?.draw(frame, lines: bandRange, at: frontier + kept, captureLength: captureLength)
        self.frontier = frontier + kept
        sourceLength = captureLength
        if sourceLength >= maximumSourceLength { reachedLimit = true }
        let moved = position - acceptedPosition
        acceptedPosition = position
        referencePosition = position
        previousOffset = offset
        slowDown = false
        acceptedFrames += 1
        reference = Reference(frame: frame, axis: axis, lines: lines.current)
        trace.outcome = .stitched(newLines: kept, band: keptBand)
        return update(accepted: true, offset: moved, trace: trace)
    }

    /// `comparison` as the log shows it; for a no-match, with the closest movement and where it fell short (worked out
    /// only then).
    private func traced(_ comparison: OffsetMatcher.Comparison, along axis: ScrollAxis,
                        lines: (previous: LineHashes, current: LineHashes),
                        frames: (previous: StitchFrame, current: StitchFrame), margin: Int) -> StitchTrace.Comparison {
        let band = comparison.top..<max(comparison.top, lines.current.count - comparison.bottom)
        var traced = StitchTrace.Comparison(axis: axis, top: comparison.top, bottom: comparison.bottom, band: band.count,
                                            estimate: comparison.estimate, movement: comparison.movement,
                                            byPieces: comparison.byPieces, stoodStill: comparison.stoodStill,
                                            verified: comparison.verified, decidedBy: comparison.decidedBy,
                                            overruled: comparison.overruled, sparse: comparison.sparse)
        if comparison.movement == .noMatch, comparison.verified.isEmpty, comparison.overruled == nil,
           let closest = matcher.pieces.votes(from: lines.previous, to: lines.current, in: band).first,
           closest.votes >= configuration.minimumDistinctiveLines {
            var nearMiss = matcher.nearMiss(from: lines.previous, to: lines.current, in: band, at: closest.offset)
            let paired = max(band.lowerBound, band.lowerBound - nearMiss.offset)
                ..< min(band.upperBound, band.upperBound - nearMiss.offset)
            nearMiss.equalAcross = frames.previous.equalAcross(frames.current, offset: nearMiss.offset, lines: paired,
                                                               along: axis, margin: margin)
            traced.nearMiss = nearMiss
        }
        return traced
    }

    private func update(accepted: Bool, offset: Int = 0, noMatch: Bool = false, trace: StitchTrace) -> StitchUpdate {
        let along = output(sourceLength)
        var warnings: Set<StitchWarning> = slowDown ? [.slowDown] : []
        if Double(along) >= configuration.veryLargeFraction * Double(configuration.maximumOutputLength) {
            warnings.insert(.veryLarge)
        }
        var size = CGSize.zero
        if let frameSize {
            let lengthAxis = axis ?? .vertical
            let across = output(lengthAxis == .vertical ? frameSize.width : frameSize.height)
            size = lengthAxis == .vertical ? CGSize(width: across, height: along) : CGSize(width: along, height: across)
        }
        var trace = trace
        trace.stickyBands = stickyBands
        return StitchUpdate(accepted: accepted, noMatch: noMatch, offset: offset, axis: axis, outputSize: size,
                            warnings: warnings, reachedLimit: reachedLimit, trace: trace)
    }

    /// The pair's pieces without the positions across the line that `current` has unchanged in place along `band` since
    /// `before`, the frame just before it (a sticky sidebar, the paper beside the text), or nil when there are none.
    private static func maskedPieces(_ previous: StitchFrame, _ current: StitchFrame, before: StitchFrame,
                                     along axis: ScrollAxis, margin: Int,
                                     band: Range<Int>) -> (previous: LineHashes, current: LineHashes)? {
        let unchanged = before.unchangedAcross(current, along: axis, lines: band)
        guard unchanged.contains(true) else { return nil }
        return (LineHashes(piecesOf: previous, axis: axis, margin: margin, ignoring: unchanged),
                LineHashes(piecesOf: current, axis: axis, margin: margin, ignoring: unchanged))
    }

    /// Source lines as output pixels.
    private func output(_ source: Int) -> Int {
        Int((Double(source) * configuration.outputScale).rounded())
    }

    /// The largest source length that rounds to at most `cap` output pixels at `scale`.
    private static func maximumSourceLength(cap: Int, scale: Double) -> Int {
        guard scale > 0 else { return .max }
        var length = Int((Double(cap) + 0.5) / scale)
        while length > 0, Int((Double(length) * scale).rounded()) > cap { length -= 1 }
        while Int((Double(length + 1) * scale).rounded()) <= cap { length += 1 }
        return length
    }
}

/// The reference frame and its line hashes, worked out per axis when first needed.
private struct Reference: Sendable {
    let frame: StitchFrame
    private var vertical: LineHashes?
    private var horizontal: LineHashes?

    init(frame: StitchFrame) {
        self.frame = frame
    }

    init(frame: StitchFrame, axis: ScrollAxis, lines: LineHashes) {
        self.frame = frame
        if axis == .vertical { vertical = lines } else { horizontal = lines }
    }

    mutating func lines(along axis: ScrollAxis, margin: Int) -> LineHashes {
        switch axis {
        case .vertical:
            if let vertical { return vertical }
            let lines = LineHashes(frame, axis: .vertical, margin: margin)
            vertical = lines
            return lines
        case .horizontal:
            if let horizontal { return horizontal }
            let lines = LineHashes(frame, axis: .horizontal, margin: margin)
            horizontal = lines
            return lines
        }
    }
}
