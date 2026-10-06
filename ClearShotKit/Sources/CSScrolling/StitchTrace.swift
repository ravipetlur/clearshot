import Foundation

/// What one frame did inside the stitcher, for the capture log: for each axis compared with the reference, the lines
/// unchanged in place at both ends, the band matched, Vision's estimate and the verdict (by whole lines, or by pieces of
/// lines with what they left out); what became of the frame (stitched, followed, too far); for a frame with no verified
/// match, the movement that came closest and where it failed. Diagnostics only: nothing but the log reads it.
///
/// A too-fast scroll has nothing in common at any offset. What still blocks a match shows as a close miss at the true
/// movement: a block that changed after its frame was stitched as one run of mismatched lines where it is, an
/// animation the same way.
public struct StitchTrace: Sendable, Equatable, CustomStringConvertible {
    /// One axis's comparison.
    struct Comparison: Sendable, Equatable, CustomStringConvertible {
        var axis: ScrollAxis
        /// Lines unchanged in place at the start and the end.
        var top: Int
        var bottom: Int
        /// The lines between them (matched unless the frames are identical or it was an animation).
        var band: Int
        /// Vision's candidate, when it was asked.
        var estimate: Int?
        var movement: Movement
        /// How pieces of lines verified the movement, when whole lines didn't.
        var byPieces: PieceMatcher.Match?
        /// An animation because no offset verifies and, by pieces, only a small part changed in place.
        var stoodStill = false
        /// The offsets that verify when several do, and how the movement was settled.
        var verified: [Int] = []
        var decidedBy: OffsetMatcher.Decision?
        /// For a no-match: the one offset that verifies, by pieces only, when the estimate fell nowhere near it; or one
        /// by whole lines that rested on too little (`sparse`).
        var overruled: Int?
        var sparse: OffsetMatcher.WholeLineEvidence?
        /// For a no-match: the closest movement, nil when the frames have nothing in common at any offset.
        var nearMiss: NearMiss?

        var description: String {
            let axisName = axis == .vertical ? "vertical" : "horizontal"
            var text = "\(axisName): top \(top), bottom \(bottom), band \(band), estimate \(estimate.map(String.init) ?? "none"), "
            switch movement {
            case .identical: text += "identical"
            case .animation: text += stoodStill ? "still by pieces (only a small part changed in place)" : "animation"
            case .moved(let offset) where offset > 0: text += "moved \(offset)"
            case .moved(let offset) where offset < 0: text += "back \(-offset)"
            case .moved: text += "still"
            case .noMatch:
                if let overruled, let sparse {
                    let basis = "on \(sparse.equal) whole lines of \(sparse.open)"
                    text += overruled < 0 ? "no match; back \(-overruled) \(basis): too few to follow back"
                        : "no match; only \(overruled) verifies, \(basis), and the estimate is not there"
                } else if let overruled {
                    text += "no match; only \(overruled) verifies, by pieces, and the estimate is not there"
                } else {
                    text += verified.isEmpty ? "no match; " + (nearMiss?.description ?? "nothing in common at any offset")
                        : "no match; several verify and nothing tells them apart"
                }
            }
            if let byPieces {
                text += " by pieces (\(byPieces.support) for, \(byPieces.contradictions) against, \(byPieces.fixed) fixed, "
                    + "\(byPieces.neutral) periodic"
                if !byPieces.forgivenRuns.isEmpty {
                    text += "; forgiven \(byPieces.forgivenRuns.map { "\($0.lowerBound)..<\($0.upperBound)" }.joined(separator: " "))"
                }
                text += ")"
            }
            if !verified.isEmpty {
                let settled = switch decidedBy {
                case .evidence?: "; the pieces that tell them apart favour it"
                case .estimate?: "; the estimate picked it"
                case .unique?, nil: ""
                }
                text += " [verify: \(verified.map(String.init).joined(separator: " "))\(settled)]"
            }
            return text
        }
    }

    /// The movement most pieces of lines agree on in a frame that had no verified match, and how it fell short.
    struct NearMiss: Sendable, Equatable, CustomStringConvertible {
        var offset: Int
        /// Pairs of lines equal (not blank), and pairs compared (not both blank), at `offset`.
        var equal: Int
        var compared: Int
        /// The current frame's lines in runs of mismatches with no equal pair between them (blank pairs don't end a
        /// run): the largest few, in order.
        var mismatchedRuns: [Range<Int>]
        var runCount: Int
        /// Per eighth across the line (inside the edge margins): the percentage of pairs whose pixels there are equal,
        /// among the pairs where either piece isn't one flat colour; nil where every pair is flat.
        var equalAcross: [Int?] = []

        var description: String {
            // One decimal: 89.8% must not read as the 90% that would have matched.
            let share = String(format: "%.1f", compared > 0 ? 100 * Double(equal) / Double(compared) : 0)
            let runs = mismatchedRuns.map { "\($0.lowerBound)..<\($0.upperBound)" }.joined(separator: " ")
            let runText = switch runCount {
            case 0: "no mismatched lines"
            case 1: "1 mismatched run: \(runs)"
            case mismatchedRuns.count: "\(runCount) mismatched runs: \(runs)"
            default: "\(runCount) mismatched runs, the largest \(runs)"
            }
            let across = equalAcross.map { $0.map(String.init) ?? "-" }.joined(separator: " ")
            return "closest \(offset): \(equal)/\(compared) equal (\(share)%), \(runText), equal across \(across)"
        }
    }

    /// Why a frame wasn't compared.
    enum Ignored: Sendable, Equatable {
        /// Not the size of the first frame.
        case otherSize
        /// The capture was composed or reached the cap.
        case finished
    }

    /// What became of a frame whose movement was verified.
    enum Outcome: Sendable, Equatable {
        /// Accepted: its lines past the frontier were stitched, and its bottom band is the capture's end.
        case stitched(newLines: Int, band: Int)
        /// Not past what is stitched (scrolled back, still, or catching up): the new reference.
        case followed
        /// Forward, but so far that the lines after what is stitched are under its top band or gone: as no match.
        case tooFar
    }

    /// The axes compared, in order; empty for the first frame and an ignored one.
    var comparisons: [Comparison] = []
    var ignored: Ignored?
    var outcome: Outcome?
    /// The forward movement verified last before this frame (a candidate for it).
    var previousOffset: Int?
    /// After this frame.
    var stickyBands: StickyBands?
    /// Frames the session dropped unseen (a newer one replaced them while waiting) since the one before; set by
    /// `StitchSession`.
    public internal(set) var framesSkipped = 0
    /// The time the session took over this frame, preview included; set by `StitchSession`.
    public internal(set) var milliseconds = 0.0

    public var description: String {
        var parts: [String] = []
        switch ignored {
        case .otherSize: parts.append("ignored: another size")
        case .finished: parts.append("ignored: finished")
        case nil: if comparisons.isEmpty, outcome == nil { parts.append("first frame") }
        }
        parts += comparisons.map(\.description)
        switch outcome {
        case .stitched(let newLines, let band)?: parts.append("stitched \(newLines) lines, band \(band)")
        case .followed?: parts.append("followed, nothing new")
        case .tooFar?: parts.append("too far for what is stitched")
        case nil: break
        }
        if let stickyBands { parts.append("sticky \(stickyBands.leading)/\(stickyBands.trailing)") }
        if let previousOffset { parts.append("previous \(previousOffset)") }
        parts.append(String(format: "%.1f ms, %d skipped", milliseconds, framesSkipped))
        return parts.joined(separator: " | ")
    }
}

extension OffsetMatcher {
    /// How many mismatched runs a near miss lists.
    static let nearMissRuns = 6

    /// For the log: how `current` fits `previous` at `offset` within `band`, line by line, as the matcher scores it.
    func nearMiss(from previous: LineHashes, to current: LineHashes, in band: Range<Int>, at offset: Int) -> StitchTrace.NearMiss {
        let previousKeys = previous.matchKeys
        let currentKeys = current.matchKeys
        var equal = 0
        var mismatched = 0
        var runs: [(lines: Range<Int>, mismatches: Int)] = []
        var run: (start: Int, end: Int, mismatches: Int)?
        for line in max(band.lowerBound, band.lowerBound - offset)..<min(band.upperBound, band.upperBound - offset) {
            let a = currentKeys[line]
            let b = previousKeys[line + offset]
            if a != b {
                mismatched += 1
                run = run.map { ($0.start, line + 1, $0.mismatches + 1) } ?? (line, line + 1, 1)
            } else if a != 0 {
                equal += 1
                if let ended = run { runs.append((ended.start..<ended.end, ended.mismatches)) }
                run = nil
            }
        }
        if let ended = run { runs.append((ended.start..<ended.end, ended.mismatches)) }
        let largest = runs.sorted { ($0.mismatches, -$0.lines.lowerBound) > ($1.mismatches, -$1.lines.lowerBound) }
            .prefix(Self.nearMissRuns).map(\.lines).sorted { $0.lowerBound < $1.lowerBound }
        return StitchTrace.NearMiss(offset: offset, equal: equal, compared: equal + mismatched, mismatchedRuns: largest,
                                    runCount: runs.count)
    }
}

extension StitchFrame {
    /// For the log: pairing this frame's line `r + offset` with `other`'s line `r` for each `r` in `lines`, the
    /// percentage of pairs whose pixels are equal in each of `parts` pieces across the line (inside `margin` pixels at
    /// both ends, as the hashes are), counting only pairs where either piece isn't one flat colour; nil for a piece where
    /// every pair is flat.
    func equalAcross(_ other: StitchFrame, offset: Int, lines: Range<Int>, along axis: ScrollAxis, margin requestedMargin: Int,
                     parts: Int = 8) -> [Int?] {
        precondition(width == other.width && height == other.height && parts > 0)
        let cross = crossLength(along: axis)
        let margin = max(0, min(requestedMargin, cross / 4))
        let span = cross - 2 * margin
        var equal = [Int](repeating: 0, count: parts)
        var counted = [Int](repeating: 0, count: parts)
        // Byte steps between neighbouring pixels along a line and between neighbouring lines.
        let (pixelStep, lineStep) = axis == .vertical ? (4, bytesPerRow) : (bytesPerRow, 4)
        let (otherPixelStep, otherLineStep) = axis == .vertical ? (4, other.bytesPerRow) : (other.bytesPerRow, 4)
        pixels.withUnsafeBytes { mine in
            other.pixels.withUnsafeBytes { theirs in
                for line in lines {
                    let mineStart = (line + offset) * lineStep
                    let theirStart = line * otherLineStep
                    for part in 0..<parts {
                        let start = margin + part * span / parts
                        let end = margin + (part + 1) * span / parts
                        guard end > start else { continue }
                        let firstMine = mine.loadUnaligned(fromByteOffset: mineStart + start * pixelStep, as: UInt32.self)
                        let firstTheirs = theirs.loadUnaligned(fromByteOffset: theirStart + start * otherPixelStep, as: UInt32.self)
                        var same = true
                        var flat = true
                        for pixel in start..<end {
                            let a = mine.loadUnaligned(fromByteOffset: mineStart + pixel * pixelStep, as: UInt32.self)
                            let b = theirs.loadUnaligned(fromByteOffset: theirStart + pixel * otherPixelStep, as: UInt32.self)
                            if a != b { same = false }
                            if a != firstMine || b != firstTheirs { flat = false }
                        }
                        guard !flat else { continue }
                        counted[part] += 1
                        if same { equal[part] += 1 }
                    }
                }
            }
        }
        return zip(equal, counted).map { equal, counted in
            counted == 0 ? nil : Int((100 * Double(equal) / Double(counted)).rounded())
        }
    }
}
